import ArgumentParser
import Foundation

/// A Wine release's draft (isomer_sdk.yml's `run: wine`): tag
/// `wine-<version>-staging`, which Shireworks lists as main's (a suffixed
/// tag maps to main, and a draft is listed only if its target is on the
/// branch its tag implies), targeting the proof's commit, main's head when
/// the proof was made, and checked to be on main still. Its assets: the
/// archive and its .sha256, proof.zip and proof-diff.json (build_tools'
/// proof-diff, against the last published wine-* release). Its notes: the
/// sources by URL and sha256, the configure line, the archive's size and
/// sha256, the proof's items and its comparison, and the lines the windows
/// layer pins it with.
///
/// A draft of the tag already there (an earlier run's) is updated, never a
/// second made: its fields set again (every PATCH names tag_name, as a
/// PATCH without it once reset a draft's tag to untagged-…), its assets
/// replaced. A published release of the tag is never touched: the windows
/// layer pins its sha256. New Container Helper checks the draft; the owner
/// publishes it in Reviews, which makes its tag. `--dry-run` reads GitHub
/// and says what it would do, writing nothing.
struct WineDraft: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine-draft",
        abstract: "Drafts a Wine release (wine-<version>-staging, on main) with the archive, its .sha256, proof.zip and proof-diff.json."
    )

    @OptionGroup var recipeOptions: WineRecipeOptions

    @Option(help: "The directory of wine-build's archive and its .sha256.")
    var assets: String

    @Option(help: "wine-proof's --out: proof.json, proof.zip, and proof-diff.json if build_tools' proof-diff made one.")
    var proof: String

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The branch the target must be on: main, which a suffixed tag implies.")
    var branch: String = "main"

    @Option(name: .customLong("run"), help: "The run that built it (GITHUB_RUN_ID by default).")
    var runID: String = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""

    @Option(help: "GitHub's REST API.")
    var api: String = "https://api.github.com"

    @Option(help: "GitHub's upload endpoint for release assets.")
    var uploads: String = "https://uploads.github.com"

    @Flag(help: "Read and check, and say what would be written, writing nothing.")
    var dryRun = false

    func run() throws {
        let recipe = try recipeOptions.load()
        guard repository.contains("/") else { throw CheckFailure("no repository (--repository or GITHUB_REPOSITORY)") }
        let environment = ProcessInfo.processInfo.environment
        let token = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"]
        guard dryRun || token != nil else { throw CheckFailure("no GITHUB_TOKEN or GH_TOKEN to draft with") }
        let github = GitHub(api: api, uploads: uploads, repository: repository, token: token)
        let tag = recipe.tag

        // The archive, checked against its .sha256.
        let archive = "\(assets)/\(recipe.archiveName)"
        guard FileManager.default.fileExists(atPath: archive) else { throw CheckFailure("no \(recipe.archiveName) in \(assets)") }
        let sha = try Wine.recordedSHA256("\(archive).sha256")
        guard try Wine.sha256(archive) == sha else { throw CheckFailure("\(archive)'s sha256 isn't its .sha256's") }
        let size = (try FileManager.default.attributesOfItem(atPath: archive)[.size] as? NSNumber)?.intValue ?? 0

        // The proof: of this tag, every tests item passed, and its commit on main.
        let proof = try WineDraftProof(directory: self.proof)
        guard proof.version == tag else { throw CheckFailure("the proof in \(self.proof) is of \(proof.version), not \(tag)") }
        if let failed = proof.failed.first { throw CheckFailure("the proof's \(failed) failed: no draft") }
        let status = try github.compare(proof.commit, branch)
        guard status == "identical" || status == "ahead" else {
            throw CheckFailure("the proof's commit \(proof.commit) isn't on \(branch) (\(branch) is \(status) of it): Shireworks wouldn't list the draft")
        }
        let commit = proof.commit
        print("wine-draft: \(tag) on \(commit) (on \(branch): \(status)), \(recipe.archiveName) \(size) bytes sha256 \(sha)\(dryRun ? " (dry run)" : "")")

        let releases = try github.releases()
        let same = releases.filter { $0.tag_name == tag }
        if let published = same.first(where: { !$0.draft }) {
            throw CheckFailure("\(tag) is published (release \(published.id)): its archive isn't replaced (the windows layer pins its sha256)")
        }
        let notes = try notes(recipe: recipe, commit: commit, archiveSize: size, sha256: sha, proof: proof)
        let name = "Wine \(recipe.version) Staging for arm64 Linux (nimbus-base)"
        let files = [(recipe.archiveName, archive), ("\(recipe.archiveName).sha256", "\(archive).sha256"), ("proof.zip", proof.zip)]
            + (proof.diff.map { [("proof-diff.json", $0)] } ?? [])

        let kept = same.first, extra = same.dropFirst()
        if dryRun {
            if let kept {
                let assets = try github.assets(of: kept.id)
                print("would update the draft \(kept.id) of \(tag) (on \(kept.target_commitish)): tag_name \(tag), target \(commit), its name and notes")
                for asset in assets { print("  would delete its asset \(asset.name)") }
            } else {
                print("would draft \(tag) on \(commit), \"\(name)\"")
            }
            for old in extra { print("would delete the second draft \(old.id) of \(tag)") }
            print("would upload:")
            for (file, _) in files { print("  \(file)") }
            print("notes:")
            print(notes.split(separator: "\n", omittingEmptySubsequences: false).map { "  | \($0)" }.joined(separator: "\n"))
            return
        }

        let release: GitHub.Release
        if let kept {
            release = try github.updateRelease(kept.id, tag: tag, commit: commit, name: name, notes: notes)
            for asset in try github.assets(of: kept.id) {
                try github.deleteAsset(asset.id)
                print("  deleted its earlier \(asset.name)")
            }
            print("updated the draft \(release.id) of \(tag)")
        } else {
            release = try github.createDraft(tag: tag, commit: commit, name: name, notes: notes)
            print("drafted \(tag) (release \(release.id))")
        }
        for old in extra { try github.deleteRelease(old.id); print("deleted the second draft \(old.id) of \(tag)") }
        guard release.tag_name == tag, release.draft else {
            throw CheckFailure("GitHub answered release \(release.id) as \(release.tag_name)\(release.draft ? "" : ", published"): not the draft of \(tag)")
        }
        for (file, path) in files {
            try github.uploadAsset(release.id, name: file, path: path)
            print("  uploaded \(file)")
        }
        print("drafted \(tag) (release \(release.id)) on \(commit): New Container Helper checks it; the owner publishes it in Reviews, which makes its tag")
    }

    func notes(recipe: WineRecipe, commit: String, archiveSize: Int, sha256: String, proof: WineDraftProof) throws -> String {
        let wine = try recipe.source("wine"), staging = try recipe.source("staging"), mingw = try recipe.source("llvm-mingw")
        let mingwName = URL(string: mingw.url)?.deletingLastPathComponent().lastPathComponent ?? "llvm-mingw"
        let url = "https://github.com/\(repository)/releases/download/\(recipe.tag)/\(recipe.archiveName)"
        // 130,019,677: thousands grouped by hand (no locale's).
        let digits = String(archiveSize)
        let bytes = digits.enumerated().map { index, digit in (index > 0 && (digits.count - index) % 3 == 0 ? "," : "") + String(digit) }.joined()
        var lines = [
            "Wine \(recipe.version) with Wine Staging's patches, built for arm64 Linux (aarch64), unpacked as `/opt/wine`. It's what Nimbus' `nimbus-base` image's windows layer installs (AttilaTheFun/nimbus `tools/images/nimbus-base/windows.Containerfile`), to run Isomer's arm64 Windows apps and tests under Wine in Linux containers. Nobody ships Wine for arm64 Linux: WineHQ's and Fedora's packages are x86 alone. Staging is needed for its AF_UNIX sockets, which SwiftNIO's Windows event loop uses.",
            "",
            "Proposed for release by run \(runID.isEmpty ? "(none)" : "[\(runID)](https://github.com/\(repository)/actions/runs/\(runID))") (isomer_sdk.yml, `run: wine`) on \(commit), \(branch)'s head when its proof was made. New Container Helper checks it before it is released.",
            "",
            "**The archive:** `\(recipe.archiveName)`, \(bytes) bytes, sha256 `\(sha256)`. It unpacks to `opt/wine` and carries `share/doc/wine/BUILD-INFO` and Wine's LICENSE, COPYING.LIB and AUTHORS.",
            "",
            "**Built from**, on Ubuntu 26.04 arm64, by `sdk-check wine-build` (sdk/wine/wine.json: `./configure \(recipe.configure.joined(separator: " "))`):",
            "- Wine \(recipe.version): \(wine.url) (sha256 `\(wine.sha256)`)",
            "- Wine Staging v\(recipe.version), all patches: \(staging.url) (sha256 `\(staging.sha256)`)",
            "- llvm-mingw \(mingwName), for Wine's arm64 PE side: \(mingw.url) (sha256 `\(mingw.sha256)`)",
            "",
            "Wine is LGPL 2.1 or later; its sources are at the URLs above.",
            "",
            "**Proof** (`proof.zip`, Reviews' format 2, by `sdk-check wine-check` and `wine-proof`), the archive unpacked in the job's ubuntu:26.04 container:",
        ]
        lines += proof.items.map { item in
            item.kind == "screen"
                ? "- `\(item.id)`: \(item.title), a screen item (window-shot, the caret's blink off, the same 3 s later), \(item.width)×\(item.height)"
                : "- `\(item.id)`: \(item.title), \(item.result)"
        }
        if let diff = proof.diffSummary {
            lines += ["", "`proof-diff.json` (build_tools' proof-diff) compares it with \(diff)."]
        } else {
            lines += ["", "No proof-diff.json: none was made."]
        }
        lines += [
            "",
            "**In the windows layer** (windows.Containerfile's arguments):",
            "",
            "```dockerfile",
            "ARG WINE_ARCHIVE_URL=\(url)",
            "ARG WINE_ARCHIVE_SHA256=\(sha256)",
            "```",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// wine-proof's proof.json, with build_tools' proof-diff.json beside it if
/// made, read for the draft.
struct WineDraftProof {
    struct Item {
        var id: String
        var kind: String
        var title: String
        var result: String
        var width: Int
        var height: Int
    }

    var version: String
    var commit: String
    var items: [Item]
    var zip: String
    var diff: String?
    /// "wine-11.21-staging: 0 added, 0 removed, 1 changed, 5 unchanged".
    var diffSummary: String?

    /// The tests items that didn't pass.
    var failed: [String] { items.filter { $0.kind == "tests" && $0.result != "passed" }.map(\.id) }

    init(directory: String) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(directory)/proof.json")))
        guard let proof = json as? [String: Any], proof["format"] as? Int == 2, let items = proof["items"] as? [[String: Any]] else {
            throw CheckFailure("\(directory)/proof.json is no format-2 proof")
        }
        zip = "\(directory)/proof.zip"
        guard FileManager.default.fileExists(atPath: zip) else { throw CheckFailure("no proof.zip in \(directory)") }
        version = proof["version"] as? String ?? ""
        commit = proof["commit"] as? String ?? ""
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw CheckFailure("\(directory)/proof.json names no commit") }
        self.items = items.map {
            Item(id: $0["id"] as? String ?? "", kind: $0["kind"] as? String ?? "", title: $0["title"] as? String ?? "",
                 result: $0["result"] as? String ?? "", width: $0["width"] as? Int ?? 0, height: $0["height"] as? Int ?? 0)
        }
        let diffPath = "\(directory)/proof-diff.json"
        if FileManager.default.fileExists(atPath: diffPath),
           let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: diffPath))) as? [String: Any] {
            diff = diffPath
            let counts = manifest["counts"] as? [String: Int] ?? [:]
            let counted = "\(counts["added"] ?? 0) added, \(counts["removed"] ?? 0) removed, \(counts["changed"] ?? 0) changed, \(counts["unchanged"] ?? 0) unchanged"
            if let base = manifest["base"] as? [String: Any], let tag = base["tag"] as? String {
                diffSummary = "\(tag)'s proof: \(counted)"
            } else {
                diffSummary = "no release before it (\(manifest["note"] as? String ?? "none")): \(counted)"
            }
        }
    }
}

