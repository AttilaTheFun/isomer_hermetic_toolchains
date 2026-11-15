// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

// Availability Macros

let availabilityTags: [_Availability] = [
    _Availability("FoundationPreview"), // Default FoundationPreview availability
]
let versionNumbers = ["6.0.2", "6.1", "6.2", "6.3", "6.4", "6.4.2"]

// Availability Macro Utilities

enum _OSAvailability: String {
    case alwaysAvailable = "macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26" // This should match the package's deployment target
    // Use 10000 for future availability to avoid compiler magic around the 9999 version number but ensure it is greater than 9999
    case future = "macOS 10000, iOS 10000, tvOS 10000, watchOS 10000, visionOS 10000"
}
struct _Availability {
    let name: String
    let osAvailability: _OSAvailability
    
    init(_ name: String, availability: _OSAvailability = .alwaysAvailable) {
        self.name = name
        self.osAvailability = availability
    }
}
let availabilityMacros: [SwiftSetting] = versionNumbers.flatMap { version in
    availabilityTags.map {
        .enableExperimentalFeature("AvailabilityMacro=\($0.name) \(version):\($0.osAvailability.rawValue)")
    }
}

let featureSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableExperimentalFeature("ImportMacroAliases"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .swiftLanguageMode(.v5)
]

var dependencies: [Package.Dependency] = []

if let useLocalDepsEnv = Context.environment["SWIFTCI_USE_LOCAL_DEPS"], !useLocalDepsEnv.isEmpty {
    let root: String
    if useLocalDepsEnv == "1" {
        root = ".."
    } else {
        root = useLocalDepsEnv
    }
    dependencies += 
        [
            .package(
                name: "swift-collections",
                path: "\(root)/swift-collections"),
            .package(
                name: "swift-foundation-icu",
                path: "\(root)/swift-foundation-icu"),
            .package(
                name: "swift-syntax",
                path: "\(root)/swift-syntax")
        ]
} else {
    // These dependencies should match `update-checkout`
    // See `update-checkout-config.json` for the `main` branch-scheme
    dependencies += 
        [
            .package(
                url: "https://github.com/apple/swift-collections",
                exact: "1.1.6"),
            .package(
                url: "https://github.com/apple/swift-foundation-icu",
                branch: "release/6.4.x"),
            .package(
                url: "https://github.com/swiftlang/swift-syntax",
                branch: "release/6.4.x")
        ]
}

let wasiLibcCSettings: [CSetting] = [
    .define("_WASI_EMULATED_SIGNAL", .when(platforms: [.wasi])),
    .define("_WASI_EMULATED_MMAN", .when(platforms: [.wasi])),
]

let testOnlySwiftSettings: [SwiftSetting] = [
    .define("FOUNDATION_EXIT_TESTS", .when(platforms: [.macOS, .linux, .openbsd, .windows]))
]

