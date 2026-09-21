import 'package:flutter/foundation.dart';

@immutable
final class SvgaDecodeOptions {
  const SvgaDecodeOptions({
    this.enableAudio = true,
    this.maxImageDimension,
    this.decodeConcurrency = 4,
  }) : assert(decodeConcurrency > 0);

  /// When false, audio payloads are dropped inside the parser isolate and
  /// never reach the main isolate.
  final bool enableAudio;

  /// Downscale any bitmap whose longest side exceeds this (in pixels) at
  /// decode time. Many gift exports ship 1500px PNGs for a 375pt banner;
  /// capping at e.g. 1024 can cut texture memory by >50%.
  final int? maxImageDimension;

  /// Parallel image decodes. The engine decodes on its own worker threads,
  /// this just bounds peak memory from in-flight decodes.
  final int decodeConcurrency;

  /// Movies decoded with different options are cached separately.
  String get cacheSuffix => 'a${enableAudio ? 1 : 0}m${maxImageDimension ?? 0}';

  @override
  bool operator ==(Object other) =>
      other is SvgaDecodeOptions &&
      other.enableAudio == enableAudio &&
      other.maxImageDimension == maxImageDimension &&
      other.decodeConcurrency == decodeConcurrency;

  @override
  int get hashCode => Object.hash(enableAudio, maxImageDimension, decodeConcurrency);
}
