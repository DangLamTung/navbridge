#!/usr/bin/env python3
"""Fetch Việt Nam red-light + speed cameras from OSM Overpass and merge them
into assets/offline_map/vietnam_cameras.json (deduped against the existing
police-list cameras). Open data (ODbL) — no Waze involved.

Usage:
    python3 tool/fetch_overpass_cameras.py [--write]

Without --write it prints the new count + samples only.
"""
import argparse
import json
import sys
import urllib.request

# Việt Nam bounding box (lat south, lon west, lat north, lon east).
BBOX = "8.19,102.14,23.39,109.47"
OVERPASS = "https://overpass-api.de/api/interpreter"

QUERY = f"""
[out:json][timeout:180];
(
  nwr["highway"="traffic_signals"]["red_light_camera"]({BBOX});
  nwr["highway"="traffic_signals"]["camera:type"]({BBOX});
  nwr["highway"="speed_camera"]({BBOX});
  nwr["enforcement"]({BBOX});
  nwr["camera:type"="red_light"]({BBOX});
);
out center tags;
"""

ASSET = "assets/offline_map/vietnam_cameras.json"


def classify(tags):
    enf = (tags.get("enforcement") or "").lower()
    rl = (tags.get("red_light_camera") or "").lower()
    cam_type = (tags.get("camera:type") or "").lower()
    hw = tags.get("highway") or ""
    if rl in ("yes", "1", "true") or cam_type == "red_light" or enf == "red_light_camera":
        return "red_light"
    if hw == "speed_camera" or cam_type == "speed" or enf in ("maxspeed", "speed", "average_speed"):
        return "speed"
    return None  # skip unclassifiable


def element_coords(el):
    if "lat" in el and "lon" in el:
        return el["lat"], el["lon"]
    c = el.get("center")
    if c:
        return c["lat"], c["lon"]
    return None


def fetch():
    req = urllib.request.Request(
        OVERPASS, data=QUERY.encode(), headers={"User-Agent": "NavBridge-camera-tool/1.0"}
    )
    with urllib.request.urlopen(req, timeout=240) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="write merged JSON")
    args = ap.parse_args()

    data = fetch()
    elems = data.get("elements", [])
    print(f"Overpass returned {len(elems)} raw elements")

    seen = {}
    for el in elems:
        tags = el.get("tags") or {}
        focus = classify(tags)
        if not focus:
            continue
        coord = element_coords(el)
        if not coord:
            continue
        lat, lng = coord
        key = (round(lat, 5), round(lng, 5))
        name = (
            tags.get("name")
            or tags.get("official_name")
            or (tags.get("ref") and f"QL {tags['ref']}")
            or f"Camera {'đèn đỏ' if focus == 'red_light' else 'tốc độ'} (OSM)"
        )
        district = tags.get("addr:province")
        seen[key] = {
            "name": name,
            "lat": round(lat, 6),
            "lng": round(lng, 6),
            "focus": focus,
            "source": "osm",
        }
        if district:
            seen[key]["district"] = district

    print(f"Classified {len(seen)} unique OSM cameras "
          f"({sum(1 for c in seen.values() if c['focus']=='red_light')} red_light, "
          f"{sum(1 for c in seen.values() if c['focus']=='speed')} speed)")

    with open(ASSET) as f:
        doc = json.load(f)
    existing = doc["cameras"]
    existing_keys = {(round(c["lat"], 5), round(c["lng"], 5)) for c in existing}

    added = 0
    for key, cam in seen.items():
        if key not in existing_keys:
            existing.append(cam)
            existing_keys.add(key)
            added += 1

    print(f"Existing {len(existing) - added} → added {added} → total {len(existing)}")
    if args.write:
        doc["generated"] = __import__("datetime").date.today().isoformat()
        doc["cameras"] = sorted(existing, key=lambda c: (c["lat"], c["lng"]))
        with open(ASSET, "w") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        print(f"Wrote {ASSET}")
    else:
        for c in sorted(seen.values(), key=lambda c: (c["lat"], c["lng"]))[:8]:
            print("  sample:", json.dumps(c, ensure_ascii=False))


if __name__ == "__main__":
    main()
