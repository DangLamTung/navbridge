#!/usr/bin/env python3
"""Build the FASTEST Vietnamese voice pack for NavBridge from the Waze mod APKs.

The Waze mod ships FOUR Vietnamese speed-limit voice packs inside
`assets/voice*` (verified 2026-09-14):

    pack                  clips  total length
    voice_thai_ngoc_bich    28     119.1 s   <- what navbridge shipped
    voice                   28     111.6 s
    voice_waze              26      98.0 s
    voice_short             26      96.1 s   <- fastest overall

Per phrase the ranking is not uniform — `voice_short` wins most
`current_speed_*` / `next_speed_*` clips, but `voice_waze` wins
`over_speed_limit` (1.63 s vs 2.74 s shipped, 40% shorter) and the bare
`next_speed` warning (1.80 s vs 2.23 s). So this tool picks the SHORTEST clip
for every phrase and writes a merged pack.

Result: 26 common clips go from 110.0 s to 94.4 s of speech (~14% less), and
the overspeed warning — the one that fires while driving — drops 40%.

Usage:
    python3 tools/build_voice_pack_vn.py                     # both mod APKs
    python3 tools/build_voice_pack_vn.py --apk <path.apk>
    python3 tools/build_voice_pack_vn.py --dry-run           # just print the table
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CRAWL = '/Users/tungdl/Documents/Eink/Decode_Waze'
OUT_DIR = os.path.join(REPO, 'assets/audio/voice_vn_fast')

# MPEG audio frame tables (Layer III). Index 0 = "free", 15 = invalid.
BITRATE_V1_L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
BITRATE_V2_L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
SAMPLE_RATE = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def mp3_seconds(path: str) -> float:
    """Exact duration by walking MPEG audio frames (handles CBR and VBR)."""
    data = open(path, 'rb').read()
    i = 0
    # skip an ID3v2 tag if present
    if data[:3] == b'ID3' and len(data) > 10:
        i = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 |
                  (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
    total = 0.0
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0:
            i += 1
            continue
        h = struct.unpack('>I', data[i:i + 4])[0]
        ver = (h >> 19) & 0x3          # 3=MPEG1, 2=MPEG2, 0=MPEG2.5
        layer = (h >> 17) & 0x3        # 1=Layer III
        brx = (h >> 12) & 0xF
        srx = (h >> 10) & 0x3
        pad = (h >> 9) & 0x1
        if ver == 1 or layer != 1 or brx in (0, 15) or srx == 3:
            i += 1
            continue
        is_v1 = (ver == 3)
        br = (BITRATE_V1_L3 if is_v1 else BITRATE_V2_L3)[brx] * 1000
        sr = SAMPLE_RATE[ver][srx]
        if br == 0:
            i += 1
            continue
        flen = (144 if is_v1 else 72) * br // sr + pad
        if flen <= 4:
            i += 4
            continue
        total += (1152 if is_v1 else 576) / sr
        i += flen
    return total


def find_packs(apks: list[str]) -> dict[str, str]:
    """Extract `assets/voice*` from each APK into a temp dir."""
    work = tempfile.mkdtemp(prefix='nbvoice')
    packs: dict[str, str] = {}
    for apk in apks:
        if not os.path.exists(apk):
            continue
        tag = os.path.basename(apk).split('_release_')[0].replace('Waze_Mod_', 'm')
        dest = os.path.join(work, tag)
        os.makedirs(dest, exist_ok=True)
        r = subprocess.run(['unzip', '-o', '-q', apk, 'assets/voice*', '-d', dest],
                           capture_output=True)
        if r.returncode != 0:
            continue
        base = os.path.join(dest, 'assets')
        if not os.path.isdir(base):
            continue
        for d in sorted(os.listdir(base)):
            p = os.path.join(base, d)
            if os.path.isdir(p) and glob.glob(os.path.join(p, '*.mp3')):
                packs['%s/%s' % (tag, d)] = p
    return packs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--apk', action='append',
                    help='Waze mod APK to mine (repeatable). Default: every '
                         'Decode_Waze/Waze_Mod_*.apk')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    apks = args.apk or sorted(glob.glob(os.path.join(CRAWL, 'Waze_Mod_*.apk')))
    if not apks:
        print('no mod APKs found under %s' % CRAWL, file=sys.stderr)
        return 1
    packs = find_packs(apks)
    if not packs:
        print('no voice packs found inside the APKs', file=sys.stderr)
        return 1

    # clip -> {pack: (seconds, path)}
    clips: dict[str, dict[str, tuple[float, str]]] = {}
    for name, path in packs.items():
        for f in sorted(glob.glob(os.path.join(path, '*.mp3'))):
            clip = os.path.basename(f)[:-4]
            clips.setdefault(clip, {})[name] = (mp3_seconds(f), f)

    names = sorted(packs)
    print('source packs:')
    for n in names:
        tot = sum(clips[c][n][0] for c in clips if n in clips[c])
        cnt = sum(1 for c in clips if n in clips[c])
        print('  %-34s %2d clips  %7.1f s' % (n, cnt, tot))
    print()

    chosen: dict[str, tuple[float, str, str]] = {}
    for clip, sources in clips.items():
        best = min(sources.items(), key=lambda kv: kv[1][0])
        chosen[clip] = (best[1][0], best[1][1], best[0])

    print('%-24s %-22s %-22s' % ('clip', 'chosen source', 'length'))
    for clip in sorted(chosen):
        secs, _, src = chosen[clip]
        print('  %-22s %-22s %6.2f s' % (clip, src, secs))

    old_total = sum(clips[c]['m10/voice_thai_ngoc_bich'][0]
                    for c in clips if 'm10/voice_thai_ngoc_bich' in clips[c])
    new_total = sum(v[0] for v in chosen.values())
    print()
    print('total speech: %.1f s (shipped thai_ngoc_bich)  ->  %.1f s (merged)  =  %.0f%% shorter'
          % (old_total, new_total, 100 * (1 - new_total / old_total)))

    if args.dry_run:
        print('\n--dry-run: nothing written')
        return 0

    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {}
    for clip, (secs, src_path, src_pack) in sorted(chosen.items()):
        dst = os.path.join(OUT_DIR, clip + '.mp3')
        shutil.copyfile(src_path, dst)
        manifest[clip + '.mp3'] = {
            'source': src_pack,
            'seconds': round(secs, 3),
            'size': os.path.getsize(dst),
        }
    with open(os.path.join(OUT_DIR, 'MANIFEST.json'), 'w', encoding='utf-8') as f:
        json.dump({
            'note': 'Fastest Vietnamese clip per phrase, merged from the Waze '
                    'mod voice packs by tools/build_voice_pack_vn.py',
            'clips': manifest,
        }, f, ensure_ascii=False, indent=1)

    total_mb = sum(v['size'] for v in manifest.values()) / 1e6
    print('\nwrote %d clips to %s (%.2f MB)'
          % (len(manifest), os.path.relpath(OUT_DIR, REPO), total_mb))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
