#!/usr/bin/env python3
# Generate the iOS AppIcon from the traced otter source.
#
# Source of truth: icon-otter-source.png (a 1024x1024 cute-otter mark drawn on a
# cream rounded card sitting on white). iOS app icons must be FULL-BLEED with no
# alpha and no rounded corners (the system applies the squircle mask itself), so
# this script floods the light background (white border + cream card + its drop
# shadow) to a single flat cream and writes the result as icon_1024.png.
#
# Run from the ios/ dir:  python3 icon-source.py
import os
from PIL import Image
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "icon-otter-source.png")
DST  = os.path.join(HERE, "Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
CREAM = (249, 244, 240)   # the card colour — becomes the full-bleed background
SCALE = 1.20              # enlarge the otter so it fills more of the frame

a = np.asarray(Image.open(SRC).convert("RGB")).astype(np.int16)
R, G, B = a[..., 0], a[..., 1], a[..., 2]
# Light background = white border + cream card + shadow. The otter (incl. its
# pale muzzle, B~212) stays below at least one of these thresholds, so it survives.
bg = (R > 238) & (G > 233) & (B > 228)
out = a.astype(np.uint8).copy()
out[bg] = CREAM

img = Image.fromarray(out)
# Enlarge the otter (cream is uniform, so scale the whole frame then centre-crop).
if SCALE != 1.0:
    big = img.resize((round(1024 * SCALE), round(1024 * SCALE)), Image.LANCZOS)
    off = (big.width - 1024) // 2
    img = big.crop((off, off, off + 1024, off + 1024))
img.save(DST, "PNG")
# A copy for the GitHub org avatar (same full-bleed art).
img.save(os.path.join(HERE, "..", "pervio-org-avatar-1024.png"), "PNG")
print("saved", DST, img.size)
