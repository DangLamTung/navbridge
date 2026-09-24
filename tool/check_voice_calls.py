#!/usr/bin/env python3
"""Audit the voice navigator against a RECORDED drive.

`trip_logger.dart` stores every announced sentence AND, per GPS fix, the street
under the car, the effective limit and the layer it came from. That turns "the
voice says the wrong street / speed" into something measurable instead of a
memory of what it sounded like.

Checks, per announcement:
  * kind='limit'    — "Tốc độ tối đa N km/h": does N match the limit actually in
                      force at that moment (limitEffective)?
  * kind='maneuver' — "Đi trên X, sau …, <verb> vào Y. Tốc độ tối đa N km/h":
                      does X match the street under the car, and N the vehicle's
                      max on the street being entered
                      (see tool/announce_speed_audit.py)?

NOTE (2026-09-24): every limit announcement uses ONE phrase, "Tốc độ tối đa
N km/h" (briefly "giới hạn tốc độ" the same day; before that the change said
"Giới hạn N km/h" and the warning ahead "Giảm tốc độ, giới hạn N km/h"). All
forms are still parsed so trips recorded before the change stay auditable.

Run:  python3 tool/check_voice_calls.py [docs/trips/device]
Exit code is non-zero when a street/limit mismatch is found, so it can gate a
release check after a test drive.

Measured 2026-09-22 over 11 recorded drives (before the fix below):
  limit announcements  104 checked, 0 wrong
  maneuver callouts    559 checked, 172 (31 %) named a DIFFERENT street than the
                       one under the car — the callout used the route engine's
                       step name while the on-screen chip used the Waze segment
                       name, and those flip at different places.
After the fix (nav_voice.dart `_announce` reads `_roadInfo.name` first) this
count should drop to the cases where the segment simply has no name.
"""

import bisect
import glob
import json
import os
import re
import sys
import unicodedata

LIMIT_RX = re.compile(
    r'(?:Gi[ớo]i h[ạa]n(?: t[ốo]c [đd][ộo])?|T[ốo]c [đd][ộo] t[ốo]i [đd]a) (\d+) km/h')
ON_RX = re.compile(r'^Đi trên (.+?), sau ')
MAX_RX = LIMIT_RX  # one phrase for every limit announcement since 2026-09-24

# Spoken turn verbs, most specific first. 'nhẹ' (slight) is excluded from the
# direction check: its heading change is small enough to be ambiguous.
VERBS = [
    ('quay đầu', 'uturn'),
    ('đi theo vòng xuyến', 'roundabout'),
    ('rẽ trái nhẹ', 'slight'),
    ('rẽ phải nhẹ', 'slight'),
    ('rẽ trái', 'left'),
    ('rẽ phải', 'right'),
]
TURN_RX = re.compile(
    '(' + '|'.join(re.escape(v) for v, _ in VERBS) + ')'
)
TURN_DIR = dict(VERBS)


def spoken_turn(text):
    """(verb, direction) for the FIRST turn verb in [text], else (None, None).

    Position in the SENTENCE decides, not the order of [VERBS]: a callout often
    names two moves — "… rẽ phải vào Lũy Bán Bích, sau đó rẽ trái vào Vườn Lài"
    — and the first one is the maneuver this sentence is about. Scanning the
    table instead of the text reported the SECOND verb for those, which is what
    inflated the turn-direction error rate to ~40 % before; corrected here the
    same drives measure 12 % (see the anchored probe below).
    """
    m = TURN_RX.search(text)
    if not m:
        return None, None
    return m.group(1), TURN_DIR[m.group(1)]


def heading_of(fix):
    h = fix.get('heading')
    return None if h is None else float(h)


def delta_deg(a, b):
    """Signed shortest rotation from heading a to heading b (+ = clockwise/right)."""
    return (b - a + 540.0) % 360.0 - 180.0


