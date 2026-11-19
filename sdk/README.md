# Isomer's Swift SDKs

swift.org's Swift SDKs for Android and WebAssembly with corelibs Foundation
taken out and Isomer's Foundation family put in (docs/hermetic_toolchains.md
in AttilaTheFun/isomer says why and how a consumer registers them).
`sdk/build.sh <sdk>` builds one in a Linux container; CI
(.github/workflows/isomer_sdk.yml) builds and checks all four on each push
to an `isomer-*` branch.

| SDK | archive | minimum |
| --- | --- | --- |
| Android, plain | `swift-6.4.2-RELEASE_android.artifactbundle.tar.gz` | API 23 (aarch64, x86_64, armv7) |
| Android, -i18n | `swift-6.4.2-RELEASE_android-i18n.artifactbundle.tar.gz` | API 23 (aarch64, x86_64, armv7) |
| WebAssembly, plain | `swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz` | wasm32-unknown-wasip1 |
| WebAssembly, -i18n | `swift-6.4.2-RELEASE_wasm-i18n.artifactbundle.tar.gz` | wasm32-unknown-wasip1 |

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
  (with swift-testing beside it);
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
it has. Then `sdk-check draft` drafts the release:

- its version, `<Swift version>.N`: the N of a release already drafted on
  this commit (the run repeated: that draft is replaced), else one past the
  highest `isomer-<Swift version>.N` among the releases and tags;
- its assets, the four SDKs and their `.sha256` files;
- its notes, the checks the run passed, each SDK's SHA-256, the lines a
  consumer's MODULE.bazel registers them with, and the commits since the
  release before;
- never over a published release of that tag (consumers pin its sha256).

The owner publishes the draft in Reviews, which makes its tag,
`isomer-<Swift version>.N`. No agent publishes a release or makes a tag.
`sdk-check draft --dry-run` reads the releases and says what it would write.
