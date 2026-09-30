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
