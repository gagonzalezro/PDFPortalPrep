import Foundation

/// Orchestrates the full pipeline: (optional) merge → measure → iterative,
/// floor-bounded compression → safety guards → validation.
///
/// This logic used to live inline in `ContentView.processPDFs`, where it could
/// not be unit-tested and silently violated two of the product rules (no
/// output>input guard, and unbounded DPI escalation that could degrade scanned
/// documents). It now lives here as a testable unit.
///
/// `@unchecked Sendable`: its only stored property is an immutable reference to a
/// thread-safe `PDFCompressionService`, so instances are safe to hand to a
/// background queue while `cancel()` is invoked from the main thread.
final class PDFProcessingService: @unchecked Sendable {
    enum Action {
        case compressSingle
        case mergeAndCompress
    }

    struct Request {
        let inputURLs: [URL]
        let action: Action
        let preset: CompressionPreset
        let targetBytes: Int64
        let outputDirectory: URL
        let baseName: String
        /// Sum of the original input file sizes, used for the reduction figure
        /// shown to the user.
        let originalTotalSize: Int64
        /// Total page count expected in the output; a mismatch aborts safely.
        let expectedPageCount: Int
    }

    /// Progress milestones reported to the UI.
    enum Progress {
        case merging
        case tryingDPI(Int)
        case finalizing
    }

    struct Outcome {
        let outputURL: URL
        let finalSize: Int64
        let originalTotalSize: Int64
        let pageCount: Int
        let expectedPageCount: Int
        let reductionPercentage: Double
        /// DPI actually applied, or `nil` when the original was kept unchanged.
        let appliedDPI: Int?
        /// True when no recompression was used (already under target, or the
        /// compressed candidate was not smaller than the input).
        let keptOriginal: Bool
        /// True when escalation reached the preset floor but still missed the target.
        let hitFloorWithoutMeeting: Bool
        let meetsLimit: Bool
        let engineLabel: String
    }

    let compressionService: PDFCompressionService

    init(compressionService: PDFCompressionService = PDFCompressionService()) {
        self.compressionService = compressionService
    }

    func cancel() {
        compressionService.cancel()
    }

    private func checkCancelled() throws {
        if compressionService.isCancelled { throw CompressionCancelled() }
    }

