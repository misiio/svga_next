import 'package:flutter/widgets.dart';

import '../dynamic/svga_dynamic_entity.dart';
import '../loader/svga_decode_options.dart';
import '../loader/svga_loader.dart';
import '../loader/svga_source.dart';
import '../movie/svga_movie.dart';
import 'svga_controller.dart';
import 'svga_painter.dart';

typedef SvgaErrorWidgetBuilder = Widget Function(BuildContext context, Object error);

class SvgaPlayer extends StatefulWidget {
  const SvgaPlayer({
    super.key,
    this.source,
    this.controller,
    this.dynamicEntity,
    this.autoPlay = true,
    this.loops = 0,
    this.fillMode = SvgaFillMode.forward,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.decodeOptions = const SvgaDecodeOptions(),
    this.waitForDynamicImages = const Duration(milliseconds: 1500),
    this.pauseInBackground = true,
    this.placeholder,
    this.errorBuilder,
    this.onLoaded,
    this.onFinished,
    this.onLayerTap,
  });

  /// If null, the player renders whatever [controller] already holds.
  final SvgaSource? source;
  final SvgaController? controller;
  final SvgaDynamicEntity? dynamicEntity;
  final bool autoPlay;

  /// 0 = infinite.
  final int loops;
  final SvgaFillMode fillMode;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final SvgaDecodeOptions decodeOptions;

  /// Before auto-play, wait up to this long for pending
  /// `setImageProvider` calls so the avatar is there on frame 1. null = don't wait.
  final Duration? waitForDynamicImages;

  /// Pause (incl. audio) while the app is backgrounded.
  final bool pauseInBackground;
  final Widget? placeholder;
  final SvgaErrorWidgetBuilder? errorBuilder;
  final ValueChanged<SvgaMovie>? onLoaded;

  /// Called only when a finite playback finishes naturally.
  final VoidCallback? onFinished;

  /// Tap on a layer, reported by imageKey (e.g. tap the avatar to open a profile).
  final ValueChanged<String>? onLayerTap;

  @override
  State<SvgaPlayer> createState() => _SvgaPlayerState();
}

class _SvgaPlayerState extends State<SvgaPlayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  SvgaController? _own;
  SvgaMovie? _shown;
  Object? _error;
  int _gen = 0;
  bool _pausedByLifecycle = false;

  SvgaController get _controller =>
      widget.controller ?? (_own ??= SvgaController(vsync: this));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller
      ..fillMode = widget.fillMode
      ..addListener(_onControllerChanged);
    _shown = _controller.movie;
    _load();
  }

  @override
  void didUpdateWidget(SvgaPlayer old) {
    super.didUpdateWidget(old);
    final oldController = old.controller ?? _own;
    if (!identical(oldController, _controller)) {
      oldController?.removeListener(_onControllerChanged);
      _controller.addListener(_onControllerChanged);
      _shown = _controller.movie;
    }
    _controller.fillMode = widget.fillMode;
    if (widget.source != old.source || widget.decodeOptions != old.decodeOptions) _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final source = widget.source;
    if (source == null) return;
    _error = null;
    SvgaMovie? movie;
    try {
      movie = await SvgaLoader.load(source, options: widget.decodeOptions);
      // Parsing and avatar downloads ran in parallel; give the avatars a
      // bounded grace period so frame 1 is complete.
      final wait = widget.waitForDynamicImages;
      final dyn = widget.dynamicEntity;
      if (widget.autoPlay && wait != null && dyn != null) await dyn.whenReady(timeout: wait);
      if (!mounted || gen != _gen) return;

      final c = _controller;
      final loaded = movie;
      c.movie = loaded; // controller retains its own reference…
      loaded.release(); // …so drop the loader's one right away
      movie = null;
      widget.onLoaded?.call(loaded);
      if (widget.autoPlay) {
        final finished = await c.play(loops: widget.loops);
        if (finished && mounted && gen == _gen) widget.onFinished?.call();
      }
    } catch (e, st) {
      if (!mounted || gen != _gen) return;
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'svga_next',
        context: ErrorDescription('while loading $source'),
      ));
      setState(() => _error = e);
    } finally {
      movie?.release(); // only non-null on early exit / error
    }
  }

  void _onControllerChanged() {
    final m = _controller.movie;
    if (!identical(m, _shown)) setState(() => _shown = m);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.pauseInBackground) return;
    if (state == AppLifecycleState.paused) {
      if (_controller.isPlaying) {
        _controller.pause();
        _pausedByLifecycle = true;
      }
    } else if (state == AppLifecycleState.resumed && _pausedByLifecycle) {
      _pausedByLifecycle = false;
      _controller.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    (widget.controller ?? _own)?.removeListener(_onControllerChanged);
    _gen++;
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final movie = _shown;
    if (movie == null || movie.isDisposed) {
      final error = _error;
      if (error != null && widget.errorBuilder != null) return widget.errorBuilder!(context, error);
      return widget.placeholder ?? const SizedBox.shrink();
    }

    Widget child = CustomPaint(
      size: movie.size,
      isComplex: true,
      willChange: true,
      painter: SvgaPainter(
        controller: _controller,
        dynamicEntity: widget.dynamicEntity,
        fit: widget.fit,
        alignment: widget.alignment,
        filterQuality: widget.filterQuality,
      ),
    );

    final onTap = widget.onLayerTap;
    if (onTap != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          final key = SvgaPainter.hitTestLayer(
            movie: movie,
            frame: _controller.frame,
            size: box.size,
            position: details.localPosition,
            fit: widget.fit,
            alignment: widget.alignment,
          );
          if (key != null) onTap(key);
        },
        child: child,
      );
    }

    // Isolates the animation's repaints from the rest of the tree.
    return RepaintBoundary(child: child);
  }
}