extension GitHub {
    struct Asset: Decodable {
        var id: Int
        var name: String
    }

    func assets(of release: Int) throws -> [Asset] {
        try JSONDecoder().decode([Asset].self, from: send("GET", "\(api)/repos/\(repository)/releases/\(release)/assets?per_page=100"))
    }

    func deleteAsset(_ id: Int) throws {
        _ = try send("DELETE", "\(api)/repos/\(repository)/releases/assets/\(id)")
    }

    /// A draft's fields set again. tag_name always: GitHub resets a draft's
    /// tag to untagged-… on a PATCH without it.
    func updateRelease(_ id: Int, tag: String, commit: String, name: String, notes: String) throws -> Release {
        let body = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "target_commitish": commit, "name": name, "body": notes, "draft": true, "prerelease": false,
        ] as [String: Any])
        return try JSONDecoder().decode(Release.self, from: send("PATCH", "\(api)/repos/\(repository)/releases/\(id)", body: body))
    }

    /// How `head` stands to `base`: "identical", "ahead" (head has base in
    /// its history), "behind" or "diverged".
    func compare(_ base: String, _ head: String) throws -> String {
        let data = try send("GET", "\(api)/repos/\(repository)/compare/\(base)...\(head)?per_page=1")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let status = object["status"] as? String else {
            throw CheckFailure("GitHub didn't compare \(base) with \(head)")
        }
        return status
    }
}
