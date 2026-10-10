import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../image_cap.dart';

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

  /// Laid out once per width and reused every frame.
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
  /// ResizeImage…) and injects it. Completes with `false` on failure, or when
  /// a newer call for [key] replaces this one first.
  ///
  /// With [animate], an animated GIF or WebP keeps playing, each frame with
  /// [fit], [circle] and [cornerRadius] applied, and the future completes on
  /// the first frame. Frames only advance while an `SvgaPlayer` is showing
  /// this entity (mounted, tickers enabled, animations not disabled);
  /// otherwise the image holds its current frame. Timing and looping follow
  /// Flutter's `Image` widget. An error after the first frame keeps the last
  /// good frame.
  ///
  /// With [maxImageDimension] (in pixels), frames whose longest side is
  /// larger are downscaled to it, keeping their aspect ratio. It is the only
  /// bound on animated frames: the engine ignores target sizes for
  /// multi-frame images (flutter/flutter#137668).
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
    int? maxImageDimension,
  }) {
    final gen = _bump(key);
    if (animate) {
      final animated = _animated[key] = _AnimatedImage(this, key, provider,
          configuration, fit, circle, cornerRadius, maxImageDimension);
      animated.attach();
      return _track(animated.ready.future);
    }
    final completer = Completer<bool>();
    final stream = provider.resolve(configuration);
    late final ImageStreamListener listener;
    void onError(Object error, StackTrace? stack) {
      if (kDebugMode) {
        debugPrint('svga_next: dynamic image "$key" failed: $error');
      }
      if (!completer.isCompleted) completer.complete(false);
    }

    void store(ui.Image image) {
      if (!_disposed && _generation[key] == gen) {
        _putImage(key, SvgaDynamicImage._(image, fit, circle, cornerRadius));
      } else {
        image.dispose();
      }
      if (!completer.isCompleted) completer.complete(true);
    }

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        final FutureOr<ui.Image> image;
        try {
          image = cappedClone(info.image, maxImageDimension);
        } finally {
          info.dispose();
        }
        if (image is ui.Image) {
          store(image);
        } else {
          image.then(store, onError: onError);
        }
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        onError(error, stack);
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

  /// Rich text, e.g. a nickname followed by a coloured gift count.
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
/// player showing the entity keeps animated images playing, a plain
/// `addListener` doesn't.
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
    this._maxDimension,
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
  final int? _maxDimension;
  final Completer<bool> ready = Completer<bool>();
  late final ImageStreamListener _listener;
  ImageStream? _stream;
  bool _attaching = false;
  bool hasFrame = false;

  /// Frames received, and the number of the frame shown, so a downscale that
  /// finishes late never replaces a newer frame.
  int _received = 0;
  int _shown = 0;

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

  bool get _isCurrent => identical(_entity._animated[_key], this);

  void _onImage(ImageInfo info, bool synchronousCall) {
    final FutureOr<ui.Image> image;
    try {
      if (!_isCurrent) return;
      if (!hasFrame) {
        hasFrame = true;
        if (_entity._players.isEmpty) detach();
      }
      final shown = _entity._images[_key]?.image;
      // Already shown, and within this call's cap. A downscaled frame never
      // matches, so re-attaching downscales the current frame again.
      if (shown != null &&
          info.image.isCloneOf(shown) &&
          cappedSize(shown.width, shown.height, _maxDimension) == null) {
        if (!ready.isCompleted) ready.complete(true);
        return;
      }
      image = cappedClone(info.image, _maxDimension);
    } finally {
      info.dispose();
    }
    final frame = ++_received;
    if (image is ui.Image) {
      _show(frame, image);
    } else {
      image.then((image) => _show(frame, image), onError: (Object e, s) {
        // A frame already replaced by a newer one can't stop the animation.
        if (frame > _shown) _onError(e, s);
      });
    }
  }

  void _show(int frame, ui.Image image) {
    if (!_isCurrent || frame < _shown) {
      image.dispose();
      return;
    }
    _shown = frame;
    final first = !ready.isCompleted;
    // Before the notify below, whose listeners may already replace the key.
    if (first) ready.complete(true);
    // Re-attaching hands back the stream's current frame synchronously,
    // possibly while a player builds; a frame stored right then gets painted
    // without a notify.
    _entity._putImage(
      _key,
      SvgaDynamicImage._(image, _fit, _circle, _cornerRadius),
      notify: first || !_attaching,
    );
  }

  void _onError(Object error, StackTrace? stack) {
    if (kDebugMode) {
      debugPrint('svga_next: dynamic image "$_key" failed: $error');
    }
    if (_isCurrent) _entity._animated.remove(_key);
    cancel();
  }
}
