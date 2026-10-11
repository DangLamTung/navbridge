# Handover: the road-limit chain answers from the wrong road

**Date:** 2026-09-29
**Branch:** `refactor/limit-chain-and-offline-loaders` (HEAD `c3991f5`)
**Status:** partially fixed, **the last two edits are unverified** — see §7.
**Author:** previous agent (GitHub Copilot). Read §9 before touching anything.

---

## 1. TL;DR

The driver sees the **wrong street name and the wrong speed limit** for tens of
fixes at a time. The lookup finds the correct segment (the one the GPS is on),
then **discards it** because its name disagrees with a name held elsewhere.

Two independent cases on one recorded drive are proven with data in §3:

| where | car is really on | app displayed | for |
|---|---|---|---|
| Trường Chinh turn | **Trường Chinh 60** (segment 4–8 m away) | Trương Công Định **50** | 29 fixes |
| Ba Vân stretch | **Ba Vân 50** (segment 3.4 m away) | Lũy Bán Bích **60** | 49 fixes |

The user's summary is correct and should be the design goal:

> *"all u need is just check gps position on the segment?"* — **yes.**

The code already does that in `pickSegmentCandidate` / `segmentScore`, correctly.
The problem is four **name-based gates** that run before/after it.

---

## 2. Environment and commands

```bash
# Flutter is NOT on PATH.
FLUTTER_ROOT="$HOME/Documents/Eink/flutter_sdk"
"$FLUTTER_ROOT/bin/flutter" <cmd>

# The gate. Runs analyze + test/func + test/unit. Currently 209 unit tests.
FLUTTER_ROOT="$HOME/Documents/Eink/flutter_sdk" ./tool/check.sh

# Web replay rig (the sim), for watching a recorded drive end-to-end
"$FLUTTER_ROOT/bin/flutter" build web        # ~40 s
# a leftover server is usually already listening on :8103 serving build/web,
# with POST /__log appended to /tmp/nb_sim.log
cp "docs/trips/2026-09-29_083715_Chuyến_đi.json" build/web/trips/apbac.json
# URL: http://127.0.0.1:8103/logged.html?trip=/trips/apbac.json&speed=4&from=286&v=NN
#      from=N starts at fix N (see TripReplay.urlFrom) — essential, the drive is
#      8m22s of drive time and the two problem spots are at ~56% and ~76%.
```

Gotchas learned the hard way:

- `python3 -c "…"` mangles Vietnamese far better than it should — write a script
  file to `/tmp` and run it. GNU grep here has no `\b`.
- The `Segments` reader used by every probe below is **`tool/waze_segments.py`**
  (`Segments`, `.query()`, `.grid`, `.pts`, `._geom`). It deliberately mirrors the
  Dart picker — if you change one, change the other or your audits lie.
- Overpass mirror that works from this sandbox: `https://overpass.kumi.systems/api/interpreter`
  with `curl -G --data-urlencode "data@query.overpass"`. `overpass-api.de` returns
  406 through the sandbox proxy.
- Browser-page ids go stale between tool calls; prefer the `/tmp/nb_sim.log` sink.

---

## 3. Evidence

### 3.1 What the DEVICE displayed (this is the smoking gun)

The recording is the device's own output: `TripLogger.addFix` is passed
`streetName: r?.name` (`nav_gps.dart` `_logFix`), i.e. **the name the app had
published**. So these fields are what the driver saw:

```
docs/trips/2026-09-29_083715_Chuyến_đi.json   fixes 285–313
idx  street(published)  hw        ow    ln  div  urb | lim eff src    layer
293  Trương Công Định   tertiary  None  2   False True | 50  50  road   segment
...
313  Trương Công Định   residential False None False True | 50  50 road  segment
```

`limitLayer=segment` matters: the layer **was** answering, and it answered 50.
The car was not on that road.

### 3.2 Ground truth at the same fixes

OSM (queried per §2) at fix 293 `10.79912,106.64196`:

```
  7.7 m  Trường Chinh      primary    oneway=yes
  8.8 m  Trương Công Định  tertiary
```

