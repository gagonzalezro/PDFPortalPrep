import Foundation

struct PDFInputFile: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let fileSize: Int64
    let pageCount: Int
    let hasPassword: Bool
    let hasInteractiveElements: Bool
    
    init(url: URL, fileSize: Int64, pageCount: Int, hasPassword: Bool, hasInteractiveElements: Bool) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.hasPassword = hasPassword
        self.hasInteractiveElements = hasInteractiveElements
    }
}
