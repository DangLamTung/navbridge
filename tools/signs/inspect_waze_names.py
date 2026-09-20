#!/usr/bin/env python3
"""Does the crawled Waze data carry a STREET NAME per segment?

Why this matters: the app resolves the street NAME via GraphHopper (throttled,
stateless nearest-edge) and the speed LIMIT via a geometric Waze-segment lookup
(per fix). They desync. If the Waze segment layer carried the street name too,
one lookup could answer both and the desync disappears.

The WME dump (Decode_Waze/vn_features/*.json) is a relational export with
top-level tables: users, segments, nodes, connections, STREETS, cities, states,
countries. Segments reference streets by id; names live in the streets table.

This reports:
  * the segment property names (looking for a street reference)
  * the streets-table shape and sample names
  * how many segments actually resolve to a non-empty name
  * whether the BUILT asset (assets/offline_map/waze_segments.bin) kept any of it

Usage:
    python3 tools/signs/inspect_waze_names.py [--dir /path/to/vn_features]
"""
import argparse
import collections
import glob
import json
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SRC = "/Users/tungdl/Documents/Eink/Decode_Waze/vn_features"
BUILT = os.path.join(ROOT, "assets", "offline_map", "waze_segments.bin")


def find_ref(seg):
    """The key that points a segment at a street, if any."""
    for k in ("primaryStreetID", "primaryStreetId", "primary_street_id",
              "streetID", "streetId", "streetIDs"):
        if k in seg:
            return k
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_SRC)
    ap.add_argument("--files", type=int, default=40, help="how many dump files to scan")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "**", "*.json"), recursive=True))
    print(f"dump files : {len(files)}  ({args.dir})")
    if not files:
        raise SystemExit("no dump files found")

    sample = json.load(open(files[0]))
    print(f"top-level tables: {list(sample.keys())}")

    # Probe the SHAPE of the segments/streets tables over the first few files:
    # some exports put a meta key (e.g. 'roadTypes') alongside the records.
    for path in files[:5]:
        try:
            doc = json.load(open(path))
        except (OSError, ValueError):
            continue
        segs0 = doc.get("segments") or {}
        sts0 = doc.get("streets") or {}
        print(f"\n{os.path.basename(path)}")
        print(f"  segments: {len(segs0)} entries, value types: "
              f"{collections.Counter(type(v).__name__ for v in segs0.values())}")
        if isinstance(segs0, dict):
            for k, v in list(segs0.items())[:3]:
                print(f"     {k}: {type(v).__name__} "
                      f"{json.dumps(v, ensure_ascii=False)[:200]}")
        print(f"  streets : {len(sts0)} entries, value types: "
              f"{collections.Counter(type(v).__name__ for v in sts0.values())}")
        if isinstance(sts0, dict):
            for k, v in list(sts0.items())[:2]:
                print(f"     {k}: {type(v).__name__} "
                      f"{json.dumps(v, ensure_ascii=False)[:200]}")

    segs = sample.get("segments") or {}
    streets = sample.get("streets") or {}

    # Find a REAL segment object anywhere in the first N files.
    first_seg = None
    for path in files[:200]:
        try:
            doc = json.load(open(path))
        except (OSError, ValueError):
            continue
        for k, v in (doc.get("segments") or {}).items():
            if isinstance(v, dict):
                first_seg = (os.path.basename(path), k, v)
                break
        if first_seg:
            break
    if first_seg:
        f, sid, s = first_seg
        print(f"\nsegment example ({f}) id={sid}")
        print(f"  keys: {list(s.keys())}")
        print(f"  ref key: {find_ref(s)}")
        print(f"  json: {json.dumps(s, ensure_ascii=False)[:600]}")
    else:
        print("\nno dict-shaped segment found in the first 200 files")

    # Scale up: scan several files and tally name coverage.
    tot_seg = tot_ref = tot_named = 0
    names = collections.Counter()
    cities = sample.get("cities") or {}
    for path in files[:args.files]:
        try:
            doc = json.load(open(path))
        except (OSError, ValueError):
            continue
        st = doc.get("streets") or {}
        for sid, s in (doc.get("segments") or {}).items():
            if not isinstance(s, dict):
                continue  # meta key such as 'roadTypes'
            tot_seg += 1
            ref = find_ref(s)
            if ref is None:
                continue
            rv = s[ref]
            if isinstance(rv, list):
                rv = rv[0] if rv else None
            if rv is None:
                continue
            tot_ref += 1
            entry = st.get(str(rv))
            nm = entry.get("name") if isinstance(entry, dict) else None
            if nm:
                tot_named += 1
                if len(names) < 4000:
                    names[nm] += 1
    print(f"\nscanned {min(len(files), args.files)} files")
    print(f"  segments                    : {tot_seg}")
    print(f"  referencing a street        : {tot_ref} "
          f"({100.0 * tot_ref / max(1, tot_seg):.1f}%)")
    print(f"  resolving to a NON-EMPTY name: {tot_named} "
          f"({100.0 * tot_named / max(1, tot_ref):.1f}% of refs)")
    if names:
        print("  most common names:")
        for n, c in names.most_common(12):
            print(f"     {c:5d}  {n}")

    # Did our built asset keep names?
    if os.path.exists(BUILT):
        with open(BUILT, "rb") as fh:
            head = fh.read(36)
        magic, ver, npts, ncoord, nseg, cell, resv, lat0, lng0 = struct.unpack(
            "<4sIIIIIIii", head
        )
        print(f"\nbuilt asset {os.path.relpath(BUILT, ROOT)}")
        print(f"  magic={magic!r} version={ver} nSegs={nseg} nPoints={npts} "
              f"coordBytes={ncoord} cellE4={cell}")
        print("  fields: offsets, zigzag-varint coords, fwd(u8 kmh), rev(u8 kmh)")
        print("  -> NO street-name field: the builder dropped it.")
    else:
        print(f"\nbuilt asset not found at {BUILT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
