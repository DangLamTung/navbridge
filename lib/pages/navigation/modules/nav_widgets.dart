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
