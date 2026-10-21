#!/usr/bin/env python3
"""Geocode the kiemtraphatnguoi.com camera list for Đồng Nai (+ Bình Phước cũ).

Input: the scraped rows (addr / provider / behaviours / map_query), one JSON per
row. The site publishes an ADDRESS STRING only — no lat/lng — so every point has
to be geocoded, and the guards in `fetch_police_cameras` (bare-km posts, province
must appear in the hit) are what keep bad hits out.

    python3 tool/geocode_dongnai.py --limit 10      # sample, prints what it does
    python3 tool/geocode_dongnai.py                 # whole list, resumable
    python3 tool/geocode_dongnai.py --report
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import fetch_police_cameras as fpc              # noqa: E402

SRC = '/tmp/dn_cams_source.json'                # scraped rows (see memory note)
OUT = 'tool/data/dongnai_kiemtra.json'          # finished rows, merged schema
JS = 'tool/data/dongnai_kiemtra.jsonl'          # resumable per-row log

# --- province polygons (cached by the earlier audit; optional) --------------
# The cache filenames are NOT stable: the earlier scrape wrote them with a
# double underscore ('poly_Đồng_Nai__Việt_Nam.json'), which a literal path
# misses — and a missing polygon used to make _inside() return True, so every
# point was labelled Bình Phước. Glob, and fail CLOSED.
PN = {'Đồng Nai': ('/tmp', 'poly_Đồng_Nai*.json'),
      'Bình Phước': ('/tmp', 'poly_Bình_Phước*.json')}


def _find(folder, pattern):
    import glob
    hits = sorted(glob.glob(os.path.join(folder, pattern)))
    return hits[0] if hits else None


def _rings(path):
    if not path or not os.path.exists(path):
        return None
    j = json.load(open(path))
    g = j[0]['geojson']
    c = g['coordinates']
    return [c[0]] if g['type'] == 'Polygon' else [p[0] for p in c]


def _inside(x, y, rs):
    if not rs:
        # fail CLOSED: a missing polygon must never mean "accept everything"
        return False
    for r in rs:
        hit, n = False, len(r)
        for i in range(n):
            x1, y1 = r[i][0], r[i][1]
            x2, y2 = r[(i + 1) % n][0], r[(i + 1) % n][1]
            if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
                hit = not hit
        if hit:
            return True
    return False


POLY = {k: _rings(_find(f, p)) for k, (f, p) in PN.items()}
if not all(POLY.values()):
    print('WARNING: province polygon missing ->',
          {k: bool(v) for k, v in POLY.items()}, file=sys.stderr)


def clean_addr(a):
    """The site's address strings carry a violation prefix and the camera code:
    'Gs tốc độ Ql 14 KM 920+500, xã Minh Hưng,' / 'QL14xHùng Vương-… (VP1N001)'.
    Both poison a geocoder query."""
    a = re.sub(r'\b(gs|gs\.)\s*t\u1ed1c\s*\u0111\u1ed9\b', ' ', a, flags=re.I)
    a = re.sub(r'\bgs\s*toc\s*do\b', ' ', a, flags=re.I)
    a = re.sub(r'\s*\([A-Z0-9][A-Z0-9._-]{2,}\)\s*$', '', a)   # camera code
    a = re.sub(r'\s*\([^)]*gi\u1edbi h\u1ea1n t\u1ed1c \u0111\u1ed9[^)]*\)', ' ', a)
    a = re.sub(r'\s+', ' ', a).strip(' ,;-')
    return a


def province_of(lat, lng):
    """Which former province a point really falls in: Bình Phước first (it is
    nested inside the merged polygon), then Đồng Nai cũ = merged minus Bình
    Phước. None when it is outside both — a wrong-province hit."""
    if _inside(lng, lat, POLY['Bình Phước']):
        return 'Bình Phước'
    if _inside(lng, lat, POLY['Đồng Nai']):
        return 'Đồng Nai'
    return None


def existing_points():
    """name -> (lat, lng) from the shipped DB, so a point we already resolved is
    never re-geocoded (and never moves). Indexed by the raw name AND by the
    cleaned one, because clean_addr() drops the "(Khu Đông dân cư, …)" tail
    that the shipped names still carry."""
    j = json.load(open('assets/offline_map/vietnam_cameras.json'))
    out = {}
    for c in j['cameras']:
        if c.get('source') != 'police':
            continue
        pt = (c['lat'], c['lng'])
        for k in (c['name'].strip().lower(), clean_addr(c['name']).lower()):
            out.setdefault(k, pt)
    return out


def pinnable(addr):
    """The shared is_mergeable() was tuned on the police-queue addresses and
    drops 'QL13 giao Phan Bội Châu'-style entries, which ARE a single point.
    Accept an intersection ('giao' + a name) or a market/commune-office."""
    if fpc.is_mergeable(addr):
        return True
    return bool(re.search(r'\bgiao\s+[A-ZĐ\u00c0-\u1ef9]', addr)) or \
        bool(re.search(r'\b(ch\u1ee3|ubnd|uy ban|c\u1ea7u)\b', addr, re.I))


def focus_of(behaviours):
    t = ' '.join(behaviours).lower()
    if 'tốc độ' in t:
        return 'speed', 'speed_camera'
    if 'đèn tín hiệu' in t:
        return 'red_light', 'red_light_camera'
    return 'violations', 'traffic_camera'


def load_done():
    done = {}
    if os.path.exists(JS):
        for line in open(JS, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            done[r['name']] = r
    return done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--report', action='store_true')
    a = ap.parse_args()

    rows = json.load(open(SRC, encoding='utf-8'))
    done = load_done()
    have = existing_points()
    print(f'{"source rows":>12}: {len(rows)}   already geocoded: {len(done)}')

    if a.report:
        ok = len(done)
        print(f'{"ok":>12}: {ok}   ({100 * ok / max(1, len(rows)):.0f}%)')
        return

    todo = [r for r in rows if r['addr'] not in done]
    if a.limit:
        todo = todo[:a.limit]

    log = open(JS, 'a', encoding='utf-8')
    fixed = reused = skipped = failed = 0
    for i, r in enumerate(todo, 1):
        addr = clean_addr(r['addr'])
        focus, typ = focus_of(r['behaviours'])

        def emit(lat, lng, prov, why):
            row = {
                'name': r['addr'], 'lat': round(lat, 6), 'lng': round(lng, 6),
                'focus': focus, 'type': typ, 'district': prov,
                'source': 'kiemtraphatnguoi', 'code': r.get('code'),
                'provider': r['provider'], 'behaviours': r['behaviours'],
                'googlemaps': ('https://www.google.com/maps/search/?api=1&query='
                               + (r.get('map_query') or addr).replace(' ', '%20')),
            }
            log.write(json.dumps(row, ensure_ascii=False) + '\n')
            log.flush()
            done[r['addr']] = row
            print(f'  [{i}/{len(todo)}] {why:6s} {prov[:9]:9s} {focus:9s} '
                  f'{lat:.4f},{lng:.4f}  {addr[:40]}')

        # 1. already in the shipped DB -> reuse the resolved coordinate
        hit = have.get(addr.lower())
        if hit:
            reused += 1
            emit(hit[0], hit[1], province_of(hit[0], hit[1]) or 'Đồng Nai', 'REUSE')
            continue

        # 2. geocode, then decide the province from the polygon (not the text)
        if not pinnable(addr):
            skipped += 1
            print(f'  [{i}/{len(todo)}] SKIP   no address to geocode: {addr[:52]}')
            continue
        got = None
        for guess in ('Đồng Nai', 'Bình Phước'):
            got = fpc.geocode(addr, guess, provider='photon')
            if got:
                break
        prov = province_of(*got) if got else None
        if not got or not prov:
            failed += 1
            print(f'  [{i}/{len(todo)}] MISS   {addr[:58]}'
                  + (f' -> {got[0]:.4f},{got[1]:.4f} outside' if got else ''))
            continue
        fixed += 1
        emit(got[0], got[1], prov, 'OK')
    log.close()

    json.dump(list(done.values()), open(OUT, 'w'), ensure_ascii=False, indent=1)
    print(f'\ngeocoded {fixed} | reused {reused} | skipped {skipped} | '
          f'failed {failed} | total in {OUT}: {len(done)}')


if __name__ == '__main__':
    main()
