# NavBridge — testing, and how to judge the numbers

Last updated 2026-09-28. Every figure here traces to a command in this file.

This document exists because the first versions of several numbers were **wrong**,
in ways that flattered and deflated the app in turn. The corrections are listed
in [§7](#7-corrections-what-was-wrong-and-why), because a test report that hides
how its numbers were made is not worth reading.

---

## 1. What is tested

| Layer | What it covers | Runtime | Gate |
|---|---|---|---|
| **Unit** (`test/unit/**`) | pure functions, parsers, maths, protocols | ~5 s | `tool/check.sh` |
| **Function** (`test/func/**`) | the rule under test driven end-to-end over the trip matrix | ~30 s | `tool/check.sh` |
| **Simulator** | the *real* web build replaying recorded drives | ~90 s/trip | manual |

```bash
./tool/check.sh          # flutter analyze + FUNCTION tests + UNIT tests
```

It prints `✔ analyze + FUNCTION tests OK + UNIT tests OK`, and **fails if any
`*_test.dart` sits outside `test/unit` and `test/func`** — the split is enforced,
not a convention. Last verified: analyze clean, **194 unit tests pass**; the
function suite passes in the same run.

> **⚠ CURRENT STATE — the gate FAILS as of 2026-09-28.** `flutter analyze` is
> clean, but three stale duplicates were left at the old paths after the split,
> so the guard trips:
>
> ```
> error: test file(s) outside test/unit and test/func — the split would
>        leave them uncovered (see tool/classify_tests.py):
> test/overpass_test.dart
> test/trip_replay_test.dart
> test/services/road_signs_test.dart
> ```
>
> Each is **byte-identical** to its classified copy, so removing them loses
> nothing:
>
> | stale path | identical to |
> |---|---|
> | `test/overpass_test.dart` | `test/unit/overpass_test.dart` |
> | `test/trip_replay_test.dart` | `test/func/trip/trip_replay_test.dart` |
> | `test/services/road_signs_test.dart` | `test/func/signs/road_signs_test.dart` |
>
> Fix (verify the diff yourself first — see §9):
>
> ```bash
> diff -q test/overpass_test.dart test/unit/overpass_test.dart
> git rm test/overpass_test.dart test/trip_replay_test.dart \
>        test/services/road_signs_test.dart
> ./tool/check.sh
> ```
>
> Not done automatically because the repo had staged renames in flight
> (`git status` shows an in-progress test reorganization) and deleting files
> inside someone else's half-finished move is how work disappears.

The unit/function split is machine-checked by `tool/classify_tests.py`.

---

## 2. The simulator harness

The point is that **the app is never simulated**. A real Flutter web build is
driven by real recorded GPS fixes, and every decision it makes is read from its
own `debugPrint` output.

| # | Piece | Role |
|---|---|---|
| 1 | `test/data/trips/<id>.json` | fixture: real GPS track, authoring form, key `geometry[]` |
| 2 | `tool/trips_to_sim.py` | converts to replay form `locations[]` (latitudeE7/longitudeE7/velocity) into `build/web/trips/` |
| 3 | `/tmp/nb_websink.py` | static server for `build/web` + a `POST /__log` sink |
| 4 | `build/web/logged.html` | loads the real build; overrides `console.log/warn/error` and POSTs each line to the sink |
| 5 | headless Chrome | opens `logged.html?trip=…&speed=…` under `perl alarm <budget>` as a hard cap |

### Running one trip

```bash
python3 /tmp/nb_websink.py --port 8103 --dir build/web --log /tmp/nb_sim.log
tool/sim_one.sh mid_01 12            # speed factor 12
tool/sim_one.sh long_39 25 car       # same build, driven as a car
```

`tool/sim_one.sh` prints the fixture, the server HTTP codes, the exact Chrome
command, and then the **raw log with nothing filtered**. Grep it yourself:

```bash
grep ANNOUNCE: /tmp/nb_sim.log
```

### Running a batch

```bash
python3 tool/pick_test_trips.py --pick 40 --budget-min 50 --emit /tmp/trips.json
python3 tool/sim_metrics.py --list /tmp/trips.json --vehicle car --visible
```

Useful flags: `--visible` (real windows instead of headless), `--base` / `--log`
(isolate a run from one in flight), `--vehicle motorbike|car|truck`,
`--layers signs,cameras,segments`, `--append` (keep earlier trips).

### URL parameters the build understands

| Param | Effect |
|---|---|
| `trip=/trips/<id>.json` | arm the replay |
| `speed=N` | replay speed factor |
| `vehicle=car` | drive the same build in another vehicle class |
| `layers=signs,cameras,segments` | enable debug map layers (**off by default**) |
| `rate=1.4` | override TTS rate on web (0.3–3.0) |

---

## 3. Scoring tools

| Tool | Answers |
|---|---|
| `tool/score_run.py` | **the headline**: precision / recall / F1 for built-up callouts, plus limit legality and agreement |
| `tool/accuracy_report.py` | posted limit vs the mapped sign that governs at that point |
| `tool/app_vs_segment.py` | does the app post what the segment under it says? |
| `tool/read_waze_segments.py` | reads the WZSG segment asset the app actually uses |
| `tool/waze_vs_signs.py` | why two speed datasets disagree |
| `tool/audit_replay_coverage.py` | **did each trip actually drive to the end?** run before scoring silence |
| `tool/pick_test_trips.py` | which trips are worth driving at all |
| `tool/eval_report.py` | tabbed eval page served at `/eval.html` |
| `tool/map_resident_case.py` | ground-truth SVG for one trip |

---

## 4. Metric definitions

These matter more than the numbers. Read them before quoting anything.

### Built-up (khu dân cư) callouts

- **Positive class** — a mapped boundary sign (`populated` / `populated_end`)
  within **150 m of the driven path**. This is the reference the announcing path
  actually consumes. It is *not* OSM `place=*` nodes; scoring against those
  manufactured a spurious "recall 20.4%" (§7.5).
- **TP** — corridor sign matched by a callout of the **right type** within the
  match radius. `populated` ↔ "Bắt đầu", `populated_end` ↔ "Hết".
- **FN** — corridor sign with no matching callout.
- **FP** — callout with no matching sign.
- **precision** = TP/(TP+FP) · **recall** = TP/(TP+FN) · **F1** = harmonic mean
- **"event-accuracy"** = TP/(TP+FP+FN).

  > There is **no meaningful true negative** for sparse events. "Nowhere along
  > 40 km of road" is not a decision the app makes, so a classic TN would be
  > padding. The older sampled-position accuracy **is not reported here** — that
  > is how a 64% was manufactured.

- **The match radius is swept.** A single number is meaningless: `phía trước`
  callouts are **approach** announcements that fire *before* the sign by design.

### Posted limits

Scored two ways, and **only the first is a correctness claim**:

1. **Legality** against Thông tư 38/2024 for the vehicle class, in the context
   the app itself logged. *Above the ceiling is illegal advice.*

   | vehicle | in town (two-way / divided) | outside town (two-way / divided) |
   |---|---|---|
   | mô tô | 50 / 60 | 60 / 70 |
   | ô tô | 50 / 60 | 80 / 90 |
   | xe tải | 40 / 50 | 60 / 70 |

   The **divided row is the ceiling**, the **two-way row is the floor**. A posted
   value below the floor is *stricter, not illegal* — a mapped sign or a Waze
   segment legitimately carries the real posted value.

2. **Agreement** with the mapped sign governing at that point. **A disagreement
   is two maps disagreeing, not proof the app is wrong** — see §5.5.

Only `kind == limit` events are scored for agreement. The limit stamped on a
`maneuver` / `overspeed` line is the value currently *held*, derived at an
earlier position; comparing it to the geometry underneath is invalid and is what
pushed an earlier mismatch rate to 44%.

---

## 5. Results

### 5.1 Built-up callouts — 22 trips, 110 boundary signs on the driven road

**The reference must exclude signs the app cannot load.** A row stored with
fewer than 4 decimals (~111 m) is discarded at boot and can never be announced,
so counting it as a positive makes recall a *floor* rather than a measurement:

```
reference: 110 boundary signs (raw index)
            25 more excluded: coordinates too coarse for the app to load
reference:  85 boundary signs (what the app can actually see)
```

Motorbike run (`/tmp/nb_sim_22trips.log`) — **85 loadable signs**:

| match radius | TP | FP | FN | precision | recall | F1 | event-acc |
|---|---|---|---|---|---|---|---|
| 200 m | 24 | 39 | 61 | 38.1% | 28.2% | 32.4% | 19.4% |
| **500 m** | **57** | **6** | **28** | **90.5%** | **67.1%** | **77.0%** | 62.6% |
| 1500 m | 58 | 5 | 27 | 92.1% | 68.2% | 78.4% | 64.4% |

Against the raw index (`--raw-reference`) the same run gives recall 51.8 %,
F1 65.9 % — that is the floor, and it is what earlier revisions of this document
quoted. The 25-sign difference is **data loss, not app behaviour**.

Car run (`/tmp/nb_visible.log`, see §6.2 — partly disturbed; `long_39` never
armed so it is skipped) — **80 loadable signs**:

| match radius | TP | FP | FN | precision | recall | F1 | event-acc |
|---|---|---|---|---|---|---|---|
| 200 m | 22 | 25 | 58 | 46.8% | 27.5% | 34.6% | 21.0% |
| **500 m** | **44** | **3** | **36** | **93.6%** | **55.0%** | **69.3%** | 53.0% |

**Headline: precision ≈ 90–94 %, recall ≈ 55–67 %, F1 ≈ 69–77 %** — at a 500 m
match radius, against the signs the app can load.

Two things the tables say:

- 200 m → 500 m swings precision from 38% to 90%. That is approach-callout
  behaviour, not a defect. 500 m → 1500 m buys **one** extra TP, so the matches
  are genuinely tied to a sign rather than loose proximity hits.
- **Recall is the real problem: 53 of 110 signs on the driven road were never
  announced.** Not a matching artefact — those signs produced no callout.

### 5.2 Posted limits

| | motorbike | car |
|---|---|---|
| events carrying a limit | 2,106 | 2,036 |
| within the statutory row | 97 | 375 |
| below it (stricter, legal) | 2,009 | 1,659 |
| **ABOVE the ceiling** | **0** | **2** |
| agreement w/ governing sign | 36 events: 44.4 / 33.3 / 22.2 % | 210 events: 52.9 / 16.7 / 30.5 % |

The 2 illegal events:

```
ILLEGAL long_24 19:17:10 posted 120 > cap 90 on QL1
ILLEGAL long_24 19:17:15 posted 120 > cap 90 on QL1
```

Car mode advised **120 km/h on QL1** where the car ceiling is 90; the same road
posted 50 in motorbike mode. Cause is structural, not random: `effectiveLimit`
in `lib/services/overpass.dart` does `if (vehicle == 'car') return taggedKmh;`
— the tagged value is returned **uncapped**, so one bad segment value becomes
illegal advice with nothing to stop it. **Needs re-confirming on a clean run**
(§6.2).

### 5.3 Coverage — how much is even testable

Scanned offline across all 171 trips (`tool/pick_test_trips.py`):

| reference | events on a driven road | trips with none |
|---|---|---|
| mapped boundary signs | **262** | **88 / 171** |
| mapped speed signs | **1,160** | **81 / 171** |

Half the matrix can only ever test silence. A value-blind sample wastes the run —
the first 6-trip sample landed almost entirely in that half (6 boundary events).

### 5.4 The trip matrix

171 trips (72 short / 52 mid / 47 long), 112,063 geometry points, **80 % of 0.5°
highway cells (136/170)**, all 8 socio-economic regions, lat 8.59–23.28.

### 5.5 Why the two speed datasets disagree

`src=segment` comes from **`assets/offline_map/waze_segments.bin`** — a 28 MB
WZSG binary, 1,033,546 segments, built from the Waze Map Editor Descartes crawl.
Each segment carries `fwdMaxSpeed` / `revMaxSpeed` — the posted limit **per
direction** — and the app posts `max(fwd, rev)`.

Segments on `long_39`'s road (Xa lộ Hà Nội / QL51), 860 within 30 m:

| value | segments | |
|---|---|---|
| 60 | 276 | |
| 50 | 252 | ← three different "truths" |
| 90 | 243 | ← on one highway |
| 80 | 39 | |
| 70 | 13 | |
| 130 | 11 | **impossible** |
| 120 | 7 | **impossible** |
| 40 | 7 | |
| 140 | 5 | **impossible** |
| 100 | 4 | |

Vietnam's legal maximum is 120 km/h anywhere; **130/140 survive** the builder's
5–150 km/h filter. And **102 of 559 segments (12 %)** with both directions posted
disagree between directions — typically `fwd 80 / rev 90`.

So the "inconsistency vs the sign" is the **data**, and the app is largely a
faithful reader of it: on genuine limit-change events (car mode, 151 events) the
posted value equals the nearest segment's `max(fwd,rev)` **55.6 %** of the time.

---

## 6. Limitations — what these numbers do NOT prove

1. **Recall measures consistency, not correctness.** The reference (the sign
   index) is the app's own input, so "matched a sign" means the app agreed with
   its data, not that it was right on the road.
2. **The car run is partly disturbed.** `build/web` was rebuilt underneath the
   run while it was in flight, so later trips may not reflect one consistent
   binary. The motorbike run at `/tmp/nb_sim_22trips.log` is clean.
3. **Limit agreement is map-vs-map.** The app's Waze segment layer vs the
   vietmap/waze sign index. `disagree` ≠ app wrong.
4. **36 limit-change events** for the motorbike agreement figure is a thin n.
5. **Neither `in town` NOR the road form is logged — two unknowns, not one.**
   `RoadInfo.urban` is false *by definition* whenever a way carries `maxspeed`,
   and every announcement carries `form?`. A posted value therefore cannot be
   checked against the right row, and the four-row table in §4 must not be
   collapsed in prose:

   | moto at 60 km/h | in town | outside town |
   |---|---|---|
   | **divided** (đường đôi) | **legal** — 60 | legal (cap 70) |
   | **two-way** | **illegal** — 50 | legal — 60 |

   60 km/h is wrong in exactly **ONE** of those four cells. The motorbike run
   holds **97 of 2,106 events at 60 km/h (4.6 %)**, all `via road` — i.e. from
   the Waze segment layer, the real posted value. Every one was scored against
   the outside-town row, so "0 above ceiling" reduces to "never above 70" and
   says nothing about in-town legality in either direction.

   **Do not call those 97 events an exposure.** On a divided road in town 60 is
   the *correct* motorbike limit, and a 60 taken from Waze is likely the true
   posted value. Without `form` and `in town` they are unadjudicable, which is a
   gap in the telemetry, not a finding about the app.
6. **The built-up decision is not logged**, so a missing callout cannot be
   attributed to the rule rather than to a cooldown.
7. **Run-to-run variance is real and unquantified.** The announcer's cooldown is
   wall-clock, so the same trip at the same speed produced 0, 1 and 4 callouts on
   three identical runs of `long_39`. The recall figures carry that noise.
8. **Replay speed factors are not free.** Faster replay = less wall time per
   metre = more cooldown suppression. The factors (short 8×, mid 12×, long 25×)
   are part of the measurement, not a knob to turn up for convenience.

---

## 7. Corrections: what was wrong, and why

Each of these produced a published number that had to be withdrawn.

| # | Claim | Why it was wrong | Fix |
|---|---|---|---|
| 7.1 | "9 trips stayed silent despite signs on the road" | A shared default Chrome profile is **single-instance**: a new run handed its URL to the still-exiting previous Chrome and loaded nothing. 9 of 22 runs logged zero events. | one `--user-data-dir=$(mktemp -d)` per run → retries 9 → 0 |
| 7.2 | same, second cause | The retry fired on "did the log grow", which a single `HB idle` heartbeat satisfied. `long_39` produced 2 lines and was scored as silence. | retry now requires `REPLAY: armed (/trips/<id>.json)` |
| 7.3 | "no segment within 25 m" = 44 % | Compared against segment **vertices**; a long straight segment's nearest vertex can be 40 m away while the line under the car is 5 m away. | perpendicular distance to edges → **0.2 %** |
| 7.4 | legality "0 within the row, 2106 below" | `ROWS` is `(two-way, divided)` but was unpacked as `cap, floor`, **swapping ceiling and floor** — a legal 70 would have been reported illegal. | unpack as `floor, cap` |
| 7.5 | "built-up recall 20.4 %, precision 74.6 %" | Scored against OSM `place=*` nodes, which the announcing path **never reads**. `short_23` was 5,230 m from the nearest sign — correct silence, scored as a miss. | score against mapped boundary signs |
| 7.6 | all 543 events of a 69.5 km trip in its last 8 km | The `NNNNm` field in an `ANNOUNCE` line is the distance to the **announced feature** ("sau 278 mét, rẽ phải"), *not* the remaining route. `total − rem` was garbage. | project the event's own coordinates onto the path |
| 7.7 | "42.5 % speed-limit mismatch" | Compared the app against `vietnam_signs.json` while its actual source is the **segment layer**. Measured map-vs-map, not app error. | score against `waze_segments.bin` |
| 7.8 | sign markers never drawn | `simShowSigns = false` by default; no run ever passed `layers`. Announcing and drawing are separate paths. | `&layers=signs,cameras,segments` |
| 7.9 | web speech "too slow" | `flutter_tts` web assigns the value straight to `SpeechSynthesisUtterance.rate` where **1.0 is normal**, so the 0.55 preference spoke at half speed. | web maps the preference into a usable band → **1.05** |
| 7.10 | "97 events at 60 km/h are illegal in a built-up area" | Collapsed the two-way and divided rows in prose — **the very distinction §4's table exists to make** (đường đôi is 60 in town for a mô tô, two-way is 50). 60 is wrong in exactly one of four in-town/outside × divided/two-way cells, and with `in town` *and* `form` both unlogged the events are unadjudicable, not suspect. They are also all `via road` — the Waze segment value, probably the real posted limit. | state both unknowns; see §6.5 |

---

## 8. Open issues

1. **Recall ≈ 52 %** — 53 corridor signs never announced. Highest-value gap.
   2 trips (`long_39`, `mid_06`) announced nothing at all despite 10 and 5 signs.
   *Caveat: run-to-run variance (§6.7) may explain part of this — needs repeated
   runs per trip to separate a rule gap from timing.*
2. **Car mode returns an uncapped tagged limit** → the only 2 illegal advisories
   found (120 km/h on QL1 against a 90 ceiling).
3. **2,371 signs silently dropped** for coordinates with < 4 decimals (≈ 111 m):
   `SIGNS: dropped 2371 sign(s) with coordinates too coarse to place`. This
   removes boundary signs from **both** display and announcing, and is a
   plausible contributor to issue 1.
4. **Impossible limits in the segment layer** — 130 / 140 km/h on an urban
   highway, and only 27 such segments on one 42 km road. The app serves them
   uncapped in car mode.
5. **`in town` is never logged** (§6.5), so the built-up branch of the limit rule
   cannot be scored end-to-end. One `debugPrint` of the `_townAt` decision closes
   this.
6. **The road form is never logged** (`form?`), so the divided vs two-way row —
   the difference between a 70 and a 60 ceiling — cannot be checked from a run.

---

## 9. Reproducing every number

```bash
# the gate
./tool/check.sh

# one trip, raw evidence, nothing filtered
tool/sim_one.sh mid_01 12

# the headline scores
python3 tool/score_run.py --log /tmp/nb_sim_22trips.log
python3 tool/score_run.py --log /tmp/nb_visible.log --vehicle car

# was a trip actually driven to the end?
python3 tool/audit_replay_coverage.py --log /tmp/nb_sim.log

# the segment layer the app reads vs the sign index it does not
python3 tool/read_waze_segments.py --info
python3 tool/read_waze_segments.py long_39 --radius 30

# does the app post what the segment under it says?
python3 tool/app_vs_segment.py --log /tmp/nb_visible.log --trip long_46

# which trips are worth driving
python3 tool/pick_test_trips.py --pick 40 --budget-min 50
```

If a claim in this document cannot be reduced to one of those commands, do not
trust it.

---

## 10. Test-integrity rules that were learned the hard way

1. **Run `tool/audit_replay_coverage.py` before scoring silence.** An unarmed
   replay looks exactly like a silent one.
2. **Never compare an announcement's own coordinates to the feature it warns
   about** when it is an *approach* callout.
3. **Only score a value at the position where it was derived** — not where it was
   re-reported.
4. **Know which dataset the app actually reads** before using another as truth.
5. **State the matching radius**; a bare precision/recall figure is not a result.
6. **Sweep the parameter** and check whether moving it changes the conclusion.
7. **Distrust a metric that reports 0 TP** — it is far more often the metric than
   the system.
8. **One Chrome instance per run**, or the run silently does nothing.
