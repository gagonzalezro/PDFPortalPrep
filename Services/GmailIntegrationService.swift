import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct GmailOAuthConfiguration {
    let clientID: String
    let clientSecret: String
    let authURI = "https://accounts.google.com/o/oauth2/v2/auth"
    let tokenURI = "https://oauth2.googleapis.com/token"

    static func load() throws -> GmailOAuthConfiguration {
        if let bundleClientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
           let bundleClientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String,
           isUsableValue(bundleClientID),
           isUsableValue(bundleClientSecret) {
            return GmailOAuthConfiguration(
                clientID: bundleClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: bundleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if let resource = loadResourceConfiguration(),
           isUsableValue(resource.clientID),
           isUsableValue(resource.clientSecret) {
            return GmailOAuthConfiguration(
                clientID: resource.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: resource.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        throw NSError(
            domain: "GmailOAuthConfiguration",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Faltan GoogleOAuthClientID o GoogleOAuthClientSecret en Info.plist o Resources/GoogleOAuth.plist. Estos valores deben venir incluidos en el bundle de la app."
            ]
        )
    }

    private static func loadResourceConfiguration() -> (clientID: String, clientSecret: String)? {
        guard let url = Bundle.module.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        guard let clientID = plist["GoogleOAuthClientID"] as? String,
              let clientSecret = plist["GoogleOAuthClientSecret"] as? String else {
            return nil
        }

        return (clientID, clientSecret)
    }

    private static func isUsableValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("REPLACE_WITH_")
    }
}

struct GmailToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt
    }

    init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)

        if let storedExpiry = try container.decodeIfPresent(Date.self, forKey: .expiresAt) {
            expiresAt = storedExpiry
        } else {
            let expiresIn = try container.decodeIfPresent(Double.self, forKey: .expiresIn) ?? 3600
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encode(expiresAt, forKey: .expiresAt)
    }

    var needsRefresh: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}

struct GmailSearchFilters {
    let text: String
    let from: String
    let after: Date?
    let before: Date?

    var query: String {
        var parts = ["has:attachment", "filename:pdf"]
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("from:\(from.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        if let after {
            parts.append("after:\(formatter.string(from: after))")
        }
        if let before {
            parts.append("before:\(formatter.string(from: before))")
        }
        return parts.joined(separator: " ")
    }
}

struct GmailAttachmentResult: Identifiable, Equatable {
    let id: String
    let accountEmail: String
    let messageID: String
    let attachmentID: String
    let filename: String
    let size: Int64
    let subject: String
    let from: String
    let date: String
}

struct GmailSearchResult {
    let scannedMessageCount: Int
    let attachments: [GmailAttachmentResult]
    let reachedLimit: Bool
}

struct GmailConnectedAccount: Identifiable, Equatable {
    let email: String

    var id: String { email }
}

@MainActor
final class GmailIntegrationService {
    static let shared = GmailIntegrationService()

    private let scope = "https://www.googleapis.com/auth/gmail.readonly"
    private let keychainService = "PDFPortalPrep.GmailOAuth"
    private let legacyKeychainAccount = "default"
    private let connectedAccountsDefaultsKey = "PDFPortalPrep.GmailConnectedAccounts"
    private let gmailSearchPageSize = 100
    private let gmailSearchMessageLimit = 500
    private var activeOAuthServer: OAuthLoopbackServer?

    var isConnected: Bool {
        !storedAccountEmails().isEmpty || (try? loadToken(account: legacyKeychainAccount)) != nil
    }

    func connectedAccounts() throws -> [GmailConnectedAccount] {
        storedAccountEmails()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map(GmailConnectedAccount.init(email:))
    }

    func refreshConnectedAccounts() async throws -> [GmailConnectedAccount] {
        let currentAccounts = try connectedAccounts()
        guard currentAccounts.isEmpty,
              (try? loadToken(account: legacyKeychainAccount)) != nil else {
            return currentAccounts
        }

        let accessToken = try await validAccessToken(account: legacyKeychainAccount)
        let profile = try await fetchProfile(accessToken: accessToken)
        let normalizedEmail = normalizedAccountEmail(profile.emailAddress)
        let token = try loadToken(account: legacyKeychainAccount)
        try saveToken(token, account: normalizedEmail)
        try deleteToken(account: legacyKeychainAccount)
        return try connectedAccounts()
    }

