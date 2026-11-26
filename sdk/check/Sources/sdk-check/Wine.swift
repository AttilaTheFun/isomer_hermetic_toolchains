import ArgumentParser
import Foundation

/// Wine Staging for arm64 Linux, the `wine-<version>-staging` releases
/// (sdk/README.md, "Wine"): what Nimbus' nimbus-base image's windows layer
/// unpacks as /opt/wine (AttilaTheFun/nimbus's
/// tools/images/nimbus-base/windows.Containerfile, by URL and sha256).
/// Proposed by isomer_sdk.yml's `run: wine` alone, never assembled by hand:
///
///   wine-build   the sources fetched and checked, Staging's patches applied,
///                Wine built with llvm-mingw, /opt/wine packed as
///                wine-<version>-staging-<platform>.tar.zst and its .sha256
///   wine-check   the archive unpacked in the job's container, then each
///                check run and logged (WineCheck.swift)
///   wine-proof   proof.json (Reviews' format 2) and proof.zip of them
///   wine-draft   the draft release, on main, with the archive and the proof
///
/// What a version is built from is sdk/wine/wine.json: the version, the
/// three sources by URL and sha256, the configure line and the packages.
/// Wine's and Staging's URLs name `{version}` (and Wine's `{major}`), so the
/// next version is its "version" and their two sha256s.
struct WineRecipe: Decodable {
    struct Source: Decodable {
        var name: String
        var url: String
        var sha256: String
        var file: String { URL(string: url)?.lastPathComponent ?? name }
    }

    var version: String
    var sources: [Source]
    /// The archive's platform: wine-<version>-staging-<platform>.tar.zst.
    var platform: String
    var configure: [String]
    /// apt's packages to build it (wine-build --apt).
    var buildPackages: [String]
    /// What a container that runs it installs (the windows layer's list).
    var runtimePackages: [String]
    /// What the checks need besides (wine-check --apt).
    var checkPackages: [String]

    /// The release's tag, which Shireworks lists (a suffixed tag maps to main).
    var tag: String { "wine-\(version)-staging" }
    var archiveName: String { "\(tag)-\(platform).tar.zst" }
    /// The `wine --version` it must answer.
    var versionLine: String { "wine-\(version) (Staging)" }

    func source(_ name: String) throws -> Source {
        guard let source = sources.first(where: { $0.name == name }) else {
            throw CheckFailure("sdk/wine/wine.json has no source named \(name)")
        }
        return source
    }

    /// The recipe at `path`, its URLs' `{version}` and `{major}` (11.21's
    /// 11) filled in: a new version is its "version" and the sources'
    /// sha256s.
    static func load(_ path: String) throws -> WineRecipe {
        var recipe = try JSONDecoder().decode(WineRecipe.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let major = String(recipe.version.prefix { $0 != "." })
        for index in recipe.sources.indices {
            recipe.sources[index].url = recipe.sources[index].url
                .replacingOccurrences(of: "{version}", with: recipe.version).replacingOccurrences(of: "{major}", with: major)
        }
        for name in ["wine", "staging", "llvm-mingw"] { _ = try recipe.source(name) }
        for source in recipe.sources where !(source.sha256.count == 64 && source.sha256.allSatisfy(\.isHexDigit)) {
            throw CheckFailure("\(path): \(source.name)'s sha256 is no sha256")
        }
        return recipe
    }
}

struct WineRecipeOptions: ParsableArguments {
    @Option(help: "The recipe: the version, its sources by URL and sha256, the configure line, the packages.")
    var recipe: String = "sdk/wine/wine.json"

    func load() throws -> WineRecipe { try WineRecipe.load(recipe) }
}

// MARK: Helpers the Wine commands share

enum Wine {
    /// A PATH of the system's directories alone, with `first` before them:
    /// Wine's configure and make see no other toolchain than the system's and
    /// llvm-mingw's (swift.org's toolchain, which built sdk-check, has a clang).
    static func systemPath(first: [String] = []) -> String {
        (first + ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]).joined(separator: ":")
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// A file's SHA-256, by coreutils' sha256sum.
    static func sha256(_ path: String) throws -> String {
        let output = try runChecked("/usr/bin/env", ["sha256sum", path])
        let sha = String(output.prefix { $0 != " " })
        guard sha.count == 64 else { throw CheckFailure("sha256sum \(path) said \(output)") }
        return sha
    }

