import ArgumentParser
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The draft release a release run makes (isomer_sdk.yml's `run: release`,
/// dispatched by hand on an `isomer-<Swift version>` branch), as isomer's
/// own release runs do (its tools/ci/version_from_tags.sh and
/// draft_release.sh): tag `isomer-<line>.<N>`, which publishing the draft in
/// Reviews makes (no agent publishes a draft or makes a tag), on the run's
/// commit, with the four SDKs and their .sha256 files.
///
/// N is the version of a release already made on this commit (the same
/// commit proposed again: its draft, found by its target_commitish, is
/// replaced), else one past the highest `isomer-<line>.N` among the
/// repository's releases (a draft has its tag's name before its tag) and
/// tags. A published release of that tag is never replaced: consumers pin
/// its sha256.
///
/// The notes: the run and commit, the checks the run passed (sdk/check's on
/// every SDK; the consumer's, from `--results`), each SDK's SHA-256, the
/// lines a consumer's MODULE.bazel registers them with, and the commits
/// since the release before. GitHub's REST API by URLSession, with
/// GITHUB_TOKEN (or GH_TOKEN): the job's, whose `contents: write` lists
/// drafts and makes them. `--dry-run` reads and says what it would write.
struct Draft: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drafts the release of a release run: its version from the repository's releases and tags, the SDKs and their checksums, the notes."
    )

    @Option(help: "The directory of the built SDKs: each <name>.artifactbundle.tar.gz with its .sha256.")
    var assets: String

    @Option(help: "A directory of the run's check results (*.txt, a check a line, as sdk/build.sh and tools/ci/sdk_smoke print them).")
    var results: String?

    @Option(help: "The run's proof (sdk-check proof's --out: proof.json, proof.zip, and proof-diff.json if build_tools' proof-diff made one), attached to the draft.")
    var proof: String?

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The commit the release is of (GITHUB_SHA by default).")
    var commit: String = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""

    @Option(name: .customLong("run"), help: "The run that built it (GITHUB_RUN_ID by default).")
    var runID: String = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""

    @Option(help: "The release line, the Swift release the SDKs are (sdk/build.sh's SWIFT_VERSION by default).")
    var line: String?

    @Option(help: "The tags' prefix: a release is <prefix><line>.N.")
    var tagPrefix: String = "isomer-"

    @Option(help: "The checkout, for sdk/build.sh's SWIFT_VERSION and the commits since the last release.")
    var checkout: String = "."

    @Option(help: "GitHub's REST API.")
    var api: String = "https://api.github.com"

    @Option(help: "GitHub's upload endpoint for release assets.")
    var uploads: String = "https://uploads.github.com"

    @Flag(help: "Read and check, and say what would be written, writing nothing.")
    var dryRun = false

    func run() throws {
        guard repository.contains("/") else { throw CheckFailure("no repository (--repository or GITHUB_REPOSITORY)") }
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw CheckFailure("no commit sha (--commit or GITHUB_SHA)") }
        let environment = ProcessInfo.processInfo.environment
        let token = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"]
        guard dryRun || token != nil else { throw CheckFailure("no GITHUB_TOKEN or GH_TOKEN to draft with") }
        let github = GitHub(api: api, uploads: uploads, repository: repository, token: token)
        let line = try self.line ?? Self.swiftVersion(inBuildScript: "\(checkout)/sdk/build.sh")

        let built = try builtSDKs()
        let releases = try github.releases()
        let tags = try github.tags()
        let version = Self.version(prefix: tagPrefix, line: line, commit: commit, releases: releases, tags: tags)
        let tag = "\(tagPrefix)\(version)"
        print("draft: \(tag) on \(commit), \(built.count) SDKs from \(assets)\(dryRun ? " (dry run)" : "")")
        let same = releases.filter { $0.tag_name == tag }
        if let published = same.first(where: { !$0.draft }) {
            throw CheckFailure("\(tag) is published (release \(published.id)): its SDKs aren't replaced (consumers pin their sha256)")
        }
        let previous = Self.previousRelease(prefix: tagPrefix, line: line, before: version, releases: releases)
        // The proof (sdk-check proof, and build_tools' proof-diff beside it),
        // which Reviews' Release waits for: of this version and commit, and
        // passed, or no draft.
        var proof: DraftProof?
        if let proofDirectory = self.proof {
            let loaded = try DraftProof(directory: proofDirectory)
            guard loaded.version == version, loaded.commit == commit else {
                throw CheckFailure("the proof in \(proofDirectory) is of \(loaded.version) at \(loaded.commit), not \(version) at \(commit)")
            }
            if let failed = loaded.failed.first { throw CheckFailure("the proof's \(failed) failed: no draft") }
            proof = loaded
            print("proof: \(loaded.items) tests items, \(loaded.tests) checks\(loaded.diff == nil ? "" : ", and proof-diff.json")")
        }
        let notes = try notes(version: version, tag: tag, built: built, previous: previous, proof: proof)

        if dryRun {
            for old in same { print("would delete the earlier draft \(old.id) of \(tag) (on \(old.target_commitish))") }
            print("would draft \(tag) on \(commit) and upload:")
            for sdk in built { print("  \(sdk.name) (sha256 \(sdk.sha256)) and \(sdk.name).sha256") }
            if let proof { print("  proof.zip\(proof.diff == nil ? "" : " and proof-diff.json")") }
            print("notes:")
            print(notes.split(separator: "\n", omittingEmptySubsequences: false).map { "  | \($0)" }.joined(separator: "\n"))
            return
        }
        // A draft of this tag goes, from an earlier run of this commit or of
        // another (a draft is no release until it is published).
        for old in same { try github.deleteRelease(old.id); print("deleted the earlier draft \(old.id) of \(tag) (on \(old.target_commitish))") }
        let release = try github.createDraft(tag: tag, commit: commit, name: "Isomer's Swift SDKs \(version)", notes: notes)
        for sdk in built {
            for (name, path) in [(sdk.name, sdk.path), ("\(sdk.name).sha256", "\(sdk.path).sha256")] {
                try github.uploadAsset(release.id, name: name, path: path)
                print("  uploaded \(name)")
            }
        }
        if let proof {
            for (name, path) in [("proof.zip", proof.zip)] + (proof.diff.map { [("proof-diff.json", $0)] } ?? []) {
                try github.uploadAsset(release.id, name: name, path: path)
                print("  uploaded \(name)")
            }
        }
        print("drafted \(tag) (release \(release.id)): published in Reviews, which makes its tag")
    }

    // MARK: The version

    static func swiftVersion(inBuildScript path: String) throws -> String {
        let script = try String(contentsOfFile: path, encoding: .utf8)
        guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("SWIFT_VERSION=") }) else {
            throw CheckFailure("\(path) sets no SWIFT_VERSION")
        }
        return String(line.dropFirst("SWIFT_VERSION=".count))
    }

    /// N of `isomer-<line>.N`, if `tag` is one.
    static func number(of tag: String, prefix tagPrefix: String, line: String) -> Int? {
        let prefix = "\(tagPrefix)\(line)."
        guard tag.hasPrefix(prefix), let n = Int(tag.dropFirst(prefix.count)), n >= 0 else { return nil }
        return n
    }

    /// `<line>.N`: this commit's release's N (a draft of it made before),
    /// else one past the highest *published* release or tag: a draft has no
    /// tag yet and is replaced, so an unpublished isomer-6.4.2.2 of another
    /// commit leaves this one 6.4.2.2 too, not 6.4.2.3.
    static func version(prefix: String, line: String, commit: String, releases: [GitHub.Release], tags: [String]) -> String {
        let numbered = releases.compactMap { release in number(of: release.tag_name, prefix: prefix, line: line).map { (release, $0) } }
        if let mine = numbered.filter({ $0.0.target_commitish == commit }).map(\.1).max() {
            return "\(line).\(mine)"
        }
        let published = numbered.filter { !$0.0.draft }.map(\.1)
        let highest = (published + tags.compactMap { number(of: $0, prefix: prefix, line: line) }).max() ?? 0
        return "\(line).\(highest + 1)"
    }

    /// The latest published release of the line before this one.
    static func previousRelease(prefix: String, line: String, before version: String, releases: [GitHub.Release]) -> String? {
        let mine = Int(version.split(separator: ".").last ?? "") ?? 0
        return releases.filter { !$0.draft }
            .compactMap { release in number(of: release.tag_name, prefix: prefix, line: line).map { (release.tag_name, $0) } }
            .filter { $0.1 < mine }.max { $0.1 < $1.1 }?.0
    }

    // MARK: The SDKs built

    struct SDK {
        var name: String
        var path: String
        var sha256: String
    }

    /// Every archive in `assets` with its checksum file, and nothing else.
    func builtSDKs() throws -> [SDK] {
        // The plain SDK before its -i18n one, and wasm's threads SDK last.
        func key(_ name: String) -> String {
            name.replacingOccurrences(of: "-i18n", with: "~").replacingOccurrences(of: "-threads", with: "~~")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: assets).sorted { key($0) < key($1) }
        var sdks: [SDK] = []
        for name in names where name.hasSuffix(".tar.gz") {
            let checksum = "\(assets)/\(name).sha256"
            guard FileManager.default.fileExists(atPath: checksum) else { throw CheckFailure("\(name) has no \(name).sha256 beside it") }
            let text = try String(contentsOfFile: checksum, encoding: .utf8)
            let sha = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw CheckFailure("\(checksum) holds no sha256") }
            sdks.append(SDK(name: name, path: "\(assets)/\(name)", sha256: sha))
        }
        for name in names where name.hasSuffix(".sha256") && !names.contains(String(name.dropLast(".sha256".count))) {
            throw CheckFailure("\(name) has no archive beside it")
        }
        guard !sdks.isEmpty else { throw CheckFailure("no SDKs (*.tar.gz with their .sha256) in \(assets)") }
        return sdks
    }

    // MARK: The notes

    func notes(version: String, tag: String, built: [SDK], previous: String?, proof: DraftProof? = nil) throws -> String {
        let base = "https://github.com/\(repository)/releases/download/\(tag)"
        var lines = [
            "Isomer's Swift SDKs \(version): Swift \(version.split(separator: ".").prefix(3).joined(separator: "."))'s Android and WebAssembly SDKs with Isomer's Foundation in place of corelibs', proposed for release by run \(runID) on \(commit).",
            "",
            "The Android SDKs' minimum is API 23 (aarch64, x86_64 and armv7), the lowest triple of their swift-sdk.json.",
            "",
            "The WebAssembly threads SDK (`…_wasm-threads`, plain: no ICU) targets wasm32-unknown-wasip1-threads: Swift's Concurrency on guest threads (swiftlang/swift#92018 on 6.4.2), C++ exceptions (the standard exnref proposal) in its libc++, and shared memory; its bundle also has the plain SDK's wasm32-unknown-wasip1 target. Its programs run on engines with WASI Threads and exception handling (WasmKit 0.5.0).",
            "",
            "## Checks",
            "",
            "Every SDK, in its build (sdk/build.sh, sdk/check): a client package built and linked against it; `autolink` (every module's importers autolink its library), `pairing` (each module's binary interface and archive from one build) and `undefined` (every archive's symbols resolve at the SDK's minimum) for each architecture.",
        ]
        let results = try resultLines()
        if !results.isEmpty {
            lines += ["", "The run's results:", ""] + results.map { "- \($0)" }
        }
        if let proof {
            lines += ["", "The proof, `proof.zip` (Reviews' format 2): \(proof.items) tests items (each SDK's targets, the consumer's cells, the emulator's), \(proof.tests) checks, all passed, each with its job's log\(proof.diff == nil ? "" : "; `proof-diff.json` compares it with the release before")."]
        }
        lines += ["", "## SHA-256", "", "| SDK | SHA-256 |", "| --- | --- |"]
        lines += built.map { "| `\($0.name)` | `\($0.sha256)` |" }
        lines += [
            "",
            "## Registering them",
            "",
            "A consumer's MODULE.bazel registers one SDK a platform, in its `swift` block (and wasm's threads SDK beside its plain or -i18n one, `threads = True`). The plain SDKs link no ICU; an app that formats dates, numbers or lists with Foundation takes the -i18n one, whose Foundation has FoundationInternationalization and the SDK's ICU.",
            "",
            "```starlark",
        ]
        for sdk in built {
            let rule = sdk.name.contains("_android") ? "android_sdk" : "wasm_sdk"
            // The threads SDK is a second wasm_sdk tag, beside the plain one.
            let threads = sdk.name.contains("_wasm-threads") ? "threads = True, " : ""
            lines.append("swift.\(rule)(\(threads)url = \"\(base)/\(sdk.name)\", sha256 = \"\(sdk.sha256)\")")
        }
        lines.append("```")
        if let previous, let log = try? runChecked("/usr/bin/git", ["-C", checkout, "log", "--first-parent", "--format=- %s", "\(previous)..\(commit)"]),
           !log.isEmpty {
            lines += ["", "## Changes since \(previous)", "", log.trimmingCharacters(in: .newlines)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The check results' lines (PASS lines and the like), each file's in order.
    func resultLines() throws -> [String] {
        guard let results else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: results).filter { $0.hasSuffix(".txt") }.sorted()
        return try names.flatMap { name in
            try String(contentsOfFile: "\(results)/\(name)", encoding: .utf8)
                .split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}

/// GitHub's REST API for releases, by URLSession.
struct GitHub {
    var api: String
    var uploads: String
    var repository: String
    var token: String?

    struct Release: Decodable {
        var id: Int
        var tag_name: String
        var target_commitish: String
        var draft: Bool
    }

    struct Tag: Decodable {
        var name: String
    }

    /// Every release, drafts included where the token may see them.
    func releases() throws -> [Release] {
        try paged("releases", as: Release.self)
    }

    func tags() throws -> [String] {
        try paged("tags", as: Tag.self).map(\.name)
    }

    func paged<T: Decodable>(_ path: String, as: T.Type) throws -> [T] {
        var all: [T] = []
        for page in 1... {
            let items = try JSONDecoder().decode([T].self, from: send("GET", "\(api)/repos/\(repository)/\(path)?per_page=100&page=\(page)"))
            all += items
            if items.count < 100 { break }
        }
        return all
    }

    func createDraft(tag: String, commit: String, name: String, notes: String) throws -> Release {
        let body = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "target_commitish": commit, "name": name, "body": notes, "draft": true, "prerelease": false,
        ] as [String: Any])
        return try JSONDecoder().decode(Release.self, from: send("POST", "\(api)/repos/\(repository)/releases", body: body))
    }

    func deleteRelease(_ id: Int) throws {
        _ = try send("DELETE", "\(api)/repos/\(repository)/releases/\(id)")
    }

    func uploadAsset(_ release: Int, name: String, path: String) throws {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        _ = try send("POST", "\(uploads)/repos/\(repository)/releases/\(release)/assets?name=\(query)",
                     file: path, contentType: "application/octet-stream")
    }

    final class Result: @unchecked Sendable {
        var data = Data()
        var status = 0
        var error: (any Error)?
    }

    func send(_ method: String, _ url: String, body: Data? = nil, file: String? = nil,
              contentType: String = "application/json") throws -> Data {
        guard let target = URL(string: url) else { throw CheckFailure("not a URL: \(url)") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 900
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("isomer-sdk-check", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil || file != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        let handler: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { data, response, error in
            result.data = data ?? Data()
            result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result.error = error
            done.signal()
        }
        let task: URLSessionTask
        if let file {
            task = URLSession.shared.uploadTask(with: request, fromFile: URL(fileURLWithPath: file), completionHandler: handler)
        } else if let body {
            task = URLSession.shared.uploadTask(with: request, from: body, completionHandler: handler)
        } else {
            task = URLSession.shared.dataTask(with: request, completionHandler: handler)
        }
        task.resume()
        done.wait()
        if let error = result.error { throw CheckFailure("\(method) \(url): \(error)") }
        guard (200..<300).contains(result.status) else {
            throw CheckFailure("\(method) \(url): HTTP \(result.status) \(String(decoding: result.data.prefix(500), as: UTF8.self))")
        }
        return result.data
    }
}

/// A proof as `sdk-check proof` leaves it (proof.json, proof.zip) with
/// build_tools' proof-diff.json beside it if made, read for the draft.
struct DraftProof {
    var version: String
    var commit: String
    var items: Int
    var tests: Int
    var failed: [String]
    var zip: String
    var diff: String?

    init(directory: String) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(directory)/proof.json")))
        guard let proof = json as? [String: Any], proof["format"] as? Int == 2, let items = proof["items"] as? [[String: Any]] else {
            throw CheckFailure("\(directory)/proof.json is no format-2 proof")
        }
        zip = "\(directory)/proof.zip"
        guard FileManager.default.fileExists(atPath: zip) else { throw CheckFailure("no proof.zip in \(directory)") }
        let diffPath = "\(directory)/proof-diff.json"
        diff = FileManager.default.fileExists(atPath: diffPath) ? diffPath : nil
        version = proof["version"] as? String ?? ""
        commit = proof["commit"] as? String ?? ""
        self.items = items.count
        tests = items.reduce(0) { $0 + ($1["tests"] as? Int ?? 0) }
        failed = items.filter { $0["result"] as? String != "passed" }.compactMap { $0["id"] as? String }
    }
}

/// The version a release run's draft will be (`sdk-check draft`'s), for the
/// proof made before it: `<line>.N`.
struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prints the version this commit's draft release will be (<Swift version>.N), as sdk-check draft numbers it."
    )

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The commit (GITHUB_SHA by default).")
    var commit: String = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""

    @Option(help: "The release line (sdk/build.sh's SWIFT_VERSION by default).")
    var line: String?

    @Option(help: "The checkout, for sdk/build.sh's SWIFT_VERSION.")
    var checkout: String = "."

    @Option(name: .customLong("releases"), help: "The releases as GitHub's API lists them, from a file, in place of asking (a rehearsal).")
    var releasesFile: String?

    @Option(name: .customLong("tags"), help: "The tags as GitHub's API lists them, from a file.")
    var tagsFile: String?

    @Option(help: "The tags' prefix: a release is <prefix><line>.N.")
    var tagPrefix: String = "isomer-"

    @Option(help: "GitHub's REST API.")
    var api: String = "https://api.github.com"

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let github = GitHub(api: api, uploads: "", repository: repository, token: environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"])
        let line = try self.line ?? Draft.swiftVersion(inBuildScript: "\(checkout)/sdk/build.sh")
        // The releases and tags as GitHub lists them, or from files (a rehearsal's).
        let releases = try releasesFile.map { try JSONDecoder().decode([GitHub.Release].self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
            ?? github.releases()
        let tags = try tagsFile.map { try JSONDecoder().decode([GitHub.Tag].self, from: Data(contentsOf: URL(fileURLWithPath: $0))).map(\.name) }
            ?? github.tags()
        print(Draft.version(prefix: tagPrefix, line: line, commit: commit, releases: releases, tags: tags))
    }
}
