#!/usr/bin/env python3
"""Regenerate `assets/offline_map/signs/no_u_turn.png` (QCVN 41:2019 P.125).

Why: the shipped PNG was structurally broken (measured by
`check_sign_structure.py`):
  * black glyph only 2,360 px vs ~7,600 px for the other P.12x signs
  * glyph centroid 30% of the disc radius off-centre (arrow pushed right)
  * the red prohibition SLASH was absent (inner-red x/y correlation +0.06,
    where the correct signs measure +0.96)

A prohibition sign without its slash reads as permission, so "cấm quay đầu"
rendered as "quay đầu được phép" — the wrong sign on the map.

This draws the sign deterministically so it can be verified by
`check_sign_art.py` and `check_sign_structure.py`:

    white disc + red ring + black u-turn arrow (loops to the LEFT)
    + red diagonal slash (top-left -> bottom-right, matching the other signs)

The original file is preserved as `no_u_turn.png.orig` the first time this runs.

Usage:
    python3 tools/signs/make_uturn_sign.py [--size 330]
"""
import argparse
import os
import shutil
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "offline_map", "signs", "no_u_turn.png")

RED = (200, 16, 46, 255)      # QCVN sign red, matches the other assets
BLACK = (26, 26, 26, 255)
WHITE = (255, 255, 255, 255)


def build(size=330):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size / 2.0
    r_out = size * 0.500
    ring = size * 0.058          # ring thickness ~ 5.8% of the size

    # Red ring with white field.
    d.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], fill=WHITE)
    d.ellipse(
        [c - r_out, c - r_out, c + r_out, c + r_out],
        outline=RED,
        width=int(ring),
    )

    # Black U-turn arrow: up on the right, loop across the top to the left,
    # back down on the left, arrowhead pointing down.
    stroke = size * 0.072
    sx = size * 0.115            # half-distance between the two legs
    top = c - size * 0.150       # apex height
    bot = c + size * 0.175       # where the legs end
    # Right leg up.
    d.line([(c + sx, bot), (c + sx, top + size * 0.06)], fill=BLACK, width=int(stroke))
    # Loop across the top (a half-circle approximated by a thick arc).
    box = [
        c - sx - size * 0.030,
        top - size * 0.030,
        c + sx + size * 0.030,
        top + size * 0.090,
    ]
    d.arc(box, start=180, end=360, fill=BLACK, width=int(stroke))
    # Left leg down.
    d.line([(c - sx, top + size * 0.06), (c - sx, bot)], fill=BLACK, width=int(stroke))
    # Arrowhead at the bottom of the left leg, pointing down.
    ah = size * 0.075
    d.polygon(
        [
            (c - sx, bot + ah * 0.75),
            (c - sx - ah, bot - ah * 0.25),
            (c - sx + ah, bot - ah * 0.25),
        ],
        fill=BLACK,
    )

    # Red prohibition slash: top-left -> bottom-right (same orientation as the
    # shipped P.123 / P.124 assets, whose inner-red correlation is +0.96).
    lim = r_out - ring * 0.55
    d.line(
        [(c - lim * 0.707, c - lim * 0.707), (c + lim * 0.707, c + lim * 0.707)],
        fill=RED,
        width=int(size * 0.078),
    )
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=330)
    args = ap.parse_args()

    if os.path.exists(OUT) and not os.path.exists(OUT + ".orig"):
        shutil.copy2(OUT, OUT + ".orig")
        print(f"backed up original -> {os.path.basename(OUT)}.orig")

    im = build(args.size)
    im.save(OUT)
    print(f"wrote {OUT} ({args.size}x{args.size})")
    print("verify with:  python3 tools/signs/check_sign_structure.py")
    print("              python3 tools/signs/check_sign_art.py")


if __name__ == "__main__":
    main()
