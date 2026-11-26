# Isomer's Swift SDKs

swift.org's Swift SDKs for Android and WebAssembly with corelibs Foundation
taken out and Isomer's Foundation family put in (docs/hermetic_toolchains.md
in AttilaTheFun/isomer says why and how a consumer registers them).
`sdk/build.sh <sdk>` builds one in a Linux container; CI
(.github/workflows/isomer_sdk.yml) builds and checks all five on each push
to an `isomer-*` branch.

| SDK | archive | minimum |
| --- | --- | --- |
| Android, plain | `swift-6.4.2-RELEASE_android.artifactbundle.tar.gz` | API 23 (aarch64, x86_64, armv7) |
| Android, -i18n | `swift-6.4.2-RELEASE_android-i18n.artifactbundle.tar.gz` | API 23 (aarch64, x86_64, armv7) |
| WebAssembly, plain | `swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz` | wasm32-unknown-wasip1 |
| WebAssembly, -i18n | `swift-6.4.2-RELEASE_wasm-i18n.artifactbundle.tar.gz` | wasm32-unknown-wasip1 |
| WebAssembly threads, plain | `swift-6.4.2-RELEASE_wasm-threads.artifactbundle.tar.gz` | wasm32-unknown-wasip1-threads (and wasm32-unknown-wasip1) |

## The threads SDK

`sdk/build.sh wasm-threads` makes a third wasm bundle: the plain wasm SDK's
`wasm32-unknown-wasip1` target with `wasm32-unknown-wasip1-threads` beside
it, Isomer's Foundation family built for both. swift.org's 6.4.2 bundle has
no threads target (6.5's should), so its runtime is built here, by
`sdk-check build-threads-runtime`, from upstream's sources cloned by tag and
checked against their commits (swift, llvm-project and
swift-experimental-string-processing at `swift-6.4.2-RELEASE`, wasi-libc at
`wasi-sdk-31`) with the patches in `sdk/patches`:

- `swift/0001`: swiftlang/swift#92018, multi-threaded wasi-threads
  Concurrency (`SWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY` off for the threads
  triple), backported to 6.4.2's build-script;
- `swift/0002`: the threads sysroot's libunwind, libc++abi and libc++ built
  with WebAssembly exceptions (the standard exnref proposal: `-fwasm-exceptions
  -mllvm -wasm-use-legacy-eh=false`), and the assembly compiled for the target;
- `swift/0003`: no embedded stdlib for the threads triple;
- `swift/0004`: build-script's `--build-wasi-threads-stdlib-only` (the
  sysroot and the threads stdlib, not the plain stdlib or the Swift SDK
  product);
- `llvm-project/`: llvm/llvm-project#168449 and libunwind's assembly left
  empty on wasm, which LLVM 21's libunwind needs (0002 applies them too, when
  they aren't already).

No compiler is built: swift.org's 6.4.2 toolchain is the host compiler, so
the modules are the compiler's that loads them; it takes a few minutes. Its
target has its own `swift-sdk.json` and `toolset.json`:

- every compile: `-matomics -mbulk-memory -mthread-model posix -pthread
  -ftls-model=local-exec` (Swift's through `-Xcc`);
- C and C++ compiles: `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false`;
  Swift compiles: `-Xllvm -wasm-enable-eh -Xllvm -wasm-use-legacy-eh=false`,
  as SwiftPM hands the C options to swiftc too (`-Xcc`, for the Clang
  importer), and swift-frontend aborts on `-Xcc -mllvm -Xcc
  -wasm-use-legacy-eh=false` unless its own LLVM has the option (Swift's
  frames still don't unwind: a C++ exception that escapes into Swift ends
  the program);
- the link: `--import-memory --export-memory --shared-memory
  --max-memory=1073741824 -lunwind` (swiftc's links also take `-lunwind`
  from the runtime's static-executable-args.lnk).

SwiftPM compiles a package's C and C++ with the clang first on PATH (the
toolset names none), so a SwiftPM build for the threads target needs
swift.org's toolchain's clang (21) there, as an installed toolchain has it:
`-wasm-use-legacy-eh` is unknown to older ones (Ubuntu's clang 18 in Visor's
agent image). sdk/build.sh puts the toolchain's `usr/bin` first for the
threads target's builds.

rules_swift reads a bundle's one `swift-sdk.json` (its threads support,
`swift.wasm_sdk(threads = True, url = …, sha256 = …)` beside the plain tag,
reads it and its toolset), so in this bundle the wasip1 target's is
`wasip1-swift-sdk.json`; SwiftPM takes either by its artifact id,
`swift-6.4.2-RELEASE_wasm` or `swift-6.4.2-RELEASE_wasm-threads`. It is plain
only: swift.org's ICU has no atomics, and none is built for the threads
triple. Its programs need an engine with WASI Threads and exception handling
(WasmKit 0.5.0's `run --wasi-threads`; the toolchain's own wasmkit, 0.3.1,
rejects shared memory).

