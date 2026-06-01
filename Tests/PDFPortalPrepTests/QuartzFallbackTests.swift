import XCTest
import PDFKit
@testable import PDFPortalPrep

/// Directly exercises the native Quartz fallback (the path used when Ghostscript
/// is absent). Runs regardless of whether `gs` is installed.
final class QuartzFallbackTests: XCTestCase {
    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("quartz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testQuartzFilterBuildsForEachPreset() {
        for preset in CompressionPreset.allCases {
            for dpi in preset.dpiLadder {
                XCTAssertNotNil(
                    PDFCompressionService.makeQuartzFilter(dpi: dpi, jpegQuality: preset.jpegQuality),
                    "Quartz filter should build for \(preset) @\(dpi)dpi"
                )
            }
        }
    }

    func testQuartzFallbackProducesValidSmallerPDF() throws {
        let input = workDir.appendingPathComponent("image.pdf")
        try PDFFixtures.makeImageHeavyPDF(at: input, pageCount: 2)
        let inputSize = PDFFixtures.fileSize(input)

        let output = workDir.appendingPathComponent("image-q.pdf")
        let service = PDFCompressionService()
        try service.compressWithQuartz(inputURL: input, outputURL: output, dpi: 110, jpegQuality: 0.6)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(PDFFixtures.fileSize(output), inputSize, "native fallback should shrink an image PDF")

        // Output must be a valid PDF with all pages intact.
        let scan = PDFValidationService.scan(url: output)
        XCTAssertTrue(scan.isValid)
        XCTAssertEqual(scan.pageCount, 2)
    }
}
