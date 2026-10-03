#!/bin/bash
# Builds a universal (Apple silicon + Intel) Phaeton.app and packs it for a GitHub Release:
#   dist/Phaeton-<version>.zip         the app, zipped with ditto so the signature survives
#   dist/Phaeton-<version>.zip.sha256  checksum that install.sh verifies
# The app is only ad-hoc signed and not notarized (no developer account is used), which is why
# install.sh downloads with curl: files fetched that way carry no quarantine flag.
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 bash scripts/build-app.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
ARCHS="$(lipo -archs dist/Phaeton.app/Contents/MacOS/FormatWheel)"
echo "Architectures: $ARCHS"
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not a universal binary" >&2; exit 1;; esac
codesign --verify --deep --strict dist/Phaeton.app
ZIP="dist/Phaeton-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent dist/Phaeton.app "$ZIP"
(cd dist && shasum -a 256 "Phaeton-$VERSION.zip" > "Phaeton-$VERSION.zip.sha256")
echo "Release files:"
ls -la "$ZIP" "$ZIP.sha256"
echo "Create the release with:  gh release create v$VERSION $ZIP $ZIP.sha256 --title \"Phaeton $VERSION\""
