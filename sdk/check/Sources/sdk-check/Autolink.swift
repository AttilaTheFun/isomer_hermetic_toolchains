import ArgumentParser
import Foundation

/// Every module's importers autolink its library, and every library an
/// import names exists. A module compiled without `-module-link-name` makes
/// its importers name nothing: a build system that lists no SDK archive (as
/// none does) then links none of it.
struct Autolink: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "An object importing each module autolinks that module's library, and every library named exists."
    )

    @OptionGroup var target: TargetOptions

    @Option(name: .customLong("module"), help: "A Swift module the SDK's build made. Repeatable.")
    var modules: [String]

    @Option(name: .customLong("library-dir"), help: "A directory of the platform's own libraries an entry may name (-lm, -llog, -lwasi-emulated-signal). Repeatable.")
    var libraryDirs: [String] = []

    func run() throws {
        let compiler = target.compiler
        let scratch = try makeScratchDirectory("autolink")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var problems: [String] = []
        var named: [String: Set<String>] = [:]
        for module in modules {
            let source = scratch.appendingPathComponent("\(module).swift")
            let object = scratch.appendingPathComponent("\(module).o")
            // `import M` alone: the entries are written for the imports, used
            // or not.
            try "import \(module)\n".write(to: source, atomically: true, encoding: .utf8)
            let output = try compiler.compile(source, to: object)
            guard output.status == 0 else {
                problems.append("import \(module) doesn't compile:\n\(output.stderr)")
                continue
            }
            let entries = try compiler.autolinks(of: object)
            if !entries.contains("-l\(module)") {
                problems.append("import \(module) autolinks no -l\(module) (its entries: \(entries.joined(separator: " ")))")
            }
            for entry in entries where entry.hasPrefix("-l") {
                named[String(entry.dropFirst(2)), default: []].insert(module)
            }
        }
        let directories = [target.archives] + libraryDirs
        for (library, importers) in named.sorted(by: { $0.key < $1.key }) {
            let found = directories.contains { directory in
                ["a", "so"].contains { FileManager.default.fileExists(atPath: "\(directory)/lib\(library).\($0)") }
            }
            if !found {
                problems.append("-l\(library) (autolinked by import \(importers.sorted().joined(separator: ", "))) is in none of \(directories.joined(separator: ", "))")
            }
        }
        print("autolink: \(modules.count) modules, \(named.count) libraries named")
        try report("autolink", target.target, problems: problems)
    }
}