The Waze segment under the car, per fix (`tool/waze_segments.py`), with the
**line angle** between the car's heading and the sub-segment (0° = riding along
it; this is the number `segmentScore` uses, `mod 180`):

```
idx  hdg | winner          kmh dist  lineAngle
293  338 | Trường Chinh     60  7.1   40   ← the junction; both roads ~40°
294  301 | Trường Chinh     60  7.4    3      Trương Công Định 13.6 m, 77°
298  281 | Trường Chinh     60  4.7   17      Trương Công Định 36.6 m, 83°
301  297 | Trường Chinh     60  4.6    1
```

So the layer is right from fix 293 and unambiguously right from 294.

### 3.3 The Ba Vân case

```
idx  | recorded street  | OSM nearest (dist)      | layer
106  | Lũy Bán Bích     | Lũy Bán Bích  4.9 m     | Lũy Bán Bích 60, 4.5 m   ← correct
188  | Lũy Bán Bích     | Ba Vân        5.6 m     | Ba Vân       50, 3.4 m   ← wrong for 49 fixes
293  | Trương Công Định | Trường Chinh  7.7 m     | Trường Chinh 60, 7.1 m
```

### 3.4 The pinned case that constrains any fix (do not break it)

`test/func/limits/speed_limits_test.dart` — "speedLimitAt with the road name
known", position `10.78760,106.63698`, `headingDeg: 0`,
`expectStreet: 'Tân Thành'` → expects **50**:

```
   4.0 m  Lũy Bán Bích     60  line  9°   ← the crossing street
  54.1 m  Tân Thành        50  line 87°   overshoot 0   ← the car's own road
```

This is why "just delete the name logic" is wrong: here the name must win, and
the nearby aligned record belongs to another street. Any new rule must keep this
green.

---

## 4. Root cause: seven gates, four of them name-based

```
GPS fix
└─ _querySegIndex                       offline_speed_limits.dart:955
   ├─ _pickWithContinuity                  :1053   GATE 1  pool narrowed to expectStreet
   │  └─ pickSegmentCandidate  :857 → segmentScore :837      ← the REAL test
   ├─ post-picker name veto                :985ish GATE 2  mismatch → null ("no data")
   ├─ _segmentValue                        :1026   fwd/rev by heading
   └─ _layerNameAgrees → layerLimitMatchesNames (road_match.dart:97) GATE 3
       └─ vetoStreetFor (road_match.dart:216) decides WHICH name is handed in
└─ applyPostedLayer → effectiveLimit → vehicleCeiling   GATE 4  50/60 by road FORM
└─ _publishRoad → pickRoadName (road_match.dart:39) + RoadNameHysteresis  GATE 5,6,7
```

**GATE 1 is the bug.** `_pickWithContinuity` replaces the candidate pool with
only the records whose name matches `expectStreet` *before* any geometry is
scored:

```dart
if (band.isNotEmpty) { ids = band; radius = inside.isNotEmpty ? maxDistM : _nameBandM; }
```

At the Trường Chinh turn `expectStreet` was `"Trương Công Định"` (the matcher
returned the crossing road, 9.2 m, 77–140° across the car), so Trường Chinh was
deleted from the pool, the crossing record's 50 was returned, **and it agreed with
the wrong name**, so gates 2, 3, 5, 6, 7 all saw a consistent answer.

GATE 4 is a *separate* bug and still open — see §8.

---

## 5. What the previous agent already changed (uncommitted)

> The working tree also holds ~47 files of pre-existing refactor work on this
> branch (`git diff --stat`: 3412 insertions). **Only the items below are this
> change.** Do not attribute the rest to it.

