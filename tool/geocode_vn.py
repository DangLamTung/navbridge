#!/usr/bin/env python3
"""Geocode the nationwide kiemtraphatnguoi list with Google, then filter.

Two phases on purpose:

  --crawl-check / (default = crawl)   call Google, log EVERY answer raw
  --build                             apply the filters, write the final JSON

Splitting them means a filter change costs nothing: the expensive part is
already on disk in the resume log.

Filter ladder (each rejected point is printed with its reason):
  1. Google status/geometry only — no hit or a whole-road collapse goes out.
  2. precision tier — ROOFTOP / RANGE_INTERPOLATED are 'precise'; a coarser hit
     is 'district' only if Google named something below the province
     ('QL13, Việt Nam' is just the road, and is dropped).
  3. same 4-dp coordinate claimed twice — two cameras cannot share a point.
  4. province sanity — Google's own administrative_area_level_1 must match the
     province the row was listed under (allowing the 2025 merged names), and the
     point must be within 250 km of that province's median point.

    python3 tool/geocode_vn.py --dry       # how many calls, spends nothing
    python3 tool/geocode_vn.py --limit 30  # sample
    python3 tool/geocode_vn.py             # whole country (resumable)
    python3 tool/geocode_vn.py --build
"""
import argparse
import collections
import json
import math
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from geocode_dongnai import clean_addr, focus_of, pinnable   # noqa: E402
from geocode_google import PRECISE, api_key                  # noqa: E402

SRC = 'tool/data/vn_cams_source.json'
RAW = 'tool/data/vn_cams_raw.jsonl'       # every Google answer, resumable
OUT = 'tool/data/vn_cams_geo.json'        # filtered result

# The listings use the post-2025 province names; Google may still answer with
# the pre-merger name, so a hit is accepted if either appears.
ALIAS = {
    'an-giang': ('an giang', 'kien giang'),
    'bac-ninh': ('bac ninh', 'bac giang'),
    'ca-mau': ('ca mau', 'bac lieu'),
    'can-tho': ('can tho', 'soc trang', 'hau giang'),
    'cao-bang': ('cao bang',),
    'da-nang': ('da nang', 'quang nam'),
    'dak-lak': ('dak lak', 'dak lak', 'phu yen'),
    'dien-bien': ('dien bien',),
    'dong-nai': ('dong nai', 'binh phuoc'),
    'dong-thap': ('dong thap', 'tien giang'),
    'gia-lai': ('gia lai', 'binh dinh'),
    'ha-noi': ('ha noi',),
    'ha-tinh': ('ha tinh', 'quang binh'),
    'hai-phong': ('hai phong', 'hai duong'),
    'hue': ('hue', 'thua thien hue'),
    'hung-yen': ('hung yen', 'thai binh'),
    'khanh-hoa': ('khanh hoa', 'ninh thuan'),
    'lam-dong': ('lam dong', 'lam dong', 'binh thuan'),
    'lang-son': ('lang son',),
    'lao-cai': ('lao cai', 'yen bai'),
    'nghe-an': ('nghe an',),
    'ninh-binh': ('ninh binh', 'nam dinh', 'ha nam'),
    'phu-tho': ('phu tho', 'vinh phuc', 'hoa binh'),
    'quang-ngai': ('quang ngai', 'kon tum'),
    'quang-ninh': ('quang ninh',),
    'quang-tri': ('quang tri', 'quang binh'),
    'son-la': ('son la',),
    'tay-ninh': ('tay ninh', 'long an'),
    'thai-nguyen': ('thai nguyen', 'bac kan'),
    'thanh-hoa': ('thanh hoa',),
    'tp-ho-chi-minh': ('ho chi minh', 'binh duong', 'ba ria vung tau'),
    'tuyen-quang': ('tuyen quang', 'ha giang'),
    'vinh-long': ('vinh long', 'ben tre', 'tra vinh'),
}


def fold(s):
    # NFD does NOT decompose đ/Đ (it is a distinct letter, not a base+mark),
    # so without this replacement 'Đà Nẵng' folds to 'đa nang' and never matches
    # the slug alias 'da nang' — that rejected 113 perfectly good Đà Nẵng rows.
    s = (s or '').replace('đ', 'd').replace('Đ', 'D')
    s = unicodedata.normalize('NFD', s)
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return re.sub(r'\s+', ' ', s.lower()).strip()


def geocode_full(addr, key, tries=3):
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
        except Exception as e:                                  # noqa: BLE001
            if n == tries - 1:
                return {'status': 'TRANSPORT_ERROR', 'error': str(e)[:120]}
            time.sleep(1.5 * (n + 1))
            continue
        st = j.get('status')
        if st in ('OVER_QUERY_LIMIT', 'OVER_DAILY_LIMIT', 'REQUEST_DENIED'):
            sys.exit(f'Google says {st}: {j.get("error_message")}')
        if st in ('UNKNOWN_ERROR', 'RESOURCE_EXHAUSTED') and n < tries - 1:
            time.sleep(1.5 * (n + 1))
            continue
        if st != 'OK' or not j.get('results'):
            return {'status': st}
        r0 = j['results'][0]
        # a component with an empty `types` array really happens; indexing it
        # blindly crashed the crawl at answer 617
        comp = {c['types'][0]: c.get('long_name', '')
                for c in r0.get('address_components', []) if c.get('types')}
        return {'status': 'OK',
                'lat': r0['geometry']['location']['lat'],
                'lng': r0['geometry']['location']['lng'],
                'location_type': r0['geometry'].get('location_type') or '',
                'formatted_address': r0.get('formatted_address'),
                'g_province': comp.get('administrative_area_level_1', ''),
                'g_commune': (comp.get('administrative_area_level_3')
                              or comp.get('administrative_area_level_4') or '')}
    return {'status': 'RETRIES_EXHAUSTED'}


