#!/usr/bin/env python3
"""Draw Wayfarer's original sail mark and generate the native macOS icon catalog."""
import json
import math
from pathlib import Path
import struct
import subprocess
import zlib

root = Path(__file__).resolve().parents[1]
catalog = root / "Assets.xcassets"
icons = catalog / "AppIcon.appiconset"
icons.mkdir(parents=True, exist_ok=True)
size = 1024
rows = bytearray()


def triangle(x, y, points):
    signs = []
    for index in range(3):
        a, b = points[index], points[(index + 1) % 3]
        signs.append((x - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (y - b[1]))
    return all(value >= 0 for value in signs) or all(value <= 0 for value in signs)


for y in range(size):
    rows.append(0)
    for x in range(size):
        # Rounded midnight square, with two sails above a calm sea.
        dx = max(abs(x - 511.5) - 322, 0)
        dy = max(abs(y - 511.5) - 322, 0)
        inside = dx * dx + dy * dy <= 162 * 162
        glow = max(0, 1 - math.hypot(x - 610, y - 310) / 800)
        color = (int(13 + 12 * glow), int(25 + 20 * glow), int(34 + 20 * glow), 255 if inside else 0)
        sail = triangle(x, y, [(492, 220), (492, 600), (255, 600)]) or triangle(x, y, [(532, 305), (532, 600), (744, 600)])
        hull = triangle(x, y, [(251, 638), (776, 638), (671, 728)]) or triangle(x, y, [(251, 638), (671, 728), (364, 728)])
        wave = 235 < x < 790 and abs(y - (782 + 12 * math.sin((x - 240) / 88))) < 8
        if inside and (sail or hull):
            color = (115, 226, 202, 255) if x > 515 else (225, 242, 233, 255)
        elif inside and wave:
            color = (74, 148, 145, 255)
        rows.extend(color)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
source = icons / "icon_512x512@2x.png"
source.write_bytes(png)
images = []
for points in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        filename = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
        output = icons / filename
        if output != source:
            subprocess.run(["sips", "-z", str(points * scale), str(points * scale), str(source), "--out", str(output)], check=True, stdout=subprocess.DEVNULL)
        images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": filename})
(icons / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
(catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
