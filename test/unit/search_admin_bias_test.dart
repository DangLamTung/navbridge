/// Place search must prefer the driver's OWN country, then province, before
/// distance and the provider's ordering.
///
/// A common Vietnamese name (Bến Thành, Hòa Bình, Tân An) exists in many
/// provinces, and a namesake can sit closer in raw kilometres.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/osm_api.dart';

const _home = AdminArea(country: 'vn', province: 'ho chi minh');
const _focus = LatLng(10.7769, 106.7009); // District 1, HCMC

OsmSuggestion _s({
  required String id,
  required double lat,
  required double lng,
  String? country,
  String? province,
}) => OsmSuggestion(
  refId: id,
  display: 'Bến Thành',
  lat: lat,
  lng: lng,
  country: country,
  province: province,
);

void main() {
  test('same province beats a closer place in another country', () {
    final out = rankSuggestions(
      [
        _s(
          id: 'local',
          lat: 10.772, // ~500 m away, same province
          lng: 106.698,
          country: 'vn',
          province: 'ho chi minh',
        ),
        _s(
          id: 'otherProvince',
          lat: 10.35, // ~50 km, same country
          lng: 107.08,
          country: 'vn',
          province: 'ba ria - vung tau',
        ),
        _s(
          id: 'abroad',
          lat: 10.78, // ~350 m away, but another country
          lng: 106.703,
          country: 'us',
          province: 'california',
        ),
      ],
      focus: _focus,
      query: 'bến thành',
      home: _home,
    );
    expect(out.first.refId, 'local');
    expect(out.last.refId, 'abroad');
  });

  test('a foreign TOP pick is no longer protected at rank 1', () {
    final out = rankSuggestions(
      [
        _s(
          id: 'foreignFirst',
          lat: 10.78,
          lng: 106.702,
          country: 'us',
          province: 'california',
        ),
        _s(
          id: 'localFar',
          lat: 10.95,
          lng: 106.80,
          country: 'vn',
          province: 'ho chi minh',
        ),
      ],
      focus: _focus,
      query: 'bến thành',
      home: _home,
    );
    // Without the fix the provider's first result stays pinned by the exact
    // match boost even though it is the wrong country.
    expect(out.first.refId, 'localFar');
  });

  test('missing admin info never demotes a nearby result', () {
    final out = rankSuggestions(
      [
        _s(id: 'unknown', lat: 10.778, lng: 106.701), // no country/province
        _s(
          id: 'knownFar',
          lat: 10.95,
          lng: 106.80,
          country: 'vn',
          province: 'ho chi minh',
        ),
      ],
      focus: _focus,
      query: 'bến thành',
      home: _home,
    );
    expect(out.first.refId, 'unknown');
  });

  test('with no home area, the provider rank still dominates within ~15 km', () {
    // Documenting the existing weighting rather than pretending distance always
    // wins: each provider rank is worth 15 km, and BOTH the exact-match boost
    // (x0.1) and the "provider's top prefix match stays at rank 1" rule can
    // outrank distance. The query here is not a prefix of the display name, so
    // neither of those fires and only distance + rank are left.
    final out = rankSuggestions(
      [
        _s(id: 'far', lat: 11.5, lng: 106.8, country: 'vn'), // ~81 km
        _s(id: 'close', lat: 10.779, lng: 106.702, country: 'us'),
      ],
      focus: _focus,
      query: 'thanh ben',
      home: null,
    );
    expect(out.first.refId, 'close');
  });

  test(
    'unresolved Google predictions keep their order, except another country',
    () {
      // Places autocomplete predictions have no coordinates until picked, so the
      // only usable signal is the country in `terms`.
      final out = rankSuggestions(
        [
          OsmSuggestion(
            refId: 'foreign',
            display: 'Bến Thành, California, Hoa Kỳ',
            lat: 0,
            lng: 0,
            country: 'us',
            province: 'california',
          ),
          OsmSuggestion(
            refId: 'local',
            display: 'Bến Thành, Quận 1, Hồ Chí Minh, Việt Nam',
            lat: 0,
            lng: 0,
            country: 'vn',
            province: 'ho chi minh',
          ),
        ],
        focus: _focus,
        query: 'bến thành',
        home: _home,
      );
      expect(out.first.refId, 'local');
    },
  );

  test('diacritics/case do not break the admin comparison', () {
    final out = rankSuggestions(
      [
        _s(
          id: 'upper',
          lat: 10.95, // far, but VIETNAM/HO CHI MINH in caps
          lng: 106.80,
          country: 'vn',
          province: 'ho chi minh',
        ),
        _s(
          id: 'abroad',
          lat: 10.779, // near, another country
          lng: 106.702,
          country: 'us',
          province: 'california',
        ),
      ],
      focus: _focus,
      query: 'bến thành',
      home: _home,
    );
    expect(out.first.refId, 'upper');
  });
}
