part of '../navigation_page.dart';

/// DEBUG REPLAY CONSOLE — the point of the web build.
///
/// The browser build has no GPS, no BLE receiver and no phone under it, so
/// what it is FOR is driving a recorded trip through the real navigation code
/// and watching what happens: start, stop, change speed, pick another drive,
/// all from the screen, with the announcements listed as they are made. That
/// is why it lives in the app instead of in a URL parameter and a page reload.
///
/// Everything it shows is read from `nav_sim.dart` (the same numbers that go
/// to the `ANNOUNCE:`/`REPLAY:` console lines), so the panel and the log can
/// never disagree.
class SimConsole extends StatefulWidget {
  const SimConsole({
    super.key,
    required this.onClose,
    required this.onLayerChanged,
  });

  final VoidCallback onClose;

  /// Called when a debug layer is toggled — the PAGE loads the data (it owns
  /// the map, the loaders and the redraw), the console only asks.
  final void Function(String layer, bool on) onLayerChanged;

  @override
  State<SimConsole> createState() => _SimConsoleState();
}

enum _ConsoleTab { replay, editor }

class _SimConsoleState extends State<SimConsole> {
  _ConsoleTab _tab = _ConsoleTab.replay;

  double _editorDistanceM() {
    if (simEditorWaypoints.length < 2) return 0;
    var total = 0.0;
    for (var i = 0; i < simEditorWaypoints.length - 1; i++) {
      total += const Distance().as(
        LengthUnit.Meter,
        simEditorWaypoints[i],
        simEditorWaypoints[i + 1],
      );
    }
    return total;
  }

  String _buildEditorTripJson() {
    if (simEditorWaypoints.length < 2) return '';
    final locations = <Map<String, dynamic>>[];
    var now = DateTime.now();
    const speedKmh = 40.0;
    const speedMps = speedKmh / 3.6;
    const stepDistM = 10.0;

    for (var i = 0; i < simEditorWaypoints.length - 1; i++) {
      final a = simEditorWaypoints[i];
      final b = simEditorWaypoints[i + 1];
      final dist = const Distance().as(LengthUnit.Meter, a, b);
      final bearing = const Distance().bearing(a, b);
      final steps = (dist / stepDistM).ceil().clamp(1, 2500);
      for (var s = 0; s < steps; s++) {
        final t = s / steps;
        final lat = a.latitude + (b.latitude - a.latitude) * t;
        final lng = a.longitude + (b.longitude - a.longitude) * t;
        locations.add({
          'latitude': lat,
          'longitude': lng,
          'timestampMs': now.millisecondsSinceEpoch,
          'accuracy': 5.0,
          'speed': speedMps,
          'heading': (bearing + 360.0) % 360.0,
        });
        now = now.add(const Duration(seconds: 1));
      }
    }
    final last = simEditorWaypoints.last;
    locations.add({
      'latitude': last.latitude,
      'longitude': last.longitude,
      'timestampMs': now.millisecondsSinceEpoch,
      'accuracy': 5.0,
      'speed': 0.0,
      'heading': 0.0,
    });
    return jsonEncode({'locations': locations});
  }

  void _startEditorTrip() {
    final json = _buildEditorTripJson();
    if (json.isEmpty) return;
    setState(() {
      _pickedLabel = 'Lộ trình tự tạo (${simEditorWaypoints.length} điểm)';
      _pickedJson = json;
      _pickedInfo = '${simEditorWaypoints.length} điểm';
      _tab = _ConsoleTab.replay;
      simToggleEditor(false);
    });
    _start(from: 0);
  }

  /// Trip catalogue served next to the app (`/trips/index.json`, written by
  /// `tool/sim_trips.py`). Empty → the panel still works with a typed path.
  List<({String name, String ref, double km})> _trips = const [];
  bool _loadingTrips = false;
  String _selected = '';
  final TextEditingController _refCtrl = TextEditingController();
  double _speed = 4;
  bool _collapsed = false;

  /// Last file chosen from disk, and what happened to it (parse errors are the
  /// common case: a Google Takeout Records.json is not a trip).
  ///
  /// [_pickedJson] is kept so the run can be started again — including after the
  /// user changed the speed, which restarts the trip — without asking for the
  /// file a second time.
  String _pickedLabel = '';
  String _pickedJson = '';
  String _pickedInfo = '';

  static const List<double> _speeds = [1, 2, 4, 10, 20, 0];

