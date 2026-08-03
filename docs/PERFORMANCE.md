# NavBridge — Performance Test Report

Date: 2026-08-03
Device: itel P663LN (`11046644BW000992`, Android, 8 GB RAM, 8 cores)
Build: release APK (commit `9e27a0e`, ~105 MB), GraphHopper Vietnam graph loaded
Scenario: turn-by-turn navigation with the offline MapLibre vector map (heading-up + 3D tilt), simulated drive (~58 km/h)

---

## CPU usage during navigation

Sampled every 2 s for 30 s with `adb shell top -b -n 1 -p <pid>`:

```
82.7  3.5  0.0  0.0  0.0  0.0  7.1  0.0  0.0  3.5  0.0  0.0  0.0  0.0  78.5   (% of one core)
```

| Metric | Value |
|---|---|
| Steady-state (typical) | **0 – 3.5 %** of one core |
| Average (incl. bursts) | ~12 % |
| Peak | ~83 % (brief, during large camera move / full re-render) |
| Device total | 765 % idle of 800 % (8 cores) — phone mostly idle |

Notes:
- The 80 %+ spikes are short bursts during a big camera jump (heading change →
  rotated `CameraPosition` → full frame re-render). Between moves MapLibre idles
  at ~0 %.
- The test route was a pathological 14,936 km polyline (an online search match
  far away). A normal city route (≈ 8 km) is measurably lighter.
- Top threads: a binder thread ~3.4 % (tile/JNI work), RenderThread present;
  85 threads total (GraphHopper + Flutter + MapLibre + GC).

## RAM usage during navigation

`adb shell dumpsys meminfo <pid>` (while navigating):

| Metric | Value | % of 8 GB |
|---|---|---|
| **TOTAL PSS** (real footprint) | **482 MB** | **6.3 %** |
| TOTAL RSS | 599 MB | 7.5 % |
| Native heap (GraphHopper graph + MapLibre + tiles) | 224 MB | — |
| Java / Dalvik heap | ~100 MB | — |
| GPU (GL mtrack) | 55 MB | — |
| Swap | ~0.5 MB | negligible |

Notes:
- Native heap is dominated by the 258 MB Vietnam routing graph
  (memory-mapped, `graph.dataaccess=MMAP`) + bundled vector tile archives
  (PMTiles) + MapLibre geometry buffers.
- `android:largeHeap=true` is required for GraphHopper init (RAM store OOMs at
  the default heap on this device).
- No swapping observed; the app stays well within the device's free memory.

## How to reproduce

```bash
ADB=/Users/tungdl/Documents/Eink/platform-tools/adb
# 1. install + launch
$ADB -s 11046644BW000992 install -r build/app/outputs/flutter-apk/app-release.apk
$ADB -s 11046644BW000992 shell am start -n com.navbridge.app/.MainActivity
# 2. build a route (search → pick destination) then start navigation (sim)
# 3. sample CPU + RAM
PID=$($ADB -s 11046644BW000992 shell pidof com.navbridge.app | tr -d '\r')
$ADB -s 11046644BW000992 shell "for i in \$(seq 1 15); do \
  top -b -n 1 -p $PID 2>/dev/null | grep $PID | awk '{print \$9}'; sleep 2; done"
$ADB -s 11046644BW000992 shell dumpsys meminfo $PID | grep -E 'TOTAL PSS|TOTAL RSS|Native Heap|GL mtrack'
```

## Conclusion

- CPU is light for an offline navigation app: ~0–3 % steady state, brief bursts
  to ~80 % during camera re-renders. No jank-inducing pressure.
- RAM is ~482 MB PSS (~6 % of 8 GB), dominated by the offline routing graph and
  vector tiles — the price of fully offline navigation.
