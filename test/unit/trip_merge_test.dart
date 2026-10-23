import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/services/trip_merge.dart';

Map<String, dynamic> _loc(int ms, double lat) => {
  'timestampMs': '$ms',
  'latitudeE7': (lat * 1e7).round(),
  'longitudeE7': 1067000000,
};

void main() {
  group('mergeTripDocuments', () {
    final t0 = DateTime(2026, 10, 23, 8).millisecondsSinceEpoch;
    final t1 = t0 + 10 * 60 * 1000;
    final t2 = t0 + 45 * 60 * 1000;

    test('sorts fixes, drops duplicate timestamps, and marks a 30 min gap', () {
      final merged = mergeTripDocuments([
        {
          'locations': [_loc(t0, 10.00), _loc(t2, 10.02)],
          'places': [
            {'lat': 10.00, 'lng': 106.70, 'enteredAt': 'a'},
          ],
        },
        {
          'locations': [
            _loc(t1, 10.01),
            _loc(t1, 10.01), // duplicate timestamp
          ],
          'places': [
            {'lat': 10.00, 'lng': 106.70, 'enteredAt': 'a'},
          ],
        },
      ], sourceNames: const ['a.json', 'b.json']);

      final locations = merged['locations'] as List;
      expect(locations, hasLength(3));
      expect((locations[0] as Map)['timestampMs'], '$t0');
      expect((locations[1] as Map)['timestampMs'], '$t1');
      expect((locations[2] as Map)['timestampMs'], '$t2');
      expect(merged['breaks'], [2]);
      expect(merged['breakGapMinutes'], 30);
      expect(merged['places'], hasLength(1));
      expect(merged['mergedFrom'], ['a.json', 'b.json']);
    });

    test('does not mark a gap under the threshold', () {
      final merged = mergeTripDocuments([
        {
          'locations': [_loc(t0, 10.00), _loc(t1, 10.01)],
        },
        {
          'locations': [_loc(t1 + 5 * 60 * 1000, 10.02)],
        },
      ]);
      expect(merged.containsKey('breaks'), isFalse);
    });

    test('merged distance skips the jump across a break', () {
      final locations = [
        _loc(t0, 10.00),
        _loc(t1, 10.01),
        _loc(t2, 10.50), // 45 min later, far away
      ];
      final withBreak = tripPathKm(locations, breaks: [2]);
      final without = tripPathKm(locations);
      expect(withBreak, lessThan(without));
      expect(withBreak, greaterThan(0));
    });
  });

  group('splitTripPath', () {
    final path = [
      const LatLng(10.00, 106.70),
      const LatLng(10.01, 106.70),
      const LatLng(10.50, 106.70),
      const LatLng(10.51, 106.70),
    ];

    test('splits at break indices', () {
      final parts = splitTripPath(path, [2]);
      expect(parts, hasLength(2));
      expect(parts[0], hasLength(2));
      expect(parts[1], hasLength(2));
      expect(parts[1].first, path[2]);
    });

    test('ignores out-of-range and zero breaks', () {
      expect(splitTripPath(path, [0, 9]), [path]);
    });

    test('empty path stays empty', () {
      expect(splitTripPath(const [], [1]), isEmpty);
    });
  });

  test('loadTrip reads breaks and exposes one segment per drive', () async {
    final dir = await Directory.systemTemp.createTemp('navbridge_merge_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/2026-10-23_080000_test.json');
    await f.writeAsString(
      jsonEncode({
        'locations': [
          _loc(1000, 10.00),
          _loc(2000, 10.01),
          _loc(3000, 10.50),
        ],
        'breaks': [2],
        'places': const [],
      }),
    );

    final trip = await loadTrip(f);
    expect(trip.path, hasLength(3));
    expect(trip.breaks, [2]);
    expect(trip.segments, hasLength(2));
    expect(trip.segments.first, hasLength(2));
    expect(trip.segments.last, hasLength(1));
  });

  test('mergeTripsForDay writes one file and archives the originals', () async {
    final docs = await Directory.systemTemp.createTemp('navbridge_docs_');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    addTearDown(() {
      PathProviderPlatform.instance = previous;
      docs.deleteSync(recursive: true);
    });

    final trips = Directory('${docs.path}/trips')..createSync(recursive: true);
    final t0 = DateTime(2026, 10, 23, 8).millisecondsSinceEpoch;
    final a = File('${trips.path}/2026-10-23_080000_A.json');
    final b = File('${trips.path}/2026-10-23_090000_B.json');
    await a.writeAsString(
      jsonEncode({
        'locations': [_loc(t0, 10.00)],
      }),
    );
    await b.writeAsString(
      jsonEncode({
        'locations': [_loc(t0 + 60 * 60 * 1000, 10.10)],
      }),
    );

    final result = await mergeTripsForDay(DateTime(2026, 10, 23));
    expect(result, isNotNull);
    expect(result!.sourceCount, 2);
    expect(result.pointCount, 2);
    expect(result.breakCount, 1);
    expect(result.file.existsSync(), isTrue);

    final top = await listTrips();
    expect(top.map((f) => f.path), [result.file.path]);
    final archived = await listArchivedTrips();
    expect(archived, hasLength(2));
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
