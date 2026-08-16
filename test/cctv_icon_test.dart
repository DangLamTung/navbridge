/// Verifies the CCTV icon widget is configured to render the bundled MDI
/// cctv SVG asset.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/ui/cctv_icon.dart';

void main() {
  testWidgets('CctvIcon points at the bundled cctv SVG', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: CctvIcon(size: 24, color: Color(0xFFD93025))),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(CctvIcon), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    final icon = tester.widget<CctvIcon>(find.byType(CctvIcon));
    expect(icon.size, 24);
  });
}
