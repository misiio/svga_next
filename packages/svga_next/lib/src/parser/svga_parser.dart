import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;

import '../errors.dart';
import '../model/movie_data.dart';
import 'proto_reader.dart';
import 'svg_path_parser.dart';

/// Parses raw `.svga` bytes. Pure Dart, designed to run inside `Isolate.run`.
///
/// * SVGA 2.x: zlib-deflated protobuf `MovieEntity` (inflated with dart:io's
///   native zlib, not a Dart port).
/// * SVGA 1.x: ZIP containing `movie.spec` (JSON) or `movie.binary` + PNGs.
MovieData parseSvgaBytes(Uint8List bytes, {bool keepAudio = true}) {
  if (bytes.length < 4) throw const SvgaException('Not an SVGA file: too small');
  try {
    if (_isZip(bytes)) return _parseZip(bytes, keepAudio);
    final proto = bytes[0] == 0x78 ? _inflate(bytes) : bytes;
    return _parseMovieEntity(proto, keepAudio: keepAudio);
  } on SvgaException {
    rethrow;
  } catch (e) {
    throw SvgaException('Failed to parse SVGA', e.toString());
  }
}

bool _isZip(Uint8List b) => b[0] == 0x50 && b[1] == 0x4b && b[2] == 0x03 && b[3] == 0x04;

Uint8List _inflate(Uint8List bytes) {
  final out = ZLibCodec().decode(bytes);
  return out is Uint8List ? out : Uint8List.fromList(out);
}

// Sentinel for ShapeType.KEEP ("reuse the previous frame's shapes").
final ShapeData _kKeep = ShapeData(kind: ShapeKind.path, style: const ShapeStyle());

final class _Ctx {
  final Map<String, PathData> _paths = {};
  int _next = 0;

  /// Interns identical `d` strings: AE exports repeat the same clip / shape
  /// path on every frame, so this typically collapses hundreds of paths to a
  /// handful, and the main isolate builds each `ui.Path` exactly once.
  PathData path(String d) => _paths[d] ??= parseSvgPath(d, _next++);

  int get pathCount => _next;
}

final class _TrackBuilder {
  final List<double> _v = [];
  List<PathData?>? _clips;
  List<List<ShapeData>>? _shapes;
  List<ShapeData> _prev = const [];
  int _n = 0;

