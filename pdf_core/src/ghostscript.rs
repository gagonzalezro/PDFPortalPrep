use crate::error::PdfError;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Rutas comunes de Ghostscript. Espejo de `Services/GhostscriptLocator.swift`.
const COMMON_PATHS: &[&str] = &[
    "/opt/homebrew/bin/gs", // Homebrew Apple Silicon
    "/usr/local/bin/gs",    // Homebrew Intel
    "/usr/bin/gs",          // sistema
];

/// Localiza el binario `gs`: primero rutas conocidas, luego `which gs`.
pub fn locate() -> Option<PathBuf> {
    for p in COMMON_PATHS {
        if Path::new(p).is_file() {
            return Some(PathBuf::from(p));
        }
    }
    if let Ok(out) = Command::new("/usr/bin/env").args(["which", "gs"]).output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return Some(PathBuf::from(s));
            }
        }
    }
    None
}

/// Etiqueta del motor para la UI.
pub fn engine_label() -> String {
    if locate().is_some() {
        "Ghostscript".to_string()
    } else {
        "Ninguno disponible".to_string()
    }
}

/// Comprime `input` en `output` a un DPI dado.
/// Flags copiados verbatim de `PDFCompressionService.swift:80-104`.
pub fn compress_at_dpi(
    gs: &Path,
    input: &Path,
    output: &Path,
    dpi: u32,
    jpeg_quality: f64,
) -> Result<(), PdfError> {
    let jpeg_q = ((jpeg_quality * 100.0).round() as i64).clamp(1, 100);

    let mut args: Vec<String> = vec![
        "-dNOPAUSE".into(),
        "-dBATCH".into(),
        "-dQUIET".into(),
        "-sDEVICE=pdfwrite".into(),
        "-dCompatibilityLevel=1.4".into(),
        "-dAutoFilterColorImages=false".into(),
        "-dAutoFilterGrayImages=false".into(),
        "-dColorImageFilter=/DCTEncode".into(),
        format!("-dColorImageResolution={dpi}"),
        "-dGrayImageFilter=/DCTEncode".into(),
        format!("-dGrayImageResolution={dpi}"),
        "-dMonoImageFilter=/CCITTFaxEncode".into(),
        format!("-dMonoImageResolution={dpi}"),
        "-dDownsampleColorImages=true".into(),
        "-dDownsampleGrayImages=true".into(),
        "-dDownsampleMonoImages=true".into(),
        format!("-dJPEGQ={jpeg_q}"),
        "-dSubsetFonts=true".into(),
        "-dCompressFonts=true".into(),
        format!("-sOutputFile={}", output.display()),
    ];
    args.push(input.display().to_string());

    let out = Command::new(gs).args(&args).output()?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(PdfError::Ghostscript(if stderr.is_empty() {
            format!("código de salida {:?}", out.status.code())
        } else {
            stderr
        }));
    }
    Ok(())
}
