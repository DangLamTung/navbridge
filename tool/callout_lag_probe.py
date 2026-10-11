#!/usr/bin/env python3
"""Is a callout mismatch a REAL wrong name, or a log-timing artifact?

`check_voice_calls.py` compares the street named in "Đi trên X" against the
FIRST GPS fix at or after the sentence. GPS fixes are ~1 Hz, so at an
intersection the car can cross onto the new street BETWEEN the callout and that
fix, which makes a CORRECT callout look wrong.

This prints the street at the fix BEFORE, AT and AFTER each mismatch and
classifies it:

  ARTIFACT — the announced name is the street at the fix BEFORE the callout.
             The callout was right; the comparison fix was too late.
  NEXT     — the announced name is the street at the fix AFTER. The callout
             named the road ahead instead of the one under the car — a real
             defect (the "Đi trên" clause must name the current road).
  REAL     — neither. A genuinely wrong name.

Run:  python3 tool/callout_lag_probe.py [docs/trips/device]
"""

import bisect
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_voice_calls import load, norm  # noqa: E402

ON_RX = re.compile(r'Đi trên ([^,]+),')


def _match(said, other):
    if not said or not other:
        return False
    return said == other or said in other or other in said


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'docs/trips/device'
    paths = sorted(glob.glob(os.path.join(root, '*.json')))
    if not paths:
        raise SystemExit(f'no trips in {root}')

    tally = {'ARTIFACT': 0, 'NEXT': 0, 'REAL': 0}
    for path in paths:
        fixes, anns = load(path)
        if not fixes or not anns:
            continue
        times = [f['ms'] for f in fixes]
        for a in anns:
            if (a.get('kind') or '') != 'maneuver':
                continue
            m = ON_RX.search(a.get('text') or '')
            if not m:
                continue
            ms = int(a.get('timestampMs', 0) or 0)
            i = bisect.bisect_left(times, ms)
            if i >= len(fixes):
                continue
            said = norm(m.group(1))
            actual = norm(fixes[i].get('street') or '')
            if _match(said, actual):
                continue
            before = fixes[i - 1].get('street') if i > 0 else None
            after = (fixes[i + 1].get('street')
                     if i + 1 < len(fixes) else None)
            b, af = norm(before or ''), norm(after or '')
            if _match(said, b):
                kind = 'ARTIFACT'
            elif _match(said, af):
                kind = 'NEXT'
            else:
                kind = 'REAL'
            tally[kind] += 1
            print(f'{kind:8} said={m.group(1)[:30]:32} '
                  f'before={b[:22]:24} at={actual[:22]:24} after={af[:22]:24} '
                  f'{os.path.basename(path)[:18]}')

    print()
    print(f'ARTIFACT (announced == the fix BEFORE) : {tally["ARTIFACT"]}')
    print(f'NEXT     (announced == the fix AFTER)  : {tally["NEXT"]}')
    print(f'REAL     (neither)                     : {tally["REAL"]}')


if __name__ == '__main__':
    main()