def first_turn_after(fixes, ms, window_s=90, min_deg=45.0, expect_m=None):
    """The turn the callout is ABOUT: (delta, fix) or (None, None).

    Heading increases clockwise, so a POSITIVE delta is a RIGHT turn.

    [expect_m] is the distance the callout itself announced ("sau 338 mét").
    Requiring the heading change to happen near THAT distance is what separates
    the announced maneuver from an unrelated curve just after the sentence, and
    from a bend the car happens to take on the way there.
    """
    idx = bisect.bisect_left([f['ms'] for f in fixes], ms)
    for i in range(idx, len(fixes) - 1):
        if fixes[i]['ms'] - ms > window_s * 1000:
            break
        if expect_m is not None:
            moved = haversine_m(fixes[idx], fixes[i])
            if moved < expect_m * 0.55:
                continue  # too early to be the announced maneuver
            if moved > expect_m * 1.6:
                return None, None  # the announced turn never arrived
        h0, h1 = heading_of(fixes[i]), heading_of(fixes[i + 1])
        if h0 is None or h1 is None:
            continue
        d = delta_deg(h0, h1)
        if abs(d) >= min_deg:
            return d, fixes[i]
    return None, None


def haversine_m(a, b):
    import math

    r = 6371000.0
    p1, p2 = math.radians(a['lat']), math.radians(b['lat'])
    dp = p2 - p1
    dl = math.radians(b['lng'] - a['lng'])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


DIST_RX = re.compile(r'sau ([\d.,]+)\s*(km|mét)')


def bearing_deg(a, b):
    """Compass bearing a -> b, from POSITIONS only (no heading field)."""
    import math

    p1, p2 = math.radians(a['lat']), math.radians(b['lat'])
    dl = math.radians(b['lng'] - a['lng'])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def path_turn_delta(fixes, i, span_m=40.0):
    """Signed turn angle of the GPS PATH through fixes[i] (+ = right).

    Independent of the `heading` field, so it is the tie-breaker if the two
    disagree: the logged heading is a DISPLAYED (smoothed) value, while this is
    the recorded track itself.
    """
    before, acc = i, 0.0
    while before > 0 and acc < span_m:
        acc += haversine_m(fixes[before - 1], fixes[before])
        before -= 1
    after, acc2 = i, 0.0
    while after < len(fixes) - 1 and acc2 < span_m:
        acc2 += haversine_m(fixes[after], fixes[after + 1])
        after += 1
    if before == i or after == i:
        return None
    return delta_deg(
        bearing_deg(fixes[before], fixes[i]), bearing_deg(fixes[i], fixes[after])
    )


def announced_meters(text):
    """'sau 338 mét' / 'sau 1,1 km' → metres, else None."""
    m = DIST_RX.search(text)
    if not m:
        return None
    v = float(m.group(1).replace(',', '.'))
    return v * 1000.0 if m.group(2) == 'km' else v


INTO_RX = re.compile(r'vào ([^.,]+)')

# Bands of the shipped direction rule (refineManeuverIcon in nav_protocol.dart):
# below 18 deg the geometry says nothing, at/above 135 deg it may be a U-turn
# shape, so both keep the router's label; in between the geometry wins.
NOISE_DEG, UTURN_DEG = 18.0, 135.0


def anchored_turn(fixes, ms, target):
    """Street-anchored probe: (angle, fix) at the maneuver the callout NAMED.

    Anchoring on "the first turn after the sentence" is unreliable where turns
    are 50-100 m apart (normal at VN junctions). The street the callout names is
    an independent signal: the fix where the car's street BECOMES that target IS
    the physical maneuver, so the path angle there can be compared with the
    spoken verb without any turn-matching guesswork.
    """
    idx = bisect.bisect_left([f['ms'] for f in fixes], ms)
    for i in range(max(1, idx), min(idx + 90, len(fixes))):
        if norm(fixes[i]['street']) != target:
            continue
        if norm(fixes[i - 1]['street']) == target:
            continue
        return path_turn_delta(fixes, i, span_m=45.0), fixes[i]
    return None, None


def norm(s):
    """Compare road names ignoring case, diacritics and punctuation."""
    s = unicodedata.normalize('NFD', (s or '').lower())
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return re.sub(r'[^a-z0-9 ]+', ' ', s).strip()


def load(path):
    d = json.load(open(path))
    fixes = []
    for f in d.get('locations', []):
        fixes.append(
            {
                'ms': int(f.get('timestampMs', 0) or 0),
                'street': f.get('street'),
                'limit': f.get('limitEffective'),
                'layer': f.get('limitLayer'),
                'src': f.get('limitSource'),
                'heading': f.get('heading'),
                'lat': (f.get('latitudeE7') or 0) / 1e7,
                'lng': (f.get('longitudeE7') or 0) / 1e7,
            }
        )
    fixes.sort(key=lambda x: x['ms'])
    return fixes, d.get('announcements', [])


