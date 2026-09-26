/// Thrown when an SVGA file cannot be loaded or parsed.
///
/// Only holds strings so it can be thrown inside a background isolate and
/// re-thrown on the main isolate by `Isolate.run`.
class SvgaException implements Exception {
  const SvgaException(this.message, [this.cause]);

  final String message;
  final String? cause;

  @override
  String toString() =>
      cause == null ? 'SvgaException: $message' : 'SvgaException: $message ($cause)';
}
