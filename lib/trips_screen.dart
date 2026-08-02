/// Trip history — list saved Google-Takeout-format logs; share or delete.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'trip_logger.dart';
import 'ui/widgets.dart';

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  List<File> _trips = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final t = await listTrips();
    if (mounted) setState(() => _trips = t);
  }

  String _displayName(File f) => f.uri.pathSegments.last;

  Future<void> _share(File f) async {
    try {
      await Share.shareXFiles(
        [XFile(f.path, mimeType: 'application/json')],
        text: 'Chuyến đi — ${_displayName(f)}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Không chia sẻ được: $e')));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Chuyến đi đã ghi',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _trips.isEmpty
          ? const Center(
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
            )
          : ListView.separated(
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
                        borderRadius: BorderRadius.circular(14)),
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFFE8F0FE),
                      child: Icon(Icons.directions_car,
                          color: kAppBlue, size: 22),
                    ),
                    title: Text(
                      _displayName(f),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
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
            ),
    );
  }
}