## The minimum Android API

The Android SDKs' minimum is API 23, swift.org's: every library in them is
compiled for `<arch>-unknown-linux-android23` with NDK r30 (sdk/build.sh's
`API`), so an app at minSdk 23 or later links them. It is written in the
bundle as its `swift-sdk.json`'s lowest target triple
(`aarch64-unknown-linux-android23` and its siblings), which rules_swift reads
as the SDK's minimum and fails an Android target whose NDK is below it. The
build fails if the two ever differ. (isomer-6.4.2.1's Android SDKs were
compiled for API 28 while their swift-sdk.json said 23: an app at 23 failed
to link, `getgrgid_r` and `getgrnam_r` undefined.)

## The checks

Every SDK build checks its bundle before it is packed for release
(sdk/build.sh's check step); a failure fails the build:

- **the client**: a package that imports Foundation, FoundationNetworking,
  Combine and CoreGraphics builds and links against the bundle, autolinks
  Isomer's libraries and none of corelibs', and on wasm runs under WasmKit
  (with swift-testing beside it, and a C++ interop client);
- **the threads target's**, in the threads SDK, under WasmKit 0.5.0 with
  WASI Threads: the client and the C++ interop client, and `sdk-check
  threads-clients`: a TaskGroup of 64 tasks on a task executor over four
  pthreads, with Foundation on each, and C++ throwing and catching on four
  `std::thread`s, both packages built by SwiftPM with the bundle's toolset;
  and `sdk-check build-threads-runtime`'s own: every object wasm, the C++
  runtimes' exception and thread symbols, no legacy EH instruction;
- **sdk-check** (`sdk/check`, a Swift program the same toolchain builds),
  for each architecture and each Swift module the build made:
  - `autolink`: `import M` autolinks `-lM`, and every library an import
    names is in the SDK or the platform's sysroot;
  - `pairing`: a client referencing every public global, static and
    conformance of the module compiles against the SDK and needs nothing
    its archives don't define, so each binary module and its archive come
    from one build;
  - `undefined`: every archive's undefined symbols resolve against the
    SDK's archives and the platform's libraries at its minimum (Android's
    API-23 libc, libm, libdl and liblog stubs, the NDK's C++ runtime and
    compiler-rt; WASI's libc).

`sdk-check --help` (and each subcommand's) says what it takes; the check
step shows the arguments for each platform.

## Releases

As isomer's own (AttilaTheFun/reviews' docs/RELEASE_PROCESS.md): a release
run, isomer_sdk.yml dispatched by hand with `run: release` on the release
branch (`isomer-<Swift version>`), builds and checks the four SDKs, then
builds a consumer against them as an app fetches them, by URL and sha256:
isomer main's tests/sdk_consumer and tools/ci/sdk_smoke, the SDKs served
from the job (a draft's assets need a token to download), plain and -i18n at
API 23 and 28, upgraded in one output base from the SDKs isomer registers
now, each cell's x86_64 APK run on an emulator at its API. isomer is
checked out in `isomer/` and every smoke step runs there, so the cell's
`--isomer` and the examples' MODULE.bazel are isomer's, and Bazel runs with
`--symlink_prefix=/` (at isomer's root and in the consumer): isomer's
Package.swift has a target at "." that would take what is under Bazel's
convenience symlinks for resources, and rules_swift_package_manager copies
that package, the consumer's directory with it, into the consumer's output
base. The smoke jobs hand on their outputs (the x86_64 APK and its cell,
the checks' results) from the workspace's `out/`, never `runner.temp`,
which in a container job names the runner's directory; the emulator job
builds sdk_smoke on the runner itself, with libcurl's development package
for its FoundationNetworking. A build is tried twice (sdk_smoke) and its
downloads retried (Bazel), as Maven Central has answered 404 for artifacts
it has, and tried at Google's mirror of Central after it (isomer's
tools/ci/downloader.cfg). The smoke jobs keep Bazel's caches in GitHub's
(isomer_sdk.yml's header): the downloads, sdk_smoke's own build, and the
consumer's build with the SDKs isomer registers now, by everything it is
made of (isomer's graph, those SDKs' URLs and sha256s, the consumer's
MODULE.bazel and Package.resolved, the variant, the image) and restored only
by that exact key. The upgraded builds, against the candidate SDKs, have no
disk cache: the upgrade in one output base is what the run proves, so they
are built each time. Then `sdk-check draft` drafts the release:

- its version, `<Swift version>.N` (`sdk-check version`): the N of a
  release already drafted on this commit (the run repeated), else one past
  the highest published `isomer-<Swift version>.N` release or tag: a draft
  is no release, so an unpublished draft of another commit is replaced by
  this one, under its version;
- its assets, the five SDKs and their `.sha256` files, and the run's proof:
  `proof.zip` (Reviews' format 2, `sdk-check proof`: a `tests` item for each
  SDK's targets, `check-<bundle>-<arch>`, each consumer cell,
  `smoke-<variant>-api<N>`, and each emulator cell,
  `emulator-<variant>-api<N>`, every one with its job's log), with
  build_tools' `proof-diff.json` comparing it with the release before.
  Reviews' Release waits for a commit's proof;
- its notes, the checks the run passed, each SDK's SHA-256, the lines a
  consumer's MODULE.bazel registers them with, and the commits since the
  release before;
- never over a published release of that tag (consumers pin its sha256).

The owner publishes the draft in Reviews, which makes its tag,
`isomer-<Swift version>.N`. No agent publishes a release or makes a tag.
`sdk-check draft --dry-run` reads the releases and says what it would write.

## Wine

The repository also releases Wine Staging for arm64 Linux, what Nimbus'
`nimbus-base` image's windows layer unpacks as `/opt/wine`
(AttilaTheFun/nimbus's tools/images/nimbus-base/windows.Containerfile, by
URL and sha256) to run Isomer's arm64 Windows apps and tests under Wine in
Linux containers. Nobody ships Wine for arm64 Linux, and Staging's AF_UNIX
sockets are what SwiftNIO's Windows event loop needs. A release is
`wine-<version>-staging`, its asset
`wine-<version>-staging-arm64-ubuntu26.04.tar.zst` with its `.sha256`.

A Wine release is proposed by a workflow, never assembled by hand:
isomer_sdk.yml dispatched with `run: wine` (on any branch: the draft
targets main's head). What it builds is `sdk/wine/wine.json`: the
version, Wine's, Staging's and llvm-mingw's sources by URL and sha256, the
configure line and the packages. Wine's and Staging's URLs name `{version}`
(and Wine's `{major}`), so the next version is its `version` and those two
sha256s.
The `wine` job runs in Ubuntu 26.04 (by digest; its toolchain is the
build's) on GitHub's arm64 runner, with sdk-check built by swift.org's
toolchain for 26.04 in `/opt/swift`, off Wine's PATH:

- `sdk-check wine-build --apt`: the recipe's build packages, the sources
  fetched and checked by sha256, Staging's every patch
  (`patchinstall.py --all --backend=patch`, checked for `afunix.h`),
  `./configure` with the recipe's line and llvm-mingw for the arm64 PE side,
  `make`, `make install` into a directory of its own, then `opt/wine`
  packed (names sorted, owned by root, zstd -19) with
  `share/doc/wine/BUILD-INFO` (the sources, the configure line, the
  machine and the run) and Wine's LICENSE, COPYING.LIB and AUTHORS;
- `sdk-check wine-check --apt`: the archive unpacked at `/opt`, as the
  windows layer does, then each check run and logged:
  - `archive-sha256`: the archive's SHA-256 is its `.sha256`'s;
  - `version`: `wine --version` is `wine-<version> (Staging)`;
  - `wineboot`: `wineboot -i` makes a prefix under Xvfb (1280×800×24);
  - `cmd-echo`: `wine cmd /c echo ok` says `ok`;
  - `hello-arm64`: a hello world built with llvm-mingw is an ARM64 PE
    and, under Wine, finds itself on arm64 (processor architecture 12);
  - `notepad`: Notepad's window shot cropped to it (window-shot's crop,
    in Swift), the caret's blink off (`CursorBlinkRate` -1), and the same
    pixels again three seconds later;
- `sdk-check wine-proof`: `proof.zip` (Reviews' format 2): a `tests` item
  each, `wine/archive-sha256`, `wine/version`, `wine/wineboot`,
  `wine/cmd-echo` and `wine/hello-arm64`, with its log, and a `screen`
  item, `wine/notepad`; the ids are wine-11.21-staging's, so releases
  compare item by item. Its version is the tag, its commit main's head.

Then `wine-draft` (the only Wine job that writes) compares the proof with
the last published `wine-*` release's (build_tools' `proof-diff`,
`PROOF_TAG_PREFIX=wine-`) and runs `sdk-check wine-draft`: a draft tagged
`wine-<version>-staging` (Shireworks lists a draft only if its target is
on the branch its tag implies, and a suffixed tag implies main), targeting
the proof's commit, checked to be on main, with the archive, its `.sha256`,
`proof.zip` and `proof-diff.json`, and notes giving the sources and their
sha256s, the configure line, the archive's sha256, the proof's items and
the windows layer's two lines. A draft of the tag already there is updated
(every PATCH names `tag_name`: one without it reset a draft's tag to
`untagged-…`) and its assets replaced, never a second made; a published
release of the tag is never touched. `wine-draft --dry-run` reads GitHub
and says what it would do. New Container Helper checks the draft before
the owner publishes it in Reviews, which makes its tag; then nimbus'
windows.Containerfile takes the new URL and sha256.
