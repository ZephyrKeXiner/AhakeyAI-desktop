import Foundation

class pluginClient {
    var nextId = 1
    let process = Process()
    let output = Pipe()
    let input = Pipe()
    enum Method {
        case substract
        case add
        case multiple
    }

    init() {
        process.standardOutput = output
        process.standardInput = input
    }
    
    func request(parm: String) -> String {
        
    }

    func response(parm: String) -> String {
        
    }
}

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