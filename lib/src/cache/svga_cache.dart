import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../movie/svga_movie.dart';

/// In-memory LRU of decoded movies with a byte budget.
///
/// * Concurrent requests for the same key share one parse/decode.
/// * The cache holds its own reference; eviction only releases that
///   reference, so a movie that is currently on screen is never freed under
///   the player – it is disposed when the last player lets go.
/// * Cleared automatically on OS memory pressure.
class SvgaCache {
  SvgaCache({this.maxBytes = 64 << 20, this.maxEntries = 24});

  static final SvgaCache instance = SvgaCache();

  /// Budget in decoded (RGBA) bytes.
  int maxBytes;
  int maxEntries;

  final LinkedHashMap<String, SvgaMovie> _entries = LinkedHashMap();
  final Map<String, Future<SvgaMovie>> _inflight = {};
  int _bytes = 0;
  _PressureObserver? _observer;

  int get currentBytes => _bytes;
  int get length => _entries.length;
  bool containsKey(String key) => _entries.containsKey(key);

  /// Returns a movie with one reference owned by the caller.
  Future<SvgaMovie> obtain(String key, Future<SvgaMovie> Function() create) async {
    _ensureObserver();
    while (true) {
      final hit = _entries.remove(key);
      if (hit != null && !hit.isDisposed) {
        _entries[key] = hit; // move to MRU
        return hit..retain();
      }
      if (hit != null) _bytes -= hit.approximateBytes;
      final movie = await (_inflight[key] ??= _create(key, create));
      if (!movie.isDisposed) return movie..retain();
      // Evicted between completion and resumption – try again.
    }
  }

  Future<SvgaMovie> _create(String key, Future<SvgaMovie> Function() create) async {
    try {
      final movie = await create(); // ref #1 becomes the cache's reference
      _entries[key] = movie;
      _bytes += movie.approximateBytes;
      _trim();
      return movie;
    } finally {
      _inflight.remove(key);
    }
  }

  void evict(String key) {
    final m = _entries.remove(key);
    if (m == null) return;
    _bytes -= m.approximateBytes;
    m.release();
  }

  void clear() {
    for (final k in _entries.keys.toList()) {
      evict(k);
    }
  }

  void _trim() {
    while (_entries.length > 1 && (_bytes > maxBytes || _entries.length > maxEntries)) {
      evict(_entries.keys.first);
    }
  }

  void _ensureObserver() {
    if (_observer != null) return;
    try {
      final o = _PressureObserver(this);
      WidgetsBinding.instance.addObserver(o);
      _observer = o;
    } catch (_) {
      // Binding not initialised (pure Dart tests) – fine.
    }
  }
}

class _PressureObserver with WidgetsBindingObserver {
  _PressureObserver(this.cache);

  final SvgaCache cache;

  @override
  void didHaveMemoryPressure() => cache.clear();
}
