/// Hand-off to the Vietmap Maps app (or web fallback) with a destination.
///
/// Vietmap Maps doesn't document a custom URI scheme, but it does intercept
/// `https://maps.vietmap.vn/?query=<lat>,<lng>` (the same URL its "share
/// location" feature produces): if the app is installed, Android hands the
/// URL to it; otherwise the browser opens the same map. Either way the driver
/// gets Vietmap navigation without bundling the heavy native navigation SDK.
library;

import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Build the Vietmap share/navigation URL for [dest].
String vietmapNavUrl(LatLng dest, {String? label}) {
  final q = Uri.encodeQueryComponent('${dest.latitude},${dest.longitude}');
  final name = (label == null || label.isEmpty)
      ? ''
      : '&q=${Uri.encodeQueryComponent(label)}';
  return 'https://maps.vietmap.vn/?query=$q$name';
}

/// Open the destination in the Vietmap Maps app (browser as fallback).
/// Returns false when the URL cannot be launched at all.
Future<bool> openVietmapNavigation(LatLng dest, {String? label}) {
  return launchUrl(
    Uri.parse(vietmapNavUrl(dest, label: label)),
    mode: LaunchMode.externalApplication,
  );
}
