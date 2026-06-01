import Foundation
import PDFKit

struct PDFMergeService {
    static func merge(files: [URL], to outputURL: URL) throws {
        guard !files.isEmpty else {
            throw NSError(
                domain: "PDFMergeService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "No files provided for merging."]
            )
        }
        
        let outputDocument = PDFDocument()
        var targetPageIndex = 0
        
        for fileURL in files {
            guard let inputDocument = PDFDocument(url: fileURL) else {
                throw NSError(
                    domain: "PDFMergeService",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to open PDF document: \(fileURL.lastPathComponent)"]
                )
            }
            
            let pageCount = inputDocument.pageCount
            for i in 0..<pageCount {
                if let page = inputDocument.page(at: i) {
                    // Copy page to prevent PDFKit ownership conflicts when writing
                    guard let pageCopy = page.copy() as? PDFPage else {
                        throw NSError(
                            domain: "PDFMergeService",
                            code: 500,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to copy page \(i + 1) of \(fileURL.lastPathComponent)."]
                        )
                    }
                    outputDocument.insert(pageCopy, at: targetPageIndex)
                    targetPageIndex += 1
                }
            }
        }
        
        guard outputDocument.write(to: outputURL) else {
            throw NSError(
                domain: "PDFMergeService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write merged PDF to target destination."]
            )
        }
    }
}
