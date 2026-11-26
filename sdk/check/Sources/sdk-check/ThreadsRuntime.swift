import ArgumentParser
import Foundation

/// Builds the wasm32-unknown-wasip1-threads runtime the threads SDK takes
/// (sdk/build.sh wasm-threads): Swift 6.4.2's stdlib, runtime and
/// Concurrency for the threads triple with swiftlang/swift#92018
/// (multi-threaded wasi-threads Concurrency), and its sysroot (wasi-libc,
/// compiler-rt, and libunwind, libc++abi and libc++ with threads and
/// WebAssembly exceptions, the standard exnref proposal), from upstream's
/// swift-6.4.2-RELEASE and friends, cloned by tag and checked against their
/// commits, plus the patch files in sdk/patches.
///
/// No compiler is built: the release toolchain sdk/build.sh downloads is the
/// host compiler (build-script's --build-runtime-with-host-compiler), so the
/// modules come out by the compiler that will load them. LLVM is only
/// configured, for its CMake modules. Swift's own build-script does the work,
/// asked for the WASI sysroot and the threads stdlib alone
/// (`--build-wasi-threads-stdlib-only`, sdk/patches/swift/0004): the plain
/// wasip1 stdlib is swift.org's bundle's, and Isomer builds its own
/// Foundation family.
///
/// In `--out`, one directory laid out as a target of swift.org's wasm
/// artifact bundle (<bundle>/swift-6.4.2-RELEASE_wasm/wasm32-unknown-wasip1/):
///
///   wasm32-unknown-wasip1-threads/
///     WASI.sdk/                    the sysroot: include/wasm32-wasip1-threads,
///                                  include/c++/v1, lib/wasm32-wasip1-threads
///                                  (libc++.a, libc++abi.a, libunwind.a: EH and
///                                  threads)
///     swift.xctoolchain/usr/lib/
///       swift_static/              the stdlib's static resources (wasi/,
///                                  shims/, clang/), libswiftCxx.a among them
///       clang/lib/                 compiler-rt, as swift.org's bundle has it
///     BUILD-INFO.txt               sources, patches, toolchain, flags
///
/// A build whose inputs (the patches, the sources' pins, the toolchain) are
/// those of the one already in `--out` is not repeated.
struct BuildThreadsRuntime: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-threads-runtime",
        abstract: "Builds the wasm32-unknown-wasip1-threads runtime (sysroot with EH C++ runtimes, threads stdlib) from upstream's sources and sdk/patches."
    )

    @Option(help: "The release toolchain's usr/bin (swift, clang, llvm-*), the host compiler.")
    var bin: String

    @Option(help: "sdk/patches: swift/*.patch (git format-patch, applied with `git am`) and llvm-project/*.patch (`git apply`).")
    var patches: String

    @Option(help: "Sources and build trees.")
    var work: String

    @Option(help: "Where the target directory, wasm32-unknown-wasip1-threads/, goes.")
    var out: String

    @Option(help: "Parallel jobs (the machine's processors by default).")
    var jobs: Int = ProcessInfo.processInfo.activeProcessorCount

    static let triple = "wasm32-unknown-wasip1-threads"
    /// clang's name for it: the sysroot's multiarch directories.
    static let clangTriple = "wasm32-wasip1-threads"

    struct Source {
        var name: String
        var url: String
        var tag: String
        var commit: String
        /// For a sparse checkout: what the build reads.
        var sparse: [String] = []
    }

    /// update-checkout's release/6.4.2 scheme (wasi-libc at wasi-sdk-31). Of
    /// llvm-project, only LLVM's CMake, compiler-rt, the runtimes and libc's
    /// shared headers (libc++ 21's charconv includes them).
    static let sources = [
        Source(name: "swift", url: "https://github.com/swiftlang/swift.git", tag: "swift-6.4.2-RELEASE",
               commit: "83eb12448e4323abbf81b0153dced2faff02d22f"),
        Source(name: "llvm-project", url: "https://github.com/swiftlang/llvm-project.git", tag: "swift-6.4.2-RELEASE",
               commit: "fb5f84d903a3b4e7aea15cd5666598a46f56c833",
               sparse: ["llvm", "cmake", "compiler-rt", "runtimes", "libcxx", "libcxxabi", "libunwind", "libc", "third-party"]),
        Source(name: "wasi-libc", url: "https://github.com/WebAssembly/wasi-libc.git", tag: "wasi-sdk-31",
               commit: "2fc32bc81b9f07f8d9525edea59bfbaf760c06d6"),
        Source(name: "swift-experimental-string-processing",
               url: "https://github.com/swiftlang/swift-experimental-string-processing.git", tag: "swift-6.4.2-RELEASE",
               commit: "7581e7b803d2ccc58409e45e1bfde40146cb8e41"),
    ]

    func run() throws {
        #if !os(Linux)
        throw CheckFailure("build-threads-runtime runs on Linux (a container), not on this machine")
        #else
        let fileManager = FileManager.default
        let work = URL(fileURLWithPath: work).standardizedFileURL.path
        let out = URL(fileURLWithPath: out).standardizedFileURL.path
        let patches = URL(fileURLWithPath: patches).standardizedFileURL.path
        try fileManager.createDirectory(atPath: work, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: out, withIntermediateDirectories: true)
        let package = "\(out)/\(Self.triple)"

        let swiftPatches = try patchFiles(in: "\(patches)/swift")
        let llvmPatches = try patchFiles(in: "\(patches)/llvm-project")
        guard !swiftPatches.isEmpty else { throw CheckFailure("no swift/*.patch in \(patches)") }
        let toolchain = try runChecked("\(bin)/swift", ["--version"]).split(separator: "\n").first.map(String.init) ?? ""

        // What the build is made of: the same inputs, the same runtime.
        var inputs = ["toolchain: \(toolchain)"] + Self.sources.map { "\($0.name) \($0.tag) \($0.commit)" }
        for patch in swiftPatches + llvmPatches {
            inputs.append("\(patch.dropFirst(patches.count + 1)) \(try sha256(of: patch))")
        }
        let stamp = inputs.joined(separator: "\n") + "\n"
        let stampPath = "\(package)/.inputs"
        if let built = try? String(contentsOfFile: stampPath, encoding: .utf8), built == stamp {
            step("runtime", "already built from these inputs in \(package)")
            try checkPackage(package)
            return
        }

        step("tools")
        try ensureTools()

        step("sources")
        let sourceRoot = "\(work)/src"
        try fileManager.createDirectory(atPath: sourceRoot, withIntermediateDirectories: true)
        for source in Self.sources {
            let directory = "\(sourceRoot)/\(source.name)"
            // A fresh checkout every build: the patches go onto upstream's tag.
            try? fileManager.removeItem(atPath: directory)
            var clone = ["-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "--branch", source.tag]
            if !source.sparse.isEmpty { clone += ["--filter=blob:none", "--sparse"] }
            try stream("/usr/bin/env", ["git"] + clone + [source.url, directory])
            if !source.sparse.isEmpty {
                try stream("/usr/bin/env", ["git", "-C", directory, "sparse-checkout", "set"] + source.sparse)
            }
            let head = try runChecked("/usr/bin/env", ["git", "-C", directory, "rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == source.commit else { throw CheckFailure("\(source.name): \(source.tag) is \(head), not \(source.commit)") }
            print("\(source.name) \(source.tag) \(source.commit)")
        }

        step("patches")
        for patch in swiftPatches {
            print("swift: \((patch as NSString).lastPathComponent)")
            try stream("/usr/bin/env", ["git", "-C", "\(sourceRoot)/swift", "-c", "user.name=isomer-build",
                                        "-c", "user.email=isomer-build@invalid", "-c", "commit.gpgsign=false",
                                        "am", "--quiet", "--keep", "--keep-cr", patch])
        }
        for patch in llvmPatches {
            print("llvm-project: \((patch as NSString).lastPathComponent)")
            try stream("/usr/bin/env", ["git", "-C", "\(sourceRoot)/llvm-project", "apply", patch])
        }

        step("build", "the \(Self.clangTriple) sysroot and the \(Self.triple) stdlib (\(jobs) jobs)")
        let buildRoot = "\(work)/build"
        let build = "\(buildRoot)/wasi-threads"
        try? fileManager.removeItem(atPath: build)
        guard let cmake = which("cmake") else { throw CheckFailure("no cmake on PATH") }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin):" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["SWIFT_BUILD_ROOT"] = buildRoot
        try stream("/usr/bin/env", [
            "python3", "utils/build-script",
            "--release", "--no-assertions", "--no-swift-stdlib-assertions",
            "--build-subdir=wasi-threads",
            "--skip-build-cmark", "--skip-build-llvm", "--skip-build-swift", "--skip-early-swift-driver",
            "--build-wasi-stdlib", "--build-wasi-threads-stdlib-only", "--skip-test-wasi-stdlib",
            "--build-runtime-with-host-compiler",
            "--host-cc=\(bin)/clang", "--host-cxx=\(bin)/clang++",
            "--native-swift-tools-path=\(bin)", "--native-clang-tools-path=\(bin)", "--native-llvm-tools-path=\(bin)",
            "--cmake=\(cmake)", "--jobs=\(jobs)",
        ], in: "\(sourceRoot)/swift", environment: environment)

        step("package", package)
        let host: String
        switch try runChecked("/usr/bin/env", ["uname", "-m"]).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "aarch64", "arm64": host = "linux-aarch64"
        case "x86_64": host = "linux-x86_64"
        case let other: throw CheckFailure("no build-script host for \(other)")
        }
        let stdlibBuild = "\(build)/wasithreadsstdlib-\(host)"
        let sysroot = "\(build)/wasi-sysroot/\(Self.clangTriple)/sysroot"
        let resourceDir = "\(build)/wasi-sysroot/\(Self.clangTriple)/resource-dir"
        for path in [stdlibBuild, sysroot, resourceDir] where !fileManager.fileExists(atPath: path) {
            throw CheckFailure("the build made no \(path)")
        }
        try? fileManager.removeItem(atPath: package)
        try fileManager.createDirectory(atPath: package, withIntermediateDirectories: true)
        try stream("/usr/bin/env", ["cp", "-a", sysroot, "\(package)/WASI.sdk"])
        let toolchainDir = "\(package)/swift.xctoolchain"
        var install = ProcessInfo.processInfo.environment
        install["DESTDIR"] = toolchainDir
        let installed = try ProcessRunner.run(cmake, ["--install", stdlibBuild], environment: install)
        guard installed.status == 0 else { throw CheckFailure("cmake --install \(stdlibBuild) failed:\n\(installed.stderr)") }
        let usr = "\(toolchainDir)/usr"
        let staticDir = "\(usr)/lib/swift_static"
        // compiler-rt into the clang resource directories, as wasiswiftsdk.py's
        // _build_target_package does.
        for directory in ["clang", "swift_static/clang"] {
            let lib = "\(usr)/lib/\(directory)/lib"
            try fileManager.createDirectory(atPath: "\(usr)/lib/\(directory)", withIntermediateDirectories: true)
            try? fileManager.removeItem(atPath: lib)
            try stream("/usr/bin/env", ["cp", "-a", "\(resourceDir)/lib", lib])
        }
        // The C++ overlay's library beside the static stdlib, where
        // swift-sdk.json points: the install leaves it beside the dynamic
        // resources alone (-lswiftCxx not found), as swift.org's bundle does.
        let cxx = "\(usr)/lib/swift/wasi/libswiftCxx.a"
        guard fileManager.fileExists(atPath: cxx) else { throw CheckFailure("the install has no \(cxx)") }
        try? fileManager.removeItem(atPath: "\(staticDir)/wasi/libswiftCxx.a")
        try fileManager.copyItem(atPath: cxx, toPath: "\(staticDir)/wasi/libswiftCxx.a")
        // What a static-stdlib SDK doesn't use: the dynamic resources (the
        // SDK's swift-sdk.json names swift_static for both), the runtime's
        // headers, the API scripts and editor files the install adds.
        for extra in ["lib/swift", "include", "bin", "share"] {
            try? fileManager.removeItem(atPath: "\(usr)/\(extra)")
        }
        // The threads triple's libc++abi throws through libunwind, so a Swift
        // program (whose runtime links libc++abi through -lstdc++) needs
        // -lunwind too. swiftc reads the static resources' link arguments from
        // this file (one source for both triples); a build system that links
        // by itself (rules_swift) takes -lunwind from the SDK's toolset.json.
        let lnk = "\(staticDir)/wasi/static-executable-args.lnk"
        var lines = try String(contentsOfFile: lnk, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.contains("-lunwind") {
            guard let index = lines.firstIndex(of: "-lstdc++") else { throw CheckFailure("\(lnk): no -lstdc++ line to put -lunwind after") }
            lines.insert("-lunwind", at: index + 1)
            try lines.joined(separator: "\n").write(toFile: lnk, atomically: true, encoding: .utf8)
        }
        var info = [
            "\(Self.triple) runtime for Swift 6.4.2 (Isomer's threads SDK: sdk-check build-threads-runtime)",
            "built on \(host) by \(toolchain)",
            "",
            "sources:",
        ] + Self.sources.map { "  \($0.name) \($0.url) \($0.tag) \($0.commit)" }
        info += ["", "patches (sha256):"] + inputs.filter { $0.hasPrefix("swift/") || $0.hasPrefix("llvm-project/") }.map { "  \($0)" }
        info += [
            "",
            "flags: C/C++ for \(Self.clangTriple): -matomics -mbulk-memory -mthread-model posix -pthread",
            "  -ftls-model=local-exec -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false;",
            "  link: -lunwind, --import-memory --export-memory --shared-memory --max-memory=N",
        ]
        try (info.joined(separator: "\n") + "\n").write(toFile: "\(package)/BUILD-INFO.txt", atomically: true, encoding: .utf8)

        try checkPackage(package)
        try stamp.write(toFile: stampPath, atomically: true, encoding: .utf8)
        #endif
    }

    /// The package is what the SDK needs: every object wasm, the C++
    /// runtimes with exceptions and threads, and no legacy EH instruction
    /// (WasmKit and the standard proposal take only try_table and throw_ref).
    func checkPackage(_ package: String) throws {
        step("runtime check", package)
        let libdir = "\(package)/WASI.sdk/lib/\(Self.clangTriple)"
        var problems: [String] = []
        let objects = try FileManager.default.subpathsOfDirectory(atPath: package)
            .filter { $0.hasSuffix(".a") || $0.hasSuffix(".o") }.map { "\(package)/\($0)" }
        let formats = try ProcessRunner.run("\(bin)/llvm-objdump", ["-f"] + objects).stdout
            .split(separator: "\n").filter { $0.contains("file format") && !$0.contains("file format wasm") }
        if !formats.isEmpty { problems.append("not wasm: \(formats.joined(separator: "; "))") }
        print("\(objects.count) archives and objects, \(formats.isEmpty ? "all wasm" : "\(formats.count) not wasm")")
        let required = [
            "libc++abi.a": ["__cxa_throw", "__gxx_personality_wasm0", "__cxa_thread_atexit"],
            "libunwind.a": ["_Unwind_CallPersonality", "_Unwind_RaiseException"],
        ]
        for (library, symbols) in required.sorted(by: { $0.key < $1.key }) {
            let path = "\(libdir)/\(library)"
            guard FileManager.default.fileExists(atPath: path) else { problems.append("no \(path)"); continue }
            let defined = Set(try ProcessRunner.run("\(bin)/llvm-nm", ["--defined-only", "-j", path]).stdout.split(separator: "\n").map(String.init))
            for symbol in symbols where !defined.contains(symbol) { problems.append("\(library) defines no \(symbol)") }
        }
        let configSite = "\(package)/WASI.sdk/include/c++/v1/__config_site"
        let config = (try? String(contentsOfFile: configSite, encoding: .utf8)) ?? ""
        for line in ["#define _LIBCPP_HAS_THREADS 1", "#define _LIBCPP_HAS_THREAD_API_PTHREAD 1", "#define _LIBCPP_ABI_NAMESPACE __2"]
        where !config.contains(line) {
            problems.append("\(configSite) has no `\(line)`")
        }
        var legacy = 0, exnref = 0
        for library in ["libc++abi.a", "libc++.a", "libunwind.a"] {
            let disassembly = try ProcessRunner.run("\(bin)/llvm-objdump", ["-d", "\(libdir)/\(library)"]).stdout
            for line in disassembly.split(separator: "\n") {
                // An instruction line: "<offset>: <bytes> <mnemonic> …".
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if words.contains(where: { ["try", "catch", "catch_all", "delegate", "rethrow"].contains($0) }) { legacy += 1 }
                if words.contains(where: { $0 == "try_table" || $0 == "throw_ref" }) { exnref += 1 }
            }
        }
        print("EH instructions in the C++ runtimes: try_table/throw_ref \(exnref), legacy (try/catch/delegate/rethrow) \(legacy)")
        if legacy != 0 { problems.append("\(legacy) legacy EH instructions in the C++ runtimes") }
        if exnref == 0 { problems.append("no try_table or throw_ref in the C++ runtimes: built without exceptions?") }
        let lnk = (try? String(contentsOfFile: "\(package)/swift.xctoolchain/usr/lib/swift_static/wasi/static-executable-args.lnk", encoding: .utf8)) ?? ""
        if !lnk.split(separator: "\n").contains("-lunwind") { problems.append("static-executable-args.lnk has no -lunwind") }
        try report("threads runtime", Self.triple, problems: problems)
    }

    func patchFiles(in directory: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".patch") }.sorted().map { "\(directory)/\($0)" }
    }

    /// cmake, ninja, python3 and git, from apt when missing (as root, or
    /// with sudo).
    func ensureTools() throws {
        let missing = ["cmake", "ninja", "python3", "git"].filter { which($0) == nil }
        if !missing.isEmpty {
            print("installing \(missing.joined(separator: ", "))")
            let sudo = try runChecked("/usr/bin/env", ["id", "-u"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0" ? [] : ["sudo"]
            var environment = ProcessInfo.processInfo.environment
            environment["DEBIAN_FRONTEND"] = "noninteractive"
            try stream("/usr/bin/env", sudo + ["apt-get", "update", "-qq"], environment: environment)
            try stream("/usr/bin/env", sudo + ["apt-get", "install", "-y", "-qq", "cmake", "ninja-build", "python3", "git"],
                       environment: environment)
        }
        print(try runChecked("/usr/bin/env", ["cmake", "--version"]).split(separator: "\n").first.map(String.init) ?? "cmake")
        print("ninja \(try runChecked("/usr/bin/env", ["ninja", "--version"]).trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

/// A step's heading, as sdk/build.sh prints its own.
func step(_ name: String, _ detail: String = "") {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    print("\n=== \(name)\(detail.isEmpty ? "" : " \(detail)") (\(formatter.string(from: Date())))")
}

/// The first `name` on PATH.
func which(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func sha256(of path: String) throws -> String {
    let output = try runChecked("/usr/bin/env", ["sha256sum", path])
    return String(output.prefix { $0 != " " })
}
