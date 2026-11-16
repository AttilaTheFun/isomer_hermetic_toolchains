#!/bin/bash
# Builds one of Isomer's Swift SDKs: swift.org's SDK for the target with
# corelibs Foundation taken out and Isomer's Foundation family put in, so that
# every `import Foundation` built with it is Isomer's
# (docs/hermetic_toolchains.md in AttilaTheFun/isomer).
#
#   sdk/build.sh <sdk> [--out=DIR] [--work=DIR]
#
#   android          swift.org's Android bundle, every architecture in it
#                    switched: aarch64, x86_64 and armv7
#   android-<arch>   the same bundle with that architecture alone switched
#                    (a quicker build; the others stay swift.org's)
#   wasm             swift.org's WebAssembly bundle, wasm32-unknown-wasip1
#   <any>-i18n       the same with FoundationInternationalization in
#                    Foundation (dates, numbers, lists and measurements
#                    formatted as on Apple's platforms) and the SDK's ICU
#                    linked for it: android-i18n, wasm-i18n. Its archive is
#                    named for the variant (…_android-i18n.artifactbundle
#                    .tar.gz); the bundle inside is the plain one's name.
#
# Runs on Linux (Ubuntu 24.04, arm64 or x86_64: a Shireworks container of
# Visor's agent image, or GitHub's ubuntu-24.04 runner), never on a Mac's own
# disk. It needs curl, git, tar, gzip, unzip and sha256sum, and the libraries
# swift.org's toolchain runs on; everything else it downloads, each download
# checked against the checksum below.
#
# Steps (each prints a line as it starts; build, assemble and check once per
# architecture):
#   fetch      swift.org's 6.4.2 toolchain for this host, the SDK's artifact
#              bundle (the one rules_swift registers for `swift.android_sdk()`
#              or `swift.wasm_sdk()`), and for Android the NDK the bundle's
#              setup script links to (r30, isomer's)
#   deps       swift-foundation's dependencies at the 6.4.2 release, cloned
#              beside the package (SWIFTCI_USE_LOCAL_DEPS, as Swift's own CI
#              builds it): a local package may carry unsafe flags, a versioned
#              one may not, and swift-collections' modules need link names too
#   prune      the stock bundle unpacked, corelibs Foundation taken out of
#              each switched architecture's static resources
#   build      the family built by SwiftPM, -c release, against the pruned
#              bundle (no corelibs module to find by mistake), each Swift
#              module with `-module-link-name <its name>`
#   assemble   the family's modules and archives put in, the helpers folded
#              into the archives clients autolink
#   pack       the bundle archived reproducibly (sorted, clamped times, no
#              owners), named as swift.org's so rules_swift takes it by
#              checksum from a --distdir; its sha256 beside it
#   check      a client package built and linked against the new bundle:
#              what `import Foundation` autolinks, and that the program has
#              Isomer's Foundation and nothing of corelibs'; on wasm the
#              program is also run, under the toolchain's WasmKit, and so are
#              two swift-testing tests that use Foundation
#
# Only static resources change: rules_swift links Swift statically. Android's
# dynamic resources (swift-<arch>/) stay swift.org's; wasm has none apart
# (its bundle's swift/ directory holds no Foundation).
# FoundationInternationalization is in only the -i18n variant, where
# Foundation re-exports it and it autolinks the SDK's own ICU
# (lib_FoundationICU.a and _foundation_unicode/, which every variant keeps as
# swift.org ships them). Without it an app links no ICU at all: the plain SDK
# is for apps that format nothing with Foundation, the -i18n one for those
# that do (ICU's data is most of an app's size: tens of megabytes, which the
# web's icu_locales trims).
set -euo pipefail
umask 022

REPO="$(cd "$(dirname "$0")/.." && pwd)"

usage() { echo "usage: sdk/build.sh <android|android-aarch64|android-x86_64|android-armv7|wasm>[-i18n] [--out=DIR] [--work=DIR]" >&2; exit 2; }
[ $# -ge 1 ] || usage
TARGET=$1; shift
# The variant: -i18n, FoundationInternationalization in Foundation.
I18N=0
case "$TARGET" in *-i18n) I18N=1; TARGET="${TARGET%-i18n}" ;; esac
OUT="$REPO/.build/isomer-sdk/out"
WORK="$REPO/.build/isomer-sdk/work"
for arg in "$@"; do
    case "$arg" in
        --out=*) OUT="${arg#--out=}" ;;
        --work=*) WORK="${arg#--work=}" ;;
        *) usage ;;
    esac
done

# --- what is built ------------------------------------------------------------

