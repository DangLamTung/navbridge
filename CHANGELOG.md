# Changelog

All notable changes to NavBridge. Versions follow `X.Y.Z+build` in `pubspec.yaml`;
each release is committed on `main` as `release: X.Y.Z (build NNNN)` and tagged
`vX.Y.Z`.

## 1.2.1 — 2026-10-24 (build 4019)

**The map no longer goes blank when the on-device layer has nothing, and the
rain announcement stops firing on another province's weather.**

- **A missing tile now switches source instead of drawing nothing.** When the
  chosen layer is `offline` / `vector` and the downloaded tiles or the vector
  archive do not cover the position, the loopback tile server asks the network
  (OSM first, then ESRI Street) instead of returning a 1×1 transparent tile.
  With no connection there is still nothing to fetch, and the log says so once
  per session. CARTO is deliberately not a fallback: its keyless endpoint
  answers with a uniform 2 KB placeholder in every city (measured 2026-10-24),
  which is the same blank map under a different name.
- **Outside the vector archive, the vector style is dropped.** The archive only
  covers the HCMC box, so past it the chosen raster layer was hidden under a
  vector style with no tiles. It now renders the raster style directly.
- **No wasted basemap inside the archive.** With an on-device layer over HCMC
  the vector tiles are the map; the raster basemap under them was invisible and
  would now have downloaded tiles on mobile data for nothing.
- **Rain is announced from the car's own weather, not an airport's.** The METAR
  radius drops from 60 km to 15 km, `VCSH` / `VCTS` / `NSW` no longer read as
  rain at the car, and a point forecast at the car's coordinates now beats a
  coarse source that reports precipitation elsewhere.
- **“Weather ahead” is sampled from the car.** It walked the route from its
  start and reset the window at each sample, so every point read ~1.5 km; it now
  measures 1.5 / 3.0 / 4.5 km ahead of the current position.

### Internal

- `NavTileServer.resolvePlan()` is pure and unit-tested: on-device layers get an
  online fallback only while connected, online layers keep their own
  style-matched mirrors.
- `metarWeatherCode` and `pickWeatherCodePreferPoint` are `@visibleForTesting`
  and covered by `test/unit/weather_test.dart`.

## 1.2.0 — 2026-10-24 (build 4018)

**Motorbike routing uses a motorcycle graph, and Waze limits are no longer
capped by a false “urban” guess.**

- **Offline motorbike graph.** The routing archive now carries both `car` and
  `motorcycle` profiles. The motorcycle profile bans motorways, so a motorbike
  route no longer follows the car graph onto an expressway. The app downloads
  the new `vietnam_graph_v2.ghz` (~257 MB) once; the old car graph is left
  untouched for older app versions.
- **Khu dân cư comes from R.420/R.421 signs.** At navigation start the route's
  first boundary sign seeds the built-up state; crossing later signs flips it.
  The POI/road-density probe is only a fallback when the route has no boundary
  sign at all. QL1 near Dầu Giây was being called urban by the density probe
  and capping a real Waze 90 to 60.
- **Waze >60 forces a rural ceiling.** 70/80/90 are not legal urban limits, so
  a posted Waze/VietMap value above 60 is treated as rural: 90 also implies a
  divided road (mô tô 70), 70/80 use the rural two-way 60 unless the graph form
  says divided. Waze 60 remains form-dependent (urban divided 60 / urban
  two-way 50).
- **Repeated KDC callouts are suppressed by zone state.** Once already inside
  or outside by sign, another same-direction R.420/R.421 point does not speak
  again.

### Internal

- Graph builder emits `car` + `motorcycle`; Android loads both profiles and
  passes the requested profile through the routing MethodChannel.
- New `_v2` graph path so a car-only archive cannot be loaded against the new
  profile list (GraphHopper refuses mismatched profiles).
- Boundary-sign seed is best-effort and runs at navigation/simulation start;
  no boundary data keeps the density fallback.

## 1.1.9 — 2026-10-23 (build 4017)

**Landscape navigation gives the map back, and a day's trips can become one
file.**

- **Landscape nav uses floating pills.** On a phone held sideways the turn
  banner and the ETA card no longer span the full width above and below the
  map. They float as compact pills (64% / 58% of the width, 64 px / 52 px tall)
  with smaller type, so most of the short screen stays map. The recenter button
  moves to the free bottom-right corner; the speed island still drags freely.