| file | change | why |
|---|---|---|
| `lib/services/offline_speed_limits.dart` | `SpeedLimitResult` gains `final bool aligned` | the page needs to know the winner is the road the car rides |
| " | file-level `_maxAlignedDeg = 45.0`, `_maxOvershootM = 10.0` | one definition shared by `segmentScore`, `_querySegIndex`, `_pickWithContinuity` |
| " | `_pickWithContinuity` now returns **`({int win, bool byGeometry})`** (was `int`) | it must tell the caller it deliberately overrode the name |
| " | new override: if the name-filtered winner is **across** the car (`>45°`) **and overshot** (`>10 m` past its end) **and** a *different-street* candidate is **aligned**, return the aligned one with `byGeometry: true` | the car is demonstrably not on the record the name would force |
| " | `_querySegIndex` **skips the post-picker veto when `pick.byGeometry`** | otherwise it discards the override and reports "no data" |
| `lib/core/road_match.dart` | `layerLimitMatchesNames(..., bool ridden = false)`; `ridden: true` returns early | a segment the car is *riding* is evidence about the road under it, whatever name we hold |
| `lib/pages/navigation/modules/nav_gps.dart` | `_layerNameAgrees(name, {ridden})`, `_publishRoad(next, {at, ridden})`; `ridden` skips `pickRoadName` | a ridden segment must also be allowed to *rename* over the route veto |
| " | hysteresis clock `DateTime.now()` → **`navNow()`** | the gate counts *observations*; at 4× replay fixes are ~330 ms of wall time apart, so every fix read as "the same fix" and a layer-driven rename could **never** confirm |
| " | `_publishRoad(next, at: pos)` on the layer path | without a position `moved == 0`, so the 30 m confirmation escape could never fire |
| " | `_replayRoadKey` (field on `_NavigationPageState`, `navigation_page.dart`) | `_applyReplayRoad` compared the recorded name to the *displayed* name, which the layer now owns → it re-published on every fix (12 in 3 s) |
| `lib/services/trip_replay.dart` | `routeFromTrack` names its steps from the recording (`streetOver`) | steps were all `name: ''`, so the banner read "Tiến lên", callouts had no street, and `routes=` was always empty |
| `test/func/limits/ridden_segment_test.dart` | **new, 5 tests** | pins the Trường Chinh case against the real pack |
| `test/func/trip/replay_step_names_test.dart` | **new, 7 tests** | pins step naming |

The `aligned` + `ridden` + override trio is the load-bearing part; the rest is
infrastructure that a rewrite can keep or drop.

---

## 6. Proposed rewrite (what "properly" means)

Goal: **one geometric decision, name as a tie-break only.**

**DELETE**
1. `_pickWithContinuity`'s pool narrowing (the `inside`/`band` block) and
   `_nameBandM`. Replace with: score all in-range candidates geometrically
   (`pickSegmentCandidate`), and use the name **only** to break a near-tie
   (e.g. within ~2 m of the best score).
2. The post-picker name veto in `_querySegIndex`.
3. `layerLimitMatchesNames` (road_match.dart) and its caller `_layerNameAgrees`.
4. `pickRoadName`'s route veto (`road_match.dart:39`) — a ridden segment beats a
   planner's guess. Keep `RoadNameHysteresis`, it is about churn, not naming.
5. `vetoStreetFor` (`road_match.dart:216`) and the `expectStreet` parameter —
   once 1–3 are gone nothing legitimate feeds it. **Remove it from the public
   `lookupSpeedLimit` signature**, do not leave it as a no-op.

**KEEP (do not touch — each encodes a measured bug)**
- `segmentScore`: the `>45°` across-the-car penalty and the `>10 m` overshoot
  penalty. This *is* "is the GPS on this segment".
- `pickSegmentCandidate`'s hard `d > maxDistM` gate.
- `keepKmh` / `keepBandM` in `_pickWithContinuity` — that is GPS noise between
  two records of ONE road (Cộng Hòa 60/50 alternation, 2026-09-22), nothing to
  do with names. Re-express it over the geometric survivors.
- `_segmentValue`'s fwd/rev choice by heading.
- `SpeedLimitResult.aligned` — keep it; it is the honest half of the old veto.

**THEN** GATE 4 (§8): the ceiling needs the ridden road's FORM, which is not
available. That is a product decision, not code.

### Suggested order of work

1. Delete 1–3, keep the tests, run `./tool/check.sh`. The pinned Tân Thành case
   will tell you immediately whether "name only on near-tie" preserves it
   (hint: it needs `_nameBandM`'s *reach*, so you may have to keep the band as a
   **preference** with a much smaller geometry penalty than 26, not as a filter).
