import ArgumentParser
import Foundation

/// Every archive's undefined symbols are defined by the SDK's archives or by
/// the platform's libraries at its oldest supported level: an archive
/// compiled for a newer Android API than the SDK claims needs a libc symbol
/// that API's libc.so stub doesn't have, and a link at the claimed level
/// fails.
struct Undefined: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Every archive's undefined symbols resolve against the SDK's archives and the platform's libraries."
    )

    @OptionGroup var target: TargetOptions
    @OptionGroup var resolve: ResolveOptions

    func run() throws {
        let nm = target.compiler.nm
        var table = SymbolTable()
        let archives = try libraries(at: [target.archives]).filter { $0.hasSuffix(".a") }
        for archive in archives { try table.read(archive, nm: nm) }
        let platform = try resolve.platformSymbols(nm: nm)
        let unresolved = table.unresolved(against: platform, allowed: resolve.allowance)
        print("undefined: \(archives.count) archives, \(table.undefined.count) undefined symbols, \(platform.count) defined by the platform's libraries")
        try report("undefined", target.target, problems: unresolved.map { symbol, users in
            "\(symbol) (needed by \(users.sorted().joined(separator: ", ")))"
        })
    }
}
