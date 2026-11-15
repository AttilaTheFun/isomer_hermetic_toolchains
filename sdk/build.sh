#!/bin/bash
# Builds one of Isomer's Swift SDKs: swift.org's SDK for the target with
# corelibs Foundation taken out and Isomer's Foundation family put in, so that
# every `import Foundation` built with it is Isomer's
# (docs/hermetic_toolchains.md in AttilaTheFun/isomer).
#
#   sdk/build.sh android-aarch64 [--out=DIR] [--work=DIR]
#
# Runs on Linux (Ubuntu 24.04, arm64 or x86_64: a Shireworks container of
# Visor's agent image, or GitHub's ubuntu-24.04 runner), never on a Mac's own
# disk. It needs curl, git, tar, gzip, unzip and sha256sum, and the libraries
# swift.org's toolchain runs on; everything else it downloads, each download
# checked against the checksum below.
#
# Steps (each prints a line as it starts):
#   fetch      swift.org's 6.4.2 toolchain for this host, its Android SDK
#              artifact bundle (the one rules_swift registers for
#              `swift.android_sdk()`), and the Android NDK the bundle's
#              setup script links to (r30, isomer's)
#   deps       swift-foundation's dependencies at the 6.4.2 release, cloned
#              beside the package (SWIFTCI_USE_LOCAL_DEPS, as Swift's own CI
#              builds it): a local package may carry unsafe flags, a versioned
#              one may not, and swift-collections' modules need link names too
#   prune      the stock bundle unpacked, corelibs Foundation taken out of
#              the target architecture's static resources
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
#              Isomer's Foundation and nothing of corelibs'
#
# Only the target architecture's static resources change: rules_swift links
# Swift statically. The dynamic resources (swift-aarch64/) and the other
# architectures stay swift.org's until their own builds replace them.
# FoundationInternationalization stays out (its ICU, lib_FoundationICU.a and
# _foundation_unicode/, stays in for it), as isomer's
# `--@isomer//foundation:internationalization` defaults to off.
set -euo pipefail
umask 022

REPO="$(cd "$(dirname "$0")/.." && pwd)"

usage() { echo "usage: sdk/build.sh android-aarch64 [--out=DIR] [--work=DIR]" >&2; exit 2; }
[ $# -ge 1 ] || usage
TARGET=$1; shift
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
case "$TARGET" in
    android-aarch64)
        ARCH=aarch64
        # isomer's NDK targets API 28 (MODULE.bazel's android.ndk), and
        # rules_swift compiles for the NDK's API.
        API=28
        ;;
    *) echo "unknown target $TARGET (android-aarch64 so far)" >&2; exit 2 ;;
esac
TRIPLE="$ARCH-unknown-linux-android$API"
# The name a module's file for this architecture has in a .swiftmodule
# directory: the triple without its API level.
MODULE_TRIPLE="$ARCH-unknown-linux-android"

# swift.org's Android SDK; the checksum is rules_swift's for 6.4.2 (its
# swift_release_metadata.json, in the project registry's 4.2.2.isomer.3).
BUNDLE=swift-$SWIFT_VERSION-RELEASE_android.artifactbundle
SDK_URL=https://download.swift.org/swift-$SWIFT_VERSION-release/android-sdk/swift-$SWIFT_VERSION-RELEASE/$BUNDLE.tar.gz
SDK_SHA256=4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233

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
# on the host: its programs are x86_64 Linux's.
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
# the build makes for the target goes into the SDK.
TARGETS=(Foundation FoundationNetworking CoreGraphics Combine IsomerFoundation)
# The helpers no client imports by name, folded into the archive a client
# does autolink (below).
FOLD_INTO_ESSENTIALS=(DequeModule InternalCollectionsUtilities OrderedCollections _RopeModule _FoundationCShims)
FOLD_INTO_FOUNDATION=(IsomerFoundation IsomerDispatchTime)

