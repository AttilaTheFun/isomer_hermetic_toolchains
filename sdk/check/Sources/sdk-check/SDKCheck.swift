import ArgumentParser
import Foundation

@main
struct SDKCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk-check",
        abstract: "Checks a Swift SDK's static resources for one target, as sdk/build.sh builds them.",
        discussion: """
            Each check fails (exit 1) naming what is wrong:
              autolink   every module's importers autolink its own library, and
                         every library any import names is in the SDK or the
                         platform's sysroot
              pairing    a client of each module's public globals, statics and
                         conformances compiles and needs nothing the SDK's
                         archives don't define: the binary module and the
                         archive come from one build
              undefined  every archive's undefined symbols are defined by the
                         SDK's archives or by the platform's libraries at its
                         oldest supported level (Android's API, WASI's libc)
            And for a release run: draft, the release drafted with the SDKs (its
            version from the repository's releases and tags).
            """,
        subcommands: [Autolink.self, Pairing.self, Undefined.self, Draft.self]
    )
}

/// What every check is given: the toolchain, and where the SDK's target is.
struct TargetOptions: ParsableArguments {
    @Option(help: "The toolchain's usr/bin (swiftc, llvm-nm, llvm-objcopy, swift-symbolgraph-extract).")
    var bin: String

    @Option(help: "The target triple (aarch64-unknown-linux-android23, wasm32-unknown-wasip1).")
    var target: String

    @Option(help: "The SDK's sysroot (Android's ndk-sysroot, wasm's WASI.sdk).")
    var sdk: String

    @Option(help: "The SDK's static resource directory (swift_static-<arch>, or wasm's swift_static).")
    var resourceDir: String

    @Option(help: "The static libraries' directory inside it (<resource-dir>/android, <resource-dir>/wasi).")
    var archives: String

    var compiler: Compiler { Compiler(bin: bin, target: target, sdk: sdk, resourceDir: resourceDir) }
}

struct ResolveOptions: ParsableArguments {
    @Option(name: .customLong("resolve-against"), help: "A library, or a directory of them (*.a, *.so), that a final link has besides the SDK's archives. Repeatable.")
    var resolveAgainst: [String] = []

    @Option(name: .customLong("allow"), help: "An undefined symbol the final link supplies itself. Repeatable.")
    var allow: [String] = []

    @Option(name: .customLong("allow-prefix"), help: "A prefix of undefined symbols the final link or the host supplies (__start_, WASI's imports). Repeatable.")
    var allowPrefix: [String] = []

    var allowance: Allowance { Allowance(names: Set(allow), prefixes: allowPrefix) }

    /// The symbols the platform's libraries define.
    func platformSymbols(nm: String) throws -> Set<String> {
        var table = SymbolTable()
        for library in try libraries(at: resolveAgainst) { try table.read(library, nm: nm) }
        return table.defined
    }
}

func report(_ check: String, _ target: String, problems: [String]) throws {
    if problems.isEmpty {
        print("PASS \(check) (\(target))")
        return
    }
    print("FAIL \(check) (\(target)): \(problems.count) problem\(problems.count == 1 ? "" : "s")")
    for problem in problems { print("  \(problem)") }
    throw ExitCode.failure
}
