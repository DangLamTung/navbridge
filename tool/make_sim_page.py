#!/usr/bin/env python3
"""Write `web/sim.html` — the SIMULATION route, next to the playback one.

The two routes are the same Flutter app; the URL decides the job (see
`_isSimRoute` in `nav_sim_panel.dart`):

  * `sim.html`      simulate a drive — the console opens with the route editor
                    showing, which is the whole point of the page
  * `logged.html`   play a recorded trip back — the console starts collapsed,
                    because there it is a debugging tool over someone else's map

Generating it from `logged.html` keeps the log sink, the service-worker guard
and the bootstrap identical: two hand-maintained copies of that shell would drift
and one of them would silently stop logging.
"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'web' / 'logged.html'
DST = ROOT / 'web' / 'sim.html'


def main() -> int:
    html = SRC.read_text()
    out = html.replace('<title>NavBridge — logged replay</title>',
                       '<title>NavBridge — simulation</title>')
    out = out.replace('content="NavBridge replay harness"',
                      'content="NavBridge simulation harness"')
    if out == html:
        raise SystemExit('neither the title nor the description matched — the '
                         'shell changed; fix this script instead of shipping a '
                         'sim.html that says "replay"')
    DST.write_text(out)
    print(f'wrote {DST.relative_to(ROOT)} ({len(out.splitlines())} lines) '
          f'from {SRC.name}')
    print('  simulation: http://127.0.0.1:PORT/sim.html?osrm=/osrm')
    print('  playback  : http://127.0.0.1:PORT/logged.html?trip=/trips/x.json')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
