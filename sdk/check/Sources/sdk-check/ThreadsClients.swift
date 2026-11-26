import ArgumentParser
import Foundation

/// The threads SDK's own clients (sdk/build.sh wasm-threads, beside the
/// client and the C++ interop client every wasm SDK's check builds): each a
/// package built by SwiftPM against the bundle, so with its swift-sdk.json
/// and toolset.json (threads, atomics, shared memory, C++ exceptions), and
/// run under WasmKit with WASI Threads:
///
///   taskgroup       Swift Concurrency on several threads: a TaskGroup of 64
///                   child tasks on a TaskExecutor over four pthreads, an
///                   actor counting them, and Isomer's Foundation on every
///                   thread (Thread.isMainThread from the thread that ran the
///                   constructors, JSONEncoder, NSLock)
///   cxx-exceptions  C++ that throws and catches on four std::threads and on
///                   the main thread, called from Swift; and its object's EH
///                   instructions the standard proposal's alone (the
///                   toolset's -wasm-use-legacy-eh=false reached it)
struct ThreadsClients: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads-clients",
        abstract: "Builds the threads SDK's clients (a TaskGroup over threads, C++ exceptions across std::threads) with SwiftPM and runs them under WasmKit with WASI Threads."
    )

    @Option(help: "The toolchain's usr/bin (swift).")
    var bin: String

    @Option(name: .customLong("swift-sdks-path"), help: "The directory the bundle is unpacked in (SwiftPM's --swift-sdks-path).")
    var swiftSDKsPath: String

    @Option(name: .customLong("swift-sdk"), help: "The threads SDK's artifact id (SwiftPM's --swift-sdk).")
    var swiftSDK: String

    @Option(help: "The target triple, for the report (wasm32-unknown-wasip1-threads).")
    var target: String = "wasm32-unknown-wasip1-threads"

    @Option(help: "A WasmKit CLI that runs WASI Threads and shared memory (0.5.0 or later).")
    var wasmkit: String

    @Option(help: "Where the packages are written and built (replaced).")
    var work: String

    func run() throws {
        try? FileManager.default.removeItem(atPath: work)
        let package = URL(fileURLWithPath: work).appendingPathComponent("ThreadsClients")
        for (path, contents) in Self.files {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let scratch = package.appendingPathComponent(".build").path
        print("building \(package.path) for \(swiftSDK)")
        // The toolchain's clang first on PATH: SwiftPM compiles C and C++
        // with the clang it finds there, and the toolset's
        // `-mllvm -wasm-use-legacy-eh=false` is LLVM 20's and later.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin):" + (environment["PATH"] ?? "/usr/bin:/bin")
        try stream("\(bin)/swift", [
            "build", "--build-system", "native", "--package-path", package.path, "--scratch-path", scratch,
            "--swift-sdks-path", swiftSDKsPath, "--swift-sdk", swiftSDK, "--static-swift-stdlib", "-c", "release",
        ], environment: environment)
        var failures: [String] = []
        for (product, expected) in [("TaskGroupCheck", ["concurrency: ok"]),
                                    ("CxxExceptionsCheck", ["main caught int 42", "caught 2 of 4 threads", "exceptions: ok"])] {
            let check = product == "TaskGroupCheck" ? "taskgroup" : "cxx-exceptions"
            guard let program = FileManager.default.enumerator(atPath: scratch)?
                .compactMap({ $0 as? String })
                .first(where: { $0.hasSuffix("/release/\(product).wasm") }) else {
                failures.append("\(check): \(product).wasm wasn't linked")
                continue
            }
            let path = "\(scratch)/\(program)"
            let output = try ProcessRunner.run(wasmkit, ["run", "--wasi-threads", path])
            print("\(product) under WasmKit, --wasi-threads (exit \(output.status)):")
            for line in (output.stdout + output.stderr).split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                print("  | \(line)")
            }
            let lines = output.stdout.split(separator: "\n").map(String.init)
            let missing = expected.filter { !lines.contains($0) }
            if output.status == 0, missing.isEmpty {
                print("PASS \(check) (\(target)): \(lines.last ?? "")")
            } else {
                print("FAIL \(check) (\(target)): exit \(output.status)\(missing.isEmpty ? "" : ", no line \(missing.map { "\"\($0)\"" }.joined(separator: ", "))")")
                failures.append(check)
            }
        }
        // The toolset's C++ flags reached the C++ target: its object throws
        // and catches with the standard proposal's instructions alone.
        if let object = FileManager.default.enumerator(atPath: scratch)?.compactMap({ $0 as? String })
            .first(where: { $0.hasSuffix("/release/Throwing.build/Throwing.cpp.o") }) {
            var legacy = 0, exnref = 0
            let disassembly = try ProcessRunner.run("\(bin)/llvm-objdump", ["-d", "\(scratch)/\(object)"]).stdout
            for line in disassembly.split(separator: "\n") {
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if words.contains(where: { ["try", "catch", "catch_all", "delegate", "rethrow"].contains($0) }) { legacy += 1 }
                if words.contains(where: { $0 == "try_table" || $0 == "throw_ref" }) { exnref += 1 }
            }
            if legacy == 0, exnref > 0 {
                print("PASS cxx-exception-instructions (\(target)): try_table/throw_ref \(exnref), legacy 0 in Throwing.cpp.o")
            } else {
                print("FAIL cxx-exception-instructions (\(target)): try_table/throw_ref \(exnref), legacy \(legacy) in Throwing.cpp.o")
                failures.append("cxx-exception-instructions")
            }
        } else {
            failures.append("cxx-exception-instructions: no Throwing.cpp.o")
        }
        if !failures.isEmpty { throw ExitCode.failure }
    }

    static let files: [(String, String)] = [
        ("Package.swift", #"""
        // swift-tools-version: 6.0
        import PackageDescription

        // The threads SDK's flags (threads, atomics, shared memory, C++
        // exceptions) come from its toolset.json: nothing here asks for them.
        let stack: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"])]
        let package = Package(
            name: "ThreadsClients",
            targets: [
                .executableTarget(name: "TaskGroupCheck", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: stack),
                .target(name: "Throwing"),
                .executableTarget(name: "CxxExceptionsCheck", dependencies: ["Throwing"],
                                  swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: stack),
            ],
            cxxLanguageStandard: .cxx17
        )
        """#),
        ("Sources/TaskGroupCheck/main.swift", #"""
        import Foundation
        import WASILibc
        import wasi_pthread

        /// A pool of pthreads that runs jobs: the task executor the tasks prefer.
        final class ThreadPool: TaskExecutor, @unchecked Sendable {
            private let lock = NSLock()
            private let ready = NSCondition()
            private var jobs: [UnownedJob] = []

            init(threads: Int) {
                for _ in 0..<threads {
                    var thread = pthread_t(bitPattern: 0)
                    let context = Unmanaged.passRetained(self).toOpaque()
                    let status = pthread_create(&thread, nil, { context in
                        Unmanaged<ThreadPool>.fromOpaque(context!).takeUnretainedValue().work()
                        return nil
                    }, context)
                    precondition(status == 0, "pthread_create: \(status)")
                }
            }

            func enqueue(_ job: consuming ExecutorJob) {
                let job = UnownedJob(job)
                ready.lock()
                jobs.append(job)
                ready.signal()
                ready.unlock()
            }

            private func work() {
                while true {
                    ready.lock()
                    while jobs.isEmpty { ready.wait() }
                    let job = jobs.removeFirst()
                    ready.unlock()
                    job.runSynchronously(on: asUnownedTaskExecutor())
                }
            }
        }

        /// Signalled from a pool thread, waited for on the main thread.
        final class Done: @unchecked Sendable {
            private let condition = NSCondition()
            private var result: Bool?
            func signal(_ ok: Bool) { condition.lock(); result = ok; condition.signal(); condition.unlock() }
            func wait() -> Bool {
                condition.lock()
                while result == nil { condition.wait() }
                let ok = result!
                condition.unlock()
                return ok
            }
        }

        actor Counter {
            var value = 0
            func add(_ n: Int) { value += n }
        }

        /// Foundation on every thread: an NSLock shared by them all.
        final class Encoded: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = 0
            func add(_ n: Int) { lock.lock(); bytes += n; lock.unlock() }
            var total: Int { lock.lock(); defer { lock.unlock() }; return bytes }
        }

        func threadID() -> Int { Int(bitPattern: pthread_self()) }

        let mainThread = threadID()
        print("main thread: Thread.isMainThread \(Thread.isMainThread)")
        let pool = ThreadPool(threads: 4)
        let done = Done()
        let encoded = Encoded()
        let tasks = 64
        Task(executorPreference: pool) {
            let counter = Counter()
            let results = await withTaskGroup(of: (Int, Bool).self) { group in
                for i in 0..<tasks {
                    group.addTask {
                        var x = 0
                        for k in 0..<10_000 { x &+= k ^ i }
                        usleep(1_000)
                        let data = try! JSONEncoder().encode(["task": i, "x": x == -1 ? 0 : 1])
                        encoded.add(data.count)
                        await counter.add(1)
                        return (threadID(), Thread.isMainThread)
                    }
                }
                var seen: [(Int, Bool)] = []
                for await result in group { seen.append(result) }
                return seen
            }
            let threads = Set(results.map(\.0))
            let total = await counter.value
            let offMain = !threads.contains(mainThread) && !results.contains { $0.1 }
            print("child tasks ran on \(threads.count) threads, none the main thread: \(offMain); counter \(total) of \(tasks); \(encoded.total) bytes of JSON")
            done.signal(threads.count > 1 && offMain && total == tasks && encoded.total > 0)
        }
        let ok = done.wait() && Thread.isMainThread
        print(ok ? "concurrency: ok" : "concurrency: FAILED")
        exit(ok ? 0 : 1)
        """#),
        ("Sources/Throwing/include/Throwing.h", #"""
        #pragma once

        #ifdef __cplusplus
        extern "C" {
        #endif

        /// Four std::threads, two of which throw a std::runtime_error and catch
        /// it, and an int thrown and caught on the calling thread: how many
        /// threads caught theirs (2), or -1 if the calling thread's escaped.
        int throwing_threads(void);

        #ifdef __cplusplus
        }
        #endif
        """#),
        ("Sources/Throwing/Throwing.cpp", #"""
        #include "Throwing.h"

        #include <atomic>
        #include <cstdio>
        #include <stdexcept>
        #include <string>
        #include <thread>
        #include <vector>

        static int check(int n) {
            if (n > 2) throw std::runtime_error("too big: " + std::to_string(n));
            return n;
        }

        int throwing_threads(void) {
            std::atomic<int> caught{0};
            std::vector<std::thread> threads;
            for (int i = 1; i <= 4; i++) {
                threads.emplace_back([i, &caught] {
                    try {
                        check(i);
                        std::printf("thread %d ok\n", i);
                    } catch (const std::runtime_error &e) {
                        std::printf("thread %d caught: %s\n", i, e.what());
                        caught++;
                    }
                });
            }
            for (auto &t : threads) t.join();
            try {
                throw 42;
            } catch (int v) {
                std::printf("main caught int %d\n", v);
            } catch (...) {
                return -1;
            }
            std::printf("caught %d of 4 threads\n", caught.load());
            std::fflush(stdout);
            return caught.load();
        }
        """#),
        ("Sources/CxxExceptionsCheck/main.swift", #"""
        import Throwing
        import WASILibc

        let caught = throwing_threads()
        print(caught == 2 ? "exceptions: ok" : "exceptions: FAILED (\(caught))")
        exit(caught == 2 ? 0 : 1)
        """#),
    ]
}
