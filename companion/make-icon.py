#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Generates the Windows .ico icon for openvrlink-companion from the visionOS app icon layers.

    python3 companion/make-icon.py

Requires Pillow (pip install pillow). Because the generated .ico is checked into the
repository, this script only needs to be re-run when the visionOS icon layers change
(see design/icon-drafts/export_visionos.py).
"""
import io, pathlib, struct
from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
LAYERS = HERE.parent / "client/visionOS/Resources"
OUT = HERE / "Resources/openvrlink-companion.ico"
# Store small icon sizes as uncompressed BMP frames for compatibility and 64 px+ sizes as PNG to keep the file small.
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
AS_PNG_FROM = 64

picture = Image.open(LAYERS / "IconBack.png").convert("RGBA")
for layer in ("IconMiddle.png", "IconFront.png"):
    picture = Image.alpha_composite(picture, Image.open(LAYERS / layer).convert("RGBA"))
# visionOS masks the layered icon to a circle at display time, so apply an antialiased circular alpha mask here.
mask = Image.new("L", (picture.width * 4, picture.height * 4), 0)
ImageDraw.Draw(mask).ellipse((0, 0, mask.width - 1, mask.height - 1), fill=255)
picture.putalpha(mask.resize(picture.size, Image.LANCZOS))


def entries(sizes, bitmap_format):
    """Render `sizes` into an in-memory ICO via Pillow and return `(width, height, colors, planes, bits, data)` tuples."""
    if not sizes:
        return []
    data = io.BytesIO()
    picture.save(data, format="ICO", sizes=[(size, size) for size in sizes], bitmap_format=bitmap_format)
    raw = data.getvalue()
    _, _, count = struct.unpack_from("<HHH", raw, 0)
    out = []
    for index in range(count):
        width, height, colors, reserved, planes, bits, length, offset = struct.unpack_from("<BBBBHHII", raw, 6 + 16 * index)
        out.append((width, height, colors, planes, bits, raw[offset:offset + length]))
    return out


images = entries([s for s in SIZES if s < AS_PNG_FROM], "bmp") + entries([s for s in SIZES if s >= AS_PNG_FROM], "png")
images.sort(key=lambda image: image[0] or 256)
header = struct.pack("<HHH", 0, 1, len(images))
offset = len(header) + 16 * len(images)
directory, body = b"", b""
for width, height, colors, planes, bits, data in images:
    directory += struct.pack("<BBBBHHII", width, height, colors, 0, planes, bits, len(data), offset + len(body))
    body += data
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(header + directory + body)
print(f"{OUT}: {len(images)} sizes, {OUT.stat().st_size} bytes")
