#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$PROJECT_DIR/dist/Codex Meter.app"
BUILD_DIR="$PROJECT_DIR/.build/codex-meter-release"
DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
ARCHS=${ARCHS:-"arm64 x86_64"}

case "$APP_DIR" in
    "$PROJECT_DIR"/dist/*.app) ;;
    *) echo "Refusing to clean unexpected app path: $APP_DIR" >&2; exit 1 ;;
esac

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"
set -- "$PROJECT_DIR"/Sources/CodexMeter/*.swift

binary_count=0
for arch in $ARCHS; do
    output="$BUILD_DIR/CodexMeter-$arch"
    xcrun swiftc \
        -O \
        -parse-as-library \
        -target "$arch-apple-macosx$DEPLOYMENT_TARGET" \
        -framework AppKit \
        -framework Foundation \
        -framework QuartzCore \
        -framework ServiceManagement \
        "$@" \
        -o "$output"
    binary_count=$((binary_count + 1))
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if [ "$binary_count" -eq 1 ]; then
    first_arch=${ARCHS%% *}
    cp "$BUILD_DIR/CodexMeter-$first_arch" "$APP_DIR/Contents/MacOS/CodexMeter"
else
    set --
    for arch in $ARCHS; do
        set -- "$@" "$BUILD_DIR/CodexMeter-$arch"
    done
    xcrun lipo -create "$@" -output "$APP_DIR/Contents/MacOS/CodexMeter"
fi

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
test -f "$PROJECT_DIR/Resources/Fonts/UbuntuMono-Regular.ttf"
test -f "$PROJECT_DIR/Resources/Fonts/UbuntuMono-Bold.ttf"
cp -R "$PROJECT_DIR/Resources/Fonts" "$APP_DIR/Contents/Resources/Fonts"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$CODE_SIGN_IDENTITY" \
        "$APP_DIR"
else
    /usr/bin/codesign --force --sign - "$APP_DIR"
    echo "Warning: built with an ad-hoc signature; this artifact is for local development only." >&2
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
