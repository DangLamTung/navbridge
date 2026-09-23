/// The ONE camera marker for the whole app.
///
/// Every screen that shows a speed / red-light enforcement camera — the browse
/// (start) map, the navigation map, the floating overlay's camera chips and the
/// overlay-layout previews — draws this same picture: the Waze alerter icon
/// (`assets/waze/icon_alerter_cam_speed.png`) that the navigation map has always
/// used. User: "for the camera in start screen they must be same png camera as
/// the navigation (taken from waze)".
///
/// It used to differ per screen: the nav map drew the Waze PNG while the browse
/// map drew the Material CCTV glyph (`CctvIcon`) inside a focus-coloured circle.
/// Keeping the drawing in one widget is what stops them drifting apart again —
/// the camera list is the same data (see `services/offline_cameras.dart`), so the
/// picture has to be the same too.
library;

import 'package:flutter/material.dart';

import 'cctv_icon.dart';

class WazeCameraIcon extends StatelessWidget {
  /// Bundled Waze "speed camera" alerter artwork.
  static const String asset = 'assets/waze/icon_alerter_cam_speed.png';

  final double size;

  /// Drawn only if the asset is missing (a stripped build): the MDI CCTV glyph,
  /// so the marker never disappears.
  final bool fallback;

  const WazeCameraIcon({super.key, this.size = 24, this.fallback = true});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      errorBuilder: !fallback
          ? null
          : (_, _, _) => CctvIcon(size: size * 0.9, color: Colors.white),
    );
  }
}
