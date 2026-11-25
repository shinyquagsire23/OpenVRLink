#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Generates the Android launcher icon from the visionOS app icon layers.

    python3 client/android/make-icon.py

Requires Pillow (pip install pillow). The generated PNG is checked into the repository, so this only
needs re-running when the visionOS icon layers change.
"""
import pathlib
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
LAYERS = HERE.parent / "visionOS/Resources"
# An adaptive icon is 108 dp square, of which launchers show at most the middle 72 dp through their mask;
# the rest only appears as the icon shifts under a pointer. 432 px is 108 dp at xxxhdpi.
CANVAS, SHOWN = 432, 288

picture = Image.open(LAYERS / "IconBack.png").convert("RGBA")
for layer in ("IconMiddle.png", "IconFront.png"):
    picture = Image.alpha_composite(picture, Image.open(LAYERS / layer).convert("RGBA"))
icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
icon.paste(picture.resize((SHOWN, SHOWN), Image.LANCZOS), ((CANVAS - SHOWN) // 2, (CANVAS - SHOWN) // 2))
out = HERE / "res/mipmap-xxxhdpi/icon_foreground.png"
icon.save(out, optimize=True)
print(out)
