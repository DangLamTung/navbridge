# Changelog

All notable changes to NavBridge. Versions follow `X.Y.Z+build` in `pubspec.yaml`;
each release is committed on `main` as `release: X.Y.Z (build NNNN)` and tagged
`vX.Y.Z`.

## 1.1.3 — 2026-09-30 (build 4008)

**The posted limit is read once, as one answer.** The cascade (Waze per-segment →
Waze points → VietMap points) used to publish the limit and the street it came
from as two separate values, so the dial could show one lookup's number next to
another lookup's name. It now returns a single result — limit, source layer,
street and segment id together.

**A segment the car is riding outranks the name we hold.** The road matcher names
a road that is not the one under the car on roughly half of all fixes, and that
wrong name was narrowing the lookup to the wrong road's records before any
geometry was scored. A segment within 45° of the car's heading is now treated as
evidence about the road under it, in the picker and in `layerLimitMatchesNames`,
so a crossing street's value can no longer be posted for our road — and a
genuinely ridden one can no longer be thrown away. An unknown heading is *not*
"riding it": the conservative reading is kept, because the score is blind at the
same moment.

Measured on the 2026-09-29 08:37 drive, the device logged `limitLayer=segment`,
50 km/h, street "Trương Công Định" for 29 consecutive fixes while the car was
riding Trường Chinh 60 (7.9 m away, 1-11° along it).

Also in this release:

- **Next-street limit** for the turn being entered, capped by the vehicle's own
  legal ceiling rather than the road form of a road it is not on.
- **Voice** — a turn is announced at 400 / 300 / 100 m, one phrase per posted
  limit, calmer camera calls, and the callout's speed follows the street being
  turned into. The name-change gate is clocked by the position clock instead of
  wall time, which had stopped layer-driven renames from ever confirming.
- **Offline graph** — download the Việt Nam OSM extract and build it on the
  phone, with progress across the download and the conversion. The streaming
  download is verified (length, no HTML error page) before the file is put in
  place, and a failed import cleans up after itself.
- **Signs** — real QCVN artwork for the Waze/VietMap kinds, coordinates
  regenerated from the source data, signs already passed are dropped, and the
  banner follows the segment being driven.
- **Trip replay / resume** — the replay's roads are keyed by street, highway and
  form; a resumed drive picks up where it stopped.
- **Test suite split in two** — `test/unit/**` (deterministic, no packs) and
  `test/func/**` (drives the app against the shipped packs and recorded trips),
  run as separate lines by `tool/check.sh`, which CI now calls instead of its own
  two steps. A test file outside those two directories is an error, so the split
  cannot silently stop covering something.

Known in this release, not fixed:

- When the held name's own segment runs *along* the car, its value still wins:
  the geometric override fires only for a record that lies *across* the car and
  overshoots its end.
- On Trường Chinh the motorbike ceiling can still clamp the layer's 60 to 50
  (`effectiveLimit`); the dial has not been re-checked on the road yet.
- The local camera DB has no "Nam Định" rows and carries "VietMap" in the
  `district` field for 21.7k of its 27.3k rows. The committed DB is the 15-byte
  stub, so CI skips the camera data tests; the real DB is served by the update
  server.

## 1.1.2 — 2026-09-21 (build 4007)

Dropped the unreachable "sign adopted early" voice branch: a sign is only
authority once the car is at it (`signLimitInForce`), so `_limitIsUpcoming` was
always false and the "Tốc độ tối đa tiếp theo N km/h" phrasing could never play.
Behaviour-neutral.

## 1.1.1 — 2026-09-02 (build 4006)

- Loopback tile server: the itel's MapLibre cannot decode tiles it fetches itself
  over HTTP, so every online source was a blank map. The app now fetches tiles
  through its own HTTP client, normalises them to a decodable PNG, caches them
  and serves MapLibre `http://127.0.0.1:<port>/tiles/{z}/{x}/{y}.png`.
- Online basemap defaults to OSM; the map opens centred on the driver's
  current/last-known place.
- UI cleanup: the centre button pinned to the left edge, the radar, cloud and
  map-layer cycle buttons removed.

## 1.1.0 — 2026-09-02 (build 4005)

Deep-audit fixes: BLE UTF-8, extraction path guard, AI key redaction, reroute
fast-fail, step-advance lead, dead-code cleanup.

## 1.0.1 — 2026-08-30 (build 4004)

- Nav map: expand `{s}` subdomains for MapLibre plus an OSM fallback (blank-map
  fix).
- ETA: cap the assumed pace at the Việt Nam legal maximum per vehicle (car 120,
  motorbike 80, bicycle 40, walk 10 km/h), floor 0.5 → 0.6.
- Voice: kilometres past 1 km in maneuvers, signs, cameras and AI context.
- Audio: pause (not duck) media during announcements via transient audio focus.

## 1.0.0 — 2026-08-29 (build 4003)

First release: offline OSM/GrapHopper routing, VietMap and Waze speed limits and
enforcement data, EInk-friendly navigation UI, voice guidance.
