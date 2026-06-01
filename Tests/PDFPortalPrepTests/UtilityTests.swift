import XCTest
@testable import PDFPortalPrep

final class UtilityTests: XCTestCase {
    func testGenerateNameStripsExtensionAndAppendsSuffix() {
        XCTAssertEqual(OutputFileNaming.generateName(base: "Doc.pdf", suffix: "_Compressed"), "Doc_Compressed.pdf")
        XCTAssertEqual(OutputFileNaming.generateName(base: "Doc", suffix: "_X"), "Doc_X.pdf")
    }

    func testUniqueURLAvoidsCollisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = OutputFileNaming.uniqueURL(in: dir, base: "Doc.pdf", suffix: "_Compressed")
        XCTAssertEqual(first.lastPathComponent, "Doc_Compressed.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))

        let second = OutputFileNaming.uniqueURL(in: dir, base: "Doc.pdf", suffix: "_Compressed")
        XCTAssertEqual(second.lastPathComponent, "Doc_Compressed-2.pdf")
    }

    func testFileSizeFormatterProducesReadableUnits() {
        XCTAssertFalse(FileSizeFormatter.format(0).isEmpty)
        XCTAssertTrue(FileSizeFormatter.format(5 * 1024 * 1024).contains("MB"))
    }
}
