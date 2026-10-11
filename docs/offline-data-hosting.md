# Where to store + how to serve the offline data bundles

Companion to [`waze-data-pipeline.md`](waze-data-pipeline.md), which covers how the
data is **built**. This one covers where it is **stored, pushed and served**, and
what can run unattended.

---

## 1. What a "bundle" is

`python3 tools/update_server.py --publish` writes an immutable dated release:

```
update/releases/<YYYY-MM-DD>/
  manifest.json            version, generated, per-file sha256 + size
  version.json             {cameras, signs, speed_limits} content hashes
  vietnam_signs.json
  vietnam_cameras.json
  waze_speed_limits.json
  waze_segments.bin
update/latest -> releases/<newest>      (symlink)
```

Every target below just needs those files reachable at a stable URL.

---

## 2. Storage targets (`--upload`)

`update_server.py` now has a storage-agnostic uploader. The target form picks the
tool; nothing else changes.

| Target | Example | Notes |
|---|---|---|
| **GCS** (recommended) | `gs://navbridge-data/update` | `gsutil` is already installed on this box (`~/Downloads/google-cloud-sdk`). Public-read bucket → HTTPS + Range requests + cheap. |
| S3 / R2 / B2 / Drive | `rclone:gdrive:navbridge/update` | needs `rclone` (`brew install rclone`). Works for any rclone remote. |
| Local / NAS / mounted Drive | `/Volumes/NAS/navbridge` | plain copy; **merges**, never deletes the destination. |

```bash
# one-off
python3 tools/update_server.py --publish --upload gs://navbridge-data/update

# or set it once and let the cron script do it
export UPLOAD_TARGET=gs://navbridge-data/update
./tools/cron_update_vietmap.sh --force

# push an existing release without rebuilding
python3 tools/update_server.py --upload gs://navbridge-data/update
```

`latest/` is dereferenced into real files while staging (object stores and
`rclone sync` do not follow symlinks). Releases are never deleted from the
remote, so a bad publish can be rolled back by pointing the app at an older date.

---

## 3. Autonomous crawling — what can and cannot be unattended

| Half | Automatable? | Why |
|---|---|---|
| **VietMap KC01** (monthly) | ✅ **Yes** | The download URL is discovered from the product page (`find_first_zip_href`), so `--vietmap-only` is idempotent and safe on a timer. Already wrapped by `tools/cron_update_vietmap.sh` (cron / systemd timer). |
| **Waze crawl** | ⚠️ **Not fully** | WME requires a **logged-in session cookie**; it expires. When it does, the crawl still "succeeds" but returns a fraction of the tiles — a silent, partial dataset. |

So a truly unattended server can do the VietMap refresh by itself. The Waze
crawl needs a human (or a stored session) at the start; if it runs headless,
**never publish its output without the count gate in §5**.

Suggested topology:

```
cron / systemd timer / Cloud Run Job / GitHub Actions schedule
        │
        ├─ ./tools/cron_update_vietmap.sh          # monthly, unattended
        │     └─ update_server.py --vietmap-only --upload $UPLOAD_TARGET
        │
        └─ (quarterly, attended)  update_server.py --publish --rebuild --upload …
                                    └─ Waze crawl (fresh cookie) → decode → assets → publish
```

A GitHub Actions **scheduled** workflow is a good scheduler here (no server to
run); the repo already uses Actions for CI + releases. The VietMap half needs no
secrets; add the storage credential (`GCS_SA_KEY` / an rclone config) as a
workflow secret.

---

## 4. Can I use my Google Drive for testing?

**Yes — three ways, in increasing order of usefulness:**

1. **`rclone` remote (best for testing)** — one-time `rclone config` for a `drive`
   remote, then `--upload rclone:gdrive:navbridge`. Gives you a real push/pull
   loop against Drive.
2. **Mount Drive locally** (Google Drive for desktop) and use the plain path
   form: `--upload "/Users/you/Library/CloudStorage/GoogleDrive-…/navbridge"`.
   No extra tools; slow, and Drive may sync mid-write.
3. **Just serve locally** — `update_server.py --serve --port 8080`, then point
   the phone/emulator at your LAN IP. This is what the pipeline already supports
   and it is the fastest inner loop:
   `flutter build apk --dart-define=DATA_URL=http://<LAN-IP>:8080/latest`.

⚠️ **Do not ship a Drive `latest/` to production.** Drive's direct-download
links are not stable/embeddable, it has per-file rate limits, and it does not do
HTTP Range requests well — the app's updater does a plain GET, so it usually
works, but a release artifact should live in object storage (GCS/R2).

---

## 5. Safety gates added 2026-09-29

- **`validate_assets()`** (called by `publish()`, before anything is written):
  refuses to publish unless the crawl has **≥10,000 tiles** and
  `waze_segments.bin` reports **≥1,000,000 segments / ≥20,000 street names**
  (plus a minimum size per file). This is the guard against a crawl silently cut
  short by an expired Waze session. Override with `--force` when a small region
  build is intentional.
- **`MAX_KMH = 120`** in `tools/signs/build_waze_segments.py` (was 150). Vietnam's
  statutory ceiling is 120 km/h (Thông tư 31/2019, 38/2024). The 2026-09 crawl
  carried **2,819 directional values above 120** (179× 150, 1,248× 140, 937× 130,
  448× 125).
- **Rebuilt 2026-09-29** (21 s over the full 10,952-tile crawl):
  `nSegs 1,033,546 → 1,032,156`, `nPoints 4,371,837 → 4,369,047`,
  `nStreets 32,241 → 32,238`, **max limit 120 (was 150)**, 28.02 MB.
  Backup of the previous binary: `/tmp/waze_segments.bin.bak_*`.

---

## 6. Wiring the app

| Build define | Point it at | Consumed by |
|---|---|---|
| `DATA_URL` | the published `latest/` (e.g. `https://storage.googleapis.com/navbridge-data/update/latest`) | `OfflineDataUpdater` — polls `version.json`, downloads the signs/cameras/speed-limit JSONs |
| `NAVMAP_URL` | dir holding `saigon_z16.pmtiles` | `nav_map_store.dart` |
| `GRAPH_URL` | `.ghz`/`.pbf` (defaults to Geofabrik if unset) | `offline_router.dart` |

All three, plus the defaults, are now visible in-app: **Offline screen → "Liên
kết tải ngoại tuyến"** (see `lib/services/offline_links.dart`).

> `waze_segments.bin` is deliberately **not** in the app's auto-update list — it
> is large and version-coupled, so it ships with the app rather than being
> hot-swapped.