    func connect() async throws -> GmailConnectedAccount {
        let configuration = try GmailOAuthConfiguration.load()
        let server = OAuthLoopbackServer()
        activeOAuthServer = server
        defer {
            activeOAuthServer = nil
        }

        let callback = try await server.start()
        let state = UUID().uuidString
        let pkce = try OAuthPKCE.make()

        var components = URLComponents(string: configuration.authURI)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: callback.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components?.url else {
            throw serviceError("No se pudo construir la URL de autorización de Google.")
        }

        NSWorkspace.shared.open(authURL)

        let response = try await server.waitForCallback()
        guard response.state == state else {
            throw serviceError("Google devolvió un estado OAuth inválido.")
        }

        let token = try await exchangeCode(
            response.code,
            redirectURI: callback,
            codeVerifier: pkce.verifier,
            configuration: configuration
        )
        let profile = try await fetchProfile(accessToken: token.accessToken)
        let account = GmailConnectedAccount(email: normalizedAccountEmail(profile.emailAddress))
        try saveToken(token, account: account.email)
        return account
    }

    func disconnect(accountEmail: String) throws {
        try deleteToken(account: accountEmail)
    }

    func search(filters: GmailSearchFilters, accountEmails: Set<String>) async throws -> GmailSearchResult {
        let selectedAccounts = accountEmails.isEmpty
            ? try connectedAccounts()
            : accountEmails
                .map { GmailConnectedAccount(email: normalizedAccountEmail($0)) }
                .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }

        guard !selectedAccounts.isEmpty else {
            throw serviceError("Selecciona al menos una cuenta Gmail conectada.")
        }

        var results: [GmailAttachmentResult] = []
        var scannedMessageCount = 0
        var reachedLimit = false

        for account in selectedAccounts {
            let accessToken = try await validAccessToken(account: account.email)
            let messageSearch = try await searchMessageIDs(query: filters.query, accessToken: accessToken)
            scannedMessageCount += messageSearch.ids.count
            reachedLimit = reachedLimit || messageSearch.reachedLimit

            for id in messageSearch.ids {
                let message = try await fetchMessage(id: id, accountEmail: account.email, accessToken: accessToken)
                results.append(contentsOf: message.pdfAttachments)
            }
        }