  void add({
    required double alpha,
    required List<double> layout,
    List<double>? transform,
    PathData? clip,
    List<ShapeData>? shapes,
    bool keep = false,
  }) {
    _v
      ..add(alpha)
      ..add(layout[0])
      ..add(layout[1])
      ..add(layout[2])
      ..add(layout[3]);
    if (transform == null) {
      _v.addAll(const [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    } else {
      for (var i = 0; i < 6; i++) {
        _v.add(transform[i]);
      }
    }

    if (clip != null && _clips == null) _clips = List<PathData?>.filled(_n, null, growable: true);
    _clips?.add(clip);

    final resolved = keep ? _prev : (shapes ?? const <ShapeData>[]);
    if (resolved.isNotEmpty && _shapes == null) {
      _shapes = List<List<ShapeData>>.filled(_n, const <ShapeData>[], growable: true);
    }
    _shapes?.add(resolved);
    _prev = resolved;
    _n++;
  }

  FrameTrack build() {
    var first = _n, last = -1;
    for (var f = 0; f < _n; f++) {
      if (_v[f * FrameTrack.stride] > 0) {
        if (f < first) first = f;
        last = f;
      }
    }
    return FrameTrack(
      length: _n,
      values: Float32List.fromList(_v),
      clips: _clips,
      shapes: _shapes,
      firstVisible: first,
      lastVisible: last,
    );
  }
}

// ---------------------------------------------------------------------------
// SVGA 2.x protobuf
// ---------------------------------------------------------------------------

MovieData _parseMovieEntity(
  Uint8List buf, {
  required bool keepAudio,
  Map<String, Uint8List>? looseFiles,
}) {
  final r = ProtoReader(buf);
  final ctx = _Ctx();
  var version = '';
  var w = 0.0, h = 0.0;
  var fps = 20, frames = 0;
  final images = <String, Uint8List>{};
  final sprites = <SpriteData>[];
  final audios = <AudioData>[];

  while (r.hasMore) {
    final tag = r.readTag();
    switch (tag >> 3) {
      case 1:
        version = r.readString();
      case 2: // MovieParams
        final p = r.sub();
        while (p.hasMore) {
          final t = p.readTag();
          switch (t >> 3) {
            case 1:
              w = p.readFloat();
            case 2:
              h = p.readFloat();
            case 3:
              fps = p.readInt32();
            case 4:
              frames = p.readInt32();
            default:
              p.skip(t & 7);
          }
        }
      case 3: // map<string, bytes> images
        final e = r.sub();
        String? key;
        Uint8List? value;
        while (e.hasMore) {
          final t = e.readTag();
          switch (t >> 3) {
            case 1:
              key = e.readString();
            case 2:
              value = e.readBytesView();
            default:
              e.skip(t & 7);
          }
        }
        if (key != null && value != null && value.isNotEmpty) images[key] = value;
      case 4:
        sprites.add(_readSprite(r.sub(), ctx));
      case 5:
        audios.add(_readAudio(r.sub()));
      default:
        r.skip(tag & 7);
    }
  }

  if (looseFiles != null) {
    for (final e in looseFiles.entries) {
      images.putIfAbsent(_stripExt(e.key), () => e.value);
    }
  }

  return _finish(
    version: version,
    w: w,
    h: h,
    fps: fps,
    frames: frames,
    images: images,
    sprites: sprites,
    audios: audios,
    keepAudio: keepAudio,
    ctx: ctx,
  );
}

SpriteData _readSprite(ProtoReader r, _Ctx ctx) {
  var key = '';
  String? matte;
  final tb = _TrackBuilder();
  while (r.hasMore) {
    final t = r.readTag();
    switch (t >> 3) {
      case 1:
        key = r.readString();
      case 2:
        _readFrame(r.sub(), tb, ctx);
      case 3:
        final m = r.readString();
        if (m.isNotEmpty) matte = m;
      default:
        r.skip(t & 7);
    }
  }
  return SpriteData(imageKey: key, matteKey: matte, track: tb.build());
}

void _readFrame(ProtoReader r, _TrackBuilder tb, _Ctx ctx) {
  var alpha = 0.0;
  List<double> layout = const [0.0, 0.0, 0.0, 0.0];
  List<double>? transform;
  PathData? clip;
  List<ShapeData>? shapes;
  var keep = false;
  while (r.hasMore) {
    final t = r.readTag();
    switch (t >> 3) {
      case 1:
        alpha = r.readFloat();
      case 2:
        layout = _floats(r.sub(), 4);
      case 3:
        transform = _floats(r.sub(), 6);
      case 4:
        final d = r.readString();
        if (d.isNotEmpty) clip = ctx.path(d);
      case 5:
        final s = _readShape(r.sub(), ctx);
        if (identical(s, _kKeep)) {
          keep = true;
        } else if (s != null) {
          (shapes ??= <ShapeData>[]).add(s);
        }
      default:
        r.skip(t & 7);
    }
  }
  tb.add(
    alpha: alpha,
    layout: layout,
    transform: transform,
    clip: clip,
    shapes: shapes,
    keep: keep && shapes == null,
  );
}

ShapeData? _readShape(ProtoReader r, _Ctx ctx) {
  var type = 0;
  PathData? path;
  Float32List? args;
  Float32List? transform;
  var style = const ShapeStyle();
  while (r.hasMore) {
    final t = r.readTag();
    switch (t >> 3) {
      case 1:
        type = r.readVarint();
      case 2: // ShapeArgs { string d = 1; }
        final a = r.sub();
        while (a.hasMore) {
          final at = a.readTag();
          if (at >> 3 == 1) {
            final d = a.readString();
            if (d.isNotEmpty) path = ctx.path(d);
          } else {
            a.skip(at & 7);
          }
        }
      case 3: // RectArgs
        args = _floats(r.sub(), 5);
      case 4: // EllipseArgs
        args = _floats(r.sub(), 4);
      case 10:
        style = _readStyle(r.sub());
      case 11:
        transform = _floats(r.sub(), 6);
      default:
        r.skip(t & 7);
    }
  }
  switch (type) {
    case 3:
      return _kKeep;
    case 1:
      return args == null
          ? null
          : ShapeData(kind: ShapeKind.rect, args: args, transform: transform, style: style);
    case 2:
      return args == null
          ? null
          : ShapeData(kind: ShapeKind.ellipse, args: args, transform: transform, style: style);
    default:
      return path == null
          ? null
          : ShapeData(kind: ShapeKind.path, path: path, transform: transform, style: style);
  }
}

ShapeStyle _readStyle(ProtoReader r) {
  int? fill, stroke;
  var strokeWidth = 0.0, miter = 4.0;
  var cap = 0, join = 0;
  final dash = Float32List(3);
  var hasDash = false;
  while (r.hasMore) {
    final t = r.readTag();
    final f = t >> 3;
    switch (f) {
      case 1:
        fill = _color(_floats(r.sub(), 4));
      case 2:
        stroke = _color(_floats(r.sub(), 4));
      case 3:
        strokeWidth = r.readFloat();
      case 4:
        cap = r.readVarint();
      case 5:
        join = r.readVarint();
      case 6:
        miter = r.readFloat();
      case 7 || 8 || 9:
        dash[f - 7] = r.readFloat();
        hasDash = true;
      default:
        r.skip(t & 7);
    }
  }
  return ShapeStyle(
    fill: fill,
    stroke: stroke,
    strokeWidth: strokeWidth,
    lineCap: cap,
    lineJoin: join,
    miterLimit: miter,
    dash: hasDash && dash[0] > 0 ? dash : null,
  );
}

AudioData _readAudio(ProtoReader r) {
  var key = '';
  var sf = 0, ef = 0, st = 0, tt = 0;
  while (r.hasMore) {
    final t = r.readTag();
    switch (t >> 3) {
      case 1:
        key = r.readString();
      case 2:
        sf = r.readInt32();
      case 3:
        ef = r.readInt32();
      case 4:
        st = r.readInt32();
      case 5:
        tt = r.readInt32();
      default:
        r.skip(t & 7);
    }
  }
  return AudioData(key: key, startFrame: sf, endFrame: ef, startTimeMs: st, totalTimeMs: tt);
}

/// Reads a message made only of float fields 1..n (Layout, Transform,
/// RectArgs, EllipseArgs, RGBAColor all have this shape).
Float32List _floats(ProtoReader r, int n) {
  final out = Float32List(n);
  while (r.hasMore) {
    final t = r.readTag();
    final f = t >> 3;
    if ((t & 7) == 5 && f >= 1 && f <= n) {
      out[f - 1] = r.readFloat();
    } else {
      r.skip(t & 7);
    }
  }
  return out;
}

int? _color(List<double> c) {
  final v = _argb(c[0], c[1], c[2], c[3]);
  return ((v >> 24) & 0xff) == 0 ? null : v;
}

int _argb(double r, double g, double b, double a) =>
    (_c8(a) << 24) | (_c8(r) << 16) | (_c8(g) << 8) | _c8(b);

int _c8(double v) => (v.clamp(0.0, 1.0) * 255).round();

// ---------------------------------------------------------------------------
// Shared post-processing
// ---------------------------------------------------------------------------

MovieData _finish({
  required String version,
  required double w,
  required double h,
  required int fps,
  required int frames,
  required Map<String, Uint8List> images,
  required List<SpriteData> sprites,
  required List<AudioData> audios,
  required bool keepAudio,
  required _Ctx ctx,
}) {
  final audioBytes = <String, Uint8List>{};
  for (final a in audios) {
    final raw = images.remove(a.key);
    if (keepAudio && raw != null && !audioBytes.containsKey(a.key)) {
      // Copy: a view would pin the whole inflated buffer for the movie's lifetime.
      audioBytes[a.key] = Uint8List.fromList(raw);
    }
  }
  images.removeWhere((_, b) => !_looksLikeImage(b));

  var frameCount = frames;
  if (frameCount <= 0) {
    for (final s in sprites) {
      frameCount = math.max(frameCount, s.track.length);
    }
  }

  return MovieData(
    version: version,
    viewBoxWidth: w,
    viewBoxHeight: h,
    fps: fps <= 0 ? 20 : fps,
    frameCount: frameCount,
    sprites: sprites,
    audios: keepAudio ? audios : const [],
    images: images,
    audioBytes: audioBytes,
    pathCount: ctx.pathCount,
  );
}

bool _looksLikeImage(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) return true; // PNG
  if (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return true; // JPEG
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return true; // WebP
  }
  return false;
}

String _stripExt(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

// ---------------------------------------------------------------------------
// SVGA 1.x (ZIP)
// ---------------------------------------------------------------------------

MovieData _parseZip(Uint8List bytes, bool keepAudio) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = <String, Uint8List>{};
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.split('/').last;
    if (name.isEmpty || name.startsWith('.')) continue;
    final Object content = f.content;
    files[name] = content is Uint8List ? content : Uint8List.fromList((content as List).cast<int>());
  }
  final binary = files.remove('movie.binary');
  if (binary != null) {
    return _parseMovieEntity(binary, keepAudio: keepAudio, looseFiles: files);
  }
  final spec = files.remove('movie.spec');
  if (spec == null) throw const SvgaException('ZIP has neither movie.binary nor movie.spec');
  final json = jsonDecode(utf8.decode(spec));
  return _parseJson(_map(json), files, keepAudio);
}

