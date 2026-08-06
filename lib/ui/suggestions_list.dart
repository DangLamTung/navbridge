/// Dropdown list of Nominatim results shown under the search bar.
library;

import 'package:flutter/material.dart';

import '../offline_poi.dart';
import '../osm_api.dart';
import 'widgets.dart';

class SuggestionList extends StatelessWidget {
  const SuggestionList({
    super.key,
    required this.suggestions,
    required this.onSelected,
  });

  final List<OsmSuggestion> suggestions;
  final ValueChanged<OsmSuggestion> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in suggestions)
            ListTile(
              dense: true,
              leading: s.poi != null
                  ? _PoiLeading(poi: s.poi!)
                  : const Icon(Icons.place_outlined, color: kAppBlue),
              title: Text(
                s.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: s.poi?.subtitle.isNotEmpty ?? false
                  ? Text(
                      s.poi!.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                      ),
                    )
                  : null,
              trailing: const Icon(Icons.north_west, size: 16, color: Colors.grey),
              onTap: () => onSelected(s),
            ),
        ],
      ),
    );
  }
}

/// Category emoji for an offline POI (loaded from the bundled index).
class _PoiLeading extends StatelessWidget {
  const _PoiLeading({required this.poi});

  final OfflinePoi poi;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _emoji(),
      builder: (_, snap) => CircleAvatar(
        radius: 14,
        backgroundColor: kAppBlue.withValues(alpha: 0.12),
        child: Text(
          snap.data ?? '📍',
          style: const TextStyle(fontSize: 15),
        ),
      ),
    );
  }

  Future<String> _emoji() async {
    final c = await offlinePoiCategory(poi.category);
    return c?.emoji ?? '📍';
  }
}