let package = Package(
    name: "swift-foundation",
    platforms: [.macOS("26"), .iOS("26"), .tvOS("26"), .watchOS("26"), .visionOS("26")],
    products: [
        .library(name: "FoundationEssentials", targets: ["FoundationEssentials"]),
        .library(name: "FoundationInternationalization", targets: ["FoundationInternationalization"]),
    ],
    dependencies: dependencies,
    targets: [
        // _FoundationCShims (Internal)
        .target(
            name: "_FoundationCShims",
            cSettings: [
                .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows]))
            ] + wasiLibcCSettings
        ),

        // TestSupport (Internal)
        .target(
            name: "TestSupport",
            path: "Tests/TestSupport",
            cSettings: wasiLibcCSettings,
            swiftSettings: availabilityMacros + featureSettings
        ),

        // FoundationEssentials
        .target(
          name: "FoundationEssentials",
          dependencies: [
            "_FoundationCShims",
            "FoundationMacros",
            .product(name: "_RopeModule", package: "swift-collections"),
            .product(name: "DequeModule", package: "swift-collections"),
            .product(name: "OrderedCollections", package: "swift-collections"),
          ],
          exclude: [
            "Formatting/CMakeLists.txt",
            "PropertyList/CMakeLists.txt",
            "Decimal/CMakeLists.txt",
            "String/CMakeLists.txt",
            "Error/CMakeLists.txt",
            "Locale/CMakeLists.txt",
            "Data/CMakeLists.txt",
            "TimeZone/CMakeLists.txt",
            "JSON/CMakeLists.txt",
            "AttributedString/CMakeLists.txt",
            "Calendar/CMakeLists.txt",
            "Predicate/CMakeLists.txt",
            "CMakeLists.txt",
            "ProcessInfo/CMakeLists.txt",
            "FileManager/CMakeLists.txt",
            "URL/CMakeLists.txt",
            "NotificationCenter/CMakeLists.txt",
            "ProgressManager/CMakeLists.txt",
          ],
          cSettings: [
            .define("_GNU_SOURCE", .when(platforms: [.linux, .wasi]))
          ] + wasiLibcCSettings,
          swiftSettings: [
            .enableExperimentalFeature("VariadicGenerics"),
            .enableExperimentalFeature("Lifetimes"),
            .enableExperimentalFeature("AddressableTypes"),
            .enableExperimentalFeature("AllowUnsafeAttribute"),
            .enableExperimentalFeature("BuiltinModule"),
            .enableExperimentalFeature("AccessLevelOnImport"),
            .define("DATA_LEGACY_ABI", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
          ] + availabilityMacros + featureSettings,
          linkerSettings: [
            .linkedLibrary("wasi-emulated-getpid", .when(platforms: [.wasi])),
          ]
        ),
        .testTarget(
            name: "FoundationEssentialsTests",
            dependencies: [
                "TestSupport",
                "FoundationEssentials"
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .define("DATA_LEGACY_ABI", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ] + availabilityMacros + featureSettings + testOnlySwiftSettings
        ),

        // FoundationInternationalization
        .target(
            name: "FoundationInternationalization",
            dependencies: [
                .target(name: "FoundationEssentials"),
                .target(name: "_FoundationCShims"),
            ],
            exclude: [
                "String/CMakeLists.txt",
                "TimeZone/CMakeLists.txt",
                "ICU/CMakeLists.txt",
                "Formatting/CMakeLists.txt",
                "Locale/CMakeLists.txt",
                "Calendar/CMakeLists.txt",
                "CMakeLists.txt",
                "Predicate/CMakeLists.txt",
            ],
            cSettings: wasiLibcCSettings,
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport"),
                .enableExperimentalFeature("Lifetimes"),
            ] + availabilityMacros + featureSettings,
            linkerSettings: [
                .linkedLibrary("_FoundationICU"),
            ]
        ),
        
        .testTarget(
            name: "FoundationInternationalizationTests",
            dependencies: [
                "TestSupport",
                "FoundationInternationalization",
            ],
            swiftSettings: availabilityMacros + featureSettings + testOnlySwiftSettings
        ),
        
        // FoundationMacros
        .macro(
            name: "FoundationMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport")
            ] + availabilityMacros + featureSettings
        ),
        
        .testTarget(
            name: "FoundationMacrosTests",
            dependencies: [
                "FoundationMacros",
                "FoundationEssentials"
            ],
            swiftSettings: availabilityMacros + featureSettings + testOnlySwiftSettings
        )
    ]
)

// MARK: - Isomer
//
// What Isomer adds (Isomer/Sources): its Foundation over FoundationEssentials,
// the modules that come with it (FoundationNetworking, IsomerFoundation,
// CoreGraphics, Combine) and their helpers. Built into Isomer's Swift SDKs for
// the platforms without Apple's Foundation (docs/hermetic_toolchains.md in
// AttilaTheFun/isomer), where every `import Foundation` is this one. Kept here,
// below swift-foundation's own declarations, so a new release's Package.swift
// rebases under it.
//
// The targets are isomer's Package.swift's, built the same way, with two
// differences that come from living here: Foundation is in swift-foundation's
// package without asking (isomer passes `-package-name swift-foundation`), and
// each target names its language mode, which isomer's package sets for all
// of them (`swiftLanguageModes: [.v5]`) and this one, at tools version 6.2,
// would otherwise take to be Swift 6.

// FoundationInternationalization in Foundation, as isomer's
// `--@isomer//foundation:internationalization` adds it: a module that
// re-exports it, which Foundation re-exports when it can import it
// (Foundation.swift's `canImport(IsomerFoundationInternationalization)`). A
// build's choice, so an environment variable's; off by default, as isomer's
// flag is, and in the SDK sdk/build.sh makes (its ICU comes later).
let isomerInternationalization = Context.environment["ISOMER_FOUNDATION_INTERNATIONALIZATION"] == "1"

