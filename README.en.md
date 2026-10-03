<p align="center"><img src="Resources/AppIcon-1024.png" width="112" alt="Phaeton"></p>

# Phaeton (轻與)

[中文](README.md)

A lightweight macOS file converter: **hold Shift, drag a file, and a wheel appears at the pointer. Drop on the format you want.** The result is saved next to the original, which is never touched. Inspired by the weapon wheel in GTA V and the ping wheel in Apex Legends.

<p align="center">
  <img src="docs/screenshots/wheel.png" height="300" alt="The wheel">
  &nbsp;&nbsp;
  <img src="docs/screenshots/image-editor.png" height="300" alt="Image editor">
</p>

- **Menu bar only:** no Dock icon. The small wheel in the menu bar opens a panel (running, launch at login, how to use it, what to allow). With the panel closed it keeps waiting for drags in the background.
- **Native:** built on macOS frameworks; no background service; nothing is uploaded.
- **No permission to trigger:** it only watches mouse events and the drag pasteboard.
- **More than converting:** drop on the **wrench** at the left of the wheel for an editor with a preview (image crop / background removal / compression, video and audio trim, PDF split).

## Install (three steps, about a minute)

Needs an Apple silicon Mac (M1 or later) on macOS 13 or newer.

**Step 1: open Terminal.** Press `⌘ Space`, type `Terminal`, press Return.

**Step 2: copy the line below, paste it into Terminal and press Return.** The button at the top right of the box copies it.

```bash
curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
```

**Step 3: wait for it to finish.** When the wheel shows up in the menu bar and the Phaeton panel opens, it is installed and you can close Terminal. From now on, hold **Shift** and drag a file.

Afterwards:
- **Update:** run the same line again.
- **Uninstall:** run `rm -rf /Applications/Phaeton.app ~/Library/Application\ Support/Phaeton` in Terminal.
- **Want to see what it does first?** The line just downloads and runs [this script](scripts/install.sh): it fetches the latest [release](https://github.com/Smartin524/Phaeton/releases), verifies its SHA-256, installs to Applications and opens it.

<details>
<summary>Prefer not to use Terminal? Download by hand</summary>

1. Download `Phaeton.zip` from [Releases](https://github.com/Smartin524/Phaeton/releases), double-click to unzip, drag `Phaeton.app` into Applications.
2. Double-click it. macOS says it cannot open it; click Done, not Move to Trash.
3. Open System Settings ▸ Privacy & Security, scroll down to Phaeton, click Open Anyway and enter your password.

(There is no developer signature or notarization, so a manually downloaded copy is blocked the first time; the Terminal install never is.)
</details>

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
- **Shift on a selected file deselects it in Finder:** start the drag first, then press Shift; or turn on "Shift does not deselect selected files" under Permissions in the menu-bar panel (needs Accessibility, off by default).
- **Never overwrites:** writes a temp file then renames, names get a counter, failures leave nothing behind.

## Optional components

WebP, MP3 and PDF → DOCX need a one-time install (about 250 MB, network) into `~/Library/Application Support/Phaeton`, touching nothing system-wide. Phaeton asks on first use, or run `bash scripts/install-extras.sh`. They carry their own licenses (GPL / AGPL / LGPL); see [THIRD-PARTY.md](THIRD-PARTY.md).

## Build and test

macOS 13+ and a Swift toolchain; no Swift package dependencies.

```bash
bash scripts/make-signing-identity.sh  # once: a local signing certificate in your login keychain
bash scripts/build-app.sh     # builds dist/Phaeton.app
swift test                    # unit tests, needs full Xcode
bash scripts/validate.sh      # end-to-end engine checks, samples generated on the spot
bash scripts/make-release.sh  # packs the release zip
```

Tests cover the conversion engine, not the UI or drag feel.

Signing: with the "Phaeton Local Signing" certificate, the Accessibility grant survives rebuilds and updates, and only the machine holding that private key can sign a matching app; without it the build is plain ad-hoc signed and Accessibility must be granted again after each build.

## Known limits

- Detection relies on macOS delivering mouse events to a background app; if it does not, the wheel will not appear. Use the right-click entry.
- Not supported: MKV / WebM / AVI input, FLAC / OGG output, Office → PDF other than Word.
- PDF → DOCX does not guarantee complex layouts; scanned PDFs are not OCR'd.

MIT licensed, see [LICENSE](LICENSE).
