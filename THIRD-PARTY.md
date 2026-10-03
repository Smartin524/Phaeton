# Third-party software

Phaeton itself (everything in this repository) is MIT-licensed and **bundles no third-party
code**. It uses macOS system frameworks (AppKit, SwiftUI, ImageIO, AVFoundation, PDFKit, Vision).

## Optional components (downloaded by the user, not distributed here)

`scripts/install-extras.sh` — which Phaeton can run for you after you confirm — creates a private
Python virtual environment in `~/Library/Application Support/Phaeton` and installs these packages
from PyPI. They enable WebP output, MP3 output and PDF → DOCX. Phaeton runs them as a separate
process (`scripts/phaeton_helper.py`); nothing is linked into the app.

| Package | Used for | License |
|---|---|---|
| [pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) | PDF → DOCX | GPL-3.0 |
| [PyMuPDF](https://github.com/pymupdf/PyMuPDF) (pinned to 1.24.14) | dependency of pdf2docx | AGPL-3.0 |
| [Pillow](https://github.com/python-pillow/Pillow) | WebP output | HPND (permissive) |
| [lameenc](https://github.com/chrisstaite/lameenc) (bundles LAME) | MP3 output | LGPL-3.0 |

If you redistribute a build together with these packages, you take on their license terms (GPL /
AGPL / LGPL). Using them locally, installed by you on your own Mac, does not change Phaeton's own
MIT license. This is a plain description, not legal advice. If that is a concern, simply do not
install the optional components; every other feature works without them.

## Inspiration

The wheel is inspired by the weapon wheel in Grand Theft Auto V and the ping wheel in Apex Legends:
hold a key, flick toward what you want, release. Phaeton shares no code, assets or artwork with
those games or with any other software.
