/// Dropdown list of Nominatim results shown under the search bar.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/ui/widgets.dart';

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
            // Custom row instead of ListTile: ListTile has a FIXED height for
            // its 1/2/3-line modes, so a multi-line address overflows it
            // ("RenderFlex overflowed"). A plain InkWell + Text lets the
            // full address wrap freely (up to 3 lines) with no overflow.
            InkWell(
              onTap: () => onSelected(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.poi != null)
                      _PoiLeading(poi: s.poi!)
                    else
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.place_outlined, color: kAppBlue),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.display,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, height: 1.3),
                          ),
                          if ((s.poi?.subtitle.isNotEmpty ?? false))
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                s.poi!.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.north_west,
                        size: 16,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
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
        child: Text(snap.data ?? '📍', style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Future<String> _emoji() async {
    final c = await offlinePoiCategory(poi.category);
    return c?.emoji ?? '📍';
  }
}
