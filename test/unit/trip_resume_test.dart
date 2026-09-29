// The "Tiếp tục" offer on the map: what a driver gets back after turning
// navigation off, and — just as important — what they must NOT get back.
//
// Pure unit test: builds the record directly, no packs, no widget.
//
//   flutter test test/trip_resume_test.dart      (also part of tool/check.sh)
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/services/trip_resume.dart';

TripStop _stop(String name, double lat, double lng) =>
    TripStop(name: name, lat: lat, lng: lng);

TripResume? _capture(
  List<TripStop> stops, {
  bool wasNavigating = true,
  bool arrived = false,
}) => TripResume.capture(
  stops: stops,
  profile: RouteProfile.motorbike,
  avoidHighway: true,
  avoidFerry: false,
  preference: RoutePreference.shortest,
  wasNavigating: wasNavigating,
  arrived: arrived,
);

void main() {
  group('what is worth offering', () {

    test('4 cases', () {
    // ---- case: a drive that was navigated and left early is offered ----
    (() {
        final r = _capture([_stop('Bến Thành', 10.7725, 106.6980)]);
        expect(r, isNotNull);
        expect(r!.label, 'Bến Thành');

    })();


    // ---- case: clearing a merely planned route offers nothing ----
    (() {
        // The same exit routine is behind "Xoá lộ trình" — re-offering a journey
        // the driver just deleted would be wrong.
        expect(
          _capture([_stop('Bến Thành', 10.7725, 106.6980)], wasNavigating: false),
          isNull,
        );

    })();


    // ---- case: arriving ends the journey — no offer ----
    (() {
        expect(
          _capture([_stop('Bến Thành', 10.7725, 106.6980)], arrived: true),
          isNull,
        );

    })();


    // ---- case: no destination, no offer ----
    (() {
        expect(_capture(const []), isNull);

    })();
    });

  });

  group('what the offer carries', () {

    test('4 cases', () {
    // ---- case: the destination is the LAST stop, and waypoints keep their order ----
    (() {
        final r = _capture([
          _stop('Chợ Lớn', 10.7550, 106.6500),
          _stop('Bến Thành', 10.7725, 106.6980),
        ])!;
        expect(r.stops.map((s) => s.name), ['Chợ Lớn', 'Bến Thành']);
        expect(r.destination.latitude, closeTo(10.7725, 1e-9));
        expect(r.destination.longitude, closeTo(106.6980, 1e-9));
        expect(r.label, 'Bến Thành');

    })();


    // ---- case: the routing choices come back unchanged ----
    (() {
        final r = _capture([_stop('Bến Thành', 10.7725, 106.6980)])!;
        expect(r.profile, RouteProfile.motorbike);
        expect(r.preference, RoutePreference.shortest);
        expect(r.avoidHighway, isTrue);
        expect(r.avoidFerry, isFalse);

    })();


    // ---- case: an unnamed stop still gives a label to show ----
    (() {
        final r = _capture([_stop('   ', 10.7725, 106.6980)])!;
        expect(r.label, 'Điểm đến');

    })();


    // ---- case: editing the live stop list afterwards cannot rewrite the offer ----
    (() {
        final live = [_stop('Bến Thành', 10.7725, 106.6980)];
        final r = _capture(live)!;
        live
          ..clear()
          ..add(_stop('Đà Lạt', 11.9404, 108.4583));
        expect(r.stops.length, 1);
        expect(r.label, 'Bến Thành');

    })();
    });

  });
}
