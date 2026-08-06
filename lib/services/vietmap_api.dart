/// Vietmap search/geocode client — fast Vietnamese place lookup.
///
/// Flow (per Vietmap best practices): autocomplete as the user types (no
/// coordinates), then ONE place call on selection to get lat/lng.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/vietmap_config.dart';

const _ua = 'navbridge/1.0 (Vietmap search)';

class VmSuggestion {
  final String refId;
  final String display;
  final String name;
  final String address;
  const VmSuggestion({
    required this.refId,
    required this.display,
    required this.name,
    required this.address,
  });
}

/// Type-ahead suggestions (NO coordinates — resolve via [vietmapPlace]).
Future<List<VmSuggestion>> vietmapAutocomplete(
  String text, {
  LatLng? focus,
}) async {
  var url = '${VietmapConfig.autocomplete}?apikey=${VietmapConfig.apiKey}'
      '&text=${Uri.encodeQueryComponent(text)}&display_type=6';
  if (focus != null) {
    url += '&focus=${focus.latitude},${focus.longitude}';
  }
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': _ua})
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) return const [];
  final data = jsonDecode(utf8.decode(res.bodyBytes));
  if (data is! List) return const [];
  final out = <VmSuggestion>[];
  for (final e in data.cast<Map<String, dynamic>>()) {
    final display = '${e['display'] ?? ''}';
    if (display.isEmpty) continue;
    out.add(VmSuggestion(
      refId: '${e['ref_id'] ?? ''}',
      display: display,
      name: '${e['name'] ?? ''}',
      address: '${e['address'] ?? ''}',
    ));
  }
  return out;
}

/// Resolve coordinates + display name for a chosen suggestion.
/// Returns (lat, lng, display) or null on failure. One transaction per call.
Future<(double, double, String)?> vietmapPlace(String refId) async {
  final url = '${VietmapConfig.place}?apikey=${VietmapConfig.apiKey}'
      '&refid=${Uri.encodeQueryComponent(refId)}';
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': _ua})
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) return null;
  final d = jsonDecode(utf8.decode(res.bodyBytes));
  if (d is! Map) return null;
  final lat = (d['lat'] as num?)?.toDouble();
  final lng = (d['lng'] as num?)?.toDouble();
  if (lat == null || lng == null) return null;
  final display = (d['display'] ?? d['name'] ?? '') as String;
  return (lat, lng, display);
}
