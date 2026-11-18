import ArgumentParser
import Foundation

/// Each module's binary interface and its archive come from one build. A
/// client compiled against a module calls what the module's interface says
/// is there: a stored global's or static's addressor where the module was
/// built without library evolution, its getter where it was resilient, a
/// conformance's witness table or its descriptor. A .swiftmodule from one
/// build beside an archive from another (another variant, another source
/// revision, other flags) leaves those undefined at the app's link. So a
/// client referencing every public global, static and conformance of the
/// module, compiled against the SDK, must need nothing in the module's
/// namespace that the SDK's archives don't define.
struct Pairing: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A client of each module's public globals, statics and conformances links against the SDK's archives."
    )

    @OptionGroup var target: TargetOptions
    @OptionGroup var resolve: ResolveOptions

    @Option(name: .customLong("module"), help: "A Swift module the SDK's build made. Repeatable.")
    var modules: [String]

    func run() throws {
        let compiler = target.compiler
        var archives = SymbolTable()
        for archive in try libraries(at: [target.archives]).filter({ $0.hasSuffix(".a") }) {
            try archives.read(archive, nm: compiler.nm)
        }
        let platform = try resolve.platformSymbols(nm: compiler.nm)
        var problems: [String] = []
        for module in modules {
            let scratch = try makeScratchDirectory("pairing-\(module)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let graphs = try SymbolGraphs.extract(module, compiler: compiler, into: scratch)
            var client = graphs.client(of: module)
            let source = scratch.appendingPathComponent("Client.swift")
            let object = scratch.appendingPathComponent("Client.o")
            let candidates = client.references.count
            // What doesn't compile (a generic type's static, an unavailable
            // one, a protocol with requirements a type meets only
            // conditionally) is dropped and the rest compiled again: the
            // check is of what does.
            var compiled = false
            for _ in 0..<12 {
                try client.source.write(to: source, atomically: true, encoding: .utf8)
                let output = try compiler.compile(source, to: object)
                if output.status == 0 { compiled = true; break }
                let lines = errorLines(in: output.stderr, file: source.path)
                if lines.isEmpty || !client.drop(lines: lines) {
                    problems.append("\(module)'s client doesn't compile, and not for its own lines:\n\(output.stderr.suffix(4000))")
                    break
                }
            }
            guard compiled else {
                if !problems.contains(where: { $0.hasPrefix("\(module)'s client") }) {
                    problems.append("\(module)'s client didn't compile after dropping what failed")
                }
                continue
            }
            var needed = SymbolTable()
            try needed.read(object.path, nm: compiler.nm)
            let missing = needed.undefined.keys
                .filter { $0.hasPrefix("$s") && !archives.defined.contains($0) && !platform.contains($0) && !resolve.allowance.allows($0) }
                .sorted()
            print("pairing: \(module): \(client.references.count) of \(candidates) references compiled (globals, statics, conformances), \(missing.count) undefined in the SDK's archives")
            for symbol in missing {
                problems.append("\(module): \(symbol) is needed by a client and defined by no archive (\(demangle(symbol, bin: compiler.bin)))")
            }
        }
        try report("pairing", target.target, problems: problems)
    }

    /// The lines of `file` the compiler reported errors on.
    func errorLines(in diagnostics: String, file: String) -> Set<Int> {
        var lines: Set<Int> = []
        for line in diagnostics.split(separator: "\n") where line.hasPrefix(file + ":") && line.contains(": error:") {
            let rest = line.dropFirst(file.count + 1)
            if let number = Int(rest.prefix { $0.isNumber }) { lines.insert(number) }
        }
        return lines
    }

    func demangle(_ symbol: String, bin: String) -> String {
        let output = try? runChecked("\(bin)/swift-demangle", ["-compact", symbol])
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? symbol
    }
}

/// A module's symbol graphs: its own, and its extensions of other modules'
/// types (`<Module>@<Other>.symbols.json`).
struct SymbolGraphs {
    struct Graph: Decodable {
        struct Symbol: Decodable {
            struct Kind: Decodable { var identifier: String }
            struct Identifier: Decodable { var precise: String }
            struct Generics: Decodable {
                struct Parameter: Decodable { var name: String }
                var parameters: [Parameter]?
            }
            var kind: Kind
            var identifier: Identifier
            var pathComponents: [String]
            var accessLevel: String
            var swiftGenerics: Generics?
        }
        struct Relationship: Decodable {
            var kind: String
            var source: String
            var target: String
            var targetFallback: String?
        }
        var symbols: [Symbol]
        var relationships: [Relationship]
    }

    /// The module's own graph, and the extension graphs by extended module.
    var own: Graph?
    var extensions: [String: Graph] = [:]