2. Run `tool/replay_all.py` over `docs/trips/device` **before and after** and diff
   the flip/revert/stub counts it prints. Treat any worse number as a regression.
3. Only then touch gate 3/4/5 and `nav_gps.dart`'s call sites.

---

## 7. State after the 2026-09-29 review

`FLUTTER_ROOT="$HOME/Documents/Eink/flutter_sdk" ./tool/check.sh` is **green**
(analyze + test/func + 209 unit tests). A code review of §5 found three real bugs
in it, all now fixed:

1. **`_withPostedLayer` ignored `hit.aligned`** — `if (!_layerNameAgrees(layerName))`
   threw a ridden segment away and kept the class value, which
   `_correctSpeedFromWazeInner` then re-adopted on the next fix (value flicker).
   This is NOT a simulator-only path: the 8 m graph refresh uses it too.
2. **`aligned` was true when `headingDeg == null`** (`headingDeg == null || …`).
   The page passes null for the first seconds of every drive
   (`_heading == 0 ? null : _heading`), and `ridden: true` switches the name veto
   OFF in `layerLimitMatchesNames` — while `segmentScore` is blind at the same
   moment, since its across-the-car penalty also needs a heading. So a crossing
   street's value AND name could be adopted with nothing checking either.
   Now: `headingDeg != null && …`. Measured blast radius over the 69 drives:
   **681 fixes (2.8%) have an unknown heading**, 492 of them with a segment
   within 25 m, and ~400 of those are mid-drive (not just drive starts) — so this
   was not theoretical.
   Pinned by `test/func/limits/ridden_segment_test.dart`: "an unknown heading does
   NOT claim the car is riding the segment".
3. The same missing `ridden` at the `cur == null` branch of
   `_correctSpeedFromWazeInner`.

Minor, also fixed: `_publishRoad`'s layer→`_roadOsm` baseline omitted
`oneway`/`lanes` (so a road divided via `oneway && lanes>=2` got the two-way class
value); `routeFromTrack`'s doc still claimed steps are named "" on purpose;
`_applyReplayRoad` set `_replayRoadKey` optimistically and never cleared it, so a
publish dropped by the "fix moved on" guard — or one that threw — wedged that
recorded road for the rest of the drive.

**Still NOT verified end-to-end**: no full replay has been run since the lookup
fix was finished, so nobody has *seen* Trường Chinh appear on screen. The last sim
run predates the final override; it showed the Ba Vân fix working
(`ANNOUNCE: … [limit 50 via road motorbike] <Ba Vân, secondary, …>`) and the
Trường Chinh rename landing (`+3687ms ROAD: waze limit=60 -> 50 (was 50)
street="Trường Chinh"`). Note that value: **60 clamped to 50** — see §8.

A release APK with all of this was installed on the phone (itel P663LN,
`lastUpdateTime 2026-09-29 17:01`) — but see the install trap in §14.

---

## 8. Open decision: 50 vs 60 on Trường Chinh (asked, never answered)

`effectiveLimit` clamps any layer value with the vehicle ceiling:

```dart
return math.min(vehicleCeiling(vehicle, urban: urban, divided: divided,
                               oneway: oneway, lanes: lanes), taggedKmh);
```

- `vehicleCeiling('motorbike', urban: true)` = **60 divided / 50 two-way**
  (Thông tư 38/2024).
- Trường Chinh is genuinely `oneway=yes` ⇒ divided ⇒ 60 is lawful.
- The app clamps to 50 because the form it uses is **the other road's**
  (`tertiary, oneway=null, lanes=2, divided=false`), i.e. Trương Công Định's.
- The layer cannot supply the form: its `separator` bit is set on **0 of
  1,032,156** segments (verified). It carries `roadType` only, and on this drive
  `roadType 7 ⇒ 60` (Trường Chinh, Lũy Bán Bích) while `roadType 2 ⇒ 50` (Ba Vân,
  Ấp Bắc, Trương Công Định, Núi Thành) — a usable signal, but unvalidated.
- In a replay there is no graph lookup at all: `_refreshRoad` returns early on
  `_startedReplay`, so `_roadOsm` can only ever be the recording.

