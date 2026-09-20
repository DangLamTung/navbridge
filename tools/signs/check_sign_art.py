#!/usr/bin/env python3
"""Check that the bundled QCVN 41 sign PNGs actually depict what their filenames
claim.

Motivation: on some routes the map rendered the WRONG sign — a "cấm rẽ phải"
(P.124) shown as "cấm rẽ trái" (P.123), and "cấm quay đầu" (P.125) wrong too.
The kinds are wired to PNGs in `SignIcon._assetFor`, so if the artwork is
mirrored or mislabelled the app shows the wrong sign no matter what the data
says.

Method (no deps beyond Pillow): isolate the near-black arrow glyph (ignoring the
red ring and the red slash), then compare the horizontal centroid of the glyph
in the TOP third vs the BOTTOM third of the image. A sign that forbids turning
LEFT is an arrow with a vertical stem at the RIGHT and a head bending LEFT at
the top, so `centroid(top) < centroid(bottom)`. A RIGHT-turn sign is the
mirror. That is a purely geometric test of drawn direction — it does not care
which way the file is named.

Usage:
    python3 tools/signs/check_sign_art.py
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install pillow")

SIGNS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "assets", "offline_map", "signs",
)

# filename -> direction the arrow MUST bend, per QCVN 41:2019/BGTVT
EXPECT = {
    "no_left_turn.png": "LEFT",   # P.123 Cấm rẽ trái
    "no_right_turn.png": "RIGHT",  # P.124 Cấm rẽ phải
}
# P.125 Cấm quay đầu: the loop curls to the LEFT of the stem in the VN sign.
EXPECT_UTURN = "no_u_turn.png"


def dark_glyph(path):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    pts = [
        (x, y)
        for y in range(h)
        for x in range(w)
        if (lambda p: p[3] > 128 and p[0] < 90 and p[1] < 90 and p[2] < 90)(px[x, y])
    ]
    return w, h, pts


def measure(name):
    path = os.path.join(SIGNS, name)
    if not os.path.exists(path):
        return None
    w, h, pts = dark_glyph(path)
    if not pts:
        return None
    cx = lambda s: (sum(p[0] for p in s) / len(s)) if s else float("nan")
    top = [p for p in pts if p[1] < h / 3]
    bot = [p for p in pts if p[1] > 2 * h / 3]
    left = [p for p in pts if p[0] < w / 2]
    cxt, cxb = cx(top), cx(bot)
    bend = "LEFT" if cxt < cxb else "RIGHT"
    return {
        "size": (w, h),
        "n": len(pts),
        "cx_top": cxt,
        "cx_bot": cxb,
        "left_pct": 100.0 * len(left) / len(pts),
        "bend": bend,
        "mid": w / 2.0,
    }


def main():
    bad = 0
    for name, want in sorted(EXPECT.items()):
        m = measure(name)
        if m is None:
            print(f"?? {name}: missing or no dark glyph")
            bad += 1
            continue
        ok = m["bend"] == want
        bad += 0 if ok else 1
        print(
            f"{'OK ' if ok else 'FAIL'} {name:20s} "
            f"{m['size'][0]}x{m['size'][1]} glyph={m['n']:6d}px  "
            f"cx(top)={m['cx_top']:6.1f} cx(bot)={m['cx_bot']:6.1f} "
            f"(mid {m['mid']:.0f})  bends {m['bend']:5s} expected {want}"
        )
    # The two prohibition signs must be mirror images of each other; if they are
    # identical something went wrong in the asset pipeline.
    a, b = "no_left_turn.png", "no_right_turn.png"
    ia, ib = Image.open(os.path.join(SIGNS, a)).convert("RGBA"), Image.open(
        os.path.join(SIGNS, b)
    ).convert("RGBA")
    if ia.size == ib.size:
        flipped = ib.transpose(Image.FLIP_LEFT_RIGHT)
        same_as_mirror = list(ia.getdata()) == list(flipped.getdata())
        same_direct = list(ia.getdata()) == list(ib.getdata())
        print(
            f"mirror-pair check: {a} vs mirrored {b} -> "
            f"{'MIRROR (as expected)' if same_as_mirror else 'NOT a mirror'}"
            f"{'  ** IDENTICAL FILES **' if same_direct else ''}"
        )
    m = measure(EXPECT_UTURN)
    if m:
        print(
            f"info {EXPECT_UTURN:20s} glyph={m['n']:6d}px left-mass="
            f"{m['left_pct']:.1f}%  cx(top)={m['cx_top']:.1f} "
            f"cx(bot)={m['cx_bot']:.1f}"
        )
    print("RESULT:", "all sign artwork matches its filename" if not bad else f"{bad} mismatch(es)")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
