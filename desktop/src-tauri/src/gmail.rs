use base64::Engine;
use keyring::Entry;
use rand::RngCore;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};
use url::Url;

const GMAIL_SCOPE: &str = "https://www.googleapis.com/auth/gmail.readonly";
const KEYCHAIN_SERVICE: &str = "PDFPortalPrep.GmailOAuth";
const GMAIL_SEARCH_PAGE_SIZE: usize = 100;
const GMAIL_SEARCH_MESSAGE_LIMIT: usize = 500;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GmailConnectedAccount {
    pub email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GmailSearchFilters {
    pub text: String,
    pub from: String,
    pub after: String,
    pub before: String,
}

impl GmailSearchFilters {
    fn query(&self) -> String {
        let mut parts = vec!["has:attachment".to_string(), "filename:pdf".to_string()];
        let text = self.text.trim();
        let from = self.from.trim();
        let after = self.after.trim();
        let before = self.before.trim();

        if !text.is_empty() {
            parts.push(text.to_string());
        }
        if !from.is_empty() {
            parts.push(format!("from:{from}"));
        }
        if !after.is_empty() {
            parts.push(format!("after:{}", after.replace('-', "/")));
        }
        if !before.is_empty() {
            parts.push(format!("before:{}", before.replace('-', "/")));
        }

        parts.join(" ")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GmailAttachmentResult {
    pub id: String,
    pub account_email: String,
    pub message_id: String,
    pub attachment_id: String,
    pub filename: String,
    pub size: u64,
    pub subject: String,
    pub from: String,
    pub date: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GmailSearchResult {
    pub scanned_message_count: usize,
    pub attachments: Vec<GmailAttachmentResult>,
    pub reached_limit: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GmailOAuthConfiguration {
    client_id: String,
    client_secret: String,
    auth_uri: String,
    token_uri: String,
}

impl GmailOAuthConfiguration {
    fn load(app: &AppHandle) -> Result<Self, String> {
        if let (Ok(client_id), Ok(client_secret)) = (
            std::env::var("GOOGLE_OAUTH_CLIENT_ID"),
            std::env::var("GOOGLE_OAUTH_CLIENT_SECRET"),
        ) {
            if is_usable_value(&client_id) && is_usable_value(&client_secret) {
                return Ok(Self {
                    client_id: client_id.trim().to_string(),
                    client_secret: client_secret.trim().to_string(),
                    auth_uri: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
                    token_uri: "https://oauth2.googleapis.com/token".to_string(),
                });
            }
        }

        for candidate in configuration_candidates(app) {
            if let Ok(content) = fs::read_to_string(&candidate) {
                if let (Some(client_id), Some(client_secret)) = (
                    plist_value(&content, "GoogleOAuthClientID"),
                    plist_value(&content, "GoogleOAuthClientSecret"),
                ) {
                    if is_usable_value(&client_id) && is_usable_value(&client_secret) {
                        return Ok(Self {
                            client_id: client_id.trim().to_string(),
                            client_secret: client_secret.trim().to_string(),
                            auth_uri: "https://accounts.google.com/o/oauth2/v2/auth".to_string(),
                            token_uri: "https://oauth2.googleapis.com/token".to_string(),
                        });
                    }
                }
            }
        }

        Err("Faltan GoogleOAuthClientID y GoogleOAuthClientSecret. Define GOOGLE_OAUTH_CLIENT_ID/SECRET o crea Resources/GoogleOAuth.plist a partir del ejemplo.".to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GmailToken {
    access_token: String,
    refresh_token: Option<String>,
    expires_at_epoch_seconds: u64,
}

impl GmailToken {
    fn needs_refresh(&self) -> bool {
        unix_now() + 60 >= self.expires_at_epoch_seconds
    }
}

#[derive(Debug, Clone)]
struct OAuthCallback {
    code: String,
    state: String,
}

#[derive(Debug, Clone)]
struct OAuthPkce {
    verifier: String,
    challenge: String,
}

impl OAuthPkce {
    fn make() -> Self {
        let mut bytes = [0_u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let verifier = base64_url_encode(&bytes);
        let digest = Sha256::digest(verifier.as_bytes());
        let challenge = base64_url_encode(&digest);
        Self { verifier, challenge }
    }
}

#[derive(Debug, Deserialize)]
struct TokenApiResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct GmailProfile {
    #[serde(rename = "emailAddress")]
    email_address: String,
}

#[derive(Debug, Deserialize)]
struct GmailListResponse {
    messages: Option<Vec<GmailMessageId>>,
    #[serde(rename = "nextPageToken")]
    next_page_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GmailMessageId {
    id: String,
}

#[derive(Debug, Deserialize)]
struct GmailMessage {
    id: String,
    payload: Option<GmailPayload>,
}

impl GmailMessage {
    fn pdf_attachments(&self, account_email: &str) -> Vec<GmailAttachmentResult> {
        let headers = self
            .payload
            .as_ref()
            .and_then(|payload| payload.headers.as_deref());
        let subject = header_value(headers, "Subject").unwrap_or("(sin asunto)");
        let from = header_value(headers, "From").unwrap_or("(sin remitente)");
        let date = header_value(headers, "Date").unwrap_or("");

        flattened_parts(self.payload.as_ref())
            .into_iter()
            .filter_map(|part| {
                let filename = part.filename.clone().unwrap_or_default();
                let attachment_id = part.body.as_ref()?.attachment_id.clone()?;
                if !filename.to_lowercase().ends_with(".pdf") {
                    return None;
                }

                Some(GmailAttachmentResult {
                    id: format!("{}-{}-{}-{}", account_email, self.id, attachment_id, filename),
                    account_email: account_email.to_string(),
                    message_id: self.id.clone(),
                    attachment_id,
                    filename,
                    size: part.body.as_ref().and_then(|body| body.size).unwrap_or(0),
                    subject: subject.to_string(),
                    from: from.to_string(),
                    date: date.to_string(),
                })
            })
            .collect()
    }
}

#[derive(Debug, Deserialize)]
struct GmailPayload {
    filename: Option<String>,
    headers: Option<Vec<GmailHeader>>,
    body: Option<GmailBody>,
    parts: Option<Vec<GmailPayload>>,
}

#[derive(Debug, Deserialize)]
struct GmailHeader {
    name: String,
    value: String,
}

#[derive(Debug, Deserialize)]
struct GmailBody {
    #[serde(rename = "attachmentId")]
    attachment_id: Option<String>,
    size: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct GmailAttachmentDownload {
    data: String,
}

#[derive(Debug, Deserialize)]
struct GoogleApiErrorResponse {
    error: GoogleApiError,
}

#[derive(Debug, Deserialize)]
struct GoogleApiError {
    message: Option<String>,
    status: Option<String>,
    errors: Option<Vec<GoogleApiErrorDetail>>,
}

#[derive(Debug, Deserialize)]
struct GoogleApiErrorDetail {
    reason: Option<String>,
}

pub fn connected_accounts(app: &AppHandle) -> Result<Vec<GmailConnectedAccount>, String> {
    Ok(stored_account_emails(app)?
        .into_iter()
        .map(|email| GmailConnectedAccount { email })
        .collect())
}

pub fn connect(app: &AppHandle) -> Result<GmailConnectedAccount, String> {
    let configuration = GmailOAuthConfiguration::load(app)?;
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    listener
        .set_nonblocking(true)
        .map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}/oauth2callback");
    let state = format!("state-{}", unix_now());
    let pkce = OAuthPkce::make();

    let mut auth_url = Url::parse(&configuration.auth_uri).map_err(|e| e.to_string())?;
    auth_url.query_pairs_mut()
        .append_pair("client_id", &configuration.client_id)
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", GMAIL_SCOPE)
        .append_pair("access_type", "offline")
        .append_pair("prompt", "consent select_account")
        .append_pair("state", &state)
        .append_pair("code_challenge", &pkce.challenge)
        .append_pair("code_challenge_method", "S256");

    open_external(auth_url.as_str())?;
    let callback = wait_for_oauth_callback(listener)?;
    if callback.state != state {
        return Err("Google devolvio un estado OAuth invalido.".to_string());
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;
    let token = exchange_code(&client, &configuration, &callback.code, &redirect_uri, &pkce.verifier)?;
    let profile = fetch_profile(&client, &token.access_token)?;
    let account = GmailConnectedAccount {
        email: normalize_email(&profile.email_address),
    };
    save_token(app, &account.email, &token)?;
    Ok(account)
}

pub fn disconnect(app: &AppHandle, account_email: &str) -> Result<(), String> {
    let entry = Entry::new(KEYCHAIN_SERVICE, account_email).map_err(|e| e.to_string())?;
    let _ = entry.delete_credential();
    remove_stored_account_email(app, account_email)
}

pub fn search(
    app: &AppHandle,
    filters: GmailSearchFilters,
    account_emails: Vec<String>,
) -> Result<GmailSearchResult, String> {
    let accounts = if account_emails.is_empty() {
        stored_account_emails(app)?
    } else {
        let mut emails = account_emails
            .into_iter()
            .map(|email| normalize_email(&email))
            .filter(|email| !email.is_empty())
            .collect::<Vec<_>>();
        emails.sort();
        emails.dedup();
        emails
    };

    if accounts.is_empty() {
        return Err("Selecciona al menos una cuenta Gmail conectada.".to_string());
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;

    let mut attachments = Vec::new();
    let mut scanned_message_count = 0;
    let mut reached_limit = false;
    let query = filters.query();

    for account in accounts {
        let access_token = valid_access_token(app, &client, &account)?;
        let message_search = search_message_ids(&client, &query, &access_token)?;
        scanned_message_count += message_search.0.len();
        reached_limit |= message_search.1;

        for id in message_search.0 {
            let message = fetch_message(&client, &id, &access_token)?;
            attachments.extend(message.pdf_attachments(&account));
        }
    }

    Ok(GmailSearchResult {
        scanned_message_count,
        attachments,
        reached_limit,
    })
}

pub fn download(app: &AppHandle, attachments: Vec<GmailAttachmentResult>) -> Result<Vec<String>, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;
    let download_dir = std::env::temp_dir().join(format!("PDFPortalPrep-Gmail-{}", unix_now()));
    fs::create_dir_all(&download_dir).map_err(|e| e.to_string())?;

    let mut outputs = Vec::new();
    for attachment in attachments {
        let access_token = valid_access_token(app, &client, &attachment.account_email)?;
        let data = fetch_attachment_data(&client, &attachment, &access_token)?;
        let filename = unique_filename(&download_dir, &attachment.filename, &attachment.account_email)?;
        let output = download_dir.join(filename);
        fs::write(&output, data).map_err(|e| e.to_string())?;
        outputs.push(output.to_string_lossy().to_string());
    }

    Ok(outputs)
}

fn exchange_code(
    client: &Client,
    configuration: &GmailOAuthConfiguration,
    code: &str,
    redirect_uri: &str,
    code_verifier: &str,
) -> Result<GmailToken, String> {
    let response = client
        .post(&configuration.token_uri)
        .form(&[
            ("code", code),
            ("client_id", &configuration.client_id),
            ("client_secret", &configuration.client_secret),
            ("redirect_uri", redirect_uri),
            ("grant_type", "authorization_code"),
            ("code_verifier", code_verifier),
        ])
        .send()
        .map_err(|e| e.to_string())?;

    decode_token_response(response)
}

fn refresh_access_token(
    client: &Client,
    configuration: &GmailOAuthConfiguration,
    refresh_token: &str,
) -> Result<GmailToken, String> {
    let response = client
        .post(&configuration.token_uri)
        .form(&[
            ("refresh_token", refresh_token),
            ("client_id", &configuration.client_id),
            ("client_secret", &configuration.client_secret),
            ("grant_type", "refresh_token"),
        ])
        .send()
        .map_err(|e| e.to_string())?;

    decode_token_response(response)
}

fn decode_token_response(response: reqwest::blocking::Response) -> Result<GmailToken, String> {
    let status = response.status();
    let body = response.text().map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(friendly_google_api_error(status.as_u16(), &body));
    }

    let decoded: TokenApiResponse = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    Ok(GmailToken {
        access_token: decoded.access_token,
        refresh_token: decoded.refresh_token,
        expires_at_epoch_seconds: unix_now() + decoded.expires_in.unwrap_or(3600),
    })
}

fn fetch_profile(client: &Client, access_token: &str) -> Result<GmailProfile, String> {
    let response = client
        .get("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        .bearer_auth(access_token)
        .send()
        .map_err(|e| e.to_string())?;
    decode_json_response(response)
}

fn search_message_ids(client: &Client, query: &str, access_token: &str) -> Result<(Vec<String>, bool), String> {
    let mut all_ids = Vec::new();
    let mut page_token: Option<String> = None;

    loop {
        let mut url = Url::parse("https://gmail.googleapis.com/gmail/v1/users/me/messages")
            .map_err(|e| e.to_string())?;
        url.query_pairs_mut()
            .append_pair("q", query)
            .append_pair("maxResults", &GMAIL_SEARCH_PAGE_SIZE.to_string());
        if let Some(token) = &page_token {
            url.query_pairs_mut().append_pair("pageToken", token);
        }

        let response = client
            .get(url)
            .bearer_auth(access_token)
            .send()
            .map_err(|e| e.to_string())?;
        let decoded: GmailListResponse = decode_json_response(response)?;
        all_ids.extend(decoded.messages.unwrap_or_default().into_iter().map(|message| message.id));
        page_token = decoded.next_page_token;

        if page_token.is_none() || all_ids.len() >= GMAIL_SEARCH_MESSAGE_LIMIT {
            break;
        }
    }

    all_ids.truncate(GMAIL_SEARCH_MESSAGE_LIMIT);
    Ok((all_ids, page_token.is_some()))
}

fn fetch_message(client: &Client, id: &str, access_token: &str) -> Result<GmailMessage, String> {
    let mut url = Url::parse(&format!("https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}"))
        .map_err(|e| e.to_string())?;
    url.query_pairs_mut().append_pair("format", "full");
    let response = client
        .get(url)
        .bearer_auth(access_token)
        .send()
        .map_err(|e| e.to_string())?;
    decode_json_response(response)
}

fn fetch_attachment_data(
    client: &Client,
    attachment: &GmailAttachmentResult,
    access_token: &str,
) -> Result<Vec<u8>, String> {
    let response = client
        .get(format!(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/{}/attachments/{}",
            attachment.message_id, attachment.attachment_id
        ))
        .bearer_auth(access_token)
        .send()
        .map_err(|e| e.to_string())?;
    let decoded: GmailAttachmentDownload = decode_json_response(response)?;
    base64_url_decode(&decoded.data)
}

fn decode_json_response<T: for<'de> Deserialize<'de>>(response: reqwest::blocking::Response) -> Result<T, String> {
    let status = response.status();
    let body = response.text().map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(friendly_google_api_error(status.as_u16(), &body));
    }
    serde_json::from_str(&body).map_err(|e| e.to_string())
}

fn valid_access_token(app: &AppHandle, client: &Client, account: &str) -> Result<String, String> {
    let mut token = load_token(account)?;
    if !token.needs_refresh() {
        return Ok(token.access_token);
    }

    let refresh_token = token
        .refresh_token
        .clone()
        .ok_or_else(|| format!("La sesion de {account} expiro. Desconecta y vuelve a conectar esa cuenta."))?;
    let configuration = GmailOAuthConfiguration::load(app)?;
    let refreshed = refresh_access_token(client, &configuration, &refresh_token)?;
    token.access_token = refreshed.access_token;
    token.expires_at_epoch_seconds = refreshed.expires_at_epoch_seconds;
    token.refresh_token = refreshed.refresh_token.or(Some(refresh_token));
    save_token(app, account, &token)?;
    Ok(token.access_token)
}

fn load_token(account: &str) -> Result<GmailToken, String> {
    let entry = Entry::new(KEYCHAIN_SERVICE, account).map_err(|e| e.to_string())?;
    let value = entry.get_password().map_err(|_| "Gmail no esta conectado.".to_string())?;
    serde_json::from_str(&value).map_err(|e| e.to_string())
}

fn save_token(app: &AppHandle, account: &str, token: &GmailToken) -> Result<(), String> {
    let entry = Entry::new(KEYCHAIN_SERVICE, account).map_err(|e| e.to_string())?;
    let value = serde_json::to_string(token).map_err(|e| e.to_string())?;
    entry.set_password(&value).map_err(|e| e.to_string())?;
    add_stored_account_email(app, account)
}

fn wait_for_oauth_callback(listener: TcpListener) -> Result<OAuthCallback, String> {
    let deadline = SystemTime::now() + Duration::from_secs(180);
    loop {
        if SystemTime::now() > deadline {
            return Err("Tiempo de espera agotado para el callback OAuth de Google.".to_string());
        }

        match listener.accept() {
            Ok((mut stream, _)) => {
                let mut buffer = [0_u8; 4096];
                let count = stream.read(&mut buffer).map_err(|e| e.to_string())?;
                let request = String::from_utf8_lossy(&buffer[..count]);
                let first_line = request.lines().next().unwrap_or_default();
                let target = first_line.split_whitespace().nth(1).unwrap_or_default();
                let callback_url = Url::parse(&format!("http://127.0.0.1{target}")).map_err(|e| e.to_string())?;
                let code = callback_url
                    .query_pairs()
                    .find(|(key, _)| key == "code")
                    .map(|(_, value)| value.to_string())
                    .ok_or_else(|| "Google no devolvio codigo OAuth.".to_string())?;
                let state = callback_url
                    .query_pairs()
                    .find(|(key, _)| key == "state")
                    .map(|(_, value)| value.to_string())
                    .ok_or_else(|| "Google no devolvio estado OAuth.".to_string())?;

                let html = "<html><body><h3>Gmail conectado. Ya puedes volver a la app.</h3></body></html>";
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    html.len(), html
                );
                let _ = stream.write_all(response.as_bytes());

                return Ok(OAuthCallback { code, state });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn open_external(target: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", target])
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(target)
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(target)
            .spawn()
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

fn friendly_google_api_error(status_code: u16, body: &str) -> String {
    let decoded = serde_json::from_str::<GoogleApiErrorResponse>(body).ok();
    let message = decoded
        .as_ref()
        .and_then(|error| error.error.message.clone())
        .unwrap_or_else(|| body.to_string());
    let reason = decoded
        .as_ref()
        .and_then(|error| error.error.errors.as_ref())
        .and_then(|errors| errors.first())
        .and_then(|error| error.reason.clone())
        .or_else(|| decoded.as_ref().and_then(|error| error.error.status.clone()))
        .unwrap_or_default()
        .to_lowercase();
    let combined = format!("{} {}", message.to_lowercase(), reason);

    if status_code == 403 && combined.contains("gmail api") && combined.contains("disabled") {
        return format!(
            "Gmail API no esta habilitada para este proyecto de Google Cloud. Detalle Google: {message}"
        );
    }

    if status_code == 403 && (combined.contains("insufficient") || combined.contains("scope")) {
        return format!(
            "Google autorizo la cuenta, pero el token no tiene permiso suficiente para Gmail. Detalle Google: {message}"
        );
    }

    format!("Google API devolvio HTTP {status_code}: {message}")
}

fn configuration_candidates(app: &AppHandle) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("GoogleOAuth.plist"));
    }

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    candidates.push(repo_root.join("Resources").join("GoogleOAuth.plist"));
    candidates.push(repo_root.join("Resources").join("GoogleOAuth.example.plist"));
    candidates
}

fn plist_value(content: &str, key: &str) -> Option<String> {
    let key_tag = format!("<key>{key}</key>");
    let key_index = content.find(&key_tag)?;
    let rest = &content[key_index + key_tag.len()..];
    let start = rest.find("<string>")? + "<string>".len();
    let end = rest[start..].find("</string>")? + start;
    Some(rest[start..end].trim().to_string())
}

fn is_usable_value(value: &str) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty() && !trimmed.starts_with("YOUR_") && !trimmed.starts_with("REPLACE_WITH_")
}

fn connected_accounts_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("PDFPortalPrep");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("gmail-connected-accounts.json"))
}

fn stored_account_emails(app: &AppHandle) -> Result<Vec<String>, String> {
    let path = connected_accounts_path(app)?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut emails = serde_json::from_str::<Vec<String>>(&content).map_err(|e| e.to_string())?;
    emails.sort();
    emails.dedup();
    Ok(emails)
}

fn add_stored_account_email(app: &AppHandle, email: &str) -> Result<(), String> {
    let mut emails = stored_account_emails(app)?;
    let normalized = normalize_email(email);
    if !emails.contains(&normalized) {
        emails.push(normalized);
    }
    emails.sort();
    let path = connected_accounts_path(app)?;
    fs::write(path, serde_json::to_vec_pretty(&emails).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn remove_stored_account_email(app: &AppHandle, email: &str) -> Result<(), String> {
    let target = normalize_email(email);
    let emails = stored_account_emails(app)?
        .into_iter()
        .filter(|value| value != &target)
        .collect::<Vec<_>>();
    let path = connected_accounts_path(app)?;
    fs::write(path, serde_json::to_vec_pretty(&emails).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn normalize_email(email: &str) -> String {
    email.trim().to_lowercase()
}

fn header_value<'a>(headers: Option<&'a [GmailHeader]>, name: &str) -> Option<&'a str> {
    headers?
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

fn flattened_parts(payload: Option<&GmailPayload>) -> Vec<&GmailPayload> {
    let Some(payload) = payload else {
        return Vec::new();
    };

    let mut parts = vec![payload];
    for child in payload.parts.as_deref().unwrap_or_default() {
        parts.extend(flattened_parts(Some(child)));
    }
    parts
}

fn base64_url_encode(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn base64_url_decode(value: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value.as_bytes())
        .map_err(|e| e.to_string())
}

fn unique_filename(dir: &Path, filename: &str, account_email: &str) -> Result<String, String> {
    let base_name = sanitize_filename(filename);
    if !dir.join(&base_name).exists() {
        return Ok(base_name);
    }

    let url = Path::new(&base_name);
    let stem = url.file_stem().and_then(|value| value.to_str()).unwrap_or("gmail-attachment");
    let extension = url.extension().and_then(|value| value.to_str()).unwrap_or("pdf");
    let account_suffix = account_email
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect::<String>();
    let candidate = format!("{}-{}.{}", stem, account_suffix, extension);
    if !dir.join(&candidate).exists() {
        return Ok(candidate);
    }

    Ok(format!("{}-{}.{}", unix_now(), stem, extension))
}

fn sanitize_filename(filename: &str) -> String {
    let raw = if filename.trim().is_empty() {
        "gmail-attachment.pdf"
    } else {
        filename
    };
    raw.chars()
        .map(|ch| match ch {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            _ => ch,
        })
        .collect()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gmail_query_matches_swift_shape() {
        let filters = GmailSearchFilters {
            text: "visa payslip".to_string(),
            from: "rrhh@example.com".to_string(),
            after: "2026-05-01".to_string(),
            before: "2026-05-31".to_string(),
        };

        assert_eq!(
            filters.query(),
            "has:attachment filename:pdf visa payslip from:rrhh@example.com after:2026/05/01 before:2026/05/31"
        );
    }

    #[test]
    fn base64_url_roundtrip_works() {
        let encoded = base64_url_encode(b"pdf-portal-prep");
        let decoded = base64_url_decode(&encoded).unwrap();
        assert_eq!(decoded, b"pdf-portal-prep");
    }

    #[test]
    fn unique_filename_adds_account_suffix_when_needed() {
        let dir = std::env::temp_dir().join(format!("gmail-file-{}", unix_now()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("document.pdf"), b"a").unwrap();

        let next = unique_filename(&dir, "document.pdf", "test.user@example.com").unwrap();

        assert!(next.starts_with("document-test-user-example-com"));
        fs::remove_dir_all(dir).ok();
    }
}