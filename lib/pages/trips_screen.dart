/// Trip history — list saved Google-Takeout-format logs grouped by date
/// (Google-Timeline style), showing the places you visited in each trip;
/// share or delete.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:navbridge/services/trip_backup.dart';
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/pages/trip_map_screen.dart';
import 'package:navbridge/ui/widgets.dart';

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  List<File> _trips = [];
  List<TripPlan> _plans = [];
  Map<String, _TripSummary> _summaries = {};
  DateTime? _filterDay;
  bool _mergeByDay = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final t = await listTrips();
    final p = await loadPlans();
    final entries = await Future.wait(
      t.map((f) async => (f.path, await _summarize(f))),
    );
    if (!mounted) return;
    setState(() {
      _trips = t;
      _plans = p;
      _summaries = {for (final (k, v) in entries) k: v};
    });
  }

  /// Parse a saved trip's metadata ONCE (places + name + size + date), off
  /// the build path, so the card list never does synchronous disk I/O per
  /// rebuild. Trip files can be hundreds of KB — jsonDecode of the full file
  /// in build() was what froze the trips list on low-end phones.
  Future<_TripSummary> _summarize(File f) async {
    final name = readTripName(f);
    var places = <TripPlace>[];
    double distanceKm = 0;
    try {
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      places = [
        for (final p in (data['places'] as List? ?? const [])
            .cast<Map<String, dynamic>>())
          TripPlace.fromJson(p),
      ];
      distanceKm = tripPathKm(data['locations'] as List? ?? const []);
    } catch (_) {
      // Unreadable/legacy trip — show name only.
    }
    DateTime date;
    try {
      date = tripLocalDate(f) ?? f.statSync().modified.toLocal();
    } catch (_) {
      date = DateTime.now();
    }
    double sizeKb = 0;
    try {
      sizeKb = (await f.length()) / 1024.0;
    } catch (_) {}
    return _TripSummary(
      name: name,
      places: places,
      distanceKm: distanceKm,
      sizeKb: sizeKb,
      date: DateTime(date.year, date.month, date.day),
      dateLabel: tripDateLabel(f),
    );
  }

  String _displayName(File f) => f.uri.pathSegments.last;

  /// Share a backup of every saved trip + the fuel log (send to Drive/email).
  Future<void> _exportAll() async {
    try {
      await shareTripsBackup();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không xuất được: $e')),
        );
      }
    }
  }

  /// Pick a backup JSON and restore the trips + fuel log into the app.
  Future<void> _restoreAll() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = picked?.files.single.path;
      if (path == null) return;
      final n = await restoreTripsBackup(File(path));
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã khôi phục $n chuyến đi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Khôi phục thất bại: $e')),
        );
      }
    }
  }


  void _openTripMap(File f) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TripMapScreen(file: f)),
    );
  }

  /// Local (day-only) date a trip belongs to, from the summary (cached) then
  /// the filename then the file mtime.
  DateTime _dateOf(File f) {
    final s = _summaries[f.path];
    final d = s?.date ?? tripLocalDate(f);
    if (d != null) return DateTime(d.year, d.month, d.day);
    final t = f.statSync().modified.toLocal();
    return DateTime(t.year, t.month, t.day);
  }

  Future<void> _pickFilterDay() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _filterDay ?? now,
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (picked != null && mounted) {
      setState(
        () => _filterDay = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }


  Future<void> _share(File f) async {
    try {
      await Share.shareXFiles([
        XFile(f.path, mimeType: 'application/json'),
      ], text: 'Chuyến đi — ${_displayName(f)}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không chia sẻ được: $e')));
      }
    }
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá chuyến đi?'),
        content: Text(_displayName(f)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xoá', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        f.deleteSync();
      } catch (_) {}
      _reload();
    }
  }

  Future<void> _deletePlan(TripPlan p) async {
    final plans = _plans.where((x) => x != p).toList();
    await savePlans(plans);
    setState(() => _plans = plans);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: const Text(
            'Chuyến của tôi',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          actions: [
            IconButton(
              tooltip: 'Xuất tất cả chuyến đi',
              icon: const Icon(Icons.upload_file),
              onPressed: _exportAll,
            ),
            IconButton(
              tooltip: 'Khôi phục từ bản sao lưu',
              icon: const Icon(Icons.settings_backup_restore),
              onPressed: _restoreAll,
            ),
          ],
          bottom: const TabBar(
            labelColor: kAppBlue,
            unselectedLabelColor: Colors.blueGrey,
            indicatorColor: kAppBlue,
            tabs: [
              Tab(text: 'Đã ghi'),
              Tab(text: 'Kế hoạch'),
            ],
          ),
        ),
        body: TabBarView(children: [_buildLogs(), _buildPlans()]),
      ),
    );
  }

  Widget _buildLogs() {
    if (_trips.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.route, size: 56, color: Colors.blueGrey),
              SizedBox(height: 12),
              Text(
                'Chưa có chuyến đi nào.\n'
                'Bắt đầu chỉ đường để tự động ghi lại hành trình.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.blueGrey),
              ),
            ],
          ),
        ),
      );
    }

    // Group by date (Google Timeline buckets), preserving newest-first order;
    // when [_filterDay] is set, show only that day's trips (flat list).
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final buckets = <TripDateBucket, List<File>>{};
    final filtered = <File>[];
    for (final f in _trips) {
      final d = _dateOf(f);
      if (_filterDay != null && d != _filterDay) continue;
      filtered.add(f);
      if (_filterDay == null) {
        final b = tripDateBucket(d, today);
        (buckets[b] ??= []).add(f);
      }
    }
    final order = [
      TripDateBucket.today,
      TripDateBucket.yesterday,
      TripDateBucket.thisWeek,
      TripDateBucket.older,
    ];

    final children = <Widget>[_dayFilterBar()];
    if (_mergeByDay) {
      // Merge each day's trips into one expandable summary row.
      if (filtered.isEmpty) {
        children.add(_noFilteredTrips());
      } else {
        children.addAll(_mergeDayChildren(filtered, today));
      }
    } else if (_filterDay != null) {
      if (filtered.isEmpty) {
        children.add(_noFilteredTrips());
      } else {
        for (final f in filtered) {
          children.add(_tripCard(f));
        }
      }
    } else {
      for (final b in order) {
        if (buckets.containsKey(b)) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text(
                tripDateBucketLabel(b),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.blueGrey,
                ),
              ),
            ),
          );
          for (final f in buckets[b]!) {
            children.add(_tripCard(f));
          }
        }
      }
    }

    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  Widget _dayFilterBar() {
    final label = _filterDay == null
        ? 'Lọc theo ngày'
        : '${_filterDay!.day}/${_filterDay!.month}/${_filterDay!.year}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ActionChip(
            avatar: const Icon(Icons.filter_alt, size: 18),
            label: Text(label),
            onPressed: _pickFilterDay,
          ),
          if (_filterDay != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: IconButton(
                tooltip: 'Bỏ lọc',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _filterDay = null),
              ),
            ),
          const Spacer(),
          FilterChip(
            label: const Text('Gộp theo ngày'),
            selected: _mergeByDay,
            onSelected: (v) => setState(() => _mergeByDay = v),
          ),
        ],
      ),
    );
  }

  Widget _noFilteredTrips() {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text(
          'Không có chuyến đi nào trong ngày này.',
          style: TextStyle(color: Colors.blueGrey),
        ),
      ),
    );
  }

  /// One expandable summary row per day: date + trip count + total km, with
  /// that day's trip cards underneath (Google-Timeline "merge by day").
  List<Widget> _mergeDayChildren(List<File> trips, DateTime today) {
    final byDay = <DateTime, List<File>>{};
    for (final f in trips) {
      byDay.putIfAbsent(_dateOf(f), () => []).add(f);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final day in days) _dayGroupTile(day, byDay[day]!, today),
    ];
  }

  Widget _dayGroupTile(DateTime day, List<File> dayTrips, DateTime today) {
    final km = dayTrips.fold(
      0.0,
      (s, f) => s + (_summaries[f.path]?.distanceKm ?? 0),
    );
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const Icon(Icons.calendar_today, color: kAppBlue),
      title: Text(
        _dayLabel(day, today),
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
      subtitle: Text(
        '${dayTrips.length} chuyến • ${km.toStringAsFixed(1)} km',
        style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
      ),
      children: [for (final f in dayTrips) _tripCard(f)],
    );
  }

  String _dayLabel(DateTime d, DateTime today) {
    final dd = '${d.day}/${d.month}/${d.year}';
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Hôm nay · $dd';
    if (diff == 1) return 'Hôm qua · $dd';
    return dd;
  }

  Widget _tripCard(File f) {
    final s = _summaries[f.path];
    final places = s?.places ?? const <TripPlace>[];
    final name = s?.name ?? readTripName(f);
    final dateLabel = s?.dateLabel ?? tripDateLabel(f);
    final sizeKb = s?.sizeKb ?? (f.existsSync() ? f.lengthSync() / 1024.0 : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        elevation: 2,
        shadowColor: Colors.black12,
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              onTap: () => _openTripMap(f),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFE8F0FE),
                child: Icon(Icons.directions_car, color: kAppBlue, size: 22),
              ),
              title: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                [
                  dateLabel,
                  if ((s?.distanceKm ?? 0) >= 0.05)
                    '${(s?.distanceKm ?? 0).toStringAsFixed(1)} km',
                  '${sizeKb.toStringAsFixed(1)} KB',
                ].join(' • '),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Xem trên bản đồ',
                    icon: const Icon(Icons.map_outlined, size: 20),
                    color: kAppBlue,
                    onPressed: () => _openTripMap(f),
                  ),
                  IconButton(
                    icon: const Icon(Icons.ios_share, size: 20),
                    color: kAppBlue,
                    onPressed: () => _share(f),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: Colors.grey,
                    onPressed: () => _delete(f),
                  ),
                ],
              ),
            ),
            // Google-Timeline style: the places you stopped at during this
            // trip, each as a chip with the POI name if known.
            if (places.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in places)
                      Chip(
                        avatar: const Icon(
                          Icons.place,
                          size: 16,
                          color: kAppBlue,
                        ),
                        label: Text(
                          p.name ?? 'Điểm dừng',
                          style: const TextStyle(fontSize: 12),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: const Color(0xFFF0F6FF),
                        side: BorderSide(color: kAppBlue.withValues(alpha: 0.2)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlans() {
    if (_plans.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_outline, size: 56, color: Colors.blueGrey),
              SizedBox(height: 12),
              Text(
                'Chưa có kế hoạch nào.\n'
                'Thêm điểm dừng rồi nhấn "Lưu" để lưu chuyến đi.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.blueGrey),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _plans.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final p = _plans[i];
        return Material(
          elevation: 2,
          shadowColor: Colors.black12,
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE8F0FE),
              child: Icon(Icons.route, color: kAppBlue, size: 22),
            ),
            title: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${p.stops.length} điểm dừng • '
              '${p.createdAt.toLocal().day.toString().padLeft(2, '0')}/'
              '${p.createdAt.toLocal().month.toString().padLeft(2, '0')}/'
              '${p.createdAt.toLocal().year}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, p),
                  child: const Text(
                    'Bắt đầu',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kAppBlue,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.grey,
                  onPressed: () => _deletePlan(p),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Lightweight per-trip metadata, loaded once when the screen opens, so the
/// list never re-reads/decodes the (potentially large) JSON in build().
class _TripSummary {
  final String name;
  final List<TripPlace> places;
  final double distanceKm;
  final double sizeKb;
  final DateTime date;
  final String dateLabel;

  _TripSummary({
    required this.name,
    required this.places,
    required this.distanceKm,
    required this.sizeKb,
    required this.date,
    required this.dateLabel,
  });
}
