#!/usr/bin/env python3
"""End-to-end functional test: replay a RECORDED drive into the Android emulator
as real GNSS fixes and check what the app actually does against the offline
"correct dataset" built by `tool/trip_truth.py`.

Why this exists: unit tests cover the pieces, and the web bench re-reads the
logs, but neither exercises the shipping APK — asset loading, the scan isolate,
the road-info lookup, the sign/limit/voice pipeline and the trip logger on a
real Android device, driven by a real GNSS stream at the recorded cadence.

The rig:
  1. installs an APK built with `--dart-define=AUTO_ROUTE=<trip end>` so the app
     plans the route to the same destination the driver used and starts
     navigation with no UI automation;
  2. seeds the emulator's GPS at the trip's first fix, then replays every fix
     through the emulator console (`geo fix <lng> <lat> 0 8 <knots>`) at the
     recorded pace, speed included;
  3. waits for the app to finish the drive, pulls the trip log IT recorded, and
     diffs its per-fix effective limit + limit announcements against the truth.

STATUS: the in-app `AUTO_ROUTE` hook was REMOVED at the user's request
(2026-09-20, `lib/pages/navigation/modules/nav_autoroute.dart` deleted), so step
1 no longer exists — a live run now stops after "navigation never started".
`--device-trip <log.json>` (offline diff) is unaffected and is the way to grade
a drive that was recorded by hand. To run the full rig again, re-add a define
that plans a route and presses Go (see git history for the deleted file).

Usage
    python3 tool/emulator_trip_test.py \
        --trip "docs/trips/device/2026-09-18_172234_Chuyến_đi.json" \
        --apk build/app/outputs/flutter-apk/app-release.apk \
        --to-m 1200 --speed 6 --install

Exit code 0 = the device matched the dataset, 1 = it did not, 2 = rig error.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emulator_gps_replay import load_fixes, meters_between  # noqa: E402

PKG = 'com.navbridge.app'
TRIPS_DIR = f'/data/data/{PKG}/app_flutter/trips'


def adb(serial, *args, timeout=120.0, binary=False):
    cmd = ['adb']
    if serial:
        cmd += ['-s', serial]
    cmd += list(args)
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    return r.stdout if binary else r.stdout.decode('utf-8', 'replace')


def shell(serial, *args, **kw):
    return adb(serial, 'shell', *args, **kw)


def logcat(serial, since_clear=True):
    return adb(serial, 'logcat', '-d')


def geo_fix(serial, lat, lng, knots=0.0):
    adb(serial, 'emu', 'geo', 'fix', f'{lng:.7f}', f'{lat:.7f}', '0', '8',
        f'{knots:.3f}', timeout=30)


def truth_path_for(trip_path: str, docs='docs') -> str:
    stem = os.path.splitext(os.path.basename(trip_path))[0]
    return os.path.join(docs, f'trip_truth_{stem}.json')


def load_truth(trip_path: str, docs='docs'):
    p = truth_path_for(trip_path, docs)
    if not os.path.exists(p):
        print(f'! no truth dataset at {p} — run tool/trip_truth.py first')
        return None
    with open(p, encoding='utf-8') as fh:
        return json.load(fh)


def wait_for_log(serial, needle, timeout_s, from_ts=None):
    """Poll logcat until [needle] appears. Returns the line or None."""
    end = time.time() + timeout_s
    while time.time() < end:
        out = logcat(serial)
        for line in out.splitlines():
            if needle in line:
                return line
        time.sleep(2)
    return None


def pull_newest_trip(serial, before: set[str]):
    out = shell(serial, f'ls {TRIPS_DIR}').split()
    new = [f for f in out if f.endswith('.json') and f not in before]
    if not new:
        return None, None
    # The app may still be writing; take the last modified one.
    newest = shell(serial, f'ls -t {TRIPS_DIR}').split()
    for f in newest:
        if f in new:
            raw = adb(serial, 'exec-out', f'cat {TRIPS_DIR}/{f}', binary=True)
            return f, raw.decode('utf-8', 'replace')
    return None, None


def nearest_truth_fix(truth_fixes, lat, lng):
    """Nearest dataset fix to a point (used only by the legacy path)."""
    best, best_d = None, float('inf')
    for f in truth_fixes:
        d = math.hypot((f['lat'] - lat) * 111320,
                       (f['lng'] - lng) * 111320 * math.cos(math.radians(lat)))
        if d < best_d:
            best, best_d = f, d
    return best, best_d


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--trip', required=True)
    ap.add_argument('--apk', default='build/app/outputs/flutter-apk/app-release.apk')
    ap.add_argument('--serial', default=None)
    ap.add_argument('--speed', type=float, default=1.0,
                    help='replay rate. Keep 1.0: the app samples the GNSS\n'
                         'stream at 1 Hz, so a faster replay makes the drive\n'
                         'look faster than it was (spurious overspeed alerts)')
    ap.add_argument('--from-m', type=float, default=0.0)
    ap.add_argument('--to-m', type=float, default=None)
    ap.add_argument('--install', action='store_true')
    ap.add_argument('--device-trip', default=None,
                    help='compare an ALREADY-pulled trip log instead of '
                         'replaying (skips install/launch/replay)')
    ap.add_argument('--timeout-s', type=float, default=90.0,
                    help='how long to wait for navigation to start')
    ap.add_argument('--settle-s', type=float, default=12.0,
                    help='wait after the replay ends before reading the log')
    ap.add_argument('--align-m', type=float, default=60.0,
                    help='a device fix must be within this of its dataset fix '
                         'to be compared at all')
    ap.add_argument('--keep-trips', action='store_true',
                    help='do not delete previously recorded trips')
    args = ap.parse_args()

    serial = args.serial
    if not args.device_trip and not serial:
        devs = [l.split()[0] for l in adb(None, 'devices').splitlines()[1:]
                if l.strip().endswith('device')]
        if not devs:
            print('! no adb device — start an emulator first')
            return 2
        serial = devs[0]
    if serial:
        print(f'device           : {serial}')

    truth = load_truth(args.trip)
    if truth is None:
        return 2
    print(f'trip             : {truth["trip"]}')
    print(f'truth dataset    : {truth["fix_count"]} fixes, {truth["km"]} km, '
          f'{len(truth["limit_events"])} expected limit announcements')
    gt = truth.get('ground_truth', {})
    val = truth.get('validation', {})
    print(f'  ground truth   : {gt.get("layer", "?")} — '
          f'nearest segment within 25 m, fwd/rev by heading, vehicle-capped')
    print(f'  parser check   : reproduces the reference run\'s logged limit on '
          f'{val.get("matches_reference_logged_limit", "?")}/'
          f'{val.get("fixes", "?")} fixes '
          f'({100 * val.get("matches_reference_logged_limit_share", 0):.1f}%)')

    # --- offline mode: compare a trip log that was already pulled ----------
    if args.device_trip:
        with open(args.device_trip, encoding='utf-8') as fh:
            dev = json.load(fh)
        dev_fixes = dev.get('locations', [])
        dev_ann = dev.get('announcements', [])
        print(f'device trip log  : {args.device_trip} (offline compare)')
        print(f'  {len(dev_fixes)} fixes, {len(dev_ann)} announcements')
        return _compare(truth, dev_fixes, dev_ann, args.device_trip,
                        args.align_m)

    # --- 1. install --------------------------------------------------------
    if args.install:
        print(f'installing       : {args.apk}')
        r = subprocess.run(['adb'] + (['-s', serial] if serial else []) +
                           ['install', '-r', '-d', args.apk],
                           capture_output=True, text=True, timeout=600)
        print('  ', r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip())
        if 'Success' not in r.stdout:
            print('! install failed')
            return 2

    # Root lets the test read the app's trip logs without a debuggable build.
    adb(serial, 'root')
    time.sleep(3)
    adb(serial, 'wait-for-device')
    who = shell(serial, 'whoami').strip()
    print(f'adb user         : {who}')

    before = set(shell(serial, f'ls {TRIPS_DIR}').split()) if not args.keep_trips \
        else set(shell(serial, f'ls {TRIPS_DIR}').split())

    # --- 2. seed the GPS at the trip's first fix ---------------------------
    fixes = load_fixes(args.trip)
    if len(fixes) < 2:
        print('! trip has no fixes')
        return 2
    dest = fixes[-1]
    print(f'route origin     : {fixes[0]["lat"]:.6f},{fixes[0]["lng"]:.6f} '
          f'→ destination {dest["lat"]:.6f},{dest["lng"]:.6f}')
    shell(serial, 'am force-stop', PKG)
    geo_fix(serial, fixes[0]['lat'], fixes[0]['lng'], 0)
    time.sleep(1)
    adb(serial, 'logcat', '-c')
    shell(serial, 'monkey', '-p', PKG, '-c',
          'android.intent.category.LAUNCHER', '1')

    # --- 3. wait for the app to build the route and start navigating -------
    started = wait_for_log(serial, 'AUTOTEST: navigation STARTED',
                           args.timeout_s)
    if not started:
        engine = wait_for_log(serial, 'AUTOTEST: engine ready', 5)
        print('! navigation never started on the device'
              + (f' (engine: {engine.strip()})' if engine else ''))
        for line in logcat(serial).splitlines():
            if 'AUTOTEST' in line or 'PLAN:' in line:
                print('   ', line.strip()[:140])
        return 2
    print(f'nav started      : {started.strip()[:110]}')

    # --- 4. replay the recorded GPS ----------------------------------------
    rng = ['--speed', str(args.speed), '--from-m', str(args.from_m)]
    if args.to_m is not None:
        rng += ['--to-m', str(args.to_m)]
    print(f'replaying GPS    : {len(fixes)} fixes total, '
          f'{args.speed}x, up to {args.to_m or "end"} m')
    t0 = time.time()
    subprocess.run([sys.executable, os.path.join(os.path.dirname(
        os.path.abspath(__file__)), 'emulator_gps_replay.py'),
        args.trip, '--serial', serial, *rng], timeout=60 * 90)
    print(f'replay finished  : {time.time() - t0:.0f}s')

    # The app writes the trip log when navigation ENDS. The AUTO_ROUTE harness
    # ends the drive by itself once the replayed car stops moving, so wait for
    # its own save line rather than poking the UI (BACK just leaves the app,
    # which never runs the trip-save path).
    saved = wait_for_log(serial, 'TRIP: saved', 120)
    if saved:
        print(f'trip saved       : {saved.strip()[-70:]}')
    else:
        still = wait_for_log(serial, 'AUTOTEST: car still', 20)
        print('! the harness never ended the drive — is AUTO_ROUTE built in?'
              + (f' ({still.strip()[-80:]})' if still else ''))
        return 2
    time.sleep(max(3.0, args.settle_s))
    name, raw = pull_newest_trip(serial, before)
    if not raw:
        print('! the app recorded no new trip')
        return 2
    print(f'device trip log  : {name} ({len(raw) / 1024:.0f} KB)')
    dev = json.loads(raw)
    return _compare(truth, dev.get('locations', []),
                    dev.get('announcements', []), str(name), args.align_m)


def _compare(truth, dev_fixes, dev_ann, label, align_m) -> int:
    """Diff a device trip log against the dataset; returns the exit code."""
    print(f'  {len(dev_fixes)} fixes, {len(dev_ann)} announcements')
    if dev_fixes:
        t0 = int(dev_fixes[0].get('timestampMs') or 0)
        t1 = int(dev_fixes[-1].get('timestampMs') or 0)
        print(f'  recorded span   : {(t1 - t0) / 1000:.0f}s, last fix on '
              f'{dev_fixes[-1].get("street")}')
    truth_fixes = truth['fixes']
    # Align device fixes to dataset fixes ONE-TO-ONE, in drive order. The app
    # logs ~1 fix/s, so while the car sits still (a red light, or the seconds
    # before road info arrives) several device fixes collapse onto the SAME
    # dataset fix — counting those as N disagreements inflates the number. A
    # device fix with no unclaimed dataset fix within --align-m is reported as
    # unmatched; a device fix whose limit is still unknown is reported as
    # `unset`; neither is a disagreement.
    rows, unset, unmatched = [], 0, 0
    lo = 0
    for f in dev_fixes:
        lat, lng = f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7
        best, best_d = None, float('inf')
        for t in truth_fixes[lo:]:
            d = math.hypot((t['lat'] - lat) * 111320,
                           (t['lng'] - lng) * 111320 * math.cos(math.radians(lat)))
            if d < best_d:
                best, best_d = t, d
        if best is None or best_d > align_m or best['i'] < lo:
            unmatched += 1
            continue
        lo = best['i']
        got = f.get('limitEffective') or f.get('speedLimit') or None
        want = best['expected_limit'] or None
        if got is None and want is not None:
            unset += 1
            continue
        if want is None:
            # The reference run had no road value at this instant (start of
            # drive) while the device did — not a disagreement.
            unset += 1
            continue
        rows.append({
            't': f.get('timestamp'), 'lat': lat, 'lng': lng,
            'dev_street': f.get('street'), 'dev_highway': f.get('highway'),
            'dev_road': f.get('speedLimit'), 'got': got, 'want': want,
            'source': f.get('limitSource'), 'truth_source': best['expected_source'],
            'truth_i': best['i'], 'truth_street': best['street'],
            'truth_s_m': best['s_m'], 'off_m': round(best_d, 1),
        })

    bad = sum(1 for r in rows if r['got'] != r['want'])
    # Ground-truth-free check, same log, same fix: does the app's effective
    # limit agree with the road value it read for that very fix? This needs no
    # alignment against another run, so it is the cleanest defect metric.
    self_conf = []
    for f in dev_fixes:
        eff = f.get('limitEffective') or 0
        road = f.get('speedLimit') or 0
        if eff and road and eff != road:
            self_conf.append((eff, road, f.get('limitSource') or '-',
                              f.get('street')))
    print('\n=== the app against its OWN road layer (same log, no alignment) ===')
    if self_conf:
        c = Counter((e, r, s) for e, r, s, _ in self_conf)
        print(f'  {len(self_conf)} of {len(dev_fixes)} fixes show an effective '
              f'limit that differs from the road value read for the same fix:')
        for (eff, road, src), n in c.most_common(6):
            ex = next(x for x in self_conf if x[0] == eff and x[1] == road
                      and x[2] == src)
            print(f'    {n:>4} fixes: effective {eff} km/h ({src}) vs road '
                  f'{road} km/h — e.g. {ex[3]!r}')
    else:
        print('  none — effective limit always matched the road layer')

    print('\n=== per-fix effective limit: device vs ground truth ===')
    print(f'  device fixes                  : {len(dev_fixes)}')
    print(f'  aligned one-to-one            : {len(rows)}')
    print(f'  skipped: limit not known yet  : {unset}')
    print(f'  skipped: no unclaimed fix <{align_m:.0f} m : {unmatched}')
    print(f'  mismatching                   : {bad} '
          f'({100.0 * bad / max(1, len(rows)):.0f}% of aligned)')
    miss = [r for r in rows if r['got'] != r['want']]
    # Group by the (got, want, source) signature — one bad sign adopted for a
    # whole street shows up as ONE finding, not 80 rows.
    groups: dict[tuple, list] = {}
    for r in miss:
        groups.setdefault((r['got'], r['want'], r['source'],
                           r['truth_source']), []).append(r)
    for (got, want, src, tsrc), rs in sorted(
            groups.items(), key=lambda kv: -len(kv[1])):
        g = next((r for r in rs if r['truth_street']), rs[0])
        span = (f'{min(r["truth_s_m"] for r in rs):.0f}-'
                f'{max(r["truth_s_m"] for r in rs):.0f} m')
        print(f'  {len(rs):>4} fixes (dataset {span}): device {got} km/h '
              f'({src or "-"}) vs dataset {want} km/h ({tsrc}) — device says '
              f'street={g["dev_street"]!r} road={g["dev_road"]}, dataset says '
              f'street={g["truth_street"]!r}')

    got_limits = []
    for a in dev_ann:
        if a.get('kind') != 'limit':
            continue
        m = re.search(r'(\d+)\s*km/h', a.get('text') or '')
        if m:
            got_limits.append(int(m.group(1)))
    want_limits = [e['limit'] for e in truth['limit_events']]
    print('\n=== limit announcements ===')
    print(f'  device  : {got_limits}')
    print(f'  dataset : {want_limits}')
    ann_ok = got_limits == want_limits

    # --- 7. verdict --------------------------------------------------------
    print('\n=== verdict ===')
    print(f'  limit values on the drive : '
          f'{"MATCH" if bad == 0 else f"{bad} WRONG"}')
    print(f'  limit announcements       : '
          f'{"MATCH" if ann_ok else "DIFFER"}')
    ok = (bad == 0 and ann_ok)
    print(f'  {label} on the device: {"PASS" if ok else "FAIL"}')
    if not ok:
        print('\n  the dataset says the app should show:')
        for e in truth['limit_events']:
            print(f'    fix {e["i"]:>4} @{e["s_m"]:>6.0f} m  {e["limit"]} km/h '
                  f'— "{e["text"]}"')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
