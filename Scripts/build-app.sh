#!/bin/bash
# Assembles build/Focusdoro.app from the SwiftPM release binary.
#
# Focusdoro ships as a SwiftPM package rather than an Xcode project because this
# machine has Command Line Tools only. The bundle below is what an Xcode app target
# would have produced: an LSUIElement (menu-bar-only) app with a bundle identifier,
# which both UNUserNotificationCenter and the Keychain require.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Focusdoro"
BUNDLE_ID="so.bon.focusdoro"
VERSION="1.0.0"
BUILD="1"
MIN_MACOS="14.0"

APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "==> Building release binary"
swift build -c release --product "${APP_NAME}"
BINARY="$(swift build -c release --product "${APP_NAME}" --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BINARY}" "${CONTENTS}/MacOS/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <!-- Menu-bar-only: no Dock icon, no app switcher entry (spec §2). -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Focusdoro</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing is enough for local use and gives the app a stable identity for the
# Keychain item and for notification authorization.
codesign --force --deep --sign - "${APP}"

echo "==> Done: ${APP}"
