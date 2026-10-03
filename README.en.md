<p align="center"><img src="Resources/AppIcon-1024.png" width="112" alt="Phaeton"></p>

# Phaeton (轻與)

[中文](README.md)

A lightweight macOS file converter: **hold Shift, drag a file, and a wheel appears at the pointer. Drop on the format you want.** The result is saved next to the original, which is never touched. Inspired by the weapon wheel in GTA V and the ping wheel in Apex Legends.

<p align="center">
  <img src="docs/screenshots/wheel.png" width="230" alt="The wheel">
  &nbsp;&nbsp;
  <img src="docs/screenshots/image-editor.png" width="520" alt="Image editor">
</p>

- **Opens ready to use:** it starts with a simple window (running, launch at login, how to use it, what to allow). Close it and the app keeps waiting for drags in the background; click its Dock icon to bring the window back.
- **Native:** built on macOS frameworks; no background service; nothing is uploaded.
- **No permission to trigger:** it only watches mouse events and the drag pasteboard.
- **More than converting:** drop on the **wrench** at the left of the wheel for an editor with a preview (image crop / background removal / compression, video and audio trim, PDF split).

## Install

Needs an Apple silicon Mac, macOS 13+.

```bash
curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
```

It downloads the latest [release](https://github.com/Smartin524/Phaeton/releases), verifies its SHA-256, installs to `/Applications` and opens it (read the [script](scripts/install.sh) first if you like). To update, run it again. Uninstall: `rm -rf /Applications/Phaeton.app ~/Library/Application\ Support/Phaeton`.

There is no developer signature or notarization, so a **manually downloaded zip** is blocked the first time: double-click once, then System Settings ▸ Privacy & Security ▸ Open Anyway (right-click ▸ Open stopped working in macOS 15); or run `xattr -dr com.apple.quarantine /Applications/Phaeton.app`. The command above avoids this.

## What it converts

| Dragged file | Formats on the wheel |
|---|---|
| Image (incl. SVG) | PNG / JPEG / WebP\* / HEIC / PDF / TXT (text recognition) |
| Video | M4A / WAV / AIFF (audio), MP3\*, MP4 / MOV |
| Audio | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG, TXT (OCR when there is no text layer), DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

\* needs the [optional components](#optional-components). Several files at once add a sector: **merge PDF** (images or PDFs), **join** (video or audio).

**The wrench window**

- **Image:** crop (ratios or exact pixels), quality, remove background, compress to a target size, strip metadata, copy the text, read QR codes.
- **Video:** fast lossless trim, grab the current frame, compress (resolution or target size), mute, change speed.
- **Audio:** pick a segment on the waveform, optional fades.
- **PDF:** preview, extract pages, split into one PDF per page.

## Other

- **Finder right-click:** Quick Actions / Services ▸ "Convert with Phaeton…" (enable it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services if missing).
- **Progress:** after the drop the wheel becomes a progress ring; click it to cancel; a notification when done.
- **Shift on a selected file deselects it in Finder:** start the drag first, then press Shift; or turn on "Shift does not deselect selected files" under Permissions in the main window (needs Accessibility, off by default).
- **Never overwrites:** writes a temp file then renames, names get a counter, failures leave nothing behind.

## Optional components

WebP, MP3 and PDF → DOCX need a one-time install (about 250 MB, network) into `~/Library/Application Support/Phaeton`, touching nothing system-wide. Phaeton asks on first use, or run `bash scripts/install-extras.sh`. They carry their own licenses (GPL / AGPL / LGPL); see [THIRD-PARTY.md](THIRD-PARTY.md).

## Build and test

macOS 13+ and a Swift toolchain; no Swift package dependencies.

```bash
bash scripts/build-app.sh     # builds dist/Phaeton.app (ad-hoc signed)
swift test                    # unit tests, needs full Xcode
bash scripts/validate.sh      # end-to-end engine checks, samples generated on the spot
bash scripts/make-release.sh  # packs the release zip
```

Tests cover the conversion engine, not the UI or drag feel.

## Known limits

- Detection relies on macOS delivering mouse events to a background app; if it does not, the wheel will not appear. Use the right-click entry.
- Not supported: MKV / WebM / AVI input, FLAC / OGG output, Office → PDF other than Word.
- PDF → DOCX does not guarantee complex layouts; scanned PDFs are not OCR'd.

MIT licensed, see [LICENSE](LICENSE).