def fix_at(fixes, ms):
    """State the callout was driving onto: first fix at/after the sentence."""
    if not fixes:
        return None
    i = bisect.bisect_left([f['ms'] for f in fixes], ms)
    return fixes[min(i, len(fixes) - 1)]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'docs/trips/device'
    paths = sorted(glob.glob(os.path.join(root, '*.json')))
    if not paths:
        raise SystemExit(f'no trips in {root}')

    checked = {'limit': 0, 'maneuver': 0, 'turn': 0}
    bad = {'limit': [], 'street': [], 'maneuver_limit': [], 'turn': []}
    turns = {}
    # Street-anchored turns (reliable) + the app's own logged geometry angle
    # (`extra.turnDeg`, written by the fixed build — the authoritative check).
    anch = {'checked': 0, 'noise': 0, 'decisive': 0, 'uturn': 0, 'wrong': []}
    direct = {'checked': 0, 'wrong': []}
    for path in paths:
        fixes, anns = load(path)
        if not fixes or not anns:
            continue
        for a in anns:
            kind = a.get('kind') or ''
            text = a.get('text') or ''
            ms = int(a.get('timestampMs', 0) or 0)
            f = fix_at(fixes, ms)
            if f is None:
                continue
            if kind == 'limit':
                m = LIMIT_RX.search(text)
                if not m:
                    continue
                checked['limit'] += 1
                if f['limit'] is not None and int(m.group(1)) != f['limit']:
                    bad['limit'].append(
                        (os.path.basename(path), text, f['limit'], f['layer'])
                    )
            elif kind == 'maneuver':
                checked['maneuver'] += 1
                m = ON_RX.search(text)
                if m and f['street']:
                    said, actual = norm(m.group(1)), norm(f['street'])
                    if (
                        said
                        and actual
                        and said != actual
                        and said not in actual
                        and actual not in said
                    ):
                        bad['street'].append(
                            (os.path.basename(path), m.group(1), f['street'])
                        )
                m2 = MAX_RX.search(text)
                if m2 and f['limit'] is not None and int(m2.group(1)) != f['limit']:
                    bad['maneuver_limit'].append(
                        (os.path.basename(path), m2.group(1), f['limit'])
                    )
                # Turn DIRECTION: compare the spoken verb with the heading the
                # car actually swings through at that maneuver. Ground truth is
                # free — every fix carries `heading`, and heading increases
                # clockwise, so a positive change is a right turn.
                verb, direction = spoken_turn(text)
                if direction in ('left', 'right'):
                    # (a) The app's own geometry angle, when the build logs it.
                    deg_txt = (a.get('extra') or {}).get('turnDeg')
                    if deg_txt not in (None, ''):
                        deg = float(deg_txt)
                        if NOISE_DEG <= abs(deg) < UTURN_DEG:
                            direct['checked'] += 1
                            if ('right' if deg > 0 else 'left') != direction:
                                direct['wrong'].append(
                                    (os.path.basename(path), text, deg)
                                )
                    # (b) Street-anchored probe (works on older drives too).
                    tgt = INTO_RX.search(text)
                    if tgt and norm(tgt.group(1)):
                        s, at = anchored_turn(
                            fixes, ms, norm(tgt.group(1))
                        )
                        if s is not None:
                            anch['checked'] += 1
                            if abs(s) < NOISE_DEG:
                                anch['noise'] += 1
                            elif abs(s) >= UTURN_DEG:
                                anch['uturn'] += 1
                            else:
                                anch['decisive'] += 1
                                if ('right' if s > 0 else 'left') != direction:
                                    anch['wrong'].append(
                                        (
                                            os.path.basename(path),
                                            tgt.group(1),
                                            direction,
                                            round(s),
                                        )
                                    )
                    d, at = first_turn_after(
                        fixes, ms, expect_m=announced_meters(text)
                    )
                    if d is not None:
                        checked['turn'] += 1
                        actual = 'right' if d > 0 else 'left'
                        path_d = path_turn_delta(fixes, fixes.index(at))
                        key = (round(at['lat'], 4), round(at['lng'], 4))
                        # One physical turn is called out far/near/final, so a
                        # wrong direction would otherwise be counted 3-6 times.
                        turns.setdefault(
                            key,
                            (verb, direction, actual, round(d), path_d, at),
                        )
                        if actual != direction:
                            bad['turn'].append(
                                (
                                    os.path.basename(path),
                                    verb,
                                    d,
                                    at['street'],
                                    at['lat'],
                                    at['lng'],
                                    path_d,
                                )
                            )

    print(f"drives checked                : {len(paths)}")
    print(f"limit announcements           : {checked['limit']}")
    print(f"  value WRONG                 : {len(bad['limit'])}")
    print(f"maneuver callouts             : {checked['maneuver']}")
    print(f"  street name WRONG           : {len(bad['street'])}")
    print(f"  limit inside callout WRONG  : {len(bad['maneuver_limit'])}")
    print(f"turn callouts (left/right)    : {checked['turn']}")
    print(f"  DISTINCT turns identified    : {len(turns)}")
    wrong_turns = sum(1 for v in turns.values() if v[1] != v[2])
    print(f"  distinct turns WRONG         : {wrong_turns}")
    # Cross-check the detector: does the POSITION-based turn agree with the
    # heading-based one? A big disagreement means the detector, not the app.
    agree = disagree = 0
    for verb, direction, actual, d, path_d, _at in turns.values():
        if path_d is None:
            continue
        path_dir = 'right' if path_d > 0 else 'left'
        if path_dir == actual:
            agree += 1
        else:
            disagree += 1
    print(f"  detector agreement (heading vs path): {agree} agree / {disagree} differ")
    path_wrong = sum(
        1
        for v in turns.values()
        if v[4] is not None and ('right' if v[4] > 0 else 'left') != v[1]
    )
    print(f"  distinct turns WRONG by PATH  : {path_wrong}")
    print(f"  DIRECTION WRONG             : {len(bad['turn'])} (callouts)")
    # Street-anchored probe — the reliable one: it needs no turn matching, only
    # the street the sentence names. Historical drives were recorded BEFORE the
    # geometry cross-check, so leftovers here are expected on old data.
    print(
        f"  ANCHORED on the named street   : {anch['checked']} "
        f"(decisive {anch['decisive']} / noise {anch['noise']} / "
        f"uturn-shaped {anch['uturn']})"
    )
    print(
        f"    direction WRONG             : {len(anch['wrong'])}"
        "   [pre-fix drives expected: the app followed the router label]"
    )
    # The shipped build logs the route-geometry angle it used, so this is an
    # end-to-end check of the rule itself (no inference from the track).
    print(
        f"    app's logged geometry angle : {direct['checked']} decisive",
    )
    print(f"    spoken verb WRONG           : {len(direct['wrong'])}")
    for b in (anch['wrong'] + direct['wrong'])[:10]:
        print(f"      {b[0][:24]:<24} said {b[2] if len(b) == 4 else '?'} {b[1]!r}")

    if bad['turn']:
        print('\n--- turn direction mismatches (said | heading swing | path swing | where)')
        for b in bad['turn'][:15]:
            pd = f"{b[6]:+6.0f}deg" if b[6] is not None else '  n/a '
            print(
                f"  {b[0][:24]:<24} said {b[1]:<10} heading {b[2]:+5.0f} path {pd} "
                f"{b[3]!r} @ {b[4]:.5f},{b[5]:.5f}"
            )

    if bad['street']:
        print('\n--- street mismatches (said | street under the car at that fix)')
        for b in bad['street'][:15]:
            print(f"  {b[0][:26]:<26} said {b[1][:34]!r:<36} actual {b[2][:30]!r}")
    if bad['limit']:
        print('\n--- limit mismatches (said | effective, layer)')
        for b in bad['limit'][:15]:
            print(f"  {b[0][:26]:<26} said {b[1]!r:<26} actual={b[2]} layer={b[3]}")

    failed = any(bad.values()) or bool(direct['wrong'])
    print('\nRESULT:', 'FAIL' if failed else 'OK')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
