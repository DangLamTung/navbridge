/// The external download links the offline features depend on, in one place.
///
/// Until now every offline source was reachable only through a build-time
/// `--dart-define` (`NAVMAP_URL` / `GRAPH_URL` / `DATA_URL`). A normal release
/// build therefore carried no URLs at all, so the driver could not see, copy or
/// open the place the data comes from — the Offline screen could only say
/// "configure it at build time". This is the single list the Offline screen
/// renders, so *any* link needed to download for offline is in the app: either
/// the working default (GraphHopper), the configured self-hosted base URL, or a
/// free public source (terrain, basemap).
library;

import 'nav_map_store.dart' show navMapName;
import 'offline_router.dart' show resolveGraphUrl;
import 'terrain.dart' show kTerrainTileUrl;
import 'vietmap_config.dart'
    show dataUpdateBaseUrl, graphDownloadBaseUrl, navMapDownloadBaseUrl;

/// One offline data source: what it is, where it comes from, how to fetch it.
class OfflineLink {
  const OfflineLink({
    required this.title,
    required this.description,
    required this.url,
    this.configured = true,
    this.template = false,
  });

  final String title;
  final String description;

  /// The link to copy or open. When [configured] is false this is a short
  /// explanation of the missing build-time URL, not an address.
  final String url;

  /// False when the feature needs a build-time URL that was not provided, so the
  /// link cannot be opened (the app falls back to bundled data / other sources).
  final bool configured;

  /// True when [url] contains `{z}/{x}/{y}` tile placeholders — copying it is
  /// useful (for a tile server), but opening it in a browser is not.
  final bool template;

  /// True when [url] is a real, openable link.
  bool get openable => configured && !template && url.startsWith('http');
}

/// Every offline download link, in the order the Offline screen shows them.
List<OfflineLink> offlineDownloadLinks() => [
  // 1. On-device turn-by-turn routing (GraphHopper). Always resolvable: the
  //    built-in Geofabrik PBF is converted to a graph on the phone.
  OfflineLink(
    title: 'Bộ dữ liệu chỉ đường (GraphHopper)',
    description: graphDownloadBaseUrl.isEmpty
        ? 'Liên kết mặc định: tải .osm.pbf của Việt Nam rồi chuyển thành graph '
              'trên máy — cần cho chỉ đường ngoại tuyến.'
        : 'GRAPH_URL đã đặt khi build; tệp phải là .ghz hoặc .pbf.',
    url: resolveGraphUrl(),
  ),
  // 2. Offline vector navigation map (PMTiles) — self-hosted.
  OfflineLink(
    title: 'Bản đồ dẫn đường (PMTiles)',
    description: navMapDownloadBaseUrl.isEmpty
        ? 'Chưa cấu hình NAVMAP_URL khi build. Đặt tệp $navMapName trên máy chủ '
              'của bạn rồi build với --dart-define=NAVMAP_URL=http://<host>/'
        : 'Tệp $navMapName trên máy chủ của bạn.',
    url: navMapDownloadBaseUrl.isEmpty
        ? 'Chưa cấu hình NAVMAP_URL (bản đồ mặc định đi kèm app được dùng)'
        : '$navMapDownloadBaseUrl/$navMapName',
    configured: navMapDownloadBaseUrl.isNotEmpty,
  ),
  // 3. Auto-updated traffic point data (cameras + road signs) — self-hosted.
  OfflineLink(
    title: 'Camera & biển báo giao thông',
    description: dataUpdateBaseUrl.isEmpty
        ? 'Chưa cấu hình DATA_URL khi build. Máy chủ cần version.json + '
              'vietnam_cameras.json + vietnam_signs.json (cùng schema với '
              'assets/offline_map/).'
        : 'Cùng schema với assets/offline_map/; app tự tải khi có bản mới.',
    url: dataUpdateBaseUrl.isEmpty
        ? 'Chưa cấu hình DATA_URL (chỉ dùng dữ liệu đi kèm app)'
        : dataUpdateBaseUrl,
    configured: dataUpdateBaseUrl.isNotEmpty,
  ),
  // 4. Offline 3D terrain (Terrarium DEM) — free, no key, downloaded per region.
  OfflineLink(
    title: 'Địa hình 3D (Terrarium DEM)',
    description: 'Nguồn độ cao miễn phí, không cần khoá. Tải theo vùng trong '
        'màn hình này ({z}/{x}/{y} là ô bản đồ).',
    url: kTerrainTileUrl,
    template: true,
  ),
  // 5. Raster basemap tiles — cached automatically while browsing online.
  OfflineLink(
    title: 'Nền bản đồ (raster tiles)',
    description: 'Ô bản đồ được lưu tự động khi bạn xem trực tuyến (nguồn OSM); '
        'vùng đã tải bên dưới cũng ghi vào cùng bộ nhớ đệm.',
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    template: true,
  ),
];
