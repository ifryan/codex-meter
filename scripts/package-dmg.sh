#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Packages dist/Meterline.app as dist/Meterline-<version>.dmg, with an Applications shortcut.
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    exit 64
fi

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$PROJECT_DIR/dist/Meterline.app"
DMG="$PROJECT_DIR/dist/Meterline-$1.dmg"

test -d "$APP" || { echo "Missing $APP. Run ./build-app.sh first." >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/Meterline.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
/usr/bin/hdiutil create -volname "Meterline" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
/usr/bin/hdiutil verify -quiet "$DMG"
echo "$DMG"
