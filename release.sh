#!/bin/bash
# Build a clean release and package TaskbarPlus.app into a distributable zip.
#
# This app links private frameworks (SkyLight/CGS) with hardened runtime OFF, so it
# cannot go through the Mac App Store and Apple notarization will not accept it as-is.
# It is distributed ad-hoc-signed (like yabai / sketchybar): users download the zip,
# clear the quarantine attribute, and grant Accessibility + Screen Recording once.
#
# Usage: ./release.sh            # uses the version from Resources/Info.plist
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TaskbarPlus"
BUNDLE="${APP_NAME}.app"
DIST_DIR="dist"

# Build fresh (build.sh signs the bundle — stable identity if present, else ad-hoc).
./build.sh

VERSION="$(/usr/bin/defaults read "$(pwd)/${BUNDLE}/Contents/Info" CFBundleShortVersionString)"
ZIP="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

mkdir -p "${DIST_DIR}"
rm -f "${ZIP}"

# ditto -c -k --keepParent preserves the code signature and bundle structure (plain
# `zip` can corrupt the signature). This is the file users download.
echo "==> packaging ${ZIP}"
/usr/bin/ditto -c -k --keepParent "${BUNDLE}" "${ZIP}"

echo "==> done: ${ZIP}"
echo "Verify signature:  codesign -dv --verbose=2 ${BUNDLE}"
echo
echo "SHA-256 (put this in Casks/taskbar-plus.rb for v${VERSION}):"
shasum -a 256 "${ZIP}" | awk '{print "  "$1}'
echo
echo "Next: upload ${ZIP} to a GitHub Release tagged v${VERSION},"
echo "then bump version + sha256 in Casks/taskbar-plus.rb and push your tap."
