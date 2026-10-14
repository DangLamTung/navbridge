#!/usr/bin/env python3
"""Plot the one-way signs currently in the shipped pack.

Why: the 2026-10-11 generated pack claims a one-way sign on streets that are
plainly two-way divided arterials (the complaint was Cộng Hòa / Trường Chinh).
The sign rows carry only a generic name, no street, so the only way to SEE which
roads got signed is to draw them.

Writes a self-contained Leaflet page to docs/oneway_map.html.

Run: python3 tool/oneway_map.py
"""

from __future__ import annotations

import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SIGNS = REPO / "assets" / "offline_map" / "vietnam_signs.json"
OUT = REPO / "docs" / "oneway_map.html"


def main() -> int:
    doc = json.loads(SIGNS.read_text(encoding="utf-8"))
    rows = doc.get("signs", [])
    one = [s for s in rows if s.get("kind") == "one_way"]
    gen = [s for s in one if s.get("source") == "waze-segment"]
    other = [s for s in one if s.get("source") != "waze-segment"]

    def pts(rs):
        return [[round(float(r["lat"]), 5), round(float(r["lng"]), 5)] for r in rs]

    html = """<!doctype html>
<meta charset="utf-8"><title>NavBridge one-way signs</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>html,body,#m{height:100%;margin:0}#h{position:absolute;z-index:999;top:8px;left:50px;
background:#111;color:#eee;font:12px/1.5 monospace;padding:8px 12px;border-radius:6px}</style>
<div id="h"></div><div id="m"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const GEN = __GEN__, OTHER = __OTHER__;
const m = L.map('m').setView([10.78, 106.66], 12);
L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
  {maxZoom: 19, attribution: '&copy; OpenStreetMap, &copy; CARTO'}).addTo(m);
L.circleMarker([0,0],{radius:1}).setStyle({});
function layer(a, color, r) {
  return L.layerGroup(a.map(p => L.circleMarker(p,
    {radius:r, color:color, weight:1, fillColor:color, fillOpacity:0.85})));
}
const lg = layer(GEN, '#e53935', 4).addTo(m);      // generated 2026-10-11
const lo = layer(OTHER, '#1e88e5', 4).addTo(m);    // pre-existing / hand rows
L.control.layers(null, {'generated (waze-segment)': lg, 'other sources': lo}).addTo(m);
document.getElementById('h').textContent =
  'generated one-way signs: ' + GEN.length.toLocaleString() +
  '   |   other sources: ' + OTHER.length.toLocaleString();
</script>
"""
    html = html.replace("__GEN__", json.dumps(pts(gen))).replace(
        "__OTHER__", json.dumps(pts(other)))
    OUT.write_text(html, encoding="utf-8")
    print(f"one_way rows: {len(one):,}  (generated {len(gen):,}, other {len(other):,})")
    print(f"wrote {OUT.relative_to(REPO)}  ({OUT.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
