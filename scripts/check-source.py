#!/usr/bin/env python3
"""Lightweight source-package checks; NOT a Swift compiler or runtime test."""
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
required = [
    "Package.swift", "Resources/Info.plist", "README.md", "LICENSE", "THIRD-PARTY.md", "Sources/FormatWheel/main.swift",
    "Sources/FormatWheel/DragMonitor.swift", "Sources/FormatWheel/DropWheel.swift",
    "Sources/FormatWheelCore/OutputFormat.swift", "Sources/FormatWheelCore/ImageConverter.swift",
    "Tests/FormatWheelCoreTests/WheelGeometryTests.swift",
    "Tests/FormatWheelCoreTests/ImageConverterTests.swift",
]
missing = [name for name in required if not (root / name).is_file()]
assert not missing, f"Missing files: {missing}"
with (root / "Resources/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["CFBundleExecutable"] == "FormatWheel"
assert info["CFBundleName"] == "Phaeton"
assert info["CFBundleDisplayName"] == "Phaeton"
assert info["CFBundleIdentifier"] == "io.github.smartin524.phaeton"
assert info["LSMinimumSystemVersion"] == "13.0"
swift_files = list((root / "Sources").rglob("*.swift"))
sources = "\n".join(path.read_text() for path in swift_files)
for token in ("MultitouchSupport", "CGSSet"):
    assert token not in sources, f"Unexpected private API or permission-request route: {token}"
engine = (root / "Sources/FormatWheelCore/ImageConverter.swift").read_text()
assert "O_EXCL" in engine and "O_NOFOLLOW" in engine
assert "Darwin.unlink(" not in engine and "removeItem(" not in engine
assert "CGImageDestinationAddImage(" in engine
assert "CGImageDestinationAddImageFromSource(" not in engine
assert "case .pdf:" in engine and "rasterTypes" in engine
print(f"PASS: required files, plist, source guardrails ({len(swift_files)} Swift source files)")
print("NOT RUN: Swift compilation, XCTest, AppKit UI, Finder/Desktop, trackpad delivery")
sys.exit(0)
