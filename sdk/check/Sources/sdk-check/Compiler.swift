import Foundation

/// The toolchain's programs and the SDK target they compile for.
struct Compiler {
    var bin: String
    var target: String
    var sdk: String
    var resourceDir: String

    var swiftc: String { "\(bin)/swiftc" }
    var nm: String { "\(bin)/llvm-nm" }
    var objcopy: String { "\(bin)/llvm-objcopy" }
    var symbolgraphExtract: String { "\(bin)/swift-symbolgraph-extract" }

    var targetArguments: [String] { ["-target", target, "-sdk", sdk, "-resource-dir", resourceDir] }

    /// Compiles `source` to an object, as an SDK's client compiles against
    /// it. Returns the compiler's output.
    func compile(_ source: URL, to object: URL) throws -> Output {
        try run(swiftc, targetArguments + [
            "-parse-as-library", "-module-name", "SDKCheckClient", "-swift-version", "5",
            "-c", source.path, "-o", object.path,
        ])
    }

    /// The libraries an object's imports autolink: its
    /// .swift1_autolink_entries section, NUL-separated.
    func autolinks(of object: URL) throws -> [String] {
        let scratch = try makeScratchDirectory("autolink")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let section = scratch.appendingPathComponent("section")
        let output = try run(objcopy, [
            "--dump-section=.swift1_autolink_entries=\(section.path)", object.path,
            scratch.appendingPathComponent("copy").path,
        ])
        guard output.status == 0 else {
            // An object that imports nothing has no such section.
            if output.stderr.contains("not found") { return [] }
            throw CheckFailure("llvm-objcopy \(object.path) failed:\n\(output.stderr)")
        }
        return String(decoding: try Data(contentsOf: section), as: UTF8.self)
            .split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }
}
