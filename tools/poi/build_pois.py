#!/usr/bin/env python3
"""Build assets/offline_map/vietnam_pois.json from the OSM POI GeoJSON.

Keeps "popular" POIs: named places with rich metadata (address, phone,
website, opening_hours, wikipedia, description, stars), plus ALL of the
notable/sparse categories (atm, fuel, hospital, pharmacy, bank, museum,
attraction, station, university, post_office, police, fire_station, ...).
Very large categories (restaurant, cafe, hotel, school, convenience, ...)
are capped per category so the bundled file stays small and search stays fast.
"""
import json
import os
import sys

SRC = os.path.join(os.path.dirname(__file__), 'poi.geojson')
OUT = os.path.join(
    os.path.dirname(__file__), '..', '..', 'assets', 'offline_map',
    'vietnam_pois.json')

# category -> (label_vn, icon_emoji, cap, quality_required)
CATEGORIES = {
    'atm': ('Cây ATM', '🏧', 4000, False),
    'bank': ('Ngân hàng', '🏦', 3000, False),
    'fuel': ('Trạm xăng', '⛽', 6000, False),
    'charging': ('Sạc xe điện', '🔌', 1000, False),
    'restaurant': ('Nhà hàng', '🍽️', 2500, True),
    'cafe': ('Cà phê', '☕', 2500, True),
    'fast_food': ('Ăn nhanh', '🍔', 1500, True),
    'bar': ('Bar / Pub', '🍺', 800, True),
    'hotel': ('Khách sạn', '🏨', 4000, True),
    'hospital': ('Bệnh viện', '🏥', 3000, False),
    'clinic': ('Phòng khám', '🩺', 1500, False),
    'pharmacy': ('Nhà thuốc', '💊', 3000, False),
    'school': ('Trường học', '🏫', 2500, True),
    'university': ('Đại học', '🎓', 1000, False),
    'marketplace': ('Chợ', '🛒', 2500, False),
    'supermarket': ('Siêu thị', '🏪', 2000, True),
    'post_office': ('Bưu điện', '📮', 1000, False),
    'police': ('Công an', '👮', 1200, False),
    'fire_station': ('Cứu hoả', '🚒', 500, False),
    'station': ('Nhà ga', '🚉', 1200, False),
    'bus_station': ('Bến xe', '🚌', 800, False),
    'ferry': ('Bến phà', '⛴️', 800, False),
    'airport': ('Sân bay', '✈️', 100, False),
    'attraction': ('Điểm tham quan', '📸', 2500, False),
    'museum': ('Bảo tàng', '🏛️', 800, False),
}

# OSM tag value -> category key
TAG_TO_CAT = {
    'atm': 'atm', 'bank': 'bank', 'fuel': 'fuel',
    'charging_station': 'charging',
    'restaurant': 'restaurant', 'cafe': 'cafe', 'fast_food': 'fast_food',
    'bar': 'bar', 'pub': 'bar',
    'hotel': 'hotel', 'guest_house': 'hotel', 'hostel': 'hotel',
    'motel': 'hotel',
    'hospital': 'hospital', 'clinic': 'clinic', 'doctors': 'clinic',
    'dentist': 'clinic',
    'pharmacy': 'pharmacy', 'school': 'school', 'university': 'university',
    'college': 'university', 'kindergarten': 'school',
    'marketplace': 'marketplace', 'supermarket': 'supermarket',
    'convenience': 'supermarket', 'mall': 'supermarket',
    'department_store': 'supermarket',
    'post_office': 'post_office', 'police': 'police',
    'fire_station': 'fire_station', 'station': 'station',
    'bus_station': 'bus_station', 'ferry_terminal': 'ferry',
    'aerodrome': 'airport', 'terminal': 'airport',
    'attraction': 'attraction', 'museum': 'museum', 'monument': 'attraction',
    'viewpoint': 'attraction', 'theme_park': 'attraction', 'zoo': 'attraction',
    'gallery': 'museum',
}


def quality_score(props):
    score = 0
    for k in ('website', 'contact:website', 'phone', 'contact:phone',
              'opening_hours', 'wikipedia', 'wikidata', 'description',
              'addr:street', 'addr:housenumber', 'stars', 'brand'):
        if props.get(k):
            score += 1
    return score


def poi_category(props):
    for key in ('amenity', 'tourism', 'shop', 'railway', 'aeroway'):
        v = props.get(key)
        if v and v in TAG_TO_CAT:
            return TAG_TO_CAT[v]
    return None


def main():
    with open(SRC) as f:
        data = json.load(f)

    # cat -> list of entries
    buckets = {c: [] for c in CATEGORIES}
    for ft in data['features']:
        p = ft['properties']
        name = (p.get('name') or '').strip()
        if not name:
            continue
        cat = poi_category(p)
        if cat is None or cat not in CATEGORIES:
            continue
        # Geometry: Point or Polygon (centroid-ish first coord).
        geo = ft.get('geometry') or {}
        coords = geo.get('coordinates')
        if not coords:
            continue
        if geo.get('type') == 'Point':
            lon, lat = coords[0], coords[1]
        elif geo.get('type') == 'Polygon':
            lon, lat = coords[0][0][0], coords[0][0][1]
        else:
            continue
        # Quality gate: some categories only keep POIs with metadata so the
        # bundled file stays small and "popular".
        if CATEGORIES[cat][3] and quality_score(p) < 2:
            continue
        entry = {
            'n': name,
            'lat': round(lat, 5),
            'lng': round(lon, 5),
        }
        # Optional rich fields (info card).
        addr_parts = [p.get('addr:housenumber'), p.get('addr:street'),
                      p.get('addr:city')]
        addr = ', '.join(x for x in addr_parts if x)
        if addr:
            entry['a'] = addr
        for k in ('phone', 'contact:phone'):
            if p.get(k):
                entry['ph'] = p[k]
                break
        if p.get('opening_hours'):
            entry['oh'] = p['opening_hours']
        if p.get('description'):
            entry['d'] = p['description'][:200]
        if p.get('wikipedia'):
            entry['w'] = p['wikipedia']
        elif p.get('wikidata'):
            entry['w'] = 'wikidata:' + p['wikidata']
        if p.get('website') or p.get('contact:website'):
            entry['ws'] = p.get('website') or p.get('contact:website')
        buckets[cat].append((quality_score(p), entry))

    # Sort each bucket by quality (best first), then cap.
    result = {}
    total = 0
    for cat, (label, emoji, cap, _) in CATEGORIES.items():
        items = buckets[cat]
        items.sort(key=lambda x: -x[0])
        capped = [e for _, e in items[:cap]]
        result[cat] = {'label': label, 'emoji': emoji, 'items': capped}
        total += len(capped)
        print(f'{cat:14s} {len(capped):6d} (raw {len(items)})')

    with open(OUT, 'w') as f:
        json.dump(result, f, ensure_ascii=False, separators=(',', ':'))
    print(f'\nTOTAL: {total} POIs -> {OUT} ({os.path.getsize(OUT)/1e6:.2f} MB)')


if __name__ == '__main__':
    main()
