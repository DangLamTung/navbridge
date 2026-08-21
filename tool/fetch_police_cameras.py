#!/usr/bin/env python3
"""Fetch provincial police "phạt nguội" camera lists from kiemtraphatnguoi.com
(which cites the official Cục CSGT / Cục Đăng kiểm data), extract each camera
location, geocode it, and merge into vietnam_cameras.json.

The location text comes from each "Xem trên Google Maps" link's `query=` — a
short factual road/km/place description. Geocoding order:
  1. Vietmap autocomplete→place (the app's own VIETMAP_API_KEY from .env,
     Vietnamese-native, free with our key) — best for 'km 260 QL1A, Xã …'.
  2. Google Maps Geocoding API (GOOGLE_MAPS_API_KEY env var, optional).
  3. Free geocoders (Nominatim/Photon) as a rough fallback.

Usage:
    python3 tool/fetch_police_cameras.py --province ninh-binh [--write]
    python3 tool/fetch_police_cameras.py --batch "a b c" --write
"""
import argparse
import html
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://kiemtraphatnguoi.com/camera-phat-nguoi"
ASSET = "assets/offline_map/vietnam_cameras.json"
UA = {"User-Agent": "NavBridge-camera-tool/1.0 (data from official police portal)"}

# Provinces we already have solid coverage for (skip).
SKIP = {
    "tp-ho-chi-minh", "ha-noi", "da-nang", "hai-phong", "can-tho", "hue",
    "an-giang", "thanh-hoa", "binh-dinh", "binh-duong", "binh-phuoc",
    "cao-bang", "dak-lak", "dien-bien", "quang-binh", "quang-nam",
    "soc-trang", "thai-nguyen", "ha-giang", "quang-tri", "lam-dong",
    "nghe-an", "khanh-hoa", "gia-lai", "dong-thap", "phu-yen", "ha-tinh",
    "vinh-long", "thai-binh", "hai-duong", "binh-thuan", "tra-vinh",
    "yen-bai", "phu-tho", "ca-mau", "hau-giang", "lang-son", "dak-nong",
    "bac-lieu", "ben-tre", "kon-tum", "hoa-binh", "son-la", "bac-kan",
    "lao-cai", "kien-giang", "tien-giang", "quang-ngai",
}


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def extract_locations(page_html):
    """Pull every camera location. The full description lives in the button
    title ('Xem <loc> trên Google Maps'); fall back to the (often truncated)
    maps query when no title is present."""
    locs = []
    for m in re.finditer(r'title="Xem ([^"]+) trên Google Maps"', page_html):
        q = html.unescape(m.group(1)).strip()
        q = re.sub(r'\s+', ' ', q)
        if q and q not in locs:
            locs.append(q)
    for m in re.finditer(r'google\.com/maps/search/\?api=1&amp;query=([^"]+)', page_html):
        q = html.unescape(urllib.parse.unquote(m.group(1))).strip()
        if q and q not in locs:
            locs.append(q)
    return locs


def clean_for_geocode(loc):
    """Text geocoders choke on 'km 315+500' prefixes — strip the km noise but
    keep the road + place names (commune/district/city) that DO resolve."""
    s = re.sub(r'\bkm\s*\d+[\d]*(?:\+\d+)?\s*[+,.;]?\s*', '', loc, flags=re.I)
    s = re.sub(r'\s{2,}', ' ', s).strip(' ,.;')
    return s


def read_vietmap_key():
    """Read VIETMAP_API_KEY from the local (gitignored) .env. Never printed."""
    try:
        for line in open(".env"):
            m = re.match(r"VIETMAP_API_KEY=(.*)", line.strip())
            if m:
                return m.group(1).strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return os.environ.get("VIETMAP_API_KEY", "").strip() or None


# Vietmap autocomplete/place is a search API with strict per-second limits;
# bulk callers get HTTP 429. Space every request and back off when throttled.
# VM_BUDGET caps total requests for the day (user quota ~300).
VM_INTERVAL = 0.4  # ~150 req/min, under Vietmap's 200/min cap (daily ~1500)
_last_call = [0.0]
VM_BUDGET = {"used": 0, "max": 0}
_budget_warned = [False]


