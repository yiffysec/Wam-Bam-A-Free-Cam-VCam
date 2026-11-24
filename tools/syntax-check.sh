#!/usr/bin/env bash
# syntax-check.sh -- Semantic check every source file against a real iOS SDK.
#
# Why this exists: hosted macOS arm64 runners are capacity-constrained, so CI
# can sit queued for a long time, and a virtual camera that has never been
# compiled is not worth much. Linking Mach-O on Linux needs a cross toolchain,
# but *checking* does not -- clang can target arm64-apple-ios with the real SDK
# and report every syntax and semantic error without ever producing an object
# file.
#
# Logos (.x) files are preprocessed to .mm first, exactly as Theos would.
#
# Usage:
#   tools/syntax-check.sh                 # uses $THEOS or ~/theos
#   THEOS=/path/to/theos tools/syntax-check.sh
#   SDK=/path/to/iPhoneOS16.5.sdk tools/syntax-check.sh

set -uo pipefail

THEOS="${THEOS:-$HOME/theos}"
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$PROJECT/.syntax-check"

if [ -z "${SDK:-}" ]; then
    SDK="$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1)"
fi

if [ ! -d "${SDK:-/nonexistent}" ]; then
    echo "no iOS SDK found under $THEOS/sdks -- set SDK=/path/to/iPhoneOSX.Y.sdk" >&2
    exit 2
fi

LOGOS=""
for candidate in "$THEOS/vendor/logos/bin/logos.pl" \
                 "$THEOS/bin/logos.pl" \
                 "$THEOS/vendor/logos/logos.pl"; do
    if [ -f "$candidate" ]; then LOGOS="$candidate"; break; fi
done
if [ -z "$LOGOS" ]; then
    echo "logos.pl not found under $THEOS" >&2
    exit 2
fi

echo "SDK:   $(basename "$SDK")"
echo "Theos: $THEOS"
echo

mkdir -p "$BUILD"

# -fobjc-arc matches every target's CFLAGS. The include path mirrors what the
# Makefiles pass. Substrate and the Preferences private framework are not in
# the public SDK, so shims stand in for them -- they only need to make the
# declarations we use available, since nothing is being linked.
CFLAGS=(
    -target arm64-apple-ios15.0
    -isysroot "$SDK"
    -fsyntax-only
    -fobjc-arc
    -fmodules
    # Warnings worth having. -Wformat matters more than usual here: os_log
    # format strings are not checked at runtime, and a mismatch between
    # %{public}s and an object (or the reverse) reads whatever is in the
    # argument register as a pointer -- inside the camera daemon.
    -Wall
    -Wextra
    -Wformat=2
    -Wconditional-uninitialized
    -Wunreachable-code
    -Wshadow
    -Wno-unused-parameter
    -Wno-gnu-folding-constant
    -Wno-deprecated-declarations
    -Wno-unused-command-line-argument
    -I "$PROJECT/Shared"
    -I "$PROJECT/VCamHost"
    -I "$BUILD/shims"
    -I "$THEOS/vendor/include"
    -I "$THEOS/include"
    -F "$SDK/System/Library/PrivateFrameworks"
)

# ---- Shims for headers Theos supplies ----------------------------------
mkdir -p "$BUILD/shims/Preferences"

cat > "$BUILD/shims/substrate.h" <<'SHIM'
// Minimal stand-in for Theos's substrate.h. Declarations only -- this harness
// never links, so the real implementation is irrelevant here.
#pragma once
#import <objc/runtime.h>
#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *orig);
void MSHookFunction(void *symbol, void *replace, void **result);
void *MSFindSymbol(void *image, const char *name);
#ifdef __cplusplus
}
#endif
SHIM

cat > "$BUILD/shims/Preferences/PSSpecifier.h" <<'SHIM'
#pragma once
#import <Foundation/Foundation.h>
@interface PSSpecifier : NSObject
@property (nonatomic, retain) NSMutableDictionary *properties;
@property (nonatomic, copy)   NSString *identifier;
@end
SHIM

cat > "$BUILD/shims/Preferences/PSListController.h" <<'SHIM'
#pragma once
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
@interface PSListController : UITableViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
@end
SHIM

cat > "$BUILD/shims/Preferences/Preferences.h" <<'SHIM'
#pragma once
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
SHIM

# ---- Collect sources ---------------------------------------------------
cd "$PROJECT"

mapfile -t PLAIN < <(find Shared VCamHost VCamApp VCamPrefs \
                        -name '*.m' -o -name '*.c' 2>/dev/null | sort)
mapfile -t LOGOS_SRC < <(find VCamHost VCamSpringBoard VCamClient \
                            -name '*.x' 2>/dev/null | sort)

fail=0
checked=0

check_one() {
    local src="$1" label="$2"
    local out
    out="$(clang "${CFLAGS[@]}" "$src" 2>&1)"
    local rc=$?
    checked=$((checked + 1))
    if [ $rc -ne 0 ]; then
        echo "FAIL  $label"
        echo "$out" | sed 's/^/        /' | head -40
        echo
        fail=$((fail + 1))
    else
        # Surface warnings even when the file compiles.
        local warns
        warns="$(echo "$out" | grep -c 'warning:' || true)"
        if [ "$warns" != "0" ] && [ -n "$out" ]; then
            echo "WARN  $label ($warns)"
            echo "$out" | grep 'warning:' | sed 's/^/        /' | head -30
        else
            echo "ok    $label"
        fi
    fi
}

echo "--- plain sources ---"
for src in "${PLAIN[@]}"; do
    check_one "$src" "$src"
done

echo
echo "--- logos sources ---"
for src in "${LOGOS_SRC[@]}"; do
    gen="$BUILD/$(echo "$src" | tr '/' '_').mm"
    mkdir -p "$(dirname "$gen")"
    if ! perl "$LOGOS" "$src" > "$gen" 2>"$gen.err"; then
        echo "FAIL  $src (logos preprocessing)"
        sed 's/^/        /' "$gen.err" | head -20
        fail=$((fail + 1))
        continue
    fi
    # A .x file is plain Objective-C -- Theos compiles .x as ObjC and only .xm
    # as ObjC++. Forcing ObjC++ here pulls in the SDK's libc++, which does not
    # match a Linux clang and fails inside the standard headers rather than in
    # our code. Compiled from the original file's directory so relative includes
    # resolve the same way.
    out="$(cd "$(dirname "$src")" && clang "${CFLAGS[@]}" -x objective-c "$gen" 2>&1)"
    rc=$?
    checked=$((checked + 1))
    if [ $rc -ne 0 ]; then
        echo "FAIL  $src"
        echo "$out" | sed 's/^/        /' | head -40
        echo
        fail=$((fail + 1))
    else
        echo "ok    $src"
    fi
done

echo
echo "checked $checked file(s), $fail failure(s)"
exit $(( fail > 0 ? 1 : 0 ))
