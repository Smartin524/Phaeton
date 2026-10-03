#!/bin/bash
# Creates a locally ad-hoc-signed .app (not notarized). No dependency install, permission
# grant, system setting change, developer-account login, signing, or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Phaeton needs macOS + Xcode/Command Line Tools. This Linux draft cannot build AppKit." >&2
  exit 1
fi
command -v xcrun >/dev/null || { echo "Install Apple developer tools first." >&2; exit 1; }
xcrun --find swift >/dev/null
SWIFT_FLAGS=()
if [[ -n "${FORMATWHEEL_SDK:-}" ]]; then
  SWIFT_FLAGS+=(--sdk "$FORMATWHEEL_SDK")
fi
if [[ "${FORMATWHEEL_DISABLE_SPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_FLAGS+=(--disable-sandbox)
fi
swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --product FormatWheel
BIN_DIR="$(swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --show-bin-path)"
APP="dist/Phaeton.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FormatWheel" "$APP/Contents/MacOS/FormatWheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Icon Composer document → Assets.car (light, dark and tinted appearances) + AppIcon.icns
# for older macOS. Without Xcode's actool, fall back to the committed light-only icns.
if ! xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
     --platform macosx --minimum-deployment-target 13.0 \
     --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null 2>&1; then
  echo "actool unavailable; using Resources/AppIcon.icns (no dark variant)" >&2
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp scripts/install-extras.sh scripts/phaeton_helper.py "$APP/Contents/Resources/"
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/"
chmod +x "$APP/Contents/MacOS/FormatWheel"
plutil -lint "$APP/Contents/Info.plist"
echo "Built: $(pwd)/$APP"
echo "Run when ready: open dist/Phaeton.app"
# Ad-hoc signature (no account, no identity). By default macOS would remember an Accessibility or
# similar grant by the exact build (its cdhash), so every rebuild or update silently invalidates
# it while the old entry still looks switched on in System Settings. Naming the bundle identifier
# as the designated requirement keeps the grant valid across builds. (Anyone able to ad-hoc sign
# code with this identifier would match it, an acceptable trade for an app that is not notarized.)
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1 \
  && echo "Ad-hoc signed (stable requirement: identifier $BUNDLE_ID)" || echo "Ad-hoc signing skipped"
