import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Listenable;
import 'package:flutter/rendering.dart';

import '../dynamic/svga_dynamic_entity.dart';
import '../model/movie_data.dart';
import '../movie/svga_movie.dart';
import 'svga_controller.dart';

/// Allocation-free (per frame) renderer. Paint objects and the transform
/// matrix are reused; paths are pre-built and cached on the movie; text is
/// laid out once; invisible sprites are culled in O(1).
class SvgaPainter extends CustomPainter {
  SvgaPainter({
    required this.controller,
    this.dynamicEntity,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
  }) : super(
            repaint: dynamicEntity == null
                ? controller
                : Listenable.merge([controller, dynamicEntity]));

  final SvgaController controller;
  final SvgaDynamicEntity? dynamicEntity;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;

  static final Float64List _matrix = Float64List(16)
    ..[10] = 1.0
    ..[15] = 1.0;
  static final Paint _imagePaint = Paint()..isAntiAlias = true;
  static final Paint _shapePaint = Paint()..isAntiAlias = true;
  static final Paint _layerPaint = Paint();
  static final Paint _dstInPaint = Paint()..blendMode = BlendMode.dstIn;
  static const _caps = [StrokeCap.butt, StrokeCap.round, StrokeCap.square];
  static const _joins = [StrokeJoin.miter, StrokeJoin.round, StrokeJoin.bevel];

