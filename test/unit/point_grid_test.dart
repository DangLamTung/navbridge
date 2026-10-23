import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/point_grid.dart';

void main() {
  group('PointGrid.near', () {
    final points = <LatLng>[
      const LatLng(10.7769, 106.7009), // HCMC centre
      const LatLng(10.7800, 106.7050), // ~500 m away
      const LatLng(10.9000, 106.7009), // ~13.7 km away
    ];
    final grid = PointGrid<LatLng>(points, posOf: (p) => p);

    test('returns candidates inside the radius', () {
      final near = grid.near(10.7769, 106.7009, 1000).toList();
      expect(near, contains(points[0]));
      expect(near, contains(points[1]));
      expect(near, isNot(contains(points[2])));
    });

    test('exact same position returns at least itself', () {
      expect(grid.near(10.7769, 106.7009, 1).toList(), contains(points[0]));
    });

    test('empty area returns no candidates', () {
      expect(grid.near(21.0278, 105.8342, 1000), isEmpty);
    });

    test('cell edges do not drop nearby points', () {
      const onEdge = LatLng(10.78, 106.70); // exactly 100 * 0.02
      final edgeGrid = PointGrid<LatLng>(
        const [LatLng(10.78001, 106.70001)],
        posOf: (p) => p,
      );
      expect(edgeGrid.near(onEdge.latitude, onEdge.longitude, 100), isNotEmpty);
    });

    test('0.02 degree cells keep points in one bucket when close', () {
      // Regression guard: a 6 km query used to scan the whole database.
      final many = <LatLng>[
        for (var i = 0; i < 5000; i++) LatLng(21.0 + i * 0.001, 105.8),
      ];
      final g = PointGrid<LatLng>(many, posOf: (p) => p);
      final near = g.near(21.0, 105.8, 500).toList();
      expect(near.length, lessThan(many.length));
      expect(near, contains(many.first));
    });
  });
}
