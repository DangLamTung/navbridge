/// The router's left/right LABEL is cross-checked against the route geometry
/// before it reaches the voice / banner / ESP32 packet — see
/// [refineManeuverIcon]. These tests pin that contract.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/nav_protocol.dart';

/// Polyline that runs [legsM] in each of [bearings] (degrees), 10 m steps.
List<LatLng> _legs(List<double> bearings, List<double> legsM) {
  const stepM = 10.0;
  var lat = 10.78;
  var lng = 106.64;
  final pts = <LatLng>[LatLng(lat, lng)];
  for (var i = 0; i < bearings.length; i++) {
    final brg = bearings[i] * math.pi / 180;
    for (var d = 0.0; d < legsM[i]; d += stepM) {
      lat += (stepM * math.cos(brg)) / 111320.0;
      lng +=
          (stepM * math.sin(brg)) / (111320.0 * math.cos(lat * math.pi / 180));
      pts.add(LatLng(lat, lng));
    }
  }
  return pts;
}

/// The vertex where the two legs of a [before, after] path meet (the "turn").
LatLng _corner(List<LatLng> pts) => pts[pts.length ~/ 2];

void main() {
  group('routeTurnDegrees', () {

    test('4 cases', () {
    // ---- case: is positive for a right turn, negative for a left turn ----
    (() {
        // heading north, then east  = right (+90)
        final right = _legs([0, 90], [80, 80]);
        expect(routeTurnDegrees(right, _corner(right))!, closeTo(90, 6));
        // heading north, then west = left (−90)
        final left = _legs([0, 270], [80, 80]);
        expect(routeTurnDegrees(left, _corner(left))!, closeTo(-90, 6));

    })();


    // ---- case: reads a slight bend as a small angle ----
    (() {
        final slight = _legs([0, 30], [80, 80]);
        expect(routeTurnDegrees(slight, _corner(slight))!, closeTo(30, 6));

    })();


    // ---- case: is ~0/+180 for straight and U-turn shapes ----
    (() {
        final straight = _legs([0, 2], [80, 80]);
        expect(
          routeTurnDegrees(straight, _corner(straight))!.abs(),
          lessThan(12),
        );
        final uturn = _legs([0, 170], [80, 80]);
        expect(routeTurnDegrees(uturn, _corner(uturn))!.abs(), greaterThan(130));

    })();


    // ---- case: returns null when the point has no polyline on both sides ----
    (() {
        final g = _legs([0, 90], [80, 80]);
        expect(routeTurnDegrees(g, g.first), isNull);
        expect(routeTurnDegrees(g, g.last), isNull);
        expect(routeTurnDegrees(const [], g.first), isNull);
        expect(routeTurnDegrees(g.take(2).toList(), g.first), isNull);

    })();
    });

  });

  group('refineManeuverIcon', () {

    test('6 cases', () {
    // ---- case: flips the side when the geometry contradicts the router label ----
    (() {
        // The bug: router said right, the route swings left (−90).
        final left = _legs([0, 270], [80, 80]);
        expect(
          refineManeuverIcon(left, _corner(left), iconTurnRight),
          iconTurnLeft,
        );
        final right = _legs([0, 90], [80, 80]);
        expect(
          refineManeuverIcon(right, _corner(right), iconTurnLeft),
          iconTurnRight,
        );

    })();


    // ---- case: keeps the label when the geometry agrees ----
    (() {
        final right = _legs([0, 90], [80, 80]);
        expect(
          refineManeuverIcon(right, _corner(right), iconTurnRight),
          iconTurnRight,
        );

    })();


    // ---- case: sharpens a mild bend into a slight turn and vice versa ----
    (() {
        final mild = _legs([0, 30], [80, 80]);
        expect(
          refineManeuverIcon(mild, _corner(mild), iconTurnLeft),
          iconSlightRight,
        );
        final sharp = _legs([0, 80], [80, 80]);
        expect(
          refineManeuverIcon(sharp, _corner(sharp), iconSlightRight),
          iconTurnRight,
        );

    })();


    // ---- case: leaves non-lateral maneuvers to the router ----
    (() {
        final left = _legs([0, 270], [80, 80]);
        final corner = _corner(left);
        for (final code in [
          iconStraight,
          iconRoundabout,
          iconUturnLeft,
          iconUturnRight,
          iconArrive,
        ]) {
          expect(refineManeuverIcon(left, corner, code), code);
        }
        // No maneuver coordinate → keep the label (route-based fallback).
        expect(refineManeuverIcon(left, null, iconTurnRight), iconTurnRight);

    })();


    // ---- case: does not invent a turn out of a near-straight or U-turn angle ----
    (() {
        final straight = _legs([0, 2], [80, 80]);
        expect(
          refineManeuverIcon(straight, _corner(straight), iconTurnLeft),
          iconTurnLeft,
        );
        final uturn = _legs([0, 170], [80, 80]);
        expect(
          refineManeuverIcon(uturn, _corner(uturn), iconTurnRight),
          iconTurnRight,
        );

    })();


    // ---- case: maneuverVerb follows the refined code through to speech ----
    (() {
        final left = _legs([0, 270], [80, 80]);
        final refined = refineManeuverIcon(left, _corner(left), iconTurnRight);
        expect(maneuverVerb(refined), 'rẽ trái');

    })();
    });

  });
}