MovieData _parseJson(Map<String, dynamic> j, Map<String, Uint8List> files, bool keepAudio) {
  final ctx = _Ctx();
  final movie = _map(j['movie']);
  final vb = _map(movie['viewBox']);

  final images = <String, Uint8List>{};
  _map(j['images']).forEach((k, v) {
    final n = '$v';
    final b = files[n] ?? files['$n.png'] ?? files['$k.png'];
    if (b != null) images[k] = b;
  });

  final sprites = <SpriteData>[];
  for (final s in _list(j['sprites'])) {
    final sm = _map(s);
    final tb = _TrackBuilder();
    for (final f in _list(sm['frames'])) {
      final fm = _map(f);
      final l = _map(fm['layout']);
      final clipStr = fm['clipPath'];
      List<ShapeData>? shapes;
      var keep = false;
      for (final sh in _list(fm['shapes'])) {
        final shape = _jsonShape(_map(sh), ctx);
        if (identical(shape, _kKeep)) {
          keep = true;
        } else if (shape != null) {
          (shapes ??= <ShapeData>[]).add(shape);
        }
      }
      tb.add(
        alpha: _d(fm['alpha']),
        layout: [_d(l['x']), _d(l['y']), _d(l['width']), _d(l['height'])],
        transform: fm['transform'] is Map ? _jsonTransform(_map(fm['transform'])) : null,
        clip: clipStr is String && clipStr.isNotEmpty ? ctx.path(clipStr) : null,
        shapes: shapes,
        keep: keep && shapes == null,
      );
    }
    final matte = sm['matteKey'];
    sprites.add(SpriteData(
      imageKey: '${sm['imageKey'] ?? ''}',
      matteKey: matte is String && matte.isNotEmpty ? matte : null,
      track: tb.build(),
    ));
  }

  return _finish(
    version: '${j['ver'] ?? '1.x'}',
    w: _d(vb['width']),
    h: _d(vb['height']),
    fps: _d(movie['fps'], 20).round(),
    frames: _d(movie['frames']).round(),
    images: images,
    sprites: sprites,
    audios: const [],
    keepAudio: keepAudio,
    ctx: ctx,
  );
}

