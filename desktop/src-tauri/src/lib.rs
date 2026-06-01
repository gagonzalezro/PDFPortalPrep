use pdf_core::{process, scan, CancelToken, ProcessOutcome, ProcessRequest, ScanResult};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use tauri::{Emitter, State, Window};

/// Registro de trabajos en curso para poder cancelarlos por id.
#[derive(Default)]
struct Jobs(Mutex<HashMap<String, CancelToken>>);

/// Escanea un PDF: tamaño, páginas, validez, cifrado e interactividad.
#[tauri::command]
fn scan_pdf(path: String) -> ScanResult {
    scan(Path::new(&path))
}

/// Procesa (comprime o une+comprime) en un hilo bloqueante para no congelar la
/// UI, emitiendo eventos `compress-progress`. Registra un token cancelable.
#[tauri::command]
async fn process_pdfs(
    window: Window,
    jobs: State<'_, Jobs>,
    job_id: String,
    request: ProcessRequest,
) -> Result<ProcessOutcome, String> {
    let token = CancelToken::new();
    jobs.0.lock().unwrap().insert(job_id.clone(), token.clone());

    let result = tauri::async_runtime::spawn_blocking(move || {
        process(&request, &token, move |p| {
            let _ = window.emit("compress-progress", p);
        })
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string());

    jobs.0.lock().unwrap().remove(&job_id);
    result?
}

/// Cancela un trabajo en curso por su id.
#[tauri::command]
fn cancel_process(jobs: State<'_, Jobs>, job_id: String) {
    if let Some(token) = jobs.0.lock().unwrap().get(&job_id) {
        token.cancel();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Jobs::default())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![scan_pdf, process_pdfs, cancel_process])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