        return GmailSearchResult(
            scannedMessageCount: scannedMessageCount,
            attachments: results,
            reachedLimit: reachedLimit
        )
    }

    func download(_ attachments: [GmailAttachmentResult]) async throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFPortalPrep-Gmail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var urls: [URL] = []
        let grouped = Dictionary(grouping: attachments, by: \.accountEmail)
        for (accountEmail, accountAttachments) in grouped {
            let accessToken = try await validAccessToken(account: accountEmail)
            for attachment in accountAttachments {
                let data = try await fetchAttachmentData(attachment, accessToken: accessToken)
                let outputURL = directory.appendingPathComponent(uniqueFilename(
                    sanitizedFilename(attachment.filename),
                    accountEmail: accountEmail,
                    existing: Set(urls.map(\.lastPathComponent))
                ))
                try data.write(to: outputURL, options: .atomic)
                urls.append(outputURL)
            }
        }
        return urls
    }

    private func validAccessToken(account: String) async throws -> String {
        let token = try loadToken(account: account)
        guard token.needsRefresh else {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken else {
            throw serviceError("La sesión de \(account) expiró. Desconecta y vuelve a conectar esa cuenta.")
        }
        let configuration = try GmailOAuthConfiguration.load()

        let refreshed = try await refreshAccessToken(refreshToken, configuration: configuration)
        let merged = GmailToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresAt: refreshed.expiresAt
        )
        try saveToken(merged, account: account)
        return merged.accessToken
    }

    private func exchangeCode(
        _ code: String,
        redirectURI: URL,
        codeVerifier: String,
        configuration: GmailOAuthConfiguration
    ) async throws -> GmailToken {
        let body = [
            "code": code,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "redirect_uri": redirectURI.absoluteString,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        return try await tokenRequest(body: body, tokenURI: configuration.tokenURI)
    }

    private func refreshAccessToken(_ refreshToken: String, configuration: GmailOAuthConfiguration) async throws -> GmailToken {
        let body = [
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "grant_type": "refresh_token"
        ]
        return try await tokenRequest(body: body, tokenURI: configuration.tokenURI)
    }

    private func tokenRequest(body: [String: String], tokenURI: String) async throws -> GmailToken {
        guard let url = URL(string: tokenURI) else {
            throw serviceError("Token URI inválida.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(GmailToken.self, from: data)
    }

    private func fetchProfile(accessToken: String) async throws -> GmailProfile {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
            throw serviceError("No se pudo construir la lectura del perfil Gmail.")
        }

        let request = authorizedRequest(url: url, accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }

    private func searchMessageIDs(query: String, accessToken: String) async throws -> GmailMessageSearchResult {
        var allIDs: [String] = []
        var pageToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: "\(gmailSearchPageSize)")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
            components?.queryItems = queryItems
            guard let url = components?.url else {
                throw serviceError("No se pudo construir la búsqueda de Gmail.")
            }

            var request = authorizedRequest(url: url, accessToken: accessToken)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTP(response, data: data)
            let decoded = try JSONDecoder().decode(GmailListResponse.self, from: data)
            allIDs.append(contentsOf: decoded.messages?.map(\.id) ?? [])
            pageToken = decoded.nextPageToken
        } while pageToken != nil && allIDs.count < gmailSearchMessageLimit

        return GmailMessageSearchResult(
            ids: Array(allIDs.prefix(gmailSearchMessageLimit)),
            reachedLimit: pageToken != nil
        )
    }

    private func fetchMessage(id: String, accountEmail: String, accessToken: String) async throws -> GmailMessage {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "full")
        ]
        guard let url = components?.url else {
            throw serviceError("No se pudo construir la lectura del mensaje Gmail.")
        }

        let request = authorizedRequest(url: url, accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)
        var message = try JSONDecoder().decode(GmailMessage.self, from: data)
        message.accountEmail = accountEmail
        return message
    }

    private func fetchAttachmentData(_ attachment: GmailAttachmentResult, accessToken: String) async throws -> Data {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(attachment.messageID)/attachments/\(attachment.attachmentID)") else {
            throw serviceError("No se pudo construir la descarga del adjunto Gmail.")
        }

        let request = authorizedRequest(url: url, accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)
        let decoded = try JSONDecoder().decode(GmailAttachmentDownload.self, from: data)
        guard let fileData = Data(base64URLEncoded: decoded.data) else {
            throw serviceError("Google devolvió un adjunto con codificación inválida.")
        }
        return fileData
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw serviceError(friendlyGoogleAPIError(statusCode: http.statusCode, data: data))
        }
    }

    private func friendlyGoogleAPIError(statusCode: Int, data: Data) -> String {
        let fallbackBody = String(data: data, encoding: .utf8) ?? "Sin detalle"
        let apiError = try? JSONDecoder().decode(GoogleAPIErrorResponse.self, from: data)
        let message = apiError?.error.message ?? fallbackBody
        let reason = apiError?.error.errors?.first?.reason ?? apiError?.error.status ?? ""
        let combined = "\(message) \(reason)".lowercased()

        if statusCode == 403,
           combined.contains("gmail api"),
           (combined.contains("disabled") || combined.contains("not been used") || combined.contains("accessnotconfigured")) {
            return """
            Gmail API no está habilitada para este Google Cloud project.

            Abre Google Cloud Console y habilita Gmail API para el proyecto 303761801205:
            https://console.cloud.google.com/apis/library/gmail.googleapis.com?project=303761801205

            Después vuelve a la app, pulsa Desconectar y Conectar con Google otra vez.

            Detalle Google: \(message)
            """
        }

        if statusCode == 403,
           combined.contains("insufficient") || combined.contains("scope") {
            return """
            Google autorizó la cuenta, pero el token no tiene permiso suficiente para Gmail.

            Pulsa Desconectar y vuelve a Conectar con Google aceptando el permiso Gmail readonly.

            Detalle Google: \(message)
            """
        }

        if statusCode == 403,
           combined.contains("test") || combined.contains("access_denied") || combined.contains("not authorized") {
            return """
            La cuenta conectada no parece estar autorizada como test user en el OAuth consent screen.

            Añade esta cuenta Gmail como Test user en Google Cloud Console y vuelve a conectar.

            Detalle Google: \(message)
            """
        }

        return "Google API devolvió HTTP \(statusCode): \(message)"
    }

    private func saveToken(_ token: GmailToken, account: String) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw serviceError("No se pudo guardar el token OAuth en Keychain. Código \(status).")
        }
        addStoredAccountEmail(account)
    }

    private func loadToken(account: String) throws -> GmailToken {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw serviceError("Gmail no está conectado.")
        }
        return try JSONDecoder().decode(GmailToken.self, from: data)
    }

    private func deleteToken(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw serviceError("No se pudo eliminar el token OAuth de Keychain. Código \(status).")
        }
        removeStoredAccountEmail(account)
    }

    private func storedAccountEmails() -> Set<String> {
        let rawEmails = UserDefaults.standard.stringArray(forKey: connectedAccountsDefaultsKey) ?? []
        return Set(rawEmails.map(normalizedAccountEmail).filter { !$0.isEmpty })
    }

    private func addStoredAccountEmail(_ email: String) {
        let normalized = normalizedAccountEmail(email)
        guard !normalized.isEmpty, normalized != legacyKeychainAccount else { return }
        var emails = storedAccountEmails()
        emails.insert(normalized)
        saveStoredAccountEmails(emails)
    }

    private func removeStoredAccountEmail(_ email: String) {
        var emails = storedAccountEmails()
        emails.remove(normalizedAccountEmail(email))
        saveStoredAccountEmails(emails)
    }

    private func saveStoredAccountEmails(_ emails: Set<String>) {
        let sortedEmails = emails.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(sortedEmails, forKey: connectedAccountsDefaultsKey)
    }

    private func removeBrokenStoredAccountEmail(_ email: String, error: Error) throws {
        let nsError = error as NSError
        guard nsError.domain == "GmailIntegrationService",
              nsError.localizedDescription == "Gmail no está conectado." else {
            throw error
        }
        removeStoredAccountEmail(email)
        throw serviceError("La cuenta \(email) ya no tiene token guardado. Conéctala otra vez.")
    }

    private func formURLEncoded(_ body: [String: String]) -> String {
        body.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        .joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let fallback = filename.isEmpty ? "gmail-attachment.pdf" : filename
        let invalid = CharacterSet(charactersIn: "/\\:")
        return fallback.components(separatedBy: invalid).joined(separator: "-")
    }

    private func uniqueFilename(_ filename: String, accountEmail: String, existing: Set<String>) -> String {
        guard existing.contains(filename) else { return filename }
        let url = URL(fileURLWithPath: filename)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let accountPrefix = accountEmail
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let candidate = ext.isEmpty ? "\(base)-\(accountPrefix)" : "\(base)-\(accountPrefix).\(ext)"
        return existing.contains(candidate) ? "\(UUID().uuidString)-\(candidate)" : candidate
    }

    private func normalizedAccountEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "GmailIntegrationService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class OAuthLoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "PDFPortalPrep.OAuthLoopbackServer")
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var pendingResult: Result<OAuthCallback, Error>?
    private var didComplete = false

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.resumeStart(with: listener.port)
                case .failed(let error):
                    self.resumeStart(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: self.queue)
        }
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingResult {
                switch pendingResult {
                case .success(let callback):
                    continuation.resume(returning: callback)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
                return
            }
            self.continuation = continuation
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.resume(throwing: error)
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.resume(throwing: NSError(domain: "OAuthLoopbackServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Respuesta OAuth local inválida."]))
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                self.resume(throwing: NSError(domain: "OAuthLoopbackServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Callback OAuth inválido."]))
                return
            }

            let items = components.queryItems ?? []
            if let errorValue = items.first(where: { $0.name == "error" })?.value {
                self.sendHTTPResponse(connection, title: "PDF Portal Prep", body: "Google OAuth error: \(errorValue)")
                self.resume(throwing: NSError(domain: "OAuthLoopbackServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Google OAuth error: \(errorValue)"]))
                return
            }

            guard let code = items.first(where: { $0.name == "code" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value else {
                self.resume(throwing: NSError(domain: "OAuthLoopbackServer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Google no devolvió código OAuth."]))
                return
            }

            self.sendHTTPResponse(connection, title: "PDF Portal Prep", body: "Gmail conectado. Ya puedes volver a la app.")
            self.resume(returning: OAuthCallback(code: code, state: state))
        }
    }

    private func sendHTTPResponse(_ connection: NWConnection, title: String, body: String) {
        let html = """
        <html><head><title>\(title)</title></head><body><h3>\(body)</h3></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resume(returning callback: OAuthCallback) {
        complete(.success(callback))
        listener?.cancel()
    }

    private func resume(throwing error: Error) {
        complete(.failure(error))
        listener?.cancel()
    }

    private func complete(_ result: Result<OAuthCallback, Error>) {
        guard !didComplete else { return }
        didComplete = true

        if let continuation {
            switch result {
            case .success(let callback):
                continuation.resume(returning: callback)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        } else {
            pendingResult = result
        }
    }

    private func resumeStart(with port: NWEndpoint.Port?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil

        guard let port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback") else {
            continuation.resume(throwing: NSError(domain: "OAuthLoopbackServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo obtener el puerto OAuth local."]))
            return
        }

        continuation.resume(returning: url)
    }

    private func resumeStart(throwing error: Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(throwing: error)
    }
}

private struct OAuthCallback {
    let code: String
    let state: String
}

private struct OAuthPKCE {
    let verifier: String
    let challenge: String

    static func make() throws -> OAuthPKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "OAuthPKCE",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "No se pudo crear un challenge OAuth seguro."]
            )
        }

        let verifier = Data(bytes).base64URLEncodedString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return OAuthPKCE(verifier: verifier, challenge: challenge)
    }
}

private struct GmailListResponse: Codable {
    let messages: [GmailMessageID]?
    let nextPageToken: String?
}

private struct GmailMessageID: Codable {
    let id: String
}

private struct GmailMessageSearchResult {
    let ids: [String]
    let reachedLimit: Bool
}

private struct GmailAttachmentDownload: Codable {
    let data: String
}

private struct GmailProfile: Codable {
    let emailAddress: String
}

private struct GoogleAPIErrorResponse: Codable {
    let error: GoogleAPIError
}

private struct GoogleAPIError: Codable {
    let code: Int?
    let message: String?
    let status: String?
    let errors: [GoogleAPIErrorDetail]?
}

private struct GoogleAPIErrorDetail: Codable {
    let message: String?
    let domain: String?
    let reason: String?
}

private struct GmailMessage: Codable {
    let id: String
    let payload: GmailPayload?
    var accountEmail = ""

    enum CodingKeys: String, CodingKey {
        case id
        case payload
    }

    var pdfAttachments: [GmailAttachmentResult] {
        let headers = payload?.headers ?? []
        let subject = headers.value(named: "Subject") ?? "(sin asunto)"
        let from = headers.value(named: "From") ?? "(sin remitente)"
        let date = headers.value(named: "Date") ?? ""
        return (payload?.flattenedParts ?? []).compactMap { part in
            guard let filename = part.filename,
                  filename.lowercased().hasSuffix(".pdf"),
                  let attachmentID = part.body?.attachmentID else {
                return nil
            }
            return GmailAttachmentResult(
                id: "\(accountEmail)-\(id)-\(attachmentID)-\(filename)",
                accountEmail: accountEmail,
                messageID: id,
                attachmentID: attachmentID,
                filename: filename,
                size: Int64(part.body?.size ?? 0),
                subject: subject,
                from: from,
                date: date
            )
        }
    }
}

private struct GmailPayload: Codable {
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?

    var flattenedParts: [GmailPayload] {
        var all = [self]
        for part in parts ?? [] {
            all.append(contentsOf: part.flattenedParts)
        }
        return all
    }
}

private struct GmailHeader: Codable {
    let name: String
    let value: String
}

private extension Array where Element == GmailHeader {
    func value(named target: String) -> String? {
        first { $0.name.caseInsensitiveCompare(target) == .orderedSame }?.value
    }
}

private struct GmailBody: Codable {
    let attachmentID: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case size
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        self.init(base64Encoded: base64)
    }
}