ShapeData? _jsonShape(Map<String, dynamic> m, _Ctx ctx) {
  final type = '${m['type'] ?? 'shape'}';
  if (type == 'keep') return _kKeep;
  final args = _map(m['args']);
  final style = _jsonStyle(_map(m['styles']));
  final transform =
      m['transform'] is Map ? Float32List.fromList(_jsonTransform(_map(m['transform']))) : null;
  switch (type) {
    case 'rect':
      return ShapeData(
        kind: ShapeKind.rect,
        args: Float32List.fromList([
          _d(args['x']), _d(args['y']), _d(args['width']), _d(args['height']),
          _d(args['cornerRadius']),
        ]),
        transform: transform,
        style: style,
      );
    case 'ellipse':
      return ShapeData(
        kind: ShapeKind.ellipse,
        args: Float32List.fromList(
            [_d(args['x']), _d(args['y']), _d(args['radiusX']), _d(args['radiusY'])]),
        transform: transform,
        style: style,
      );
    default:
      final d = args['d'];
      if (d is! String || d.isEmpty) return null;
      return ShapeData(kind: ShapeKind.path, path: ctx.path(d), transform: transform, style: style);
  }
}

ShapeStyle _jsonStyle(Map<String, dynamic> m) {
  int? col(Object? v) {
    if (v is! List || v.length < 4) return null;
    final c = _argb(_d(v[0]), _d(v[1]), _d(v[2]), _d(v[3]));
    return ((c >> 24) & 0xff) == 0 ? null : c;
  }

  final dash = m['lineDash'];
  return ShapeStyle(
    fill: col(m['fill']),
    stroke: col(m['stroke']),
    strokeWidth: _d(m['strokeWidth']),
    lineCap: switch ('${m['lineCap']}') { 'round' => 1, 'square' => 2, _ => 0 },
    lineJoin: switch ('${m['lineJoin']}') { 'round' => 1, 'bevel' => 2, _ => 0 },
    miterLimit: _d(m['miterLimit'], 4),
    dash: dash is List && dash.length >= 2 && _d(dash[0]) > 0
        ? Float32List.fromList([_d(dash[0]), _d(dash[1]), dash.length > 2 ? _d(dash[2]) : 0])
        : null,
  );
}

List<double> _jsonTransform(Map<String, dynamic> t) => [
      _d(t['a'], 1), _d(t['b']), _d(t['c']), _d(t['d'], 1), _d(t['tx']), _d(t['ty']),
    ];

Map<String, dynamic> _map(Object? o) =>
    o is Map ? o.cast<String, dynamic>() : const <String, dynamic>{};

List<Object?> _list(Object? o) => o is List ? o : const [];

double _d(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;
