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

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The commit the release is of (GITHUB_SHA by default).")
    var commit: String = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""

    @Option(name: .customLong("run"), help: "The run that built it (GITHUB_RUN_ID by default).")
    var runID: String = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""

    @Option(help: "The release line, the Swift release the SDKs are (sdk/build.sh's SWIFT_VERSION by default).")
    var line: String?

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
        let version = Self.version(line: line, commit: commit, releases: releases, tags: tags)
        let tag = "isomer-\(version)"
        print("draft: \(tag) on \(commit), \(built.count) SDKs from \(assets)\(dryRun ? " (dry run)" : "")")
        let same = releases.filter { $0.tag_name == tag }
        if let published = same.first(where: { !$0.draft }) {
            throw CheckFailure("\(tag) is published (release \(published.id)): its SDKs aren't replaced (consumers pin their sha256)")
        }
        let previous = Self.previousRelease(line: line, before: version, releases: releases)
        let notes = try notes(version: version, tag: tag, built: built, previous: previous)

        if dryRun {
            for old in same { print("would delete the earlier draft \(old.id) of \(tag)") }
            print("would draft \(tag) on \(commit) and upload:")
            for sdk in built { print("  \(sdk.name) (sha256 \(sdk.sha256)) and \(sdk.name).sha256") }
            print("notes:")
            print(notes.split(separator: "\n", omittingEmptySubsequences: false).map { "  | \($0)" }.joined(separator: "\n"))
            return
        }
        // A draft of this tag from an earlier run of this commit goes.
        for old in same { try github.deleteRelease(old.id); print("deleted the earlier draft \(old.id) of \(tag)") }
        let release = try github.createDraft(tag: tag, commit: commit, name: "Isomer's Swift SDKs \(version)", notes: notes)
        for sdk in built {
            for (name, path) in [(sdk.name, sdk.path), ("\(sdk.name).sha256", "\(sdk.path).sha256")] {
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
    static func number(of tag: String, line: String) -> Int? {
        let prefix = "isomer-\(line)."
        guard tag.hasPrefix(prefix), let n = Int(tag.dropFirst(prefix.count)), n >= 0 else { return nil }
        return n
    }

    /// `<line>.N`: this commit's release's N, else one past the highest.
    static func version(line: String, commit: String, releases: [GitHub.Release], tags: [String]) -> String {
        let numbered = releases.compactMap { release in number(of: release.tag_name, line: line).map { (release, $0) } }
        if let mine = numbered.filter({ $0.0.target_commitish == commit }).map(\.1).max() {
            return "\(line).\(mine)"
        }
        let highest = (numbered.map(\.1) + tags.compactMap { number(of: $0, line: line) }).max() ?? 0
        return "\(line).\(highest + 1)"
    }

    /// The latest published release of the line before this one.
    static func previousRelease(line: String, before version: String, releases: [GitHub.Release]) -> String? {
        let mine = Int(version.split(separator: ".").last ?? "") ?? 0
        return releases.filter { !$0.draft }
            .compactMap { release in number(of: release.tag_name, line: line).map { (release.tag_name, $0) } }
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
        let names = try FileManager.default.contentsOfDirectory(atPath: assets).sorted()
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

    func notes(version: String, tag: String, built: [SDK], previous: String?) throws -> String {
        let base = "https://github.com/\(repository)/releases/download/\(tag)"
        var lines = [
            "Isomer's Swift SDKs \(version): Swift \(version.split(separator: ".").prefix(3).joined(separator: "."))'s Android and WebAssembly SDKs with Isomer's Foundation in place of corelibs', proposed for release by run \(runID) on \(commit).",
            "",
            "The Android SDKs' minimum is API 23 (aarch64, x86_64 and armv7), the lowest triple of their swift-sdk.json.",
            "",
            "## Checks",
            "",
            "Every SDK, in its build (sdk/build.sh, sdk/check): a client package built and linked against it; `autolink` (every module's importers autolink its library), `pairing` (each module's binary interface and archive from one build) and `undefined` (every archive's symbols resolve at the SDK's minimum) for each architecture.",
        ]
        let results = try resultLines()
        if !results.isEmpty {
            lines += ["", "The run's results:", ""] + results.map { "- \($0)" }
        }
        lines += ["", "## SHA-256", "", "| SDK | SHA-256 |", "| --- | --- |"]
        lines += built.map { "| `\($0.name)` | `\($0.sha256)` |" }
        lines += [
            "",
            "## Registering them",
            "",
            "A consumer's MODULE.bazel registers one SDK a platform, in its `swift` block. The plain SDKs link no ICU; an app that formats dates, numbers or lists with Foundation takes the -i18n one, whose Foundation has FoundationInternationalization and the SDK's ICU.",
            "",
            "```starlark",
        ]
        for sdk in built {
            let rule = sdk.name.contains("_android") ? "android_sdk" : "wasm_sdk"
            lines.append("swift.\(rule)(url = \"\(base)/\(sdk.name)\", sha256 = \"\(sdk.sha256)\")")
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
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
