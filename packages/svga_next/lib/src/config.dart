/// Process-wide settings. Configure once at startup.
abstract final class SvgaConfig {
  /// Directory for the raw `.svga` disk cache (e.g. from path_provider's
  /// `getTemporaryDirectory()`). `null` disables disk caching.
  ///
  /// Reads/writes happen inside the background isolate, never on the UI thread.
  static String? diskCacheDirectory;

  /// Network timeout for the built-in downloader.
  static Duration networkTimeout = const Duration(seconds: 20);
}