SWIFT_VERSION=6.4.2
# The SDKs' checksums are rules_swift's for 6.4.2 (its
# swift_release_metadata.json, in the project registry's 4.2.2.isomer.3), and
# their URLs where rules_swift downloads them from (swift_sdk_releases.bzl).
case "$TARGET" in
    android|android-aarch64|android-x86_64|android-armv7)
        PLATFORM=android
        if [ "$TARGET" = android ]; then ARCHES=(aarch64 x86_64 armv7); else ARCHES=("${TARGET#android-}"); fi
        BUNDLE=swift-$SWIFT_VERSION-RELEASE_android.artifactbundle
        SDK_URL=https://download.swift.org/swift-$SWIFT_VERSION-release/android-sdk/swift-$SWIFT_VERSION-RELEASE/$BUNDLE.tar.gz
        SDK_SHA256=4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233
        # isomer's NDK targets API 28 (MODULE.bazel's android.ndk), and
        # rules_swift compiles for the NDK's API. The bundle names armv7's
        # triple `armv7-unknown-linux-android28` (its swift-sdk.json), which
        # the compiler takes as androideabi.
        API=28
        ;;
    wasm)
        PLATFORM=wasi
        ARCHES=(wasm32)
        BUNDLE=swift-$SWIFT_VERSION-RELEASE_wasm.artifactbundle
        SDK_URL=https://download.swift.org/swift-$SWIFT_VERSION-release/wasm-sdk/swift-$SWIFT_VERSION-RELEASE/$BUNDLE.tar.gz
        SDK_SHA256=83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
        ;;
    *) echo "unknown SDK $TARGET" >&2; usage ;;
esac
# The archive is named for the variant, so a URL says which it is: swift.org's
# name (`…_android.artifactbundle.tar.gz`, which rules_swift's default
# download is), or with -i18n after the platform. rules_swift finds the
# bundle inside by its one .artifactbundle directory, whatever the archive's
# name, so the directory keeps swift.org's.
if [ $I18N = 1 ]; then
    ARCHIVE_NAME="${BUNDLE%.artifactbundle}-i18n.artifactbundle.tar.gz"
else
    ARCHIVE_NAME="$BUNDLE.tar.gz"
fi

# The triple SwiftPM is given (a key of the bundle's swift-sdk.json), and the
# architecture's static resources, relative to the unpacked bundle. Android's
# bundle has a directory per architecture; wasm's one, beside its embedded
# Swift variant (which has no Foundation and is left alone).
triple_of() {
    case "$PLATFORM" in
        android) echo "$1-unknown-linux-android$API" ;;
        wasi) echo "wasm32-unknown-wasip1" ;;
    esac
}
static_rel_of() {
    case "$PLATFORM" in
        android) echo "swift-android/swift-resources/usr/lib/swift_static-$1" ;;
        wasi) echo "swift-$SWIFT_VERSION-RELEASE_wasm/wasm32-unknown-wasip1/swift.xctoolchain/usr/lib/swift_static" ;;
    esac
}
# What SwiftPM's --swift-sdk names: Android's triple selects its variant, but
# wasm's bundle has two SDKs for one triple (Swift and embedded Swift), so the
# artifact's id.
swift_sdk_of() {
    case "$PLATFORM" in
        android) triple_of "$1" ;;
        wasi) echo "swift-$SWIFT_VERSION-RELEASE_wasm" ;;
    esac
}

# swift.org's toolchain for this host: the SDK needs its compiler exactly.
case "$(uname -m)" in
    aarch64|arm64)
        TOOLCHAIN_PLATFORM=ubuntu24.04-aarch64
        TOOLCHAIN_SHA256=307772afcc0b9501faa4797eb4197076facf5768593a0d8d2b83615c95b0040e ;;
    x86_64)
        TOOLCHAIN_PLATFORM=ubuntu24.04
        TOOLCHAIN_SHA256=2e9ebec040ad459dd89a6d093a02d8314939135104850fae4d5c0f174fb3ba8c ;;
    *) echo "no swift.org toolchain for $(uname -m)" >&2; exit 1 ;;
esac
TOOLCHAIN_URL=https://download.swift.org/swift-$SWIFT_VERSION-release/${TOOLCHAIN_PLATFORM//[.]/}/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-$TOOLCHAIN_PLATFORM.tar.gz

# The Android NDK, isomer's (hermetic_android_toolchains' r30). Google
# publishes its sha1 (5107f898313790e449e87eee2183d9a20602dee9); this is the
# same archive's sha256. Only its sysroot and clang headers are used, and only
# on the host: its programs are x86_64 Linux's. (wasm's bundle carries its
# own sysroot, WASI.sdk.)
NDK_URL=https://dl.google.com/android/repository/android-ndk-r30-linux.zip
NDK_SHA256=753611f410d002cfcd3f3dc2ef49aad532089d3180b436c060a90bf0fcb64df2

# swift-foundation's dependencies at the commits its 6.4.2 release takes
# (isomer's Package.resolved has the same): swift-collections by its
# version, the others by their swift-6.4.2-RELEASE tags. swift-foundation-icu
# is only resolved: Isomer's ICU patch links the SDK's ICU instead.
DEPS=(
    "swift-collections https://github.com/apple/swift-collections.git 1.1.6 c11818f3cae0780656baa430b49e7f163f08dffd"
    "swift-syntax https://github.com/swiftlang/swift-syntax.git swift-6.4.2-RELEASE 050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf"
    "swift-foundation-icu https://github.com/apple/swift-foundation-icu.git swift-6.4.2-RELEASE f986d0728da0766cf81f371521b909d4a11681d2"
)

