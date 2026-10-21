#!/usr/bin/env python3
"""Geocode the kiemtraphatnguoi camera list with the Google Geocoding API.

Why Google and not Photon: measured on this list, Photon MISSES house-number
addresses that Google resolves to ROOFTOP.  'số 397 Hùng Vương, Thị trấn Gia
Ray, Huyện Xuân Lộc, Đồng Nai' -> Photon: no hit.  Google: 10.933275,107.404316
ROOFTOP.  Google also says *what kind* of hit it is, which is the guard Photon
lacks: 'QL14 - Nội ô xã Phú Sơn…' comes back as GEOMETRIC_CENTER of the whole
road (14.12,107.95 — 200 km away), and that must be rejected, not shipped.

    python3 tool/geocode_google.py --dry        # count the calls, spend nothing
    python3 tool/geocode_google.py --limit 20   # sample
    python3 tool/geocode_google.py              # whole list, resumable
    python3 tool/geocode_google.py --report

Key: GOOGLEMAPS_API_KEY (or GOOGLE_GEOCODE_KEY) from navbridge/.env — the same
key the app already uses.  Geocoding is an "Essentials" SKU (~10k free/month).
"""
import argparse
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

from geocode_dongnai import (                    # noqa: E402
    clean_addr, focus_of, pinnable, province_of)

SRC = 'tool/data/dongnai_kiemtra_source.json'
OUT = 'tool/data/dongnai_google.json'
JS = 'tool/data/dongnai_google.jsonl'
ENV = '.env'


def api_key():
    for name in ('GOOGLE_GEOCODE_KEY', 'GOOGLEMAPS_API_KEY'):
        v = os.environ.get(name)
        if v:
            return v.strip()
    if os.path.exists(ENV):
        for line in open(ENV, encoding='utf-8'):
            line = line.strip()
            if line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            if k.strip() in ('GOOGLE_GEOCODE_KEY', 'GOOGLEMAPS_API_KEY'):
                v = v.strip().strip('"').strip("'")
                if v:
                    return v
    sys.exit('no Google key: set GOOGLE_GEOCODE_KEY or GOOGLEMAPS_API_KEY in .env')


def fold(s):
    # đ/Đ do not decompose under NFD — fold them by hand, else 'Đà Nẵng' never
    # matches its slug spelling 'da nang'
    s = (s or '').replace('đ', 'd').replace('Đ', 'D')
    s = unicodedata.normalize('NFD', s.lower())
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return re.sub(r'[^a-z0-9 ]+', ' ', s)


COMMUNE = re.compile(
    r'\b(?:xa|phuong|thi tran|p|tt)\s*\.?\s+'
    r'([a-z0-9 ]{3,})$|'
    r'\b(?:xa|phuong|thi tran)\s+([a-z0-9 ]{3,}?)(?:\s*[,]|$)')


def commune_of(addr):
    """The commune/ward name the query asks for, folded — used to decide
    whether a fuzzy hit actually landed in that commune."""
    a = fold(clean_addr(addr))
    m = COMMUNE.search(a)
    if not m:
        return None
    return (m.group(1) or m.group(2) or '').strip()


def geocode_g(addr, key, tries=3):
    """-> (lat, lng, location_type, formatted_address) or None."""
    q = f'{clean_addr(addr)}, Việt Nam'
    url = ('https://maps.googleapis.com/maps/api/geocode/json?'
           + urllib.parse.urlencode({'address': q, 'key': key,
                                     'language': 'vi', 'region': 'vn',
                                     'components': 'country:VN'}))
    for n in range(tries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent':
                                                       'navbridge-geo/1.0'})
            with urllib.request.urlopen(req, timeout=25) as r:
                j = json.load(r)
        except Exception as e:                              # noqa: BLE001
            time.sleep(1.5 * (n + 1))
            if n == tries - 1:
                return ('ERR', f'{type(e).__name__}: {e}')
            continue
        st = j.get('status')
        if st in ('OVER_QUERY_LIMIT', 'OVER_DAILY_LIMIT', 'REQUEST_DENIED'):
            sys.exit(f'Google says {st}: {j.get("error_message")}')
        if st in ('UNKNOWN_ERROR', 'RESOURCE_EXHAUSTED') and n < tries - 1:
            time.sleep(1.5 * (n + 1))
            continue
        if st != 'OK' or not j.get('results'):
            return None
        r0 = j['results'][0]
        g = r0['geometry']
        return (g['location']['lat'], g['location']['lng'],
                g.get('location_type'), r0.get('formatted_address'))
    return None


PRECISE = ('ROOFTOP', 'RANGE_INTERPOLATED')

# An address component beyond the road itself: xã/phường/thị trấn/huyện/thành phố
ADMIN = re.compile(r'\b(xa|phuong|thi tran|huyen|thi xa|thanh pho)\b')


