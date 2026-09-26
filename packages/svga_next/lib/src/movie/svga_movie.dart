import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../model/movie_data.dart';

/// A fully materialised, ready-to-draw SVGA movie.
///
/// All bitmaps are already decoded `ui.Image`s (GPU-resident on Impeller /
/// uploaded by the IO thread on Skia); no encoded image bytes or protobuf
/// remain. Reference counted: whoever obtains one owns one reference and must
/// [release] it. `SvgaController` and `SvgaCache` retain/release for you.
class SvgaMovie {
  /// Internal – use `SvgaLoader`.
  SvgaMovie.fromDecoded(this._data, this._images)
      : _paths = List<ui.Path?>.filled(_data.pathCount, null) {
    for (final s in _data.sprites) {
      _spritesByKey.putIfAbsent(s.imageKey, () => s);
    }
    var bytes = 0;
    for (final img in _images.values) {
      bytes += img.width * img.height * 4;
    }
    for (final a in _data.audioBytes.values) {
      bytes += a.lengthInBytes;
    }
    approximateBytes = bytes;
  }

  final MovieData _data;
  final Map<String, ui.Image> _images;
  final List<ui.Path?> _paths;
  final Map<String, SpriteData> _spritesByKey = {};
  final Expando<ui.Path> _dashed = Expando('svga-dash');

  int _refs = 1;
  bool _disposed = false;

  /// Decoded RGBA footprint + audio bytes; used for the cache budget.
  late final int approximateBytes;

  String get version => _data.version;
  double get width => _data.viewBoxWidth;
  double get height => _data.viewBoxHeight;
  ui.Size get size => ui.Size(width, height);
  int get fps => _data.fps;
  int get frameCount => _data.frameCount;
  Duration get duration =>
      Duration(microseconds: frameCount * Duration.microsecondsPerSecond ~/ math.max(fps, 1));
  List<SpriteData> get sprites => _data.sprites;
  List<AudioData> get audios => _data.audios;
  Map<String, Uint8List> get audioBytes => _data.audioBytes;
  Iterable<String> get imageKeys => _images.keys;
  bool get isDisposed => _disposed;
  int get debugRefCount => _refs;

  ui.Image? imageFor(String key) => _images[key];
  SpriteData? spriteForKey(String key) => _spritesByKey[key];

  /// The slot's native size in viewBox units, before its transform.
  ///
  /// Uses the first visible frame with positive width and height in the first
  /// sprite matching [key]. Returns `null` if there is no such frame.
  /// Multiply by the display scale and device pixel ratio for a pixel size.
  ui.Size? layoutSizeOf(String key) {
    final track = _spritesByKey[key]?.track;
    if (track == null) return null;
    for (var frame = track.firstVisible; frame <= track.lastVisible; frame++) {
      final offset = frame * FrameTrack.stride;
      final width = track.values[offset + 3];
      final height = track.values[offset + 4];
      if (track.visibleAt(frame) && width > 0 && height > 0) {
        return ui.Size(width, height);
      }
    }
    return null;
  }

  /// Built once per distinct path, then reused every frame.
  ui.Path pathOf(PathData p) => _paths[p.id] ??= _buildPath(p);

  /// Dashing via PathMetrics is expensive, so the result is cached per shape.
  ui.Path dashedPathOf(ShapeData shape, ui.Path source) {
    final cached = _dashed[shape];
    if (cached != null) return cached;
    final d = shape.style.dash!;
    final on = d[0], off = math.max(0.0, d[1]).toDouble(), phase = d[2];
    final period = on + off;
    if (on <= 0 || period <= 0) return source;
    final out = ui.Path();
    for (final metric in source.computeMetrics()) {
      var pos = -(phase % period);
      while (pos < metric.length) {
        final start = math.max(0.0, pos).toDouble();
        final end = math.min(metric.length, pos + on).toDouble();
        if (end > start) out.addPath(metric.extractPath(start, end), ui.Offset.zero);
        pos += period;
      }
    }
    _dashed[shape] = out;
    return out;
  }

  void retain() {
    assert(!_disposed, 'retain() on a disposed SvgaMovie');
    _refs++;
  }

  void release() {
    if (_disposed) return;
    assert(_refs > 0);
    if (--_refs == 0) _dispose();
  }

  void _dispose() {
    _disposed = true;
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _paths.fillRange(0, _paths.length, null);
    _data.audioBytes.clear();
  }

  static ui.Path _buildPath(PathData p) {
    final path = ui.Path();
    final pt = p.points;
    var k = 0;
    for (final verb in p.verbs) {
      switch (verb) {
        case PathData.moveTo:
          path.moveTo(pt[k], pt[k + 1]);
          k += 2;
        case PathData.lineTo:
          path.lineTo(pt[k], pt[k + 1]);
          k += 2;
        case PathData.cubicTo:
          path.cubicTo(pt[k], pt[k + 1], pt[k + 2], pt[k + 3], pt[k + 4], pt[k + 5]);
          k += 6;
        case PathData.quadTo:
          path.quadraticBezierTo(pt[k], pt[k + 1], pt[k + 2], pt[k + 3]);
          k += 4;
        case PathData.close:
          path.close();
        case PathData.arcTo:
          path.arcToPoint(
            ui.Offset(pt[k], pt[k + 1]),
            radius: ui.Radius.elliptical(pt[k + 2], pt[k + 3]),
            rotation: pt[k + 4],
            largeArc: pt[k + 5] != 0,
            clockwise: pt[k + 6] != 0,
          );
          k += 7;
      }
    }
    return path;
  }
}
