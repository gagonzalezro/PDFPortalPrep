import Foundation

struct OutputFileNaming {
    static func generateName(base: String, suffix: String) -> String {
        let nameWithoutExt = (base as NSString).deletingPathExtension
        return "\(nameWithoutExt)\(suffix).pdf"
    }

    static func uniqueURL(in directory: URL, base: String, suffix: String) -> URL {
        let fileManager = FileManager.default
        let nameWithoutExt = (base as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent("\(nameWithoutExt)\(suffix).pdf")
        var counter = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(nameWithoutExt)\(suffix)-\(counter).pdf")
            counter += 1
        }

        return candidate
    }
}
