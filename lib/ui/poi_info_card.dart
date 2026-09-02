/// Wiki-style info card for an offline POI: name, category emoji, address,
/// phone, opening hours, description, and a Wikipedia / website link.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/ui/widgets.dart';

/// Bottom-sheet detail card shown when the user taps an offline POI result.
/// Shows the rich OSM metadata when present, plus a "đi đến" (navigate) action.
void showPoiInfoCard(
  BuildContext context, {
  required OfflinePoi poi,
  required String categoryLabel,
  required String categoryEmoji,
  required VoidCallback onNavigate,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PoiInfoCard(
      poi: poi,
      categoryLabel: categoryLabel,
      categoryEmoji: categoryEmoji,
      onNavigate: onNavigate,
    ),
  );
}

class PoiInfoCard extends StatelessWidget {
  const PoiInfoCard({
    super.key,
    required this.poi,
    required this.categoryLabel,
    required this.categoryEmoji,
    required this.onNavigate,
  });

  final OfflinePoi poi;
  final String categoryLabel;
  final String categoryEmoji;
  final VoidCallback onNavigate;

  Future<void> _open(String url) async {
    final u = Uri.tryParse(url);
    if (u == null) return;
    final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: kAppBlue.withValues(alpha: 0.12),
                    child: Text(
                      categoryEmoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          poi.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          categoryLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (poi.address != null)
                _row(Icons.location_on_outlined, poi.address!),
              if (poi.phone != null) _row(Icons.call_outlined, poi.phone!),
              if (poi.openingHours != null)
                _row(Icons.schedule_outlined, poi.openingHours!),
              if (poi.description != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    poi.description!,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              if (poi.wikipedia != null ||
                  (poi.website != null && poi.website!.isNotEmpty)) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (poi.wikipedia != null)
                      ActionChip(
                        avatar: const Icon(Icons.menu_book, size: 16),
                        label: const Text('Wikipedia'),
                        onPressed: () => _open(_wikiUrl(poi.wikipedia!)),
                      ),
                    if (poi.website != null && poi.website!.isNotEmpty)
                      ActionChip(
                        avatar: const Icon(Icons.language, size: 16),
                        label: Text(_host(poi.website!)),
                        onPressed: () => _open(_withScheme(poi.website!)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAppBlue,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: onNavigate,
                  icon: const Icon(Icons.navigation),
                  label: const Text(
                    'Đi đến đây',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return card;
  }

  Widget _row(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
        ],
      ),
    );
  }
}

/// "vi:Địa_đạo_Củ_Chi" → en.wikipedia/wiki/… or vi.wikipedia.org/wiki/…
String _wikiUrl(String ref) {
  final colon = ref.indexOf(':');
  if (ref.startsWith('wikidata:')) {
    final qid = ref.substring('wikidata:'.length);
    return 'https://www.wikidata.org/wiki/$qid';
  }
  if (colon <= 0) return 'https://en.wikipedia.org/wiki/$ref';
  final lang = ref.substring(0, colon);
  final title = ref.substring(colon + 1);
  return 'https://$lang.wikipedia.org/wiki/${Uri.encodeComponent(title)}';
}

String _withScheme(String url) => url.startsWith('http') ? url : 'https://$url';

String _host(String url) {
  final u = Uri.tryParse(_withScheme(url));
  return u?.host ?? url;
}