    static func extract(_ module: String, compiler: Compiler, into directory: URL) throws -> SymbolGraphs {
        let out = directory.appendingPathComponent("graphs")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try runChecked(compiler.symbolgraphExtract, compiler.targetArguments + [
            "-module-name", module, "-output-dir", out.path, "-minimum-access-level", "public",
            "-skip-synthesized-members",
        ])
        var graphs = SymbolGraphs()
        for name in try FileManager.default.contentsOfDirectory(atPath: out.path) where name.hasSuffix(".symbols.json") {
            let graph = try JSONDecoder().decode(Graph.self, from: Data(contentsOf: out.appendingPathComponent(name)))
            let stem = String(name.dropLast(".symbols.json".count))
            if stem == module {
                graphs.own = graph
            } else if let at = stem.firstIndex(of: "@") {
                graphs.extensions[String(stem[stem.index(after: at)...])] = graph
            }
        }
        return graphs
    }

    /// Protocols whose conformances no code can reference (marker protocols).
    static let markers: Set<String> = ["Sendable", "Copyable", "Escapable", "BitwiseCopyable", "SendableMetatype"]

    /// A client referencing every public global and static (`_ = M.T.x`) and
    /// every non-generic type's conformance (a generic function constrained
    /// to the protocol, called with the type).
    func client(of module: String) -> Client {
        var client = Client(module: module)
        var protocolNames: [String: String] = [:] // precise identifier → spelling
        var typeNames: [String: (String, Bool)] = [:] // precise → (spelling, generic)
        let graphs: [(Graph, qualified: Bool)] = (own.map { [($0, true)] } ?? []) + extensions.values.map { ($0, false) }
        for (graph, qualified) in graphs {
            for symbol in graph.symbols {
                let spelling = (qualified ? [module] : []) + symbol.pathComponents
                let generic = !(symbol.swiftGenerics?.parameters ?? []).isEmpty
                switch symbol.kind.identifier {
                case "swift.protocol":
                    protocolNames[symbol.identifier.precise] = spelling.joined(separator: ".")
                case "swift.struct", "swift.class", "swift.enum":
                    typeNames[symbol.identifier.precise] = (spelling.joined(separator: "."), generic)
                default: break
                }
            }
        }
        // A member of a generic type can't be named without its arguments.
        let genericTypes = Set(typeNames.values.filter(\.1).map(\.0))
        for (graph, qualified) in graphs {
            for symbol in graph.symbols where ["swift.var", "swift.type.property"].contains(symbol.kind.identifier) {
                let spelling = ((qualified ? [module] : []) + symbol.pathComponents).joined(separator: ".")
                let parent = ((qualified ? [module] : []) + symbol.pathComponents.dropLast()).joined(separator: ".")
                if genericTypes.contains(parent) { continue }
                client.add(reference: "_ = \(spelling)")
            }
            for relationship in graph.relationships where relationship.kind == "conformsTo" {
                guard let (type, generic) = typeNames[relationship.source], !generic else { continue }
                guard let proto = protocolNames[relationship.target] ?? relationship.targetFallback else { continue }
                if Self.markers.contains(proto.split(separator: ".").last.map(String.init) ?? proto) { continue }
                client.add(conformance: type, to: proto)
            }
        }
        return client
    }
}

/// The generated client: its declarations and references, a line each, so
/// the lines the compiler rejects can be dropped.
struct Client {
    var module: String
    var references: [String] = []
    var protocols: [String] = []
    private var dropped: Set<String> = []

    init(module: String) { self.module = module }

    mutating func add(reference: String) {
        if !references.contains(reference) { references.append(reference) }
    }

    mutating func add(conformance type: String, to proto: String) {
        let index: Int
        if let existing = protocols.firstIndex(of: proto) { index = existing } else {
            protocols.append(proto)
            index = protocols.count - 1
        }
        add(reference: "_conforms\(index)(\(type).self)")
    }

    // The header's lines: the imports, then one generic function a protocol.
    private var header: [String] {
        let imports = ["import \(module)", "#if canImport(Combine)", "import Combine", "#endif"]
        return imports + protocols.enumerated().map { index, proto in
            dropped.contains("p\(index)") ? "// (dropped) \(proto)" : "func _conforms\(index)<T: \(proto)>(_: T.Type) {}"
        } + ["@inline(never) public func _touch() {"]
    }

    var source: String {
        (header + references.map { "    " + $0 } + ["}"]).joined(separator: "\n") + "\n"
    }

    /// Drops the reported lines (1-based); false if none of them was a
    /// declaration or reference of the client's.
    mutating func drop(lines: Set<Int>) -> Bool {
        let headerCount = header.count
        var removed: Set<Int> = []
        var changed = false
        for line in lines {
            let index = line - 1
            if index >= headerCount, index - headerCount < references.count {
                removed.insert(index - headerCount)
            } else if index >= 4, index < headerCount - 1 {
                // A protocol's function: the protocol can't constrain here
                // (unavailable, or not a protocol by that name). Its calls
                // go with it.
                let protocolIndex = index - 4
                dropped.insert("p\(protocolIndex)")
                let call = "_conforms\(protocolIndex)("
                for (i, reference) in references.enumerated() where reference.hasPrefix(call) { removed.insert(i) }
                changed = true
            }
        }
        references = references.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return changed || !removed.isEmpty
    }
}