# What clients import, built with their dependencies (by target: SwiftPM
# builds an automatic library product only as a dependency): every module
# the build makes for the target goes into the SDK. FoundationNetworking too
# on wasm, whose stock SDK has none: Isomer's is a module that re-exports its
# Foundation's URLSession, so code written for Linux's
# `#if canImport(FoundationNetworking)` sees the one URLSession there as well.
TARGETS=(Foundation FoundationNetworking CoreGraphics Combine IsomerFoundation)
# The helpers no client imports by name, folded into the archive a client
# does autolink (below). CWasiThreadIdentity is Foundation's on wasm only; a
# helper the build didn't make is skipped.
FOLD_INTO_ESSENTIALS=(DequeModule InternalCollectionsUtilities OrderedCollections _RopeModule _FoundationCShims)
FOLD_INTO_FOUNDATION=(IsomerFoundation IsomerDispatchTime CWasiThreadIdentity)
# The archives every build must have made.
REQUIRED_ARCHIVES=(Foundation FoundationNetworking FoundationEssentials IsomerFoundation IsomerDispatchTime CoreGraphics Combine
    DequeModule InternalCollectionsUtilities OrderedCollections _RopeModule _FoundationCShims)
# The -i18n variant: Foundation's dependency on IsomerFoundationInternationalization
# (Package.swift's ISOMER_FOUNDATION_INTERNATIONALIZATION) builds it and
# FoundationInternationalization, which clients autolink through Foundation's
# re-export, as they do Foundation: nothing to fold. FoundationInternationalization
# asks its clients for the SDK's ICU, _FoundationICU (Package.swift's
# ISOMER_SWIFT_SDK block).
[ $I18N = 0 ] || REQUIRED_ARCHIVES+=(FoundationInternationalization IsomerFoundationInternationalization)

# Corelibs' Foundation in the stock SDK: its Swift modules, its archives and
# what they alone link (CoreFoundation and its shims; on Android curl,
# libxml2 and OpenSSL, which wasm's bundle keeps in its WASI.sdk sysroot,
# left as it is). On wasm also what is built on corelibs Foundation and would
# bring it back: XCTest (its module crashes the compiler against this
# Foundation, `_BridgedStoredNSError` not found, and libXCTest.a wants
# corelibs' symbols) and swift-testing's Foundation overlay
# (_Testing_Foundation, loaded by `import Testing` beside `import
# Foundation`). The overlays' declarations go with them: swift-testing's
# Testing.swiftcrossimport names a Foundation overlay, and a CoreGraphics one
# that only Apple's SDKs carry, which this SDK's CoreGraphics would now ask
# for ("no such module '_Testing_CoreGraphics'"). Testing itself stays: it
# links against this FoundationEssentials (the check runs a test).
# Android's static resources have neither XCTest nor Testing.
case "$PLATFORM" in
    android)
        CORELIBS_MODULES=(Foundation FoundationNetworking FoundationXML FoundationEssentials FoundationInternationalization _FoundationCollections)
        CORELIBS_ARCHIVES=(Foundation FoundationNetworking FoundationXML FoundationEssentials FoundationInternationalization
            _FoundationCollections _FoundationCShims CoreFoundation _CFURLSessionInterface _CFXMLInterface curl xml2 ssl crypto)
        CORELIBS_OTHER=()
        ;;
    wasi)
        CORELIBS_MODULES=(Foundation FoundationXML FoundationEssentials FoundationInternationalization _FoundationCollections
            XCTest _Testing_Foundation)
        CORELIBS_ARCHIVES=(Foundation FoundationXML FoundationEssentials FoundationInternationalization
            _FoundationCollections _FoundationCShims CoreFoundation _CFXMLInterface XCTest _Testing_Foundation)
        CORELIBS_OTHER=(Testing.swiftcrossimport/Foundation.swiftoverlay Testing.swiftcrossimport/CoreGraphics.swiftoverlay)
        ;;
esac

# --- helpers ------------------------------------------------------------------

DOWNLOADS="$WORK/downloads"
TOOLCHAIN="$WORK/toolchain"
NDK="$WORK/ndk"
PRUNED="$WORK/pruned"           # the stock bundle, corelibs out: what goes out
BUILD_SDKS="$WORK/sdks/build"   # a copy of it set up to build with
CHECK_SDKS="$WORK/sdks/check"   # the finished bundle set up to check
BIN="$TOOLCHAIN/usr/bin"

