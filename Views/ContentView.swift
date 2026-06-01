import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var limitMB: Double = 5.0
    @State private var files: [PDFInputFile] = []
    @State private var isDragging: Bool = false
    @State private var actionType: ActionType = .mergeAndCompress
    @State private var selectedPreset: CompressionPreset = .balanced

    // Gmail import states
    @State private var gmailAccounts: [GmailConnectedAccount] = (try? GmailIntegrationService.shared.connectedAccounts()) ?? []
    @State private var selectedGmailAccountEmails: Set<String> = Set(((try? GmailIntegrationService.shared.connectedAccounts()) ?? []).map(\.email))
    @State private var gmailQuery: String = ""
    @State private var gmailFrom: String = ""
    @State private var gmailAfter: String = ""
    @State private var gmailBefore: String = ""
    @State private var gmailResults: [GmailAttachmentResult] = []
    @State private var selectedGmailAttachmentIDs: Set<String> = []
    @State private var isGmailWorking: Bool = false
    @State private var gmailStatusText: String? = nil
    
    // Process & Result States
    @State private var isProcessing: Bool = false
    @State private var progressText: String? = nil
    @State private var errorText: String? = nil
    @State private var result: CompressionResult? = nil
    @State private var showQualityWarning: Bool = false
    @State private var qualityWarningText: String? = nil
    @State private var activeProcessingService: PDFProcessingService? = nil

    enum ActionType: Hashable {
        case compressSingle
        case mergeAndCompress
    }

    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.fileSize }
    }
    
    var totalPages: Int {
        files.reduce(0) { $0 + $1.pageCount }
    }
    
    var hasEncryptedFiles: Bool {
        files.contains { $0.hasPassword }
    }
    
    var hasInteractiveFiles: Bool {
        files.contains { $0.hasInteractiveElements }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Main Control Panel
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "doc.zipper")
                        .font(.title)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("PDF Portal Prep")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Local & Secure Document Optimization")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, 8)
                
                // Limit config
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Límite objetivo:")
                            .fontWeight(.semibold)
                        Spacer()
                        TextField("", value: $limitMB, formatter: NumberFormatter())
                            .frame(width: 60)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .multilineTextAlignment(.trailing)
                        Text("MB")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $limitMB, in: 1.0...50.0, step: 0.5)
                        .accentColor(.blue)
                }
                
                Divider()
                
                // Input Drop Zone / Selector
                VStack(spacing: 12) {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 32))
                            .foregroundColor(isDragging ? .blue : .secondary)
                        
                        Text("Arrastra aquí tus documentos PDF")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Text("o")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Button("Seleccionar PDFs") {
                            selectFiles()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isDragging ? Color.blue : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(Color.secondary.opacity(0.02))
                    )
                    .onDrop(of: [UTType.pdf], isTargeted: $isDragging) { providers in
                        handleDroppedProviders(providers)
                        return true
                    }
                }

                GmailImportView(
                    accounts: gmailAccounts,
                    selectedAccountEmails: $selectedGmailAccountEmails,
                    query: $gmailQuery,
                    from: $gmailFrom,
                    after: $gmailAfter,
                    before: $gmailBefore,
                    results: gmailResults,
                    selectedIDs: $selectedGmailAttachmentIDs,
                    isWorking: isGmailWorking,
                    statusText: gmailStatusText,
                    onConnect: connectGmail,
                    onDisconnect: disconnectGmail,
                    onSearch: searchGmail,
                    onDownload: downloadSelectedGmailAttachments
                )
                .task {
                    await refreshGmailAccountsFromKeychain()
                }
                
                // Actions & Profiles
                VStack(alignment: .leading, spacing: 10) {
                    Text("Acción:")
                        .fontWeight(.semibold)
                    
                    Picker("", selection: $actionType) {
                        Text("Comprimir un PDF").tag(ActionType.compressSingle)
                        Text("Unir documentos y comprimir").tag(ActionType.mergeAndCompress)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Perfil:")
                        .fontWeight(.semibold)
                    
                    Picker("", selection: $selectedPreset) {
                        ForEach(CompressionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if selectedPreset.alwaysWarnsAboutQuality {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("La compresión máxima puede reducir la nitidez de texto escaneado e imágenes. Revisa el resultado antes de enviarlo.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                // Security Notifications
                if hasEncryptedFiles || hasInteractiveFiles {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasEncryptedFiles {
                            HStack {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(.orange)
                                Text("Advertencia: Hay archivos protegidos con contraseña.")
                                    .font(.caption)
                            }
                        }
                        if hasInteractiveFiles {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Aviso: El archivo contiene firmas digitales o elementos interactivos que podrían descalibrarse al comprimir.")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
                
                Spacer()

                if isProcessing, let progressText {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2.fill")
                            .foregroundColor(.secondary)
                        Text(progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Process Button
                Button(action: processPDFs) {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                        }
                        Text("Crear PDF menor de \(String(format: "%.1f", limitMB)) MB")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(files.isEmpty || isProcessing || (actionType == .compressSingle && files.count != 1))

                if isProcessing {
                    Button(action: cancelProcessing) {
                        Text("Cancelar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                if actionType == .compressSingle && files.count > 1 {
                    Text("Para comprimir un PDF, deja solo un documento en la lista.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .frame(width: 320)
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Document List & Results Panel
            VStack(alignment: .leading, spacing: 16) {
                Text("Documentos seleccionados:")
                    .font(.headline)
                
                if files.isEmpty {
                    VStack {
                        Spacer()
                        Text("No se han agregado archivos")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PDFFileListView(files: $files)
                    
                    HStack {
                        Text("Total: \(FileSizeFormatter.format(totalSize)) / \(totalPages) páginas")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                
                Divider()
                
                // Output/Results Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Resultado:")
                        .font(.headline)
                    
                    if let result = result {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(result.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.bold)
                            
                            if result.keptOriginal {
                                Text("\(result.pageCount) páginas - \(FileSizeFormatter.format(result.finalSize)) - sin reducción (se conservó el original)")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(result.pageCount) páginas - \(FileSizeFormatter.format(result.finalSize)) - Reducción \(String(format: "%.0f", result.reductionPercentage))%")
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 12) {
                                Text(result.qualityImpactLabel)
                                Text("·")
                                Text("Motor: \(result.engineLabel)")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("PDF válido")
                                }
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Todas las páginas conservadas (\(result.pageCount) de \(result.expectedPageCount))")
                                }
                                if result.meetsLimit {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Cumple límite de \(String(format: "%.1f", limitMB)) MB")
                                    }
                                } else {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                        Text("Supera límite de \(String(format: "%.1f", limitMB)) MB")
                                    }
                                }
                            }
                            .font(.subheadline)
                            
                            if showQualityWarning, let qualityWarningText {
                                Text(qualityWarningText)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(8)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            
                            HStack(spacing: 12) {
                                Button("Abrir resultado") {
                                    NSWorkspace.shared.open(result.outputURL)
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Mostrar en Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                                }
                                .buttonStyle(.bordered)

                                if let logURL = result.logURL {
                                    Button("Abrir registro") {
                                        NSWorkspace.shared.open(logURL)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                    } else if let errorText = errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundColor(.red)
                                Text("Error")
                                    .fontWeight(.bold)
                            }
                            Text(errorText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(8)
                    } else {
                        VStack {
                            Text("Los resultados de la compresión aparecerán aquí.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: 40)
                        .padding()
                        .background(Color.secondary.opacity(0.02))
                        .cornerRadius(8)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.underPageBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 520)
    }
    
    // --- File Handling Actions ---
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }
    
    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { item, error in
                if let url = item {
                    DispatchQueue.main.async {
                        self.addURLs([url])
                    }
                }
            }
        }
    }
    
    private func addURLs(_ urls: [URL]) {
        for url in urls {
            let fileManager = FileManager.default
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64 else {
                continue
            }
            
            let scan = PDFValidationService.scan(url: url)
            let inputFile = PDFInputFile(
                url: url,
                fileSize: size,
                pageCount: scan.pageCount,
                hasPassword: scan.isEncrypted,
                hasInteractiveElements: scan.hasInteractiveElements
            )
            
            if !files.contains(where: { $0.url == url }) {
                files.append(inputFile)
            }
        }
    }

    // --- Gmail Import Actions ---
    private func connectGmail() {
        isGmailWorking = true
        gmailStatusText = "Abriendo el navegador para autorizar con Google..."
        Task {
            do {
                let account = try await GmailIntegrationService.shared.connect()
                await MainActor.run {
                    reloadGmailAccounts(select: account.email, fallbackAccount: account)
                    gmailStatusText = "Gmail conectado: \(account.email)."
                    isGmailWorking = false
                }
            } catch {
                await MainActor.run {
                    gmailStatusText = error.localizedDescription
                    isGmailWorking = false
                }
            }
        }
    }

    private func disconnectGmail(_ accountEmail: String) {
        do {
            try GmailIntegrationService.shared.disconnect(accountEmail: accountEmail)
            reloadGmailAccounts()
            gmailResults = []
            selectedGmailAttachmentIDs = []
            gmailStatusText = "Gmail desconectado: \(accountEmail). Token eliminado de Keychain."
        } catch {
            gmailStatusText = error.localizedDescription
        }
    }

    private func searchGmail() {
        guard !gmailAccounts.isEmpty else {
            isGmailWorking = true
            gmailStatusText = "Sincronizando cuenta Gmail conectada..."
            Task {
                await refreshGmailAccountsFromKeychain()
                await MainActor.run {
                    isGmailWorking = false
                    if gmailAccounts.isEmpty {
                        gmailStatusText = "Conecta al menos una cuenta Gmail antes de buscar."
                    } else {
                        searchGmail()
                    }
                }
            }
            return
        }

        guard !selectedGmailAccountEmails.isEmpty else {
            gmailStatusText = "Selecciona al menos una cuenta Gmail para buscar."
            return
        }

        let filters = GmailSearchFilters(
            text: gmailQuery,
            from: gmailFrom,
            after: parseGmailDate(gmailAfter),
            before: parseGmailDate(gmailBefore)
        )

        isGmailWorking = true
        gmailStatusText = "Buscando: \(filters.query)"
        Task {
            do {
                let searchResult = try await GmailIntegrationService.shared.search(
                    filters: filters,
                    accountEmails: selectedGmailAccountEmails
                )
                await MainActor.run {
                    gmailResults = searchResult.attachments
                    selectedGmailAttachmentIDs = []
                    let limitNote = searchResult.reachedLimit ? " Se alcanzó el límite de 500 mensajes; ajusta la búsqueda para acotar más." : ""
                    gmailStatusText = searchResult.attachments.isEmpty
                        ? "Escaneados \(searchResult.scannedMessageCount) mensaje(s). Sin PDFs encontrados.\(limitNote)"
                        : "Escaneados \(searchResult.scannedMessageCount) mensaje(s). \(searchResult.attachments.count) PDF(s) encontrados.\(limitNote)"
                    isGmailWorking = false
                }
            } catch {
                await MainActor.run {
                    gmailStatusText = error.localizedDescription
                    isGmailWorking = false
                }
            }
        }
    }

    private func reloadGmailAccounts(select selectedEmail: String? = nil, fallbackAccount: GmailConnectedAccount? = nil) {
        var accounts = (try? GmailIntegrationService.shared.connectedAccounts()) ?? []
        if accounts.isEmpty, let fallbackAccount {
            accounts = [fallbackAccount]
        } else if let fallbackAccount, !accounts.contains(fallbackAccount) {
            accounts.append(fallbackAccount)
            accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        }

        gmailAccounts = accounts
        let availableEmails = Set(accounts.map(\.email))
        selectedGmailAccountEmails = selectedGmailAccountEmails.intersection(availableEmails)
        if let selectedEmail, availableEmails.contains(selectedEmail) {
            selectedGmailAccountEmails.insert(selectedEmail)
        }
        if selectedGmailAccountEmails.isEmpty {
            selectedGmailAccountEmails = availableEmails
        }
    }

    private func refreshGmailAccountsFromKeychain() async {
        do {
            let accounts = try await GmailIntegrationService.shared.refreshConnectedAccounts()
            await MainActor.run {
                gmailAccounts = accounts
                let availableEmails = Set(accounts.map(\.email))
                selectedGmailAccountEmails = selectedGmailAccountEmails.intersection(availableEmails)
                if selectedGmailAccountEmails.isEmpty {
                    selectedGmailAccountEmails = availableEmails
                }
            }
        } catch {
            await MainActor.run {
                gmailStatusText = error.localizedDescription
            }
        }
    }

    private func downloadSelectedGmailAttachments() {
        let selected = gmailResults.filter { selectedGmailAttachmentIDs.contains($0.id) }
        guard !selected.isEmpty else {
            gmailStatusText = "Selecciona al menos un PDF de Gmail."
            return
        }

        isGmailWorking = true
        gmailStatusText = "Descargando \(selected.count) PDF(s)..."
        Task {
            do {
                let urls = try await GmailIntegrationService.shared.download(selected)
                await MainActor.run {
                    addURLs(urls)
                    gmailStatusText = "\(urls.count) PDF(s) descargados y añadidos."
                    isGmailWorking = false
                }
            } catch {
                await MainActor.run {
                    gmailStatusText = error.localizedDescription
                    isGmailWorking = false
                }
            }
        }
    }

    private func parseGmailDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: trimmed)
    }
    
    // --- Central PDF Logic (Merge & Compressing Strategy) ---
    private func cancelProcessing() {
        activeProcessingService?.cancel()
        progressText = "Cancelando…"
    }

    private func processPDFs() {
        guard !files.isEmpty else { return }
        if actionType == .compressSingle && files.count != 1 {
            errorText = "La acción 'Comprimir un PDF' requiere exactamente un documento."
            return
        }

        isProcessing = true
        progressText = "Preparando…"
        errorText = nil
        result = nil
        showQualityWarning = false
        qualityWarningText = nil

        let targetLimitBytes = Int64(limitMB * 1024 * 1024)
        let fileURLs = files.map { $0.url }
        let selectedAction: PDFProcessingService.Action = (actionType == .mergeAndCompress) ? .mergeAndCompress : .compressSingle
        let selectedPreset = self.selectedPreset
        let expectedPages = totalPages
        let originalSizeTotal = totalSize
        let limitForMessages = limitMB

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let baseName = actionType == .mergeAndCompress
            ? "Visa_Documents_Combined.pdf"
            : files.first?.name ?? "Document.pdf"

        let service = PDFProcessingService()
        activeProcessingService = service

        DispatchQueue.global(qos: .userInitiated).async {
            let request = PDFProcessingService.Request(
                inputURLs: fileURLs,
                action: selectedAction,
                preset: selectedPreset,
                targetBytes: targetLimitBytes,
                outputDirectory: documentsDir,
                baseName: baseName,
                originalTotalSize: originalSizeTotal,
                expectedPageCount: expectedPages
            )

            do {
                let outcome = try service.process(request) { progress in
                    let text: String
                    switch progress {
                    case .merging:            text = "Uniendo documentos…"
                    case .tryingDPI(let dpi):  text = "Comprimiendo a \(dpi) dpi…"
                    case .finalizing:         text = "Validando resultado…"
                    }
                    DispatchQueue.main.async { self.progressText = text }
                }

                let qualityImpact = VisualQualityImpact.estimate(forAppliedDPI: outcome.appliedDPI)
                let levelLabel: String = {
                    if outcome.keptOriginal { return "Sin recompresión" }
                    if let dpi = outcome.appliedDPI { return "\(selectedPreset.shortLabel) (\(dpi) dpi)" }
                    return selectedPreset.shortLabel
                }()

                let logURL = try? ProcessingLogService.write(
                    outputURL: outcome.outputURL,
                    originalSize: outcome.originalTotalSize,
                    finalSize: outcome.finalSize,
                    pageCount: outcome.pageCount,
                    compressionLevel: levelLabel,
                    meetsLimit: outcome.meetsLimit
                )

                // Decide whether/what to warn about, honestly.
                var warningText: String? = nil
                if outcome.keptOriginal && !outcome.meetsLimit {
                    warningText = "No se pudo reducir el archivo por debajo de \(String(format: "%.1f", limitForMessages)) MB sin que quedara más grande que el original, así que se conservó el original. Considera el perfil Máximo o subir el límite."
                } else if outcome.hitFloorWithoutMeeting {
                    warningText = "Se alcanzó el límite de calidad del perfil \(selectedPreset.shortLabel) sin bajar de \(String(format: "%.1f", limitForMessages)) MB. Para reducir más, elige el perfil Máximo (con pérdida de calidad)."
                } else if selectedPreset.alwaysWarnsAboutQuality && !outcome.keptOriginal {
                    warningText = "Perfil Máximo: la nitidez de texto escaneado e imágenes puede haberse reducido. Revisa el PDF antes de enviarlo."
                }

                DispatchQueue.main.async {
                    self.result = CompressionResult(
                        outputURL: outcome.outputURL,
                        name: outcome.outputURL.lastPathComponent,
                        originalSize: outcome.originalTotalSize,
                        finalSize: outcome.finalSize,
                        pageCount: outcome.pageCount,
                        expectedPageCount: outcome.expectedPageCount,
                        reductionPercentage: outcome.reductionPercentage,
                        compressionLevel: levelLabel,
                        isValid: true,
                        meetsLimit: outcome.meetsLimit,
                        logURL: logURL,
                        appliedDPI: outcome.appliedDPI,
                        keptOriginal: outcome.keptOriginal,
                        engineLabel: outcome.engineLabel,
                        qualityImpactLabel: qualityImpact.label
                    )
                    self.qualityWarningText = warningText
                    self.showQualityWarning = warningText != nil
                    self.progressText = nil
                    self.isProcessing = false
                    self.activeProcessingService = nil
                }
            } catch is CompressionCancelled {
                DispatchQueue.main.async {
                    self.errorText = nil
                    self.result = nil
                    self.progressText = nil
                    self.isProcessing = false
                    self.activeProcessingService = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorText = error.localizedDescription
                    self.progressText = nil
                    self.isProcessing = false
                    self.activeProcessingService = nil
                }
            }
        }
    }
}

struct GmailImportView: View {
    let accounts: [GmailConnectedAccount]
    @Binding var selectedAccountEmails: Set<String>
    @Binding var query: String
    @Binding var from: String
    @Binding var after: String
    @Binding var before: String
    let results: [GmailAttachmentResult]
    @Binding var selectedIDs: Set<String>
    let isWorking: Bool
    let statusText: String?
    let onConnect: () -> Void
    let onDisconnect: (String) -> Void
    let onSearch: () -> Void
    let onDownload: () -> Void

    var isConnected: Bool {
        !accounts.isEmpty
    }

    var selectedCount: Int {
        selectedIDs.count
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onConnect) {
                    Label(isConnected ? "Conectar otra cuenta" : "Conectar con Google", systemImage: "bolt")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isWorking)

                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Buscar en:")
                            .font(.caption)
                            .fontWeight(.semibold)

                        ForEach(accounts) { account in
                            HStack(spacing: 8) {
                                Button {
                                    if selectedAccountEmails.contains(account.email) {
                                        selectedAccountEmails.remove(account.email)
                                    } else {
                                        selectedAccountEmails.insert(account.email)
                                    }
                                } label: {
                                    Image(systemName: selectedAccountEmails.contains(account.email) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(selectedAccountEmails.contains(account.email) ? .blue : .secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(isWorking)

                                Text(account.email)
                                    .font(.caption)
                                    .lineLimit(1)

                                Spacer()

                                Button {
                                    onDisconnect(account.email)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                                .disabled(isWorking)
                                .help("Desconectar \(account.email)")
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }

                HStack {
                    TextField("payslip, bank statement, visa", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button(action: onSearch) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                }

                HStack(spacing: 8) {
                    TextField("from", text: $from)
                        .textFieldStyle(.roundedBorder)
                    TextField("after yyyy-mm-dd", text: $after)
                        .textFieldStyle(.roundedBorder)
                    TextField("before yyyy-mm-dd", text: $before)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)

                if !results.isEmpty {
                    List(results) { result in
                        GmailAttachmentRow(
                            result: result,
                            isSelected: selectedIDs.contains(result.id),
                            onToggle: {
                                if selectedIDs.contains(result.id) {
                                    selectedIDs.remove(result.id)
                                } else {
                                    selectedIDs.insert(result.id)
                                }
                            }
                        )
                    }
                    .frame(minHeight: 110, maxHeight: 170)
                    .listStyle(.plain)

                    Button(action: onDownload) {
                        Label("Descargar seleccionados (\(selectedCount))", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isWorking || selectedIDs.isEmpty)
                }

                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(statusText.lowercased().contains("http") || statusText.lowercased().contains("google") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "envelope.badge")
                    .foregroundColor(isConnected ? .green : .blue)
                Text("Importar PDFs desde Gmail")
                    .fontWeight(.semibold)
                Spacer()
                if isConnected {
                    Text("\(accounts.count) cuenta\(accounts.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
        }
    }
}

struct GmailAttachmentRow: View {
    let result: GmailAttachmentResult
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.filename)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(result.subject)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                    Text("\(shortSender(result.from)) - \(FileSizeFormatter.format(result.size))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    private func shortSender(_ value: String) -> String {
        if let name = value.split(separator: "<").first {
            return String(name).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

// Helper Subview to Render list of files with reordering support
struct PDFFileListView: View {
    @Binding var files: [PDFInputFile]
    
    var body: some View {
        List {
            ForEach(files) { file in
                HStack {
                    Image(systemName: "doc.plaintext.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                        Text("\(file.pageCount) pág\(file.pageCount > 1 ? "s" : "") — \(FileSizeFormatter.format(file.fileSize))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    // Order modifiers
                    HStack(spacing: 8) {
                        Button(action: { moveUp(file) }) {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(files.first == file)
                        
                        Button(action: { moveDown(file) }) {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(files.last == file)
                        
                        Button(action: { remove(file) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(PlainListStyle())
        .background(Color.clear)
    }
    
    private func moveUp(_ file: PDFInputFile) {
        guard let index = files.firstIndex(of: file), index > 0 else { return }
        files.swapAt(index, index - 1)
    }
    
    private func moveDown(_ file: PDFInputFile) {
        guard let index = files.firstIndex(of: file), index < files.count - 1 else { return }
        files.swapAt(index, index + 1)
    }
    
    private func remove(_ file: PDFInputFile) {
        files.removeAll { $0.id == file.id }
    }
}

extension Picker {
    @ViewBuilder
    func horizontalRadioGroupLayout() -> some View {
        #if macOS
        self.pickerStyle(RadioGroupPickerStyle())
        #else
        self.pickerStyle(SegmentedPickerStyle())
        #endif
    }
}