- **"Gộp theo ngày" can really merge a day.** Each day group gets a merge
  action: fixes from every trip that day are sorted by time, duplicate
  timestamps dropped, and pauses longer than 30 minutes become break indices so
  the map draws one polyline per continuous drive instead of a straight jump.
  The result is one `YYYY-MM-DD_…_Gộp_ngày.json`; originals move to
  `trips/originals/` (never deleted) and are included in the trip backup.
- **Releases are signed with a persistent upload key.** The previous GitHub
  APKs were debug-signed with a fresh CI key on every run, so Android refused
  to update one release over another and users had to uninstall (losing app
  data). From this build the `ANDROID_*` repository secrets point at one
  upload keystore, so later releases update in place.
  *One-time migration:* a device still on a debug-signed 1.1.8 (or older)
  GitHub APK must uninstall that APK once before installing this signed build;
  export trips first. After that, updates keep settings, offline data and trips.

### Internal

- `LoadedTrip` carries `breaks` and `segments`; the trip map draws a polyline
  per segment and distance/statistics skip the gap. Backup format adds an
  optional `archived` flag so restored originals go back to `trips/originals/`.
- Compact `NavTopBar` / `NavigationCard` variants are covered by overflow tests
  at 360 px pill width.

## 1.1.8 — 2026-10-21 (build 4016)

**Camera data is now nationwide, Google routing finally uses live traffic, and
the app can tell you how much of the free Google quota this phone has spent.**

- **Camera database: 30,990 → 31,979.** The phạt-nguội lists of all 33
  provinces were scraped (8,364 rows), geocoded with the Google Geocoding API
  (5,381 addresses → 2,396 usable points) and merged: 1,042 new points, 239
  nameless VietMap rows replaced, 53 redundant neighbours dropped, 120 m dedup.
  1,265 of the points now carry what the camera watches (`penalty_camera` 641,
  `speed_camera` 466, `red_light_camera` 158) plus the CSGT unit and the camera
  code. A hand-kept list like this is only announced with the “có thể có camera”
  wording unless a Waze/VietMap camera sits at the same spot.
- **Google routing asks for traffic.** Both paths were computing ETAs from
  free-flow time: the legacy Directions call had no `departure_time` (so Google
  returned no `duration_in_traffic` at all) and the motorbike Routes API call
  had no `routingPreference`. Measured on Q1 → Thủ Đức: 3,250 s without,
  3,454 s with traffic. Car routing does not change billing SKU (alternatives
  already put it on Directions Advanced); motorbike moves to Compute Routes Pro.
- **Google API meter** in Settings → Nguồn dữ liệu: per-SKU calls this month,
  remaining free calls and the overage cost. Google exposes no “calls
  remaining” API, so this counts on-device and says so.
- **PiP is readable again.** 5 signs + 5 cameras instead of the street-level
  curve’s 20 + 12, and the window gets +/− zoom (it cannot be pinched).
- **Voice pack tempo is its own setting** (`Tốc độ giọng đọc sẵn`): recorded
  clips are no longer replayed at the TTS rate, which played every announcement
  at 0.55× of the tempo it was recorded at.
- `NAVBRIDGE_TARGET_SDK` build override, used to probe whether an OEM
  split-screen allowlist is keyed on targetSdk ≥ 34.

### Internal

- **45 HCMC camera points re-geocoded.** The source lists had addresses whose
  stated district did not match the point (some sat in Vũng Tàu, Thủ Dầu Một or
  Tân Thành). Each was re-geocoded with district-scoped queries and scored
  against the expected ADM2 polygon and street tokens; the camera DB is v6
  (31,979 points, still zero same-focus pairs within 80 m).
- **Voice callouts fire once per zone.** Far/near/final zones are now a pure
  function (400/300/100 m, speed-scaled), a stale `await` can no longer speak a
  maneuver the car has already passed, and the next-street limit write is
  guarded after every await. Red-light cameras cover the junction with one
  warning; sign callouts use the 60 m route corridor.
- **Speech recognition falls back on-device.** A network/start failure switches
  the recognizer to on-device and alternates engines if that also fails, instead
  of silently leaving voice commands dead offline.
- **Heavy data work moved off the UI isolate.** The 5.6 MB camera index, ~8 MB
  sign index and 14 MB gzipped segment pack are decoded with `compute`; near
  camera/sign queries use a 0.02° `PointGrid` instead of scanning all 32k/11k
  rows; the 1 Hz nav layer skips `setState` when the drawn markers are
  unchanged; the auto tile cache is capped at 300 MB (trimmed to 80%).