package.products += [
    .library(name: "Foundation", targets: ["Foundation"]),
    .library(name: "FoundationNetworking", targets: ["FoundationNetworking"]),
    .library(name: "IsomerFoundation", targets: ["IsomerFoundation"]),
    .library(name: "CoreGraphics", targets: ["CoreGraphics"]),
    .library(name: "Combine", targets: ["Combine"]),
]

package.targets += [
    .target(
        name: "CoreGraphics",
        path: "Isomer/Sources/CoreGraphics",
        swiftSettings: [
            // The toolchain's corelibs Foundation declares CGFloat and the
            // geometry types there, until those SDKs carry this Foundation.
            .define("ISOMER_CORELIBS_FOUNDATION", .when(platforms: [.linux, .windows])),
            .swiftLanguageMode(.v5),
        ]
    ),
    .target(
        name: "Combine",
        path: "Isomer/Sources/Combine",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "IsomerFoundation",
        dependencies: ["FoundationEssentials"],
        path: "Isomer/Sources/IsomerFoundation",
        swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
    ),
    .target(
        name: "IsomerDispatchTime",
        path: "Isomer/Sources/IsomerDispatchTime",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "CWasiThreadIdentity",
        path: "Isomer/Sources/CWasiThreadIdentity",
        publicHeadersPath: "."
    ),
    .target(
        name: "IsomerFoundationInternationalization",
        dependencies: ["FoundationInternationalization"],
        path: "Isomer/Sources/IsomerFoundationInternationalization",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        // In this package, so its string API searches with FoundationEssentials'
        // `package` helpers.
        name: "Foundation",
        dependencies: [
            "Combine",
            "CoreGraphics",
            "IsomerFoundation",
            "FoundationEssentials",
            .target(name: "IsomerDispatchTime", condition: .when(platforms: [.android, .wasi])),
            .target(name: "CWasiThreadIdentity", condition: .when(platforms: [.wasi])),
        ] + (isomerInternationalization ? ["IsomerFoundationInternationalization"] : []),
        path: "Isomer/Sources/Foundation",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "FoundationNetworking",
        dependencies: ["Foundation"],
        path: "Isomer/Sources/FoundationNetworking",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// Link names, for a Swift SDK's build (sdk/build.sh sets ISOMER_SWIFT_SDK).
// A client's object records the libraries its imports name, by the link
// names their modules carry when it compiles, and SwiftPM gives a module
// none: so in an SDK, whose archives no build system lists, every Swift
// module carries its own name (`-module-link-name`), and `import Foundation`
// links libFoundation.a. Unsafe flags, so only for that build: a package
// that depends on this one by version can't take them.
//
// On WASI, each module also asks its clients for wasi-libc's emulated
// getpid, signals and mmap, as swift-foundation's CMake build makes the stock
// SDK's do (CMakeLists.txt's `-public-autolink-library` for a static build):
// FoundationEssentials calls them, and SwiftPM's `linkedLibrary` only reaches
// this package's own links, never a client's.
//
// And no module hash in the objects (`-disable-incremental-llvm-codegen`):
// a hash of each object's LLVM module, which differs with the build's paths
// while the rest of the object doesn't, read only by the compiler's
// incremental code generation. Without it an SDK is the same wherever it is
// built. (On ELF it is a section objcopy could strip; on wasm a data
// segment, which it can't.)
if Context.environment["ISOMER_SWIFT_SDK"] == "1" {
    let cTargets: Set<String> = ["_FoundationCShims", "CWasiThreadIdentity"]
    let wasiEmulated = ["wasi-emulated-getpid", "wasi-emulated-signal", "wasi-emulated-mman"]
        .flatMap { ["-Xfrontend", "-public-autolink-library", "-Xfrontend", $0] }
    for target in package.targets where target.type == .regular && !cTargets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + [
            .unsafeFlags(["-module-link-name", target.name, "-Xfrontend", "-disable-incremental-llvm-codegen"]),
            .unsafeFlags(wasiEmulated, .when(platforms: [.wasi])),
        ]
    }
}
