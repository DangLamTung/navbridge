#!/usr/bin/env python3
"""Scrape every province's camera list from kiemtraphatnguoi.com.

The site is Next.js App Router: the HTML carries no table, the rows live in
`self.__next_f.push([1,"<json-escaped-string>"])` chunks. Reassemble those,
then split on the row marker `"className":"camera-item"`.

Output: tool/data/vn_cams_source.json  (one entry per published CAMERA SITE —
the same camera appears once per violation type, so duplicates are expected
here and are collapsed later by the geocoder).

    python3 tool/scrape_kiemtraphatnguoi.py               # all provinces
    python3 tool/scrape_kiemtraphatnguoi.py --only ha-noi,dong-nai
    python3 tool/scrape_kiemtraphatnguoi.py --refresh      # ignore HTML cache
"""
import argparse
import collections
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://kiemtraphatnguoi.com/camera-phat-nguoi'
UA = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/124.0 Safari/537.36',
      'Accept-Language': 'vi,en;q=0.8'}
CACHE = '/tmp/kn'
OUT = 'tool/data/vn_cams_source.json'

# every slug the index page links to (fetched 2026-10-21)
SLUGS = [
    'an-giang', 'bac-ninh', 'ca-mau', 'can-tho', 'cao-bang', 'da-nang',
    'dak-lak', 'dien-bien', 'dong-nai', 'dong-thap', 'gia-lai', 'ha-noi',
    'ha-tinh', 'hai-phong', 'hue', 'hung-yen', 'khanh-hoa', 'lam-dong',
    'lang-son', 'lao-cai', 'nghe-an', 'ninh-binh', 'phu-tho', 'quang-ngai',
    'quang-ninh', 'quang-tri', 'son-la', 'tay-ninh', 'thai-nguyen',
    'thanh-hoa', 'tp-ho-chi-minh', 'tuyen-quang', 'vinh-long',
]


def fetch(slug, page, refresh=False):
    os.makedirs(CACHE, exist_ok=True)
    path = f'{CACHE}/{slug}_{page:03d}.html'
    if not refresh and os.path.exists(path) and os.path.getsize(path) > 5000:
        return open(path, encoding='utf-8', errors='replace').read()
    url = f'{BASE}/{slug}' + ('' if page == 1 else f'?page={page}')
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=90) as r:
                html = r.read().decode('utf-8', 'replace')
            open(path, 'w', encoding='utf-8').write(html)
            return html
        except urllib.error.HTTPError as e:
            if e.code == 404:              # past the last page, not an error
                raise
            if attempt == 2:
                raise
            print(f'  {slug} p{page}: HTTP {e.code}, retry')
            time.sleep(2 * (attempt + 1))
        except Exception as e:                                  # noqa: BLE001
            if attempt == 2:
                raise
            print(f'  {slug} p{page}: {type(e).__name__}, retry')
            time.sleep(2 * (attempt + 1))


def rsc(html):
    """Reassemble the streamed RSC payload into one string."""
    out = []
    for c in re.findall(r'self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)',
                        html):
        try:
            out.append(json.loads(c))
        except ValueError:
            pass
    return ''.join(out)


def unesc(s):
    try:
        return json.loads('"' + s + '"')
    except ValueError:
        return s


def parse_page(html):
    text = rsc(html)
    rows = []
    for part in text.split('"className":"camera-item"')[1:]:
        addr = re.search(r'camera-item__addr","children":"((?:[^"\\]|\\.)*)"',
                         part)
        if not addr:
            continue
        a = unesc(addr.group(1)).strip()
        prov = re.search(
            r'camera-item__provider","children":"((?:[^"\\]|\\.)*)"', part)
        beh = re.search(r'camera-item__behaviors","children":\[(.*?)\]\}\]',
                        part, re.S)
        q = re.search(r'query=([^"&]+)', part)
        code = re.search(r'\(([A-Z0-9._-]{4,})\)\s*$', a)
        rows.append({
            'addr': a,
            'code': code.group(1) if code else None,
            'provider': unesc(prov.group(1)).strip() if prov else '',
            'behaviours': re.findall(
                r'"children":"((?:[^"\\]|\\.)*)"', beh.group(1)) if beh else [],
            'map_query': urllib.parse.unquote(q.group(1)) if q else None,
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='')
    ap.add_argument('--refresh', action='store_true')
    ap.add_argument('--max-pages', type=int, default=60)
    a = ap.parse_args()

    slugs = [s.strip() for s in a.only.split(',') if s.strip()] or SLUGS
    out = []
    per = collections.Counter()
    for slug in slugs:
        seen = set()
        got = 0
        for page in range(1, a.max_pages + 1):
            try:
                rows = parse_page(fetch(slug, page, a.refresh))
            except urllib.error.HTTPError as e:
                if e.code == 404:          # past the last page — normal end
                    break
                print(f'  {slug} p{page}: HTTP {e.code}')
                break
            except Exception as e:                              # noqa: BLE001
                print(f'  {slug} p{page}: FAILED {type(e).__name__}: {e}')
                break
            fresh = 0
            for r in rows:
                if r['addr'] in seen:
                    continue
                seen.add(r['addr'])
                r['province'] = slug
                out.append(r)
                fresh += 1
            got += fresh
            if not rows or fresh == 0:
                break
            time.sleep(0.6)
        per[slug] = got
        print(f'{slug:16s} {got:5d} rows')

    json.dump(out, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print(f'\n{OUT}: {len(out)} rows from {len(slugs)} provinces')
    for slug, n in per.most_common(8):
        print(f'  {n:5d}  {slug}')


if __name__ == '__main__':
    main()
