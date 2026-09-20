# Waze Data Pipeline → NavBridge offline assets

> End-to-end runbook: crawl Vietnam's Waze Map Editor (WME) data → decode it into
> a road-notice DB → build the offline assets the NavBridge app ships → (optionally)
> publish a **monthly update bundle** so devices can refresh without a full app release.

Two repos are involved:

| Repo | Path | Role |
|---|---|---|
| **Decode_Waze** | `/Users/tungdl/Documents/Eink/Decode_Waze` | Crawl WME + decode into TSV/JSON data bases |
| **navbridge** | `/Users/tungdl/Documents/Eink/navbridge` | Flutter app; `assets/offline_map/*.json` are served/bundled |

The board (ESP32_OSM_NAV) receives **live** nav state over BLE from the Waze Mod
(not from these files). The offline assets are the **map overlay data** the app uses.

---

## 1. The source of truth

WME's Descartes `/app/Features` endpoint returns a JSON per bbox tile:

```
https://www.waze.com/row-Descartes/app/Features?bbox={minLon},{minLat},{maxLon},{maxLat}
  &language=en-US&v=2&apiV2=true&mapComments=true&houseNumbers=true
  &roadTypes=1,2,3,4,5,6,7,8,9,10,15,16,17,18,19,20,22
  &venueLevel=4&venueFilter=1,1,1,0&zoomLevel=19
```

Requires a **logged-in** Waze session. The three data sources that matter:

| JSON key | What it holds | Used for |
|---|---|---|
| `mapComments[]` | **Editor traffic signs** — `subject` = "KDC", "Hết KDC", "Cấm vượt", "60", "Hết 60", … | residential, no-passing, speed-limit signs |
| `permanentHazards[]` | **Cameras / enforcement** — `type=10`, `subTypes` (RED_LIGHT, SPEED, MOBILE_PHONE, …) | cameras |
| `segments[].fwdMaxSpeed/revMaxSpeed` | Road **speed limits** per direction | speed-limits layer |

> `signTypes[]` is a *catalog* (not placed signs). Do not use it for placements.

---

## 2. Step 1 — Crawl (Decode_Waze)

Two crawlers (both use one logged-in session, not browser-per-tile):

```bash
cd /Users/tungdl/Documents/Eink/Decode_Waze

# Parallel HTTP (fastest, uses CDP to grab the session cookie)
./.venv/bin/python wme_crawl_http.py \
  --bbox "102.1,8.6,109.5,23.4" --half 0.05 --workers 8 --out ./vn_features

# OR direct-fetch from one Selenium page context (reuses cookies in-page)
./.venv/bin/python wme_crawl_vn.py \
  --bbox "102.1,8.6,109.5,23.4" --half 0.05 --out ./vn_features --sleep 0.3 --resume
```

- `--half 0.05` ⇒ 0.1°-degree tiles. Full Vietnam `102.1,8.6,109.5,23.4` ≈ **~10,952 tiles** (~3 h).
- `--resume` skips tiles already present in `--out`.
- Output: `vn_features/*.json` (one per tile).

---

## 3. Step 2 — Decode the crawl into data bases (Decode_Waze)

Run these in order. Each reads the crawl and writes a TSV/JSON.

### 3.1 Traffic-sign notes from `mapComments`
```bash
./.venv/bin/python extract_mapcomments.py
```
Writes `vn_mapcomments_notes.tsv` (raw) and `vn_mapcomments_notes_dedup.tsv`
(one per physical sign, 30 m dedup). `classify()` maps Vietnamese subjects to the
mod's point-notice type code (verified against `Signs.java`).

### 3.2 Cameras + segments from `permanentHazards`
```bash
./.venv/bin/python extract_compare.py
```
Writes `vn_point_notices.tsv` (cameras/hazards + segment metadata) and prints the
cross-comparison vs. the mod DB.

### 3.3 Build the corrected mod point-notice DB
```bash
./.venv/bin/python build_mod_db_v2.py
```
Writes `point_notices_v2.tsv` — the **corrected** sign+speed-limit DB in the mod's
own schema (`id, type, lat, lng, dist_m, kmh, side`).

> ⚠️ **Corrections baked in:** mod types `12`/`13` are **speed limits**, not
> cameras; `19`/`20` are **Cấm ô tô / Cấm xe máy** (prohibition signs). Cameras
> come from `permanentHazards` type 10. Do NOT re-introduce the old mislabeling.

---

## 4. Step 3 — Build the NavBridge offline assets (navbridge)

```bash
cd /Users/tungdl/Documents/Eink/navbridge

# Back up current assets first (the rebuild scripts overwrite them)
cd assets/offline_map
ts=$(date +%Y%m%d_%H%M%S)
cp vietnam_cameras.json vietnam_cameras.json.bak_$ts
cp vietnam_signs.json   vietnam_signs.json.bak_$ts
cp waze_speed_limits.json waze_speed_limits.json.bak_$ts
cd ../..

# Rebuild signs + speed limits + cameras from the corrected DB + real cameras
python3 tools/signs/rebuild_waze_assets.py

# Dedup cameras spatially (50 m, per-focus) + prefer the richest source
python3 tools/signs/dedup_cameras.py
```

