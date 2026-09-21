import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../movie/svga_movie.dart';

/// Plug in any audio engine (audioplayers, just_audio, a native channel…).
/// The core package stays dependency-free.
abstract interface class SvgaAudioBackend {
  Future<SvgaAudioTrack> createTrack(String key, Uint8List bytes);
}

abstract interface class SvgaAudioTrack {
  Future<void> play(Duration position);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

abstract final class SvgaAudio {
  /// `null` = SVGA audio is ignored (and not even decoded into tracks).
  static SvgaAudioBackend? backend;
}

/// Frame-driven audio sync: a track starts when the playhead enters
/// `[startFrame, endFrame)` at `startTime + elapsed-in-range`, stops on exit,
/// and is re-synced on seeks and loop wrap-around.
class SvgaAudioScheduler {
  SvgaAudioScheduler(this._movie, this._backend);

  final SvgaMovie _movie;
  final SvgaAudioBackend _backend;
  final Map<int, SvgaAudioTrack> _tracks = {};
  final Set<int> _active = {};
  bool _disposed = false;
  double _volume = 1;
  bool _muted = false;

  double get _effective => _muted ? 0 : _volume;

  set volume(double v) {
    _volume = v.clamp(0.0, 1.0).toDouble();
    _applyVolume();
  }

  set muted(bool v) {
    _muted = v;
    _applyVolume();
  }

  Future<void> prepare() async {
    final audios = _movie.audios;
    for (var i = 0; i < audios.length; i++) {
      final bytes = _movie.audioBytes[audios[i].key];
      if (bytes == null) continue;
      try {
        final track = await _backend.createTrack(audios[i].key, bytes);
        if (_disposed) {
          await track.dispose();
          return;
        }
        await track.setVolume(_effective);
        _tracks[i] = track;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
              'svga_next: audio "${audios[i].key}" failed to prepare: $e');
        }
      }
    }
  }

  void onFrame(int previous, int frame, {bool jumped = false}) {
    if (_disposed) return;
    if (jumped || frame < previous) stopAll();
    final audios = _movie.audios;
    final fps = _movie.fps;
    for (final e in _tracks.entries) {
      final i = e.key;
      final a = audios[i];
      final end = a.endFrame > a.startFrame ? a.endFrame : _movie.frameCount;
      final inRange = frame >= a.startFrame && frame < end;
      if (inRange && !_active.contains(i)) {
        _active.add(i);
        final ms =
            a.startTimeMs + ((frame - a.startFrame) * 1000 / fps).round();
        _ignore(e.value.play(Duration(milliseconds: ms)));
      } else if (!inRange && _active.remove(i)) {
        _ignore(e.value.stop());
      }
    }
  }

  void pauseAll() {
    for (final i in _active) {
      _ignore(_tracks[i]?.pause());
    }
  }

  void resumeAll() {
    for (final i in _active) {
      _ignore(_tracks[i]?.resume());
    }
  }

  void stopAll() {
    for (final i in _active) {
      _ignore(_tracks[i]?.stop());
    }
    _active.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopAll();
    for (final t in _tracks.values) {
      _ignore(t.dispose());
    }
    _tracks.clear();
  }

  void _applyVolume() {
    for (final t in _tracks.values) {
      _ignore(t.setVolume(_effective));
    }
  }

  static void _ignore(Future<void>? f) {
    f?.catchError((Object e) {
      if (kDebugMode) {
        debugPrint('svga_next audio: $e');
      }
    });
  }
}
