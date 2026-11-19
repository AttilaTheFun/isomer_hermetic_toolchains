import ArgumentParser
import Foundation

/// A release run's proof, in Reviews' format 2 (AttilaTheFun/reviews'
/// docs/PROOF_FORMAT.md): `proof.json` and the logs it names, zipped as
/// `proof.zip`, which the draft carries (Reviews' Release waits for a
/// commit's proof). A toolchain has no pictures: every item is a `tests`
/// item, made from the logs the run's jobs hand on (isomer_sdk.yml's
/// `logs-*` artifacts), by their names:
///
///   sdk-<bundle>.log                 sdk/build.sh's for one SDK: an item a
///                                    target it checked (the client, and
///                                    sdk-check's undefined, autolink and
///                                    pairing), check-<bundle>-<arch>
///   smoke-<variant>-<api>.log        the consumer built against the SDKs
///                                    (tools/ci/sdk_smoke build: the JNI
///                                    library, the WASI command, the APKs),
///                                    smoke-<variant>-api<api>
///   emulator-<variant>-<api>.log     its x86_64 APK on an emulator
///                                    (sdk_smoke run-android: a check a line),
///                                    emulator-<variant>-api<api>
///
/// The ids are stable from release to release: Reviews' proof-diff matches
/// items by id and compares their result, tests and failures. An item
/// passes when its log has check lines and no FAIL among them; its counts
/// are those lines. Each item's log is logs/<id>.txt, its job's.
///
/// In `--out`: proof.json, logs/, and proof.zip of the two. build_tools'
/// `proof-diff make <out>/proof.zip` writes proof-diff.json beside it, and
/// `sdk-check draft --proof <out>` attaches what it finds there.
struct Proof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Makes a release run's proof (Reviews' format 2: proof.json and its logs, zipped as proof.zip) from its jobs' logs."
    )

    @Option(help: "The directory of the jobs' logs (sdk-*.log, smoke-*.log, emulator-*.log).")
    var logs: String

    @Option(help: "Where proof.json, logs/ and proof.zip go (the directory is replaced).")
    var out: String

    @Option(help: "The version it is a proof of (the release's: sdk-check version).")
    var version: String

    @Option(help: "owner/name (GITHUB_REPOSITORY by default).")
    var repository: String = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? ""

    @Option(help: "The commit (GITHUB_SHA by default).")
    var commit: String = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""

    @Option(name: .customLong("run"), help: "The run that made it (GITHUB_RUN_ID by default).")
    var runID: String = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? ""

    func run() throws {
        let items = try ProofWriter.write(logs: logs, out: out, version: version, repository: repository, commit: commit, run: runID)
        print("proof: \(items.count) tests items, \(items.filter { $0.result != "passed" }.count) failed, in \(out)/proof.zip")
        for item in items { print("  \(item.result) \(item.id): \(item.tests) tests, \(item.failures) failures") }
    }
}

enum ProofWriter {
    struct Item {
        var id: String
        var title: String
        var result: String
        var tests: Int
        var failures: Int
        var log: String { "logs/\(id).txt" }
    }

    /// proof.json, logs/ and proof.zip in `out`, from the logs in `logs`.
    static func write(logs: String, out: String, version: String, repository: String, commit: String, run: String) throws -> [Item] {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: logs).filter { $0.hasSuffix(".log") }.sorted()
        guard !names.isEmpty else { throw CheckFailure("no logs (sdk-*.log, smoke-*.log, emulator-*.log) in \(logs)") }
        try? fileManager.removeItem(atPath: out)
        try fileManager.createDirectory(atPath: "\(out)/logs", withIntermediateDirectories: true)