- The voice-callout audit no longer compares a maneuver callout's limit with the
  limit under the car — that number belongs to the street being entered. The
  next-street check is `tool/announce_speed_audit.py`.

## 1.1.7 — 2026-10-14 (build 4015)

**The layer you pick is remembered, and the vector map is always underneath.**
Three follow-ups found by driving 1.1.7, all in the map's fallback chain:

- The basemap layer was per-session page state, so the layer menu's choice was
  thrown away on every launch — pick OpenStreetMap, restart, and the offline map
  came back (*"map osm still not show when start"*). It is saved with the other
  nav preferences now, and an id this build does not know falls back to `offline`
  rather than leaving the basemap blank.
- The vector archive is the base for **every** layer, not only for
  `offline`/`vector`. Picking an online layer used to render raster-only, so the
  30 MB archive the app carries went unused — and when that layer was
  rate-limited, blocked or simply unreachable there was nothing underneath it: an
  empty map. The picked layer draws BELOW the vector layers now, so it shows
  through where the vector has no data and the vector map is what remains when the
  layer cannot be fetched at all.
- The `osm` source had no fallback servers on purpose (mirrors label in their own
  language), so an OSM rate limit or IP block left the map blank — and OSM does
  block: a bulk pack fetch got this network banned. `tile.openstreetmap.de` and
  `openstreetmap.fr` are tried after the primary now, and the detector that
  triggers the failover was broken in **both** directions: OSM's "Access blocked"
  page is a 6 997-byte 256x256 PNG, over the old 3 000-byte guard, so it was never
  detected and the app *drew it as the map*, while a genuinely empty tile
  (~103 bytes) was flagged as a block and marked the server blocked over open sea.
  The size band (4-40 KB) separates them.

**The basemap you pick wins over the cache again.** Reported from the device:
*"my map still fallback to using the carto even when have the network"*. The
disk cache was consulted BEFORE the online fetch in both tile paths, and the
cross-source caches hold imagery from a DIFFERENT provider than the one you
selected — so the bundled `overview` pack (z0-z8, captured from CARTO) was what
an OSM or vector selection rendered at those zooms, online or not. Order is now:
the selected source's own cache (same provider, so it still saves the request)
→ online fetch → the cross-source caches → transparent. The same reorder applies
to the browse map, where `source == 'osm'` also used to fall back to the `carto`
directory (bulk region downloads are CARTO) and where a missing tile was
synthesized from a CARTO ancestor.

**The bundled overview map no longer carries CARTO's stamp.** Every tile in the
shipped pack was stamped "API KEY REQUIRED — carto.com/basemaps" and no build
ever had a CARTO key: measured, `.../voyager/8/203/120.png` answers **2 049 B**
without a key and **20 325 B** with one, and `release.yml` was not passing
`CARTO_API_KEY` at all. The pack is regenerated from keyed CARTO (same imagery,
no stamp) and the key is now a release secret.

**A recording says WHICH ceiling clamped its limit.** The trip log carried
`oneway`/`lanes`/`divided`, but not `RoadInfo.formKnown` — the flag that decides
whether a posted value is clamped by the road form's ceiling (50 hai chiều / 60
đường đôi for a mô tô in town) or by the ZONE ceiling (60) when the form is
unknown. Auditing the 2026-10-14 08:47 drive against the app's own
`vehicleCeiling` left 33 fixes on Lũy Bán Bích that published 60 while the form
logged for them (residential, two-way, no lanes) derives 50 — and the recording
could not say whether the ceiling had been skipped or the form was honestly
unknown. The layer-rename path copies the previous road's tags and marks the form
unknown, so those carried-over tags read as a two-way road unless this flag is
recorded next to them. It is now, and the log schema test pins both directions.

### Internal

- `tool/build_overview_tiles.py`: rebuilds the overview pack from
  `--provider osm|esri-street|carto`, reproducing the pack's EXACT (z,x,y) set so
  only the imagery can change. It refuses to write when a provider is not really
  serving tiles: it fingerprints OSM's "Access blocked" page (which arrives as
  **HTTP 200 with valid PNG magic**, 6 987 B — OSM blocked this machine's IP on
  the first attempt, and all 171 fetches were that page) and CARTO's
  "API KEY REQUIRED" placeholder, rejects non-images, and aborts when under 90%
  of the CONTENT tiles are distinct. Blank tiles are not failures: open sea
  legitimately encodes as a ~103-byte 1-bit PNG, so they are reported (38 of 171)
  and excluded from that ratio.