So **Trường Chinh shows 50 today even after the name is fixed.** Options put to
the user (they skipped, then asked for the latency investigation instead):

- **A** follow the segment — do not clamp with a form that is not that road's.
  Matches the user's stated preference ("the speed max to follow the waze first").
  Risk: a genuine two-way road where Waze posts 70 would show 70 for a motorbike.
- **B** same, but still clamp when the form is genuinely that road's.
- **C** give the replay the real OSM road (network) and keep the law intact.
- **D** leave it.

Do not silently weaken this clamp — it is a legal guard.

---

## 9. Do-not-do list (measured negative results)

1. **Do not tighten the segment acceptance radius** (25 m). Device data: name
   agreement is LOWEST at ≤8 m (76%) and HIGHEST at 20–25 m (84%); churn rises
   4.5 → 12.7 per 100 fixes as you tighten; 49.9% of fixes have no segment within
   25 m. The 25 m radius is not the problem.
2. **Do not remove the name check outright.** Measured 2026-09-29 by removing it:
   Lũy Bán Bích (Waze 60) dropped to a crossing street's 50 on 5 consecutive
   publishes. (The §6 plan deletes it *and* replaces it with the near-tie rule —
   those must land together.)
3. **Do not add a same-name guard to `_pickWithContinuity`.** It breaks the pinned
   Cộng Hòa case: 50 'Cộng Hòa' / 60 'Cộng Hòa' / 50 'Thăng Long' all at 9.4 m.
4. **Do not read `speedLimit` from a recording.** `ReplayFix` deliberately does
   not: it is the old build's output. **The same is true of `street`** — it is
   what `_logFix` passed, i.e. the published name. Label with it, never use it as
   evidence about which road the car is on.
5. **Do not let the sim diverge from the device.** The user's objection
   ("but it is the app problem not web") is right: fixes belong in the shared
   lookup, not behind `_startedReplay`.

---

## 10. Probe scripts

Written to `/tmp` and therefore disposable. Recreate as needed; their logic is
what matters.

**a. Per-fix layer answer + line angle** (`nbtc`-style):

```python
import json, math, sys
sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
from waze_segments import Segments
segs = Segments('/Users/tungdl/Documents/Eink/navbridge/assets/offline_map/waze_segments.bin')
locs = json.load(open('/Users/tungdl/Documents/Eink/navbridge/docs/trips/'
                      '2026-09-29_083715_Chuyến_đi.json', encoding='utf-8'))['locations']
for i in range(292, 312):
    e = locs[i]; lat = e['latitudeE7']/1e7; lng = e['longitudeE7']/1e7; hdg = e.get('heading')
    kmh, st, cls, div, dist, sid = segs.query(lat, lng, hdg, max_dist_m=25.0)
    if sid is None: print(i, 'no segment'); continue
    _, brg, over = segs._geom(lat, lng, segs.pts[sid])
    d = abs(hdg - brg) % 180.0
    la = 180 - d if d > 90 else d
    print(f'{i} {lat:.5f} {lng:.5f} hdg={hdg} {st} {kmh} {dist:.1f}m line={la:.0f}')
```

**b. All candidates within 65 m, with the score the picker would use:**

```python
gy, gx = int(lat // 0.005), int(lng // 0.005)
for dx in (-1, 0, 1):
  for dy in (-1, 0, 1):
    for s in segs.grid.get((gy + dy, gx + dx), ()):
        d, brg, over = segs._geom(lat, lng, segs.pts[s])
        if d > 65: continue        # then print name, value(s,hdg,brg), line angle,
                                   # and d + 26 if line>45 + 26 if over>10
```

**c. What the device displayed** — read `locs[i]['street' | 'speedLimit' |
'limitEffective' | 'limitSource' | 'limitLayer' | 'highway' | 'oneway' | 'lanes' |
'divided' | 'urban']`.

**d. OSM ground truth** — Overpass `way(around:45,lat,lng)["highway"]; out tags geom;`
against `https://overpass.kumi.systems/api/interpreter` (§2).

---

## 11. The two new tests, and why they exist

