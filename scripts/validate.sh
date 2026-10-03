#!/bin/bash
# Runs the standalone checks in validation/ in a temp folder, with sample files generated on the spot.
# They exercise the real conversion engine (not the UI). Checks that need the optional
# components (WebP, MP3, PDF→DOCX) are skipped when those are not installed.
# Needs macOS with the Swift toolchain and the `say` and `sips` tools.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=()
if [[ -n "${FORMATWHEEL_SDK:-}" ]]; then SDK=(-sdk "$FORMATWHEEL_SDK"); fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Everything the checks need is generated here, nothing is read from the repository:
# a drawn picture and a transparent cut-out, an SVG, system-voice speech, and a few text documents.
# (The video clip is made by the "media" check itself.)
swiftc ${SDK[@]+"${SDK[@]}"} -o "$WORK/make-samples" scripts/make-samples.swift 2>&1 | grep "error:" || true
"$WORK/make-samples" "$WORK" >/dev/null
cat > "$WORK/logo.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160" viewBox="0 0 240 160">
  <rect width="240" height="160" rx="20" fill="#d97757"/>
  <circle cx="78" cy="80" r="44" fill="#fff"/>
  <rect x="132" y="38" width="76" height="84" rx="10" fill="#4f46e5"/>
</svg>
SVG
say -o "$WORK/speech.aiff" "Hello, this is a Phaeton test."
printf '你好，这是 Phaeton 的文档转换测试。\nHello world.\n' > "$WORK/notes.txt"
textutil -convert rtf -encoding UTF-8 "$WORK/notes.txt" -output "$WORK/notes.rtf"
textutil -convert docx -encoding UTF-8 "$WORK/notes.txt" -output "$WORK/notes.docx"
cp "$WORK/sample.jpg" "$WORK/sample-photo.jpg"
sips -Z 360 "$WORK/sample.jpg" --out "$WORK/small.jpg" -s formatOptions 8 >/dev/null
sips -z 3000 4000 "$WORK/sample.jpg" --out "$WORK/big.jpg" -s formatOptions 100 >/dev/null
for i in $(seq 1 12); do echo "This is a long sentence number $i, used to build a longer speech file."; done > "$WORK/long-speech.txt"
say -f "$WORK/long-speech.txt" -o "$WORK/long.aiff"

failed=0
for name in media image tools trim audio extras cancel docs; do
  echo "== $name"
  bin="$WORK/$name-smoke"
  swiftc ${SDK[@]+"${SDK[@]}"} -parse-as-library -o "$bin" Sources/FormatWheelCore/*.swift "validation/$name-smoke.swift" 2>&1 | grep "error:" || true
  run="$WORK/run-$name"
  mkdir "$run"
  find "$WORK" -maxdepth 1 -type f ! -name "*.out" -exec cp {} "$run/" \;
  "$bin" "$run" > "$WORK/$name.out" 2>&1 || true
  tail -n 4 "$WORK/$name.out"
  if grep -q "FAIL\|Fatal error" "$WORK/$name.out"; then grep "FAIL\|Fatal error" "$WORK/$name.out"; failed=1; fi
  # later checks reuse what the media check made: a PDF and a short video clip
  if [[ "$name" == "media" ]]; then
    for made in notes.pdf clip.mov; do if [[ -f "$run/$made" ]]; then cp "$run/$made" "$WORK/$made"; fi; done
  fi
done
if [[ $failed == 0 ]]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
