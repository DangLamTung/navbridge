/// Google-Maps-style DIRECTIONS bar (start + end + swap + add stop).
///
/// Shown in directions mode instead of the single search pill. Two stacked
/// fields — "Điểm bắt đầu" (top) and "Điểm đến" (bottom) — with a swap
/// button between them and an "Thêm điểm dừng" row at the bottom. Typing in
/// either field fills the active one; tapping the map sets it too.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/ui/widgets.dart';

class DirectionsBar extends StatelessWidget {
  const DirectionsBar({
    super.key,
    required this.startController,
    required this.startFocus,
    required this.endController,
    required this.endFocus,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onSwap,
    required this.onAddStop,
    required this.onBackToSearch,
    this.onCollapse,
    this.busy = false,
    this.startLabel = 'Vị trí hiện tại',
  });

  final TextEditingController startController;
  final FocusNode startFocus;
  final TextEditingController endController;
  final FocusNode endFocus;
  final ValueChanged<String> onStartChanged;
  final ValueChanged<String> onEndChanged;
  final VoidCallback onSwap;
  final VoidCallback onAddStop;
  final VoidCallback onBackToSearch;

  /// When provided, shows a collapse (chevron) button that shrinks the bar
  /// into [CollapsedDirectionsBar] to free the map.
  final VoidCallback? onCollapse;

  /// True while searching or building a route (spinner in the end field).
  final bool busy;

  /// Text shown in the start field when it's empty (defaults to current
  /// location).
  final String startLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- start field (top) ----
          Row(
            children: [
              const SizedBox(width: 14),
              const _FieldDot(color: Color(0xFF34A853)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: startController,
                  focusNode: startFocus,
                  onChanged: onStartChanged,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    hintText: 'Điểm bắt đầu',
                    labelText: startLabel,
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              if (startController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    startController.clear();
                    onStartChanged('');
                  },
                ),
              // Swap button between the two fields (Google ⇅).
              IconButton(
                tooltip: 'Đổi điểm bắt đầu / điểm đến',
                icon: const Icon(Icons.swap_vert, size: 20),
                color: kAppBlue,
                onPressed: onSwap,
              ),
              if (onCollapse != null)
                IconButton(
                  tooltip: 'Thu gọn thanh chỉ đường',
                  icon: Icon(
                    Icons.expand_more,
                    size: 20,
                    color: Colors.grey[600],
                  ),
                  onPressed: onCollapse,
                ),
              const SizedBox(width: 4),
            ],
          ),
          const Divider(height: 1),
          // ---- end field (bottom) ----
          Row(
            children: [
              const SizedBox(width: 14),
              const _FieldDot(color: Color(0xFFEA4335)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: endController,
                  focusNode: endFocus,
                  onChanged: onEndChanged,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Điểm đến',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  style: const TextStyle(fontSize: 14),
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
              if (endController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    endController.clear();
                    onEndChanged('');
                  },
                ),
              const SizedBox(width: 4),
            ],
          ),
          const Divider(height: 1),
          // ---- add stop + back to search ----
          // Both buttons are Flexible + FittedBox(scaleDown) so this row can
          // never overflow ("RIGHT OVERFLOWED BY N PIXELS") when the bar is
          // squeezed beside the mic + displays buttons on narrow phones.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onAddStop,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text(
                      'Thêm điểm dừng',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onBackToSearch,
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text(
                      'Tìm kiếm',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact single-row version of the directions bar (shown when the user
/// collapses it to free the map): green start → red destination + a chevron
/// to expand back into the full start/end form.
class CollapsedDirectionsBar extends StatelessWidget {
  const CollapsedDirectionsBar({
    super.key,
    required this.destination,
    required this.startLabel,
    required this.onExpand,
    this.onBackToSearch,
  });

  final String destination;
  final String startLabel;
  final VoidCallback onExpand;
  final VoidCallback? onBackToSearch;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onExpand,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const _FieldDot(color: Color(0xFF34A853)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  startLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
              ),
              const Icon(Icons.arrow_forward, size: 14, color: Colors.black38),
              const SizedBox(width: 8),
              const _FieldDot(color: Color(0xFFEA4335)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  destination,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onBackToSearch != null)
                IconButton(
                  tooltip: 'Tìm kiếm',
                  icon: const Icon(Icons.search, size: 20),
                  color: kAppBlue,
                  onPressed: onBackToSearch,
                ),
              IconButton(
                tooltip: 'Mở rộng thanh chỉ đường',
                icon: Icon(
                  Icons.expand_less,
                  size: 22,
                  color: Colors.grey[700],
                ),
                onPressed: onExpand,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small colored dot marker (green start / red end), Google-Maps style.
class _FieldDot extends StatelessWidget {
  const _FieldDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
      ),
    );
  }
}
