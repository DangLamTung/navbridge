/// Widget tests for the new nav UI pieces (bottom status bar + elevation
/// chart).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/ui/elevation_chart.dart';
import 'package:navbridge/ui/nav_status_bar.dart';

void main() {
  group('NavStatusBar', () {
    testWidgets('shows the live clock, distance, ETA and progress line', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NavStatusBar(
              remainingMeters: 2400,
              etaMinutes: 6,
              progress: 0.3,
            ),
          ),
        ),
      );
      // Distance formatted as 2.4 km and ETA.
      expect(find.textContaining('km'), findsOneWidget);
      expect(find.textContaining('phút'), findsOneWidget);
      // A clock HH:mm is present (regex-ish: contains ':').
      expect(find.textContaining(':'), findsWidgets);
      // Dispose to stop the 1 s clock timer.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('ElevationChart', () {
    testWidgets('renders a small elevation profile', (tester) async {
      final profile = <(double, double)>[
        (0, 10),
        (500, 60),
        (1000, 40),
        (1500, 120),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElevationChart(
              profile: profile,
              minElev: 10,
              maxElev: 120,
              up: 120,
              down: 30,
              progress: 0.5,
            ),
          ),
        ),
      );
      expect(find.textContaining('120m'), findsWidgets); // ascent
      expect(find.textContaining('30m'), findsWidgets); // descent
      expect(find.textContaining('10–120m'), findsOneWidget); // min–max
      expect(find.textContaining('%'), findsWidgets); // grade
    });
  });
}
