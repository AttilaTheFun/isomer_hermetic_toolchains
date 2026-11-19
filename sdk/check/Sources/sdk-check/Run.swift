import Foundation

/// A program's result: its exit status and what it wrote.
struct Output {
    var status: Int32
    var stdout: String
    var stderr: String
}

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Runs `executable` with `arguments`, its output collected through files (a
/// pipe left unread fills and stops the program; the nm of a large archive
/// writes megabytes).
func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> Output {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let outURL = scratch.appendingPathComponent("out")
    let errURL = scratch.appendingPathComponent("err")
    _ = FileManager.default.createFile(atPath: outURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    if let directory { process.currentDirectoryURL = directory }
    try process.run()
    process.waitUntilExit()
    try out.close()
    try err.close()
    return Output(
        status: process.terminationStatus,
        stdout: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
    )
}

/// Runs a program that must succeed, its standard output returned.
func runChecked(_ executable: String, _ arguments: [String]) throws -> String {
    let output = try run(executable, arguments)
    guard output.status == 0 else {
        throw CheckFailure("\(executable) \(arguments.joined(separator: " ")) failed (\(output.status)):\n\(output.stderr)")
    }
    return output.stdout
}

func makeScratchDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-check-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
