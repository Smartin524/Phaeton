#!/usr/bin/env python3
"""Optional converters for Phaeton that macOS frameworks cannot do.

usage: phaeton_helper.py pdf2docx IN.pdf OUT.docx
       phaeton_helper.py webp IN.png OUT.webp
       phaeton_helper.py mp3 IN.wav OUT.mp3
Exit code 0 on success; errors go to stderr.
"""
import sys


def main() -> int:
    mode, source, target = sys.argv[1:4]
    if mode == "pdf2docx":
        from pdf2docx import Converter
        converter = Converter(source)
        try:
            # By default pdf2docx skips a page it cannot parse and still saves the rest;
            # fail instead so a document with missing pages is never reported as done.
            converter.convert(target, ignore_page_error=False)
        finally:
            converter.close()
    elif mode == "webp":
        from PIL import Image
        with Image.open(source) as image:
            image.save(target, "WEBP", quality=90, method=4)
    elif mode == "mp3":
        import lameenc
        # AVFoundation writes WAVE_FORMAT_EXTENSIBLE, which Python's wave module rejects,
        # so read the RIFF chunks directly.
        import struct
        with open(source, "rb") as wav:
            if wav.read(4) != b"RIFF":
                print("not a RIFF/WAV file", file=sys.stderr)
                return 2
            wav.read(8)
            channels = rate = bits = 0
            data_size = 0
            while True:
                header = wav.read(8)
                if len(header) < 8:
                    print("no audio data", file=sys.stderr)
                    return 2
                name, size = header[:4], struct.unpack("<I", header[4:])[0]
                if name == b"fmt ":
                    _, channels, rate, _, _, bits = struct.unpack("<HHIIHH", wav.read(16))
                    wav.read(size - 16 + (size & 1))
                elif name == b"data":
                    data_size = size
                    break
                else:
                    wav.read(size + (size & 1))
            if bits != 16 or channels not in (1, 2):
                print("need 16-bit mono or stereo WAV", file=sys.stderr)
                return 2
            encoder = lameenc.Encoder()
            encoder.set_bit_rate(192)
            encoder.set_in_sample_rate(rate)
            encoder.set_channels(channels)
            encoder.set_quality(2)
            remaining = data_size
            with open(target, "wb") as out:
                while remaining > 0:
                    chunk = wav.read(min(262144, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    out.write(encoder.encode(chunk))
                out.write(encoder.flush())
    else:
        print("unknown mode", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
