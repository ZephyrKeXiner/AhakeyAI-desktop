import Foundation

let process = Process()
let output = Pipe()

process.executableURL = URL(filePath: "/usr/bin/env")
process.arguments = ["node", "-v"]
process.standardOutput = output
do {
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text)
} catch {
    print("Failed to run node:", error)
}