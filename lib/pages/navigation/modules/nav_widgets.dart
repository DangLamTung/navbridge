part of '../navigation_page.dart';

/// Voice mic button shared by the nav controls and the floated cluster.
/// TAP = one-shot listen. LONG-PRESS = toggle always-on wake-word listening
/// (mic turns red while always-on).
extension _NavMicButton on _NavigationPageState {
  Widget _micButton({double size = 46}) {
    final active = _listening || _alwaysOnVoice;
    return RoundActionButton(
      icon: active ? Icons.mic : Icons.mic_none,
      color: active ? const Color(0xFFEA4335) : kAppBlue,
      onTap: _toggleListening,
      onLongPress: _toggleAlwaysOnVoice,
      size: size,
    );
  }
}

/// Google-style draggable route handle: a grab dot on the route that the
/// user drags to insert a via point and re-plan. Drawn as a Flutter widget
/// on top of the map so its pan gesture doesn't fight the map's own pan.
class _RouteDragHandle extends StatelessWidget {
  const _RouteDragHandle({
    super.key,
    required this.via,
    required this.cameraListenable,
    required this.onDrag,
    required this.onDragEnd,
  });

  final LatLng via;
  final ValueListenable<MapCamera?> cameraListenable;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MapCamera?>(
      valueListenable: cameraListenable,
      builder: (context, cam, _) {
        if (cam == null) return const SizedBox.shrink();
        final p = cam.latLngToScreenPoint(via);
        return Positioned(
          left: p.x - 18,
          top: p.y - 18,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => onDrag(d.delta),
            onPanEnd: (_) => onDragEnd(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: kAppBlue, width: 3),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 4),
                ],
              ),
              child: const Icon(Icons.drag_handle, size: 16, color: kAppBlue),
            ),
          ),
        );
      },
    );
  }
}
