use pdf_core::{process, ProcessOutcome, ProcessRequest};
use serde::Serialize;
use std::path::PathBuf;
use tauri::{Emitter, Window};

/// Resultado de escanear un PDF para la UI (tamaño + páginas).
/// Versión mínima de Fase 1; la detección de cifrado/interactivos llega en Fase 2.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ScanResult {
    path: String,
    file_size: u64,
    page_count: u32,
    is_valid: bool,
}

#[tauri::command]
fn scan_pdf(path: String) -> ScanResult {
    let p = PathBuf::from(&path);
    let file_size = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
    match pdf_core::pdf::page_count(&p) {
        Ok(page_count) => ScanResult { path, file_size, page_count, is_valid: true },
        Err(_) => ScanResult { path, file_size, page_count: 0, is_valid: false },
    }
}

/// Procesa la petición en un hilo bloqueante para no congelar la UI,
/// emitiendo eventos `compress-progress` a la ventana.
#[tauri::command]
async fn process_pdfs(
    window: Window,
    request: ProcessRequest,
) -> Result<ProcessOutcome, String> {
    tauri::async_runtime::spawn_blocking(move || {
        process(&request, move |p| {
            let _ = window.emit("compress-progress", p);
        })
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![scan_pdf, process_pdfs])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