def load_raw():
    done = {}
    if os.path.exists(RAW):
        for line in open(RAW, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            done[(r['addr'], r['province'])] = r
    return done


def dist_km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(min(1.0, h)))


def build():
    raw = load_raw()
    print(f'raw answers: {len(raw)}')
    ok = [r for r in raw.values() if r.get('status') == 'OK']
    print(f'status OK  : {len(ok)}')

    # per-province median point, from precise hits only — self-calibrating, so
    # no polygon files are needed for 33 provinces
    by_prov = collections.defaultdict(list)
    for r in ok:
        if r['location_type'] in PRECISE:
            by_prov[r['province']].append((r['lat'], r['lng']))
    med = {}
    for p, pts in by_prov.items():
        if len(pts) < 3:
            continue
        la = sorted(x[0] for x in pts)[len(pts) // 2]
        ln = sorted(x[1] for x in pts)[len(pts) // 2]
        med[p] = (la, ln)

    out, seen, why = [], {}, collections.Counter()
    for r in sorted(ok, key=lambda x: (x['province'], x['addr'])):
        slug = r['province']
        lt = r['location_type']
        comps = [c for c in (r['formatted_address'] or '').split(',') if c.strip()]
        if lt not in PRECISE and len(comps) < 3:
            why['vague (road only)'] += 1
            continue
        ck = (round(r['lat'], 4), round(r['lng'], 4))
        if ck in seen:
            why['duplicate coordinate'] += 1
            continue
        gp = fold(r.get('g_province', ''))
        alias = ALIAS.get(slug, (slug.replace('-', ' '),))
        if gp and not any(a in gp or gp in a for a in alias):
            why[f'wrong province ({r.get("g_province")})'] += 1
            continue
        if slug in med:
            d = dist_km(r['lat'], r['lng'], *med[slug])
            if d > 250:
                why[f'outlier {d:.0f} km'] += 1
                continue
        seen[ck] = True
        focus, typ = focus_of(r.get('behaviours', []))
        out.append({
            'name': r['addr'], 'lat': round(r['lat'], 6),
            'lng': round(r['lng'], 6), 'focus': focus, 'type': typ,
            'district': slug, 'source': 'kiemtraphatnguoi',
            'code': r.get('code'),
            'precision': 'precise' if lt in PRECISE else 'district',
            'location_type': lt, 'formatted_address': r['formatted_address'],
            'provider': r.get('provider', ''),
            'behaviours': r.get('behaviours', []),
        })

    json.dump(out, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print(f'\naccepted {len(out)} -> {OUT}')
    print('precise:', sum(1 for r in out if r['precision'] == 'precise'),
          ' district:',
          sum(1 for r in out if r['precision'] == 'district'))
    for k, v in why.most_common(12):
        print(f'  dropped {v:5d}  {k}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--only', default='')
    a = ap.parse_args()

    if a.build:
        build()
        return

    rows = json.load(open(SRC, encoding='utf-8'))
    uniq = {}
    for r in rows:
        a_ = clean_addr(r['addr'])
        uniq.setdefault((a_, r['province']), r)
    done = load_raw()
    todo = [k for k in uniq if k not in done and pinnable(k[0])]
    if a.only:
        todo = [k for k in todo if k[1] in a.only.split(',')]
    print(f'{"rows":>16}: {len(rows)}')
    print(f'{"unique":>16}: {len(uniq)}')
    print(f'{"already asked":>16}: {len(done)}')
    print(f'{"to call":>16}: {len(todo)}')
    if a.dry:
        return

    key = api_key()
    if a.limit:
        todo = todo[:a.limit]
    log = open(RAW, 'a', encoding='utf-8')
    for i, (addr, slug) in enumerate(todo, 1):
        r0 = uniq[(addr, slug)]
        res = geocode_full(addr, key)
        rec = {'addr': addr, 'province': slug, 'code': r0.get('code'),
               'provider': r0.get('provider', ''),
               'behaviours': r0.get('behaviours', []), **res}
        log.write(json.dumps(rec, ensure_ascii=False) + '\n')
        log.flush()
        if res.get('status') == 'OK':
            print(f'  [{i}/{len(todo)}] {slug[:14]:14s} '
                  f'{(res["location_type"] or "?")[:9]:9s} {res["lat"]:.4f},'
                  f'{res["lng"]:.4f}  {addr[:38]}')
        else:
            print(f'  [{i}/{len(todo)}] {slug[:14]:14s} {res["status"]:9s} '
                  f'{addr[:44]}')
    log.close()
    print(f'\ndone — run --build to filter')


if __name__ == '__main__':
    main()