    /// The first field of a `.sha256` file (sha256sum's format).
    static func recordedSHA256(_ path: String) throws -> String {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let sha = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw CheckFailure("\(path) holds no sha256") }
        return sha
    }

    /// Runs `command` (found on its environment's PATH), its output and
    /// errors written to `log` as they come, the command at its top. Fails
    /// naming the log, with its last lines, when the command fails.
    static func logged(_ command: [String], log: String, in directory: String? = nil,
                       environment: [String: String]) throws {
        try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let header = "$ \(command.joined(separator: " "))\(directory.map { "   (in \($0))" } ?? "")\n"
        if !FileManager.default.fileExists(atPath: log) { _ = FileManager.default.createFile(atPath: log, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(header.utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let started = Date()
        print("  \(command.prefix(3).joined(separator: " "))\(command.count > 3 ? " …" : "") > \(log)")
        fflush(nil)
        try process.run()
        process.waitUntilExit()
        let footer = "(exit \(process.terminationStatus), \(Int(Date().timeIntervalSince(started))) s)\n"
        try handle.write(contentsOf: Data(footer.utf8))
        try handle.close()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: log))) ?? Data(), as: UTF8.self)
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
            throw CheckFailure("\(command.joined(separator: " ")) failed (exit \(process.terminationStatus)); the end of \(log):\n\(tail)")
        }
    }

    /// apt's packages installed (the job runs as root), its output in `log`.
    static func aptInstall(_ packages: [String], log: String) throws {
        var environment = Self.environment
        environment["DEBIAN_FRONTEND"] = "noninteractive"
        try logged(["apt-get", "update"], log: log, environment: environment)
        try logged(["apt-get", "install", "-y", "--no-install-recommends"] + packages, log: log, environment: environment)
    }

    /// A source downloaded to `directory` and checked by its sha256; one
    /// already there with that sha256 is kept.
    static func fetch(_ source: WineRecipe.Source, into directory: String, log: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(source.file)"
        if FileManager.default.fileExists(atPath: path), (try? sha256(path)) == source.sha256 {
            print("  \(source.file): there already, sha256 \(source.sha256)")
            return path
        }
        try logged(["curl", "-fsSL", "--retry", "3", "-o", path, source.url], log: log, environment: environment)
        let sha = try sha256(path)
        guard sha == source.sha256 else {
            throw CheckFailure("\(source.url): sha256 \(sha), not the recipe's \(source.sha256)")
        }
        print("  \(source.file): sha256 \(sha), the recipe's")
        return path
    }

    /// llvm-mingw unpacked at `directory` (its arm64 Windows compilers in
    /// bin/), unless it is there already.
    static func llvmMingw(_ recipe: WineRecipe, at directory: String, downloads: String, log: String) throws -> String {
        let clang = "\(directory)/bin/aarch64-w64-mingw32-clang"
        if FileManager.default.isExecutableFile(atPath: clang) { return clang }
        let archive = try fetch(try recipe.source("llvm-mingw"), into: downloads, log: log)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try logged(["tar", "-xf", archive, "-C", directory, "--strip-components=1"], log: log, environment: environment)
        guard FileManager.default.isExecutableFile(atPath: clang) else { throw CheckFailure("llvm-mingw has no \(clang)") }
        return clang
    }

    /// The machine it runs on, for logs: "Ubuntu 26.04.1 LTS aarch64".
    static func machine() -> String {
        let release = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        let pretty = release.split(separator: "\n").first { $0.hasPrefix("PRETTY_NAME=") }
            .map { String($0.dropFirst("PRETTY_NAME=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? "Linux"
        let arch = (try? runChecked("/usr/bin/env", ["uname", "-m"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        return "\(pretty) \(arch)"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: wine-build

/// The recipe's Wine built and packed: wine-<version>-staging-<platform>.tar.zst
/// (`tar -C <root>/opt wine`, zstd -19) and its .sha256, in `--out`. As
/// AttilaTheFun/nimbus's tools/images/wine/Dockerfile built it (the release
/// wine-11.21-staging, by hand): Staging's every patch
/// (`patchinstall.py --all --backend=patch`), the recipe's configure line,
/// llvm-mingw for Wine's arm64 PE side, then `make install` into a
/// directory of its own (DESTDIR), so the job's /opt/wine is the checks'
/// alone, unpacked from the archive. share/doc/wine in it has BUILD-INFO
/// (the sources, the configure line, the machine and the run) and Wine's
/// LICENSE, COPYING.LIB and AUTHORS. Each step's output is a log in `--logs`.
struct WineBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine-build",
        abstract: "Builds the recipe's Wine Staging (sdk/wine/wine.json) and packs /opt/wine as wine-<version>-staging-<platform>.tar.zst with its .sha256."
    )

    @OptionGroup var recipeOptions: WineRecipeOptions

    @Option(help: "Where the sources are fetched, unpacked and built.")
    var work: String = "/tmp/wine-build"

    @Option(help: "Where the archive and its .sha256 go.")
    var out: String

    @Option(help: "Where each step's log goes (apt, fetch, patch, configure, make, install, pack).")
    var logs: String

    @Option(help: "Where llvm-mingw is unpacked (kept there for wine-check's arm64 hello world).")
    var llvmMingw: String = "/opt/llvm-mingw"

    @Option(help: "make's jobs (the machine's CPUs by default).")
    var jobs: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(help: "Install the recipe's build packages with apt first (the job's container runs as root).")
    var apt = false

    func run() throws {
        let recipe = try recipeOptions.load()
        let version = recipe.version
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: out, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: work, withIntermediateDirectories: true)
        print("wine-build: Wine \(version) with Staging, \(recipe.archiveName), on \(Wine.machine()), \(jobs) jobs")

        if apt {
            print("apt: the build packages")
            try Wine.aptInstall(recipe.buildPackages, log: "\(logs)/apt.log")
        }

        print("sources, by sha256:")
        let downloads = "\(work)/downloads"
        let wineArchive = try Wine.fetch(try recipe.source("wine"), into: downloads, log: "\(logs)/fetch.log")
        let stagingArchive = try Wine.fetch(try recipe.source("staging"), into: downloads, log: "\(logs)/fetch.log")
        let clang = try Wine.llvmMingw(recipe, at: llvmMingw, downloads: downloads, log: "\(logs)/fetch.log")

        // The sources afresh: a tree patched before isn't patched again.
        let source = "\(work)/wine-\(version)", staging = "\(work)/wine-staging-\(version)", root = "\(work)/root"
        for directory in [source, staging, root] { try? fileManager.removeItem(atPath: directory) }
        try Wine.logged(["tar", "-xf", wineArchive, "-C", work], log: "\(logs)/fetch.log", environment: Wine.environment)
        try Wine.logged(["tar", "-xf", stagingArchive, "-C", work], log: "\(logs)/fetch.log", environment: Wine.environment)
        guard fileManager.fileExists(atPath: "\(source)/configure"), fileManager.fileExists(atPath: "\(staging)/staging/patchinstall.py") else {
            throw CheckFailure("the sources didn't unpack as wine-\(version)/ and wine-staging-\(version)/ in \(work)")
        }

        var environment = Wine.environment
        environment["PATH"] = Wine.systemPath(first: ["\(llvmMingw)/bin"])
        environment["DEBIAN_FRONTEND"] = "noninteractive"
        print("Staging's patches (all of them):")
        try Wine.logged(["python3", "\(staging)/staging/patchinstall.py", "--destdir=\(source)", "--all", "--backend=patch"],
                        log: "\(logs)/patch.log", in: work, environment: environment)
        // Staging's AF_UNIX sockets, what the release is for (SwiftNIO's
        // event loop on Windows).
        guard fileManager.fileExists(atPath: "\(source)/include/afunix.h") else {
            throw CheckFailure("Staging's patches left no include/afunix.h: its AF_UNIX sockets are missing")
        }

        print("configure, make, install (\(recipe.configure.joined(separator: " "))):")
        try Wine.logged(["./configure"] + recipe.configure, log: "\(logs)/configure.log", in: source, environment: environment)
        let started = Date()
        try Wine.logged(["make", "-j\(jobs)"], log: "\(logs)/make.log", in: source, environment: environment)
        print("  make took \(Int(Date().timeIntervalSince(started)) / 60) min")
        try Wine.logged(["make", "install", "DESTDIR=\(root)"], log: "\(logs)/install.log", in: source, environment: environment)
        let prefix = recipe.configure.first { $0.hasPrefix("--prefix=") }.map { String($0.dropFirst("--prefix=".count)) } ?? "/usr/local"
        let installed = root + prefix
        guard fileManager.isExecutableFile(atPath: "\(installed)/bin/wine") else { throw CheckFailure("make install left no \(installed)/bin/wine") }

        // Wine is LGPL-2.1-or-later: its licence, and what it was built
        // from, inside the archive.
        let docs = "\(installed)/share/doc/wine"
        try fileManager.createDirectory(atPath: docs, withIntermediateDirectories: true)
        for name in ["LICENSE", "COPYING.LIB", "AUTHORS"] {
            try? fileManager.removeItem(atPath: "\(docs)/\(name)")
            try fileManager.copyItem(atPath: "\(source)/\(name)", toPath: "\(docs)/\(name)")
        }
        try buildInfo(recipe, clang: clang).write(toFile: "\(docs)/BUILD-INFO", atomically: true, encoding: .utf8)

        // Packed as the windows layer unpacks it (`tar -xf - -C /opt`): one
        // top directory, wine/, its names sorted and owned by root.
        let archive = "\(out)/\(recipe.archiveName)"
        try? fileManager.removeItem(atPath: archive)
        let parent = (installed as NSString).deletingLastPathComponent, top = (installed as NSString).lastPathComponent
        print("pack:")
        try Wine.logged(["tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner", "--use-compress-program=zstd -19 -T0",
                         "-C", parent, "-cf", archive, top], log: "\(logs)/pack.log", environment: Wine.environment)
        let sha = try Wine.sha256(archive)
        try "\(sha)  \(recipe.archiveName)\n".write(toFile: "\(archive).sha256", atomically: true, encoding: .utf8)
        let size = (try fileManager.attributesOfItem(atPath: archive)[.size] as? NSNumber)?.intValue ?? 0
        print("PASS wine-build: \(archive), \(size) bytes, sha256 \(sha)")
    }

    /// share/doc/wine/BUILD-INFO: the sources, the configure line, where and
    /// by what it was built.
    func buildInfo(_ recipe: WineRecipe, clang: String) throws -> String {
        let wine = try recipe.source("wine"), staging = try recipe.source("staging"), mingw = try recipe.source("llvm-mingw")
        let environment = Wine.environment
        var lines = [
            "Wine \(recipe.version) (\(wine.url), sha256 \(wine.sha256))",
            "Wine Staging v\(recipe.version), every patch (patchinstall.py --all --backend=patch) (\(staging.url), sha256 \(staging.sha256))",
            "llvm-mingw for the PE side (\(mingw.url), sha256 \(mingw.sha256)): \((try? runChecked(clang, ["--version"]))?.split(separator: "\n").first.map(String.init) ?? "?")",
            "configure \(recipe.configure.joined(separator: " "))",
            "built on \(Wine.machine()), \(Wine.timestamp().prefix(10))",
        ]
        if let repository = environment["GITHUB_REPOSITORY"], let run = environment["GITHUB_RUN_ID"] {
            lines.append("by sdk-check wine-build in \(repository)'s run \(run) at \(environment["GITHUB_SHA"] ?? "?") (sdk/wine/wine.json)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
