#!/bin/bash
# Runs the standalone checks in validation/ against the samples in samples/, in a temp folder.
# They exercise the real conversion engine (not the UI). Checks that need the optional
# components (WebP, MP3, PDF→DOCX) are skipped when those are not installed.
# Needs macOS with the Swift toolchain and the `say` and `sips` tools.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=()
if [[ -n "${FORMATWHEEL_SDK:-}" ]]; then SDK=(-sdk "$FORMATWHEEL_SDK"); fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp samples/* "$WORK/"
cp samples/sample.jpg "$WORK/sample-photo.jpg"
sips -Z 360 samples/sample.jpg --out "$WORK/small.jpg" -s formatOptions 8 >/dev/null
sips -z 3000 4000 samples/sample.jpg --out "$WORK/big.jpg" -s formatOptions 100 >/dev/null
for i in $(seq 1 12); do echo "This is a long sentence number $i, used to build a longer speech file."; done > "$WORK/long-speech.txt"
say -f "$WORK/long-speech.txt" -o "$WORK/long.aiff"

failed=0
for name in media image tools trim audio cancel docs; do
  echo "== $name"
  bin="$WORK/$name-smoke"
  swiftc "${SDK[@]}" -parse-as-library -o "$bin" Sources/FormatWheelCore/*.swift "validation/$name-smoke.swift" 2>&1 | grep "error:" || true
  run="$WORK/run-$name"
  mkdir "$run"
  find "$WORK" -maxdepth 1 -type f ! -name "*.out" -exec cp {} "$run/" \;
  "$bin" "$run" > "$WORK/$name.out" 2>&1 || true
  tail -n 4 "$WORK/$name.out"
  if grep -q "FAIL\|Fatal error" "$WORK/$name.out"; then grep "FAIL\|Fatal error" "$WORK/$name.out"; failed=1; fi
  # later checks (image) reuse the PDF made by the media check
  if [[ "$name" == "media" && -f "$run/notes.pdf" ]]; then cp "$run/notes.pdf" "$WORK/notes.pdf"; fi
done
if [[ $failed == 0 ]]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
