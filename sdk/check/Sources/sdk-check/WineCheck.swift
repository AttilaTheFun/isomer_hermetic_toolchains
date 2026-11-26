import ArgumentParser
import Foundation

/// A Wine archive checked as the windows layer uses it: unpacked in the
/// job's container (`tar -xf - -C /opt`), then each check run, its commands
/// and their output logged in `--out`/logs/<check>.txt, its result printed
/// (PASS or FAIL wine/<check>) and recorded in `--out`/checks.json for
/// wine-proof:
///
///   archive-sha256  the archive's SHA-256 is its .sha256's
///   version         `wine --version` is the recipe's, with "(Staging)"
///   wineboot        `wineboot -i` makes a prefix, under Xvfb
///   cmd-echo        `wine cmd /c echo ok` says ok
///   hello-arm64     an arm64 hello world built with llvm-mingw runs under
///                   Wine and finds itself on arm64 (processor architecture 12)
///   notepad         Notepad's window, shot cropped to it (window-shot), the
///                   caret's blink off (CursorBlinkRate -1), and the same
///                   again three seconds later: held still
///
/// Every check runs whatever another's result; the command fails (exit 1)
/// after the last when any did.
struct WineCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine-check",
        abstract: "Unpacks a Wine archive (wine-build's) and checks it: its sha256, wine --version, wineboot -i under Xvfb, cmd /c echo, an arm64 hello world, Notepad's window."
    )

    @OptionGroup var recipeOptions: WineRecipeOptions

    @Option(help: "The archive (wine-build's), its .sha256 beside it.")
    var archive: String

    @Option(help: "Where the logs (logs/<check>.txt, other/), the pictures (screens/) and checks.json go (the directory is replaced).")
    var out: String

    @Option(help: "Where the archive is unpacked: its wine/ goes there, as the windows layer's /opt.")
    var unpackTo: String = "/opt"

    @Flag(help: "Replace a wine/ already at --unpack-to (else refused: the checks are of the archive alone).")
    var replace = false

    @Option(help: "Scratch: the prefix, the hello world.")
    var work: String = "/tmp/wine-check"

    @Option(help: "llvm-mingw, for the hello world (fetched by the recipe's URL and sha256 when not there).")
    var llvmMingw: String = "/opt/llvm-mingw"

    @Option(help: "The X display Xvfb serves.")
    var display: String = ":7"

    @Flag(help: "Install the recipe's runtime and check packages with apt first (the job's container runs as root).")
    var apt = false

    func run() throws {
        let recipe = try recipeOptions.load()
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: out)
        try? fileManager.removeItem(atPath: work)
        for directory in ["\(out)/logs", "\(out)/other", "\(out)/screens", work] {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        print("wine-check: \(archive), on \(Wine.machine())")
        if apt {
            print("apt: the runtime and check packages")
            try Wine.aptInstall(recipe.runtimePackages + recipe.checkPackages, log: "\(out)/other/apt.log")
        }
        let session = CheckSession(out: out, work: work)

        // The archive's sha256, before it is unpacked.
        session.check("archive-sha256", "Wine archive's SHA-256") { log in
            let recorded = try Wine.recordedSHA256("\(archive).sha256")
            log.run(["ls", "-l", archive])
            let sha = try Wine.sha256(archive)
            log.note("sha256 \(sha)  \((archive as NSString).lastPathComponent)")
            log.note("its .sha256: \(recorded)")
            guard sha == recorded else { throw CheckFailure("the archive's sha256 is \(sha), its .sha256 says \(recorded)") }
        }

        // Unpacked as the windows layer does: zstd's stream into tar at /opt.
        let wineRoot = "\(unpackTo)/wine"
        if fileManager.fileExists(atPath: wineRoot) {
            guard replace else { throw CheckFailure("\(wineRoot) is there already: the checks are of the archive alone (--replace to replace it)") }
            try fileManager.removeItem(atPath: wineRoot)
        }
        try fileManager.createDirectory(atPath: unpackTo, withIntermediateDirectories: true)
        try Wine.logged(["tar", "--use-compress-program=zstd", "-xf", archive, "-C", unpackTo], log: "\(out)/other/unpack.log", environment: Wine.environment)
        guard fileManager.isExecutableFile(atPath: "\(wineRoot)/bin/wine") else { throw CheckFailure("the archive has no wine/bin/wine") }
        // What its Unix side links that the container lacks (Wine's own
        // ntdll.so and win32u.so, which Wine loads itself, aside).
        if let ldd = try? ProcessRunner.run("/bin/sh", ["-c", "find \"$0\"/lib/wine -name '*.so' -exec ldd {} + 2>/dev/null | grep 'not found' | sort -u", wineRoot]) {
            try? "libraries not found (ldd):\n\(ldd.stdout.isEmpty ? "none\n" : ldd.stdout)".write(toFile: "\(out)/other/ldd.log", atomically: true, encoding: .utf8)
        }

        let prefix = "\(work)/prefix"
        var environment = Wine.environment
        environment["PATH"] = "\(wineRoot)/bin:" + (environment["PATH"] ?? Wine.systemPath())
        // No Mono or Gecko installers (their prompts wait forever), no debug
        // channels: as the windows layer's ENV.
        environment["WINEDEBUG"] = "-all"
        environment["WINEDLLOVERRIDES"] = "mscoree=;mshtml="
        environment["WINEPREFIX"] = prefix
        environment["DISPLAY"] = display
        session.environment = environment

        session.check("version", "wine --version") { log in
            let output = log.run(["wine", "--version"])
            let line = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, line == recipe.versionLine else { throw CheckFailure("wine --version said \"\(line)\", not \"\(recipe.versionLine)\"") }
        }

        // The display: Xvfb of its own, 1280×800, 24 bits (no window manager:
        // Wine draws its own frames).
        let xvfb = try session.background(["Xvfb", display, "-screen", "0", "1280x800x24", "-nolisten", "tcp"], log: "\(out)/other/xvfb.log")
        defer { xvfb.terminate() }
        var ready = false
        for _ in 0..<40 where !ready {
            ready = (try? ProcessRunner.run("/usr/bin/env", ["xdpyinfo", "-display", display], environment: environment))?.status == 0
            if !ready { Thread.sleep(forTimeInterval: 0.5) }
        }
        if !ready { print("Xvfb on \(display) didn't answer in 20 s (other/xvfb.log)") }

        // An aarch64-only Wine has no WoW64: wineboot says "failed to start
        // C:\windows\syswow64\rundll32.exe: c0000135" and still makes the
        // prefix, exit 0.
        session.check("wineboot", "wineboot -i under Xvfb") { log in
            let info = log.run(["xdpyinfo", "-display", display], quiet: true)
            log.note(info.stdout.split(separator: "\n").filter { $0.contains("dimensions") || $0.contains("depth of root") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
            let started = Date()
            let output = log.run(["timeout", "300", "wineboot", "-i"])
            log.note(String(format: "wineboot took %.1f s", Date().timeIntervalSince(started)))
            guard output.status == 0 else { throw CheckFailure("wineboot -i exited \(output.status)") }
            guard FileManager.default.fileExists(atPath: "\(prefix)/system.reg") else { throw CheckFailure("no \(prefix)/system.reg: no prefix made") }
            log.note("prefix: \(prefix)/system.reg present")
        }

        session.check("cmd-echo", "wine cmd /c echo ok") { log in
            let output = log.run(["timeout", "120", "wine", "cmd", "/c", "echo", "ok"])
            let said = output.stdout.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, said == "ok" else { throw CheckFailure("cmd /c echo ok said \"\(said)\", exit \(output.status)") }
        }

        session.check("hello-arm64", "An arm64 hello world (llvm-mingw) under Wine") { log in
            let clang = try Wine.llvmMingw(recipe, at: llvmMingw, downloads: "\(work)/downloads", log: "\(out)/other/llvm-mingw.log")
            log.run([clang, "--version"])
            let source = "\(work)/hello.c", exe = "\(work)/hello.exe"
            try Self.hello.write(toFile: source, atomically: true, encoding: .utf8)
            log.note("--- hello.c\n\(Self.hello)---")
            guard log.run([clang, "-O2", "-o", exe, source]).status == 0 else { throw CheckFailure("hello.c didn't compile") }
            let kind = log.run(["file", exe]).stdout
            guard kind.contains("Aarch64") || kind.contains("ARM64") else { throw CheckFailure("hello.exe isn't arm64: \(kind)") }
            let output = log.run(["timeout", "120", "wine", exe])
            let said = output.stdout.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, said == "hello from arm64 Windows, arch 12" else {
                throw CheckFailure("hello.exe said \"\(said)\", exit \(output.status)")
            }
        }

        // Notepad, its caret's blink off before it starts (CursorBlinkRate
        // -1), shot cropped to its window, then again: the two the same.
        session.check("notepad", "Notepad under Wine (Xvfb)") { log in
            log.run(["wine", "reg", "add", "HKCU\\Control Panel\\Desktop", "/v", "CursorBlinkRate", "/t", "REG_SZ", "/d", "-1", "/f"])
            let notepad = try session.background(["wine", "notepad"], log: "\(out)/other/notepad.log")
            defer { notepad.terminate() }
            let shot = "\(out)/screens/notepad.png", again = "\(work)/notepad-again.png"
            var shotTaken = false
            for _ in 0..<30 where !shotTaken {
                shotTaken = (try? WindowShot.take("notepad", to: shot, environment: environment)) != nil
                if !shotTaken { Thread.sleep(forTimeInterval: 2) }
            }
            guard shotTaken else {
                log.run(["xwininfo", "-root", "-tree"])
                throw CheckFailure("no Notepad window in 60 s")
            }
            // Settled: the window drawn whole before the picture kept.
            Thread.sleep(forTimeInterval: 3)
            let geometry = try WindowShot.take("notepad", to: shot, environment: environment)
            log.note("window-shot notepad: \(geometry.name) at \(geometry.crop)")
            Thread.sleep(forTimeInterval: 3)
            _ = try WindowShot.take("notepad", to: again, environment: environment)
            log.run(["identify", shot])
            let colours = log.run(["convert", shot, "-format", "%k", "info:"], quiet: true).stdout
            log.note("colours: \(colours)")
            let compared = log.run(["compare", "-metric", "AE", shot, again, "null:"], quiet: true)
            let differing = compared.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            log.note("pixels differing between two shots 3 s apart: \(differing)")
            log.run(["sha256sum", shot, again])
            guard Double(differing.split(separator: " ").first ?? "") == 0 else {
                throw CheckFailure("two shots 3 s apart differ in \(differing) pixels: Notepad isn't held still")
            }
        }

        _ = try? ProcessRunner.run("/usr/bin/env", ["wineserver", "-k"], environment: environment)
        try session.save()
        let failed = session.records.filter { !$0.passed }
        print("wine-check: \(session.records.count - failed.count) of \(session.records.count) passed, in \(out)")
        if !failed.isEmpty { throw ExitCode.failure }
    }

    static let hello = """
        #include <stdio.h>
        #include <windows.h>
        int main(void) { SYSTEM_INFO si; GetNativeSystemInfo(&si); printf("hello from arm64 Windows, arch %u\\n", si.wProcessorArchitecture); return si.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64 ? 0 : 1; }

        """
}

/// One check's result, as checks.json keeps it for wine-proof.
struct WineCheckRecord: Codable {
    var name: String
    var title: String
    var passed: Bool
    /// Its log, relative to wine-check's --out.
    var log: String
    var failure: String?
}

/// The checks of one wine-check: their logs, their records, the processes
/// left running in the background (Xvfb, Notepad).
final class CheckSession {
    let out: String
    let work: String
    var environment: [String: String] = Wine.environment
    var records: [WineCheckRecord] = []

    init(out: String, work: String) {
        self.out = out
        self.work = work
    }

    /// A check's transcript: each command, its output and its exit.
    final class Log {
        var text: String
        let environment: [String: String]

        init(name: String, environment: [String: String]) {
            text = "# wine/\(name), \(Wine.timestamp()) in \(Wine.machine())\n"
            self.environment = environment
        }

        func note(_ line: String) { text += line.hasSuffix("\n") ? line : line + "\n" }

        /// Runs a program (found on the check's PATH), its output in the log
        /// (`quiet`: the command and its exit alone).
        @discardableResult
        func run(_ command: [String], quiet: Bool = false) -> Output {
            text += "$ \(command.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))\n"
            let output: Output
            do {
                output = try sdk_check.run("/usr/bin/env", command, environment: environment)
            } catch {
                text += "(didn't run: \(error))\n"
                return Output(status: 127, stdout: "", stderr: "\(error)")
            }
            if !quiet {
                for part in [output.stdout, output.stderr] where !part.isEmpty {
                    text += part.replacingOccurrences(of: "\r", with: "")
                    if !part.hasSuffix("\n") { text += "\n" }
                }
            }
            text += "(exit \(output.status))\n"
            return output
        }
    }

    /// Runs one check, its log written and its result recorded and printed
    /// whatever it throws.
    func check(_ name: String, _ title: String, _ body: (Log) throws -> Void) {
        let log = Log(name: name, environment: environment)
        var failure: String?
        do {
            try body(log)
        } catch {
            failure = "\(error)"
        }
        log.note(failure.map { "FAIL: \($0)" } ?? "PASS")
        let path = "logs/\(name).txt"
        try? log.text.write(toFile: "\(out)/\(path)", atomically: true, encoding: .utf8)
        records.append(WineCheckRecord(name: name, title: title, passed: failure == nil, log: path, failure: failure))
        print("\(failure == nil ? "PASS" : "FAIL") wine/\(name)\(failure.map { ": \($0)" } ?? "")")
        fflush(nil)
    }

    /// A program left running (Xvfb, Notepad), its output in `log`.
    func background(_ command: [String], log: String) throws -> Process {
        _ = FileManager.default.createFile(atPath: log, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(records).write(to: URL(fileURLWithPath: "\(out)/checks.json"))
    }
}

/// Nimbus' window-shot (tools/images/nimbus-base/window-shot) in Swift: the
/// display's largest window whose name has `pattern` in it (any case),
/// cropped from the root window by ImageMagick's import, so the picture has
/// no desktop around the app.
enum WindowShot {
    struct Geometry {
        var name: String
        var crop: String
    }

    @discardableResult
    static func take(_ pattern: String, to path: String, environment: [String: String]) throws -> Geometry {
        let tree = try run("/usr/bin/env", ["xwininfo", "-root", "-tree"], environment: environment)
        guard tree.status == 0 else { throw CheckFailure("xwininfo -root -tree failed: \(tree.stderr)") }
        // Lines like `     0x200007 "Untitled - Notepad": ("notepad.exe" "Notepad")  752x536+0+0  +264+132`.
        var best: (area: Int, id: String, name: String)?
        for line in tree.stdout.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("0x"), let open = trimmed.firstIndex(of: "\"") else { continue }
            let id = String(trimmed.prefix { $0 != " " })
            let rest = trimmed[trimmed.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<close])
            guard name.lowercased().contains(pattern.lowercased()) else { continue }
            let info = try geometry(of: id, environment: environment)
            let area = info.width * info.height
            if area > (best?.area ?? 0) { best = (area, id, name) }
        }
        guard let best else { throw CheckFailure("no window named like \(pattern)") }
        let info = try geometry(of: best.id, environment: environment)
        let crop = "\(info.width)x\(info.height)+\(info.x)+\(info.y)"
        let shot = try run("/usr/bin/env", ["import", "-window", "root", "-crop", crop, "+repage", path], environment: environment)
        guard shot.status == 0 else { throw CheckFailure("import -window root -crop \(crop) failed: \(shot.stderr)") }
        return Geometry(name: best.name, crop: crop)
    }

    static func geometry(of id: String, environment: [String: String]) throws -> (x: Int, y: Int, width: Int, height: Int) {
        let info = try run("/usr/bin/env", ["xwininfo", "-id", id], environment: environment)
        var values: [String: Int] = [:]
        for line in info.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            values[parts[0]] = value
        }
        guard let x = values["Absolute upper-left X"], let y = values["Absolute upper-left Y"],
              let width = values["Width"], let height = values["Height"] else {
            throw CheckFailure("xwininfo -id \(id) gave no geometry")
        }
        return (x, y, width, height)
    }
}
