# NavBridge

BLE portable turn-by-turn navigation: routes + turn-by-turn directions on
your phone, mirrored in real time to external BLE-connected monitors:

- **E-ink clock** (DA14585) — binary nav frame (`lib/core/nav_protocol.dart`).
- **ESP32 2.8" TFT display** (NAV-OSM board, ILI9341 320×240) — compact binary
  overlay frames (`lib/core/map_protocol.dart`): route polyline, live position,
  maneuver, ETA and clock, fed through `BleMapClock`.

Everything else is offline-friendly and key-free (OpenStreetMap data, OSRM
routing, Overpass, Open-Meteo, RainViewer — no API keys required).

## Features

### Navigation
- Turn-by-turn navigation over an OSM map with live GPS
- Route planning: start → destination → **via points**, route preview with
  elevation profile, and saved favourite routes (stops + routing profile +
  preference metadata persisted with the plan)
- **Route preferences**: Nhanh nhất (fastest) / Ngắn nhất (shortest) /
  Đường chính (main roads) / Đẹp cảnh (scenic) — alternatives are ranked by
  duration, distance, average leg length or curvature
- Avoid motorways / ferries when routing
- **Export the planned route** to GPX 1.1, KML 2.2 and KMZ
  (`lib/services/route_export.dart`) — Garmin, OSMAnd, Komoot, GaiaGPS,
  Google Earth / "My Maps"
- Google-Maps-style driving experience: **Kalman-filtered GPS**
  (`lib/core/location_kalman.dart` — adaptive velocity zeroing when parked so
  the dot never crawls), **route snapping** (`lib/core/route_snap.dart` — the
  puck rides the road), smooth dead-reckoned camera follow, and **network
  matching** (`snapToRoad` — on-device GraphHopper snaps the fix to the nearest
  road and detects off-route deviation)
- Wrong-way / off-route detection with automatic reroute
- Road type + speed limit lookup (Overpass), with **Việt Nam statutory speed
  tables per vehicle** (car / motorbike / truck) and an EU-style speed-limit
  chip

### Safety & awareness
- **Speed / red-light camera alerts** (phạt nguội DB) — bundled offline
  `vietnam_cameras.json` with **8,600+ enforcement points nationwide**
  (refreshed by `tool/fetch_overpass_cameras.py` /
  `tool/fetch_police_cameras.py`, plus aggregated online traffic-camera data)
- **Road signs** (STOP, nhường đường, traffic lights, cấm vượt / cấm rẽ /
  cấm quay đầu, speed limits…) from the bundled offline Việt Nam index
  `vietnam_signs.json` — **48,600+ signs** (built by
  `tools/signs/build_signs.py` plus aggregated online traffic-sign data) —
  spoken warnings ahead on the route + colored dots on the map
  (`lib/services/offline_road_signs.dart`, `lib/ui/sign_icons.dart`)
- **Real posted speed limits, offline** — a bundled nationwide
  `vietnam_speed_limits.geojson` (93,000+ road segments with actual posted
  limits, aggregated from online navigation data) corrects the statutory
  class default during navigation, with **no network** needed
  (`lib/services/offline_speed_limits.dart`)
- **Rain radar overlay** (RainViewer, free/no key) with a past/nowcast frame
  selector so you can watch the storm move

### Search & data
- Geocoding with **Photon** (primary — includes Vietnamese date-street
  rewriting, e.g. "30/4" → "30 Tháng 4", and GPS location bias) with
  **Nominatim** as fallback
- POI search (ATM, gas, food, parking…) online + a bundled offline index
  (`vietnam_pois.json`); scenic spots / mountain passes (đèo) via Overpass
  for the AI's "beautiful stop" suggestions
- Weather (Open-Meteo) with rain probability in the status bar
- OSM map tiles with automatic failover (OSM → CARTO Voyager → OpenTopoMap)
  and OSM tile-policy-compliant caching

### Offline mode
- On-device **GraphHopper routing** for the whole Việt Nam graph (downloaded
  on demand) — navigation works with no network at all
- Offline region downloader (slippy tiles with progress/cancel), offline POI
  + geocoding fallback, offline camera/sign databases
- **Bundled offline datasets for the whole of Việt Nam** — 8,600+ cameras,
  48,600+ road signs, 93,000+ speed-limit segments, 20,000+ POIs (see *Data &
  attribution* below)