- `test/func/limits/ridden_segment_test.dart` — 5 tests. The key one:
  `lookupSpeedLimit(LatLng(10.79915, 106.64191), headingDeg: 301,
  expectStreet: 'Trương Công Định')` must return **60 / Trường Chinh /
  aligned == true**. Uses the **real bundled pack**, like its neighbours, so it
  fails if the data or the picker drifts.
  Two traps when writing tests here: call
  `TestWidgetsFlutterBinding.ensureInitialized()` (without it `rootBundle` fails
  and *every* lookup returns null, so the test "passes" for the wrong reason),
  and note `LatLng` is `(lat, lng)`.
- `test/func/trip/replay_step_names_test.dart` — 7 tests. `routeFromTrack` must
  name each step from the recording's majority street, keep the tiling, and still
  degrade to the engine's placeholder when the recording has no street.

---

## 12. Corpus baseline — `tool/waze_segment_alignment.py` (NEW, 2026-09-29)

```bash
python3 tool/waze_segment_alignment.py --dir docs/trips/device --worst 10
```

Questions the layer GEOMETRICALLY only (every candidate within 25 m, scored by
`segment_score`), i.e. "is the GPS on the segment". Baseline over 69 drives /
24,000 fixes:

```
COVERAGE
  a segment within 25 m            19832   82.6%
  no segment at all                 4168   17.4%
IS THE WINNER THE ROAD UNDER THE CAR?   (of those with one)
  aligned (≤45° off heading, ≤10 m overshoot)  19094  96.3%
  across the car (>45°)                          717   3.6%
  overshot (>10 m past its end)                   19   0.1%
  distance: median 3.5 m, p90 11.0 m      line angle: median 5.0°, p90 23.8°
NAME vs the name the app PUBLISHED
  layer names a different street    3026   15.3%   (14.7% with the layer ALIGNED)
    … of which the shown VALUE would change        969   4.9%
GATE 1 (a held name forcing the wrong road)
  fixes answering from the wrong road    61   0.3%
    … of which the LIMIT was wrong       19
```

Read it this way:

- **The layer's geometry is good.** 96.3% of its answers are the road under the
  car, median 3.5 m away and 5° off the heading. "The waze segment quality is
  good enough" (user) is supported by the data.
- **The real coverage problem is the 17.4% with no segment at all**, not the
  picker.
- **GATE 1's blast radius is 0.3%** (61 fixes, 19 with a wrong limit). The
  Trường Chinh case is a 15-fix instance of it. So the override in §5 is correct
  but RARE — do not expect it to move the headline numbers.
- **The 15.3% name disagreement is NOT cleanly an app bug.** Attribution on a
  10-fix sample (same method as §3.2, `around:40` Overpass): OSM agreed with the
  LAYER 5/10, with the APP's name 4/10, neither 1/10. Roughly a coin flip — a
  large part of that 15.3% is the layer naming a NEIGHBOURING street, which is
  exactly what the veto exists for and why the override requires across+overshot
  rather than merely a name mismatch. ⚠️ The attribution script's `fold()` is
  cruder than the app's `streetNameMatches()` (no abbreviation/number rules), so
  it under-credits the layer on pairs like "QL13" vs "Quốc lộ 13". Redo the
  sample with the real matcher before quoting those percentages.

Overpass note: keep the query to ≤10 `around` clauses with `[timeout:180]`;
26 clauses returns 504 from overpass.kumi.systems.

## 13. Where the rest of the story lives

- `docs/waze-data-pipeline.md`, `tools/signs/build_waze_segments.py` — the layer
  format (WZSG v3) and build. `MIN_KMH, MAX_KMH = 5, 120`.
- `tool/replay_all.py` — the offline audit over `docs/trips/device`: runs, stubs
  (<40 m), flips, reverts, unnamed runs, fixes with no segment, hearable zones.
  This is the regression harness for §6.
- `tool/waze_segments.py`, `tool/announce_speed_audit.py`,
  `tool/next_street_audit.py`, `tool/audit_spoken_limits.py`.
- `docs/limit_flicker_fix_2026-09-23.md`, `docs/audit_sweep_2026-09-23.txt` —
  the history that produced gates 1 and the continuity band. Read them before
  deleting anything; they contain the measurements the gates were built from.
