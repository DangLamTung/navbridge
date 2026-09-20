#!/usr/bin/env python3
"""Grade EVERY recorded trip against the Waze-segment ground truth.

One process, one parse of the 27 MB segment layer, then every trip in
`docs/trips/device/` is replayed through three rules and counted:

  app today      — the build that recorded these drives (sign applied up to
                   400 m early, road frozen at adoption)
  app with fix   — `signLimitInForce`: reached + same road, road bound when known
  ground truth   — the segment under the car, vehicle-capped

This is the widest coverage the app-behaviour test can have: it needs a
TRAJECTORY, so it covers every drive ever recorded rather than every segment.
(The data-level "all segments" question — does a sign point agree with the
segment under it — is `tool/compare_speed_sources.py`, which already runs over
all 1,031,546 segments + all 20,753 sign points nationwide.)

Usage
    python3 tool/grade_all_trips.py [--dir docs/trips/device] [--max 40]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402
from waze_segments import Segments  # noqa: E402

A = 'assets/offline_map/'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', default='docs/trips/device')
    ap.add_argument('--vehicle', default='motorbike')
    ap.add_argument('--max-fixes', type=int, default=4000,
                    help='skip absurd logs')
    ap.add_argument('--skip-emulator', action='store_true', default=True)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, '*.json')))
    if args.skip_emulator:
        files = [f for f in files if 'emulator' not in os.path.basename(f)]
    if not files:
        print(f'no trips in {args.dir}')
        return 2

    t0 = time.time()
    segs = Segments(A + 'waze_segments.bin', verbose=True)
    print(f'parsed in {time.time() - t0:.0f}s — grading {len(files)} trips\n')
    print(f'{"trip":<44}{"fixes":>6}{"seg%":>6}{"app→GT":>9}{"fixed→GT":>10}'
          f'{"ann(app)":>10}{"ann(fixed)":>11}{"ann(GT)":>8}')

    tot = {'fixes': 0, 'app': 0, 'fixed': 0, 'ann_app': 0, 'ann_fixed': 0,
           'ann_gt': 0, 'seghit': 0, 'agree_log': 0, 'log_val': 0}
    per_trip = []
    for path in files:
        try:
            truth = T.build(path, A + 'vietnam_signs.json', args.vehicle,
                            A + 'waze_segments.bin',
                            A + 'waze_speed_limits.json',
                            A + 'vietmap_speed_limits.json',
                            verbose=False, segs=segs)
        except Exception as e:  # noqa: BLE001
            print(f'{os.path.basename(path):<44}  SKIP ({e})')
            continue
        v = truth['validation']
        n = v['fixes']
        if n == 0 or n > args.max_fixes:
            continue
        app = v['app_vs_ground_truth_diff']
        fixed = v['app_fixed_vs_ground_truth_diff']
        ann_app = _events(truth, 'app_limit')
        ann_fixed = _events(truth, 'app_fixed_limit')
        ann_gt = len(truth['limit_events'])
        print(f'{os.path.basename(path)[:43]:<44}{n:>6}'
              f'{100 * v["segment_hits"] / n:>5.0f}%{app:>9}{fixed:>10}'
              f'{ann_app:>10}{ann_fixed:>11}{ann_gt:>8}')
        tot['fixes'] += n
        tot['app'] += app
        tot['fixed'] += fixed
        tot['ann_app'] += ann_app
        tot['ann_fixed'] += ann_fixed
        tot['ann_gt'] += ann_gt
        tot['seghit'] += v['segment_hits']
        tot['agree_log'] += v['matches_reference_logged_limit']
        tot['log_val'] += sum(1 for f in truth['fixes'] if f['road_limit'])
        per_trip.append((os.path.basename(path), n, app, fixed))

    if not tot['fixes']:
        print('nothing graded')
        return 2
    n = tot['fixes']
    print(f'\n=== {len(per_trip)} trips, {n} fixes ===')
    print(f'  segment ground truth available : {100 * tot["seghit"] / n:.1f}% of fixes')
    lv = max(1, tot['log_val'])
    print(f'  offline lookup reproduces the app\'s OWN logged road value on '
          f'{tot["agree_log"]}/{tot["log_val"]} fixes '
          f'({100 * tot["agree_log"] / lv:.1f}%) ← the floor: those are pure '
          f'lookup disagreements, not app bugs')
    print(f'  app TODAY   wrong vs ground truth : {tot["app"]:>6} '
          f'({100 * tot["app"] / n:.1f}%)')
    print(f'  app WITH FIX wrong vs ground truth : {tot["fixed"]:>6} '
          f'({100 * tot["fixed"] / n:.1f}%)')
    print(f'  limit announcements: app today {tot["ann_app"]}, '
          f'with the fix {tot["ann_fixed"]}, ground truth {tot["ann_gt"]}')
    worst = sorted(per_trip, key=lambda r: -r[3])[:6]
    print('\n  trips the fix still cannot reconcile (top 6):')
    for name, nf, app, fixed in worst:
        print(f'    {name[:44]:<46}{nf:>5} fixes  app {app} → fixed {fixed}')
    return 0


def _events(truth, key):
    """Count expected-announcement events on a given per-fix limit trace."""
    stable = cooldown = None
    last_spoken = pending = pending_since = None
    n = 0
    for f in truth['fixes']:
        limit = f.get(key) or 0
        if limit <= 0:
            continue
        t_s = f['tMs'] / 1000.0
        if limit == last_spoken:
            pending = pending_since = None
        elif limit != pending:
            pending, pending_since = limit, t_s
        elif (pending_since is not None and t_s - pending_since >= 2.0
              and (stable is None or t_s - stable >= 4.0)):
            stable, last_spoken = t_s, limit
            pending = pending_since = None
            n += 1
    _ = cooldown
    return n


if __name__ == '__main__':
    sys.exit(main())
