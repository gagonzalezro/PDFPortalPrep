mod gmail;

use pdf_core::{process, scan, CancelToken, ProcessOutcome, ProcessRequest, ScanResult};
use serde_json::json;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State, Window};

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

#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    let target = PathBuf::from(&path);
    if !target.exists() {
        return Err(format!("La ruta no existe: {path}"));
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", &path])
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&path)
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(&path)
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[tauri::command]
fn reveal_in_folder(path: String) -> Result<(), String> {
    let target = PathBuf::from(&path);
    if !target.exists() {
        return Err(format!("La ruta no existe: {path}"));
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", target.display()))
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .args(["-R", &path])
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let parent = target
            .parent()
            .ok_or_else(|| format!("La ruta no tiene carpeta contenedora: {path}"))?;
        std::process::Command::new("xdg-open")
            .arg(parent)
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[tauri::command]
fn write_process_log(
    app: AppHandle,
    output_path: String,
    original_size: u64,
    final_size: u64,
    page_count: u32,
    compression_level: String,
    meets_limit: bool,
) -> Result<String, String> {
    let app_data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let log_dir = app_data_dir.join("PDFPortalPrep");
    fs::create_dir_all(&log_dir).map_err(|e| e.to_string())?;

    let log_path = log_dir.join("process-log.jsonl");
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();

    let entry = json!({
        "createdAtEpochSeconds": created_at,
        "result": output_path,
        "originalSizeBytes": original_size,
        "finalSizeBytes": final_size,
        "pageCount": page_count,
        "compressionLevel": compression_level,
        "meetsLimit": meets_limit
    });

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| e.to_string())?;
    writeln!(file, "{entry}").map_err(|e| e.to_string())?;

    Ok(log_path.to_string_lossy().to_string())
}

#[tauri::command]
async fn gmail_connected_accounts(app: AppHandle) -> Result<Vec<gmail::GmailConnectedAccount>, String> {
    tauri::async_runtime::spawn_blocking(move || gmail::connected_accounts(&app))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn gmail_connect(app: AppHandle) -> Result<gmail::GmailConnectedAccount, String> {
    tauri::async_runtime::spawn_blocking(move || gmail::connect(&app))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn gmail_disconnect(app: AppHandle, account_email: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || gmail::disconnect(&app, &account_email))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn gmail_search(
    app: AppHandle,
    filters: gmail::GmailSearchFilters,
    account_emails: Vec<String>,
) -> Result<gmail::GmailSearchResult, String> {
    tauri::async_runtime::spawn_blocking(move || gmail::search(&app, filters, account_emails))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn gmail_download(
    app: AppHandle,
    attachments: Vec<gmail::GmailAttachmentResult>,
) -> Result<Vec<String>, String> {
    tauri::async_runtime::spawn_blocking(move || gmail::download(&app, attachments))
        .await
        .map_err(|e| e.to_string())?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Jobs::default())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            scan_pdf,
            process_pdfs,
            cancel_process,
            open_path,
            reveal_in_folder,
            write_process_log,
            gmail_connected_accounts,
            gmail_connect,
            gmail_disconnect,
            gmail_search,
            gmail_download
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
