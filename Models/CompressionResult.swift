import Foundation

struct CompressionResult: Equatable {
    let outputURL: URL
    let name: String
    let originalSize: Int64
    let finalSize: Int64
    let pageCount: Int
    let expectedPageCount: Int
    let reductionPercentage: Double
    let compressionLevel: String
    let isValid: Bool
    let meetsLimit: Bool
    let logURL: URL?
    /// DPI applied to images, or `nil` when the original was kept unchanged.
    let appliedDPI: Int?
    /// True when no recompression helped (already small, or output not smaller).
    let keptOriginal: Bool
    /// Engine that produced the output ("Ghostscript" or "Motor nativo (Quartz)").
    let engineLabel: String
    /// Estimated visual-quality impact label shown to the user.
    let qualityImpactLabel: String
}
