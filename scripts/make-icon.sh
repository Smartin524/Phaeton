#!/bin/bash
# Refreshes the committed icon fallbacks from Resources/AppIcon.icon (the Icon Composer
# document: SVG layers, Claude-orange light appearance, dark appearance):
#   Resources/AppIcon.icns     light-only icon for systems / builds without actool
#   Resources/AppIcon-1024.png README preview
# build-app.sh compiles AppIcon.icon itself, so the app gets the dark variant.
# usage: scripts/make-icon.sh   (needs Xcode 26+ with Icon Composer)
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun actool Resources/AppIcon.icon --compile "$WORK" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 13.0 --output-partial-info-plist "$WORK/partial.plist" >/dev/null
cp "$WORK/AppIcon.icns" Resources/AppIcon.icns
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" Resources/AppIcon.icon --export-image --output-file Resources/AppIcon-1024.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon-1024.png"