- The street-baseline golden now SKIPS when `assets/trips/index.json` is absent
  instead of throwing `PathNotFoundException` — `assets/trips/` is not in git
  (and `tool/stub_assets.sh` does not recreate it), so CI went red on 1.1.6 while
  every dev machine passed.

## 1.1.6 — 2026-10-14 (build 4013)

**The driven part of the route clears as you drive it.** The route line's
rebuild key did not include the car's own position, so the line was only re-cut
when the consumed *vertex* index changed — on a long or sparse segment the part
already driven stayed drawn behind the car. The key now carries the position
quantised to ~11 m, so the consumed line is removed on the fix.

**A limit no longer survives leaving the road it came from.** The posted-value
hold is gone from both writers. On a layer MISS the road name falls back to the
previous one, so the hold's same-road test was a tautology — it was really only
a 300 m timer, and it kept a posted 60 alive on a road the layer knows nothing
about. Reproduced on Luỹ Bán Bích → Thống Nhất (no per-segment coverage, dial
stuck at 60 for the whole street).

**Voice clips obey the speaking-rate setting.** `playAsset` accepted a `speed`
argument and dropped it, so every recorded clip played at 1.0× while the TTS
sentences used the user's rate — the two never matched. The rate is now applied
after `prepare()` (the decoder must be configured first) and guarded, so a rate
the decoder rejects falls back to 1.0× instead of silencing the announcement.

**A deliberate multi-window declaration.** `resizeableActivity` on the activity,
no `screenOrientation` or `taskAffinity` lock, `allow_multiple_resumed_activities`,
and a `<layout>` giving the freeform window its minimum size — so a window
rearrangement neither recreates the activity nor restarts navigation, and PiP
and split share the compact layout. Known limit: the stock ROM on the TB331FC
still greys out its own "Floating Window" / "Split Screen" menu entries for this
app. That gate is inside ZUI; no manifest declaration changes it.

**A hai chiều street is no longer read as a đường đôi.** The on-device graph
carries no `oneway` and no `lanes` encoded value, so the road FORM was unknown
for every street and the ceiling fell back to the zone one — 60 in town even
where a mô tô may only do 50. `car_access` *is* stored, per direction, and
"exactly one direction open" is precisely a one-way way (which is also how a
divided road is mapped, one way per carriageway). The form now comes from that
pair, so a genuine hai chiều street caps at 50 again and a đường đôi keeps 60.
Verified against the shipped graph with `tools/ProbeOneway.java`.

**Settings → Dẫn đường → "Nguồn hướng" picks where the heading comes from.**
"Điện thoại" uses the heading the receiver reports with each fix, which exists
below the 2 m of movement the travel bearing needs — the case stop-and-go traffic
creates, and the one the posted-limit segment layer needs a direction for. The
same heading now reaches the graph snap, so crossing a junction no longer flashes
the name and limit of the cross street that happened to be a few metres nearer.

**Spoken announcements can be turned off for good.** Settings → Giọng nói →
"Đọc thông báo khi dẫn đường" — the same value the nav screen's speaker button
and the "tắt tiếng" voice command write — is now persisted, so a drive armed in
silence stays silent instead of having to be re-toggled. It gates *every*
guidance path, including the camera sentences, which was the one path that never
checked it. The replay harness can arm both with `?voice=off` / `?heading=phone`.

**A Windy key can be pasted in Settings, and the weather chain was fixed.**
The key is stored encrypted on the device (the build-time `--dart-define` stays
as the dev fallback), so trying one no longer needs a rebuild. Three live bugs
went with it: `weatherWarnings` is not an allowed GFS parameter and 400'd the
whole call — which is why Windy never answered while a key was configured —
`temp` arrives in kelvin and was read as °C (299 °C on screen), and
`past3hprecip` arrives in metres. METAR is now a *neighbourhood* source: a
station more than 60 km away no longer outranks the forecast, which is how a
driver in the highlands was shown another province's weather. The WMO code is
voted across the sources, so a precipitation reading is not silenced by a drier
one from a coarser source.

### Internal

- `street_baseline_test.dart` + `test/data/street_baseline.json`: a functional
  golden that replays every bundled trip through the real limit cascade and
  asserts each street's limit, source and spoken callout. The first run writes
  the golden, later runs compare against it.
- `tool/install.sh` launches with the real launcher intent
  (`ACTION_MAIN` + `CATEGORY_LAUNCHER`) instead of `monkey`/`am start -n`. A bare
  component intent produces a task the ROM does not classify as a launcher task,
  and `singleTop` then reuses that task for every later launch.
