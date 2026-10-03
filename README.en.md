<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Phaeton"></p>

# Phaeton

[中文](README.md)

A lightweight macOS menu-bar file converter: **hold Shift, drag a file, and a wheel appears at the pointer. Drop the file on the format you want.** The result is saved next to the original, which is never touched.

- **Native and light:** built on macOS frameworks (AppKit, SwiftUI, ImageIO, AVFoundation, PDFKit, Vision). No background service, nothing is uploaded.
- **No permission to trigger:** it only watches mouse events and the drag pasteboard, so it needs no Accessibility or Input Monitoring access.
- **More than converting:** image crop and compress, video trim / frame grab / compress, audio trim with fades, each in a small window with a preview.

## What it converts

| Dragged file | Formats on the wheel |
|---|---|
| Image (incl. SVG) | PNG / JPEG / WebP\* / HEIC / PDF |
| Video | M4A / WAV / AIFF (audio extraction), MP3\*, MP4 / MOV |
| Audio | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG (a folder for multi-page), TXT (OCR when there is no text layer), DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

\* needs the [optional components](#optional-components); Phaeton asks before installing them on first use. A format the file already has is hidden.

The last sector of the wheel for images, video and audio is a **wrench**: drop on it to open an editor window.

| | In the window |
|---|---|
| Image | draggable crop box, fixed ratios, exact width × height; three quality levels for JPEG / HEIC with a size estimate |
| Video | thumbnail timeline to pick start and end, **fast trim** (no re-encode, lossless, starts on a key frame); save the current frame as PNG; compress to 1080p / 720p / 480p |
| Audio | waveform to pick start and end; optional 1 s fade in / out; copied losslessly without fades, re-encoded to M4A with them |

## Other entry points and details

- **Finder right-click:** Quick Actions / Services ▸ "用 Phaeton 转换…". If missing, enable it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.
- **Menu bar:** "Choose files…", cancel, reveal last result.
- **Progress and notifications:** after the drop the wheel turns into a progress ring where it was; a system notification when done (asks permission once).
- **Shift on a selected file deselects it** (that is Finder's own behavior): start the drag first, then press Shift; or enable "Shift does not deselect selected files" in the menu (needs Accessibility, off by default).
- **Safety:** output is written to a hidden temp file and renamed atomically; existing files are never overwritten (names get a counter); failures and cancels leave nothing behind.

## Build and run

Needs macOS 13+ and a Swift toolchain (Xcode or Command Line Tools). No Swift package dependencies.

```bash
bash scripts/build-app.sh        # builds dist/Phaeton.app (ad-hoc signed, not notarized)
open dist/Phaeton.app
```

If the SDK and toolchain disagree, set `FORMATWHEEL_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. An un-notarized app needs right-click ▸ Open the first time.

## Optional components

WebP, MP3 and PDF → DOCX need a one-time install (about 250 MB, network required) into the private folder `~/Library/Application Support/Phaeton`, touching nothing system-wide. Phaeton offers to do it on first use, or run `bash scripts/install-extras.sh`. To remove them, delete that folder.
They carry their own licenses (GPL / AGPL / LGPL); see [THIRD-PARTY.md](THIRD-PARTY.md).

## Validation

`bash scripts/validate.sh` runs standalone checks of the conversion engine against `samples/` (images, audio/video, documents, cancel, trim, OCR). They test the engine, not the UI. The `swift test` unit tests need full Xcode (the Command Line Tools lack XCTest) and the author has not run them yet.

## Known limits

- Detection relies on macOS delivering global mouse events to a background app; if it does not, the wheel will not appear. Use the right-click or menu-bar entry.
- Not supported: MKV / WebM / AVI input, FLAC / OGG output, Office → PDF other than Word.
- PDF → DOCX does not guarantee complex layouts; scanned PDFs are not OCR'd.
- Not signed or notarized; the UI and drag feel have no automated tests.

## Layout

```text
Sources/FormatWheel/      menu bar, drag monitor, wheel, editor windows, progress ring
Sources/FormatWheelCore/  file kinds and formats, wheel geometry, image / media / document engines
scripts/                  build, icon, optional-components installer, validation
validation/               standalone engine checks
samples/                  hand-made sample files
```

The internal target is still named `FormatWheel`.

## License

MIT, see [LICENSE](LICENSE).
