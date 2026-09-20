#!/usr/bin/env python3
"""ASCII-render a sign PNG so its actual shape can be inspected without an
image viewer, plus a colour histogram.

Written to diagnose `no_u_turn.png` (P.125 Cấm quay đầu), which the geometric
check in `check_sign_art.py` flagged as odd: few dark pixels, none in the top or
bottom third, and all of them in the right half.

Usage:
    python3 tools/signs/dump_sign_art.py assets/offline_map/signs/no_u_turn.png
"""
import os
import sys
from collections import Counter

from PIL import Image


def classify(p):
    r, g, b, a = p
    if a < 32:
        return ' '          # transparent
    if r > 180 and g < 90 and b < 90:
        return 'R'          # sign red (border / slash)
    if r < 90 and g < 90 and b < 90:
        return '#'          # black glyph
    if r > 200 and g > 200 and b > 200:
        return '.'          # white field
    return '+'              # anything else


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    im = Image.open(path).convert('RGBA')
    w, h = im.size
    px = im.load()
    print(f"{os.path.basename(path)}  {w}x{h}")

    hist = Counter(classify(px[x, y]) for y in range(h) for x in range(w))
    print("classes:", dict(hist))

    # ASCII render, block-averaged down to <= 60 cols.
    cols = 56
    import sys as _s
    if "--cols" in _s.argv:
        cols = int(_s.argv[_s.argv.index("--cols") + 1])
    step = max(1, w // cols)
    for y in range(0, h, step):
        row = []
        for x in range(0, w, step):
            counts = Counter(
                classify(px[xx, yy])
                for yy in range(y, min(y + step, h))
                for xx in range(x, min(x + step, w))
            )
            # ignore transparent unless it dominates
            body = {k: v for k, v in counts.items() if k != ' '}
            row.append(max(body, key=body.get) if body else ' ')
        print(''.join(row))

    # Bounding box of the black glyph.
    dk = [(x, y) for y in range(h) for x in range(w)
          if classify(px[x, y]) == '#']
    if dk:
        xs = [p[0] for p in dk]
        ys = [p[1] for p in dk]
        print(f"black glyph bbox: x {min(xs)}..{max(xs)}  y {min(ys)}..{max(ys)}"
              f"  ({len(dk)} px)")
    else:
        print("black glyph: NONE")


if __name__ == "__main__":
    main()
