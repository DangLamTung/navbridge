#!/usr/bin/env python3
"""The app's road/limit decision rules, ported once, for offline simulation.

Every rule here mirrors a specific function in the Dart code — the simulators
(tool/replay_road_rules.py, tool/simulate_nav.py) import them so a threshold can
only be changed in one place. If you change one of these, change its Dart
counterpart in the same commit:

    sim_limit()       <- lib/services/overpass.dart  statutoryLimit + urbanLimit
                         (motorbike table; built-up rule 60 đường đôi / 50 hai chiều)
    road_key/same_road<- lib/core/road_match.dart    roadKey / sameRoad
    pick_road_name()  <- lib/core/road_match.dart    pickRoadName
    RoadNameHysteresis<- lib/core/road_match.dart    RoadNameHysteresis
"""

from __future__ import annotations

# lib/services/overpass.dart — the motorbike class table.
MB = {
    'motorway': 80, 'motorway_link': 60, 'trunk': 60, 'trunk_link': 50,
    'primary': 60, 'primary_link': 50, 'secondary': 60, 'secondary_link': 50,
    'tertiary': 60, 'tertiary_link': 50, 'unclassified': 50, 'residential': 50,
    'living_street': 20, 'service': 30, 'pedestrian': 10, 'footway': 10,
    'cycleway': 20,
}
NON_MOTOR = ('motorway', 'motorway_link', 'living_street', 'service',
             'pedestrian', 'footway', 'cycleway')
_ONE_WAY = ('yes', 'true', '1', '-1', 'reverse')


def _is_oneway(v) -> bool:
    return str(v).strip().lower() in _ONE_WAY


def statutory_motorbike(highway, oneway=None, lanes=None, divided=False,
                        urban=True) -> int:
    """statutoryLimit() + urbanLimit() for a mô tô."""
    base = MB.get(highway or '', 50)
    if highway in NON_MOTOR:
        return base
    if urban or highway in ('residential', 'unclassified'):
        lanes_n = int(lanes) if str(lanes).isdigit() else 2
        # đường đôi / một chiều ≥2 làn -> 60, hai chiều / 1 làn -> 50
        is_div = bool(divided) or (_is_oneway(oneway) and lanes_n >= 2)
        return 60 if is_div else 50
    return base


def sim_limit(highway, oneway=None, lanes=None, posted=None,
              divided=False, urban=True) -> int:
    """What the chip would show: the vehicle table, with a posted value as a cap.

    Mirrors effectiveLimit(): a posted (Waze segment) value only ever TIGHTENS
    the vehicle's statutory limit for a motorbike.
    """
    stat = statutory_motorbike(highway, oneway=oneway, lanes=lanes,
                               divided=divided, urban=urban)
    if posted:
        try:
            p = int(posted)
        except (TypeError, ValueError):
            return stat
        return min(stat, p)
    return stat


# lib/services/overpass.dart — way class handling ---------------------------------

# `_classPriority`: 0 = highest. Each step is ~8 m of "distance" when scoring.
WAY_PRIORITY = {
    'motorway': 0, 'motorway_link': 1, 'trunk': 2, 'trunk_link': 3,
    'primary': 4, 'primary_link': 5, 'secondary': 6, 'secondary_link': 7,
    'tertiary': 8, 'tertiary_link': 9, 'unclassified': 10, 'residential': 11,
    'living_street': 12, 'service': 13, 'track': 14, 'path': 15,
    'pedestrian': 16, 'footway': 17, 'cycleway': 18, 'steps': 19,
}
# `_isDrivable`: these are only used when nothing drivable is nearby.
NON_DRIVABLE = frozenset({'footway', 'path', 'steps', 'cycleway', 'bridleway',
                          'track', 'construction'})
QUERY_M = 30.0      # overpass.dart: way(around:30,<fix>)[highway]
CLASS_STEP_M = 8.0  # priority step -> metres
HEADING_M = 20.0    # heading penalty is scaled into 0..HEADING_M by 90 deg


def class_penalty(highway: str) -> float:
    return WAY_PRIORITY.get(highway or '', 20) * CLASS_STEP_M


# lib/core/road_match.dart -----------------------------------------------------

def road_key(name: str) -> str:
    import re
    import unicodedata
    s = unicodedata.normalize('NFD', (name or '').lower())
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    s = s.replace('đ', 'd')
    return re.sub(r'[^a-z0-9]', '', s)


def same_road(a: str, b: str) -> bool:
    ka, kb = road_key(a), road_key(b)
    if not ka or not kb:
        return False
    return ka == kb or ka in kb or kb in ka


def pick_road_name(current: str, candidate: str, candidate_on_route: bool,
                   current_on_route: bool) -> str:
    """pickRoadName(): the route is a veto on a match that is off-route."""
    if not candidate:
        return current
    if candidate_on_route:
        return candidate
    if current_on_route:
        return current
    return candidate


def posted_limit_matches_name(segment_name, settled_name) -> bool:
    """postedLimitMatchesName() (lib/core/road_match.dart): a NAMED segment may
    only supply the limit of the road it names. An unnamed segment carries no
    evidence either way."""
    if not segment_name or not settled_name:
        return True
    return same_road(segment_name, settled_name)


class RoadNameHysteresis:
    """RoadNameHysteresis: 2 proposals or 30 m before a name change shows."""

    def __init__(self, confirm_fixes: int = 2, confirm_meters: float = 30.0):
        self.confirm_fixes = confirm_fixes
        self.confirm_meters = confirm_meters
        self.pending = None
        self.count = 0
        self.moved = 0.0

    def accept(self, current: str, candidate: str, moved_m: float) -> bool:
        if candidate == current:
            self.reset()
            return False
        if self.pending != candidate:
            self.pending = candidate
            self.count = 1
            self.moved = moved_m
            return False
        self.count += 1
        self.moved += moved_m
        if self.count >= self.confirm_fixes or self.moved >= self.confirm_meters:
            self.reset()
            return True
        return False

    def reset(self) -> None:
        self.pending = None
        self.count = 0
        self.moved = 0.0


if __name__ == '__main__':
    # Tiny self-check of the ported rules, so a typo cannot pass silently.
    assert statutory_motorbike('residential', oneway=False) == 50
    assert statutory_motorbike('secondary', oneway='yes', lanes=2) == 60
    assert statutory_motorbike('secondary', oneway='yes', lanes=1) == 50
    assert statutory_motorbike('primary', oneway='yes', lanes=None) == 60
    assert statutory_motorbike('service') == 30
    assert sim_limit('primary', oneway='yes', posted=50) == 50  # posted caps
    assert sim_limit('tertiary', posted=60) == 50               # capped by the table
    assert same_road('Đường 30 Tháng 4', 'duong 30 thang 4')
    assert same_road('Vườn Lài', 'Hẻm 4 Vườn Lài')
    assert not same_road('Trường Chinh', 'Trương Công Định')
    assert pick_road_name('A', 'B', candidate_on_route=True,
                          current_on_route=True) == 'B'
    assert pick_road_name('Trương Công Định', 'Trường Chinh',
                          candidate_on_route=False,
                          current_on_route=True) == 'Trương Công Định'
    h = RoadNameHysteresis()
    assert h.accept('Ấp Bắc', 'Lũy Bán Bích', 4.0) is False
    assert h.accept('Ấp Bắc', 'Lũy Bán Bích', 4.0) is True
    print('app_rules self-check: OK')
