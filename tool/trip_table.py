#!/usr/bin/env python3
"""Render a trip JSON as a scrollable/filterable HTML table.

The raw log is ~700 KB of nested JSON — this flattens the per-fix fields the
speed-limit work cares about (time, street, class, posted, effective, source,
segment value, speed, accuracy) plus every voice announcement, with a text
filter and click-to-sort, so a specific second can be found by eye.

Usage: python3 tool/trip_table.py <trip.json> [-o out.html]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEGS = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip')
    ap.add_argument('-o', '--out', default=os.path.join(
        REPO, 'docs/trip_log.html'))
    args = ap.parse_args()

    with open(args.trip, encoding='utf-8') as fh:
        doc = json.load(fh)
    segs = T.Segments(SEGS)

    rows = []
    for e in doc.get('locations') or []:
        lat, lng = (e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7) \
            if e.get('latitudeE7') else (None, None)
        h = e.get('heading')
        seg = segs.query(lat, lng, h if isinstance(h, (int, float)) else None,
                         25)[0] if lat is not None else 0
        road, eff = e.get('speedLimit'), e.get('limitEffective')
        flag = ''
        if eff and seg and eff != seg:
            flag = 'eff≠seg'
        elif eff and not seg:
            flag = 'no segment'
        rows.append([
            (e.get('timestamp') or '')[11:19], e.get('street') or '',
            e.get('highway') or '', road, eff, e.get('limitSource') or '',
            seg or '', f'{(e.get("velocity") or 0) * 3.6:.0f}',
            e.get('accuracy'), f'{lat:.5f},{lng:.5f}' if lat else '', flag,
        ])

    anns = []
    for a in doc.get('announcements') or []:
        anns.append([(a.get('time') or a.get('timestamp') or '')[11:19],
                     a.get('kind') or '', a.get('text') or ''])

    head = ['time', 'street', 'class', 'posted', 'eff', 'src', 'segment',
            'km/h', 'acc', 'lat,lng', '']
    th = ''.join(f'<th onclick="sortCol({i})">{html.escape(h)}</th>'
                 for i, h in enumerate(head))
    def tr_html(r):
        cls = ('bad' if r[-1] == 'eff≠seg'
               else 'warn' if r[-1] == 'no segment' else '')
        return '<tr>' + ''.join(
            f'<td class="{cls if i == len(r) - 1 else ""}">'
            f'{html.escape(str(v))}</td>' for i, v in enumerate(r)) + '</tr>'

    body = '\n'.join(tr_html(r) for r in rows)
    ann_body = '\n'.join(
        '<tr><td>' + '</td><td>'.join(html.escape(str(v)) for v in a)
        + '</td></tr>' for a in anns)

    page = f"""<!doctype html><html><head><meta charset="utf-8">
<title>{html.escape(os.path.basename(args.trip))}</title><style>
 body{{margin:0;font:12px/1.4 ui-monospace,Menlo,monospace;background:#141414;
      color:#e8e8e8}}
 header{{position:sticky;top:0;background:#1d1d1d;padding:8px 10px;
        border-bottom:1px solid #333;font-family:system-ui}}
 input{{background:#222;color:#eee;border:1px solid #444;padding:4px 6px;
       width:240px}}
 table{{border-collapse:collapse;width:100%}}
 th,td{{padding:2px 6px;border-bottom:1px solid #242424;text-align:left;
      white-space:nowrap}}
 th{{position:sticky;top:44px;background:#1a1a1a;cursor:pointer;user-select:none}}
 tr:hover td{{background:#232323}}
 td.bad{{background:#4a1414}} td.warn{{background:#3a2c10}}
 .anns td{{color:#bbb}}
 h3{{margin:10px;font-family:system-ui}}
</style></head><body>
<header>{html.escape(os.path.basename(args.trip))} — {len(rows)} fixes,
 {len(anns)} announcements &nbsp;
 <input id="q" placeholder="filter street / class / value…" oninput="filt()">
 <span id="n"></span></header>
<table id="t"><thead><tr>{th}</tr></thead><tbody>
{body}
</tbody></table>
<h3>announcements</h3>
<table class="anns"><tbody>{ann_body}</tbody></table>
<script>
const tb=document.getElementById('t').tBodies[0];
function filt(){{const q=document.getElementById('q').value.toLowerCase();
 let n=0;for(const r of tb.rows){{const show=r.innerText.toLowerCase().includes(q);
  r.style.display=show?'':'none'; if(show)n++;}}
 document.getElementById('n').textContent=n+' shown';}}
let dir={{}};
function sortCol(i){{dir[i]=!dir[i];const rows=[...tb.rows];
 rows.sort((a,b)=>{{const x=a.cells[i].innerText,y=b.cells[i].innerText;
  const nx=parseFloat(x),ny=parseFloat(y);
  const c=(isNaN(nx)||isNaN(ny))?x.localeCompare(y):nx-ny;
  return dir[i]?c:-c;}});
 rows.forEach(r=>tb.appendChild(r));}}
filt();
</script></body></html>
"""
    with open(args.out, 'w', encoding='utf-8') as fh:
        fh.write(page)
    print(f'{len(rows)} fixes, {len(anns)} announcements -> {args.out}')
    bad = sum(1 for r in rows if r[10] == 'eff≠seg')
    nseg = sum(1 for r in rows if r[10] == 'no segment')
    print(f'  eff≠seg: {bad}   no segment within 25 m: {nseg}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
