import Foundation

struct IconEntry {
    let type: String
    let filename: String
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: swift Scripts/make_icns.swift <iconset-dir> <output.icns>\n".utf8))
    exit(64)
}

let iconsetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])

let entries = [
    IconEntry(type: "icp4", filename: "icon_16x16.png"),
    IconEntry(type: "icp5", filename: "icon_32x32.png"),
    IconEntry(type: "icp6", filename: "icon_32x32@2x.png"),
    IconEntry(type: "ic07", filename: "icon_128x128.png"),
    IconEntry(type: "ic08", filename: "icon_256x256.png"),
    IconEntry(type: "ic09", filename: "icon_512x512.png"),
    IconEntry(type: "ic10", filename: "icon_512x512@2x.png")
]

func bigEndianUInt32(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
}

var body = Data()

for entry in entries {
    let fileURL = iconsetURL.appendingPathComponent(entry.filename)
    let pngData = try Data(contentsOf: fileURL)
    guard let typeData = entry.type.data(using: .ascii), typeData.count == 4 else {
        throw NSError(domain: "make_icns", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ICNS entry type \(entry.type)"])
    }

    body.append(typeData)
    body.append(bigEndianUInt32(UInt32(pngData.count + 8)))
    body.append(pngData)
}

var output = Data()
output.append(Data("icns".utf8))
output.append(bigEndianUInt32(UInt32(body.count + 8)))
output.append(body)

try output.write(to: outputURL, options: .atomic)
