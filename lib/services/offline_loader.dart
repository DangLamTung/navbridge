/// Generic cached-async loader used by the offline data services.
///
/// Each service used to repeat the same `_loaded` / `_loading` / `loadXxx()`
/// boilerplate; this hoists it so a service only supplies the actual fetch
/// and the caching + failure-fallback live in one place.
library;

/// Lazily loads a list once and caches it. On failure it caches an empty list
/// and never retries — callers are expected to degrade gracefully (e.g. show
/// the statutory default instead of a real value).
class OfflineListLoader<T> {
  final Future<List<T>> Function() _fetch;

  List<T>? _items;
  Future<List<T>>? _loading;

  OfflineListLoader(this._fetch);

  /// Load the value once (idempotent, cached). Never throws; a failed fetch
  /// yields an empty list.
  Future<List<T>> load() {
    final cached = _items;
    if (cached != null) return Future.value(cached);
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final fut = _doLoad();
    _loading = fut;
    return fut;
  }

  Future<List<T>> _doLoad() async {
    try {
      _items = await _fetch();
    } catch (_) {
      _items = const [];
    } finally {
      _loading = null;
    }
    return _items!;
  }
}