- **Simulated drive mode** for testing without GPS, driven by a seeded GPS
  noise simulator (`lib/core/gps_noise_simulator.dart`) and trip replay
  (`--dart-define=TRIPREPLAY`)

### Voice & AI
- Vietnamese **voice commands** (mute/unmute, cancel, nearby POIs…) and spoken
  turn-by-turn guidance (STOP/give-way sign warnings included)
- **AI assistant** grounded in the live drive context (position, road, speed,
  destination, ETA, next maneuver, camera-ahead, weather, scenic spots) —
  DeepSeek by default, Google Gemini fallback; keys stored encrypted on-device
  (`flutter_secure_storage`), never in the APK

### Trip logging & extras
- Google-Takeout-style trip logging (`Records.json` format) with share/export
- Heads-up turn-by-turn banner notifications, foreground-service background
  navigation, Picture-in-Picture window, keep-screen-on while navigating
- Vietmap navigation hand-off for city driving when desired

## Hardware companions

The app broadcasts compact binary frames over BLE. Reference implementations
live in sibling repos:

- **E-ink clock** — DA14585, `lib/core/nav_protocol.dart` defines the frame.
- **ESP32 2.8" TFT** — NAV-OSM board (ILI9341 320×240),
  `lib/core/map_protocol.dart` defines the overlay frames (route polyline, live
  position, maneuver, ETA, clock).

## Getting Started

```sh
flutter pub get
flutter run
```

For voice / AI features, paste your API keys once in Settings (stored
encrypted) or provide build-time defines. No keys are required for core
navigation, search, routing, cameras, signs, radar or weather.

## Development

Quality gates run automatically via [pre-commit](https://pre-commit.com/)
(installed once) and on CI (GitHub Actions, `.github/workflows/ci.yml`):

```sh
# One-time setup
pip install pre-commit
pre-commit install

# What runs on every commit
#   - trailing whitespace / EOF / YAML checks
#   - `dart format` on staged .dart files
#   - `flutter analyze`
#   - `flutter test` (unit tests in test/)
#   - large-file guard (see .pre-commit-config.yaml for the limit)

# Run everything manually
tool/check.sh
```

The Flutter SDK is located automatically (`FLUTTER_ROOT`, `flutter` on PATH,
or `~/Documents/Eink/flutter_sdk`).

### Data tooling

- `tools/signs/build_signs.py` — rebuild `vietnam_signs.json` from OSM Overpass
- `tool/fetch_overpass_cameras.py` / `tool/fetch_police_cameras.py` — refresh
  the camera database (`vietnam_cameras.json`)
- `tool/analyze_trip.py` — analyze a recorded trip
- `tools/build_graph.sh` — build the on-device GraphHopper Việt Nam graph

See `docs/PERFORMANCE.md` for the performance test report.

## Data & attribution

The app ships with bundled offline datasets for Việt Nam (no network, no API
keys required):

| Dataset | Entries | Sources | Refresh |
|---|---|---|---|
| Cameras<br>`vietnam_cameras.json` | 8,618<br>(speed / violations / red-light) | police "phạt nguội" lists, OSM Overpass, Waze, online traffic-camera data | `tool/fetch_police_cameras.py` · `tool/fetch_overpass_cameras.py` |
| Road signs<br>`vietnam_signs.json` | 48,653 | OSM Overpass, Waze, online traffic-sign data | `tools/signs/build_signs.py` · `tools/signs/build_waze_signs.py` |
| Speed limits<br>`vietnam_speed_limits.geojson` | 93,463 road segments<br>(real posted limits) | online navigation data | — |
| POIs<br>`vietnam_pois.json` | 20,607 across 25 categories | OSM Overpass | — |

Map data, routing and POIs come from OpenStreetMap (© OpenStreetMap
contributors, ODbL). Camera lists are derived from public provincial police
"phạt nguội" data, OSM/Waze reports and aggregated online traffic-camera
data. Speed-limit and traffic-sign data are aggregated from online navigation
sources. All data is provided **as-is for awareness only** — always obey
posted speed limits and traffic law.

## License

MIT © 2026 DangLamTung — see [LICENSE](LICENSE).

Bundled datasets remain subject to their own upstream licenses (OSM ODbL,
Waze, and the provincial police "phạt nguội" sources) — the MIT license
covers the code in this repository, not the third-party data.
