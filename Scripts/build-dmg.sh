#!/bin/bash
# Packages the assembled app in a drag-to-Applications disk image.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Focusdoro.app"
DMG="build/Focusdoro.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/focusdoro-dmg.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT

test -d "${APP}"
cp -R "${APP}" "${STAGING}/Focusdoro.app"
ln -s /Applications "${STAGING}/Applications"

echo "==> Creating ${DMG}"
hdiutil create \
    -volname "Focusdoro" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${DMG}"

echo "==> Done: ${DMG}"
