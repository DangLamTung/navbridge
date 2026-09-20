#!/usr/bin/env python3
"""Replay a recorded NavBridge trip into an Android emulator as REAL GPS.

The nav app can only be tested end-to-end if the emulator feeds it the same
positions a real receiver did. `adb emu geo fix` accepts a fix over the
emulator console:

    geo fix <longitude> <latitude> [<altitude> [<satellites> [<velocity>]]]

so we push every fix of a saved trip — with its own recorded SPEED (knots) —
at the cadence it was driven (or accelerated). The app sees an ordinary GNSS
stream: the outlier gate, the heading filter, the speed chip, the sign /
camera / limit logic and the trip logger all run for real.

Usage
    python3 tool/emulator_gps_replay.py "docs/trips/device/2026-09-18_172234_Chuyến_đi.json"
    ... --from-m 0 --to-m 3000        # only the first 3 km of the track
    ... --speed 4                     # 4x faster than the recording
    ... --serial emulator-5554

Notes
  * Altitude 0 and 8 satellites are placeholders; the app ignores altitude.
  * Velocity is KNOTS in the console protocol (1 m/s = 1.943844 kn) and is what
    makes the app's speed / overspeed logic behave exactly like the real drive.
  * --hold keeps re-sending the last fix so the car doesn't "teleport" back to
    the emulator's own position when the replay ends.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import socket
import subprocess
import sys
import time

MPS_TO_KNOTS = 1.943844


class Console:
    """The emulator's own console port (5554 etc.), spoken directly.

    `adb emu geo fix` costs a process spawn + an adb round trip (~1.4 s on this
    machine), which throttles the replay below the recording's cadence and
    makes the drive look slower and jumpier than it was. One socket keeps the
    exact 1 Hz timing. Falls back to `adb emu` when the console cannot be
    reached.
    """

    def __init__(self, serial: str | None):
        self.sock = None
        self.serial = serial or 'emulator-5554'
        self._connect()

    def _connect(self):
        if not self.serial.startswith('emulator-'):
            return
        port = int(self.serial.split('-', 1)[1]) + 0  # 5554 → console 5554
        try:
            s = socket.create_connection(('127.0.0.1', port), timeout=5)
        except OSError:
            return
        s.settimeout(5)
        banner = self._read_until(s, b'')
        if b'auth' in banner.lower() or b'Android Console' in banner:
            token = self._token()
            if token:
                s.sendall(f'auth {token}\r\n'.encode())
                reply = self._read_until(s, b'OK')
                if b'OK' not in reply:
                    s.close()
                    return
        self.sock = s

    @staticmethod
    def _token() -> str | None:
        p = os.path.expanduser('~/.emulator_console_auth_token')
        try:
            with open(p, encoding='utf-8') as fh:
                return fh.read().strip()
        except OSError:
            return None

    @staticmethod
    def _read_until(s, needle: bytes, limit: int = 4096) -> bytes:
        buf = b''
        s.settimeout(2)
        try:
            while len(buf) < limit:
                chunk = s.recv(limit)
                if not chunk:
                    break
                buf += chunk
                if needle and needle.lower() in buf.lower():
                    break
                if needle == b'':
                    break
        except (TimeoutError, OSError):
            pass
        return buf

    def geo_fix(self, lat: float, lng: float, knots: float) -> bool:
        if self.sock is None:
            return False
        try:
            self.sock.sendall(
                f'geo fix {lng:.7f} {lat:.7f} 0 8 {knots:.3f}\r\n'.encode())
            self._read_until(self.sock, b'OK')
            return True
        except OSError:
            self.sock = None
            return False

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def _adb_binary() -> str:
    """Locate the adb binary.

    A bare 'adb' is NOT on the PATH in every shell this script runs from (a
    replay once drove the whole recorded track and then died at the final park
    step with FileNotFoundError: 'adb'), so resolve it explicitly: PATH first,
    then $ANDROID_HOME / $ANDROID_SDK_ROOT, then the usual macOS install.
    """
    found = shutil.which('adb')
    if found:
        return found
    for root in (os.environ.get('ANDROID_HOME'),
                 os.environ.get('ANDROID_SDK_ROOT'),
                 os.path.expanduser('~/Library/Android/sdk')):
        if not root:
            continue
        cand = os.path.join(root, 'platform-tools', 'adb')
        if os.path.exists(cand):
            return cand
    return 'adb'  # let subprocess raise a clear error if it truly is missing


ADB = _adb_binary()


def adb(serial: str | None, *args: str, timeout: float = 20.0) -> str:
    cmd = [ADB]
    if serial:
        cmd += ['-s', serial]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout).stdout


def load_fixes(path: str) -> list[dict]:
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    out = []
    for loc in data.get('locations', []):
        try:
            lat = float(loc['latitudeE7']) / 1e7
            lng = float(loc['longitudeE7']) / 1e7
        except (KeyError, TypeError, ValueError):
            continue
        # `velocity` is m/s in the takeout shape this app writes.
        try:
            spd = float(loc.get('velocity') or 0.0)
        except (TypeError, ValueError):
            spd = 0.0
        t = int(loc.get('timestampMs') or 0)
        out.append({'lat': lat, 'lng': lng, 'spd': max(0.0, spd), 't': t})
    return out


def meters_between(a: dict, b: dict) -> float:
    m_per_deg_lat = 111320.0
    m_per_deg_lng = m_per_deg_lat * math.cos(math.radians(a['lat']))
    dlat = (b['lat'] - a['lat']) * m_per_deg_lat
    dlng = (b['lng'] - a['lng']) * m_per_deg_lng
    return math.hypot(dlat, dlng)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip')
    ap.add_argument('--serial', default=None)
    ap.add_argument('--speed', type=float, default=1.0,
                    help='playback rate vs the recording. KEEP IT AT 1: the app\n'
                         'subscribes to the GNSS stream at 1 Hz, so a faster\n'
                         'replay makes every fix it sees a bigger jump (and a\n'
                         'higher implied speed) than the drive really had')
    ap.add_argument('--from-m', type=float, default=0.0,
                    help='skip to this along-track distance (m)')
    ap.add_argument('--to-m', type=float, default=None,
                    help='stop at this along-track distance (m)')
    ap.add_argument('--min-interval', type=float, default=0.0,
                    help='floor between two geo fixes (s). 0 keeps the\n'
                         'recording\'s true 1 Hz cadence, which is what the\n'
                         'app subscribes at')
    ap.add_argument('--hold', type=float, default=0.0,
                    help='after the last fix, keep re-sending it for N s')
    ap.add_argument('--still', type=float, default=None,
                    help='print the AUTO_ROUTE still=<s> value this segment '
                         'needs (longer than its longest recorded stop) +10%%')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    fixes = load_fixes(args.trip)
    if len(fixes) < 2:
        print('no fixes in', args.trip, file=sys.stderr)
        return 2

    # Along-track distance → lets --from-m/--to-m cut a clean segment.
    dist = [0.0]
    for i in range(1, len(fixes)):
        dist.append(dist[-1] + meters_between(fixes[i - 1], fixes[i]))

    sel = [i for i in range(len(fixes))
           if dist[i] >= args.from_m and
           (args.to_m is None or dist[i] <= args.to_m)]
    if len(sel) < 2:
        print('segment has no fixes', file=sys.stderr)
        return 2

    print(f'{args.trip}')
    print(f'  fixes      : {len(fixes)} total, replaying {len(sel)} '
          f'(={dist[sel[-1]] - dist[sel[0]]:.0f} m)')
    print(f'  rate       : {args.speed}x'
          f'{"" if args.dry_run else f", serial {args.serial or "(default)"}"}')

    # Longest stationary run inside the segment: the AUTO_ROUTE watchdog must
    # not mistake a recorded red light for the end of the replay (the 09-18 trip
    # has a 48 s stop).
    longest = cur = 0
    run_start = 0
    best_start = 0
    for k, i in enumerate(sel):
        if fixes[i]['spd'] < 0.5:
            if cur == 0:
                run_start = k
            cur += 1
            if cur > longest:
                longest, best_start = cur, run_start
        else:
            cur = 0
    still_s = 0.0
    if longest > 1:
        a = sel[best_start]
        b = sel[min(best_start + longest - 1, len(sel) - 1)]
        still_s = (fixes[b]['t'] - fixes[a]['t']) / 1000.0
    print(f'  longest stop: {still_s:.0f}s in this segment → build with '
          f'AUTO_ROUTE=...,still={int(max(60, still_s * 1.5))}')

    console = None if args.dry_run else Console(args.serial)
    if not args.dry_run:
        print(f'  transport  : '
              f'{"emulator console socket" if console.sock else "adb emu"}')

    prev_wall = None
    sent = 0
    try:
        for n, i in enumerate(sel):
            fx = fixes[i]
            if prev_wall is not None and i > 0:
                # Recorded gap between the two fixes — the pacing IS the
                # recording's cadence, which is what makes the app's outlier
                # gate and its speed-based logic behave as they did on the day.
                gap = (fixes[i]['t'] - fixes[i - 1]['t']) / 1000.0
                if gap <= 0 or gap > 10:  # GPS outage in the log → pace 1 s
                    gap = 1.0
                wait = gap / max(0.05, args.speed)
                wait -= (time.monotonic() - prev_wall)
                if wait > args.min_interval:
                    time.sleep(min(wait, 5.0))
            knots = fx['spd'] * MPS_TO_KNOTS
            if args.dry_run:
                if n % 25 == 0:
                    print(f'  [{n:5d}] {fx["lat"]:.6f},{fx["lng"]:.6f} '
                          f'{fx["spd"]:5.1f} m/s')
            else:
                ok = console is not None and console.geo_fix(
                    fx['lat'], fx['lng'], knots)
                if not ok:
                    adb(args.serial, 'emu', 'geo', 'fix',
                        f'{fx["lng"]:.7f}', f'{fx["lat"]:.7f}', '0', '8',
                        f'{knots:.3f}')
            prev_wall = time.monotonic()
            sent += 1
            if sent % 20 == 0 and not args.dry_run:
                print(f'  sent {sent}/{len(sel)} '
                      f'({fx["spd"] * 3.6:5.1f} km/h)', flush=True)
        if args.hold > 0 and not args.dry_run:
            last = fixes[sel[-1]]
            end = time.monotonic() + args.hold
            while time.monotonic() < end:
                if not (console is not None
                        and console.geo_fix(last['lat'], last['lng'], 0)):
                    adb(args.serial, 'emu', 'geo', 'fix', f'{last["lng"]:.7f}',
                        f'{last["lat"]:.7f}', '0', '8', '0')
                time.sleep(0.5)
    except KeyboardInterrupt:
        print('\ninterrupted')
    finally:
        if console is not None:
            console.close()
    # Park the car explicitly: the emulator's GNSS keeps dead-reckoning from
    # the last velocity, so without a final zero-velocity fix the app sees a
    # permanently "moving" car and the AUTO_ROUTE watchdog never fires.
    if not args.dry_run and sent:
        last = fixes[sel[-1]]
        for _ in range(3):
            if not (console is not None
                    and console.geo_fix(last['lat'], last['lng'], 0)):
                adb(args.serial, 'emu', 'geo', 'fix', f'{last["lng"]:.7f}',
                    f'{last["lat"]:.7f}', '0', '8', '0')
            time.sleep(1.0)
        print('  parked the car (velocity 0) — the app can now detect the end')
    print(f'done: {sent} fixes sent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
