#!/usr/bin/env python3
"""Key, crop and split the nano-banana cog renders into the board sprites.

The board character is a NANO-BANANA RENDER OF THE SOFTMAX COG, not a
procedural rig: `scripts/art/source/cog_topdown.png` is a
`gemini-2.5-flash-image` render anchored on the shipped `data/soldier_red.png`
master (the same character, drawn from directly above so it reads on a game
board). This script turns it into the four board facings the sim needs.

Gemini does not return alpha, and the "pure green" you asked for comes back as
*some* green with a tinted edge. So: flood-fill from the image border (green
accents INSIDE the character survive), take the backdrop colour as the MEDIAN
OF THE BORDER (corners sometimes carry a smudge), crop to the alpha bounding
box, pad to a square, and resize.

THE FOUR FACINGS ARE ROTATIONS OF THE ONE RENDER, not four separate
generations. That is deliberate and it is correct: a strict top-down sprite
rotated by 90 degrees IS the same character facing the next direction, and one
render keeps the style identical across all four (four calls would not). The
source render faces SOUTH; PIL rotates counter-clockwise, so the bottom edge
swings to the right and rotate(90) yields the EAST facing.

    python3 scripts/art/split_cog_sheet.py

Writes data/art/cog_{east,south,west,north}.png. The derived PNGs are
COMMITTED — CI does not regenerate art — and `src/minigrid/global.nim`
staticReads them, so the wasm module carries its own character art and a
missing preload can never leave the hosted viewer with a blank cog.
"""

import os
import sys
from collections import deque

try:
    from PIL import Image
except ImportError:                                        # pragma: no cover
    sys.exit("this script needs Pillow: python3 -m pip install --user pillow")

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(REPO, "scripts", "art", "source", "cog_topdown.png")
OUT_DIR = os.path.join(REPO, "data", "art")
SIZE = 128
TOLERANCE = 78
# The source render faces SOUTH; PIL rotates counter-clockwise.
FACINGS = {"south": 0, "east": 90, "north": 180, "west": 270}


def median_border(image):
    """The backdrop colour: the median of the border pixels, not a corner."""
    width, height = image.size
    reds, greens, blues = [], [], []
    for x in range(width):
        for y in (0, height - 1):
            r, g, b, _ = image.getpixel((x, y))
            reds.append(r); greens.append(g); blues.append(b)
    for y in range(height):
        for x in (0, width - 1):
            r, g, b, _ = image.getpixel((x, y))
            reds.append(r); greens.append(g); blues.append(b)
    reds.sort(); greens.sort(); blues.sort()
    mid = len(reds) // 2
    return reds[mid], greens[mid], blues[mid]


def key_from_border(image, backdrop):
    """Flood-fill the backdrop from the border so inside greens survive."""
    width, height = image.size
    pixels = image.load()
    seen = bytearray(width * height)
    queue = deque()

    def close(pixel):
        return (abs(pixel[0] - backdrop[0]) + abs(pixel[1] - backdrop[1]) +
                abs(pixel[2] - backdrop[2])) <= TOLERANCE * 3

    for x in range(width):
        for y in (0, height - 1):
            queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        if not close(pixels[x, y]):
            continue
        seen[index] = 1
        pixels[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return image


def square_pad(image):
    box = image.getbbox()
    if box is None:
        sys.exit("the keyed render is empty — the chroma key removed everything")
    cropped = image.crop(box)
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(cropped, ((side - cropped.width) // 2,
                           (side - cropped.height) // 2))
    return canvas


def main():
    if not os.path.exists(SOURCE):
        sys.exit("missing %s — regenerate it with the recipe in "
                 "playbooks/art-nanobanana.md" % SOURCE)
    image = Image.open(SOURCE).convert("RGBA")
    backdrop = median_border(image)
    print("backdrop: %r" % (backdrop,))
    keyed = key_from_border(image, backdrop)
    body = square_pad(keyed).resize((SIZE, SIZE), Image.LANCZOS)
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, angle in FACINGS.items():
        facing = body.rotate(angle, resample=Image.BICUBIC, expand=False)
        path = os.path.join(OUT_DIR, "cog_%s.png" % name)
        facing.save(path)
        print("wrote %s" % path)


if __name__ == "__main__":
    main()
