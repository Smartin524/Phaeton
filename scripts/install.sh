#!/bin/bash
# Installs the latest Phaeton release (Apple silicon, macOS 13+):
#   curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
# It downloads the zip from the GitHub release with curl (so the app is not quarantined and no
# "unidentified developer" prompt appears), checks its SHA-256, copies it to /Applications
# (or ~/Applications when that is not writable) and opens it. Read the script before running it.
set -euo pipefail
REPO="${PHAETON_REPO:-Smartin524/Phaeton}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "Phaeton is for macOS." >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "Phaeton needs a Mac with Apple silicon (M1 or later)." >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || { echo "Phaeton needs macOS 13 or later." >&2; exit 1; }

DEST="${PHAETON_DEST:-/Applications}"
if [[ ! -w "$DEST" ]]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# PHAETON_ZIP_URL lets you point at another zip (also used for testing with a file:// URL).
if [[ -n "${PHAETON_ZIP_URL:-}" ]]; then
  ZIP_URL="$PHAETON_ZIP_URL"
else
  echo "Looking up the latest release of $REPO…"
  ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n 1 | cut -d'"' -f4)"
  [[ -n "$ZIP_URL" ]] || { echo "No release found. Build from source instead: https://github.com/$REPO#构建与运行" >&2; exit 1; }
fi

echo "Downloading $ZIP_URL"
curl -fL --progress-bar "$ZIP_URL" -o "$WORK/Phaeton.zip"
if curl -fsSL "$ZIP_URL.sha256" -o "$WORK/Phaeton.zip.sha256" 2>/dev/null; then
  expected="$(cut -d' ' -f1 "$WORK/Phaeton.zip.sha256")"
  actual="$(shasum -a 256 "$WORK/Phaeton.zip" | cut -d' ' -f1)"
  [[ "$expected" == "$actual" ]] || { echo "Checksum mismatch, not installing." >&2; exit 1; }
  echo "Checksum OK."
else
  echo "(no checksum file next to the zip; skipping the check)"
fi

ditto -x -k "$WORK/Phaeton.zip" "$WORK"
[[ -d "$WORK/Phaeton.app" ]] || { echo "The zip does not contain Phaeton.app." >&2; exit 1; }
codesign --verify --deep --strict "$WORK/Phaeton.app"

pkill -x FormatWheel 2>/dev/null || true
rm -rf "$DEST/Phaeton.app"
ditto "$WORK/Phaeton.app" "$DEST/Phaeton.app"
xattr -dr com.apple.quarantine "$DEST/Phaeton.app" 2>/dev/null || true
echo "Installed: $DEST/Phaeton.app"
if [[ -z "${PHAETON_NO_OPEN:-}" ]]; then open "$DEST/Phaeton.app"; fi
echo "Phaeton opened a window that explains how to use it. Hold Shift and drag a file to try it."
