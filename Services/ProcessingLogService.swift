import Foundation

struct ProcessingLogService {
    static func write(
        outputURL: URL,
        originalSize: Int64,
        finalSize: Int64,
        pageCount: Int,
        compressionLevel: String,
        meetsLimit: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let logDirectory = appSupport.appendingPathComponent("PDFPortalPrep", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let logURL = logDirectory.appendingPathComponent("process-log.jsonl")
        let entry: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "result": outputURL.path,
            "originalSizeBytes": originalSize,
            "finalSizeBytes": finalSize,
            "pageCount": pageCount,
            "compressionLevel": compressionLevel,
            "meetsLimit": meetsLimit
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        guard var line = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ProcessingLogService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode process log entry."]
            )
        }
        line.append("\n")

        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
        } else {
            try line.write(to: logURL, atomically: true, encoding: .utf8)
        }

        return logURL
    }
}
