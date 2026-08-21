#!/usr/bin/env python3
"""Build assets/offline_map/vietnam_signs.json from OSM Overpass.

Downloads Vietnam's road-sign nodes — traffic lights
(highway=traffic_signals), stop signs (traffic_sign=stop / highway=stop) and
give-way signs (traffic_sign=give_way / highway=give_way) — and writes a
compact JSON the app loads offline (the same pattern as
vietnam_cameras.json / vietnam_pois.json).

The sign *kind* is what the app cares about (stop / giveWay / signal); the
physical sign is mapped many ways in OSM (traffic_sign=stop,
traffic_sign:forward=stop, highway=stop, ...), so we match them all.

Usage: python3 tools/signs/build_signs.py
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

OUT = os.path.join(
    os.path.dirname(__file__), '..', '..', 'assets', 'offline_map',
    'vietnam_signs.json')

# Vietnam bounding box (south, west, north, east).
BBOX = '8.2,102.1,23.4,109.5'

ENDPOINTS = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.osm.ch/api/interpreter',
]

LABELS = {
    'stop': 'Biển STOP',
    'giveWay': 'Biển nhường đường',
    'speed': 'Hạn chế tốc độ',
    'populated': 'Khu đông dân cư',
    'signal': 'Đèn giao thông',
}


def parse_maxspeed(raw):
    """km/h from a maxspeed tag value ("50", "50 km/h", "30 mph"), or
    None for implicit/none (no number to show on the sign)."""
    if not raw:
        return None
    s = str(raw).lower()
    if s in ('implicit', 'none', 'signals', 'unknown'):
        return None
    m = re.search(r'(\d+)', s)
    if not m:
        return None
    v = int(m.group(1))
    return v if 5 <= v <= 200 else None


def overpass(query, timeout=300):
    body = urllib.parse.urlencode({'data': query}).encode()
    last = None
    for ep in ENDPOINTS:
        try:
            req = urllib.request.Request(
                ep, data=body,
                headers={'User-Agent': 'navbridge-signs-builder/1.0'})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 — try the next mirror
            last = e
    raise SystemExit(f'Overpass query failed on all mirrors: {last}')


def kind_for(tags):
    """Returns (kind, value) for a node's tags, or (None, None) to skip.
    The physical sign is mapped many ways in OSM (traffic_sign=stop,
    traffic_sign:forward=stop, highway=stop, ...), so we match them all."""
    if tags.get('highway') == 'traffic_signals':
        return 'signal', None
    if tags.get('highway') == 'stop':
        return 'stop', None
    if tags.get('highway') == 'give_way':
        return 'giveWay', None
    ts = (
        tags.get('traffic_sign')
        or tags.get('traffic_sign:forward')
        or tags.get('traffic_sign:backward')
        or tags.get('traffic_sign:direction')
        or ''
    )
    ts = ts.lower()
    # Speed-limit sign → carry the km/h value so the icon can show it.
    if 'maxspeed' in ts:
        val = parse_maxspeed(tags.get('maxspeed'))
        return ('speed', val) if val else (None, None)
    # "Khu đông dân cư" / city-limit sign.
    if 'city_limit' in ts:
        return 'populated', None
    if 'stop' in ts and 'stop_ahead' not in ts:
        return 'stop', None
    if 'give_way' in ts or 'yield' in ts:
        return 'giveWay', None
    return None, None


def main():
    node_query = (
        f'[out:json][timeout:300];'
        f'(node["highway"="traffic_signals"]({BBOX});'
        f'node["traffic_sign"]({BBOX});'
        f'node["highway"="stop"]({BBOX});'
        f'node["highway"="give_way"]({BBOX}););'
        # `center` makes nodes include lat/lon (plain `out tags` drops them).
        f'out tags center;'
    )
    print('fetching Overpass nodes (Vietnam bbox)...')
    data = overpass(node_query)
    seen = set()
    signs = []
    for el in data.get('elements', []):
        if el.get('type') != 'node':
            continue
        lat = el.get('lat')
        lon = el.get('lon')
        if lat is None or lon is None:
            continue
        kind, value = kind_for(el.get('tags') or {})
        if not kind:
            continue
        key = (round(lat, 5), round(lon, 5), kind, value)
        if key in seen:
            continue
        seen.add(key)
        entry = {
            'name': LABELS[kind],
            'lat': round(lat, 6),
            'lng': round(lon, 6),
            'kind': kind,
        }
        if value is not None:
            entry['value'] = value
        signs.append(entry)

    # Vietnam has almost no real sign NODES (checked: ~11k total), so derive
    # SPEED-LIMIT signs from ways with a real posted `maxspeed` (explicitly
    # sign-posted via source:maxspeed=sign, or major roads with a limit).
    # The marker sits at the way's centre — the VALUE (the posted limit) is
    # real, which is what the driver cares about. Best-effort: if this query
    # fails we keep the node signs.
    try:
        way_query = (
            f'[out:json][timeout:300];'
            f'(way["highway"]["maxspeed"]["source:maxspeed"~"sign"]({BBOX});'
            f'way["highway"~"motorway|trunk|primary|secondary"]["maxspeed"]'
            f'({BBOX}););'
            f'out tags center;'
        )
        print('fetching Overpass way-derived speed signs...')
        wdata = overpass(way_query)
        for el in wdata.get('elements', []):
            if el.get('type') != 'way':
                continue
            c = el.get('center')
            if not c:
                continue
            lat, lon = c.get('lat'), c.get('lon')
            if lat is None or lon is None:
                continue
            val = parse_maxspeed((el.get('tags') or {}).get('maxspeed'))
            if not val:
                continue
            key = (round(lat, 4), round(lon, 4), 'speed', val)
            if key in seen:
                continue
            seen.add(key)
            signs.append({
                'name': LABELS['speed'],
                'lat': round(lat, 6),
                'lng': round(lon, 6),
                'kind': 'speed',
                'value': val,
            })
    except Exception as e:  # noqa: BLE001 — keep the node signs
        print(f'warning: way-derived speed signs failed: {e}')

    signs.sort(key=lambda s: (s['lat'], s['lng']))
    out = {
        'version': '1.2',
        'generated': int(time.time()),
        'signs': signs,
    }
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
    size = os.path.getsize(OUT) / 1024
    from collections import Counter
    kinds = Counter(s['kind'] for s in signs)
    print(f'wrote {len(signs)} signs to {OUT} ({size:.0f} KB) kinds={dict(kinds)}')


if __name__ == '__main__':
    main()
