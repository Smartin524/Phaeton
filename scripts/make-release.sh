#!/bin/bash
# Builds Phaeton.app for Apple silicon and packs it for a GitHub Release:
#   dist/Phaeton-<version>.zip         the app, zipped with ditto so the signature survives
#   dist/Phaeton-<version>.zip.sha256  checksum that install.sh verifies
# The app is only ad-hoc signed and not notarized (no developer account is used), which is why
# install.sh downloads with curl: files fetched that way carry no quarantine flag.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
ARCHS="$(lipo -archs dist/Phaeton.app/Contents/MacOS/FormatWheel)"
echo "Architecture: $ARCHS"
[[ "$ARCHS" == "arm64" ]] || { echo "expected an arm64-only build, got: $ARCHS" >&2; exit 1; }
codesign --verify --deep --strict dist/Phaeton.app
# A release signed ad-hoc would make every user grant Accessibility again after each update.
codesign -d -r- dist/Phaeton.app 2>&1 | grep -q "certificate leaf" \
  || { echo "not signed with \"Phaeton Local Signing\"; run scripts/make-signing-identity.sh first" >&2; exit 1; }
ZIP="dist/Phaeton-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent dist/Phaeton.app "$ZIP"
(cd dist && shasum -a 256 "Phaeton-$VERSION.zip" > "Phaeton-$VERSION.zip.sha256")
echo "Release files:"
ls -la "$ZIP" "$ZIP.sha256"
echo "Create the release with:  gh release create v$VERSION $ZIP $ZIP.sha256 --title \"Phaeton $VERSION\""
