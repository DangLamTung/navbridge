/// "Tìm kiếm gần đây" — the places searched before, shown under the search bar
/// as soon as the field is focused (Google-Maps style "previous searches") so
/// a repeat destination is one tap away with no typing and no network call.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/ui/widgets.dart';

class RecentSearchesList extends StatelessWidget {
  const RecentSearchesList({
    super.key,
    required this.items,
    required this.onSelected,
    required this.onRemove,
    required this.onClear,
  });

  /// Newest first.
  final List<OsmSuggestion> items;

  /// Tap on a previous search → pin / place card / route (no search request).
  final ValueChanged<OsmSuggestion> onSelected;

  /// Drop one entry from the history.
  final ValueChanged<OsmSuggestion> onRemove;

  /// Forget the whole history.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    // Cap the height so a full history never hides the map on a small phone —
    // the list scrolls instead of growing off-screen.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: Material(
        elevation: 6,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
              child: Row(
                children: [
                  Icon(Icons.history, size: 16, color: kAppBlue),
                  const SizedBox(width: 6),
                  const Text(
                    'Tìm kiếm gần đây',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: onClear,
                    child: const Text('Xoá hết', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 4),
                itemCount: items.length,
                itemBuilder: (_, i) => _row(context, items[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, OsmSuggestion s) {
    // Custom row instead of ListTile: a ListTile has a FIXED height for its
    // 1/2/3-line modes, so a long address overflows it ("RenderFlex
    // overflowed"). A plain InkWell + wrapping Text has no such limit.
    return InkWell(
      onTap: () => onSelected(s),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            const Icon(Icons.history, size: 18, color: kAppBlue),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                s.display,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.3),
              ),
            ),
            IconButton(
              tooltip: 'Xoá khỏi lịch sử',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, color: Colors.grey[600]),
              onPressed: () => onRemove(s),
            ),
          ],
        ),
      ),
    );
  }
}
