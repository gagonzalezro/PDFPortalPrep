use crate::cancel::CancelToken;
use crate::error::PdfError;
use crate::ghostscript;
use crate::merge;
use crate::models::*;
use crate::pdf;
use std::fs;
use std::path::{Path, PathBuf};

/// Resultado intermedio de la escalera de compresión.
#[derive(Debug)]
struct CompressStats {
    final_size: u64,
    applied_dpi: Option<u32>,
    kept_original: bool,
    hit_floor_without_meeting: bool,
}

fn temp_step_path() -> PathBuf {
    std::env::temp_dir().join(format!("pdfportalprep-step-{}.pdf", uuid::Uuid::new_v4()))
}

/// Genera un nombre de salida único: `base.pdf`, luego `base-2.pdf`, etc.
/// Espejo de `Utilities/OutputFileNaming.swift`.
fn unique_output_path(dir: &Path, base_name: &str) -> PathBuf {
    let stem = Path::new(base_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(base_name);
    let mut candidate = dir.join(format!("{stem}.pdf"));
    let mut n = 2u32;
    while candidate.exists() {
        candidate = dir.join(format!("{stem}-{n}.pdf"));
        n += 1;
    }
    candidate
}

/// Orquestación pura de la escalera DPI + guard "output nunca mayor que input".
/// Espejo de `PDFProcessingService.swift:109-184`.
///
/// `step(dpi, path)` produce un archivo comprimido en `path` y devuelve su tamaño.
/// Está inyectado para poder testear la lógica sin invocar Ghostscript.
fn run_ladder<F>(
    input_size: u64,
    target_bytes: u64,
    ladder: &[u32],
    output: &Path,
    cancel: &CancelToken,
    copy_original: &dyn Fn(&Path) -> Result<(), PdfError>,
    mut step: F,
    mut progress: impl FnMut(Progress),
) -> Result<CompressStats, PdfError>
where
    F: FnMut(u32, &Path) -> Result<u64, PdfError>,
{
    let mut best: Option<(PathBuf, u64, u32)> = None; // (ruta, tamaño, dpi)
    let mut hit_floor = false;

    for (i, &dpi) in ladder.iter().enumerate() {
        cancel.check()?; // cancelación antes de cada peldaño (espejo de `:119`)
        progress(Progress::TryingDpi(dpi));
        let step_path = temp_step_path();
        let _ = fs::remove_file(&step_path);
        let size = step(dpi, &step_path)?;

        let is_best = best.as_ref().map_or(true, |(_, bs, _)| size < *bs);
        if is_best {
            if let Some((old, _, _)) = best.take() {
                let _ = fs::remove_file(old);
            }
            best = Some((step_path, size, dpi));
        } else {
            let _ = fs::remove_file(&step_path);
        }

        let best_size = best.as_ref().expect("best siempre presente tras el primer paso").1;
        if best_size <= target_bytes {
            break; // objetivo cumplido: salida temprana
        }
        if i == ladder.len() - 1 {
            hit_floor = true; // se llegó al floor sin cumplir el target
        }
    }

    let (chosen_path, chosen_size, chosen_dpi) = best.expect("la escalera nunca está vacía");

    // Guard: nunca devolver un archivo >= al original.
    if chosen_size >= input_size {
        let _ = fs::remove_file(&chosen_path);
        copy_original(output)?;
        return Ok(CompressStats {
            final_size: input_size,
            applied_dpi: None,
            kept_original: true,
            hit_floor_without_meeting: false,
        });
    }

    fs::copy(&chosen_path, output)?;
    let _ = fs::remove_file(&chosen_path);
    Ok(CompressStats {
        final_size: chosen_size,
        applied_dpi: Some(chosen_dpi),
        kept_original: false,
        hit_floor_without_meeting: hit_floor,
    })
}

/// Punto de entrada principal. Espejo de `PDFProcessingService.process`.
/// Soporta compresión simple y unir+comprimir, con cancelación.
pub fn process(
    req: &ProcessRequest,
    cancel: &CancelToken,
    mut progress: impl FnMut(Progress),
) -> Result<ProcessOutcome, PdfError> {
    if req.input_paths.is_empty() {
        return Err(PdfError::NoInput);
    }
    cancel.check()?;

    // Preparar la fuente: archivo único, o el resultado del merge (temporal).
    let (source, source_is_temp) = match req.action {
        Action::CompressSingle => {
            if req.input_paths.len() != 1 {
                return Err(PdfError::InvalidPdf(
                    "la compresión simple requiere exactamente un PDF".into(),
                ));
            }
            (req.input_paths[0].clone(), false)
        }
        Action::MergeAndCompress => {
            progress(Progress::Merging);
            let combined = std::env::temp_dir()
                .join(format!("pdfportalprep-{}-combined.pdf", uuid::Uuid::new_v4()));
            merge::merge(&req.input_paths, &combined, cancel)?;
            (combined, true)
        }
    };

    let result = compress_source(&source, req, cancel, &mut progress);
    if source_is_temp {
        let _ = fs::remove_file(&source);
    }
    result
}

/// Comprime una fuente ya preparada (single o merged) y construye el Outcome.
fn compress_source(
    source: &Path,
    req: &ProcessRequest,
    cancel: &CancelToken,
    progress: &mut impl FnMut(Progress),
) -> Result<ProcessOutcome, PdfError> {
    let source_size = fs::metadata(source)?.len();
    let output = unique_output_path(&req.output_dir, &req.base_name);

    let stats = if source_size <= req.target_bytes {
        // Ya está bajo el límite: copiar sin recomprimir.
        fs::copy(source, &output)?;
        CompressStats {
            final_size: source_size,
            applied_dpi: None,
            kept_original: true,
            hit_floor_without_meeting: false,
        }
    } else {
        let gs = ghostscript::locate().ok_or(PdfError::GhostscriptNotFound)?;
        let jpeg_q = req.preset.jpeg_quality();
        run_ladder(
            source_size,
            req.target_bytes,
            req.preset.dpi_ladder(),
            &output,
            cancel,
            &|out: &Path| {
                fs::copy(source, out)?;
                Ok(())
            },
            |dpi, path| {
                ghostscript::compress_at_dpi(&gs, source, path, dpi, jpeg_q)?;
                Ok(fs::metadata(path)?.len())
            },
            &mut *progress,
        )?
    };

    progress(Progress::Finalizing);

    // Conteo de páginas estricto (espejo de `:193-197`).
    let page_count = pdf::page_count(&output)?;
    if page_count != req.expected_page_count {
        let _ = fs::remove_file(&output);
        return Err(PdfError::PageCountMismatch {
            expected: req.expected_page_count,
            actual: page_count,
        });
    }

    // Reducción honesta: nunca negativa si se conservó el original (`:201-204`).
    let raw_reduction = if req.original_total_size > 0 {
        (req.original_total_size as f64 - stats.final_size as f64) / req.original_total_size as f64
            * 100.0
    } else {
        0.0
    };
    let reduction = if stats.kept_original {
        raw_reduction.max(0.0)
    } else {
        raw_reduction
    };

    Ok(ProcessOutcome {
        output_path: output,
        final_size: stats.final_size,
        original_size: req.original_total_size,
        page_count,
        expected_page_count: req.expected_page_count,
        reduction_percentage: reduction,
        applied_dpi: stats.applied_dpi,
        kept_original: stats.kept_original,
        hit_floor_without_meeting: stats.hit_floor_without_meeting,
        meets_limit: stats.final_size <= req.target_bytes,
        engine_label: ghostscript::engine_label(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_sized(path: &Path, size: u64) -> Result<u64, PdfError> {
        fs::write(path, vec![0u8; size as usize])?;
        Ok(size)
    }

    fn tmp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("pdfcore-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn target_met_exits_early_and_keeps_best_step() {
        let dir = tmp_dir();
        let out = dir.join("out.pdf");
        let mut tried = Vec::new();
        let stats = run_ladder(
            1000,
            400,
            &[220, 180, 150],
            &out,
            &CancelToken::new(),
            &|o| write_sized(o, 4).map(|_| ()),
            |dpi, p| {
                tried.push(dpi);
                let s = match dpi {
                    220 => 500, // > target
                    180 => 300, // <= target -> para aquí
                    _ => 200,
                };
                write_sized(p, s)
            },
            |_| {},
        )
        .unwrap();

        assert_eq!(tried, vec![220, 180], "no debe probar el floor 150");
        assert_eq!(stats.final_size, 300);
        assert_eq!(stats.applied_dpi, Some(180));
        assert!(!stats.kept_original);
        assert!(!stats.hit_floor_without_meeting);
        assert!(out.exists());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn hits_floor_without_meeting_target() {
        let dir = tmp_dir();
        let out = dir.join("out.pdf");
        let stats = run_ladder(
            1000,
            100, // target inalcanzable
            &[220, 180, 150],
            &out,
            &CancelToken::new(),
            &|o| write_sized(o, 4).map(|_| ()),
            |dpi, p| {
                let s = match dpi {
                    220 => 800,
                    180 => 600,
                    _ => 500, // floor, mejor pero aún > target
                };
                write_sized(p, s)
            },
            |_| {},
        )
        .unwrap();

        assert_eq!(stats.final_size, 500);
        assert_eq!(stats.applied_dpi, Some(150));
        assert!(!stats.kept_original);
        assert!(stats.hit_floor_without_meeting, "debe marcar el floor sin target");
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn guard_keeps_original_when_compression_is_bigger() {
        let dir = tmp_dir();
        let out = dir.join("out.pdf");
        let stats = run_ladder(
            1000,
            100,
            &[220, 180, 150],
            &out,
            &CancelToken::new(),
            &|o| write_sized(o, 1000).map(|_| ()), // "original"
            |dpi, p| {
                // Todos los pasos salen MÁS grandes que el input.
                let s = match dpi {
                    220 => 1100,
                    180 => 1200,
                    _ => 1300,
                };
                write_sized(p, s)
            },
            |_| {},
        )
        .unwrap();

        assert_eq!(stats.final_size, 1000, "se conserva el tamaño del original");
        assert_eq!(stats.applied_dpi, None);
        assert!(stats.kept_original);
        assert!(!stats.hit_floor_without_meeting);
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn cancelled_before_ladder_returns_error() {
        let dir = tmp_dir();
        let out = dir.join("out.pdf");
        let token = CancelToken::new();
        token.cancel();
        let err = run_ladder(
            1000,
            100,
            &[220, 180, 150],
            &out,
            &token,
            &|o| write_sized(o, 4).map(|_| ()),
            |_dpi, p| write_sized(p, 50),
            |_| {},
        )
        .unwrap_err();
        assert!(matches!(err, PdfError::Cancelled));
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn preset_contract_matches_swift() {
        assert_eq!(CompressionPreset::Light.dpi_ladder(), &[220, 180, 150]);
        assert_eq!(CompressionPreset::Balanced.dpi_ladder(), &[150, 130, 110]);
        assert_eq!(CompressionPreset::Maximum.dpi_ladder(), &[110, 90, 72]);
        assert_eq!(CompressionPreset::Balanced.floor_dpi(), 110);
        assert_eq!(CompressionPreset::Maximum.jpeg_quality(), 0.55);
        assert!(CompressionPreset::Maximum.always_warns_about_quality());
        assert!(!CompressionPreset::Light.always_warns_about_quality());
    }

    #[test]
    fn unique_output_path_avoids_collisions() {
        let dir = tmp_dir();
        let p1 = unique_output_path(&dir, "Documento.pdf");
        assert_eq!(p1.file_name().unwrap(), "Documento.pdf");
        fs::write(&p1, b"x").unwrap();
        let p2 = unique_output_path(&dir, "Documento.pdf");
        assert_eq!(p2.file_name().unwrap(), "Documento-2.pdf");
        fs::remove_dir_all(&dir).ok();
    }
}