  @override
  void paint(Canvas canvas, Size size) {
    final movie = controller.movie;
    if (movie == null || movie.isDisposed || controller.isCleared) return;
    final map = _ViewMapping.compute(movie, size, fit, alignment);
    if (map == null) return;

    _imagePaint.filterQuality = filterQuality;
    final frame = controller.frame;
    final bounds = Offset.zero & movie.size;

    canvas.save();
    canvas.clipRect(map.clip);
    canvas.translate(map.tx, map.ty);
    canvas.scale(map.sx, map.sy);

    for (final sprite in movie.sprites) {
      if (sprite.isMatte || !sprite.track.visibleAt(frame)) continue;
      if (dynamicEntity?.isHidden(sprite.imageKey) ?? false) continue;

      final matteKey = sprite.matteKey;
      final matte = matteKey == null ? null : movie.spriteForKey(matteKey);
      if (matte == null) {
        _drawSprite(canvas, movie, sprite, frame);
      } else {
        // Content layer, then keep only where the matte sprite has alpha.
        canvas.saveLayer(bounds, _layerPaint);
        _drawSprite(canvas, movie, sprite, frame);
        canvas.saveLayer(bounds, _dstInPaint);
        if (matte.track.visibleAt(frame)) {
          _drawSprite(canvas, movie, matte, frame);
        }
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _drawSprite(
      Canvas canvas, SvgaMovie movie, SpriteData sprite, int frame) {
    final t = sprite.track;
    final v = t.values;
    final o = frame * FrameTrack.stride;
    final alpha = v[o].clamp(0.0, 1.0).toDouble();
    final a8 = (alpha * 255).round();
    final layout = Rect.fromLTWH(v[o + 1], v[o + 2], v[o + 3], v[o + 4]);

    _matrix[0] = v[o + 5];
    _matrix[1] = v[o + 6];
    _matrix[4] = v[o + 7];
    _matrix[5] = v[o + 8];
    _matrix[12] = v[o + 9];
    _matrix[13] = v[o + 10];

    canvas.save();
    canvas.transform(_matrix);

    final clip = t.clips?[frame];
    if (clip != null) canvas.clipPath(movie.pathOf(clip));

    final key = sprite.imageKey;
    final dyn = dynamicEntity;
    final dynImage = dyn?.imageFor(key);
    if (dynImage != null) {
      _drawDynamicImage(canvas, dynImage, layout, a8);
    } else {
      // A matte sprite's bitmap is stored under either its own key (1.x ZIP,
      // some 2.x exporters) or the key without `.matte` (other 2.x exporters).
      // The exact key wins, so a separate `x.matte` bitmap is never replaced
      // by the content bitmap `x`.
      final img = movie.imageFor(key) ??
          (sprite.isMatte
              ? movie.imageFor(key.substring(0, key.length - 6))
              : null);
      if (img != null) {
        _imagePaint.color = Color.fromARGB(a8, 0, 0, 0);
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          layout,
          _imagePaint,
        );
      }
    }

    final shapes = t.shapes?[frame];
    if (shapes != null && shapes.isNotEmpty) {
      _drawShapes(canvas, movie, shapes, alpha);
    }

    final text = dyn?.textFor(key);
    if (text != null) _drawText(canvas, text, layout, alpha);

    final drawer = dyn?.drawerFor(key);
    if (drawer != null) drawer(canvas, layout, frame, alpha);

    canvas.restore();
  }

  void _drawDynamicImage(
      Canvas canvas, SvgaDynamicImage di, Rect layout, int a8) {
    final img = di.image;
    final imgSize = Size(img.width.toDouble(), img.height.toDouble());
    final fs = applyBoxFit(di.fit, imgSize, layout.size);
    final src = Alignment.center.inscribe(fs.source, Offset.zero & imgSize);
    final dst = Alignment.center.inscribe(fs.destination, layout);
    final clipped = di.circle || di.cornerRadius > 0;
    if (clipped) {
      canvas.save();
      if (di.circle) {
        final r = layout.shortestSide / 2;
        canvas.clipRRect(RRect.fromRectAndRadius(
            Rect.fromCircle(center: layout.center, radius: r),
            Radius.circular(r)));
      } else {
        canvas.clipRRect(
            RRect.fromRectAndRadius(layout, Radius.circular(di.cornerRadius)));
      }
    }
    _imagePaint.color = Color.fromARGB(a8, 0, 0, 0);
    canvas.drawImageRect(img, src, dst, _imagePaint);
    if (clipped) canvas.restore();
  }

  void _drawShapes(
      Canvas canvas, SvgaMovie movie, List<ShapeData> shapes, double alpha) {
    for (final s in shapes) {
      final st = s.style;
      final hasStroke = st.stroke != null && st.strokeWidth > 0;
      if (st.fill == null && !hasStroke) continue;

      final tr = s.transform;
      if (tr != null) {
        canvas.save();
        _matrix[0] = tr[0];
        _matrix[1] = tr[1];
        _matrix[4] = tr[2];
        _matrix[5] = tr[3];
        _matrix[12] = tr[4];
        _matrix[13] = tr[5];
        canvas.transform(_matrix);
      }

      ui.Path? path;
      Rect? rect;
      var radius = 0.0; // < 0 means ellipse
      switch (s.kind) {
        case ShapeKind.path:
          path = movie.pathOf(s.path!);
        case ShapeKind.rect:
          final a = s.args!;
          rect = Rect.fromLTWH(a[0], a[1], a[2], a[3]);
          radius = a[4];
        case ShapeKind.ellipse:
          final a = s.args!;
          rect = Rect.fromCenter(
              center: Offset(a[0], a[1]), width: a[2] * 2, height: a[3] * 2);
          radius = -1;
      }

      final fill = st.fill;
      if (fill != null) {
        _shapePaint
          ..style = PaintingStyle.fill
          ..color = _withAlpha(fill, alpha);
        _drawGeometry(canvas, path, rect, radius);
      }
      if (hasStroke) {
        _shapePaint
          ..style = PaintingStyle.stroke
          ..strokeWidth = st.strokeWidth
          ..strokeCap = _caps[st.lineCap.clamp(0, 2).toInt()]
          ..strokeJoin = _joins[st.lineJoin.clamp(0, 2).toInt()]
          ..strokeMiterLimit = st.miterLimit
          ..color = _withAlpha(st.stroke!, alpha);
        final strokePath = (path != null && st.dash != null)
            ? movie.dashedPathOf(s, path)
            : path;
        _drawGeometry(canvas, strokePath, rect, radius);
      }

      if (tr != null) canvas.restore();
    }
  }

  static void _drawGeometry(
      Canvas canvas, ui.Path? path, Rect? rect, double radius) {
    if (path != null) {
      canvas.drawPath(path, _shapePaint);
    } else if (rect != null) {
      if (radius < 0) {
        canvas.drawOval(rect, _shapePaint);
      } else if (radius > 0) {
        canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)),
            _shapePaint);
      } else {
        canvas.drawRect(rect, _shapePaint);
      }
    }
  }

  static Color _withAlpha(int argb, double alpha) => Color(
      ((((argb >> 24) & 0xff) * alpha).round() << 24) | (argb & 0xffffff));

  void _drawText(
      Canvas canvas, SvgaDynamicText text, Rect layout, double alpha) {
    if (layout.width <= 0 || alpha <= 0) return;
    final tp = text.layoutFor(layout.width);
    var scale = 1.0;
    if (text.scaleDown && tp.width > layout.width) {
      scale = layout.width / tp.width;
    }
    final w = tp.width * scale, h = tp.height * scale;
    final dx = switch (text.textAlign) {
      TextAlign.left => 0.0,
      TextAlign.right => layout.width - w,
      TextAlign.start =>
        text.textDirection == TextDirection.ltr ? 0.0 : layout.width - w,
      TextAlign.end =>
        text.textDirection == TextDirection.ltr ? layout.width - w : 0.0,
      _ => (layout.width - w) / 2,
    };
    final dy = (layout.height - h) / 2;
    final needsLayer = alpha < 0.999;
    if (needsLayer) {
      canvas.saveLayer(layout,
          Paint()..color = Color.fromARGB((alpha * 255).round(), 0, 0, 0));
    }
    canvas.save();
    canvas.translate(layout.left + dx, layout.top + dy);
    if (scale != 1.0) canvas.scale(scale);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
    if (needsLayer) canvas.restore();
  }

  /// Top-most visible layer key under [position] (widget-local coordinates).
  static String? hitTestLayer({
    required SvgaMovie movie,
    required int frame,
    required Size size,
    required Offset position,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    final map = _ViewMapping.compute(movie, size, fit, alignment);
    if (map == null || !map.clip.contains(position)) return null;
    final vx = (position.dx - map.tx) / map.sx;
    final vy = (position.dy - map.ty) / map.sy;
    final sprites = movie.sprites;
    for (var i = sprites.length - 1; i >= 0; i--) {
      final s = sprites[i];
      if (s.isMatte || !s.track.visibleAt(frame)) continue;
      final v = s.track.values;
      final o = frame * FrameTrack.stride;
      final a = v[o + 5], b = v[o + 6], c = v[o + 7], d = v[o + 8];
      final det = a * d - b * c;
      if (det.abs() < 1e-9) continue;
      final px = vx - v[o + 9], py = vy - v[o + 10];
      final lx = (d * px - c * py) / det;
      final ly = (-b * px + a * py) / det;
      if (lx >= v[o + 1] &&
          lx <= v[o + 1] + v[o + 3] &&
          ly >= v[o + 2] &&
          ly <= v[o + 2] + v[o + 4]) {
        return s.imageKey;
      }
    }
    return null;
  }

  @override
  bool shouldRepaint(SvgaPainter old) =>
      !identical(old.controller, controller) ||
      !identical(old.dynamicEntity, dynamicEntity) ||
      old.fit != fit ||
      old.alignment != alignment ||
      old.filterQuality != filterQuality;
}

final class _ViewMapping {
  const _ViewMapping(this.clip, this.sx, this.sy, this.tx, this.ty);

  final Rect clip;
  final double sx, sy, tx, ty;

  static _ViewMapping? compute(
      SvgaMovie movie, Size size, BoxFit fit, Alignment alignment) {
    final vb = movie.size;
    if (vb.isEmpty || size.isEmpty) return null;
    final fs = applyBoxFit(fit, vb, size);
    if (fs.source.isEmpty || fs.destination.isEmpty) return null;
    final dst = alignment.inscribe(fs.destination, Offset.zero & size);
    final src = alignment.inscribe(fs.source, Offset.zero & vb);
    final sx = dst.width / src.width, sy = dst.height / src.height;
    return _ViewMapping(
        dst, sx, sy, dst.left - src.left * sx, dst.top - src.top * sy);
  }
}
