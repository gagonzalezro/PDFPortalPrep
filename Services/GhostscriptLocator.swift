import Foundation

struct GhostscriptLocator {
    static let commonPaths = [
        "/opt/homebrew/bin/gs",
        "/usr/local/bin/gs",
        "/usr/bin/gs"
    ]
    
    static func locate() -> String? {
        let fileManager = FileManager.default
        
        // 1. Check common absolute paths
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) && fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // 2. Try looking it up using which in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "gs"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty,
                   fileManager.fileExists(atPath: output) {
                    return output
                }
            }
        } catch {
            // Ignore error and return nil
        }
        
        return nil
    }
}
