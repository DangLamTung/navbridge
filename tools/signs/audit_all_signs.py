#!/usr/bin/env python3
"""Audit EVERY bundled sign PNG in assets/offline_map/signs/.

For each image it measures the structure a QCVN 41 sign must have and flags
anything anomalous:

  * red ring present (the sign is a red-bordered disc)
  * black/pictogram mass (the glyph) and how far its centroid sits from the
    disc centre — a glyph pushed to one side means mis-cropped artwork
  * red pixels INSIDE the disc (excluding the ring) and their x/y correlation:
    on a prohibition sign that is the diagonal SLASH (corr ~ +/-1). A
    prohibition sign with no slash reads as the opposite meaning.

Expectation rules
-----------------
* `no_*turn*.png` and `no_passing.png` and `end_prohibitions.png` are P.12x
  prohibition-family signs: if they are drawn as a disc they should carry a
  slash (the "Hết" signs and some others legitimately do not, so a missing
  slash is reported as a NOTE, and a MISSING slash on `no_left/right/u_turn`
  as a FAIL).
* Any sign with no pictogram at all is a FAIL.

Run:  python3 tools/signs/audit_all_signs.py
Exit code is non-zero when any FAIL is reported.
"""
import math
import os
import sys

from PIL import Image

SIGNS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "assets", "offline_map", "signs",
)

# Signs that are unambiguously prohibition signs (must have the red slash).
MUST_HAVE_SLASH = ("no_left_turn.png", "no_right_turn.png", "no_u_turn.png")


def is_dark(p):
    return p[3] > 128 and p[0] < 90 and p[1] < 90 and p[2] < 90


def is_red(p):
    return p[3] > 128 and p[0] > 150 and p[1] < 100 and p[2] < 100


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


def audit(path):
    im = Image.open(path).convert('RGBA')
    w, h = im.size
    px = im.load()
    cx, cy = w / 2.0, h / 2.0
    rmax, red_total, dark = 0.0, 0, []
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            r = math.hypot(x - cx, y - cy)
            if is_red(p):
                red_total += 1
                if r > rmax:
                    rmax = r
            elif is_dark(p):
                dark.append((x, y))
    res = {
        "size": f"{w}x{h}", "rmax": rmax, "red_total": red_total,
        "dark_n": len(dark), "off_pct": float('nan'), "corr": float('nan'),
        "inner_red": 0,
    }
    if dark:
        gx = sum(p[0] for p in dark) / len(dark)
        gy = sum(p[1] for p in dark) / len(dark)
        off = math.hypot(gx - cx, gy - cy)
        res["off_pct"] = 100 * off / rmax if rmax else float('nan')
    if rmax:
        inner = rmax * 0.72
        red_in = [
            (x, y)
            for y in range(h)
            for x in range(w)
            if math.hypot(x - cx, y - cy) < inner and is_red(px[x, y])
        ]
        res["inner_red"] = len(red_in)
        res["corr"] = corr(red_in)
    return res


def main():
    names = sorted(f for f in os.listdir(SIGNS) if f.lower().endswith('.png'))
    print(f"Auditing {len(names)} sign PNGs in {os.path.relpath(SIGNS)}\n")
    hdr = (f"{'file':<24}{'size':>9}{'ring':>6}{'glyph':>7}{'off%':>7}"
           f"{'slashpx':>9}{'corr':>7}  flags")
    print(hdr)
    print('-' * len(hdr))
    fails, notes = [], []
    for n in names:
        a = audit(os.path.join(SIGNS, n))
        flags = []
        if a["red_total"] == 0:
            flags.append("NO-RED-RING")
        if a["dark_n"] == 0:
            flags.append("NO-GLYPH")
        elif a["off_pct"] > 35:
            flags.append(f"GLYPH-OFF-CENTRE({a['off_pct']:.0f}%)")
        slash_ok = a["inner_red"] > 200 and abs(a["corr"]) > 0.5
        if n in MUST_HAVE_SLASH and not slash_ok:
            flags.append("NO-SLASH")
        elif n not in MUST_HAVE_SLASH and abs(a["corr"]) > 0.5 and a["inner_red"] > 800:
            flags.append("unexpected-slash?")
        if n not in MUST_HAVE_SLASH and a["dark_n"] < 400:
            flags.append("LOW-GLYPH?")
        print(f"{n:<24}{a['size']:>9}{a['red_total']:>6}{a['dark_n']:>7}"
              f"{a['off_pct']:>7.0f}{a['inner_red']:>9}{a['corr']:>7.2f}  "
              f"{' '.join(flags) if flags else 'ok'}")
        hard = [f for f in flags if f.split('(')[0] in
                ("NO-RED-RING", "NO-GLYPH", "NO-SLASH")]
        hard += [f for f in flags if f.startswith("GLYPH-OFF-CENTRE")]
        (fails if hard else notes).extend(f"{n}: {f}" for f in hard)
        notes.extend(f"{n}: {f}" for f in flags if f not in hard)

    print()
    if fails:
        print("FAILURES:")
        for f in fails:
            print("  -", f)
    if notes:
        print("NOTES (review, not necessarily wrong):")
        for f in notes:
            print("  -", f)
    print()
    print("RESULT:", "all sign artwork is structurally sound"
          if not fails else f"{len(fails)} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
