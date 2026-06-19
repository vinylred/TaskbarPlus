#!/bin/bash
# Build TaskbarPlus, assemble it into a .app bundle, and code-sign it (with the
# stable "TaskbarPlus Dev" self-signed identity if present, else ad-hoc).
#
# NOTE: This invokes `swiftc` directly rather than SwiftPM. The Command Line
# Tools install on this machine ships a libPackageDescription.dylib that is out
# of sync with the swiftc frontend, so `swift build` fails on any manifest.
# `swiftc` itself works fine, so we compile the C shim + Swift sources by hand.
set -euo pipefail

cd "$(dirname "$0")"

# Stop a running instance so codesign doesn't race on the in-use binary.
pkill -x TaskbarPlus 2>/dev/null || true

APP_NAME="TaskbarPlus"
BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build-direct"
PRIVATE_FW="/System/Library/PrivateFrameworks"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> compiling"
swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -I Sources/CSkyLight/include \
    -F "${PRIVATE_FW}" \
    -framework SkyLight \
    -framework AppKit \
    -framework ServiceManagement \
    Sources/TaskbarPlus/AppMenuBuilder.swift \
    Sources/TaskbarPlus/DockItem.swift \
    Sources/TaskbarPlus/DockModelService.swift \
    Sources/TaskbarPlus/DesktopSwitcher.swift \
    Sources/TaskbarPlus/LayoutConfig.swift \
    Sources/TaskbarPlus/LoginItem.swift \
    Sources/TaskbarPlus/PreferencesController.swift \
    Sources/TaskbarPlus/WindowInfo.swift \
    Sources/TaskbarPlus/WindowControl.swift \
    Sources/TaskbarPlus/SpaceWindowService.swift \
    Sources/TaskbarPlus/TaskbarPanel.swift \
    Sources/TaskbarPlus/main.swift \
    -o "${BUILD_DIR}/${APP_NAME}"

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Sign with a stable self-signed identity if present, else fall back to ad-hoc.
# A stable identity keeps the CDHash-independent designated requirement constant
# across rebuilds, so macOS TCC (Accessibility / Screen Recording) grants persist.
SIGN_IDENTITY="TaskbarPlus Dev"
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> code signing with identity '${SIGN_IDENTITY}'"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${BUNDLE}"
else
    echo "==> ad-hoc code signing (no '${SIGN_IDENTITY}' identity found)"
    codesign --force --deep --sign - "${BUNDLE}"
fi

echo "==> done: ${BUNDLE}"
echo "Launch with:  open ./${BUNDLE}    (or: ./${BUNDLE}/Contents/MacOS/${APP_NAME})"
