#!/bin/bash
# Creates an unsigned, local-development .app. No dependency install, permission
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
swift build "${SWIFT_FLAGS[@]}" -c release --product FormatWheel
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)"
APP="dist/Phaeton.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FormatWheel" "$APP/Contents/MacOS/FormatWheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/install-extras.sh scripts/phaeton_helper.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/MacOS/FormatWheel"
plutil -lint "$APP/Contents/Info.plist"
echo "Built: $(pwd)/$APP"
echo "Run when ready: open dist/Phaeton.app"
# Ad-hoc signature (no account, no identity): needed for system notifications and
# keeps Launch Services / Services menus consistent. Not a distributable signature.
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "Ad-hoc signed" || echo "Ad-hoc signing skipped"
