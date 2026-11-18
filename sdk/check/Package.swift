// swift-tools-version: 6.0
// sdk-check: the checks sdk/build.sh runs on each Swift SDK it builds, after
// the client's (sdk/build.sh's check step): every library a module's
// importers autolink is in the SDK, each module's binary interface and its
// archive come from one build, and the archives need nothing the platform's
// oldest supported C library (Android's API level, WASI's libc) lacks.
// Built by the toolchain sdk/build.sh downloads, for the machine it runs on.
import PackageDescription

let package = Package(
    name: "sdk-check",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "sdk-check",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
    ]
)
