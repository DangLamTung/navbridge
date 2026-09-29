// The "Tiếp tục" bar on the map: it must name the destination, act on a tap,
// be dismissable, and stay inert while a route is being built.
//
//   flutter test test/resume_trip_bar_test.dart     (also in tool/check.sh)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/ui/resume_trip_bar.dart';

Future<void> _pump(
  WidgetTester tester, {
  required String label,
  required VoidCallback onContinue,
  required VoidCallback onDismiss,
  bool busy = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ResumeTripBar(
        label: label,
        busy: busy,
        onContinue: onContinue,
        onDismiss: onDismiss,
      ),
    ),
  ),
);

void main() {
  testWidgets('names the destination and offers to continue', (tester) async {
    var continued = 0;
    await _pump(
      tester,
      label: 'Đầm Sen Water Park',
      onContinue: () => continued++,
      onDismiss: () {},
    );
    expect(find.text('Chuyến đi đang dở'), findsOneWidget);
    expect(find.text('Đầm Sen Water Park'), findsOneWidget);

    await tester.tap(find.text('Tiếp tục'));
    await tester.pump();
    expect(continued, 1);
  });

  testWidgets('the ✕ drops the offer instead of continuing it', (tester) async {
    var continued = 0;
    var dismissed = 0;
    await _pump(
      tester,
      label: 'Bến Thành',
      onContinue: () => continued++,
      onDismiss: () => dismissed++,
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(dismissed, 1);
    expect(continued, 0);
  });

  testWidgets('a build in flight disables the button', (tester) async {
    await _pump(
      tester,
      label: 'Bến Thành',
      busy: true,
      onContinue: () {},
      onDismiss: () {},
    );
    final b = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(b.onPressed, isNull);
  });

  testWidgets('a long destination name is clipped, not overflowing', (
    tester,
  ) async {
    await _pump(
      tester,
      label: 'Khu du lịch sinh thái Vàm Sát, Cần Giờ, Hồ Chí Minh',
      onContinue: () {},
      onDismiss: () {},
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ResumeTripBar), findsOneWidget);
  });
}