- Lifetime fixes found by audit: the BLE map clock and BLE link controller cancel
  and null their subscriptions before closing the controllers, the overlay TTS
  handle is awaited on dispose, the overlay segment index dedupes duplicate
  candidates, and the route-send continuation no longer re-emits the first point.
- `tool/oneway_street_audit.py` + `tool/drop_oneway_signs.py`: the generated
  "đường một chiều" signs were placed on plainly two-way divided arterials (WME
  stores a divided road as two one-way carriageways), so the pack is stripped of
  them until the predicate is right. `tools/signs/build_oneway_signs.py` no
  longer trusts the per-segment flag alone — the whole street must be one-way —
  and now also rejects runs outside Vietnam.
- The track-sim feed is cancelled on `dispose` (leaving the page mid-simulation
  kept firing the GPS callback for the life of the isolate), `setNavState` is
  `mounted`-guarded, and the sim-arm overrides (`?voice=` / `?heading=`) are
  dropped as soon as the settings screen hands back a new choice.

## 1.1.5 — 2026-10-14 (build 4012)

**Offline routing works on a fresh install.** A route planned in the first
second after launch could see the on-device graph as "not loaded" and fail with
*"chưa tải bộ dữ liệu chỉ đường"* — for a graph that was installed and finished
loading a moment later. The boot preload runs in the background and had not
reached `loadBestGraph()` yet; the provider's readiness gate did not cover it.
Measured on a TB331FC: the route failed at t+0.17 s, and the graph reported
loaded at t+1.35 s. The provider now waits for the load. Same device afterwards:
a 4.66 km / 7-step offline route in 2.5 s, with no network.

**The graph downloads ready-made.** The default was a 329 MB Geofabrik
`.osm.pbf` that had to be imported into a graph *on the phone* — minutes of CPU
that Android can kill halfway, and the corpse it leaves behind shadows the good
archive. It is now a prebuilt `.ghz` (on the `routing-latest` release) that
only has to be extracted: ~4 s measured, 258 MB at ~2.5 MB/s.

**Offline routing says why it failed.** One string covered every cause and it
named "this region" — the one thing the code has never measured, since no
coverage test exists. It now separates *not downloaded* / *not loaded* /
*corrupt* / *loaded but no path*, each with the action that fixes it.

**An interrupted download resumes.** The partial file was deleted at the start
of every attempt, so any interruption cost the entire transfer. It is kept now
and continued with a `Range` request (`206`), and discarded only when provably
unusable.

**Less clutter on the navigation screen.** The compass is gone from the nav
map; the fuel (⛽) and car-icon buttons are gone from the controls column; and
the POI category chips are no longer drawn over the ETA panel while navigating
(search and voice results still render). `Nhà riêng` / `Cơ quan` now flow in
the top column instead of a hardcoded offset, so a collapsed directions bar can
no longer end up beneath them.

**The 1.1.4 one-way signs are withdrawn.** Those 17,805 rows were wrong — 82.5%
of the signal sat on two-way arterials, because WME stores a divided road as two
one-way carriageways, so QL1, Trường Chinh and Cộng Hòa all qualified. They were
removed from the pack, and are not coming back until the predicate is rewritten
against local carriageway proximity.

### Internal

- Device test hooks `TEST_ROUTE`, `TEST_GRAPH_DOWNLOAD` and `FORCE_OFFLINE`
  (build-time defines, inert otherwise). The camera-bearing diagnostic is now
  opt-in via `DEBUG_BEARING` rather than always-on.
- The one-way generator is deliberately **not** in this release: it still holds
  the rejected whole-street predicate.

## 1.1.4 — 2026-10-11 (build 4011)

**A one-way street with one lane is 50, not 60.** Thông tư 38/2024 names
"đường một chiều một làn" as its own 50 km/h case, but the road-form test read
the inferred `divided` flag first, so a way tagged `oneway` + `lanes=1` still
counted as a đường đôi and showed 60 in a built-up area. A direct one-way
one-lane tag now outranks that inference, which is itself only guessed from an
opposite carriageway of the same street running alongside. Recorded on Đường
Tôn Thất Hiệp, where the attributes flip mid-street and the dial jumped 50 → 60
on the same road; the same signature appeared on Đường D2 and Lê Đại Hành.

**One-way signs, from the Waze segment data.** The sign pack gains 17,805
`one_way` rows (59,200 → 77,005) chained from the segment one-way flags, one
sign at each end of every one-way run of 85 m or more. They are drawn on the
map and deliberately not announced — a spoken "one-way" at every junction is
noise. The published pack gzips to 889 KB.

