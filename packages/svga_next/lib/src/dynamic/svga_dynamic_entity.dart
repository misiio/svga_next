import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Custom per-layer painting. [bounds] is the sprite's layout rect in the
/// sprite's local (already transformed & clipped) space; [alpha] is the
/// layer's current opacity.
typedef SvgaLayerDrawer = void Function(
    Canvas canvas, Rect bounds, int frame, double alpha);

final class SvgaDynamicImage {
  SvgaDynamicImage._(this.image, this.fit, this.circle, this.cornerRadius);

  final ui.Image image;
  final BoxFit fit;
  final bool circle;
  final double cornerRadius;
}

final class SvgaDynamicText {
  SvgaDynamicText._(this.span, this.textAlign, this.maxLines, this.scaleDown,
      this.textDirection);

  final InlineSpan span;
  final TextAlign textAlign;
  final int maxLines;

  /// Shrink to fit the layer width instead of wrapping/ellipsizing – the usual
  /// behaviour for nicknames on gift banners.
  final bool scaleDown;
  final TextDirection textDirection;

  TextPainter? _painter;
  double _laidOutWidth = double.nan;

  /// Laid out once per width and reused every frame (flutter_svga re-laid out
  /// text on every paint).
  TextPainter layoutFor(double width) {
    final p = _painter ??= TextPainter(
      text: span,
      textAlign: textAlign,
      textDirection: textDirection,
      maxLines: scaleDown ? 1 : maxLines,
      ellipsis: scaleDown ? null : '\u2026',
    );
    if (_laidOutWidth != width) {
      p.layout(maxWidth: scaleDown ? double.infinity : width);
      _laidOutWidth = width;
    }
    return p;
  }

  void _dispose() {
    _painter?.dispose();
    _painter = null;
  }
}

/// Runtime replacements for layers, addressed by the sprite's imageKey.
///
/// Every setter takes the layer key first and everything else as named
/// arguments, so key/value can never be swapped by accident.
class SvgaDynamicEntity extends ChangeNotifier {
  final Map<String, SvgaDynamicImage> _images = {};
  final Map<String, SvgaDynamicText> _texts = {};
  final Map<String, SvgaLayerDrawer> _drawers = {};
  final Set<String> _hidden = {};
  final Map<String, int> _generation = {};
  final Set<Future<bool>> _pending = {};
  final Map<String, _AnimatedImage> _animated = {};
  final Set<Object> _players = {};
  bool _disposed = false;

  // ---- images -------------------------------------------------------------

  /// Uses an already decoded image. The entity takes a clone, so the caller
  /// keeps ownership of [image].
  void setImage(
    String key, {
    required ui.Image image,
    BoxFit fit = BoxFit.cover,
    bool circle = false,
    double cornerRadius = 0,
  }) {
    _bump(key);
    _putImage(
        key, SvgaDynamicImage._(image.clone(), fit, circle, cornerRadius));
  }

  /// Resolves any `ImageProvider` (NetworkImage, CachedNetworkImageProvider,
  /// ResizeImage…) and injects it. Completes with `false` on failure. Late
  /// results for a key that has since been changed are discarded.
  ///
  /// With [animate], an animated GIF or WebP keeps playing: every frame
  /// Flutter's image stream delivers replaces the previous one, with [fit],
  /// [circle] and [cornerRadius] applied. Frames only advance while an
  /// `SvgaPlayer` using this entity is mounted; otherwise the image holds its
  /// current frame. The returned future still completes on the first frame.
  ///
  /// Timing and looping are Flutter's, as in the `Image` widget: frame delays
  /// are not clamped, so frames with a zero delay advance every vsync. After
  /// a pause the image continues from wherever Flutter's stream is, and
  /// restarts from its first frame if `ImageCache` has evicted it. An error
  /// after the first frame keeps the last good frame.
  ///
  /// Tip: wrap avatars in `ResizeImage(provider, width: 128)` – decoding a
  /// 1080px avatar for a 60pt circle wastes texture memory.
  Future<bool> setImageProvider(
    String key, {
    required ImageProvider provider,
    BoxFit fit = BoxFit.cover,
    bool circle = false,
    double cornerRadius = 0,
    ImageConfiguration configuration = ImageConfiguration.empty,
    bool animate = false,
  }) {
    final gen = _bump(key);
    if (animate) {
      final animated = _animated[key] = _AnimatedImage(
          this, key, provider, configuration, fit, circle, cornerRadius);
      animated.attach();
      return _track(animated.ready.future);
    }
    final completer = Completer<bool>();
    final stream = provider.resolve(configuration);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!_disposed && _generation[key] == gen) {
          _putImage(
              key,
              SvgaDynamicImage._(
                  info.image.clone(), fit, circle, cornerRadius));
        }
        info.dispose();
        if (!completer.isCompleted) completer.complete(true);
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        if (kDebugMode) {
          debugPrint('svga_next: dynamic image "$key" failed: $error');
        }
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    stream.addListener(listener);
    return _track(completer.future);
  }

  Future<bool> _track(Future<bool> future) {
    _pending.add(future);
    future.whenComplete(() => _pending.remove(future));
    return future;
  }

  // ---- text ---------------------------------------------------------------

  void setText(
    String key, {
    required String text,
    TextStyle? style,
    TextAlign textAlign = TextAlign.center,
    int maxLines = 1,
    bool scaleDown = true,
    TextDirection textDirection = TextDirection.ltr,
  }) =>
      setTextSpan(
        key,
        span: TextSpan(text: text, style: style),
        textAlign: textAlign,
        maxLines: maxLines,
        scaleDown: scaleDown,
        textDirection: textDirection,
      );

  /// Rich text (e.g. nickname + coloured gift count, or emoji via WidgetSpan-free spans).
  void setTextSpan(
    String key, {
    required InlineSpan span,
    TextAlign textAlign = TextAlign.center,
    int maxLines = 1,
    bool scaleDown = true,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    _texts.remove(key)?._dispose();
    _texts[key] =
        SvgaDynamicText._(span, textAlign, maxLines, scaleDown, textDirection);
    notifyListeners();
  }

  // ---- drawers / visibility -----------------------------------------------

  void setDrawer(String key, {required SvgaLayerDrawer drawer}) {
    _drawers[key] = drawer;
    notifyListeners();
  }

  void setHidden(String key, {bool hidden = true}) {
    final changed = hidden ? _hidden.add(key) : _hidden.remove(key);
    if (changed) notifyListeners();
  }

  // ---- housekeeping ---------------------------------------------------------

  /// Completes when all pending `setImageProvider` calls settle, or after
  /// [timeout] – so a slow avatar never blocks a gift from starting.
  Future<void> whenReady(
      {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_pending.isEmpty) return;
    await Future.wait(_pending.toList())
        .timeout(timeout, onTimeout: () => const <bool>[]);
  }

  void remove(String key) {
    _bump(key);
    _images.remove(key)?.image.dispose();
    _texts.remove(key)?._dispose();
    _drawers.remove(key);
    _hidden.remove(key);
    notifyListeners();
  }

  void clear() {
    for (final k in _generation.keys.toList()) {
      _bump(k);
    }
    for (final i in _images.values) {
      i.image.dispose();
    }
    for (final t in _texts.values) {
      t._dispose();
    }
    _images.clear();
    _texts.clear();
    _drawers.clear();
    _hidden.clear();
    notifyListeners();
  }

  SvgaDynamicImage? imageFor(String key) => _images[key];
  SvgaDynamicText? textFor(String key) => _texts[key];
  SvgaLayerDrawer? drawerFor(String key) => _drawers[key];
  bool isHidden(String key) => _hidden.contains(key);

  /// Invalidates late results for [key] and stops its animation, so an older
  /// image can never overwrite a newer one.
  int _bump(String key) {
    _animated.remove(key)?.cancel();
    return _generation[key] = (_generation[key] ?? 0) + 1;
  }

  void _putImage(String key, SvgaDynamicImage img, {bool notify = true}) {
    _images.remove(key)?.image.dispose();
    _images[key] = img;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final a in _animated.values) {
      a.cancel();
    }
    _animated.clear();
    _players.clear();
    for (final i in _images.values) {
      i.image.dispose();
    }
    for (final t in _texts.values) {
      t._dispose();
    }
    _images.clear();
    _texts.clear();
    super.dispose();
  }
}

