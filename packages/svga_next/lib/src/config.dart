/// Process-wide settings. Configure once at startup.
abstract final class SvgaConfig {
  /// Maximum concurrent uncached loads, including parsing and image decoding.
  ///
  /// Defaults to 2. Cache hits and shared in-flight loads bypass this limit.
  /// Lowering it affects new acquisitions; active loads finish normally.
  /// Must be positive; setting a nonpositive value throws [RangeError].
  static int get maxConcurrentLoads => _maxConcurrentLoads;
  static int _maxConcurrentLoads = 2;

  static set maxConcurrentLoads(int value) {
    if (value < 1) {
      throw RangeError.range(value, 1, null, 'maxConcurrentLoads');
    }
    _maxConcurrentLoads = value;
  }

  /// Directory for the raw `.svga` disk cache (e.g. from path_provider's
  /// `getTemporaryDirectory()`). `null` disables disk caching.
  ///
  /// Reads/writes happen inside the background isolate, never on the UI thread.
  static String? diskCacheDirectory;

  /// Network timeout for the built-in downloader.
  static Duration networkTimeout = const Duration(seconds: 20);
}
