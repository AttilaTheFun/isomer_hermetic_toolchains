import Foundation

/// The symbols a set of libraries defines and needs, as llvm-nm reads them
/// (ELF archives and shared objects, wasm archives).
struct SymbolTable {
    /// Global symbols defined (strong or weak).
    var defined: Set<String> = []
    /// Strong undefined references, each with the libraries that make it.
    var undefined: [String: Set<String>] = [:]

    /// Reads `path`: an archive or object's symbol table, or a shared
    /// object's dynamic one (what a link against it can take).
    mutating func read(_ path: String, nm: String) throws {
        let shared = path.hasSuffix(".so") || path.contains(".so.")
        let arguments = (shared ? ["-D", "--defined-only"] : []) + ["-P", "--no-sort", path]
        var output = try run(nm, arguments)
        // A wasm shared object has no ELF dynamic table: its symbols are its
        // own table's.
        if shared, output.status != 0 {
            output = try run(nm, ["--defined-only", "-P", "--no-sort", path])
        }
        // A linker script (the NDK's libc++.a and libc++.so name the real
        // archives, which are given too) holds no symbols.
        if output.status != 0, Self.isLinkerScript(path) { return }
        // An archive member with no symbols makes llvm-nm complain and go on;
        // a file it can't read at all is an error.
        guard output.status == 0 || !output.stdout.isEmpty else {
            throw CheckFailure("llvm-nm \(path) failed:\n\(output.stderr)")
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        for line in output.stdout.split(separator: "\n") {
            // POSIX format: "name type [value size]"; an archive's members are
            // headed "archive[member]:" (whose names may have spaces).
            if line.hasSuffix(":") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[1].count == 1, let type = fields[1].first else { continue }
            // A shared object's dynamic symbols carry their version
            // (write@LIBC); a link takes them by name.
            let symbol = String(fields[0].split(separator: "@", maxSplits: 1).first ?? fields[0])
            switch type {
            case "U":
                undefined[symbol, default: []].insert(name)
            case "w", "v":
                continue // weak undefined: nothing needs it
            default:
                // Uppercase is global (T, D, B, R, W, V, C, A, ...); `u` a GNU
                // unique global. Lowercase is local to its object.
                if type.isUppercase || type == "u" { defined.insert(symbol) }
            }
        }
    }

    static func isLinkerScript(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 64), as: UTF8.self)
        return head.hasPrefix("INPUT(") || head.hasPrefix("GROUP(") || head.hasPrefix("/*")
    }

    /// What `undefined` holds that nothing in `defined` (or `others`) defines
    /// and `allowed` doesn't excuse.
    func unresolved(against others: Set<String> = [], allowed: Allowance) -> [(String, Set<String>)] {
        undefined
            .filter { !defined.contains($0.key) && !others.contains($0.key) && !allowed.allows($0.key) }
            .sorted { $0.key < $1.key }
    }
}

/// Undefined symbols a final link supplies itself (section bounds, the wasm
/// linker's globals) or a host does (WASI's imports).
struct Allowance {
    var names: Set<String>
    var prefixes: [String]

    func allows(_ symbol: String) -> Bool {
        names.contains(symbol) || prefixes.contains { symbol.hasPrefix($0) }
    }
}

/// The libraries at `paths`: files as given, directories' `*.a` and `*.so`
/// (not their subdirectories).
func libraries(at paths: [String]) throws -> [String] {
    var result: [String] = []
    for path in paths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CheckFailure("no such library or directory: \(path)")
        }
        if isDirectory.boolValue {
            let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            result += names.filter { $0.hasSuffix(".a") || $0.hasSuffix(".so") }.map { "\(path)/\($0)" }
        } else {
            result.append(path)
        }
    }
    return result
}
