part of '../navigation_page.dart';

/// Simple nav mode — NO map. A clean full-screen view with a BIG curved
/// maneuver arrow in the middle, the distance / road / ETA around it, the
/// "next of next" maneuver (what comes after the upcoming turn — important
/// with no map), and the voice controls (mic + live "Đang nghe…" text +
/// camera/weather info). Has a dark theme (🌙 toggle in the top bar). Enabled
/// from Settings → "Chế độ đơn giản". Lighter than the vector map and easier
/// to read at a glance while riding.
extension _NavSimple on _NavigationPageState {
  Widget _buildSimpleNavLayout() {
    final nav = _progress;
    final dark = _simpleDark;
    // Palette (dark ⇄ light).
    final bg = dark ? const Color(0xFF1B1F24) : Colors.white;
    final card = dark ? const Color(0xFF2A2E33) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF202124);
    final sub = dark ? Colors.white70 : Colors.grey[700];
    final accent = dark ? const Color(0xFF8AB4F8) : kAppBlue;

    final iconCode = nav?.iconCode ?? iconStraight;
    final road = (nav?.text.isNotEmpty ?? false) ? nav!.text : 'Đang chỉ đường';
    final dist = nav == null ? '' : formatDistance(nav.meter);
    final eta = nav == null
        ? '--:--'
        : '${nav.etaHour.toString().padLeft(2, '0')}:'
              '${nav.etaMinute.toString().padLeft(2, '0')}';
    final kmh = (nav?.speedMps.isFinite ?? false)
        ? (nav!.speedMps * 3.6).round()
        : null;
    final limit = _effectiveSpeedLimit;
    final speeding = kmh != null && limit > 0 && kmh > limit;
    final cam = _nextCamera;
    final ahead = _weatherAhead;
    final nextVerb = nav == null ? '' : maneuverVerb(nav.iconCode);
    final nextRoad = (nav?.nextText.isNotEmpty ?? false) ? nav!.nextText : '';
    // "Next of next" — the maneuver after the upcoming one (no map to see it).
    final hasNextNext = (nav?.nextIconCode ?? 0) != 0;
    final nextNextVerb = nav == null ? '' : maneuverVerb(nav.nextIconCode);
    final nextNextRoad = (nav?.nextNextText.isNotEmpty ?? false)
        ? nav!.nextNextText
        : '';
    // Remaining route distance (not just to the next maneuver).
    final remaining = (_route?.distance ?? 0) * (1 - (nav?.progress ?? 0));

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            // --- top bar: destination + ETA + AI / dark / mic / exit ---
            Material(
              color: card,
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(Icons.flag, color: accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _destinationName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: fg,
                            ),
                          ),
                          Text(
                            'ETA $eta · còn ${formatDistance(remaining)}',
                            style: TextStyle(fontSize: 12, color: sub),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: dark ? 'Chế độ sáng' : 'Chế độ tối',
                      icon: Icon(
                        dark ? Icons.light_mode : Icons.dark_mode,
                        color: dark ? Colors.amber : const Color(0xFF5F6368),
                      ),
                      onPressed: () =>
                          setNavState(() => _simpleDark = !_simpleDark),
                    ),
                    IconButton(
                      tooltip: 'Trợ lý AI',
                      icon: const Icon(
                        Icons.auto_awesome,
                        color: Color(0xFF7B1FA2),
                      ),
                      onPressed: () => _openAiAssistant(),
                    ),
                    IconButton(
                      tooltip: 'Cửa sổ nổi (PiP)',
                      icon: const Icon(
                        Icons.picture_in_picture_alt,
                        color: Color(0xFF1A73E8),
                      ),
                      onPressed: _enterPip,
                    ),
                    _micButton(size: 44),
                    IconButton(
                      tooltip: 'Thoát chỉ đường',
                      icon: const Icon(Icons.close, color: Color(0xFFD93025)),
                      onPressed: _exitNavigation,
                    ),
                  ],
                ),
              ),
            ),
            // --- the BIG curved arrow, dead center ---
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _simpleArrowIcon(iconCode),
                        size: 180,
                        color: accent,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        dist,
                        style: TextStyle(
                          fontSize: 52,
                          height: 1.0,
                          fontWeight: FontWeight.w900,
                          color: fg,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        road,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                      if (nextVerb.isNotEmpty && nextRoad.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          '$nextVerb vào $nextRoad',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: accent,
                          ),
                        ),
                      ],
                      // Next of next: what comes AFTER the upcoming turn.
                      if (hasNextNext) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: dark
                                ? Colors.white.withValues(alpha: 0.06)
                                : const Color(0xFFF1F3F4),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _simpleArrowIcon(nav!.nextIconCode),
                                size: 26,
                                color: sub,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Sau đó: $nextNextVerb'
                                  '${nextNextRoad.isNotEmpty ? ' vào $nextNextRoad' : ''}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: sub,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // --- bottom info: speed / limit / camera / weather + voice hint ---
            Material(
              color: card,
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _simpleSpeedPill(kmh, limit, speeding, dark),
                        const Spacer(),
                        if (cam != null && cam.routeMeters <= 1500)
                          _simpleChip(
                            '📷 ${cam.routeMeters.round()}m',
                            const Color(0xFFD93025),
                            dark,
                          ),
                        if (ahead != null)
                          _simpleChip(
                            '${weatherEmoji(ahead.weatherCode)} '
                            '${ahead.tempC?.round() ?? '--'}°',
                            const Color(0xFF1A73E8),
                            dark,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Voice status: "Đang nghe… <text>" while listening,
                    // otherwise a hint of the commands.
                    Text(
                      _listening
                          ? (_voiceText.isEmpty
                                ? 'Đang nghe…'
                                : 'Đang nghe: “$_voiceText”')
                          : (_voiceText.isEmpty
                                ? 'Nói: “chỉ đường đến…” · “dừng lại” · “hỏi AI…”'
                                : 'Đã nghe: “$_voiceText”'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _listening ? const Color(0xFFD93025) : sub,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Curved Google-Maps-style turn arrows for the big central indicator.
  IconData _simpleArrowIcon(int code) => switch (code) {
    iconTurnLeft => Icons.turn_left,
    iconTurnRight => Icons.turn_right,
    iconSlightLeft => Icons.turn_slight_left,
    iconSlightRight => Icons.turn_slight_right,
    iconUturnLeft => Icons.u_turn_left,
    iconUturnRight => Icons.u_turn_right,
    iconRoundabout => Icons.roundabout_left,
    iconArrive => Icons.flag,
    _ => Icons.straight,
  };

  /// Circular speed pill (red when over the limit) + the EU speed-limit sign.
  Widget _simpleSpeedPill(int? kmh, int? limit, bool speeding, bool dark) {
    final accent = dark ? const Color(0xFF8AB4F8) : kAppBlue;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: speeding ? const Color(0xFFD93025) : Colors.white,
            border: Border.all(
              color: speeding ? const Color(0xFFD93025) : accent,
              width: 3,
            ),
          ),
          child: Text(
            kmh == null ? '--' : '$kmh',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              height: 1.0,
              color: speeding ? Colors.white : accent,
            ),
          ),
        ),
        if (limit != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFD93025), width: 1.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '$limit',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFFD93025),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Small info chip (camera ahead / weather ahead).
  Widget _simpleChip(String text, Color color, bool dark) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withValues(alpha: dark ? 0.8 : 1.0),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: dark ? Colors.white : color,
        ),
      ),
    );
  }

  /// Compact PiP window for SIMPLE (no-map) mode: a medium curved arrow +
  /// distance + ETA/road — no map, so it fits the tiny floating window
  /// cleanly. Used by [_buildPipLayout] when `simpleMode` is on.
  Widget _buildPipSimple() {
    final nav = _progress;
    final dark = _simpleDark;
    final bg = dark ? const Color(0xFF1B1F24) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF202124);
    final sub = dark ? Colors.white70 : Colors.grey[700];
    final accent = dark ? const Color(0xFF8AB4F8) : kAppBlue;
    final iconCode = nav?.iconCode ?? iconStraight;
    final road = (nav?.text.isNotEmpty ?? false) ? nav!.text : 'Đang chỉ đường';
    final dist = nav == null ? '' : formatDistance(nav.meter);
    final eta = nav == null
        ? ''
        : '${nav.etaHour.toString().padLeft(2, '0')}:'
              '${nav.etaMinute.toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            // Slim top row: destination + ETA.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _destinationName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: fg,
                      ),
                    ),
                  ),
                  Text('ETA $eta', style: TextStyle(fontSize: 11, color: sub)),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_simpleArrowIcon(iconCode), size: 84, color: accent),
                    const SizedBox(height: 8),
                    Text(
                      dist,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      road,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: sub),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
