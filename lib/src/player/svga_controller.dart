import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../audio/svga_audio.dart';
import '../movie/svga_movie.dart';

/// What to show after a finite playback ends.
enum SvgaFillMode { forward, backward, clear }

/// Drives playback from a [Ticker].
///
/// The frame index is derived from wall-clock elapsed time, so a janky frame
/// skips ahead instead of slowing the whole animation (and audio stays in
/// sync). Listeners are notified **only when the frame index changes** – a
/// 20 fps SVGA on a 120 Hz display repaints 20 times a second, not 120.
class SvgaController extends ChangeNotifier {
  SvgaController({required TickerProvider vsync, this.fillMode = SvgaFillMode.forward}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;
  SvgaFillMode fillMode;

  SvgaMovie? _movie;
  SvgaAudioScheduler? _audio;
  int _frame = 0;
  bool _cleared = false;
  bool _playing = false;
  bool _paused = false;
  int _start = 0, _end = 0, _loops = 0;
  Duration _offset = Duration.zero;
  Duration _lastElapsed = Duration.zero;
  double _speed = 1;
  double _volume = 1;
  bool _muted = false;
  Completer<bool>? _done;
  bool _disposed = false;

  SvgaMovie? get movie => _movie;
  int get frame => _frame;
  bool get isPlaying => _playing && !_paused;
  bool get isPaused => _playing && _paused;
  bool get isCleared => _cleared;

  /// Attach a movie. The controller retains its own reference; callers may
  /// release theirs right after.
  set movie(SvgaMovie? value) {
    if (identical(value, _movie)) return;
    _halt(completed: false);
    _audio?.dispose();
    _audio = null;
    _movie?.release();
    _movie = value?..retain();
    _frame = 0;
    _cleared = false;
    final backend = SvgaAudio.backend;
    if (value != null && backend != null && value.audios.isNotEmpty && value.audioBytes.isNotEmpty) {
      final scheduler = SvgaAudioScheduler(value, backend)
        ..volume = _volume
        ..muted = _muted;
      _audio = scheduler;
      unawaited(scheduler.prepare());
    }
    notifyListeners();
  }

  /// Plays `[from, to)`; [loops] 0 = forever. Completes `true` when the
  /// playback finished naturally, `false` if interrupted (stop / new play / movie swap).
  Future<bool> play({int? from, int? to, int loops = 0}) {
    final m = _movie;
    if (m == null || _disposed || m.frameCount <= 0) return Future.value(false);
    _halt(completed: false);
    final count = m.frameCount;
    _start = _clampInt(from ?? 0, 0, count - 1);
    _end = _clampInt(to ?? count, _start + 1, count);
    _loops = math.max(0, loops);
    _cleared = false;
    _playing = true;
    _paused = false;
    final done = _done = Completer<bool>();
    _setFrame(_start, jumped: true, force: true);
    _ticker.start();
    return done.future;
  }

  void pause() {
    if (!_playing || _paused) return;
    _offset += _lastElapsed;
    _lastElapsed = Duration.zero;
    _ticker.stop();
    _paused = true;
    _audio?.pauseAll();
    notifyListeners();
  }

  void resume() {
    if (!_playing || !_paused) return;
    _paused = false;
    _ticker.start();
    _audio?.resumeAll();
    notifyListeners();
  }

  void stop({bool clear = false}) {
    _halt(completed: false);
    if (clear) _cleared = true;
    notifyListeners();
  }

  void seekTo(int frame) {
    final m = _movie;
    if (m == null) return;
    _cleared = false;
    if (!_playing) {
      _setFrame(_clampInt(frame, 0, m.frameCount - 1), force: true);
      return;
    }
    final f = _clampInt(frame, _start, _end - 1);
    final len = _end - _start;
    final loopsDone = _progressedFrames(m).floor() ~/ len;
    final wasTicking = _ticker.isActive;
    if (wasTicking) _ticker.stop();
    _offset = _framesToDuration(loopsDone * len + (f - _start), m, _speed);
    _lastElapsed = Duration.zero;
    _setFrame(f, jumped: true, force: true);
    if (wasTicking) _ticker.start();
  }

  double get speed => _speed;
  set speed(double value) {
    assert(value > 0);
    final m = _movie;
    if (m == null || !_playing) {
      _speed = value;
      return;
    }
    final frames = _progressedFrames(m);
    final wasTicking = _ticker.isActive;
    if (wasTicking) _ticker.stop();
    _speed = value;
    _offset = _framesToDuration(frames, m, value);
    _lastElapsed = Duration.zero;
    if (wasTicking) _ticker.start();
  }

  double get volume => _volume;
  set volume(double v) {
    _volume = v.clamp(0.0, 1.0).toDouble();
    _audio?.volume = _volume;
  }

  bool get muted => _muted;
  set muted(bool v) {
    _muted = v;
    _audio?.muted = v;
  }

  // ---------------------------------------------------------------------------

  void _onTick(Duration elapsed) {
    final m = _movie;
    if (m == null) return;
    _lastElapsed = elapsed;
    final progressed = _progressedFrames(m).floor();
    final len = _end - _start;
    if (_loops > 0 && progressed >= len * _loops) {
      _finish();
      return;
    }
    _setFrame(_start + progressed % len);
  }

  double _progressedFrames(SvgaMovie m) =>
      (_offset + _lastElapsed).inMicroseconds * m.fps * _speed / Duration.microsecondsPerSecond;

  static Duration _framesToDuration(num frames, SvgaMovie m, double speed) => Duration(
      microseconds: (frames * Duration.microsecondsPerSecond / (m.fps * speed)).round());

  void _finish() {
    _ticker.stop();
    _playing = false;
    _paused = false;
    _audio?.stopAll();
    switch (fillMode) {
      case SvgaFillMode.forward:
        _setFrame(_end - 1, force: true);
      case SvgaFillMode.backward:
        _setFrame(_start, force: true);
      case SvgaFillMode.clear:
        _cleared = true;
        notifyListeners();
    }
    _complete(true);
  }

  void _setFrame(int f, {bool jumped = false, bool force = false}) {
    if (f == _frame && !force) return;
    final prev = _frame;
    _frame = f;
    if (_playing && !_paused) _audio?.onFrame(prev, f, jumped: jumped);
    notifyListeners();
  }

  void _halt({required bool completed}) {
    if (_ticker.isActive) _ticker.stop();
    final wasPlaying = _playing;
    _playing = false;
    _paused = false;
    _offset = Duration.zero;
    _lastElapsed = Duration.zero;
    if (wasPlaying) _audio?.stopAll();
    _complete(completed);
  }

  void _complete(bool value) {
    final d = _done;
    _done = null;
    if (d != null && !d.isCompleted) d.complete(value);
  }

  static int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  @override
  void dispose() {
    _disposed = true;
    _halt(completed: false);
    _ticker.dispose();
    _audio?.dispose();
    _audio = null;
    _movie?.release();
    _movie = null;
    super.dispose();
  }
}
