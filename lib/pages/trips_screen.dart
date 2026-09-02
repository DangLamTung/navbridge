/// Trip history — list saved Google-Takeout-format logs; share or delete.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/ui/widgets.dart';

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  List<File> _trips = [];
  List<TripPlan> _plans = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final t = await listTrips();
    final p = await loadPlans();
    if (mounted) {
      setState(() {
        _trips = t;
        _plans = p;
      });
    }
  }

  String _displayName(File f) => f.uri.pathSegments.last;

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
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _trips.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final f = _trips[i];
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
              child: Icon(Icons.directions_car, color: kAppBlue, size: 22),
            ),
            title: Text(
              _displayName(f),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB • '
              '${f.statSync().modified.toLocal()}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
        );
      },
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
              '${p.stops.length} điểm dừng • ${p.createdAt.toLocal()}',
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
