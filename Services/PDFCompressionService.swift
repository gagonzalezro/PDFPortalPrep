import Foundation
import Quartz

/// Thrown when the user cancels an in-flight compression.
struct CompressionCancelled: Error {}

/// Compresses a single PDF at a specific DPI.
///
/// Primary engine is Ghostscript (`gs`) when available. When `gs` is not
/// installed, it transparently falls back to a native Quartz filter (the same
/// mechanism macOS Preview's "Reduce File Size" uses), so compression still
/// works on a stock machine — at degraded, Preview-equivalent quality.
///
/// The instance owns the running `Process` so a long job can be cancelled via
/// `cancel()`.
///
/// `@unchecked Sendable`: all mutable state (`cancelled`, `currentProcess`) is
/// guarded by `lock`, and `cancel()` is designed to be called from a different
/// thread than the one running the compression.
final class PDFCompressionService: @unchecked Sendable {
    enum Engine: Equatable {
        case ghostscript(String)
        case quartz
    }

    private let lock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Requests cancellation. Terminates any running Ghostscript process and
    /// causes subsequent / in-flight steps to throw `CompressionCancelled`.
    func cancel() {
        lock.lock()
        cancelled = true
        currentProcess?.terminate()
        lock.unlock()
    }

    /// Which engine will be used right now, based on whether `gs` is installed.
    static func availableEngine() -> Engine {
        if let gsPath = GhostscriptLocator.locate() {
            return .ghostscript(gsPath)
        }
        return .quartz
    }

    /// Human-readable engine name for the UI.
    static func engineDescription() -> String {
        switch availableEngine() {
        case .ghostscript: return "Ghostscript"
        case .quartz:      return "Motor nativo (Quartz)"
        }
    }

    /// Compresses `inputURL` into `outputURL` targeting `dpi` for raster images,
    /// using JPEG quality `jpegQuality` (0...1). Throws on failure or cancellation.
    func compress(inputURL: URL, outputURL: URL, dpi: Int, jpegQuality: Double) throws {
        if isCancelled { throw CompressionCancelled() }
        switch Self.availableEngine() {
        case .ghostscript(let gsPath):
            try compressWithGhostscript(gsPath: gsPath, inputURL: inputURL, outputURL: outputURL, dpi: dpi, jpegQuality: jpegQuality)
        case .quartz:
            try compressWithQuartz(inputURL: inputURL, outputURL: outputURL, dpi: dpi, jpegQuality: jpegQuality)
        }
    }

    // MARK: - Ghostscript

    private func compressWithGhostscript(gsPath: String, inputURL: URL, outputURL: URL, dpi: Int, jpegQuality: Double) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gsPath)

        // JPEGQ is an integer 1...100.
        let jpegQ = max(1, min(100, Int((jpegQuality * 100).rounded())))
        process.arguments = [
            "-dNOPAUSE",
            "-dBATCH",
            "-dQUIET",
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            // Explicit JPEG for color/gray so -dJPEGQ takes effect; CCITT for mono.
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dColorImageResolution=\(dpi)",
            "-dGrayImageFilter=/DCTEncode",
            "-dGrayImageResolution=\(dpi)",
            "-dMonoImageFilter=/CCITTFaxEncode",
            "-dMonoImageResolution=\(dpi)",
            "-dDownsampleColorImages=true",
            "-dDownsampleGrayImages=true",
            "-dDownsampleMonoImages=true",
            "-dJPEGQ=\(jpegQ)",
            // Help text-heavy PDFs too: subset and compress embedded fonts.
            "-dSubsetFonts=true",
            "-dCompressFonts=true",
            "-sOutputFile=\(outputURL.path)",
            inputURL.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        lock.lock()
        if cancelled {
            lock.unlock()
            throw CompressionCancelled()
        }
        currentProcess = process
        lock.unlock()

        try process.run()
        process.waitUntilExit()

        lock.lock()
        currentProcess = nil
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled { throw CompressionCancelled() }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown Ghostscript error"
            throw NSError(
                domain: "PDFCompressionService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Ghostscript execution failed: \(errorMessage)"]
            )
        }
    }

    // MARK: - Native Quartz fallback

    /// Re-renders the document through a Quartz image-compression filter built to
    /// match the requested DPI and JPEG quality. Preserves vector text/pages;
    /// downsamples and JPEG-recompresses raster images. Used only when `gs` is
    /// unavailable. Exposed (internal) so tests can exercise the fallback even on
    /// machines where `gs` is installed.
    func compressWithQuartz(inputURL: URL, outputURL: URL, dpi: Int, jpegQuality: Double) throws {
        guard let document = CGPDFDocument(inputURL as CFURL) else {
            throw NSError(
                domain: "PDFCompressionService",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo abrir el PDF con el motor nativo (¿archivo dañado o cifrado?)."]
            )
        }

        guard let filter = Self.makeQuartzFilter(dpi: dpi, jpegQuality: jpegQuality) else {
            throw NSError(
                domain: "PDFCompressionService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo construir el filtro de compresión nativo."]
            )
        }

        guard let context = CGContext(outputURL as CFURL, mediaBox: nil, nil) else {
            throw NSError(
                domain: "PDFCompressionService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo crear el contexto PDF de salida."]
            )
        }

        filter.apply(to: context)

        let pageCount = document.numberOfPages
        for pageNumber in 1...max(pageCount, 1) {
            if isCancelled {
                context.closePDF()
                throw CompressionCancelled()
            }
            guard pageCount > 0, let page = document.page(at: pageNumber) else { continue }
            var mediaBox = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &mediaBox)
            context.drawPDFPage(page)
            context.endPage()
        }
        context.closePDF()
    }

    /// Builds a Quartz filter (`QuartzFilter`) that JPEG-recompresses and
    /// downsamples images to `dpi`. The property schema mirrors the system
    /// "Reduce File Size.qfilter".
    static func makeQuartzFilter(dpi: Int, jpegQuality: Double) -> QuartzFilter? {
        let quality = max(0.0, min(1.0, jpegQuality))
        let properties: [String: Any] = [
            "Name": "PDFPortalPrep \(dpi)dpi",
            "FilterType": 1,
            "Domains": ["Applications": 1, "Printing": 1],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "ImageCompression": "ImageJPEGCompress",
                        "Compression Quality": quality,
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleInterpolate": 1,
                            "ImageSizeMax": dpi * 12,
                            "ImageSizeMin": 0
                        ]
                    ]
                ]
            ]
        ]
        return QuartzFilter(properties: properties)
    }
}