def load_done():
    done = {}
    if os.path.exists(JS):
        for line in open(JS, encoding='utf-8'):
            line = line.strip()
            if line:
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
    ap.add_argument('--dry', action='store_true')
    a = ap.parse_args()

    rows = json.load(open(SRC, encoding='utf-8'))
    # one call per distinct cleaned address: the site lists a camera once per
    # violation type, so 583 rows collapse to ~518 addresses
    by_addr = {}
    for r in rows:
        by_addr.setdefault(clean_addr(r['addr']), []).append(r)
    done = load_done()

    todo = [(k, v) for k, v in by_addr.items() if k not in done and pinnable(k)]
    skipped = len(by_addr) - len([k for k in by_addr if pinnable(k)])
    print(f'{"rows":>14}: {len(rows)}')
    print(f'{"unique address":>14}: {len(by_addr)}')
    print(f'{"pinnable":>14}: {len(by_addr) - skipped}')
    print(f'{"no address":>14}: {skipped}')
    print(f'{"done":>14}: {len(done)}')
    print(f'{"to call":>14}: {len(todo)}')

    if a.report:
        by_tier, by_type = {}, {}
        for r in done.values():
            by_tier[r.get('precision')] = by_tier.get(r.get('precision'), 0) + 1
            by_type[r.get('location_type')] = by_type.get(
                r.get('location_type'), 0) + 1
        print('precision:', by_tier)
        print('location types:', by_type)
        return
    if a.dry:
        return

    key = api_key()
    if a.limit:
        todo = todo[:a.limit]

    log = open(JS, 'a', encoding='utf-8')
    ok = rejected = miss = 0
    calls = 0
    seen_coords = {(round(r['lat'], 4), round(r['lng'], 4))
                   for r in done.values()}
    for i, (addr, group) in enumerate(todo, 1):
        res = geocode_g(addr, key)
        calls += 1
        if res and res[0] == 'ERR':
            print(f'  [{i}/{len(todo)}] ERROR {res[1][:80]}')
            miss += 1
            continue
        if not res:
            miss += 1
            print(f'  [{i}/{len(todo)}] MISS   {addr[:52]}')
            continue
        lat, lng, ltype, fmt = res
        prov = province_of(lat, lng)
        if not prov:
            rejected += 1
            print(f'  [{i}/{len(todo)}] OUTSIDE {lat:.4f},{lng:.4f} {addr[:40]}')
            continue
        # Impossible: two cameras cannot share a point. When Google collapses a
        # whole road to one coordinate it repeats it for every address on it
        # (that is how 'QL14' answered five different rows with 14.1223,107.9502).
        ck = (round(lat, 4), round(lng, 4))
        if ck in seen_coords:
            rejected += 1
            print(f'  [{i}/{len(todo)}] DUP    {lat:.4f},{lng:.4f} '
                  f'(same as another row) {addr[:34]}')
            continue
        # A non-precise hit is only usable if Google actually located a place
        # and not just the road: 'QL13, Việt Nam' is 2 components (reject),
        # while 'QL14, Đồng Xoài, Đồng Nai, Việt Nam' names a city (~3 km) —
        # usable but NOT the same thing as a rooftop, so keep the grade.
        tier = 'precise' if ltype in PRECISE else 'district'
        comps = [c.strip() for c in (fmt or '').split(',')]
        if ltype not in PRECISE and len(comps) < 3:
            rejected += 1
            print(f'  [{i}/{len(todo)}] VAGUE  {ltype} {lat:.4f},{lng:.4f} '
                  f'{fmt!r} <- {addr[:34]}')
            continue
        seen_coords.add(ck)
        r0 = group[0]
        focus, typ = focus_of(r0['behaviours'])
        row = {
            'name': addr, 'lat': round(lat, 6), 'lng': round(lng, 6),
            'focus': focus, 'type': typ, 'district': prov,
            'source': 'kiemtraphatnguoi', 'code': r0.get('code'),
            'precision': tier,
            'location_type': ltype, 'formatted_address': fmt,
            'provider': r0['provider'], 'behaviours': r0['behaviours'],
            'violations': sorted({b for g in group for b in g['behaviours']}),
        }
        log.write(json.dumps(row, ensure_ascii=False) + '\n')
        log.flush()
        done[addr] = row
        ok += 1
        print(f'  [{i}/{len(todo)}] OK {prov[:9]:9s} {tier:8s} {ltype[:9]:9s} '
              f'{lat:.4f},{lng:.4f}  {addr[:34]}')
    log.close()

    json.dump(list(done.values()), open(OUT, 'w'), ensure_ascii=False, indent=1)
    print(f'\ncalls {calls} | ok {ok} | rejected {rejected} | miss {miss} | '
          f'total {len(done)} -> {OUT}')


if __name__ == '__main__':
    main()