**A held limit can no longer outlive the road it came from.** A lookup miss
used to fall through a guard that was tautological on a miss, so the previous
segment's value could stand indefinitely. The value is now held only while the
car is still on the same road and within 300 m, and a value may not change
until two consecutive fixes agree on it — which stops the dial flickering
through the attributes that flip at intersections.

**The data updater actually updates.** The app's default data source is the
`offline-data-latest` release asset, not the bundled files, and that release
had 404'd since 2026-10-03 — so every pack since reached the phone only inside a
new APK. Published and verified live.

### Internal

- Track simulation: a route plus a modelled GPS receiver (lateral scatter,
speed/heading jitter, cold start, degraded and lost fixes) driving the real
`_onGpsFix` pipeline, so the algorithm can be tested without a recording.
- The voice-callout audit no longer reports the 1 Hz log artifact as a wrong
street name: a callout fired at an intersection was being compared against the
fix *after* the car had crossed. Only the pre-callout fix is accepted, so the
real defect (naming the road ahead) cannot hide.
- Offline graph source/candidate selection, geo-index build, and new sign,
camera, resident-coverage and limit-chain audit tools.
- Sign-pack backups, downloaded shapefile sources and pre-built `.pmtiles`
archives are now git-ignored.

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

Measured on one recorded drive, the device logged the segment layer answering
50 km/h from a *crossing* street's record for 29 consecutive fixes, while the
segment under the car posted 60 — its nearest point 7.9 m away, 1-11° off the
car's heading. The same wrong answer, on every fix of the stretch.

### The posted limit

- **One answer per fix.** The cascade (Waze per-segment → Waze points → VietMap
  points) returns the limit, its source layer, its street and its segment id
  together, so a caller can no longer pair one lookup's number with another
  lookup's name.
- **A segment the car is riding outranks the name we hold** — within 45° of the
  heading, in the candidate picker and in the name veto. An unknown heading is
  *not* "riding it": the score is blind at that moment too.
- **A segment lying across the car's path can no longer name or limit the
  road** (alignment is scored before distance), while a car stopped mid-turn
  still falls back to nearest-wins.
- **A segment the car has already passed can no longer supply the limit** —
  projecting beyond a sub-segment's end is penalised past the search radius.
- **The value on screen is held between parallel records of one road.** The
  source carries near-identical records a couple of metres apart with different
  values, and sometimes variant spellings that fold to one name, so a
  nearest-record answer alternated fix by fix. Continuity keeps a value already
  on screen while it sits within a 6 m band: over the recorded drives, 398 value
  changes become 368. The one-fix lag this can cost just after a turn is
  documented, not hidden.
- **A Waze value is the authority, capped only by the vehicle's legal ceiling**
  for the road form in that context (Thông tư 31/2019). The app's own road-class
  guess had been clamping it: across 56 recorded drives, 103 fixes showed
  30 km/h where the layer posts 50 or 60, because the way under the car happened
  to be classed `service`.
- **A posted sign may lift a class default.** A genuine 60 on a street the
  statutory table called 50 now reads 60, and stays 60 for the length of the
  street instead of jumping where the way's class changes. A value posted for
  cars (80) is still capped for a motorbike, and a stricter own value still
  wins.
- **An OSM `maxspeed` tag is the last source and may only tighten.** Tagging
  here is sparse, often stale, and car-oriented, so it can no longer set or
  raise a motorbike or truck limit — and the chip reads "osm" only when the tag
  actually decided the number.

### Road matching

Audited against OSM, the app named a street that was not the way under the car
on **265 of 552 fixes (48%)**; when it differed, the street it claimed was a
**median 119 m away** while the correct way was **4 m**. The name, the class and
therefore the built-up 50/60 limit all followed that wrong road.

- **The road is resolved at the raw fix**, not at the route-snapped point. The
  projection lags at a junction, so the lookup kept answering with the leg the
  car had just left.
- **The route is a veto**: a road the route never touches cannot be the road
  under the car.
- **A name change must be confirmed twice, or 30 m driven** — and one fix now
  counts once, because two writers publish a road on every fix and both
  proposals together burned the confirmation budget inside a single fix.
  Accents, case and punctuation are no longer a change, so a folded spelling
  variant cannot repaint the label. On a replayed drive: name changes 76 → 15,
  oscillations 64 → 10.
- **The graph lookup is heading-aware.** The heading/class candidate picker was
  never called: the native lookup took whatever edge was nearest, so a service
  alley metres away set the class (30 km/h on a 50/60 road) and a footway set
  10 km/h twice.
