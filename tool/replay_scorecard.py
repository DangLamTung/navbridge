#!/usr/bin/env python3
"""Score emulator replays against the recorded drive AND against the Waze truth.

Two mistakes this tool exists to avoid:

1. Comparing builds over different stretches of the drive. Each replay covers a
   different fix range, so raw "86% match" numbers are not comparable — this
   tool restricts every build to the recorded fixes they ALL cover.
2. Treating the recorded drive as ground truth for the LIMIT. It is not: the
   recording came from a build whose chain was broken (e.g. Lũy Bán Bích showed
   50 on a street Waze posts 60 on for its whole length). For every fix this
   tool also asks the Waze layer itself what is posted there, so a disagreement
   can be attributed: did the build fix a wrong recording, or break a right one?

    python3 tool/replay_scorecard.py REAL.json SIM1.json SIM2.json ...
"""

from __future__ import annotations

import json
import math
import sys
from collections import Counter

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from waze_segments import Segments  # noqa: E402

M = 111_320.0
SEG_BIN = __file__.rsplit('/', 2)[0] + '/assets/offline_map/waze_segments.bin'


def ll(f: dict) -> tuple[float, float]:
    return f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7


def meters(a, b) -> float:
    return math.hypot((a[0] - b[0]) * M,
                      (a[1] - b[1]) * M * math.cos(math.radians(a[0])))


def load(p: str) -> list[dict]:
    with open(p, encoding='utf-8') as fh:
        return json.load(fh)['locations']


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    real = load(sys.argv[1])
    sims = [(p.split('/')[-1][:22], load(p)) for p in sys.argv[2:]]
    rp = [ll(f) for f in real]
    seg = Segments(SEG_BIN)

    # Each replay fix → the recorded fix it was driven from (nearest point).
    maps = []
    for name, fixes in sims:
        m = {}
        for f in fixes:
            q = ll(f)
            d, i = min(((meters(q, p), k) for k, p in enumerate(rp)))
            if d <= 15:
                m[i] = f
        maps.append((name, m))
    shared = sorted(set.intersection(*(set(m) for _, m in maps))) if maps else []
    print(f'recorded drive {sys.argv[1].split("/")[-1]}  ({len(real)} fixes)')
    for name, m in maps:
        print(f'  {name:24} {len(m):>4} fixes, {len(shared):>4} of them shared')
    print()

    # Waze truth per recorded fix (heading matters on per-direction segments).
    truth = {}
    for i in shared:
        f = real[i]
        lat, lng = ll(f)
        val = seg.query(lat, lng, heading_deg=f.get('heading') or None)[0]
        truth[i] = val or None

    hdr = (f'{"build":24} {"n":>4} {"street=":>8} {"agree":>6} {"fixed":>6} '
           f'{"broke":>6} {"layer%":>7} {"truth%":>7}')
    print(hdr)
    print('-' * len(hdr))
    for name, m in maps:
        n = agree = fixed = broke = layer_ok = truth_ok = street_ok = 0
        diffs = Counter()
        for i in shared:
            r, s = real[i], m[i]
            rl, sl = r.get('limitEffective'), s.get('limitEffective')
            t = truth[i]
            n += 1
            if (r.get('street') or '') == (s.get('street') or ''):
                street_ok += 1
            if rl == sl:
                agree += 1
            elif t is not None and sl == t:
                fixed += 1
                diffs[f'{r.get("limitEffective")} -> {sl} (truth {t})'] += 1
            elif t is not None and rl == t:
                broke += 1
                diffs[f'BROKE {rl} -> {sl} (truth {t})'] += 1
            if t is not None:
                if sl == t:
                    truth_ok += 1
                if rl == t:
                    layer_ok += 1
        with_t = sum(1 for i in shared if truth[i] is not None)
        print(f'{name:24} {n:>4} {100*street_ok/max(1,n):>7.1f}% {agree:>6} '
              f'{fixed:>6} {broke:>6} '
              f'{100*layer_ok/max(1,with_t):>6.1f}% {100*truth_ok/max(1,with_t):>6.1f}%')
        if diffs:
            for k, v in diffs.most_common(8):
                print(f'      {v:>3}  {k}')
    print('\n  "fixed"  = the recording was wrong there and this build shows the '
          'Waze value\n  "broke"  = the recording was right and this build does '
          'not\n  "street=" = the street name matches the recording\n  '
          '"truth%" = fixes showing exactly the Waze posted value '
          '(recording vs build)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
