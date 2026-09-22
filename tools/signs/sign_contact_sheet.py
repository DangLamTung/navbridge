#!/usr/bin/env python3
"""Lay every bundled sign PNG out in ONE labelled sheet, big, for eyeballing.

Why this exists: `audit_all_signs.py` measures GEOMETRY (red ring, slash, glyph
mass) and therefore cannot tell you that an image is the WRONG SIGN. Two assets
were structurally fine while depicting something else entirely:

  * `stop.png` — a PHOTO of P.102 "CẤM ĐI NGƯỢC CHIỀU" (no entry), watermarked
    "ThietBiBaoHoLaoDong.Net", in the STOP slot (the STOP sign is P.101);
  * `no_u_turn.png` — the CẤM VƯỢT sign (two cars), so "cấm quay đầu" rendered
    as a no-overtaking sign;
  * `end_prohibitions.png` — P.135 "hết cấm vượt", not P.133 "hết mọi lệnh cấm".

All three passed the geometry audit, and inspecting the PNGs one at a time does
not work well (small images come back as "no text detected"). Side by side, big,
with captions, is what caught them — so it is a tool now.

Usage:
    python3 tools/signs/sign_contact_sheet.py [--out build/sim/sign_sheet.png]
                                              [--cell 400]

The caption for each file is the sign kind the app maps it to, read from
lib/ui/sign_icons.dart — a file that is bundled but NOT mapped is reported as
UNUSED, because an unused asset is one that can be re-mapped by accident.
"""
import argparse
import os
import re

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIGNS = os.path.join(ROOT, "assets", "offline_map", "signs")
ICONS = os.path.join(ROOT, "lib", "ui", "sign_icons.dart")


def mapped_assets():
    """{filename: kind} parsed from the assetFor() switch."""
    src = open(ICONS, encoding="utf-8").read()
    m = re.search(r"assetFor\(RoadSignKind kind\) => switch \(kind\) \{(.*?)\n  \};", src, re.S)
    out = {}
    if not m:
        return out
    for kind, path in re.findall(r"RoadSignKind\.(\w+) => '\$_assetDir/([^']+)'", m.group(1)):
        out[path] = kind
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "sim", "sign_sheet.png"))
    ap.add_argument("--cell", type=int, default=400)
    args = ap.parse_args()

    mapped = mapped_assets()
    files = sorted(f for f in os.listdir(SIGNS) if f.lower().endswith(".png"))
    if not files:
        raise SystemExit(f"no PNGs in {SIGNS}")

    cols = 2
    rows = (len(files) + cols - 1) // cols
    cell, pad, label_h = args.cell, 16, 30
    sheet = Image.new(
        "RGB", (cols * (cell + pad) + pad, rows * (cell + label_h + pad) + pad), (240, 240, 240)
    )
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.load_default(size=20)
    except TypeError:
        font = ImageFont.load_default()

    for i, name in enumerate(files):
        cx = pad + (i % cols) * (cell + pad)
        cy = pad + (i // cols) * (cell + label_h + pad)
        draw.rectangle([cx, cy, cx + cell, cy + cell], fill=(255, 255, 255))
        im = Image.open(os.path.join(SIGNS, name)).convert("RGBA")
        im.thumbnail((cell - 16, cell - 16))
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, im).convert("RGB")
        sheet.paste(im, (cx + (cell - im.width) // 2, cy + (cell - im.height) // 2))
        kind = mapped.get(name)
        caption = f"{name}  ->  {kind}" if kind else f"{name}  ->  UNUSED"
        draw.text((cx + 4, cy + cell + 4), caption, font=font, fill=(10, 10, 10))
        print(f"{name:<24} {im.width:>4}x{im.height:<4} -> {kind or 'UNUSED — remove or map it'}")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    sheet.save(args.out)
    print("sheet ->", args.out)


if __name__ == "__main__":
    main()
