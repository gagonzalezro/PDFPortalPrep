import Foundation
import PDFKit

struct PDFValidationService {
    struct ScanResult {
        let isValid: Bool
        let pageCount: Int
        let isEncrypted: Bool
        let hasInteractiveElements: Bool
    }
    
    static func scan(url: URL) -> ScanResult {
        guard let document = PDFDocument(url: url) else {
            return ScanResult(isValid: false, pageCount: 0, isEncrypted: false, hasInteractiveElements: false)
        }
        
        let isEncrypted = document.isEncrypted || document.isLocked
        var hasInteractive = false
        
        let pageCount = document.pageCount
        for i in 0..<pageCount {
            if let page = document.page(at: i) {
                let annotations = page.annotations
                for annotation in annotations {
                    // Detect interactive elements (Forms, Buttons, Fields, Signatures)
                    if annotation.fieldName != nil {
                        hasInteractive = true
                        break
                    }
                    if #available(macOS 10.13, *) {
                        if annotation.annotationKeyValues[AnyHashable("/Subtype")] as? String == "/Widget" {
                            hasInteractive = true
                            break
                        }
                    }
                }
            }
            if hasInteractive { break }
        }
        
        return ScanResult(
            isValid: true,
            pageCount: pageCount,
            isEncrypted: isEncrypted,
            hasInteractiveElements: hasInteractive
        )
    }
}
