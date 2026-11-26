import ArgumentParser
import Foundation

/// A Wine release's proof, in Reviews' format 2 (AttilaTheFun/reviews'
/// docs/PROOF_FORMAT.md), from wine-check's --out: proof.json, the checks'
/// logs and Notepad's picture, zipped as proof.zip. Its items, under the ids
/// the first release (wine-11.21-staging) has, so build_tools' proof-diff
/// compares them from release to release:
///
///   wine/archive-sha256, wine/version, wine/wineboot, wine/cmd-echo,
///   wine/hello-arm64   tests items, a check each, with its log
///   wine/notepad       a screen item, screens/wine/notepad.png
///
/// Its version is the release's tag (wine-<version>-staging), as the first
/// one's; its commit main's head (the draft's target, which Reviews takes as
/// the release's commit), asked of GitHub unless --commit names it.
struct WineProof: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine-proof",
        abstract: "Makes a Wine release's proof (Reviews' format 2: proof.json, the checks' logs and Notepad's picture, zipped as proof.zip) from wine-check's results."
    )

    @OptionGroup var recipeOptions: WineRecipeOptions

    @Option(help: "wine-check's --out: checks.json, logs/, screens/.")
    var checks: String

    @Option(help: "Where proof.json, logs/, screens/ and proof.zip go (the directory is replaced).")
    var out: String

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The commit it is a proof of, the draft's target (by default --branch's head, asked of GitHub).")
    var commit: String?

    @Option(help: "The branch whose head is the commit: a suffixed tag (wine-<version>-staging) is main's to Shireworks.")
    var branch: String = "main"

    @Option(name: .customLong("run"), help: "The run that made it (GITHUB_RUN_ID by default).")
    var runID: String = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""

    @Option(help: "GitHub's REST API.")
    var api: String = "https://api.github.com"

    /// The items, in the order Reviews shows them: each one's check (its id
    /// wine/<check>) and kind.
    static let items: [(check: String, kind: String)] = [
        ("archive-sha256", "tests"), ("version", "tests"), ("wineboot", "tests"), ("cmd-echo", "tests"), ("hello-arm64", "tests"), ("notepad", "screen"),
    ]

    func run() throws {
        let recipe = try recipeOptions.load()
        guard repository.contains("/") else { throw CheckFailure("no repository (--repository or GITHUB_REPOSITORY)") }
        let environment = ProcessInfo.processInfo.environment
        let github = GitHub(api: api, uploads: "", repository: repository, token: environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"])
        let commit = try self.commit ?? github.head(of: branch)
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw CheckFailure("\(commit) is no commit sha") }

        let records = try JSONDecoder().decode([WineCheckRecord].self, from: Data(contentsOf: URL(fileURLWithPath: "\(checks)/checks.json")))
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: out)
        try fileManager.createDirectory(atPath: "\(out)/logs", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: "\(out)/screens/wine", withIntermediateDirectories: true)

        var items: [[String: Any]] = []
        for (check, kind) in Self.items {
            guard let record = records.first(where: { $0.name == check }) else { throw CheckFailure("\(checks)/checks.json has no \(check): wine-check didn't run it") }
            let id = "wine/\(check)"
            if kind == "screen" {
                // A screen item has no result: a picture, or no proof.
                let picture = "\(checks)/screens/\(check).png", file = "screens/wine/\(check).png"
                guard record.passed, fileManager.fileExists(atPath: picture) else {
                    throw CheckFailure("\(id): no picture (\(record.failure ?? "\(picture) missing"))")
                }
                try fileManager.copyItem(atPath: picture, toPath: "\(out)/\(file)")
                let (width, height) = try Self.pngSize("\(out)/\(file)")
                items.append(["id": id, "kind": "screen", "title": record.title, "file": file,
                              "sha256": try Wine.sha256("\(out)/\(file)"), "width": width, "height": height])
            } else {
                let log = "logs/\(check).txt"
                try fileManager.copyItem(atPath: "\(checks)/\(record.log)", toPath: "\(out)/\(log)")
                items.append(["id": id, "kind": "tests", "title": record.title, "result": record.passed ? "passed" : "failed",
                              "tests": 1, "failures": record.passed ? 0 : 1, "log": log])
            }
        }
        let json: [String: Any] = [
            "format": 2,
            "app": "isomer_hermetic_toolchains",
            "version": recipe.tag,
            "repository": repository,
            "commit": commit,
            "run": Int(runID) ?? 0,
            "made": Wine.timestamp(),
            "items": items,
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: "\(out)/proof.json"))
        _ = try runChecked("/usr/bin/env", ["sh", "-c", "cd \"$0\" && zip -q -r -X proof.zip proof.json logs screens", out])
        let failed = items.filter { $0["kind"] as? String == "tests" && $0["result"] as? String != "passed" }
        print("wine-proof: \(recipe.tag) at \(commit) (\(branch)'s head\(self.commit == nil ? "" : ", as given")): \(items.count) items, \(failed.count) failed, in \(out)/proof.zip")
        for item in items {
            print("  \(item["id"] as? String ?? "") \(item["result"] as? String ?? "\(item["width"] ?? 0)x\(item["height"] ?? 0) sha256 \(item["sha256"] ?? "")")")
        }
    }

    /// A PNG's width and height, from its IHDR (bytes 16 to 24).
    static func pngSize(_ path: String) throws -> (Int, Int) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw CheckFailure("\(path) is no PNG") }
        func big(_ offset: Int) -> Int { data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (big(data.startIndex + 16), big(data.startIndex + 20))
    }
}

extension GitHub {
    /// A branch's head commit.
    func head(of branch: String) throws -> String {
        let data = try send("GET", "\(api)/repos/\(repository)/commits/\(branch)")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let sha = object["sha"] as? String else {
            throw CheckFailure("GitHub gave no commit for \(repository)'s \(branch)")
        }
        return sha
    }
}