/// Lets `SvgaPlayer` mark the entity as on screen. Not exported: only a
/// mounted player keeps animated images playing, a plain `addListener` doesn't.
extension SvgaDynamicEntityPlayers on SvgaDynamicEntity {
  void registerPlayer(Object player) {
    if (_disposed || !_players.add(player) || _players.length > 1) return;
    for (final a in _animated.values.toList()) {
      a.attach();
    }
  }

  void unregisterPlayer(Object player) {
    if (_disposed || !_players.remove(player) || _players.isNotEmpty) return;
    for (final a in _animated.values) {
      if (a.hasFrame) a.detach();
    }
  }
}

/// The live stream behind a `setImageProvider(..., animate: true)` key.
///
/// It listens while a player is registered, or until the first frame. Each
/// attach resolves the provider again, so a stream Flutter disposed while
/// nothing listened is replaced; `ImageCache` hands back the same stream when
/// it still has it.
final class _AnimatedImage {
  _AnimatedImage(
    this._entity,
    this._key,
    this._provider,
    this._configuration,
    this._fit,
    this._circle,
    this._cornerRadius,
  ) {
    _listener = ImageStreamListener(_onImage, onError: _onError);
  }

  final SvgaDynamicEntity _entity;
  final String _key;
  final ImageProvider _provider;
  final ImageConfiguration _configuration;
  final BoxFit _fit;
  final bool _circle;
  final double _cornerRadius;
  final Completer<bool> ready = Completer<bool>();
  late final ImageStreamListener _listener;
  ImageStream? _stream;
  bool _attaching = false;

  bool get hasFrame => ready.isCompleted;

  void attach() {
    if (_stream != null) return;
    final stream = _stream = _provider.resolve(_configuration);
    _attaching = true;
    try {
      stream.addListener(_listener);
    } finally {
      _attaching = false;
    }
  }

  void detach() {
    _stream?.removeListener(_listener);
    _stream = null;
  }

  /// Stops for good, e.g. because the key got a newer image.
  void cancel() {
    detach();
    if (!ready.isCompleted) ready.complete(false);
  }

  bool get _current => identical(_entity._animated[_key], this);

  void _onImage(ImageInfo info, bool synchronousCall) {
    try {
      if (!_current) return;
      final shown = _entity._images[_key]?.image;
      if (shown == null || !info.image.isCloneOf(shown)) {
        // Re-attaching hands back the stream's current frame synchronously,
        // possibly while a player builds; it gets painted without a notify.
        _entity._putImage(
          _key,
          SvgaDynamicImage._(info.image.clone(), _fit, _circle, _cornerRadius),
          notify: !(_attaching && hasFrame),
        );
      }
    } finally {
      info.dispose();
    }
    if (!ready.isCompleted) {
      ready.complete(true);
      if (_entity._players.isEmpty) detach();
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (kDebugMode) {
      debugPrint('svga_next: dynamic image "$_key" failed: $error');
    }
    if (_current) _entity._animated.remove(_key);
    cancel();
  }
}
