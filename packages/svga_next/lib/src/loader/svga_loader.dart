import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../cache/svga_cache.dart';
import '../config.dart';
import '../model/movie_data.dart';
import '../movie/svga_movie.dart';
import 'svga_decode_options.dart';
import 'svga_source.dart';

abstract final class SvgaLoader {
  static int _activeLoads = 0;
  static final Queue<Completer<void>> _pendingLoads = Queue();

  /// Loads, parses (background isolate) and pre-decodes every bitmap before
  /// completing, so frame 1 never waits on a decode.
  ///
  /// The returned movie carries ONE reference owned by the caller – hand it
  /// to an `SvgaController` (which retains its own) and then [SvgaMovie.release].
  /// `SvgaPlayer` does this for you.
  static Future<SvgaMovie> load(
    SvgaSource source, {
    SvgaDecodeOptions options = const SvgaDecodeOptions(),
    SvgaCache? cache,
  }) {
    final key = source.cacheKey;
    if (key == null) return _loadUncached(source, options);
    return (cache ?? SvgaCache.instance).obtain(
        '$key#${options.cacheSuffix}', () => _loadUncached(source, options));
  }

  /// Warm the cache ahead of time (e.g. for the next gift in the queue).
  /// Only meaningful for sources with a cache key.
  static Future<void> preload(
    SvgaSource source, {
    SvgaDecodeOptions options = const SvgaDecodeOptions(),
    SvgaCache? cache,
  }) async {
    final movie = await load(source, options: options, cache: cache);
    movie.release();
  }

  static Future<SvgaMovie> _loadUncached(
      SvgaSource source, SvgaDecodeOptions options) async {
    final slot = Completer<void>();
    _pendingLoads.addLast(slot);
    _startPendingLoads();
    await slot.future;
    try {
      final data = await source.parse(options);
      return await materialize(data, options);
    } finally {
      _activeLoads--;
      _startPendingLoads();
    }
  }

  static void _startPendingLoads() {
    while (_pendingLoads.isNotEmpty &&
        _activeLoads < SvgaConfig.maxConcurrentLoads) {
      _activeLoads++;
      _pendingLoads.removeFirst().complete();
    }
  }

  /// Turns parsed data into GPU-ready `ui.Image`s and purges every encoded
  /// byte array as soon as it has been decoded.
  static Future<SvgaMovie> materialize(
      MovieData data, SvgaDecodeOptions options) async {
    final keys = data.images.keys.toList(growable: false);
    final decoded = <String, ui.Image>{};
    try {
      var next = 0;
      Future<void> worker() async {
        while (next < keys.length) {
          final key = keys[next++];
          final bytes = data.images[key];
          if (bytes == null) continue;
          try {
            decoded[key] = await _decode(bytes, options.maxImageDimension);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('svga_next: failed to decode image "$key": $e');
            }
          }
          // Purge immediately: drop the reference to the encoded bytes.
          data.images.remove(key);
        }
      }

      await Future.wait(
        List.generate(
            math.min(options.decodeConcurrency, keys.length), (_) => worker()),
      );
    } catch (_) {
      for (final img in decoded.values) {
        img.dispose();
      }
      rethrow;
    } finally {
      // Once empty, nothing references the inflated protobuf buffer any more.
      data.images.clear();
    }
    return SvgaMovie.fromDecoded(data, decoded);
  }

  static Future<ui.Image> _decode(Uint8List bytes, int? maxDim) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } finally {
      buffer.dispose();
    }
    int? tw, th;
    if (maxDim != null) {
      final longest = math.max(descriptor.width, descriptor.height);
      if (longest > maxDim) {
        final s = maxDim / longest;
        tw = math.max(1, (descriptor.width * s).round());
        th = math.max(1, (descriptor.height * s).round());
      }
    }
    final codec =
        await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
      descriptor.dispose();
    }
  }
}
