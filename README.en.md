<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Phaeton"></p>

# Phaeton (轻與)

[中文](README.md)

A lightweight macOS menu-bar file converter: **hold Shift, drag a file, and a wheel appears at the pointer. Drop the file on the format you want.** The result is saved next to the original, which is never touched.

- **Inspiration:** the weapon wheel in GTA V and the ping wheel in Apex Legends: hold, flick toward what you want, release.
- **Native and light:** built on macOS frameworks (AppKit, SwiftUI, ImageIO, AVFoundation, PDFKit, Vision). No background service, nothing is uploaded.
- **No permission to trigger:** it only watches mouse events and the drag pasteboard, so it needs no Accessibility or Input Monitoring access.
- **More than converting:** image crop and compress, video trim / frame grab / compress, audio trim with fades, each in a small window with a preview.

## Install

**One command** (macOS 13+, Apple silicon and Intel):

```bash
curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
```

It downloads the latest zip from [Releases](https://github.com/Smartin524/Phaeton/releases), verifies its SHA-256, installs to `/Applications` (or `~/Applications` if that is not writable) and opens it. Read the [script](scripts/install.sh) before running it; it is short. To update, run it again.

**Manual install:** download the zip from Releases, unzip, drag `Phaeton.app` into Applications. The app has no developer signature or notarization, so a browser-downloaded copy is blocked the first time: right-click ▸ Open, or run `xattr -dr com.apple.quarantine /Applications/Phaeton.app`. Installing with the command above avoids that prompt.

**Uninstall:** `rm -rf /Applications/Phaeton.app ~/Library/Application\ Support/Phaeton` (the second path holds the optional components).

**Build from source:** see [Build and run](#build-and-run).

## What it converts

| Dragged file | Formats on the wheel |
|---|---|
| Image (incl. SVG) | PNG / JPEG / WebP\* / HEIC / PDF / TXT (text recognised in the picture) |
| Video | M4A / WAV / AIFF (audio extraction), MP3\*, MP4 / MOV |
| Audio | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG (a folder for multi-page), TXT (OCR when there is no text layer), DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

\* needs the [optional components](#optional-components); Phaeton asks before installing them on first use. A format the file already has is hidden.

**Dragging several files** adds a sector: several images → **merge into one PDF**, several PDFs → **merge**, several videos or audio files → **join**.

The last sector of the wheel for images, video, audio and PDFs is a **wrench**: drop on it to open an editor window.

| | In the window |
|---|---|
| Image | Crop page: draggable box, fixed ratios, exact width × height; three quality levels for JPEG / HEIC with a size estimate. More page: **remove background** (transparent PNG, macOS 14+), strip location and other metadata, **compress to a target size**, copy the text in the picture, read QR codes |
| Video | Edit page: thumbnail timeline, **fast trim** (no re-encode, lossless, starts on a key frame), save the current frame as PNG. More page: compress to 1080p / 720p / 480p, **compress to a target size**, mute, change speed (0.5× – 2×) |
| Audio | waveform to pick start and end; optional 1 s fade in / out; copied losslessly without fades, re-encoded to M4A with them |
| PDF | preview; extract pages (e.g. `1-3,5`) into a new PDF; split into one PDF per page |

## Other entry points and details

- **Finder right-click:** Quick Actions / Services ▸ "Convert with Phaeton…". If missing, enable it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.
- **Menu bar:** just one settings switch and Quit; everything else is dragging, right-click and notifications.
- **Progress and notifications:** after the drop the wheel turns into a progress ring where it was, and **clicking the ring cancels**; a system notification when done (asks permission once) reveals the result when clicked.
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

- `swift test`: 22 unit tests (image-conversion safety and pixel details, wheel geometry, file-kind and format rules); needs full Xcode.
- `bash scripts/validate.sh`: end-to-end checks of the conversion engine, with sample files generated on the spot (images, audio/video, documents, merge and join, OCR, trim, cancel…). Checks that need the optional components are skipped when they are not installed.

Both test the engine, not the UI; the interface and drag feel have no automated tests.

## Known limits

- Detection relies on macOS delivering global mouse events to a background app; if it does not, the wheel will not appear. Use the right-click or menu-bar entry.
- Not supported: MKV / WebM / AVI input, FLAC / OGG output, Office → PDF other than Word.
- PDF → DOCX does not guarantee complex layouts; scanned PDFs are not OCR'd.
- No developer signature or notarization (see Install); the UI and drag feel have no automated tests; the Intel build compiles but has not been tested on real hardware.

## Layout

```text
Sources/FormatWheel/      menu bar, drag monitor, wheel, editor windows, progress ring
Sources/FormatWheelCore/  file kinds and formats, wheel geometry, image / media / document engines
scripts/                  build, icon, optional-components installer, validation
validation/               standalone engine checks
```

The internal target is still named `FormatWheel`.

## License

MIT, see [LICENSE](LICENSE).