- **Snap distance was metres, not kilometres.** It was multiplied by 1000, which
  made every distance dwarf the class penalty and left the whole class-scoring
  rule inert.
- Every road publish now goes through one place, so the graph, Overpass and
  segment paths cannot drift apart again.

### Voice

- **Turns are announced at 400 / 300 / 100 m** (they were timed in seconds,
  which fired at 350/120/80 m at 30 km/h). The seconds rule survives as a floor
  on fast roads; the final callout is a fixed 100 m.
- **One phrase, one number.** Three different sentences carried one fact, two of
  them composable seconds apart; all three now say "giới hạn tốc độ <X> km/h",
  matching the pre-recorded clip, and a value already spoken is remembered for
  45 s so it is not announced again when it takes effect.
- **The spoken number is the vehicle's maximum for that road** — never above the
  road's own limit, never above the vehicle's ceiling. The lower-limit-ahead
  warning now caps the sign's value for the vehicle too.
- **The callout's speed is the street being turned INTO.** It used to append the
  limit of the street *under the car* to a sentence about the *next* street: on
  the recorded drives, all 31 callouts that spoke a limit matched the old
  street, and 6 named a number the next street does not have. The lookup now
  samples the route past the turn with the outgoing bearing, requires the
  supplying segment to be the street the engine named, and says nothing at all
  when it cannot tell — a wrong number is worse than none.
- **One red-light warning, not two**: a junction with a traffic light and a
  red-light camera produced both callouts.
- **Surveillance-camera chatter is capped** to one sentence per 20 s — 23 of 51
  announcements were cameras, 9 inside a two-minute window, 8 of them the same
  sentence. Speed, red-light and fine cameras are unaffected.
- **The spoken direction follows the route geometry** when the router's
  left/right label disagrees with the path actually taken (decisive angles only;
  U-turns and roundabouts are never overruled). Every maneuver callout now logs
  its icon and turn angle, so the next drive can be checked from the JSON.
- A debug line about a skipped next-street limit was written with the
  announcement logger, so it appeared in trip files as if it had been spoken and
  the audits counted it as a callout. It is a debug print now.

### Signs and enforcement data

- **Real QCVN artwork** for the kinds the Waze decode and the VietMap dumps
  emit, with the codes corrected: the overtaking ban is P.125, the U-turn ban
  P.124a, the lane-direction boards R.301a/d/e — the previous codes pointed at
  unrelated pictures.
- **One camera icon everywhere** (nav map, browse map, overlay chips,
  previews), replacing a Material glyph in one place. The provenance dot is
  gone; the tap sheet still names the source.
- **Coordinates regenerated from the real sources**: 4,264 rows repaired from
  the official dump and 4,118 from the Waze decode (median move ~41 m, max 60),
  468 duplicates collapsed, coarse speed rows 4,122 → 536 (19.9% → 3.1%), and
  3,261 speed rows correctly attributed.
- **Rows whose coordinate cannot place them on a road are dropped at load.**
  The index had been snapped to a ~111 m grid, and the app *speaks* the turn
  kinds, so a sign half a block away warned on the wrong street. 9,762 rows
  (23.8%) used to be discarded for this; it is 1,401 now.
- **Signs the car has already passed are dropped, and turning back re-admits
  them** — the test is the live heading, so there is no state to reset. The
  route sign corridor is 60 m (was 200 m: 12 signs on the driven stretch
  against 23, eleven of them off-segment), and announcements exclude anything
  more than 40 m to the side of the route.

### Routing and the map

- **The provider chain is explicit** — one file holds the order and a
  capability matrix, so the router obeys what the settings screen prints, and
  every fall-through says so in a notice instead of looking like a working
  route. **Google honours the avoid toggles at last** (legacy and Routes v2), and
  bicycle/walking routes stop being requested as driving. Measured on a coastal
  corridor: 96.8 km / 113 min → 109.8 km / 167 min with highways avoided.
- **One verified instruction-sign table.** `7` is KEEP RIGHT, not a roundabout —
  every keep-right fork used to announce a roundabout; the roundabout-exit,
  keep-left and ferry signs had no case at all and fell through to "go
  straight", inviting the driver past the exit they were meant to take.
- **The nav map is no longer blank above the archive's zoom ceiling.** The
  bundled archive holds z0–z16 while the camera sits at z19 and the style never
  declared the source's zoom range, so the renderer asked for tiles that do not
  exist: the vector layers drew nothing and only a raster base remained. The
  renderer overzooms now, and the declared ceiling is what stops the low-end
  phone stuttering.