    /// Runs the pipeline. The caller is responsible for running this off the main
    /// thread. `progress` is invoked on the calling thread.
    func process(_ request: Request, progress: (Progress) -> Void) throws -> Outcome {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let combinedURL = tempDir.appendingPathComponent("pdfportalprep-\(UUID().uuidString)-combined.pdf")
        defer { try? fm.removeItem(at: combinedURL) }

        // Step 1: merge or copy the single file.
        progress(.merging)
        try checkCancelled()
        switch request.action {
        case .mergeAndCompress:
            try PDFMergeService.merge(files: request.inputURLs, to: combinedURL)
        case .compressSingle:
            guard let first = request.inputURLs.first else {
                throw NSError(domain: "PDFProcessingService", code: 400,
                              userInfo: [NSLocalizedDescriptionKey: "No se proporcionaron archivos."])
            }
            if fm.fileExists(atPath: combinedURL.path) {
                try fm.removeItem(at: combinedURL)
            }
            try fm.copyItem(at: first, to: combinedURL)
        }

        // Step 2: measure the combined input — this is the baseline the
        // output>input guard compares against.
        let combinedSize = (try fm.attributesOfItem(atPath: combinedURL.path)[.size] as? Int64) ?? 0

        let outputURL = OutputFileNaming.uniqueURL(in: request.outputDirectory, base: request.baseName, suffix: "_Compressed")

        var appliedDPI: Int? = nil
        var keptOriginal = false
        var hitFloorWithoutMeeting = false
        var finalSize = combinedSize

        if combinedSize <= request.targetBytes {
            // Already under the target: never recompress an acceptable file.
            try fm.copyItem(at: combinedURL, to: outputURL)
            keptOriginal = true
        } else {
            let ladder = request.preset.dpiLadder
            var bestStepURL: URL?
            var bestStepSize: Int64 = .max

            for (index, dpi) in ladder.enumerated() {
                try checkCancelled()
                progress(.tryingDPI(dpi))

                let stepURL = tempDir.appendingPathComponent("pdfportalprep-step-\(UUID().uuidString).pdf")
                try? fm.removeItem(at: stepURL)

                try compressionService.compress(
                    inputURL: combinedURL,
                    outputURL: stepURL,
                    dpi: dpi,
                    jpegQuality: request.preset.jpegQuality
                )

                let stepSize = (try? fm.attributesOfItem(atPath: stepURL.path)[.size] as? Int64) ?? .max

                if stepSize <= request.targetBytes {
                    bestStepURL.map { try? fm.removeItem(at: $0) }
                    bestStepURL = stepURL
                    bestStepSize = stepSize
                    appliedDPI = dpi
                    break
                } else if index == ladder.count - 1 {
                    // Reached the preset floor without hitting the target. Keep
                    // this (smallest readable-for-the-preset) version and flag it,
                    // rather than silently degrading further.
                    bestStepURL.map { try? fm.removeItem(at: $0) }
                    bestStepURL = stepURL
                    bestStepSize = stepSize
                    appliedDPI = dpi
                    hitFloorWithoutMeeting = true
                } else {
                    // Keep this as current best (it is smaller than the input even
                    // if not under target), but try the next rung.
                    if stepSize < bestStepSize {
                        bestStepURL.map { try? fm.removeItem(at: $0) }
                        bestStepURL = stepURL
                        bestStepSize = stepSize
                        appliedDPI = dpi
                    } else {
                        try? fm.removeItem(at: stepURL)
                    }
                }
            }

            guard let chosen = bestStepURL else {
                throw NSError(domain: "PDFProcessingService", code: 500,
                              userInfo: [NSLocalizedDescriptionKey: "No se pudo generar una versión comprimida."])
            }

            progress(.finalizing)

            // Safety guard: never deliver a file larger than (or equal to) what we
            // fed in. If compression didn't actually help, keep the original.
            if bestStepSize >= combinedSize {
                try? fm.removeItem(at: chosen)
                try fm.copyItem(at: combinedURL, to: outputURL)
                keptOriginal = true
                appliedDPI = nil
                hitFloorWithoutMeeting = false
                finalSize = combinedSize
            } else {
                try fm.copyItem(at: chosen, to: outputURL)
                try? fm.removeItem(at: chosen)
                finalSize = bestStepSize
            }
        }

        // Step 3: validate the result and verify no pages were lost.
        let scan = PDFValidationService.scan(url: outputURL)
        guard scan.isValid else {
            try? fm.removeItem(at: outputURL)
            throw NSError(domain: "PDFProcessingService", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "El documento resultante está dañado."])
        }
        guard scan.pageCount == request.expectedPageCount else {
            try? fm.removeItem(at: outputURL)
            throw NSError(domain: "PDFProcessingService", code: 501,
                          userInfo: [NSLocalizedDescriptionKey: "El PDF resultante tiene \(scan.pageCount) páginas, pero se esperaban \(request.expectedPageCount). No se reemplazó ningún original."])
        }

        let meetsLimit = finalSize <= request.targetBytes
        // Honesty: only report a positive reduction when one actually occurred.
        let rawReduction = request.originalTotalSize > 0
            ? (Double(request.originalTotalSize - finalSize) / Double(request.originalTotalSize)) * 100.0
            : 0.0
        let reduction = keptOriginal ? max(0.0, rawReduction) : rawReduction

        return Outcome(
            outputURL: outputURL,
            finalSize: finalSize,
            originalTotalSize: request.originalTotalSize,
            pageCount: scan.pageCount,
            expectedPageCount: request.expectedPageCount,
            reductionPercentage: reduction,
            appliedDPI: appliedDPI,
            keptOriginal: keptOriginal,
            hitFloorWithoutMeeting: hitFloorWithoutMeeting,
            meetsLimit: meetsLimit,
            engineLabel: PDFCompressionService.engineDescription()
        )
    }
}
