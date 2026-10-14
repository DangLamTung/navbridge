#!/usr/bin/env python3
"""Rebuild `assets/offline_map/overview_tiles.tar.gz` from a KEYLESS provider.

Why (2026-10-14)
----------------
The shipped overview pack was captured from CARTO, and CARTO now serves
basemap tiles WITHOUT a key as a stamped placeholder — a diagonal
"API KEY REQUIRED -- carto.com/basemaps" watermark. Verified by extracting
tiles straight out of the committed archive:

    tar -xzf assets/offline_map/overview_tiles.tar.gz -C /tmp/ov
    # /tmp/ov/6/50/36.png  and  /tmp/ov/8/203/117.png both carry the stamp
    # live check: .../voyager/8/203/120.png  ->     2 049 B unkeyed
    #            .../voyager/8/203/120.png?key=  -> 20 325 B keyed

That matters because the tile cache is consulted BEFORE the network in both
map paths, so those CARTO tiles were what an OSM / vector selection rendered at
the pack's zooms (z0-z8) even with a working connection — the user's "my map
still fallback to using the carto even when have the network".

This re-fetches the SAME (z, x, y) set from OpenStreetMap's standard tiles, which
is the app's own primary basemap source, so the bundled overview finally MATCHES
the online look. No key, no watermark, no third-party licence on the shipped
bytes.

Coverage is read from the archive being replaced, never recomputed, so this can
only change the IMAGERY, not which tiles exist. Pass --from-pack with a different
archive to re-seed from another pack.

Usage
-----
    python3 tool/build_overview_tiles.py                       # dry run
    python3 tool/build_overview_tiles.py --write               # OSM (default)
    python3 tool/build_overview_tiles.py --provider esri-street --write
    python3 tool/build_overview_tiles.py --provider carto --write   # uses .env

Which provider (read this before running)
-----------------------------------------
* `osm` — tile.openstreetmap.org. The look the app's own OSM layer draws, and
  the cheapest licence-wise for a small pack, BUT their tile usage policy
  forbids "distributing an app that uses tiles" from the volunteer servers
  without prior permission, AND they rate-limit/bulk-block aggressively: the
  first attempt at this pack (2026-10-14) got HTTP **200** with a 6 987-byte
  "Access blocked — not following the tile usage policy" PNG for EVERY tile,
  which is why the block-page fingerprint below exists. Ask OSM for permission,
  or pick another provider.
* `esri-street` — server.arcgisonline.com World Street Map, keyless. A different
  look from OSM (the app already ships it as the `esri-street` layer).
* `carto` — basemaps.cartocdn.com with `?key=` from `--key` / `.env`
  (CARTO_API_KEY). Keeps the pack's existing CARTO look but without the
  "API KEY REQUIRED" stamp; check your CARTO plan allows offline bundling.

Pace + validation
-----------------
The script paces itself, and ABORTS rather than write a partial or blocked pack:
the known block-image fingerprints (OSM's "Access blocked" page, CARTO's
"API KEY REQUIRED" placeholder), a response that is not an image at all, or a
fetch where fewer than 90% of the CONTENT tiles are distinct (the signature of a
provider serving one error image for everything) fails the run. Blank tiles are
NOT failures — open sea legitimately encodes as a ~100-byte 1-bit PNG; they are
reported and excluded from the distinctness check.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_PACK = REPO / "assets" / "offline_map" / "overview_tiles.tar.gz"

# Each provider: the hosts to rotate through, the path template, and whether the
# URL needs a `key` query parameter. ESRI is the odd one out — its tile API is
# `{z}/{y}/{x}`, not `{z}/{x}/{y}`.
PROVIDERS: dict[str, dict] = {
    "osm": {
        "hosts": [
            "https://a.tile.openstreetmap.org",
            "https://b.tile.openstreetmap.org",
            "https://c.tile.openstreetmap.org",
        ],
        "path": "{z}/{x}/{y}.png",
        "key": False,
    },
    "esri-street": {
        "hosts": [
            "https://server.arcgisonline.com/ArcGIS/rest/services/"
            "World_Street_Map/MapServer/tile",
        ],
        "path": "{z}/{y}/{x}",
        "key": False,
    },
    "carto": {
        "hosts": [
            "https://a.basemaps.cartocdn.com",
            "https://b.basemaps.cartocdn.com",
            "https://c.basemaps.cartocdn.com",
            "https://d.basemaps.cartocdn.com",
        ],
        "path": "rastertiles/voyager/{z}/{x}/{y}.png",
        "key": True,
    },
}

# OSM blocks disguised scrapers; identify the app and how to reach it.
USER_AGENT = (
    "NavBridge-offline-pack-builder/1.0 "
    "(+https://github.com/DangLamTung/navbridge; offline map pack)"
)

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# Anything under this is not a tile at all (a truncated body, an empty file).
MIN_IMAGE_BYTES = 60

# ⭐ A tile under this is BLANK, not broken: open sea / empty terrain encodes as
# a 1-bit single-colour 256x256 PNG and really is ~100-200 bytes (verified: a
# CARTO z8 tile over the Gulf of Thailand is a 103-byte "256 x 256, 1-bit
# colormap" PNG). Treating those as failures aborted a legitimate pack — the
# sea tiles simply ARE empty. They are counted and reported instead, and they
# are excluded from the distinctness check below, because every blank tile is
# legitimately byte-identical to every other blank tile.
BLANK_TILE_BYTES = 3000

# Images that LOOK like a tile but must never be packed.
# * OSM answers a blocked client with HTTP **200** and this exact 6 987-byte
#   PNG, so the status code and the PNG magic both pass a naive check.
# * CARTO answers an UNKEYED basemap request with this 2 049-byte stamped tile
#   ("API KEY REQUIRED") — the very stamp found burned into the shipped pack.
# Measured 2026-10-14.
KNOWN_BLOCK_IMAGES = {
    "c069a15b2cc2d6b6f527ad09eb93c61a": "OpenStreetMap 'Access blocked' page",
    "502fc5f6793fad87dcf8ba3fa646c38f": "CARTO 'API KEY REQUIRED' placeholder",
}

# Below this share of DISTINCT images the run is not real map data: a provider
# serving one error/blank image for every request. Measured over the NON-blank
# tiles only (a pack legitimately holds many identical empty sea tiles).
MIN_DISTINCT_RATIO = 0.90


def load_env_key(name: str) -> str:
    """Read `NAME=value` from the gitignored .env (never printed)."""
    env = REPO / ".env"
    if not env.exists():
        return os.environ.get(name, "")
    for line in env.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip()
    return os.environ.get(name, "")


def read_pack_tiles(pack: Path) -> list[tuple[int, int, int]]:
    """The (z, x, y) set in [pack] — the coverage we must reproduce exactly."""
    out: list[tuple[int, int, int]] = []
    with tarfile.open(pack, "r:gz") as tf:
        for m in tf.getmembers():
            if not m.isfile() or not m.name.endswith(".png"):
                continue
            parts = m.name.split("/")
            if len(parts) != 3:
                continue
            try:
                z, x, y = (int(p) for p in parts[:2] + [parts[2][:-4]])
            except ValueError:
                continue
            out.append((z, x, y))
    out.sort()
    return out


def fetch_tile(
    z: int,
    x: int,
    y: int,
    attempt: int,
    provider: str,
    key: str,
) -> bytes:
    """One tile, cycling hosts per attempt. Raises on failure."""
    spec = PROVIDERS[provider]
    hosts = spec["hosts"]
    url = (
        f"{hosts[(x + y + attempt) % len(hosts)]}/"
        + spec["path"].format(z=z, x=x, y=y)
    )
    if spec["key"] and key:
        url += f"?key={key}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as res:
        body = res.read()
    label = url.replace(key, "REDACTED") if key else url
    if not body.startswith(PNG_MAGIC) and not body.startswith(b"\xff\xd8\xff"):
        raise ValueError(f"{label}: not a raster image ({len(body)} B)")
    if len(body) < MIN_IMAGE_BYTES:
        raise ValueError(
            f"{label}: {len(body)} B is not an image at all — empty or "
            f"truncated response"
        )
    digest = hashlib.md5(body).hexdigest()
    if digest in KNOWN_BLOCK_IMAGES:
        raise ValueError(
            f"{label}: this is the {KNOWN_BLOCK_IMAGES[digest]} — the provider "
            f"is refusing us (HTTP 200 does NOT mean a tile). Stop and pick "
            f"another --provider, or ask for permission."
        )
    return body


def write_pack(out: Path, tiles: dict[tuple[int, int, int], bytes]) -> int:
    """Write a deterministic .tar.gz (fixed mtime/uid/gid, sorted names).

    Python's TarDecoder reads it back in `offline_tiles_test.dart`, which is why
    the layout stays the plain `z/x/y.png` the extractor expects.
    """
    raw = io.BytesIO()
    # mtime=0 in BOTH the gzip header and every entry, so rebuilding from the
    # same tiles gives the same bytes — a diff is then a real data change.
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w") as tf:
            for (z, x, y) in sorted(tiles):
                data = tiles[(z, x, y)]
                info = tarfile.TarInfo(name=f"{z}/{x}/{y}.png")
                info.size = len(data)
                info.mtime = 0
                info.mode = 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                tf.addfile(info, io.BytesIO(data))
    blob = raw.getvalue()
    out.write_bytes(blob)
    return len(blob)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--from-pack", default=str(DEFAULT_PACK),
                    help="archive whose (z,x,y) coverage is reproduced")
    ap.add_argument("--out", default=str(DEFAULT_PACK),
                    help="archive to write (default: replace in place)")
    ap.add_argument("--provider", default="osm", choices=sorted(PROVIDERS),
                    help="tile source (see the docstring before choosing)")
    ap.add_argument("--key", default="",
                    help="API key for a keyed provider; defaults to the "
                         "CARTO_API_KEY in .env")
    ap.add_argument("--rate", type=float, default=1.0,
                    help="seconds between requests (OSM asks for ~1/s)")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--write", action="store_true",
                    help="actually write; without it this is a dry run")
    args = ap.parse_args()

    src = Path(args.from_pack)
    if not src.exists():
        print(f"error: {src} not found", file=sys.stderr)
        return 2

    spec = PROVIDERS[args.provider]
    key = args.key.strip()
    if spec["key"] and not key:
        key = load_env_key("CARTO_API_KEY")
        if not key:
            print(f"error: --provider {args.provider} needs a key: pass --key "
                  f"or set CARTO_API_KEY in .env", file=sys.stderr)
            return 2

    wanted = read_pack_tiles(src)
    if not wanted:
        print(f"error: no z/x/y.png entries in {src}", file=sys.stderr)
        return 2

    zooms = sorted({z for z, _, _ in wanted})
    was = src.stat().st_size
    print(f"pack            : {src} ({was / 1e6:.2f} MB)")
    print(f"tiles to fetch  : {len(wanted):,}  zooms {zooms[0]}-{zooms[-1]}")
    print(f"provider        : {args.provider} ({spec['hosts'][0]}"
          f"{' , keyed' if spec['key'] and key else ''})")
    print(f"pace            : {args.rate:.1f}s/tile -> "
          f"~{len(wanted) * args.rate / 60:.1f} min")
    if not args.write:
        print("\n(dry run - pass --write)")
        return 0

    tiles: dict[tuple[int, int, int], bytes] = {}
    failed: list[str] = []
    for i, (z, x, y) in enumerate(wanted, 1):
        for attempt in range(args.retries):
            try:
                tiles[(z, x, y)] = fetch_tile(
                    z, x, y, attempt, args.provider, key
                )
                break
            except (urllib.error.URLError, ValueError, OSError) as e:
                if attempt == args.retries - 1:
                    failed.append(f"{z}/{x}/{y}: {e}")
                else:
                    time.sleep(2.0 * (attempt + 1))
        if i % 20 == 0 or i == len(wanted):
            got = len(tiles)
            print(f"  {i}/{len(wanted)} fetched ({got} ok, "
                  f"{len(failed)} failed)", flush=True)
        time.sleep(args.rate)

    if failed:
        # NEVER ship a partial pack: the missing tiles would be blanks on the
        # map, which is worse than the watermarked tiles we are replacing.
        print(f"\nABORT: {len(failed)} tile(s) failed:", file=sys.stderr)
        for f in failed[:20]:
            print(f"  {f}", file=sys.stderr)
        return 1

    # Second net after the block-page fingerprints: a provider answering every
    # request with ONE image (blank, error, or a caching proxy) passes the size
    # and magic checks above. Real map tiles are almost all distinct — measured
    # over the CONTENT tiles only, since empty sea tiles are legitimately
    # identical to each other.
    blanks = [b for b in tiles.values() if len(b) < BLANK_TILE_BYTES]
    content = [b for b in tiles.values() if len(b) >= BLANK_TILE_BYTES]
    print(f"blank tiles     : {len(blanks):,}/{len(tiles):,} "
          f"(open sea / empty terrain — legitimate)")
    if not content:
        print("\nABORT: every tile is blank — the provider is not serving real "
              "map data. Nothing was written.\n", file=sys.stderr)
        return 1
    digests = {hashlib.md5(b).hexdigest() for b in content}
    ratio = len(digests) / len(content)
    print(f"distinct images : {len(digests):,}/{len(content):,} content tiles "
          f"({ratio:.0%})")
    if ratio < MIN_DISTINCT_RATIO:
        print(f"\nABORT: only {ratio:.0%} of the content tiles are distinct "
              f"(min {MIN_DISTINCT_RATIO:.0%}) — the provider is not serving "
              f"real map data (a block page, one blank tile, or a broken "
              f"proxy). Nothing was written.\n", file=sys.stderr)
        return 1

    total = sum(len(b) for b in tiles.values())
    print(f"tiles OK        : {len(tiles):,}  raw {total / 1e6:.2f} MB  "
          f"avg {total / len(tiles) / 1024:.1f} KB")
    out = Path(args.out)
    written = write_pack(out, tiles)
    try:
        shown = out.relative_to(REPO)
    except ValueError:
        shown = out  # --out outside the repo (a test run)
    print(f"wrote           : {shown} "
          f"({written / 1e6:.2f} MB, was {was / 1e6:.2f} MB)")
    print("verify: extract a tile and LOOK at it — there must be no "
          "'API KEY REQUIRED' watermark and no 'Access blocked' page.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
