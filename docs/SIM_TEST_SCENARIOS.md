# NavBridge — Navigation Simulator Test Scenarios

Tested against the emulator (`eink_test`, GPS = HCMC 10.8231,106.6297) using the
**simulated drive** (SIM mode: walks the route at ~16 m/s) so the full
turn-by-turn pipeline runs without physically driving.

## How SIM works
- Flow: search → select → route preview → tap the **green play (SIM)** button.
- `_toggleSimulation()` sets `_navigating=true`, `_simulating=true`, then a
  500 ms timer advances `_simDist += 8` (≈58 km/h) along the route geometry
  (`TurnByTurnEngine.positionAtDistance`).
- Each tick calls `_handleNav(pos, speedMps:16)` → engine update → nav UI,
  voice (`_maybeSpeakManeuver`), clock frame (`_sendToClock`), road info, trip log.

## Scenario list

| # | Scenario | Steps | Expected (log / UI) |
|---|----------|-------|---------------------|
| T1 | Plan + start nav | search `chobenthanh`, pick #1, start | `PLAN: BUILD ok`; banner "Còn X …" + ETA card render |
| T2 | Voice announces ahead of turn | SIM until first turn | `VOICE: speak "Sau X mét, …"` when within 300 m, again at 80 m, final "rẽ trái…" just before |
| T3 | Step change re-announce | pass a turn | `SIM: handleNav meter=… icon=…` jumps; new "Sau X mét…" for next maneuver |
| T4 | Speed-limit / road info | SIM on a street | `ROAD: graph highway=… maxspeed=…`; chip shows EU sign + class |
| T5 | Clock frame feed | during SIM | `_sendToClock` pushes a frame (meter/icon/eta/text) each tick |
| T6 | Arrival | reach destination | `VOICE: speak "Bạn đã đến nơi."`; arrival card replaces ETA bar |
| T7 | Off-route re-route | NAVTEST auto-drives ~300 m off-route at 20 s | `SIM: REROUTE` then a fresh `PLAN: BUILD ok` (new route from the off-route fix) |
| T8 | UI chrome during nav | screenshots | banner, amber ETA bar, POI quick bar, blue recenter button |
| T9 | No GPS-vs-SIM fight | NAVTEST SIM drive | real (stationary) GPS must NOT overwrite `_current`; `SIM: handleNav dist` increases monotonically (no yank back to origin); `hasPos=false` stays ~1 (follow engaged) |
| T10 | No repeated speech | NAVTEST SIM drive | each maneuver announced ONCE (fresh) + near/final callouts; no identical `VOICE: speak` repeating every ~5 s |
| T11 | Long-distance routing | `NAVTEST_LONG` → Hà Nội | `PLAN: BUILD ok dist≈1630 km`; nav runs; follow engaged (`hasPos=false` stays ~1) |
| T12 | Smooth follow (native animation) | any nav | follow uses MapLibre `animateCamera` (interruptible, auto-cancelled on touch); car icon updates every fix (`VECTORMAP: paint car`) |
| T13 | User can pan / pinch / rotate | any nav, then gesture | gesture cancels the follow animation; `onCameraIdle` sees the deviation → follow pauses, blue recenter button appears; tap recenter resumes |
| T14 | In-turn callout | SIM near a maneuver | final callout (within ~8 s) says just the verb ("rẽ trái vào X", `now:true`) — never "Sau X mét" at the turn |
| T15 | Complex multi-turn always announced | SIM through turns | each maneuver has a DISTINCT signature (icon+road+coords) → every turn in a close series is announced once; no missed turns |

## Pass criteria
- T2: at least one `VOICE: speak "Sau …"` appears BEFORE `meter` drops below 80
  for that maneuver (announcement is ahead of the turn, not after).
- T3: `icon` changes across steps (e.g. 1 straight → 2 turn-right) and a new
  announcement fires for the next maneuver.
- T6: "Bạn đã đến nơi." spoken once; bottom card switches to arrival.
- T4/T5: logs present.

## How to run
```bash
# one-shot runner (installs nothing; uses the already-installed build)
bash scripts/sim_test.sh
```
The runner drives T1→T6 automatically and prints a PASS/FAIL summary from logcat.
