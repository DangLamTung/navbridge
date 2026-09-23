# Sign data regeneration — what was wrong, what was recovered (2026-09-23)

## The complaint
"is it correct sign, also the cấm rẽ and turn left sign is not correct" — and
then "regenerate vietnam_signs.json? didnt we recalculate the vietmap before".

Yes: `tools/signs/fix_vietmap_precision.py` ran on 2026-09-18. It repairs only
rows whose `source == "vietmap"` and only the E-DOG KC01 kinds (2,3,5,6,7,8,9),
and it now reports "already precise 13,329" for signs — its own scope is done
(the cameras were the win: 76% of the camera DB had been grid-snapped). It could
never have fixed the turn signs, for two independent reasons:

1. The E-DOG dump has **no turn types at all** (types 1–10 only, 76,236 rows,
   2026-09-09). Only 141 of the 4,073 snapped speed rows and ~9 of the 116
   snapped `no_left_turn` rows even sit in a cell with a matching E-DOG type.
2. The turn signs came from the **Waze point-notice decode**
   (`Decode_Waze/notes_combined.tsv`, 6-decimal coordinates), merged on a ~100 m
   grid that **rounded the coordinates and merged distinct signs**, then labelled
   `source: vietmap` (wrong provenance — which is why the fixer skipped them):

```
Waze TSV    16 no_left_turn  22.665712 106.256093
            16 no_left_turn  22.665709 106.257330   ← a second sign, ~100 m on
            17 no_right_turn 22.665650 106.256956
asset       no_left_turn  vietmap 22.666,106.256    ← both left signs in ONE row
```

## What was regenerated
`tools/signs/repair_sign_coords.py` (new): every snapped row is matched to the
E-DOG dump (**both** KC01 tables — two conflicting ones were used;
`check_edog_kind_mapping.py` documents that) or to the Waze decode, inside its own
0.001° cell and ≤60 m, then the precise coordinate is written and `source` fixed.

| outcome | rows | median move |
|---|---|---|
| already precise | 34,657 | — |
| repaired from E-DOG | 4,264 | 41.1 m |
| repaired from WAZE | 4,118 | 40.5 m |
| left snapped (no source places them) | 1,210 | — |
| skipped on purpose | 948 | `populated`/`populated_end`: dead kinds, and their type codes collide between the two tables |

Followed by `tools/signs/dedup_signs.py --write` (100 m, per kind): 468 rows
collapsed — the precise positions exposed same-kind duplicates the grid had been
hiding (`test/data_integrity_test.dart` caught 308 pairs within 80 m).

## Result

| | before | after |
|---|---|---|
| coarse `speed` rows | 4,122 (19.9%) | **536 (3.1%)** |
| all turn kinds | 10–100% coarse | **98 snapped of 9,531 spoken kinds (1%)** |
| `source` on speed rows | all `vietmap` | 3,261 correctly `waze` |
| rows the app drops at load | **9,762** | **1,386** |
| corridor turn signs with NO street within 30 m | 2 of 8 | **0 of 7** |

The load guard `kMinSignDecimals = 4` (`offline_road_signs.dart`) is now only the
net for those 1,210 rows instead of a filter over a fifth of the index.

### Caveat on the "junction" heuristic
`tool/audit_turn_signs.py` asks whether ≥2 different Waze street names sit within
30 m. It still reports 64% of turn signs with only one street — that number barely
moved with the coordinates, because the heuristic is weak (a T-junction, an
unnamed segment or a street name 31 m away all read as "no junction"). Use it for
the extreme case (a sign with NO street at all) and the coordinate *precision* as
the real signal.

## How to ship it
`assets/offline_map/vietnam_signs.json` is **skip-worktree in git** (`S` in
`git ls-files -v`), so the regenerated file does not appear in `git status`. It has
to be shipped the usual way (the app prefers a downloaded copy — `readOfflineText`).

## End-to-end, on the emulator, same 3.84 km track
Two replays of the 2026-09-22 20:48 recorded drive, scored identically
(`tool/limit_audit.py --continuity`), 2026-09-23 16:44 (old sign data) and 17:30
(regenerated):

| run | fixes | ok | sign | class fallback | disagreed | same-road flips |
|---|---|---|---|---|---|---|
| 16:44 old sign data | 526 | 498 (94.7%) | 14 (2.7%) | 7 (1.3%) | 5 (1.0%) | 14 |
| **17:30 regenerated** | 517 | **492 (95.2%)** | 10 (1.9%) | 8 (1.5%) | **5 (1.0%)** | **12** |

The app logged `SIGNS: dropped 1386 sign(s) …` on the second run, against 9,762
before the regeneration. No regression anywhere — and the 5 remaining
disagreements are the same parallel-record residuals (Cộng Hòa 6 flips,
Trần Quốc Hoàn 5), all single fixes, none of them a sign.

### The turn-sign announcements still need your eyes
This run still spoke `Cấm rẽ trái …` (twice near, twice far) for signs now placed
precisely from real sources:

```
  no_left_uturn   waze     10.80128,106.65439
  no_left_turn    waze     10.79801,106.65825
  no_left_uturn   vietmap  10.81226,106.66515
  no_left_turn    vietmap  10.80778,106.66425
```

Before the repair the same `no_left_turn` sat at `10.798,106.658` — a 3-decimal
position (up to ±55 m off). Whether the sign physically exists at each of those
posts is the one thing no local file can answer; that is now a drive on the phone
(installed 17:38, `base.apk` md5 verified against the built APK).

