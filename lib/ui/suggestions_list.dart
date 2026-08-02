/// Dropdown list of Nominatim results shown under the search bar.
library;

import 'package:flutter/material.dart';

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
              leading: const Icon(Icons.place_outlined, color: kAppBlue),
              title: Text(
                s.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              trailing: const Icon(Icons.north_west, size: 16, color: Colors.grey),
              onTap: () => onSelected(s),
            ),
        ],
      ),
    );
  }
}
