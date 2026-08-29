/// Full-screen real Vietmap turn-by-turn navigation.
///
/// Uses `vietmap_flutter_navigation` (the official Vietmap Flutter wrapper
/// around the native navigation SDK), so the guidance here is Vietmap's own
/// engine — not our custom [TurnByTurnEngine]. The map/routing/voice all come
/// from Vietmap; the app just hands it [origin] → [destination].
///
/// Needs the Vietmap API key (--dart-define=VIETMAP_API_KEY); without it the
/// SDK cannot build a route, so the screen shows an error and lets the user
/// close back to the app.
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:vietmap_flutter_navigation/vietmap_flutter_navigation.dart';
import 'package:vietmap_flutter_navigation/models/voice_units.dart'
    show VoiceUnits;

import 'package:navbridge/services/vietmap_config.dart';

/// Full-screen Vietmap navigation from [origin] to [destination].
class VietmapNavScreen extends StatefulWidget {
  const VietmapNavScreen({
    super.key,
    required this.origin,
    required this.destination,
    this.destinationName,
  });

  /// Where to start (latlong2 coordinate — converted to the Vietmap SDK
  /// `LatLng` internally).
  final ll.LatLng origin;

  /// Where to go.
  final ll.LatLng destination;

  /// Human-readable destination name shown in the top bar.
  final String? destinationName;

  @override
  State<VietmapNavScreen> createState() => _VietmapNavScreenState();
}

class _VietmapNavScreenState extends State<VietmapNavScreen> {
  final VietMapNavigationPlugin _plugin = VietMapNavigationPlugin();
  MapOptions? _options;
  MapNavigationViewController? _controller;
  RouteProgressEvent? _progress;
  bool _started = false;
  bool _building = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final key = VietmapConfig.apiKey;
    _options = _plugin.getDefaultOptions()
      ..apiKey = key
      // The style endpoint 423s with the API key (locked / needs the paid nav
      // SDK key) but works with the TILE key — use it so the map actually
      // renders. The API key still drives routing/guidance in the SDK.
      ..mapStyle =
          'https://maps.vietmap.vn/api/maps/light/styles.json?apikey=${VietmapConfig.tileKey}'
      ..language = 'vi'
      ..units = VoiceUnits.metric
      ..simulateRoute = false
      ..mode = MapNavigationMode.drivingWithTraffic;
  }

  /// Build the route and start Vietmap turn-by-turn. Called once the map has
  /// rendered (the SDK recommends this so it doesn't crash mid-render).
  void _startNavigation() {
    final c = _controller;
    if (c == null || _started) return;
    _started = true;
    c.buildAndStartNavigation(
      waypoints: [
        LatLng(widget.origin.latitude, widget.origin.longitude),
        LatLng(widget.destination.latitude, widget.destination.longitude),
      ],
      profile: DrivingProfile.drivingTraffic,
    );
  }

  Future<void> _close() async {
    await _controller?.finishNavigation();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller?.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return Scaffold(
      body: Stack(
        children: [
          if (options != null)
            Positioned.fill(
              child: NavigationView(
                mapOptions: options,
                onMapCreated: (c) => _controller = c,
                onMapRendered: _startNavigation,
                onRouteProgressChange: (e) => setState(() {
                  _progress = e;
                  _building = false;
                }),
                onRouteBuildFailed: (m) => setState(() {
                  _error = m;
                  _building = false;
                }),
                onNavigationFinished: () {
                  if (mounted) Navigator.of(context).pop();
                },
                onNavigationCancelled: () {
                  if (mounted) Navigator.of(context).pop();
                },
              ),
            ),
          // Top bar: destination + close.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 4,
                    shadowColor: Colors.black26,
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Đóng Vietmap',
                      onPressed: _close,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 4,
                      shadowColor: Colors.black26,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(
                          'Vietmap • ${widget.destinationName ?? 'Điểm đến'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Route building overlay / error.
          if (_building || _error != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _error != null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.error_outline,
                                  color: Colors.red,
                                  size: 40,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Không mở được Vietmap: $_error',
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                FilledButton(
                                  onPressed: _close,
                                  child: const Text('Đóng'),
                                ),
                              ],
                            )
                          : const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text('Đang tìm đường…'),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          // Bottom: Vietmap banner instruction + action bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                BannerInstructionView(
                  routeProgressEvent: _progress,
                  instructionIcon: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.navigation,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                BottomActionView(
                  controller: _controller,
                  routeProgressEvent: _progress,
                  recenterButton: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16, bottom: 8),
                      child: Material(
                        color: Colors.white,
                        shape: const CircleBorder(),
                        elevation: 4,
                        shadowColor: Colors.black26,
                        child: IconButton(
                          icon: const Icon(Icons.my_location),
                          tooltip: 'Về vị trí',
                          onPressed: () => _controller?.recenter(),
                        ),
                      ),
                    ),
                  ),
                  onOverviewCallback: () => _controller?.overview(),
                  onStopNavigationCallback: _close,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
