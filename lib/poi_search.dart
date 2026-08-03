/// Point-of-interest search (Overpass/OSM) for quick "nearest X" during
/// navigation: gas, food, hotel, ATM, medical, parking.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A POI category shown as a quick button during navigation.
enum PoiType {
  fuel('fuel', 'Xăng', Icons.local_gas_station, 'amenity=fuel'),
  food('food', 'Ăn uống', Icons.restaurant,
      'amenity in restaurant,cafe,fast_food,food_court'),
  hotel('hotel', 'Khách sạn', Icons.hotel,
      'tourism in hotel,motel,hostel,guest_house'),
  atm('atm', 'ATM', Icons.local_atm, 'amenity in atm,bank'),
  hospital('hospital', 'Y tế', Icons.local_hospital,
      'amenity in hospital,clinic,pharmacy'),
  parking('parking', 'Đỗ xe', Icons.local_parking, 'amenity=parking');

  const PoiType(this.key, this.label, this.icon, this.overpassFilter);

  final String key;
  final String label;
  final IconData icon;
  final String overpassFilter;
}

/// One search result.
class PoiResult {
  final String name;
  final double lat;
  final double lng;
  final PoiType type;

  const PoiResult({
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
  });

  LatLng get pos => LatLng(lat, lng);
}

/// Brand color used to highlight a POI type (markers + cards).
Color poiColor(PoiType t) => switch (t) {
      PoiType.fuel => const Color(0xFFF4B400),
      PoiType.food => const Color(0xFFEA4335),
      PoiType.hotel => const Color(0xFF1A73E8),
      PoiType.atm => const Color(0xFF9334E6),
      PoiType.hospital => const Color(0xFF34A853),
      PoiType.parking => const Color(0xFF5F6368),
    };

const _mirrors = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.osm.ch/api/interpreter',
];

/// Find the nearest [type] POIs around [center] (Overpass `around` query).
/// Tries each mirror in order; returns up to [limit] results.
Future<List<PoiResult>> searchPois(
  PoiType type,
  LatLng center, {
  double radius = 5000,
  int limit = 8,
}) async {
  final q = '[out:json][timeout:15];'
      '(node[${type.overpassFilter}]'
      '(around:${radius.round()},${center.latitude},${center.longitude}););'
      'out center $limit;';
  Object? last;
  for (final mirror in _mirrors) {
    try {
      final res = await http
          .post(
            Uri.parse(mirror),
            body: {'data': q},
            headers: const {'User-Agent': 'navbridge/1.0 (POI search)'},
          )
          .timeout(const Duration(seconds: 18));
      if (res.statusCode != 200) continue;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final elements = (data['elements'] as List?) ?? const [];
      final out = <PoiResult>[];
      for (final e in elements) {
        if (e is! Map) continue;
        final tags = (e['tags'] as Map?) ?? const {};
        final name = (tags['name'] as String?)?.trim() ?? '';
        final lat = (e['lat'] ?? e['center']?['lat']) as num?;
        final lon = (e['lon'] ?? e['center']?['lon']) as num?;
        if (lat == null || lon == null) continue;
        if (name.isEmpty) continue; // skip unnamed POIs
        out.add(PoiResult(name: name, lat: lat.toDouble(), lng: lon.toDouble(), type: type));
        if (out.length >= limit) break;
      }
      if (out.isNotEmpty) return out;
    } catch (e) {
      last = e;
    }
  }
  if (last is Exception) throw last;
  throw Exception('Không tìm thấy ${type.label} gần đây');
}
