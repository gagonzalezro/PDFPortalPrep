import XCTest
@testable import PDFPortalPrep

final class CompressionPresetTests: XCTestCase {
    func testLaddersAreDescendingAndEndAtFloor() {
        for preset in CompressionPreset.allCases {
            let ladder = preset.dpiLadder
            XCTAssertFalse(ladder.isEmpty, "\(preset) has an empty ladder")
            XCTAssertEqual(ladder.last, preset.floorDPI, "\(preset) floor must equal last rung")
            for i in 1..<ladder.count {
                XCTAssertLessThan(ladder[i], ladder[i - 1], "\(preset) ladder must strictly descend")
            }
        }
    }

    func testFloorsKeepLightAndBalancedReadable() {
        // Light/Balanced must never auto-degrade below a readable floor.
        XCTAssertGreaterThanOrEqual(CompressionPreset.light.floorDPI, 150)
        XCTAssertGreaterThanOrEqual(CompressionPreset.balanced.floorDPI, 110)
    }

    func testOnlyMaximumWarnsByDefault() {
        XCTAssertFalse(CompressionPreset.light.alwaysWarnsAboutQuality)
        XCTAssertFalse(CompressionPreset.balanced.alwaysWarnsAboutQuality)
        XCTAssertTrue(CompressionPreset.maximum.alwaysWarnsAboutQuality)
    }

    func testJPEGQualityOrdering() {
        XCTAssertGreaterThan(CompressionPreset.light.jpegQuality, CompressionPreset.balanced.jpegQuality)
        XCTAssertGreaterThan(CompressionPreset.balanced.jpegQuality, CompressionPreset.maximum.jpegQuality)
    }

    func testVisualQualityImpactBuckets() {
        XCTAssertEqual(VisualQualityImpact.estimate(forAppliedDPI: nil), .none)
        XCTAssertEqual(VisualQualityImpact.estimate(forAppliedDPI: 200), .low)
        XCTAssertEqual(VisualQualityImpact.estimate(forAppliedDPI: 150), .low)
        XCTAssertEqual(VisualQualityImpact.estimate(forAppliedDPI: 120), .medium)
        XCTAssertEqual(VisualQualityImpact.estimate(forAppliedDPI: 96), .high)
    }
}
