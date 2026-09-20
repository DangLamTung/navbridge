#!/usr/bin/env python3
"""Print the PMTiles metadata JSON (the archive's own manifest).

Used to settle what a nav-map archive really contains: the header's zoom fields
can be wrong and the tile directory is easy to mis-parse by hand, but the
metadata block is written by the tile builder itself and usually carries the
generator, the zoom range and per-layer feature counts.

    python3 tool/pmtiles_meta.py assets/offline_map/saigon_z16.pmtiles
"""

from __future__ import annotations

import gzip
import json
import struct
import sys

HDR = 127


def _u64(d: bytes, at: int) -> int:
    return struct.unpack('<Q', d[at:at + 8])[0]


def main(paths: list[str]) -> None:
    for path in paths:
        try:
            with open(path, 'rb') as fh:
                head = fh.read(HDR)
                if head[0:7] != b'PMTiles':
                    print(f'{path}: not a PMTiles archive')
                    continue
                meta_o, meta_l = _u64(head, 24), _u64(head, 32)
                fh.seek(meta_o)
                raw = fh.read(meta_l)
        except OSError as e:
            print(f'{path}: {e}')
            continue
        if head[97] == 2:
            try:
                raw = gzip.decompress(raw)
            except Exception:  # noqa: BLE001
                pass
        try:
            meta = json.loads(raw)
        except Exception as e:  # noqa: BLE001
            print(f'{path}: metadata not JSON ({e})')
            continue
        print(f'== {path}')
        print(f'   header: min_zoom={head[100]} max_zoom={head[101]} '
              f'addressed_tiles={_u64(head, 72)}')
        keep = {k: v for k, v in meta.items() if k != 'tilestats'}
        print('   metadata: ' + json.dumps(keep)[:400])
        layers = meta.get('tilestats', {}).get('layers', [])
        for layer in layers:
            print(f"   layer {layer.get('layer')}: "
                  f"{layer.get('count')} features, "
                  f"zoom {layer.get('minzoom')}-{layer.get('maxzoom')}, "
                  f"counts={layer.get('geometry')}")


if __name__ == '__main__':
    main(sys.argv[1:])
