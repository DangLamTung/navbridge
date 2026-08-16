/// CCTV / surveillance-camera icon — the official Material Design Icons
/// "cctv" glyph (dome lens head on a mounting pole), the classic
/// "phạt nguội" / traffic-enforcement camera look.
///
/// The SVG (`assets/offline_map/icons/cctv.svg`) is the Apache-2.0 MDI glyph
/// bundled as an app asset and rendered with `flutter_svg`, tinted to match
/// the on/off toggle state. (No custom SVG parser needed — that was
/// over-engineered; a bundled SVG + flutter_svg is the normal way to use an
/// icon.)
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class CctvIcon extends StatelessWidget {
  final double size;
  final Color color;

  const CctvIcon({super.key, this.size = 24, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    // Material icons draw their glyph with ~8% inset baked in (a 24px box
    // shows ~20px of ink), so a bare MDI SVG — which fills its whole box —
    // looks BIGGER than a Material icon of the same size. Inset the glyph to
    // match Material's metrics so the CCTV icon sits consistently with the
    // other round action buttons.
    const inset = 0.82;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(
          'assets/offline_map/icons/cctv.svg',
          width: size * inset,
          height: size * inset,
          // MDI icons use `currentColor` — tint it with the requested color.
          color: color,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
