part of '../navigation_page.dart';

/// DEBUG markers — the console's view of the data layers.
///
/// These are deliberately *literal*: a sign shows the posted number, a camera
/// shows what it enforces, and both are colour-coded by kind so a glance at the
/// map answers "is that record even the right one?" without opening a log. They
/// are drawn only when the console asks (see `nav_sim.dart`).

/// A road sign record, drawn as the REAL QCVN 41 sign it is.
///
/// It used to draw a letter per kind, which is fine for spotting a misplaced
/// marker but useless for the actual question — "is that record the right
/// sign?" — because the answer is a picture. The image comes from the same
/// bundled artwork the driver sees (`SignIcon`), so the debug map and the road
/// can never disagree. A ring carries the provenance (which source claims the
/// sign); the letter is now only a fallback for a kind with no artwork.
class _DebugSignMarker extends StatelessWidget {
  const _DebugSignMarker({required this.sign});

  final RoadSign sign;

  @override
  Widget build(BuildContext context) {
    final color = switch (sign.source) {
      'vietmap' => const Color(0xFF6A1B9A),
      'waze' => const Color(0xFF1565C0),
      _ => const Color(0xFF37474F), // osm / other
    };
    final hasArt = SignIcon.assetFor(sign.kind) != null;
    return Tooltip(
      message:
          '${sign.name}\n${sign.kind.name}'
          '${sign.value == null ? '' : ' · ${sign.value} km/h'}\n'
          // Zone records are announced without a distance (see zoneSignKinds),
          // so the console says which records those are — otherwise "this one
          // has no distance" looks like a bug while debugging the voice.
          '${zoneSignKinds.contains(sign.kind) ? '· vùng (không đọc khoảng cách)\n' : ''}'
          'source=${sign.source}',
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
          color: hasArt ? Colors.transparent : color,
        ),
        alignment: Alignment.center,
        child: hasArt
            ? SignIcon(kind: sign.kind, value: sign.value, size: 24)
            : Text(
                _kindLetter(sign.kind),
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }

  /// One letter per sign family, for the records that carry no number.
  String _kindLetter(RoadSignKind k) => switch (k) {
    RoadSignKind.stop => 'S',
    RoadSignKind.giveWay => 'G',
    RoadSignKind.speed => 'V',
    RoadSignKind.signal => 'D',
    RoadSignKind.noPassing || RoadSignKind.noPassingEnd => 'P',
    RoadSignKind.noLeftTurn || RoadSignKind.noLeftUTurn => 'L',
    RoadSignKind.noRightTurn || RoadSignKind.noRightUTurn => 'R',
    RoadSignKind.noUTurn => 'U',
    RoadSignKind.onlyStraight || RoadSignKind.onlyLeft ||
    RoadSignKind.onlyRight => 'O',
    RoadSignKind.noTurnBoth || RoadSignKind.noStraight => 'X',
    RoadSignKind.oneWay => 'I',
    RoadSignKind.railwayCrossing => 'W',
    RoadSignKind.tunnel => 'H', // hầm
    // 'B' for booth: 'T' was shared with tunnel, which made the debug map
    // ambiguous exactly where the two disagree most (both are E-DOG ZONE
    // records, ~70 m off the carriageway — see tool/sign_placement_audit.py).
    RoadSignKind.tollBooth => 'B',
    _ => k.key.isEmpty ? '?' : k.key.substring(0, 1).toUpperCase(),
  };
}

/// A camera record, coloured by what it enforces.
class _DebugCameraMarker extends StatelessWidget {
  const _DebugCameraMarker({required this.camera});

  final OfflineCamera camera;

  @override
  Widget build(BuildContext context) {
    // Enforcement first — an unenforced monitoring camera must never look like
    // a fine. Red = fines (speed/red light/penalty), cyan = CCTV.
    final enforcement =
        camera.type == 'speed_camera' ||
        camera.type == 'penalty_camera' ||
        camera.type == 'red_light' ||
        camera.focus == 'speed' ||
        camera.focus == 'red_light' ||
        camera.focus == 'violations';
    final color = enforcement
        ? const Color(0xFFD32F2F)
        : const Color(0xFF00838F);
    return Tooltip(
      message:
          '${camera.name}\n'
          'type=${camera.type ?? '-'} focus=${camera.focus}\n'
          '${camera.speedLimit == null ? '' : 'limit=${camera.speedLimit} km/h · '}'
          'source=${camera.source}'
          '${camera.segmentMeters == null ? '' : ' · ${camera.segmentMeters} m'}',
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: const Icon(Icons.videocam, size: 12, color: Colors.white),
      ),
    );
  }
}