- **One implementation of the speed-limit chain.** The Overpass lookup, the
  graph lookup and the floating overlay each had their own copy and had drifted
  — the overlay still used the rural default inside a city.
- **One reader for "downloaded copy vs bundled asset"**, so a published update
  actually takes effect. The posted-limit data had been read from the bundle
  only, which meant OTA updates to it could never apply on a device.

### Offline data and the graph

- Download the Việt Nam OSM extract and build it on the phone, with progress
  across the download and the conversion. The streaming download is verified
  (length, no HTML error page) before the file is put in place, and a failed
  import cleans up after itself.

### Simulator and tooling

- **A trip server**: view any recorded drive in the browser, switch between
  trips, pull them off the phone with adb (no debug build needed), and read the
  audit — no rebuild per trip.
- **The Waze segment layer is drawn under the trip path**, with a coverage
  endpoint, which is what made "is this limit right?" measurable: 78% of fixes
  on one drive had a segment within 25 m, and geometry — not the search radius —
  accounts for the rest.
- **The app's road and limit rules are ported to Python** and replayed against
  recorded drives, so a rule change can be measured before it ships. On one
  drive the ported chain matched the route's own street name 94% of the time,
  against 56% for the answer the app had logged.
- The limit audit now scores a posted sign and a deliberately held value as what
  they are, instead of counting both as defects.
- **Trip replay and resume**: a replay's roads are keyed by street, highway and
  form, and a resumed drive picks up where it stopped.

### Tests, CI and build

- **The suite is split in two.** `test/unit/**` is deterministic and reads no
  data pack; `test/func/**` drives the app against the shipped packs and
  recorded trips. `tool/check.sh` runs the two lines separately and refuses to
  pass when a test file sits outside them, so the split cannot silently stop
  covering something — and CI calls that script instead of its own two steps.
- New suites cover the ridden-segment rule, trip-replay step naming and source
  shapes, offline links, limit changes, trip resume, nav layout maths, resident
  trips and urban areas, sign priority, and the instruction-sign table.
- **171 synthetic drives** chained from the Việt Nam OSM extract, in
  `test/data/trips`, for the country-scale runs (plus an OSRM route fixture).
- **Five tests stopped failing on the absence of local-only data** — see "Build
  and release" below.

### Build and release

- **`release.yml` builds again.** Two things had to be committed or switched off
  first: `tool/signs_app_filter.py`, which the sign-placement gate imports (the
  module existed only in a working tree, so the release job died on the import in
  1m40s), and then the gate itself — it compares the sign asset against a
  41,373-row baseline, and `assets/offline_map/vietnam_signs.json` is a 13-byte
  stub in git, so it answered "every kind is gone from the asset" for an
  environment that never had the pack. `release.yml` now sets
  `SKIP_SIGN_GATE=1`, the switch `tool/build.sh` already carried; the gate still
  runs locally, where the real pack is checked out.
- **The data packs are local-only, and five of them are stubs in git**
  (`vietnam_signs.json` 13 B, `vietnam_cameras.json` 15 B,
  `waze_speed_limits.json` / `vietmap_speed_limits.json` 26 B,
  `vietnam_speed_limits.geojson` 43 B) — only the Waze segment pack
  (`waze_segments.bin`, 28 MB) ships in the repo. CI stubs whatever is missing
  and the data-driven tests skip themselves; the real packs arrive over the air.
- **Tests no longer fail on the absence of those packs.** Five did: three
  `long_*` cases preferred `build/web/trips/<id>.json` (a build artifact the
  browser harness generates) over their own fixture, so they passed only where
  the converter had been run and died on `expect(locs, isNotEmpty)` in CI; one
  replayed the driver's own recording out of the gitignored `docs/trips/`; one
  counted sampled points from the stub Waze/VietMap point files. The fixtures are
  now the only input, the recording case skips, and an empty pack is a skip
  rather than a failure.

### Known in this release, not fixed

- The geometric override fires only for a record that lies *across* the car and
  overshoots its end, so when the name we hold belongs to a segment running
  *along* the car, that segment's value still wins.
- The motorbike ceiling can still clamp a layer value on a road whose form the
  class table does not distinguish, and the dial has not been re-checked on the
  road since these changes.
- The camera DB tags 21,724 of its 27,361 rows with "VietMap" in the `district`
  field, where a province or city belongs. The app does not read that field for
  these rows, but the province spot-check tests count by it.

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
