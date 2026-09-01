#!/bin/bash
set -euo pipefail

DMG="${1:-build/Focusdoro.dmg}"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/focusdoro-dmg.XXXXXX")"
MOUNTED=false

cleanup() {
    if [[ "${MOUNTED}" == true ]]; then
        hdiutil detach "${MOUNT_DIR}" -quiet
    fi
    rmdir "${MOUNT_DIR}"
}
trap cleanup EXIT

if [[ ! -f "${DMG}" ]]; then
    echo "missing DMG: ${DMG}" >&2
    exit 1
fi
hdiutil verify "${DMG}"
hdiutil attach "${DMG}" -readonly -nobrowse -mountpoint "${MOUNT_DIR}" -quiet
MOUNTED=true

APP="${MOUNT_DIR}/Focusdoro.app"
test -x "${APP}/Contents/MacOS/Focusdoro"
plutil -lint "${APP}/Contents/Info.plist"
BUILD_COMMIT="$(defaults read "${APP}/Contents/Info" FocusdoroBuildCommit 2>/dev/null || true)"
if [[ ! "${BUILD_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "invalid or missing FocusdoroBuildCommit" >&2
    exit 1
fi
if [[ -n "${GITHUB_SHA:-}" && "${BUILD_COMMIT}" != "${GITHUB_SHA}" ]]; then
    echo "bundle commit ${BUILD_COMMIT} does not match GITHUB_SHA ${GITHUB_SHA}" >&2
    exit 1
fi
ICON_NAME="$(defaults read "${APP}/Contents/Info" CFBundleIconFile 2>/dev/null || true)"
if [[ "${ICON_NAME}" != "AppIcon" ]]; then
    echo "missing CFBundleIconFile=AppIcon" >&2
    exit 1
fi
test -f "${APP}/Contents/Resources/AppIcon.icns"
sips -g format "${APP}/Contents/Resources/AppIcon.icns" >/dev/null
test -L "${MOUNT_DIR}/Applications"
test "$(readlink "${MOUNT_DIR}/Applications")" = "/Applications"
codesign --verify --strict --verbose=2 "${APP}"
