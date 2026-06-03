use crate::error::PdfError;
use std::env;
#[cfg(any(target_os = "windows", test))]
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Rutas comunes de Ghostscript. Espejo de `Services/GhostscriptLocator.swift`.
#[cfg(not(target_os = "windows"))]
const COMMON_PATHS: &[&str] = &[
    "/opt/homebrew/bin/gs", // Homebrew Apple Silicon
    "/usr/local/bin/gs",    // Homebrew Intel
    "/usr/bin/gs",          // sistema
];

fn first_existing(candidates: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    candidates.into_iter().find(|candidate| candidate.is_file())
}

fn locate_in_path(names: &[&str]) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        for name in names {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn windows_install_candidates_from(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    for root in roots {
        let gs_root = root.join("gs");
        let Ok(entries) = fs::read_dir(gs_root) else {
            continue;
        };

        let mut versions = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect::<Vec<_>>();
        versions.sort();
        versions.reverse();

        for version in versions {
            candidates.push(version.join("bin").join("gswin64c.exe"));
            candidates.push(version.join("bin").join("gswin32c.exe"));
            candidates.push(version.join("bin").join("gs.exe"));
        }
    }

    candidates
}

#[cfg(target_os = "windows")]
fn windows_install_candidates() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for var in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(root) = env::var_os(var) {
            roots.push(PathBuf::from(root));
        }
    }
    windows_install_candidates_from(&roots)
}

#[cfg(target_os = "windows")]
fn locate_via_shell() -> Option<PathBuf> {
    let out = Command::new("where").arg("gswin64c.exe").output().ok()?;
    if out.status.success() {
        let s = String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|line| !line.trim().is_empty())?
            .trim()
            .to_string();
        return Some(PathBuf::from(s));
    }
    None
}

#[cfg(not(target_os = "windows"))]
fn locate_via_shell() -> Option<PathBuf> {
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

/// Localiza Ghostscript con rutas conocidas del sistema, PATH y lookup de shell.
pub fn locate() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        first_existing(windows_install_candidates())
            .or_else(|| locate_in_path(&["gswin64c.exe", "gswin32c.exe", "gs.exe", "gs"]))
            .or_else(locate_via_shell)
    }

    #[cfg(not(target_os = "windows"))]
    {
        first_existing(COMMON_PATHS.iter().map(PathBuf::from))
            .or_else(|| locate_in_path(&["gs"]))
            .or_else(locate_via_shell)
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_install_candidates_include_latest_program_files_versions() {
        let temp = env::temp_dir().join(format!("gs-locate-{}", uuid::Uuid::new_v4()));
        let program_files = temp.join("Program Files");
        let old_bin = program_files.join("gs").join("10.03.0").join("bin");
        let new_bin = program_files.join("gs").join("10.05.1").join("bin");

        fs::create_dir_all(&old_bin).unwrap();
        fs::create_dir_all(&new_bin).unwrap();
        fs::write(old_bin.join("gswin64c.exe"), []).unwrap();
        fs::write(new_bin.join("gswin64c.exe"), []).unwrap();

        let candidates = windows_install_candidates_from(&[program_files]);

        assert_eq!(
            candidates.first(),
            Some(&new_bin.join("gswin64c.exe")),
            "debe priorizar la versión más nueva instalada"
        );

        fs::remove_dir_all(temp).ok();
    }

    #[test]
    fn locate_in_path_finds_binary_in_supplied_path() {
        let temp = env::temp_dir().join(format!("gs-path-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&temp).unwrap();

        #[cfg(target_os = "windows")]
        let binary_name = "gswin64c.exe";
        #[cfg(not(target_os = "windows"))]
        let binary_name = "gs";

        let binary_path = temp.join(binary_name);
        fs::write(&binary_path, []).unwrap();

        let original_path = env::var_os("PATH");
        let new_path = env::join_paths([temp.clone()]).unwrap();
        unsafe { env::set_var("PATH", new_path) };

        let located = locate_in_path(&[binary_name]);

        match original_path {
            Some(path) => unsafe { env::set_var("PATH", path) },
            None => unsafe { env::remove_var("PATH") },
        }

        assert_eq!(located, Some(binary_path));

        fs::remove_dir_all(temp).ok();
    }
}
