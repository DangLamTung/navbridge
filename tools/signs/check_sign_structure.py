#!/usr/bin/env python3
"""Structural check of the QCVN prohibition-sign PNGs.

A Vietnamese prohibition sign (P.12x) is: white disc + red ring + a black glyph
+ a RED DIAGONAL SLASH across it. The slash is what makes it a prohibition. If
the slash is missing or the glyph sits off-centre, the sign reads as the
opposite meaning.

This measures, per sign:
  * dark-glyph mass and its centroid (should be near the disc centre)
  * red pixels INSIDE the disc, i.e. excluding the ring: that is the slash
  * the x/y correlation of those inner red pixels (a slash is diagonal, so the
    correlation is strongly +/-1; a ring only leaks in with ~0 correlation)

Usage:
    python3 tools/signs/check_sign_structure.py
"""
import math
import os
import sys

from PIL import Image

SIGNS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "assets", "offline_map", "signs",
)
FILES = ("no_left_turn.png", "no_right_turn.png", "no_u_turn.png")


def is_dark(p):
    return p[3] > 128 and p[0] < 90 and p[1] < 90 and p[2] < 90


def is_red(p):
    return p[3] > 128 and p[0] > 180 and p[1] < 90 and p[2] < 90


def corr(pts):
    n = len(pts)
    if n < 10:
        return float('nan')
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxy = sum((p[0] - mx) * (p[1] - my) for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    syy = sum((p[1] - my) ** 2 for p in pts)
    if sxx <= 0 or syy <= 0:
        return float('nan')
    return sxy / math.sqrt(sxx * syy)


def main():
    for name in FILES:
        path = os.path.join(SIGNS, name)
        if not os.path.exists(path):
            print(f"{name}: MISSING")
            continue
        im = Image.open(path).convert('RGBA')
        w, h = im.size
        px = im.load()
        cx, cy = w / 2.0, h / 2.0
        # Disc radius: outermost red ring pixel.
        rmax = 0.0
        for y in range(h):
            for x in range(w):
                if is_red(px[x, y]):
                    rmax = max(rmax, math.hypot(x - cx, y - cy))
        inner = rmax * 0.72  # safely inside the ring
        dark, red_in = [], []
        for y in range(h):
            for x in range(w):
                d = math.hypot(x - cx, y - cy)
                p = px[x, y]
                if d < inner:
                    if is_dark(p):
                        dark.append((x, y))
                    elif is_red(p):
                        red_in.append((x, y))
        gx = sum(p[0] for p in dark) / len(dark) if dark else float('nan')
        gy = sum(p[1] for p in dark) / len(dark) if dark else float('nan')
        off = math.hypot(gx - cx, gy - cy) if dark else float('nan')
        print(f"{name}")
        print(f"   disc r={rmax:.1f}  inner r={inner:.1f}")
        print(f"   black glyph  n={len(dark):5d}  centroid=({gx:.1f},{gy:.1f}) "
              f"off-centre by {off:.1f}px = {100 * off / rmax:.0f}% of radius")
        print(f"   red INNER (the slash) n={len(red_in):5d}  "
              f"x/y corr={corr(red_in):+.2f}")
        slash = len(red_in) > 0.02 * math.pi * inner * inner and abs(corr(red_in)) > 0.5
        print(f"   => prohibition slash: {'PRESENT' if slash else 'MISSING/UNUSUAL'}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
