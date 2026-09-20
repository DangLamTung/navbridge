"""Prove the Google routing contract by asking the real APIs (no app needed).

Answers "is Google routing actually working, and do the avoid toggles reach the
server?" — the two questions a code read cannot settle, because Google BIASES
rather than forbids: a request that is accepted can still return the same route,
and only comparing outputs tells you which happened.

Usage:  python3 tool/check_google_route.py
Reads the key from .env (GOOGLE_PLACES_KEY or GOOGLEMAPS_API_KEY) and prints
only status + distance/duration — never the key or the full URL.

Corridors (D1 HCMC origin) are picked so a change is POSSIBLE:
  • My Tho   — default route uses the HCMC–Trung Luong expressway
  • Vung Tau — default route uses the Long Thanh expressway / Can Gio ferry
  • Bien Hoa — CONTROL: no expressway, so "no change" there is expected.

Measured 2026-09-21 (all status OK):
  legacy car   My Tho   75.96 km/98.7 min -> 72.25 km/116.0 min
  legacy car   Vung Tau 96.82 km/113.0 min -> 109.80 km/167.4 min
  v2 two-wheel Vung Tau 99.95 km/188.4 min -> 113.02 km/193.7 min (avoidFerries)
  => avoid=highways bites for cars; avoidHighways is nearly a no-op for
     motorbikes because TWO_WHEELER already keeps them off expressways (VN law).
"""

import json
import os
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

env = {}
with open(os.path.join(ROOT, ".env")) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

key = env.get("GOOGLE_PLACES_KEY") or env.get("GOOGLEMAPS_API_KEY")
if not key:
    raise SystemExit("no Google key in .env")

O = (10.7769, 106.7009)  # District 1, HCMC
C = [
    ("Bien Hoa (control)", 10.9508, 106.8000),
    ("My Tho", 10.3600, 106.3650),
    ("Vung Tau", 10.3460, 107.0843),
]
UA = {"User-Agent": "navbridge/1.0"}


def _get(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def legacy(dest, avoid):
    """Directions API (Legacy) — the car / bicycle / walking path."""
    url = (
        "https://maps.googleapis.com/maps/api/directions/json"
        f"?origin={O[0]},{O[1]}&destination={dest[0]},{dest[1]}"
        f"&mode=driving&language=vi&alternatives=false{avoid}&key={key}"
    )
    d = _get(url)
    if d.get("status") != "OK":
        return d.get("status"), None, None
    leg = d["routes"][0]["legs"][0]
    return "OK", leg["distance"]["value"] / 1000, leg["duration"]["value"] / 60


def two_wheeler(dest, modifiers):
    """Routes API v2 computeRoutes — the motorbike (TWO_WHEELER) path."""
    body = {
        "origin": {"location": {"latLng": {"latitude": O[0], "longitude": O[1]}}},
        "destination": {
            "location": {"latLng": {"latitude": dest[0], "longitude": dest[1]}}
        },
        "travelMode": "TWO_WHEELER",
        "languageCode": "vi",
        "units": "METRIC",
    }
    if modifiers:
        body["routeModifiers"] = modifiers
    req = urllib.request.Request(
        "https://routes.googleapis.com/directions/v2:computeRoutes",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Goog-Api-Key": key,
            "X-Goog-FieldMask": "routes.distanceMeters,routes.duration",
            **UA,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}", None, None
    routes = d.get("routes") or []
    if not routes:
        return "NO ROUTES", None, None
    dur = (routes[0].get("duration") or "0s").rstrip("s")
    return "OK", routes[0]["distanceMeters"] / 1000, float(dur) / 60


def show(label, res):
    status, km, mins = res
    if km is None:
        print(f"{label:<40} {status}")
    else:
        print(f"{label:<40} {status}  {km:6.2f} km {mins:6.1f} min")


def main():
    for name, lat, lng in C:
        dest = (lat, lng)
        print(f"=== {name}: D1 -> {lat},{lng} ===")
        print("legacy Directions (car, mode=driving)")
        show("  no avoid", legacy(dest, ""))
        show("  avoid=highways", legacy(dest, "&avoid=highways"))
        show("  avoid=highways|ferries", legacy(dest, "&avoid=highways|ferries"))
        print("Routes API v2 (motorbike, travelMode=TWO_WHEELER)")
        show("  no routeModifiers", two_wheeler(dest, None))
        show("  avoidHighways", two_wheeler(dest, {"avoidHighways": True}))
        show(
            "  avoidHighways+avoidFerries",
            two_wheeler(dest, {"avoidHighways": True, "avoidFerries": True}),
        )
        print()


if __name__ == "__main__":
    main()
