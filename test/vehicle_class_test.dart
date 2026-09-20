/// The vehicle class decides WHICH statutory table a limit is read from, so a
/// wrong default silently shows the wrong law (car: primary 80 / tertiary 50;
/// mô tô: both 60 outside town).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/offline_tiles.dart';
import 'package:navbridge/services/overpass.dart';

void main() {
  test('the default vehicle class is motorbike, not car', () {
    // This is a motorbike nav: the setting must default to the class the rider
    // is on, on a fresh install and in the standalone overlay alike.
    expect(const AppSettings().vehicleType, 'motorbike');
    expect(vehicleType, 'motorbike');
  });

  test('the per-class tables differ, so the class is not cosmetic', () {
    expect(statutoryLimit('primary', vehicle: 'motorbike'), 60);
    expect(statutoryLimit('primary', vehicle: 'car'), 80);
    expect(statutoryLimit('tertiary', vehicle: 'motorbike'), 60);
    expect(statutoryLimit('tertiary', vehicle: 'car'), 50);
  });

  test('inside a built-up area the road FORM replaces the class row', () {
    // Thông tư 38/2024 keys the built-up limit on the road's form, not the OSM
    // class — the vehicle class only shows through the xe tải row.
    expect(statutoryLimit('primary', vehicle: 'motorbike', urban: true), 50);
    expect(
      statutoryLimit(
        'primary',
        vehicle: 'motorbike',
        urban: true,
        divided: true,
      ),
      60,
    );
    expect(statutoryLimit('tertiary', vehicle: 'motorbike', urban: true), 50);
    expect(statutoryLimit('primary', vehicle: 'truck', urban: true), 40);
    expect(
      statutoryLimit('primary', vehicle: 'truck', urban: true, divided: true),
      50,
    );
  });

  test('a posted OSM maxspeed only tightens a non-car class', () {
    // OSM `maxspeed` is car-oriented: a motorbike must not inherit the car's
    // 80 on a primary road, but a lower posted value still applies.
    expect(effectiveLimit('primary', vehicle: 'motorbike', taggedKmh: 80), 60);
    expect(effectiveLimit('primary', vehicle: 'motorbike', taggedKmh: 40), 40);
    expect(effectiveLimit('primary', vehicle: 'car', taggedKmh: 80), 80);
  });
}
