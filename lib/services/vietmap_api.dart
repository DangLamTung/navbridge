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
  var url =
      '${VietmapConfig.autocomplete}?apikey=${VietmapConfig.nextKey()}'
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
    out.add(
      VmSuggestion(
        refId: '${e['ref_id'] ?? ''}',
        display: display,
        name: '${e['name'] ?? ''}',
        address: '${e['address'] ?? ''}',
      ),
    );
  }
  return out;
}

/// Resolve coordinates + display name for a chosen suggestion.
/// Returns (lat, lng, display) or null on failure. One transaction per call.
Future<(double, double, String)?> vietmapPlace(String refId) async {
  final url =
      '${VietmapConfig.place}?apikey=${VietmapConfig.nextKey()}'
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

/// A POI found via the Vietmap place index.
class VmPoi {
  final String name;
  final double lat;
  final double lng;
  const VmPoi(this.name, this.lat, this.lng);
}

/// Small TTL cache so repeated "trạm xăng" / "trạm sạc" taps are instant.
final _vmPoiCache = <String, (List<VmPoi>, DateTime)>{};
const _vmPoiCacheTtl = Duration(minutes: 4);

/// Find [text] POIs (e.g. "trạm xăng", "trạm sạc") around [center] via the
/// Vietmap place index: autocomplete returns names + ref_ids, then each ref_id
/// is resolved to coordinates IN PARALLEL. Returns up to [limit] nearest-first.
/// Empty when there's no Vietmap key (or offline).
Future<List<VmPoi>> vietmapPoiSearch(
  String text,
  LatLng center, {
  int limit = 8,
}) async {
  if (VietmapConfig.apiKey.isEmpty) return const [];
  final key =
      '$text|${center.latitude.toStringAsFixed(3)},'
      '${center.longitude.toStringAsFixed(3)}';
  final hit = _vmPoiCache[key];
  if (hit != null && DateTime.now().difference(hit.$2) < _vmPoiCacheTtl) {
    return hit.$1;
  }
  final suggestions = await vietmapAutocomplete(text, focus: center);
  final resolved = await Future.wait([
    for (final s in suggestions.take(limit * 2)) _resolveVmPoi(s),
  ]);
  final out = [for (final p in resolved) ?p];
  const Distance d = Distance();
  out.sort(
    (a, b) => d
        .as(LengthUnit.Meter, center, LatLng(a.lat, a.lng))
        .compareTo(d.as(LengthUnit.Meter, center, LatLng(b.lat, b.lng))),
  );
  final result = out.take(limit).toList();
  _vmPoiCache[key] = (result, DateTime.now());
  return result;
}

Future<VmPoi?> _resolveVmPoi(VmSuggestion s) async {
  final p = await vietmapPlace(s.refId);
  if (p == null) return null;
  return VmPoi(s.display, p.$1, p.$2);
}