def _vm_get(url, retries=4):
    """Throttled Vietmap GET with 429 backoff and a hard request budget.
    Returns parsed JSON or None (None also when budget is exhausted)."""
    def exhausted():
        if VM_BUDGET["max"] > 0 and VM_BUDGET["used"] >= VM_BUDGET["max"]:
            if not _budget_warned[0]:
                print(f"[vietmap] BUDGET EXHAUSTED after {VM_BUDGET['used']} req",
                      flush=True)
                _budget_warned[0] = True
            return True
        return False
    if exhausted():
        return None
    delay = _last_call[0] + VM_INTERVAL - time.time()
    if delay > 0:
        time.sleep(delay)
    for attempt in range(retries):
        if exhausted():
            return None
        _last_call[0] = time.time()
        VM_BUDGET["used"] += 1
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = 15 * (attempt + 1)
                print(f"  [vietmap 429] backoff {wait}s (attempt {attempt + 1})",
                      flush=True)
                time.sleep(wait)
                continue
            raise
        except Exception:
            time.sleep(3)
            continue
    return None


def _norm(s):
    """NFC-normalize + collapse all whitespace (incl. non-breaking spaces, which
    Vietmap uses between words) to plain single spaces. ASCII substring checks
    (e.g. 'ninh binh' in 'Ninh Bình') then work reliably."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(s))).strip()


def _ascii(s):
    """Strip Vietnamese diacritics so 'Bình' == 'binh' when matching."""
    nfkd = unicodedata.normalize("NFKD", str(s))
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _prov_norm(s):
    """Normalize province names for matching. The API writes 'Thành phố Hồ Chí
    Minh' while our canonical name is 'TP Hồ Chí Minh' (and pages use 'HCM'), so
    'tp'/'hcm' are expanded — otherwise every HCMC camera fails the province
    check."""
    a = _ascii(s).lower()
    a = re.sub(r"\btp\b", "thanh pho", a)
    a = re.sub(r"\bhcm\b", "ho chi minh", a)
    return a


def geocode_vietmap(loc, province):
    """Geocode via Vietmap search → place (same flow the app uses for search;
    search/v4 returns precise house-number/address matches). Returns (lat, lng)
    or None. We reject any hit not in the target province so we never merge a
    wrong-province point."""
    key = read_vietmap_key()
    if not key:
        return None
    prov = _prov_norm(province)
    # ONE variant only to conserve the daily request budget (1 autocomplete +
    # up to 2 place calls ≈ ≤3 req/entry). The full 'loc, province' string
    # resolved best in testing.
    variants = [f"{loc}, {province}"]
    qwords = {w.lower() for w in re.findall(
        r"\w{4,}", _norm(clean_for_geocode(loc)))}
    for q in variants:
        if not q.strip():
            continue
        try:
            res = _vm_get("https://maps.vietmap.vn/api/search/v4?apikey="
                           + key + "&text=" + urllib.parse.quote(q))
        except Exception as e:  # noqa
            print(f"  vietmap search fail: {q[:60]} {type(e).__name__}")
            continue
        if not isinstance(res, list) or not res:
            continue
        best = None
        # Top-1 candidate only — minimum calls inside the ~300 req/day budget.
        for e in res[:1]:
            ref = e.get("ref_id")
            if not ref:
                continue
            # The autocomplete entry already carries address/display — reject a
            # wrong-province hit BEFORE spending a place call (biggest budget
            # saver: most km-marker top matches are out-of-province POIs).
            e_text = _norm(str(e.get("display") or "") + " "
                           + str(e.get("address") or "")).lower()
            if prov not in _prov_norm(e_text):
                continue
            try:
                p = _vm_get("https://maps.vietmap.vn/api/place/v4?apikey="
                             + key + "&refid=" + urllib.parse.quote(ref))
            except Exception:
                continue
            if p is None:
                continue
            lat = p.get("lat") if isinstance(p, dict) else None
            lng = p.get("lng") if isinstance(p, dict) else None
            if lat is None or lng is None:
                continue
            text = _norm((str(p.get("display") or p.get("name") or "") + " "
                         + str(p.get("address") or "")).lower())
            # Diacritic-insensitive province match — 'Bình' vs 'binh', and
            # 'TP HCM' vs 'Thành phố Hồ Chí Minh'. Without this we reject
            # every hit (the #1 silent failure we hit).
            if prov not in _prov_norm(text):
                continue
            score = 5 + sum(1 for w in qwords if w in text)
            if best is None or score > best[0]:
                best = (score, float(lat), float(lng))
        if best:
            return best[1], best[2]
    return None


# Tokens that pin a location to a small, defensible area (neighbourhood/
# commune/ward/intersection). A bare road name or km-marker does NOT pin — it
# collapses to one arbitrary point on the road, so those entries are skipped.
PINNING = ("phường ", "xã ", "thị trấn", "thị xã", "ngã ba", "ngã tư",
           "nga ba", "nga tu", "cầu ", "ga ", "bến ", "ngã 3", "ngã 4",
           "ngã 5", "ngã 6", "ngã 7", "nga 3", "nga 4", "nga 5",
           "nga 6", "nga 7")


def is_mergeable(loc):
    """True if the entry pins to a distinct location. Bare km-markers
    ('km284, Cao tốc …') collapse to one road point, so they're excluded — but
    we ALSO accept street addresses (house numbers), street-pair intersections,
    abbreviated wards (P./X./TT/TX) and named landmarks, which the strict
    token list alone would wrongly drop."""
    s = _norm(clean_for_geocode(loc)).lower()
    if any(t in s for t in PINNING):
        return True
    # abbreviated ward/commune/town: 'P. Tân Hưng', 'X. Long Thành', 'TT Cầu Gồ'
    if re.search(r"\b(p|x|tt|tx)\b\s*\.?\s*[a-z\u00e0-\u1ef9]", s):
        return True
    # house-number street address: '469 Nguyễn Hữu Thọ' or 'Đối diện 142 …'
    # (clean_for_geocode already stripped any 'km 40' prefix, so a leading
    # number here is a real house number, not a km marker)
    if re.match(r"^\s*(s\u1ed1|so)?\s*\d{1,4}\b", s):
        return True
    if re.search(r"\b(s\u1ed1|so|\u0111\u1ed1i di\u1ec7n|doi dien|c\u1ea1nh|canh|g\u1ea7n|gan)\s+\d{1,4}\b", s):
        return True
    # street-pair intersection: 'Lê Văn Lương - Hoàng Đạo Thuý' (2-char names
    # like 'lý' are common, so {2,} not {3,})
    if re.search(r"[a-z\u00e0-\u1ef9]{2,}\s*[-\u2013\u2014]\s*[a-z\u00e0-\u1ef9]{2,}", s):
        return True
    # named landmarks: hospitals, schools, markets, stations, airports
    if re.search(r"\b(b\u1ec7nh vi\u1ec7n|benh vien|tr\u01b0\u1eddng|truong|ch\u1ee3|cho|ga|c\u1ea3ng|cang|s\u00e2n bay|san bay)\b", s):
        return True
    return False


# All Vietnamese provinces & centrally-run cities. The site's pages frequently
# list cameras from OTHER provinces too (e.g. Bắc Giang cameras on the Bắc Ninh
# page), so we detect the real province from the entry text instead of trusting
# the page slug.
PROVINCES = [
    "An Giang", "Bà Rịa - Vũng Tàu", "Bạc Liêu", "Bắc Giang", "Bắc Kạn",
    "Bắc Ninh", "Bến Tre", "Bình Dương", "Bình Định", "Bình Phước",
    "Bình Thuận", "Cà Mau", "Cao Bằng", "Cần Thơ", "Đà Nẵng", "Đắk Lắk",
    "Đắk Nông", "Điện Biên", "Đồng Nai", "Đồng Tháp", "Gia Lai",
    "Hà Giang", "Hà Nam", "Hà Nội", "Hà Tĩnh", "Hải Dương", "Hải Phòng",
    "Hậu Giang", "Hòa Bình", "Hưng Yên", "Khánh Hòa", "Kiên Giang",
    "Kon Tum", "Lai Châu", "Lâm Đồng", "Lạng Sơn", "Lào Cai", "Long An",
    "Nam Định", "Nghệ An", "Ninh Bình", "Ninh Thuận", "Phú Thọ",
    "Phú Yên", "Quảng Bình", "Quảng Nam", "Quảng Ngãi", "Quảng Ninh",
    "Quảng Trị", "Sóc Trăng", "Sơn La", "Tây Ninh", "Thái Bình",
    "Thái Nguyên", "Thanh Hóa", "Thừa Thiên Huế", "Tiền Giang",
    "TP Hồ Chí Minh", "Trà Vinh", "Tuyên Quang", "Vĩnh Long", "Vĩnh Phúc",
    "Yên Bái",
]
# ASCII-normalized province name -> canonical name (longest-first matching so
# 'Thừa Thiên Huế' wins over a bare 'Huế').
_PROV_INDEX = {_ascii(p).lower(): p for p in PROVINCES}
_PROV_KEYS = sorted(_PROV_INDEX, key=len, reverse=True)


def detect_province(loc):
    """Return the canonical Vietnamese province/city named in the entry text
    (e.g. '… Tỉnh Bắc Giang' → 'Bắc Giang'), or None if none is found."""
    a = _ascii(loc).lower()
    for key in _PROV_KEYS:
        if key in a:
            return _PROV_INDEX[key]
    return None


# slug -> canonical province name ('bac-ninh' -> 'Bắc Ninh') so cross-province
# fallback labels are never ASCII/title-cased.
SLUG_TO_PROV = {}
for _p in PROVINCES:
    SLUG_TO_PROV[re.sub(r"[^a-z0-9]+", "-", _ascii(_p).lower()).strip("-")] = _p


def province_label(slug):
    return SLUG_TO_PROV.get(slug, slug.replace("-", " ").title())


def canon_province(name):
    """Map any province-name variant ('Dong Nai', 'dong-nai', 'Đồng Nai') to the
    canonical Vietnamese form, so the same province never appears under two
    spellings in the cache/DB."""
    a = _ascii(name).strip().lower()
    for canon in PROVINCES:
        if a == _ascii(canon).strip().lower():
            return canon
    slug = re.sub(r"[^a-z0-9]+", "-", a).strip("-")
    return SLUG_TO_PROV.get(slug, name)


def gm_url(loc):
    """The Google Maps search link for a location text (the link style the site
    itself uses), so each camera can be opened/verified on Google Maps."""
    return "https://www.google.com/maps/search/?api=1&query=" \
        + urllib.parse.quote(loc)


def normalize_km(loc):
    """Bare km-marker numbers that are missing the 'Km' prefix ('1098, Quốc lộ 1',
    '1106+800, Quốc lộ 1') -> 'Km 1098, Quốc lộ 1' so the record is
    self-describing. House numbers ('469 Nguyễn Hữu Thọ') are left alone — they
    are addresses, not km markers (they're followed by a street name, not a road
    ref)."""
    m = re.match(r"^\s*(\d{1,5}(?:\+\d+)?)\s*[.,]?\s+(.*)$", loc)
    if not m:
        return loc
    num, rest = m.group(1), m.group(2)
    road = re.match(
        r"^(?:qu\u1ed1c l\u1ed9|quoc lo|ql|q\b|dt|\u0111t|dh|qd|tl|t\u1ec9nh "
        r"l\u1ed9|cao t\u1ed1c|cao toc|c\u1ea7u|cau|\u0111\u01b0\u1eddng|duong)",
        rest, flags=re.I)
    if road:
        return f"Km {num}, {rest}"
    return loc


def norm_key(loc):
    """Format-insensitive key so repeat entries of the SAME camera (different
    casing/punctuation/abbreviations: 'QL 91' vs 'Quốc lộ 91', 'TP Long Xuyên'
    vs 'TPLX') collapse to one — the 'obvious overlap' filter. For km-marker
    entries we anchor on km number + road + ward/commune names; for the rest we
    keep the full normalized text (safe — never merges distinct intersections)."""
    a = _ascii(loc).upper()
    a = re.sub(r"\bQUOC LO", "QL", a)
    a = re.sub(r"\bTHANH PHO\b", "TP", a)
    a = re.sub(r"\bCAO TOC\b|\bTINH\b|\bHUYEN\b|\bXA HOI\b|\bDUONG\b", " ", a)
    a = re.sub(r"\s+", " ", a).strip()
    km = re.search(r"\bKM\s*(\d+)", a)
    if km:
        tail = a[km.end():]
        road = re.search(r"\b(?:QL|DT|DH|QD|QLB)\s*\.?\s*(\d+)", tail)
        places = re.findall(
            r"\b(?:PHUONG|XA|THI TRAN|THI XA)\s+([A-Z]+(?:\s+[A-Z]+)?)", tail)
        key = "K" + km.group(1)
        if road:
            key += "R" + re.sub(r"[^A-Z0-9]", "", road.group(0))
        key += "P" + "".join(re.sub(r"\s", "", p) for p in places)
        return key
    return re.sub(r"[^A-Z0-9]", "", a)


def load_existing_police():
    """Set of norm_keys already in the DB as source=police, so re-runs skip
    them instead of burning Vietmap requests again."""
    try:
        with open(ASSET) as f:
            doc = json.load(f)
        return {norm_key(c.get("name", "")) for c in doc["cameras"]
                if c.get("source") == "police"}
    except (FileNotFoundError, KeyError):
        return set()


def geocode(loc, province):
    """Best-effort forward geocoding. Only Vietmap (the app's own key) is used —
    it is Vietnamese-native and we verify the province of the hit. Free geocoders
    (Nominatim/Photon) were removed: they collapse highway km-markers to one
    arbitrary road point, which would pollute the DB with wrong positions.
    Google Maps Geocoding API (GOOGLE_MAPS_API_KEY env var) is an optional
    better fallback if you set it yourself."""
    vm = geocode_vietmap(loc, province)
    if vm:
        return vm
    variants = [
        f"{loc}, {province}, Việt Nam",
        f"{clean_for_geocode(loc)}, {province}, Việt Nam",
    ]
    key = os.environ.get("GOOGLE_MAPS_API_KEY", "").strip()
    for q in variants:
        if key:
            try:
                url = ("https://maps.googleapis.com/maps/api/geocode/json"
                       "?language=vi&address=" + urllib.parse.quote(q)
                       + "&key=" + urllib.parse.quote(key))
                with urllib.request.urlopen(
                        urllib.request.Request(url, headers=UA), timeout=30) as r:
                    data = json.load(r)
                if data.get("status") == "OK" and data.get("results"):
                    g = data["results"][0]["geometry"]["location"]
                    return float(g["lat"]), float(g["lng"])
            except Exception as e:  # noqa
                print(f"  google fail: {q[:60]} {type(e).__name__}")
    return None


def extract_province_locs(slug):
    """Fetch all pages of a province, return deduped raw location strings."""
    all_locs = []
    page = 1
    while True:
        url = f"{BASE}/{slug}" + (f"?page={page}" if page > 1 else "")
        try:
            page_html = fetch(url)
        except Exception as e:
            print("  fetch fail:", url, e)
            break
        locs = extract_locations(page_html)
        if not locs:
            break
        all_locs.extend(locs)
        if f"?page={page + 1}" not in page_html:
            break
        page += 1
        if page > 6:
            break
        time.sleep(0.4)
    seen = []
    for l in all_locs:
        if l not in seen:
            seen.append(l)
    return seen


def crawl_provinces(slugs, cache_path):
    """Phase 1 — ZERO Vietmap calls. Fetch every page, keep only place-named
    entries, collapse format-variant duplicates, drop already-merged. Writes the
    distinct list to cache_path and returns it."""
    entries = []
    for slug in slugs:
        label = province_label(slug)
        seen = extract_province_locs(slug)
        print(f"== {label} ({slug}): {len(seen)} locations", flush=True)
        for l in seen:
            if is_mergeable(l):
                l = normalize_km(l)
                entries.append((l, canon_province(detect_province(l) or label)))
    uniq = {}
    existing = load_existing_police()
    for loc, prov in entries:
        k = norm_key(loc)
        if k in existing or k in uniq:
            continue
        uniq[k] = (loc, prov)
    result = [(l, p) for _, (l, p) in sorted(uniq.items())]
    with open(cache_path, "w") as f:
        json.dump([{"loc": l, "prov": p, "googlemaps": gm_url(l)}
                   for l, p in result], f, ensure_ascii=False, indent=1)
    print(f"CRAWL: {len(entries)} raw place-named -> "
          f"{len(result)} distinct NEW to geocode "
          f"(~{len(result) * 2} Vietmap req)", flush=True)
    return result


def geocode_cache(cache_path, budget, write):
    """Phase 2 — Vietmap only, on the deduped crawl cache. Incremental merge.
    After the run the queue DRAINS: every entry attempted (added, collapsed by
    coord-dedup, or failed) is removed from the cache file, so the next run
    never re-burns requests on the same entries."""
    with open(cache_path) as f:
        cache = json.load(f)
    VM_BUDGET["max"] = budget
    out = []
    done = 0
    attempted = 0
    for e in cache:
        if budget and VM_BUDGET["used"] >= budget:
            print("budget exhausted; stopping", flush=True)
            break
        attempted += 1
        loc, prov = e["loc"], e["prov"]
        coord = geocode(loc, prov)
        if coord is None:
            continue
        out.append({
            "name": loc,
            "lat": round(coord[0], 6),
            "lng": round(coord[1], 6),
            "focus": "violations",
            "district": canon_province(prov),
            "source": "police",
            "googlemaps": e.get("googlemaps", gm_url(loc)),
        })
        print(f"  + {loc} -> {coord}", flush=True)
        if write and len(out) >= 8:
            merge(out)
            out.clear()
        done += 1
    if write and out:
        merge(out)
        out.clear()
    # Drain the queue: drop everything we just attempted so collapsing/failed
    # entries aren't re-geocoded on the next run.
    if attempted:
        with open(cache_path, "w") as f:
            json.dump(cache[attempted:], f, ensure_ascii=False, indent=1)
    print(f"GEOCODE: {done} geocoded [{VM_BUDGET['used']} Vietmap req]; "
          f"{len(cache) - attempted} left in queue", flush=True)
    return done


def merge(entries):
    with open(ASSET) as f:
        doc = json.load(f)
    existing = doc["cameras"]
    keys = {(round(c["lat"], 5), round(c["lng"], 5)) for c in existing}
    added = 0
    for e in entries:
        # Round to 5dp (~1 m) to match the dedup set — storing at 6dp previously
        # meant the key NEVER matched, so coordinate-duplicates slipped through.
        k = (round(e["lat"], 5), round(e["lng"], 5))
        if k not in keys:
            existing.append(e)
            keys.add(k)
            added += 1
    doc["cameras"] = existing
    with open(ASSET, "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print(f"merged: +{added} -> total {len(existing)}")


# Provinces reachable on the site but not linked from the index page.
EXTRA = {"vinh-phuc"}


def province_slugs():
    """All province slugs on the site (index + known extra pages). No SKIP
    filter — the user wants every province in the list processed."""
    html = fetch("https://kiemtraphatnguoi.com/camera-phat-nguoi")
    slugs = set(re.findall(r"/camera-phat-nguoi/([a-z0-9-]+)", html))
    slugs |= EXTRA
    return sorted(slugs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--province")
    ap.add_argument("--batch", help="space-separated province slugs")
    ap.add_argument("--all", action="store_true",
                    help="all provinces on the site")
    ap.add_argument("--crawl", action="store_true",
                    help="phase 1: crawl + dedup + overlap-filter (no API)")
    ap.add_argument("--geocode", action="store_true",
                    help="phase 2: geocode the crawl cache (Vietmap)")
    ap.add_argument("--cache", default="tool/data/police_crawl.json",
                    help="crawl cache file path")
    ap.add_argument("--budget", type=int, default=0,
                    help="hard cap on Vietmap requests")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    slugs = []
    if args.province:
        slugs = [args.province]
    if args.batch:
        slugs = args.batch.split()
    if args.all:
        slugs = province_slugs()
        print(f"targeting {len(slugs)} provinces: {' '.join(slugs)}")
    # Slugs are only required for the crawl phase; --geocode reads the cache.
    if not slugs and (args.crawl or not args.geocode):
        ap.print_help()
        return
    # Default = crawl then geocode; --crawl only or --geocode only to split.
    do_crawl = args.crawl or not args.geocode
    do_geocode = args.geocode or not args.crawl
    if do_crawl:
        try:
            crawl_provinces(slugs, args.cache)
        except KeyboardInterrupt:
            print("\ncrawl interrupted — nothing written yet", flush=True)
            return
    if do_geocode:
        try:
            geocode_cache(args.cache, args.budget, args.write)
        except KeyboardInterrupt:
            print("\ninterrupted — completed entries were already merged",
                  flush=True)


if __name__ == "__main__":
    main()
