# The 50↔60 flicker on arterial roads — what it is, and the fix (2026-09-23)

## Symptom the user reported
`Cầu vượt Hoàng Hoa` / `Cộng Hòa`: the chip swaps **50 → 60 → 50** every second
or two while the car never leaves the road.

```
16:22:16  ROAD: waze limit=50 -> 50 (was 60)  street="Cộng Hoà"
16:22:18  ROAD: waze limit=60 -> 60 (was 50)  street="Cộng Hòa"
16:22:19  ROAD: waze limit=50 -> 50 (was 60)  street="Cộng Hoà"
16:22:24  ROAD: waze limit=60 -> 60 (was 50)  street="Cộng Hòa"
16:22:26  ROAD: waze limit=50 -> 50 (was 60)  street="Cộng Hoà"
16:22:32  ROAD: waze limit=60 -> 60 (was 50)  street="Cộng Hòa"
```

## Cause: Waze carries parallel records for ONE road
Dumped from the layer at the car's own coordinates (2026-09-22 20:48 drive):

| street | fix | segment | distance | value | notes |
|---|---|---|---|---|---|
| `Cộng Hòa` | 10.80250,106.64096 | id 601376 | 3.0 m | **60** | `Cộng Hòa` |
| `Cộng Hòa` | 10.80250,106.64096 | id 603315 | 5.5 m | **50** | `Cộng Hoà` — folds to the SAME key `cong hoa` |
| `Nguyễn Văn Trỗi` | 10.79935,106.66917 | id 598608 | 3.7 m | **60** | named `Nguyễn Văn Trỗi` |
| `Nguyễn Văn Trỗi` | 10.79935,106.66917 | id 598613 | 3.0 m | **50** | record has NO name |
| `Trần Quốc Hoàn` | 10.80170,106.66276 | id 599324 | 6.7 m | **60** | `Trần Quốc Hoàn` |
| `Trần Quốc Hoàn` | 10.80170,106.66276 | id 601835 | 16.8 m | **50** | `Trần Quốc Hoàn (Làn xe 2 bánh)` |

So the nearest record alternates with GPS noise, and only **continuity** can pick
between them — a name rule cannot (`Cộng Hòa` and `Cộng Hoà` are the same string
after folding) and `sameRoad()` deliberately treats them as one road, which is why
the name hysteresis does not hold the value.

## Fix: continuity inside the ambiguity band
`_pickWithContinuity` (`lib/services/offline_speed_limits.dart`): a candidate that
carries the value **already on screen** wins while it is within `keepBandM`
(default 6 m) of the best candidate. `speedLimitAt(..., keepKmh:)` is fed by the
navigation writer and the overlay; mirrored in `tool/waze_segments.query(...,
keep_kmh=, keep_band_m=)`. Test: `test/waze_segment_rule_test.dart` — a real
coordinate where the plain pick takes 50 and the kept pick holds 60.

## Measured

### Same-road flips on the target track (2026-09-22 20:48, 3.84 km)
`tool/limit_flicker.py` — a flip counts only when the ROAD does not change.

| run | fixes | same-road flips | 1-fix flips | on Cộng Hòa |
|---|---|---|---|---|
| recorded drive (old build) | 543 | 30 | 8 | 24 |
| replay, clamp fix only | 527 | 32 | 6 | 25 |
| replay, hysteresis only (rejected) | 531 | 27 | 2 | 19 |
| **replay, continuity** | 526 | **14** | **0** | **7** |

Remaining 14: the slower alternations that outlive the band — Trần Quốc Hoàn
(6, the motorbike-lane record) and Cộng Hòa (7).

### Chip vs the engine's own rule (`tool/limit_audit.py`)
Each build scored against what ITS rule should produce; `--continuity` for the
builds that have it, so a held value is not counted as a disagreement, and a
`sign` state for a posted sign that lowers the layer value (by rule, see
`signLimitInForce`) instead of calling it a disagreement.

| run | ok | sign (by rule) | class fallback | **disagreed** |
|---|---|---|---|---|
| recorded drive (old build) | 493 (90.8%) | 11 (2.0%) | 17 (3.1%) | **20 (3.7%)** |
| before the fix (clamp only) | 485 (92.0%) | 11 (2.1%) | 17 (3.2%) | **12 (2.3%)** |
| **after the fix (continuity)** | **498 (94.7%)** | 14 (2.7%) | 7 (1.3%) | **5 (1.0%)** |

### What the last 5 are (every one is a single fix)
* `Trần Quốc Hoàn` — the layer holds `Trần Quốc Hoàn (Làn xe 2 bánh)` 50 right
  next to the general carriageway 60, and the pick is not vehicle-aware.
* `Cộng Hòa` — alternations whose dwell is longer than the 6 m band, plus one
  deliberate hold (60 held while the plain pick said 50).
* `Nguyễn Văn Trỗi` — the closer record is UNNAMED and carries 50.

### Why the earlier report showed 19 "bad"
14 of them were a **posted speed sign in force** (`limitSource=sign`):
`Trần Quốc Hoàn`'s segment says 60 while the sign index carries VietMap 50 km/h
signs 127–174 m away (verified in `assets/offline_map/vietnam_signs.json`; there
is also a 60 sign 37 m away), and the rule is that a sign may tighten a layer
value, never raise it. The audit had no state for that and counted the rule as a
defect — it now reports it separately as `sign`.

### The cost, measured rather than hidden
`tool/continuity_side_effect.py` — over every recorded drive (20,616 fixes):

| band | value changes | flicker suppressed (same street) | corner lag (other street) |
|---|---|---|---|
| none | 398 | — | — |
| 2 m | 334 | 58 | 158 |
| 4 m | 350 | 72 | 241 |
| **6 m (shipped)** | 368 | 74 | 278 |
| 8 m | 384 | 75 | 299 |

The corner lag is real: after a turn the road just left may still have a record
inside the band, so its value can hold for a fix. The name hysteresis holds the
NAME at the same moments, so the chip stays self-consistent.

### Still open
* Trần Quốc Hoàn: the layer holds `Trần Quốc Hoàn (Làn xe 2 bánh)` 50 next to
  the general carriageway 60. Only 2 such lane-qualified records exist in the
  whole 1,033,546-segment layer, so the pick is not vehicle-aware. Needs the
  record chosen by vehicle class + route bearing rather than distance.
* Nguyễn Văn Trỗi: an UNNAMED parallel record carrying 50 sits 0.7 m closer
  than the named 60 record, so the road name is lost with the value.

## Reports to open
- `docs/limit_audit_recorded_204857.html` — recording, old build (31 wrong fixes)
- `docs/limit_audit_replay_204857_BEFORE_fix.html` — clamp fix only (23 wrong)
- `docs/limit_audit_replay_204857_AFTER_fix.html` — with continuity
- `docs/audit_sweep_2026-09-23.txt` — every drive: chip vs layer
