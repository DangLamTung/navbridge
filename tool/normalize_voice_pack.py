#!/usr/bin/env python3
"""Raise the shipped voice packs to a consistent LOUDNESS.

Why: the driver reported "the voice too small" (2026-10-08). The packs are what
the app actually plays for speed-limit announcements, and measured with ffmpeg
`volumedetect` over every clip they were NOT comparable:

    voice_thai_ngoc_bich    mean -15.8 dB   (the pre-2026 pack — loudest)
    voice_vn_fast           mean -18.2 dB
    voice_vn_gcp            mean -19.0 dB
    voice_vn_hanoi_quyphai  mean -19.7 dB   (the shipped default — quietest)

so switching to the cloned pack made the guidance measurably quieter, on top of
a TTS volume already at its maximum (`voiceVolume` 1.0). A plain gain is not
available: the loudest clip already peaks at -0.4 dB, so any linear boost clips.
`speechnorm` (a speech-dynamics normaliser) raises the average instead of the
peaks — measured +3.6 dB on `current_speed_50.mp3`, peak -0.9 dB, no clipping.

Usage:  python3 tool/normalize_voice_pack.py [--apply] [pack ...]
        (dry run by default — prints the before/after for each pack)
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(os.path.dirname(HERE), 'assets', 'audio')

# The filter that was measured to win on this material (+3.6 dB mean, peak
# -0.9 dB). `l` = 1 keeps the normalisation on (auto-level across the clip).
FILTER = 'speechnorm=e=12.5:r=0.0001:l=1'
BITRATE = '96k'


def volume(path: str) -> tuple[float, float] | None:
    out = subprocess.run(
        ['ffmpeg', '-hide_banner', '-i', path, '-af', 'volumedetect', '-f', 'null', '-'],
        capture_output=True, text=True).stderr
    m = re.search(r'mean_volume: (-?[\d.]+)', out)
    p = re.search(r'max_volume: (-?[\d.]+)', out)
    if not m or not p:
        return None
    return float(m.group(1)), float(p.group(1))


def report(pack_dir: str) -> tuple[float, float, int]:
    means, peaks = [], []
    for f in sorted(glob.glob(os.path.join(pack_dir, '*.mp3'))):
        v = volume(f)
        if v:
            means.append(v[0])
            peaks.append(v[1])
    if not means:
        return 0.0, 0.0, 0
    return statistics.mean(means), max(peaks), len(means)


def process(pack: str, apply: bool) -> None:
    pack_dir = os.path.join(AUDIO, pack)
    if not os.path.isdir(pack_dir):
        print('  %-26s MISSING' % pack)
        return
    before = report(pack_dir)
    print('  %-26s n=%3d mean=%6.1f dB peak=%5.1f dB' % (pack, before[2],
                                                         before[0], before[1]))
    if not apply:
        return
    files = sorted(glob.glob(os.path.join(pack_dir, '*.mp3')))
    with tempfile.TemporaryDirectory() as tmp:
        for f in files:
            dst = os.path.join(tmp, os.path.basename(f))
            r = subprocess.run(
                ['ffmpeg', '-hide_banner', '-y', '-i', f, '-af', FILTER,
                 '-c:a', 'libmp3lame', '-b:a', BITRATE, dst],
                capture_output=True, text=True)
            if r.returncode != 0 or not os.path.exists(dst):
                print('    FAILED %s: %s' % (os.path.basename(f),
                                             r.stderr.strip()[-200:]))
                return
        # Swap only after EVERY clip rendered, so a failure cannot leave a
        # half-normalised pack on disk (the app plays whichever files exist).
        for f in files:
            shutil.move(os.path.join(tmp, os.path.basename(f)), f)
    after = report(pack_dir)
    print('  %-26s n=%3d mean=%6.1f dB peak=%5.1f dB  (%+.1f dB)' % (
        pack + ' AFTER', after[2], after[0], after[1], after[0] - before[0]))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true',
                    help='rewrite the clips (default: measure only)')
    ap.add_argument('packs', nargs='*', default=None)
    a = ap.parse_args()
    packs = a.packs or ['voice_vn_hanoi_quyphai', 'voice_vn_fast',
                        'voice_vn_gcp', 'voice_thai_ngoc_bich']
    print('filter: %s' % FILTER)
    for p in packs:
        process(p, a.apply)
    if not a.apply:
        print('\n(dry run — pass --apply to rewrite)')


if __name__ == '__main__':
    sys.exit(main())
