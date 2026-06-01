import XCTest
@testable import PDFPortalPrep

/// End-to-end tests for the compression pipeline. Per project decision these
/// HARD-REQUIRE Ghostscript: the suite fails (rather than skips) if `gs` is
/// missing, so a misconfigured environment is loud, not silent.
final class PDFProcessingServiceTests: XCTestCase {
    var workDir: URL!

    override func setUpWithError() throws {
        guard GhostscriptLocator.locate() != nil else {
            XCTFail("Ghostscript ('gs') is required for compression tests but was not found. Install with 'brew install ghostscript'.")
            return
        }
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfproc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeRequest(
        input: URL,
        action: PDFProcessingService.Action,
        preset: CompressionPreset,
        targetBytes: Int64,
        expectedPages: Int,
        inputs: [URL]? = nil
    ) -> PDFProcessingService.Request {
        let urls = inputs ?? [input]
        let originalTotal = urls.reduce(Int64(0)) { $0 + PDFFixtures.fileSize($1) }
        return PDFProcessingService.Request(
            inputURLs: urls,
            action: action,
            preset: preset,
            targetBytes: targetBytes,
            outputDirectory: workDir,
            baseName: input.lastPathComponent,
            originalTotalSize: originalTotal,
            expectedPageCount: expectedPages
        )
    }

    func testImageHeavyPDFIsReducedAndPagesPreserved() throws {
        let input = workDir.appendingPathComponent("image.pdf")
        try PDFFixtures.makeImageHeavyPDF(at: input, pageCount: 1)
        let inputSize = PDFFixtures.fileSize(input)
        XCTAssertGreaterThan(inputSize, 1_000_000, "fixture should be a large image PDF")

        let service = PDFProcessingService()
        let outcome = try service.process(
            makeRequest(input: input, action: .compressSingle, preset: .balanced,
                        targetBytes: 500 * 1024, expectedPages: 1)
        ) { _ in }

        XCTAssertEqual(outcome.pageCount, 1)
        XCTAssertFalse(outcome.keptOriginal, "an image-heavy PDF should actually compress")
        XCTAssertLessThan(outcome.finalSize, inputSize)
        XCTAssertGreaterThan(outcome.reductionPercentage, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.outputURL.path))
        // The applied DPI must come from the selected preset's ladder.
        XCTAssertTrue(CompressionPreset.balanced.dpiLadder.contains(outcome.appliedDPI ?? -1))
    }

    func testAlreadyUnderTargetKeepsOriginalWithoutRecompression() throws {
        let input = workDir.appendingPathComponent("text.pdf")
        try PDFFixtures.makeTextPDF(at: input, pageCount: 1)
        let inputSize = PDFFixtures.fileSize(input)

        let service = PDFProcessingService()
        let outcome = try service.process(
            makeRequest(input: input, action: .compressSingle, preset: .light,
                        targetBytes: 50 * 1024 * 1024, expectedPages: 1)
        ) { _ in }

        XCTAssertTrue(outcome.keptOriginal)
        XCTAssertNil(outcome.appliedDPI)
        XCTAssertEqual(outcome.finalSize, inputSize)
        XCTAssertTrue(outcome.meetsLimit)
    }

    func testOutputIsNeverLargerThanInput() throws {
        // An impossible target forces full escalation; the guard must still ensure
        // we never deliver a file larger than the input.
        let input = workDir.appendingPathComponent("text.pdf")
        try PDFFixtures.makeTextPDF(at: input, pageCount: 1)
        let inputSize = PDFFixtures.fileSize(input)

        let service = PDFProcessingService()
        let outcome = try service.process(
            makeRequest(input: input, action: .compressSingle, preset: .maximum,
                        targetBytes: 1, expectedPages: 1)
        ) { _ in }

        XCTAssertLessThanOrEqual(outcome.finalSize, inputSize, "must never ship a file bigger than the input")
        XCTAssertEqual(outcome.pageCount, 1)
        if outcome.keptOriginal {
            XCTAssertEqual(outcome.finalSize, inputSize)
        }
    }

    func testMergePreservesTotalPageCount() throws {
        let a = workDir.appendingPathComponent("a.pdf")
        let b = workDir.appendingPathComponent("b.pdf")
        try PDFFixtures.makeTextPDF(at: a, pageCount: 1)
        try PDFFixtures.makeTextPDF(at: b, pageCount: 2)

        let service = PDFProcessingService()
        let outcome = try service.process(
            makeRequest(input: a, action: .mergeAndCompress, preset: .balanced,
                        targetBytes: 50 * 1024 * 1024, expectedPages: 3, inputs: [a, b])
        ) { _ in }

        XCTAssertEqual(outcome.pageCount, 3)
    }

    func testCancellationBeforeProcessingThrows() throws {
        let input = workDir.appendingPathComponent("image.pdf")
        try PDFFixtures.makeImageHeavyPDF(at: input, pageCount: 1)

        let service = PDFProcessingService()
        service.cancel()

        XCTAssertThrowsError(
            try service.process(
                makeRequest(input: input, action: .compressSingle, preset: .balanced,
                            targetBytes: 1, expectedPages: 1)
            ) { _ in }
        ) { error in
            XCTAssertTrue(error is CompressionCancelled)
        }
    }
}
