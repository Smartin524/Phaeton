#!/bin/bash
# Optional: installs the tools behind PDF→DOCX, WebP and MP3 into a private virtualenv at
# ~/Library/Application Support/Phaeton. Nothing system-wide is touched. Phaeton offers
# to run it the first time one of those formats is used. Remove the folder to uninstall.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Phaeton"
mkdir -p "$DEST"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet pdf2docx "pymupdf==1.24.14" pillow lameenc
cp "$HERE/phaeton_helper.py" "$DEST/phaeton_helper.py"
touch "$DEST/has-mp3"
echo "Installed to: $DEST"
