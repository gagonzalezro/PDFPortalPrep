import Foundation
import CoreGraphics

/// Generates representative PDF fixtures programmatically so the repo carries no
/// binary blobs and tests stay deterministic.
enum PDFFixtures {
    static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter @72pt

    static func makePDF(at url: URL, pageCount: Int, draw: (CGContext, Int) -> Void) throws {
        var mediaBox = pageRect
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFFixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context."])
        }
        for page in 0..<pageCount {
            ctx.beginPage(mediaBox: &mediaBox)
            draw(ctx, page)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// A small vector "text-like" PDF: rows of thin strokes. Not meaningfully
    /// reducible by image downsampling, so it exercises the output>input guard.
    static func makeTextPDF(at url: URL, pageCount: Int = 1) throws {
        try makePDF(at: url, pageCount: pageCount) { ctx, _ in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(pageRect)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1)
            for row in stride(from: 40, to: Int(pageRect.height) - 40, by: 16) {
                ctx.stroke(CGRect(x: 50, y: CGFloat(row), width: 480, height: 1))
            }
        }
    }

    /// An image-heavy PDF embedding a large, high-entropy (noisy) bitmap so the
    /// original is genuinely large and downsampling produces a real reduction.
    static func makeImageHeavyPDF(at url: URL, pageCount: Int = 1) throws {
        let image = makeNoiseImage(width: 2550, height: 3300) // ~300 dpi for a Letter page
        try makePDF(at: url, pageCount: pageCount) { ctx, _ in
            ctx.draw(image, in: pageRect)
        }
    }

    private static func makeNoiseImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((seed >> 33) & 0xFF)
        }
        for i in stride(from: 0, to: data.count, by: bytesPerPixel) {
            data[i] = next()
            data[i + 1] = next()
            data[i + 2] = next()
            data[i + 3] = 255
        }
        let ctx = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}