`rebuild_waze_assets.py` reads `Decode_Waze/point_notices_v2.tsv` (signs/speed)
and `Decode_Waze/vn_point_notices.tsv` (cameras), and writes:

| Asset | Contents |
|---|---|
| `assets/offline_map/vietnam_signs.json` | road signs (KDC, no-passing, no-turn, speed, …) |
| `assets/offline_map/waze_speed_limits.json` | **speed limits** (types 12/13) |
| `assets/offline_map/vietnam_cameras.json` | **real cameras** (permanentHazards type 10, no DUMMY) |

### 4.2 VietMap KC01 data (second source)

VietMap publishes an official traffic-warning dataset for its KC01 device every
month. It carries speed limits (type 1), residential (2/3), no-passing (5/6),
slow-down (7), toll (8), tunnel (9), and cameras (4/10).

- **Product page:** <https://vietmap.vn/cap-nhat-ban-do-vietmap-kc01>
- **ZIP:** `https://download.vietmap.vn/dvr/VietMap_KC01_G40_TS-2K_2026T9.zip`
  (the tag `2026T9` changes each release).
- **Inside:** `edog_data.txt` (tab-separated `POINT_X POINT_Y TYPE Speed DirType Direction`,
  coords × 1e6).

Build step (merges VietMap onto the existing assets, so it runs **after**
`rebuild_waze_assets.py`):

```bash
python3 tools/signs/build_vietmap.py [path/to/edog_data.txt]
# no path => auto-picks the NEWEST edog_data.txt under Decode_Waze
```

`build_vietmap.py` writes the same three assets (signs / speed-limits / cameras)
with `source: vietmap`, deduped by ~100 m, preserving any Waze-crawled points.

---

## 5. Step 4 — (Optional) Publish a monthly update bundle

The app currently loads these from `assets/offline_map/` (bundled). For over-the-air
refresh without shipping a new APK, serve a **dated, versioned** bundle and a
`manifest.json` the app can poll. See [`tools/update_server.py`](../tools/update_server.py).

### Server layout
```
update/               # HTTP server root (python tools/update_server.py --serve)
  latest/            # symlink -> the newest release
  releases/
    2026-09-06/
      manifest.json
      vietnam_signs.json
      vietnam_cameras.json
      waze_speed_limits.json
      ...
```

> The HTTP handler is rooted at `update/`, so the **public** URLs are
> `/latest/manifest.json` and `/latest/<filename>` (not `/update/...`).

### `manifest.json` example
```json
{
  "version": "2026-09-06",
  "generated": "2026-09-06T00:00:00+07:00",
  "files": {
    "vietnam_signs.json": { "sha256": "…", "size": 7894151 },
    "vietnam_cameras.json": { "sha256": "…", "size": 5092396 },
    "waze_speed_limits.json": { "sha256": "…", "size": 1494188 }
  }
}
```

### How a device refreshes
1. Poll `GET /latest/manifest.json`; compare `version` with local.
2. For each file whose `sha256` differs, `GET /latest/{file}`.
3. Verify the SHA-256, write it into the local `assets/offline_map/`, reload.

---

## 6. Re-running monthly

```
# 1. Crawl (refresh)
cd /Users/tungdl/Documents/Eink/Decode_Waze
./.venv/bin/python wme_crawl_http.py --bbox "102.1,8.6,109.5,23.4" --half 0.05 \
  --workers 8 --out ./vn_features --resume

# 2. Decode (refresh intermediate TSVs)
./.venv/bin/python extract_mapcomments.py
./.venv/bin/python extract_compare.py
./.venv/bin/python build_mod_db_v2.py

# 3. Build assets + publish
cd /Users/tungdl/Documents/Eink/navbridge
python3 tools/signs/rebuild_waze_assets.py
python3 tools/signs/dedup_cameras.py
python3 tools/signs/build_vietmap.py        # VietMap KC01 merge (uses newest edog_data.txt)
python3 tools/update_server.py --publish

# OR do it all in one shot (fetches VietMap KC01 + crawls + rebuilds):
python3 tools/update_server.py --publish --rebuild
#   (--no-vietmap skips the VietMap KC01 download if you want Waze-only)
```

---

## 7. Gotchas / don't-repeat

- **Borders/sea tiles** return 0 segments — normal, ignore.
- Dense city tiles can be 10–30 MB JSON each; the full crawl is large.
- **WME endpoint** caps bbox size server-side (0.2° bbox ≈ 20k segments, not fully linear).
- The mod **`Signs.java`** is the authoritative type map. `12/13`=speed limits,
  `19/20`=cấm signs, cameras=`permanentHazards` type 10.
- Camera dedup must be **grid-based** (O(n²) on ~37k rows times out).
- Back up `*.json` assets before every rebuild (the scripts overwrite them).
- The Waze Mod's `mapComments` are **the** source for traffic signs / speed limits —
  `signTypes` is only a catalog.
