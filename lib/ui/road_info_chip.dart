/// Floating chip shown while navigating: road name, road class and an
/// EU-style speed-limit sign (white circle, red ring).
library;

import 'package:flutter/material.dart';

import '../overpass.dart';
import 'widgets.dart';

class RoadInfoChip extends StatelessWidget {
  const RoadInfoChip({super.key, this.info, this.loading = false});

  final RoadInfo? info;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final i = info;
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Speed-limit sign.
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: const Color(0xFFD93025), width: 4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    i == null ? '--' : '${i.speedLimit}',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        height: 1.0),
                  ),
                  const Text(
                    'km/h',
                    style: TextStyle(
                        fontSize: 7,
                        fontWeight: FontWeight.w600,
                        height: 1.1),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i?.label ?? (loading ? 'Đang tải…' : 'Ngoài đường'),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: kAppBlue),
                ),
                Text(
                  (i != null && i.name.isNotEmpty) ? i.name : (i?.highway ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
