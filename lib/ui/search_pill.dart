/// The floating Google-Maps-style search bar.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/ui/widgets.dart';

class SearchPill extends StatelessWidget {
  const SearchPill({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    this.busy = false,
    this.showClear = false,
    this.onDirections,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// True while searching or building a route (shows spinner instead of icon).
  final bool busy;

  /// Whether to show the clear (×) button.
  final bool showClear;

  /// When set, shows a small "Chỉ đường" (directions) icon at the right edge
  /// that switches the bar into directions mode (start/end + stops).
  final VoidCallback? onDirections;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(28),
      color: Colors.white,
      child: Container(
        height: 50,
        padding: const EdgeInsets.only(left: 16, right: 6),
        child: Row(
          children: [
            Icon(
              busy ? Icons.hourglass_top : Icons.search,
              color: kAppBlue,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Tìm kiếm địa điểm',
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 15),
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (showClear)
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: onClear,
              ),
            if (onDirections != null)
              IconButton(
                tooltip: 'Chỉ đường',
                icon: const Icon(Icons.directions, size: 20),
                color: const Color(0xFF1A73E8),
                onPressed: onDirections,
              ),
          ],
        ),
      ),
    );
  }
}
