/// Panel under the search bar listing the planned stops of a multi-stop trip:
/// reorder, remove, add another, or save the plan.
library;

import 'package:flutter/material.dart';

import '../trip_plan.dart';
import 'widgets.dart';

class StopsPanel extends StatelessWidget {
  const StopsPanel({
    super.key,
    required this.stops,
    required this.onAdd,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    required this.onSave,
  });

  final List<TripStop> stops;
  final VoidCallback onAdd;
  final ValueChanged<int> onMoveUp;
  final ValueChanged<int> onMoveDown;
  final ValueChanged<int> onRemove;
  final VoidCallback onSave;

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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 0),
            child: Row(
              children: [
                const Icon(Icons.route, size: 16, color: kAppBlue),
                const SizedBox(width: 6),
                Text(
                  'Điểm dừng (${stops.length})',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text('Lưu',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          for (var i = 0; i < stops.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor:
                        i == stops.length - 1 ? const Color(0xFFEA4335) : kAppBlue,
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      stops[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: i == 0 ? null : () => onMoveUp(i),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        i == stops.length - 1 ? null : () => onMoveDown(i),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onRemove(i),
                  ),
                ],
              ),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.add, size: 18, color: kAppBlue),
            title: const Text('Thêm điểm dừng',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            onTap: onAdd,
          ),
        ],
      ),
    );
  }
}