# Corelibs' Foundation in the stock SDK: its Swift modules, its archives and
# what they alone link (CoreFoundation and its shims, curl, libxml2, OpenSSL).
CORELIBS_MODULES=(Foundation FoundationNetworking FoundationXML FoundationEssentials FoundationInternationalization _FoundationCollections)
CORELIBS_ARCHIVES=(Foundation FoundationNetworking FoundationXML FoundationEssentials FoundationInternationalization
    _FoundationCollections _FoundationCShims CoreFoundation _CFURLSessionInterface _CFXMLInterface curl xml2 ssl crypto)

# --- helpers ------------------------------------------------------------------

DOWNLOADS="$WORK/downloads"
TOOLCHAIN="$WORK/toolchain"
NDK="$WORK/ndk"
PRUNED="$WORK/pruned"           # the stock bundle, corelibs out: what goes out
BUILD_SDKS="$WORK/sdks/build"   # a copy of it set up with the NDK, to build with
CHECK_SDKS="$WORK/sdks/check"   # the finished bundle set up with the NDK, to check
SCRATCH="$WORK/swiftpm"
STATIC_REL="swift-android/swift-resources/usr/lib/swift_static-$ARCH"
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

# set_up_with_ndk <dir containing the bundle>: the bundle's own setup script
# links the NDK's sysroot and clang headers into it, as a user does once
# after `swift sdk install`. Only on copies: what goes out stays as
# swift.org shipped it.
set_up_with_ndk() {
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

step fetch
[ "$(uname -s)" = Linux ] || { echo "sdk/build.sh runs on Linux (a container), not $(uname -s)" >&2; exit 1; }
mkdir -p "$DOWNLOADS" "$OUT"
fetch "$TOOLCHAIN_URL" "$TOOLCHAIN_SHA256" "swift-$SWIFT_VERSION-RELEASE-$TOOLCHAIN_PLATFORM.tar.gz"
fetch "$SDK_URL" "$SDK_SHA256" "$BUNDLE.tar.gz"
fetch "$NDK_URL" "$NDK_SHA256" android-ndk-r30-linux.zip

if [ ! -x "$BIN/swift" ] || [ "$(cat "$TOOLCHAIN/.sha256" 2>/dev/null)" != "$TOOLCHAIN_SHA256" ]; then
    rm -rf "$TOOLCHAIN"; mkdir -p "$TOOLCHAIN"
    tar -xzf "$DOWNLOADS/swift-$SWIFT_VERSION-RELEASE-$TOOLCHAIN_PLATFORM.tar.gz" -C "$TOOLCHAIN" --strip-components=1
    echo "$TOOLCHAIN_SHA256" > "$TOOLCHAIN/.sha256"
fi
"$BIN/swift" --version 2>&1 | sed -n 1p
if [ ! -f "$NDK/source.properties" ]; then
    rm -rf "$NDK" "$WORK/ndk.unzip"; mkdir -p "$WORK/ndk.unzip"
    unzip -q "$DOWNLOADS/android-ndk-r30-linux.zip" -d "$WORK/ndk.unzip" \
        'android-ndk-r30/source.properties' \
        'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/sysroot/*' \
        'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/*'
    mv "$WORK/ndk.unzip/android-ndk-r30" "$NDK"; rmdir "$WORK/ndk.unzip"
fi
echo "NDK $(sed -n 's/^Pkg.Revision = //p' "$NDK/source.properties"): its sysroot and clang headers"

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
cat >> "$WORK/deps/swift-collections/Package.swift" <<'EOF'

// Isomer's Swift SDK build (isomer_hermetic_toolchains' sdk/build.sh): each
// module carries its link name, as swift-foundation's do there.
for target in package.targets where target.type == .regular {
    target.swiftSettings = (target.swiftSettings ?? []) + [.unsafeFlags(["-module-link-name", target.name])]
}
EOF

# --- prune ----------------------------------------------------------------------

step prune "the stock bundle, corelibs Foundation out of swift_static-$ARCH"
rm -rf "$PRUNED"; mkdir -p "$PRUNED"
tar -xzf "$DOWNLOADS/$BUNDLE.tar.gz" -C "$PRUNED"
STOCK_STATIC_BYTES="$(du -sb "$PRUNED/$BUNDLE/$STATIC_REL/android" | cut -f1)"
STATIC="$PRUNED/$BUNDLE/$STATIC_REL"
[ -d "$STATIC/android" ] || { echo "unexpected layout: no $STATIC/android" >&2; exit 1; }
for m in "${CORELIBS_MODULES[@]}"; do
    [ -d "$STATIC/android/$m.swiftmodule" ] || { echo "the stock SDK has no $m.swiftmodule" >&2; exit 1; }
    rm -rf "$STATIC/android/$m.swiftmodule"
done
for l in "${CORELIBS_ARCHIVES[@]}"; do
    [ -f "$STATIC/android/lib$l.a" ] || { echo "the stock SDK has no lib$l.a" >&2; exit 1; }
    echo "  out: lib$l.a ($(human "$(size_of "$STATIC/android/lib$l.a")"))"
    rm -f "$STATIC/android/lib$l.a"
done
# CoreFoundation's clang module; the C shims' is replaced by the build's.
rm -rf "$STATIC/CoreFoundation" "$STATIC/_FoundationCShims"
echo "  out: ${CORELIBS_MODULES[*]} (.swiftmodule), CoreFoundation/ and _FoundationCShims/ (clang modules)"

# --- build ----------------------------------------------------------------------

step build "the family, -c release, for $TRIPLE"
rm -rf "$BUILD_SDKS"; mkdir -p "$BUILD_SDKS"
cp -a "$PRUNED/$BUNDLE" "$BUILD_SDKS/"
set_up_with_ndk "$BUILD_SDKS"
# A fresh scratch directory: SwiftPM keeps modules a build made before, and a
# stale one would go into the SDK.
# SwiftPM's native build system: Swift Build, the default, looks for a whole
# NDK installed (its compilers, x86_64 Linux's), where the native one takes
# the SDK's sysroot alone, and leaves each target's objects in a directory
# of its own, which is what the SDK's archives are made from.
rm -rf "$SCRATCH"
for target in "${TARGETS[@]}"; do
    echo "-- $target"
    ISOMER_SWIFT_SDK=1 SWIFTCI_USE_LOCAL_DEPS="$WORK/deps" "$BIN/swift" build --build-system native \
        --package-path "$REPO" --scratch-path "$SCRATCH" \
        --swift-sdks-path "$BUILD_SDKS" --swift-sdk "$TRIPLE" --static-swift-stdlib \
        -c release -debug-info-format none --target "$target"
done
PRODUCTS_DIR="$SCRATCH/$TRIPLE/release"
[ -d "$PRODUCTS_DIR/Modules" ] || PRODUCTS_DIR="$(dirname "$(find "$SCRATCH" -path "*$TRIPLE*" -name Modules -type d -print -quit)")"
[ -d "$PRODUCTS_DIR/Modules" ] || { echo "no $TRIPLE build under $SCRATCH" >&2; exit 1; }
echo "built in $PRODUCTS_DIR"

# --- assemble -------------------------------------------------------------------

step assemble "the family into swift_static-$ARCH"
# Every target the build compiled for Android: a directory of objects each.
swift_modules=()
for dir in "$PRODUCTS_DIR"/*.build; do
    module="$(basename "$dir" .build)"
    objects=("$dir"/*.o)
    [ -e "${objects[0]}" ] || continue
    # An archive per module, its members sorted and llvm-ar's deterministic
    # headers, so the same objects make the same archive.
    rm -f "$STATIC/android/lib$module.a"
    # (Object names have spaces: FoundationEssentials' sources' do.)
    mapfile -t objects < <(printf '%s\n' "${objects[@]}" | LC_ALL=C sort)
    # Each object's .swift_modhash is a hash of its LLVM module, which
    # differs with the build's paths (the rest of the object doesn't), and
    # only the compiler's incremental code generation reads it: without it
    # the archives are the same wherever they are built.
    for object in "${objects[@]}"; do "$BIN/llvm-objcopy" --remove-section=.swift_modhash "$object"; done
    "$BIN/llvm-ar" crsD "$STATIC/android/lib$module.a" "${objects[@]}"
    if [ -f "$PRODUCTS_DIR/Modules/$module.swiftmodule" ]; then
        mkdir -p "$STATIC/android/$module.swiftmodule"
        cp "$PRODUCTS_DIR/Modules/$module.swiftmodule" "$STATIC/android/$module.swiftmodule/$MODULE_TRIPLE.swiftmodule"
        [ ! -f "$PRODUCTS_DIR/Modules/$module.swiftdoc" ] ||
            cp "$PRODUCTS_DIR/Modules/$module.swiftdoc" "$STATIC/android/$module.swiftmodule/$MODULE_TRIPLE.swiftdoc"
        swift_modules+=("$module")
        echo "  in: $module.swiftmodule, lib$module.a ($(human "$(size_of "$STATIC/android/lib$module.a")"))"
    else
        echo "  in: lib$module.a ($(human "$(size_of "$STATIC/android/lib$module.a")")), C"
    fi
done
for m in Foundation FoundationNetworking FoundationEssentials IsomerFoundation IsomerDispatchTime CoreGraphics Combine \
         "${FOLD_INTO_ESSENTIALS[@]}"; do
    [ -f "$STATIC/android/lib$m.a" ] || { echo "the build made no lib$m.a" >&2; exit 1; }
done

# The C shims' clang module, as the stock SDK lays it out: this package's
# include directory, its module map naming no library (the archive is
# folded below), as swift.org's does.
mkdir -p "$STATIC/_FoundationCShims"
cp "$REPO"/Sources/_FoundationCShims/include/* "$STATIC/_FoundationCShims/"
echo "  in: _FoundationCShims/ (clang module: $(ls "$STATIC/_FoundationCShims" | wc -l) files)"

# Autolink entries are written when the importing module compiles: a client
# of Foundation records the libraries of the modules it can see, and
# FoundationEssentials' swift-collections and C shims, and Foundation's
# IsomerFoundation, are imported out of its sight. So, as swift.org's SDK
# does with _FoundationCollections, each helper's archive is folded into the
# archive a client does autolink. The helpers' own archives stay too, for a
# client that imports one by name (Isomer's hosts import IsomerFoundation):
# a member already loaded from one archive leaves its copy in the other
# unloaded.
fold_into() { # <archive's module> <helpers' modules…>
    local name=$1 target="$STATIC/android/lib$1.a" merged="$STATIC/android/lib$1.merged.a"; shift
    {
        echo "create $merged"
        echo "addlib $target"
        for m in "$@"; do echo "addlib $STATIC/android/lib$m.a"; done
        echo save
        echo end
    } | "$BIN/llvm-ar" -M
    # llvm-ar's MRI script writes deterministic headers too; mv keeps the name.
    mv "$merged" "$target"
    echo "  lib$name.a carries $* ($(human "$(size_of "$target")"))"
}
fold_into FoundationEssentials "${FOLD_INTO_ESSENTIALS[@]}"
fold_into Foundation "${FOLD_INTO_FOUNDATION[@]}"
NEW_STATIC_BYTES="$(du -sb "$STATIC/android" | cut -f1)"

# --- pack -----------------------------------------------------------------------

step pack
# Reproducible: entries sorted, no owners, and every time no later than the
# commit built (the stock files keep their own, earlier ones).
EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || true)}"
[ -n "$EPOCH" ] || { echo "no commit time: set SOURCE_DATE_EPOCH" >&2; exit 1; }
ARCHIVE="$OUT/$BUNDLE.tar.gz"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
    --mtime="@$EPOCH" --clamp-mtime -C "$PRUNED" -cf - "$BUNDLE" | gzip -n > "$ARCHIVE.part"
mv "$ARCHIVE.part" "$ARCHIVE"
SHA256="$(sha256_of "$ARCHIVE")"
echo "$SHA256  $BUNDLE.tar.gz" > "$ARCHIVE.sha256"

# --- check ----------------------------------------------------------------------

step check "a client built and linked against the new bundle"
rm -rf "$CHECK_SDKS"; mkdir -p "$CHECK_SDKS"
tar -xzf "$ARCHIVE" -C "$CHECK_SDKS"
set_up_with_ndk "$CHECK_SDKS"
CLIENT="$WORK/client"
rm -rf "$CLIENT"; mkdir -p "$CLIENT/Sources/Client"
cat > "$CLIENT/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Client",
    targets: [.executableTarget(name: "Client", swiftSettings: [.swiftLanguageMode(.v5)])]
)
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
"$BIN/swift" build --build-system native --package-path "$CLIENT" --scratch-path "$CLIENT/.build" \
    --swift-sdks-path "$CHECK_SDKS" --swift-sdk "$TRIPLE" --static-swift-stdlib -c release
CLIENT_DIR="$(dirname "$(find "$CLIENT/.build" -path "*$TRIPLE*" -name Client -type f -print -quit)")"
CLIENT_BIN="$CLIENT_DIR/Client"
[ -f "$CLIENT_BIN" ] || { echo "the client did not link" >&2; exit 1; }
autolinks="$(for o in "$CLIENT_DIR"/Client.build/*.o; do autolinks_of "$o"; done | grep . | LC_ALL=C sort -u | tr '\n' ' ')"
echo "the client's object autolinks: $autolinks"
syms="$("$BIN/llvm-nm" --defined-only -j "$CLIENT_BIN")"
count() { printf '%s\n' "$syms" | grep -cE "$1" || true; }
corelibs_c="$(count '^(CFRelease|CFRetain|__CFInitialize|_CFRuntimeCreateInstance|_CFURLSession[A-Za-z0-9_]*|curl_easy_init|xmlInitParser|SSL_new)$')"
corelibs_net="$(count '20FoundationNetworking10URLSessionC')"
stock_collections="$(count '22_FoundationCollections')"
isomer_urlsession="$(count '^\$s10Foundation10URLSessionC')"
isomer_foundation="$(count '16IsomerFoundation')"
essentials="$(count '^\$s20FoundationEssentials')"
echo "the client: $(human "$(size_of "$CLIENT_BIN")"); Foundation.URLSession (Isomer's) $isomer_urlsession symbols," \
    "IsomerFoundation $isomer_foundation, FoundationEssentials $essentials; corelibs C $corelibs_c," \
    "corelibs FoundationNetworking.URLSession $corelibs_net, the stock _FoundationCollections $stock_collections"
bad=""
for l in Foundation FoundationNetworking FoundationEssentials CoreGraphics Combine; do
    [[ " $autolinks " == *" -l$l "* ]] || bad="$bad no -l$l autolinked;"
done
for l in CoreFoundation _FoundationCollections FoundationXML curl xml2 ssl crypto; do
    [[ " $autolinks " != *" -l$l "* ]] || bad="$bad -l$l autolinked;"
done
[ "$corelibs_c$corelibs_net$stock_collections" = 000 ] || bad="$bad corelibs symbols linked;"
[ "$isomer_urlsession" -gt 0 ] && [ "$isomer_foundation" -gt 0 ] && [ "$essentials" -gt 0 ] || bad="$bad Isomer's Foundation not linked;"
[ -z "$bad" ] || { echo "FAIL:$bad" >&2; exit 1; }
echo "PASS: one Foundation, Isomer's"

# --- the result -------------------------------------------------------------------

step done
echo "Swift modules in swift_static-$ARCH/android: ${swift_modules[*]}"
echo "swift_static-$ARCH/android: $(human "$STOCK_STATIC_BYTES") stock, $(human "$NEW_STATIC_BYTES") now"
echo "stock: $BUNDLE.tar.gz $(human "$(size_of "$DOWNLOADS/$BUNDLE.tar.gz")") sha256 $SDK_SHA256"
echo "built: $ARCHIVE"
echo "       $(human "$(size_of "$ARCHIVE")") ($(size_of "$ARCHIVE") bytes) sha256 $SHA256"
