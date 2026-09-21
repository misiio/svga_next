import 'dart:typed_data';

// Everything in this file is plain Dart data (no dart:ui handles), so the
// whole graph can leave the parser isolate through `Isolate.exit` (which is
// what `Isolate.run` uses) *without being copied*.

/// Result of background parsing. Owned by an `SvgaMovie` once materialised.
final class MovieData {
  MovieData({
    required this.version,
    required this.viewBoxWidth,
    required this.viewBoxHeight,
    required this.fps,
    required this.frameCount,
    required this.sprites,
    required this.audios,
    required this.images,
    required this.audioBytes,
    required this.pathCount,
  });

  final String version;
  final double viewBoxWidth;
  final double viewBoxHeight;
  final int fps;
  final int frameCount;
  final List<SpriteData> sprites;
  final List<AudioData> audios;

  /// Encoded bitmaps (PNG / WebP / JPEG) keyed by imageKey. These are views
  /// into the inflated protobuf buffer; the loader clears this map as soon as
  /// every entry has become a `ui.Image`, which releases that buffer.
  final Map<String, Uint8List> images;

  /// Audio payloads (usually MP3), detached copies so they don't pin the
  /// inflated buffer.
  final Map<String, Uint8List> audioBytes;

  /// Number of distinct (interned) paths; sizes the main-isolate `ui.Path` cache.
  final int pathCount;
}

final class SpriteData {
  SpriteData({required this.imageKey, required this.matteKey, required this.track});

  final String imageKey;

  /// Key of the sprite used as an alpha mask for this sprite (SVGA 2.x mattes).
  final String? matteKey;
  final FrameTrack track;

  /// Matte sprites are never drawn directly; they only mask other sprites.
  bool get isMatte => imageKey.endsWith('.matte');
}

/// Per-sprite frame data stored as a struct-of-arrays.
///
/// Instead of N `FrameEntity` objects (each with Layout/Transform children)
/// every scalar lives in one contiguous `Float32List`:
/// `[alpha, x, y, w, h, a, b, c, d, tx, ty] * frameCount`.
final class FrameTrack {
  FrameTrack({
    required this.length,
    required this.values,
    required this.clips,
    required this.shapes,
    required this.firstVisible,
    required this.lastVisible,
  });

  static const int stride = 11;

  final int length;
  final Float32List values;

  /// `null` when the sprite never clips (the common case) – no per-frame list at all.
  final List<PathData?>? clips;

  /// `null` when the sprite has no vector shapes. KEEP frames share the
  /// previous frame's list instance.
  final List<List<ShapeData>>? shapes;

  /// Visible frame range (alpha > 0) for O(1) culling.
  final int firstVisible;
  final int lastVisible;

  double alphaAt(int frame) => frame < length ? values[frame * stride] : 0;

  bool visibleAt(int frame) =>
      frame >= firstVisible && frame <= lastVisible && values[frame * stride] > 0;
}

/// An SVG path pre-tokenised into absolute verbs and points (background
/// isolate). Turned into a `ui.Path` lazily on the main isolate and cached by [id].
final class PathData {
  PathData(this.id, this.verbs, this.points);

  static const int moveTo = 0; // x y
  static const int lineTo = 1; // x y
  static const int cubicTo = 2; // x1 y1 x2 y2 x y
  static const int quadTo = 3; // x1 y1 x y
  static const int close = 4; //
  static const int arcTo = 5; // x y rx ry rotationDeg largeArc(0/1) sweep(0/1)

  final int id;
  final Uint8List verbs;
  final Float32List points;
}

enum ShapeKind { path, rect, ellipse }

final class ShapeData {
  ShapeData({required this.kind, required this.style, this.path, this.args, this.transform});

  final ShapeKind kind;
  final PathData? path;

  /// rect: `[x, y, w, h, cornerRadius]`, ellipse: `[cx, cy, rx, ry]`.
  final Float32List? args;

  /// `[a, b, c, d, tx, ty]` or null for identity.
  final Float32List? transform;
  final ShapeStyle style;
}

final class ShapeStyle {
  const ShapeStyle({
    this.fill,
    this.stroke,
    this.strokeWidth = 0,
    this.lineCap = 0,
    this.lineJoin = 0,
    this.miterLimit = 4,
    this.dash,
  });

  /// ARGB ints; null means "don't paint".
  final int? fill;
  final int? stroke;
  final double strokeWidth;

  /// 0 butt, 1 round, 2 square.
  final int lineCap;

  /// 0 miter, 1 round, 2 bevel.
  final int lineJoin;
  final double miterLimit;

  /// `[dash, gap, offset]` or null.
  final Float32List? dash;
}

final class AudioData {
  const AudioData({
    required this.key,
    required this.startFrame,
    required this.endFrame,
    required this.startTimeMs,
    required this.totalTimeMs,
  });

  final String key;
  final int startFrame;
  final int endFrame;

  /// Offset into the audio file at which playback starts.
  final int startTimeMs;
  final int totalTimeMs;
}