  @override
  void initState() {
    super.initState();
    _speed = TripReplay.speed;
    final boot = TripReplay.source;
    if (boot != null && boot != 'injected') _selected = boot;
    _refCtrl.text = _selected;
    simTick.addListener(_onTick);
    unawaited(_loadTrips());
  }

  @override
  void dispose() {
    simTick.removeListener(_onTick);
    _refCtrl.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTrips() async {
    setState(() => _loadingTrips = true);
    final t = await TripReplay.servedTrips();
    if (!mounted) return;
    setState(() {
      _trips = t;
      _loadingTrips = false;
      // Nothing armed at boot (no `?trip=` in the URL) and nothing chosen yet:
      // preselect the newest staged drive, so opening the page and pressing
      // Start just works instead of a disabled button with an unopened menu.
      if (_selected.isEmpty && t.isNotEmpty) {
        _selected = t.first.ref;
        _refCtrl.text = _selected;
      }
    });
  }

  String get _label =>
      simTripLabel.isEmpty ? '(chưa chạy)' : simTripLabel;

  /// `0` means "as fast as the pipeline takes them", not "stopped".
  String get _speedLabel =>
      simSpeed == 0 ? 'max' : '${simSpeed.toStringAsFixed(0)}×';

  String get _kmLabel =>
      simTripMeters > 0 ? ' · ${(simTripMeters / 1000).toStringAsFixed(2)} km' : '';

  String get _spanLabel =>
      simTripDuration > Duration.zero ? ' · ${_span(simTripDuration)}' : '';

  /// How many sentences the run has produced (the live log is capped, this is
  /// the true count).
  int get simLogCount => simLog.length;

  /// Start is available as soon as there is something to drive: a catalogue
  /// entry, a typed path/URL, the trip the page was opened with, or a file
  /// already picked.
  bool get _canStart =>
      _pickedJson.isNotEmpty ||
      _selected.trim().isNotEmpty ||
      _refCtrl.text.trim().isNotEmpty;

  /// `670` → `11m10s` — the honest "how long would this take at 1×".
  String _span(Duration d) =>
      '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';

  @override
  Widget build(BuildContext context) {
    final running = simState == SimRunState.running;
    final roadPct = simFixesFed == 0
        ? 0
        : (simFixesNoRoad * 100 / simFixesFed).round();
    // Warn only once the sample can mean something: the first fixes of ANY
    // drive (a real one too) have no road yet, so an early 100 % is noise, not
    // a verdict. 40 fixes ≈ the first 40 s of the drive.
    final behind = simFixesFed >= 40 && roadPct >= 20;

    if (_collapsed) {
      return _shell(
        child: Row(
          children: [
            IconButton(
              tooltip: 'Mở bảng mô phỏng',
              icon: const Icon(Icons.bug_report, size: 18),
              onPressed: () => setState(() => _collapsed = false),
            ),
            Text(
              running ? 'Sim $simSpeed× · $simFixesFed/$simFixesTotal'
                     : 'Sim (${_stateLabel(simState)})',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return _shell(
      // SCROLLABLE body, with the log at a FIXED height.
      //
      // The panel is a fixed-size box and its content keeps growing (trip
      // picker, path box, layer chips, speed chips, two control rows,
      // counters, warning, log). When the fixed part outgrew the box, a release
      // build CLIPPED the bottom silently — no exception, no console line, the
      // Stop button just was not there (found 2026-09-25). Scrolling the whole
      // body is the only shape that cannot fail that way, and it is why the log
      // is a fixed 170 px instead of an `Expanded` (an Expanded inside a scroll
      // view has no bounded height to divide up).
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          Row(
            children: [
              const Icon(Icons.bug_report, size: 16, color: Colors.white70),
              const SizedBox(width: 6),
              const Text(
                'MÔ PHỎNG LÁI (debug)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              Text(
                _stateLabel(simState),
                style: TextStyle(
                  color: _stateColor(simState),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                tooltip: 'Thu nhỏ',
                icon: const Icon(Icons.remove, size: 16),
                onPressed: () => setState(() => _collapsed = true),
              ),
              IconButton(
                tooltip: 'Ẩn bảng',
                icon: const Icon(Icons.close, size: 16),
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Mode switch tabs: Replay vs Editor
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _tab = _ConsoleTab.replay);
                    simToggleEditor(false);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: _tab == _ConsoleTab.replay
                          ? Colors.white24
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Phát lại (Replay)',
                      style: TextStyle(
                        color: _tab == _ConsoleTab.replay
                            ? Colors.white
                            : Colors.white60,
                        fontSize: 11,
                        fontWeight: _tab == _ConsoleTab.replay
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _tab = _ConsoleTab.editor);
                    simToggleEditor(true);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: _tab == _ConsoleTab.editor
                          ? const Color(0xFF673AB7)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Biên tập (Editor)',
                      style: TextStyle(
                        color: _tab == _ConsoleTab.editor
                            ? Colors.white
                            : Colors.white60,
                        fontSize: 11,
                        fontWeight: _tab == _ConsoleTab.editor
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_tab == _ConsoleTab.replay) ...[
            // Trip source: the staged catalogue when one exists, a typed
            // path/URL always, and a file straight off disk (the picker) — a trip
            // that was never staged into the served directory is still one tap
            // away, which is what a debugging console needs.
            if (_trips.isNotEmpty)
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _trips.any((t) => t.ref == _selected) ? _selected : null,
                  isExpanded: true,
                  hint: const Text(
                    'chọn chuyến đi…',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  dropdownColor: const Color(0xFF181A22),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: [
                    for (final t in _trips)
                      DropdownMenuItem(
                        value: t.ref,
                        child: Text(
                          '${t.name}${t.km > 0 ? ' · ${t.km.toStringAsFixed(1)}km' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _selected = v;
                      _refCtrl.text = v;
                    });
                  },
                ),
              ),
            // Any path / URL (a staged file, a fixture, a dev server) — kept
            // visible even when the catalogue is populated.
            SizedBox(
              height: 30,
              child: TextField(
                controller: _refCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _loadingTrips
                      ? 'đang tải danh sách…'
                      : '/trips/x.json hoặc https://…',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                onChanged: (v) => _selected = v.trim(),
              ),
            ),
            const SizedBox(height: 4),
            // JSON chooser: pick a recorded trip straight off the disk.
            SizedBox(
              height: 30,
              child: OutlinedButton.icon(
                onPressed: _pickJson,
                icon: const Icon(Icons.folder_open, size: 15),
                label: const Text(
                  'Chọn tệp JSON…',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chạm trên bản đồ để thêm các điểm (waypoint) tạo đường đi.',
                    style: TextStyle(color: Colors.white70, fontSize: 10.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${simEditorWaypoints.length} điểm đã chọn'
                    '${simEditorWaypoints.length >= 2 ? ' · ~${(_editorDistanceM() / 1000).toStringAsFixed(2)} km' : ''}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: simEditorWaypoints.length >= 2
                              ? _startEditorTrip
                              : null,
                          icon: const Icon(Icons.play_arrow, size: 14),
                          label: const Text(
                            'Chạy lộ trình này',
                            style: TextStyle(fontSize: 10.5),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF673AB7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Xóa điểm cuối',
                        icon: const Icon(Icons.undo, size: 16),
                        color: Colors.white70,
                        visualDensity: VisualDensity.compact,
                        onPressed: simEditorWaypoints.isNotEmpty
                            ? () => setState(() => simRemoveEditorWaypoint(
                                simEditorWaypoints.length - 1))
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Xóa hết',
                        icon: const Icon(Icons.delete_outline, size: 16),
                        color: Colors.white70,
                        visualDensity: VisualDensity.compact,
                        onPressed: simEditorWaypoints.isNotEmpty
                            ? () => setState(simClearEditorWaypoints)
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Sao chép JSON',
                        icon: const Icon(Icons.copy, size: 16),
                        color: Colors.white70,
                        visualDensity: VisualDensity.compact,
                        onPressed: simEditorWaypoints.length >= 2
                            ? () {
                                Clipboard.setData(
                                  ClipboardData(text: _buildEditorTripJson()),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Đã sao chép JSON lộ trình'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
          // Debug data layers: the records the app decides with, drawn on the
          // map. Each chip shows how many records it loaded, so a layer that is
          // on but empty is visible as such.
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _layerChip('cameras', 'Camera', simLayerCameras),
              _layerChip('signs', 'Biển báo', simLayerSigns),
              _layerChip('segments', 'Waze seg', simLayerSegments),
            ],
          ),
          const SizedBox(height: 6),
          // Speaker speed + volume, in the console that is driving the run.
          // The same widget is on the voice settings page, so a value tuned
          // here is the value the app ships with.
          const SpeechControls(dense: true),
          const SizedBox(height: 6),
          // Speed.
          Wrap(
            spacing: 4,
            children: [
              for (final s in _speeds)
                ChoiceChip(
                  label: Text(
                    s == 0 ? 'max' : '${s.toStringAsFixed(0)}×',
                    style: TextStyle(
                      fontSize: 11,
                      color: _speed == s ? Colors.black : Colors.white,
                    ),
                  ),
                  selected: _speed == s,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: const Color(0xFF2A2F3A),
                  selectedColor: const Color(0xFF7CC4FF),
                  onSelected: (_) {
                    setState(() => _speed = s);
                    // Changing speed mid-run restarts the trip: the pipeline's
                    // per-fix work cannot be re-timed after the fact, and a
                    // half-and-half run would be a number nobody can compare.
                    if (running) _start();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Two rows, not one: four controls (start / continue / stop /
          // refresh) do not fit the panel's width, and a Row that overflows is
          // clipped SILENTLY in a release build — the Continue button was
          // simply invisible (nothing in the console). Splitting them also
          // groups the two ways to START separately from stop/refresh.
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _canStart ? () => _start(from: 0) : null,
                  icon: Icon(
                    running ? Icons.replay : Icons.play_arrow,
                    size: 16,
                  ),
                  label: Text(
                    running ? 'Chạy lại' : 'Bắt đầu',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Continue: pick the drive up at the fix the last run stopped at.
              // Without it, studying a junction mid-trip meant replaying the
              // first kilometre every time (user, 2026-09-25: "do a continue
              // trip button which can resume the trip if we stop").
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: !running && _resumeAt > 0
                      ? () => _start(from: _resumeAt)
                      : null,
                  icon: const Icon(Icons.play_circle_outline, size: 16),
                  label: Text(
                    _resumeAt > 0
                        // ignore: unnecessary_brace_in_string_interps
                        ? 'Tiếp tục ${_resumeAt}/$simFixesTotal'
                        : 'Tiếp tục',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.white,
                    // Legible while disabled: on the dark panel the default
                    // disabled colour fades to nothing and the control looks
                    // missing rather than unavailable.
                    disabledForegroundColor: Colors.white38,
                    // A visible outline while disabled: the button has to READ
                    // as "nothing stopped to continue from" instead of
                    // vanishing into the panel.
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: running || simState == SimRunState.done
                    ? _stop
                    : null,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Dừng', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Tải lại danh sách chuyến',
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _loadTrips,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Live counters: what is loaded, how far the feed has got, and how far
          // behind the per-fix road lookup is (the metric that says whether the
          // result can be trusted).
          Text(
            '$_label · $_speedLabel$_kmLabel$_spanLabel',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          Text(
            'fix $simFixesFed/$simFixesTotal'
            ' · không có đường $roadPct%'
            ' · đã nói $simLogCount',
            style: TextStyle(
              color: behind ? const Color(0xFFFFB74D) : Colors.white70,
              fontSize: 11,
              fontWeight: behind ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          if (behind)
            const Text(
              '⚠ tra cứu đường không theo kịp → thiếu thông báo. '
              'Giảm tốc độ để đo cho đúng.',
              style: TextStyle(color: Color(0xFFFFB74D), fontSize: 10),
            ),
          if (_pickedInfo.isNotEmpty)
            Text(
              _pickedInfo,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          const SizedBox(height: 6),
          const Text(
            'NHẬT KÝ THÔNG BÁO',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
          // Newest first: while a run is on, the interesting line is the last.
          // Fixed height (see the note on the scroll view above).
          SizedBox(
            height: 170,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(6),
              child: simLog.isEmpty
                  ? const Text(
                      'chưa có thông báo nào',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    )
                  : ListView.builder(
                      reverse: true,
                      itemCount: simLog.length,
                      itemBuilder: (_, i) {
                        final a = simLog[simLog.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            a.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              height: 1.25,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        ),
      ),
    );
  }

  /// One debug-layer toggle. Tapping it loads the layer (whole data set) and
  /// asks the map to draw it; tapping again hides it without dropping the data,
  /// so re-enabling is instant.
  Widget _layerChip(String layer, String label, int count) {
    final on = simLayerOn(layer);
    return FilterChip(
      label: Text(
        count > 0 ? '$label $count' : label,
        style: TextStyle(
          fontSize: 10.5,
          color: on ? Colors.black : Colors.white70,
        ),
      ),
      selected: on,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: const Color(0xFF2A2F3A),
      selectedColor: const Color(0xFFFFD54F),
      onSelected: (v) {
        widget.onLayerChanged(layer, v);
        setState(() {});
      },
    );
  }

  void _start({int? from}) {
    // A trip picked from disk is replayed from the JSON we already hold — the
    // path box shows its NAME (so the panel says what will run), which is not a
    // loadable ref, and asking for the file again to change the speed would be
    // silly.
    final typed = _refCtrl.text.trim();
    // `from` = null keeps the stored resume point (Continue); 0 starts over, so
    // "Bắt đầu" always means the beginning of the drive.
    if (from == 0) TripReplay.clearResume(_tripKey);
    if (_pickedJson.isNotEmpty && (typed.isEmpty || typed == _pickedLabel)) {
      TripReplay.startInline(
        _pickedJson,
        label: _pickedLabel,
        speed: _speed,
        from: from,
      );
      return;
    }
    if (typed.isEmpty && _selected.isEmpty) return;
    _selected = typed.isNotEmpty ? typed : _selected;
    TripReplay.start(_selected, speed: _speed, from: from);
  }

  /// The ref the console is currently pointed at — the same key [TripReplay]
  /// stores the resume point under, so "Tiếp tục" never resumes another trip.
  String get _tripKey {
    final typed = _refCtrl.text.trim();
    if (_pickedJson.isNotEmpty && (typed.isEmpty || typed == _pickedLabel)) {
      return TripReplay.inlineRef;
    }
    return typed.isNotEmpty ? typed : _selected;
  }

  /// Fix "Tiếp tục" would start at (0 = nothing stopped to continue from).
  int get _resumeAt => simState == SimRunState.running
      ? 0
      : TripReplay.resumeFor(_tripKey);

  /// Read a trip JSON straight off the disk and drive it.
  ///
  /// A debugging session usually starts with "I have this one file" — a drive
  /// pulled off the phone, a fixture, a trimmed-down repro. Staging it into the
  /// served directory first is a step that exists only because a browser cannot
  /// open a file; the picker removes that step.
  Future<void> _pickJson() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final f = res?.files.single;
      final bytes = f?.bytes;
      if (f == null || bytes == null) return;
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trim().isEmpty) {
        _note('tệp rỗng');
        return;
      }
      // Parse BEFORE starting, so a wrong file says so here instead of
      // producing a run that silently does nothing.
      final fixes = parseReplayFixes(text);
      if (fixes.length < 3) {
        _note('${f.name}: không đọc được GPS (${fixes.length} điểm)');
        return;
      }
      setState(() {
        _pickedLabel = f.name;
        _pickedJson = text;
        // Show the chosen file in the PATH BOX: that box is what the panel uses
        // to say which scenario is loaded, and leaving a stale path in it made
        // it look as if the picker had not taken effect. The catalogue choice
        // no longer applies, so clear it.
        _selected = '';
        _refCtrl.text = f.name;
      });
      TripReplay.startInline(text, label: f.name, speed: _speed);
      _note('${f.name}: ${fixes.length} điểm GPS');
    } catch (e) {
      _note('lỗi đọc tệp: $e');
    }
  }

  void _note(String message) {
    debugPrint('SIM: $message');
    if (mounted) setState(() => _pickedInfo = message);
  }

  void _stop() => TripReplay.stop();
  Color _stateColor(SimRunState s) => switch (s) {
    SimRunState.running => const Color(0xFF7CE38B),
    SimRunState.done => const Color(0xFF7CC4FF),
    SimRunState.stopped => const Color(0xFFFFB74D),
    SimRunState.failed => const Color(0xFFFF6B6B),
    _ => Colors.white54,
  };

  /// The run state in the app's language — this is a Vietnamese UI, and the raw
  /// enum name ("idle", "running") is English.
  String _stateLabel(SimRunState s) => switch (s) {
    SimRunState.idle => 'chờ',
    SimRunState.loading => 'đang tải',
    SimRunState.running => 'đang chạy',
    SimRunState.done => 'xong',
    SimRunState.stopped => 'đã dừng',
    SimRunState.failed => 'lỗi',
  };

  Widget _shell({required Widget child}) => Material(
    elevation: 10,
    color: const Color(0xF2181A22),
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 12, color: Colors.white),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white70, size: 16),
          child: child,
        ),
      ),
    ),
  );
}