        var items: [Item] = []
        for name in names {
            let stem = String(name.dropLast(".log".count))
            let text = try String(contentsOfFile: "\(logs)/\(name)", encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { plain($0) }
            var made: [Item] = []
            if stem.hasPrefix("sdk-") {
                made = sdkItems(bundle: String(stem.dropFirst("sdk-".count)), lines: lines)
            } else if stem.hasPrefix("smoke-"), let (variant, api) = cell(String(stem.dropFirst("smoke-".count))) {
                made = [checksItem(id: "smoke-\(variant)-api\(api)",
                                   title: "A consumer on the \(variant) SDKs at Android API \(api): the JNI library, the WASI command, the APKs",
                                   lines: lines.filter { $0.hasPrefix("PASS ") || $0.hasPrefix("FAIL ") || $0.hasPrefix("Error: ") })]
            } else if stem.hasPrefix("emulator-"), let (variant, api) = cell(String(stem.dropFirst("emulator-".count))) {
                // run-android prints the app's checks as "  | ok …" and
                // "  | FAIL …", then "PASS the APK on …" for the run.
                let checks = lines.compactMap { line -> String? in
                    let body = line.drop { $0 == " " }
                    guard body.hasPrefix("| ") else { return nil }
                    let check = String(body.dropFirst(2))
                    return check.hasPrefix("ok ") || check.hasPrefix("FAIL ") ? check : nil
                }
                let failures = checks.filter { $0.hasPrefix("FAIL ") }.count
                let passed = lines.contains { $0.hasPrefix("PASS the APK on") } && failures == 0 && !checks.isEmpty
                made = [Item(id: "emulator-\(variant)-api\(api)",
                             title: "Its APK on Android \(api), an x86_64 emulator, with the \(variant) SDKs",
                             result: passed ? "passed" : "failed", tests: checks.count, failures: failures)]
            } else {
                throw CheckFailure("\(name): not a log the proof knows (sdk-<bundle>, smoke-<variant>-<api>, emulator-<variant>-<api>)")
            }
            // Each item's log: its job's, whole.
            for item in made {
                try text.write(toFile: "\(out)/\(item.log)", atomically: true, encoding: .utf8)
            }
            items += made
        }
        items.sort { $0.id < $1.id }
        let duplicates = Dictionary(grouping: items, by: \.id).filter { $0.value.count > 1 }.keys
        guard duplicates.isEmpty else { throw CheckFailure("two items with one id: \(duplicates.sorted().joined(separator: ", "))") }

        let json: [String: Any] = [
            "format": 2,
            "app": "isomer_hermetic_toolchains",
            "version": version,
            "repository": repository,
            "commit": commit,
            "run": Int(run) ?? run,
            "made": ISO8601DateFormatter().string(from: Date()),
            "items": items.map {
                ["id": $0.id, "kind": "tests", "title": $0.title, "result": $0.result,
                 "tests": $0.tests, "failures": $0.failures, "log": $0.log] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "\(out)/proof.json"))
        // proof.zip: proof.json at its top, the logs beside it.
        _ = try runChecked("/usr/bin/env", ["sh", "-c", "cd \"$0\" && zip -q -r -X proof.zip proof.json logs", out])
        return items
    }

    /// One item a target sdk/build.sh checked: its lines naming the triple
    /// ("PASS (<triple>): …", "PASS undefined (<triple>)", "FAIL pairing
    /// (<triple>): …").
    static func sdkItems(bundle: String, lines: [String]) -> [Item] {
        var byTriple: [String: [String]] = [:]
        var order: [String] = []
        for line in lines where line.hasPrefix("PASS") || line.hasPrefix("FAIL") {
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { continue }
            let triple = String(line[line.index(after: open)..<close])
            guard triple.contains("-unknown-") else { continue }
            if byTriple[triple] == nil { order.append(triple) }
            byTriple[triple, default: []].append(line)
        }
        return order.map { triple in
            let arch = String(triple.prefix { $0 != "-" })
            return checksItem(id: "check-\(bundle)-\(arch)",
                              title: "The \(bundle) SDK for \(triple): its client, undefined, autolink and pairing",
                              lines: byTriple[triple] ?? [])
        }
    }

    /// A tests item from its check lines: passed when there are some and no
    /// FAIL (or Error) among them.
    static func checksItem(id: String, title: String, lines: [String]) -> Item {
        let failures = lines.filter { $0.hasPrefix("FAIL") || $0.hasPrefix("Error: ") }.count
        return Item(id: id, title: title, result: failures == 0 && !lines.isEmpty ? "passed" : "failed",
                    tests: lines.count, failures: failures)
    }

    /// ("i18n", "23") from "i18n-23".
    static func cell(_ name: String) -> (String, String)? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let variant = String(name[..<dash]), api = String(name[name.index(after: dash)...])
        return ["plain", "i18n"].contains(variant) && Int(api) != nil ? (variant, api) : nil
    }

    /// A log line without terminal colours or a carriage return.
    static func plain(_ line: Substring) -> String {
        var text = String(line)
        while let escape = text.range(of: "\u{1B}[") {
            let rest = text[escape.upperBound...]
            guard let end = rest.firstIndex(where: { $0.isLetter }) else { break }
            text.removeSubrange(escape.lowerBound...end)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
}