step() { echo; echo "=== $* ($(date -u +%H:%M:%S))"; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
size_of() { stat -c %s "$1"; }
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# fetch <url> <sha256> <file>: downloaded once, checked every time.
fetch() {
    local url=$1 sha=$2 file="$DOWNLOADS/$3"
    if [ ! -f "$file" ] || [ "$(sha256_of "$file")" != "$sha" ]; then
        echo "downloading $url"
        curl -fL --retry 3 -sS -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    [ "$(sha256_of "$file")" = "$sha" ] || { echo "$file: sha256 is not $sha" >&2; exit 1; }
    echo "$3: $(human "$(size_of "$file")"), sha256 $sha"
}

# set_up <dir containing the bundle>: Android's bundle's own setup script
# links the NDK's sysroot and clang headers into it, as a user does once
# after `swift sdk install`. Only on copies: what goes out stays as
# swift.org shipped it. wasm's bundle needs nothing.
set_up() {
    [ "$PLATFORM" = android ] || return 0
    ANDROID_NDK_HOME="$NDK" bash "$1/$BUNDLE/swift-android/scripts/setup-android-sdk.sh"
}

# The libraries an object's `import`s autolink: its
# .swift1_autolink_entries section (what `llvm-objdump -s -j` shows), read
# whole, its NUL-separated entries one a line. (objdump's text column wraps
# entries across lines, and a parse of it loses some.)
autolinks_of() {
    local section copy
    section="$(mktemp)"; copy="$(mktemp)"
    "$BIN/llvm-objcopy" --dump-section=.swift1_autolink_entries="$section" "$1" "$copy"
    tr '\0' '\n' < "$section"
    rm -f "$section" "$copy"
}

# --- fetch --------------------------------------------------------------------

step fetch "$TARGET$([ $I18N = 0 ] || echo ' (-i18n: with FoundationInternationalization)'): ${ARCHES[*]}"
[ "$(uname -s)" = Linux ] || { echo "sdk/build.sh runs on Linux (a container), not $(uname -s)" >&2; exit 1; }
mkdir -p "$DOWNLOADS" "$OUT"
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256" "swift-$SWIFT_VERSION-RELEASE-$TOOLCHAIN_PLATFORM.tar.gz"
fetch "$SDK_URL" "$SDK_SHA256" "$BUNDLE.tar.gz"
[ "$PLATFORM" != android ] || fetch "$NDK_URL" "$NDK_SHA256" android-ndk-r30-linux.zip

if [ ! -x "$BIN/swift" ] || [ "$(cat "$TOOLCHAIN/.sha256" 2>/dev/null)" != "$TOOLCHAIN_SHA256" ]; then
    rm -rf "$TOOLCHAIN"; mkdir -p "$TOOLCHAIN"
    tar -xzf "$DOWNLOADS/swift-$SWIFT_VERSION-RELEASE-$TOOLCHAIN_PLATFORM.tar.gz" -C "$TOOLCHAIN" --strip-components=1
    echo "$TOOLCHAIN_SHA256" > "$TOOLCHAIN/.sha256"
fi
"$BIN/swift" --version 2>&1 | sed -n 1p
if [ "$PLATFORM" = android ]; then
    if [ ! -f "$NDK/source.properties" ]; then
        rm -rf "$NDK" "$WORK/ndk.unzip"; mkdir -p "$WORK/ndk.unzip"
        unzip -q "$DOWNLOADS/android-ndk-r30-linux.zip" -d "$WORK/ndk.unzip" \
            'android-ndk-r30/source.properties' \
            'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/sysroot/*' \
            'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*'
        mv "$WORK/ndk.unzip/android-ndk-r30" "$NDK"; rmdir "$WORK/ndk.unzip"
    fi
    echo "NDK $(sed -n 's/^Pkg.Revision = //p' "$NDK/source.properties"): its sysroot and clang headers"
fi

# --- deps ---------------------------------------------------------------------

step deps
mkdir -p "$WORK/deps"
for dep in "${DEPS[@]}"; do
    read -r name url ref commit <<< "$dep"
    dir="$WORK/deps/$name"
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
        rm -rf "$dir"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$url" "$dir"
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "$name at $ref is not $commit" >&2; exit 1; }
    git -C "$dir" checkout -q -- Package.swift
    echo "$name $ref ($commit)"
done
# swift-collections' modules carry their link names too, as this package's
# do (Package.swift's ISOMER_SWIFT_SDK): FoundationEssentials imports them.
# And no module hash in their objects, as this package's (the same block).
cat >> "$WORK/deps/swift-collections/Package.swift" <<'EOF'

// Isomer's Swift SDK build (isomer_hermetic_toolchains' sdk/build.sh): each
// module carries its link name, and its objects no module hash, as
// swift-foundation's do there.
for target in package.targets where target.type == .regular {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-module-link-name", target.name, "-Xfrontend", "-disable-incremental-llvm-codegen"]),
    ]
}
EOF

# The package built from a copy under a fixed name: SwiftPM names a root
# package after its directory and compiles every module with that
# `-package-name`, which its .swiftmodule records, so a checkout named
# otherwise (isomer_hermetic_toolchains, a CI runner's) would make other
# modules. swift-foundation is the name isomer gives these modules too.
PACKAGE="$WORK/package/swift-foundation"
rm -rf "$WORK/package"; mkdir -p "$PACKAGE"
tar -C "$REPO" --exclude=./.git --exclude=./.build --exclude=./.swiftpm -cf - . | tar -C "$PACKAGE" -xf -
echo "the package: $REPO, copied to $PACKAGE"

# --- prune ----------------------------------------------------------------------

