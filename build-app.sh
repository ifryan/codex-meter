#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$PROJECT_DIR/dist/Codex Meter.app"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/release"
swiftc \
    -O \
    -parse-as-library \
    -framework AppKit \
    -framework Foundation \
    -framework QuartzCore \
    "$PROJECT_DIR/Sources/CodexMeter/main.swift" \
    -o "$PROJECT_DIR/.build/release/CodexMeter"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/CodexMeter" "$APP_DIR/Contents/MacOS/CodexMeter"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
