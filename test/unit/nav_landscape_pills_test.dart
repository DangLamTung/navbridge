import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/ui/nav_top_bar.dart';
import 'package:navbridge/ui/navigation_card.dart';

void main() {
  testWidgets('compact nav banner fits the landscape pill width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: NavTopBar(
                destination: 'Chợ Bến Thành, Quận 1, TP. Hồ Chí Minh',
                progress: NavProgress(
                  meter: 480,
                  iconCode: iconTurnLeft,
                  etaHour: 12,
                  etaMinute: 30,
                  text: 'Rẽ trái vào Đường Võ Văn Kiệt',
                  speedMps: 10,
                  nextIconCode: iconTurnRight,
                  nextText: 'Đường Nguyễn Văn Cừ rất dài',
                ),
                onExit: _noop,
                stopLabel: 'Điểm 2/3',
                compact: true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(NavTopBar));
    expect(size.width, lessThanOrEqualTo(360));
    expect(size.height, lessThan(120));
  });

  testWidgets('compact ETA card fits the landscape pill width', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: NavigationCard(
                progress: NavProgress(
                  meter: 900,
                  iconCode: iconStraight,
                  etaHour: 12,
                  etaMinute: 30,
                  text: 'Đi thẳng',
                  speedMps: 12,
                  remainingMeters: 15000,
                ),
                onStop: _noop,
                onOverview: _noop,
                stopLabel: 'Điểm 2/3',
                compact: true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(NavigationCard));
    expect(size.width, lessThanOrEqualTo(340));
    expect(size.height, lessThan(70));
  });
}

void _noop() {}