step prune "the stock bundle, corelibs Foundation out of ${ARCHES[*]}"
rm -rf "$PRUNED"; mkdir -p "$PRUNED"
tar -xzf "$DOWNLOADS/$BUNDLE.tar.gz" -C "$PRUNED"
declare -A STOCK_STATIC_BYTES MODULE_TRIPLE
for arch in "${ARCHES[@]}"; do
    STATIC="$PRUNED/$BUNDLE/$(static_rel_of "$arch")"
    OS_DIR="$STATIC/$PLATFORM"
    [ -d "$OS_DIR" ] || { echo "unexpected layout: no $OS_DIR" >&2; exit 1; }
    STOCK_STATIC_BYTES[$arch]="$(du -sb "$OS_DIR" | cut -f1)"
    # The name a module's file for this architecture has in a .swiftmodule
    # directory (the triple without an API level, as the compiler normalizes
    # it): read from the stock Foundation's, which the build's replaces.
    MODULE_TRIPLE[$arch]="$(basename "$(ls "$OS_DIR"/Foundation.swiftmodule/*.swiftmodule | head -1)" .swiftmodule)"
    echo "-- $arch: modules are $OS_DIR/<module>.swiftmodule/${MODULE_TRIPLE[$arch]}.swiftmodule"
    for m in "${CORELIBS_MODULES[@]}"; do
        [ -d "$OS_DIR/$m.swiftmodule" ] || { echo "the stock SDK has no $m.swiftmodule for $arch" >&2; exit 1; }
        rm -rf "$OS_DIR/$m.swiftmodule"
    done
    for l in "${CORELIBS_ARCHIVES[@]}"; do
        [ -f "$OS_DIR/lib$l.a" ] || { echo "the stock SDK has no lib$l.a for $arch" >&2; exit 1; }
        echo "  out: lib$l.a ($(human "$(size_of "$OS_DIR/lib$l.a")"))"
        rm -f "$OS_DIR/lib$l.a"
    done
    for f in "${CORELIBS_OTHER[@]}"; do
        [ -e "$OS_DIR/$f" ] || { echo "the stock SDK has no $f for $arch" >&2; exit 1; }
        rm -rf "${OS_DIR:?}/$f"
        echo "  out: $f"
    done
    # CoreFoundation's clang module; the C shims' is replaced by the build's.
    rm -rf "$STATIC/CoreFoundation" "$STATIC/_FoundationCShims"
    echo "  out: ${CORELIBS_MODULES[*]} (.swiftmodule), CoreFoundation/ and _FoundationCShims/ (clang modules)"
done

# --- build, assemble ------------------------------------------------------------

rm -rf "$BUILD_SDKS"; mkdir -p "$BUILD_SDKS"
cp -a "$PRUNED/$BUNDLE" "$BUILD_SDKS/"
set_up "$BUILD_SDKS"

# Autolink entries are written when the importing module compiles: a client
# of Foundation records the libraries of the modules it can see, and
# FoundationEssentials' swift-collections and C shims, and Foundation's
# IsomerFoundation, are imported out of its sight. So, as swift.org's SDK
# does with _FoundationCollections, each helper's archive is folded into the
# archive a client does autolink. The helpers' own archives stay too, for a
# client that imports one by name (Isomer's hosts import IsomerFoundation):
# a member already loaded from one archive leaves its copy in the other
# unloaded.
fold_into() { # <static dir> <archive's module> <helpers' modules…>
    local dir=$1 name=$2 target="$1/lib$2.a" merged="$1/lib$2.merged.a" folded=() m; shift 2
    for m in "$@"; do [ ! -f "$dir/lib$m.a" ] || folded+=("$m"); done
    {
        echo "create $merged"
        echo "addlib $target"
        for m in "${folded[@]}"; do echo "addlib $dir/lib$m.a"; done
        echo save
        echo end
    } | "$BIN/llvm-ar" -M
    # llvm-ar's MRI script writes deterministic headers too; mv keeps the name.
    mv "$merged" "$target"
    echo "  lib$name.a carries ${folded[*]} ($(human "$(size_of "$target")"))"
}

declare -A NEW_STATIC_BYTES SWIFT_MODULES
for arch in "${ARCHES[@]}"; do
    TRIPLE="$(triple_of "$arch")"
    STATIC="$PRUNED/$BUNDLE/$(static_rel_of "$arch")"
    OS_DIR="$STATIC/$PLATFORM"

    step build "the family, -c release, for $TRIPLE"
    # A fresh scratch directory for each triple: SwiftPM keeps modules a
    # build made before, and a stale one would go into the SDK.
    # SwiftPM's native build system: Swift Build, the default, looks for a
    # whole NDK installed (its compilers, x86_64 Linux's), where the native
    # one takes the SDK's sysroot alone, and leaves each target's objects in
    # a directory of its own, which is what the SDK's archives are made from.
    SCRATCH="$WORK/swiftpm/$TRIPLE$([ $I18N = 0 ] || echo -i18n)"
    rm -rf "$SCRATCH"
    for target in "${TARGETS[@]}"; do
        echo "-- $target"
        ISOMER_SWIFT_SDK=1 ISOMER_FOUNDATION_INTERNATIONALIZATION=$I18N SWIFTCI_USE_LOCAL_DEPS="$WORK/deps" \
            "$BIN/swift" build --build-system native \
            --package-path "$PACKAGE" --scratch-path "$SCRATCH" \
            --swift-sdks-path "$BUILD_SDKS" --swift-sdk "$(swift_sdk_of "$arch")" --static-swift-stdlib \
            -c release -debug-info-format none --target "$target"
    done
    # The target's products: the release directory that has Modules and
    # isn't the host's (the macros' and plugins' builds are the host's).
    PRODUCTS_DIR="$(find "$SCRATCH" -mindepth 3 -maxdepth 3 -type d -name Modules -path "*/release/Modules" |
        grep -E "/[^/]*(android|wasi)[^/]*/release/Modules$" | head -1 | xargs -r dirname)"
    [ -n "$PRODUCTS_DIR" ] && [ -d "$PRODUCTS_DIR/Modules" ] || { echo "no $TRIPLE build under $SCRATCH" >&2; exit 1; }
    echo "built in $PRODUCTS_DIR"

    step assemble "the family into $(static_rel_of "$arch")"
    # Every target the build compiled for the target: a directory of objects
    # each.
    modules=()
    for dir in "$PRODUCTS_DIR"/*.build; do
        module="$(basename "$dir" .build)"
        objects=("$dir"/*.o)
        [ -e "${objects[0]}" ] || continue
        # An archive per module, its members sorted and llvm-ar's
        # deterministic headers, so the same objects make the same archive.
        rm -f "$OS_DIR/lib$module.a"
        # (Object names have spaces: FoundationEssentials' sources' do.)
        mapfile -t objects < <(printf '%s\n' "${objects[@]}" | LC_ALL=C sort)
        # (The objects carry no module hash, which differs with the build's
        # paths: Package.swift's ISOMER_SWIFT_SDK block.)
        "$BIN/llvm-ar" crsD "$OS_DIR/lib$module.a" "${objects[@]}"
        if [ -f "$PRODUCTS_DIR/Modules/$module.swiftmodule" ]; then
            mkdir -p "$OS_DIR/$module.swiftmodule"
            cp "$PRODUCTS_DIR/Modules/$module.swiftmodule" "$OS_DIR/$module.swiftmodule/${MODULE_TRIPLE[$arch]}.swiftmodule"
            [ ! -f "$PRODUCTS_DIR/Modules/$module.swiftdoc" ] ||
                cp "$PRODUCTS_DIR/Modules/$module.swiftdoc" "$OS_DIR/$module.swiftmodule/${MODULE_TRIPLE[$arch]}.swiftdoc"
            modules+=("$module")
            echo "  in: $module.swiftmodule, lib$module.a ($(human "$(size_of "$OS_DIR/lib$module.a")"))"
        else
            echo "  in: lib$module.a ($(human "$(size_of "$OS_DIR/lib$module.a")")), C"
        fi
    done
    SWIFT_MODULES[$arch]="${modules[*]}"
    for m in "${REQUIRED_ARCHIVES[@]}"; do
        [ -f "$OS_DIR/lib$m.a" ] || { echo "the build made no lib$m.a for $arch" >&2; exit 1; }
    done

    # The C shims' clang module, as the stock SDK lays it out: this package's
    # include directory, its module map naming no library (the archive is
    # folded below), as swift.org's does. (CWasiThreadIdentity, Foundation's
    # other C module, is imported only by a threaded wasm build, which this
    # SDK isn't: its archive is folded, its headers not needed.)
    mkdir -p "$STATIC/_FoundationCShims"
    cp "$PACKAGE"/Sources/_FoundationCShims/include/* "$STATIC/_FoundationCShims/"
    echo "  in: _FoundationCShims/ (clang module: $(ls "$STATIC/_FoundationCShims" | wc -l) files)"

    fold_into "$OS_DIR" FoundationEssentials "${FOLD_INTO_ESSENTIALS[@]}"
    fold_into "$OS_DIR" Foundation "${FOLD_INTO_FOUNDATION[@]}"
    NEW_STATIC_BYTES[$arch]="$(du -sb "$OS_DIR" | cut -f1)"
done

# --- pack -----------------------------------------------------------------------

step pack
# Reproducible: entries sorted, no owners, and every time no later than the
# last commit to what goes into the bundle (the stock files keep their own,
# earlier ones): the package, Isomer's sources and this script. A commit to
# anything else (CI's workflow, the Bazel module's files) leaves the bundle,
# and its checksum, as they were.
EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct -- Package.swift Sources Isomer sdk 2>/dev/null || true)}"
[ -n "$EPOCH" ] || { echo "no commit time: set SOURCE_DATE_EPOCH" >&2; exit 1; }
ARCHIVE="$OUT/$ARCHIVE_NAME"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
    --mtime="@$EPOCH" --clamp-mtime -C "$PRUNED" -cf - "$BUNDLE" | gzip -n > "$ARCHIVE.part"
mv "$ARCHIVE.part" "$ARCHIVE"
SHA256="$(sha256_of "$ARCHIVE")"
echo "$SHA256  $ARCHIVE_NAME" > "$ARCHIVE.sha256"

# --- check ----------------------------------------------------------------------

rm -rf "$CHECK_SDKS"; mkdir -p "$CHECK_SDKS"
tar -xzf "$ARCHIVE" -C "$CHECK_SDKS"
set_up "$CHECK_SDKS"
CLIENT="$WORK/client"
rm -rf "$CLIENT"; mkdir -p "$CLIENT/Sources/Client" "$CLIENT/Sources/Resilient"
cat > "$CLIENT/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Client",
    targets: [
        .executableTarget(
            name: "Client",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // A wasm program needs isomer's 16 MiB stack (its AGENTS.md):
            // Swift's generic metadata code overruns wasm-ld's default.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"], .when(platforms: [.wasi]))]
        ),
        // A library built for distribution: resilient, internal imports by
        // default, `-library-level api`, where a public import of a module
        // built without library evolution is an error. Isomer's modules in
        // the SDK are resilient (Package.swift's ISOMER_SWIFT_SDK block).
        .target(
            name: "Resilient",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .unsafeFlags(["-enable-library-evolution", "-library-level", "api"]),
            ]
        ),
    ]
)
EOF
cat > "$CLIENT/Sources/Resilient/Resilient.swift" <<'EOF'
public import Combine
public import CoreGraphics
public import Foundation

public func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect { rect.insetBy(dx: amount, dy: amount) }
public func urls() -> PassthroughSubject<URL, Never> { PassthroughSubject() }
EOF
cat > "$CLIENT/Sources/Client/main.swift" <<'EOF'
// Plain `import Foundation`, as any package's code: no dependency declared.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Combine

let json = try JSONSerialization.data(withJSONObject: ["n": 1], options: [.sortedKeys])
let subject = PassthroughSubject<Int, Never>()
let cancellable = subject.sink { print(String(format: "%05.2f", Double($0))) }
subject.send(3)
print(String(decoding: json, as: UTF8.self), CGRect(x: 0, y: 0, width: 2, height: 3).area)
print(String(reflecting: URLSession.self), URLSession(configuration: .default))
_ = cancellable
extension CGRect { var area: CGFloat { width * height } }
EOF
# What the client prints, where it can be run (wasm, under WasmKit): the
# first two lines (the third is URLSession's description), and with -i18n
# the two after it.
EXPECTED_OUTPUT='03.00
{"n":1} 6.0'
EXPECTED_I18N_OUTPUT=""
# The -i18n variant's client also formats a date and a number in other
# locales, through `import Foundation` alone: FoundationInternationalization
# and ICU's data are there.
if [ $I18N = 1 ]; then
    cat >> "$CLIENT/Sources/Client/main.swift" <<'EOF'
let epoch = Date(timeIntervalSince1970: 0)
print(epoch.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "fr_FR"), timeZone: TimeZone(identifier: "UTC")!)))
print(1234567.formatted(.number.locale(Locale(identifier: "de_DE"))))
EOF
    EXPECTED_I18N_OUTPUT='1 janvier 1970
1.234.567'
fi

for arch in "${ARCHES[@]}"; do
    TRIPLE="$(triple_of "$arch")"
    step check "a client built and linked against the new bundle, for $TRIPLE"
    rm -rf "$CLIENT/.build"
    "$BIN/swift" build --build-system native --package-path "$CLIENT" --scratch-path "$CLIENT/.build" \
        --swift-sdks-path "$CHECK_SDKS" --swift-sdk "$(swift_sdk_of "$arch")" --static-swift-stdlib -c release
    # Android's program is Client; wasm's Client.wasm.
    CLIENT_BIN="$(find "$CLIENT/.build" \( -name Client -o -name Client.wasm \) -type f -path "*/release/*" -print -quit)"
    [ -n "$CLIENT_BIN" ] && [ -f "$CLIENT_BIN" ] || { echo "the client did not link" >&2; exit 1; }
    CLIENT_DIR="$(dirname "$CLIENT_BIN")"
    autolinks="$(for o in "$CLIENT_DIR"/Client.build/*.o; do autolinks_of "$o"; done | grep . | LC_ALL=C sort -u | tr '\n' ' ')"
    echo "the client's object autolinks: $autolinks"
    # A linked wasm program's symbols are its name section's (wasm-ld keeps
    # it unless told to strip): llvm-nm reads them as an ELF program's.
    syms="$("$BIN/llvm-nm" --defined-only -j "$CLIENT_BIN")"
    count() { printf '%s\n' "$syms" | grep -cE "$1" || true; }
    corelibs_c="$(count '^(CFRelease|CFRetain|__CFInitialize|_CFRuntimeCreateInstance|_CFURLSession[A-Za-z0-9_]*|_CFXML[A-Za-z0-9_]*|curl_easy_init|xmlInitParser|SSL_new)$')"
    corelibs_net="$(count '20FoundationNetworking10URLSessionC')"
    stock_collections="$(count '22_FoundationCollections')"
    isomer_urlsession="$(count '^\$s10Foundation10URLSessionC')"
    isomer_foundation="$(count '16IsomerFoundation')"
    essentials="$(count '^\$s20FoundationEssentials')"
    echo "the client: $(human "$(size_of "$CLIENT_BIN")"), $(printf '%s\n' "$syms" | grep -c .) symbols;" \
        "Foundation.URLSession (Isomer's) $isomer_urlsession symbols, IsomerFoundation $isomer_foundation," \
        "FoundationEssentials $essentials; corelibs C $corelibs_c, corelibs FoundationNetworking.URLSession $corelibs_net," \
        "the stock _FoundationCollections $stock_collections"
    bad=""
    for l in Foundation FoundationNetworking FoundationEssentials CoreGraphics Combine; do
        [[ " $autolinks " == *" -l$l "* ]] || bad="$bad no -l$l autolinked;"
    done
    for l in CoreFoundation _FoundationCollections FoundationXML curl xml2 ssl crypto; do
        [[ " $autolinks " != *" -l$l "* ]] || bad="$bad -l$l autolinked;"
    done
    # FoundationInternationalization and ICU: in the -i18n variant's every
    # client, in no plain one's.
    for l in FoundationInternationalization IsomerFoundationInternationalization _FoundationICU; do
        if [ $I18N = 1 ]; then [[ " $autolinks " == *" -l$l "* ]] || bad="$bad no -l$l autolinked;"
        else [[ " $autolinks " != *" -l$l "* ]] || bad="$bad -l$l autolinked;"; fi
    done
    [ "$corelibs_c$corelibs_net$stock_collections" = 000 ] || bad="$bad corelibs symbols linked;"
    [ "$isomer_urlsession" -gt 0 ] && [ "$isomer_foundation" -gt 0 ] && [ "$essentials" -gt 0 ] || bad="$bad Isomer's Foundation not linked;"
    if [ "$PLATFORM" = wasi ]; then
        # WASI's emulated getpid, signal and mman come by autolink, as
        # swift-foundation's CMake build makes the stock SDK's
        # FoundationEssentials ask for them (Package.swift's ISOMER_SWIFT_SDK
        # does the same here), and the program runs.
        for l in wasi-emulated-getpid wasi-emulated-signal wasi-emulated-mman; do
            [[ " $autolinks " == *" -l$l "* ]] || bad="$bad no -l$l autolinked;"
        done
        output="$("$BIN/wasmkit" run "$CLIENT_BIN" 2>&1)" || bad="$bad the program failed under WasmKit;"
        echo "the client under WasmKit:"; printf '%s\n' "$output" | sed 's/^/  | /'
        [ "$(printf '%s\n' "$output" | head -2)" = "$EXPECTED_OUTPUT" ] || bad="$bad the program printed something else;"
        [ $I18N = 0 ] || [ "$(printf '%s\n' "$output" | sed -n 4,5p)" = "$EXPECTED_I18N_OUTPUT" ] ||
            bad="$bad the program formatted its date or number otherwise;"
        # swift-testing beside this Foundation: `import Testing` with
        # `import Foundation` loads no overlay (above), and libTesting.a's
        # FoundationEssentials symbols are this one's. Its runner is called
        # as SwiftPM's test product calls it (SwiftPM's own test build
        # wants XCTest, which this SDK hasn't).
        TESTING="$WORK/testing-client"
        rm -rf "$TESTING"; mkdir -p "$TESTING/Sources/Runner"
        cat > "$TESTING/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runner",
    targets: [
        .executableTarget(
            name: "Runner",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"])]
        ),
    ]
)
EOF
        cat > "$TESTING/Sources/Runner/main.swift" <<'EOF'
import Testing
import Foundation

@Test func data() { #expect(Data([1, 2, 3]).count == 3) }
@Test func json() throws {
    #expect(String(decoding: try JSONEncoder().encode(["a": 1]), as: UTF8.self) == #"{"a":1}"#)
}
let status: CInt = await Testing.__swiftPMEntryPoint(passing: nil)
exit(status)
EOF
        "$BIN/swift" build --build-system native --package-path "$TESTING" --scratch-path "$TESTING/.build" \
            --swift-sdks-path "$CHECK_SDKS" --swift-sdk "$(swift_sdk_of "$arch")" -c release
        RUNNER="$(find "$TESTING/.build" -name Runner.wasm -type f -path "*/release/*" -print -quit)"
        if [ -z "$RUNNER" ]; then bad="$bad the swift-testing runner did not link;"
        else
            output="$("$BIN/wasmkit" run "$RUNNER" 2>&1)" || bad="$bad swift-testing's tests failed under WasmKit;"
            echo "swift-testing under WasmKit:"; printf '%s\n' "$output" | sed 's/^/  | /'
            [[ "$output" == *"with 2 tests"*" passed"* ]] || bad="$bad swift-testing didn't find and pass both tests;"
        fi
    fi
    [ -z "$bad" ] || { echo "FAIL ($TRIPLE):$bad" >&2; exit 1; }
    echo "PASS ($TRIPLE): one Foundation, Isomer's"
done

# --- the result -------------------------------------------------------------------

step done
for arch in "${ARCHES[@]}"; do
    rel="$(static_rel_of "$arch")"
    echo "$(triple_of "$arch"): Swift modules in ${rel##*/}/$PLATFORM: ${SWIFT_MODULES[$arch]}"
    echo "  ${rel##*/}/$PLATFORM: $(human "${STOCK_STATIC_BYTES[$arch]}") stock, $(human "${NEW_STATIC_BYTES[$arch]}") now"
done
echo "variant: $([ $I18N = 1 ] && echo "-i18n (FoundationInternationalization and ICU)" || echo "plain (no ICU)")"
echo "stock: $BUNDLE.tar.gz $(human "$(size_of "$DOWNLOADS/$BUNDLE.tar.gz")") ($(size_of "$DOWNLOADS/$BUNDLE.tar.gz") bytes) sha256 $SDK_SHA256"
echo "built: $ARCHIVE"
echo "       $(human "$(size_of "$ARCHIVE")") ($(size_of "$ARCHIVE") bytes) sha256 $SHA256"
