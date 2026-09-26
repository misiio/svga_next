import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:just_audio/just_audio.dart';
import 'package:svga_next/svga_next.dart';

/// An [SvgaAudioBackend] powered by just_audio.
final class SvgaJustAudioBackend implements SvgaAudioBackend {
  const SvgaJustAudioBackend();

  @override
  Future<SvgaAudioTrack> createTrack(String key, Uint8List bytes) async {
    final directory = await Directory.systemTemp.createTemp('svga_next_audio_');
    final file = File('${directory.path}/audio${_extension(key)}');
    AudioPlayer? player;
    try {
      await file.writeAsBytes(bytes, flush: true);
      player = AudioPlayer();
      await player.setFilePath(file.path);
      return _JustAudioTrack(player, directory);
    } catch (_) {
      try {
        await player?.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }
}

class _JustAudioTrack implements SvgaAudioTrack {
  _JustAudioTrack(this._player, this._directory);

  final AudioPlayer _player;
  final Directory _directory;
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposeFuture;
  int _generation = 0;
  bool _disposed = false;

  Future<void> _enqueue(Future<void> Function() command) {
    final result = _tail.then((_) => command());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _startPlayback() {
    // just_audio's play future completes when playback ends or is interrupted.
    unawaited(_player.play().then<void>((_) {}, onError: (Object error) {
      if (kDebugMode) debugPrint('svga_next_just_audio: $error');
    }));
  }

  @override
  Future<void> play(Duration position) {
    if (_disposed) return Future<void>.value();
    final generation = ++_generation;
    return _enqueue(() async {
      if (generation != _generation) return;
      await _player.seek(position);
      if (generation == _generation) _startPlayback();
    });
  }

  @override
  Future<void> pause() {
    if (_disposed) return Future<void>.value();
    ++_generation;
    return _enqueue(_player.pause);
  }

  @override
  Future<void> resume() {
    if (_disposed) return Future<void>.value();
    final generation = ++_generation;
    return _enqueue(() async {
      if (generation == _generation) _startPlayback();
    });
  }

  @override
  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    ++_generation;
    return _enqueue(_player.stop);
  }

  @override
  Future<void> setVolume(double volume) {
    if (_disposed) return Future<void>.value();
    return _enqueue(() => _player.setVolume(volume));
  }

  @override
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    ++_generation;
    return _disposeFuture = _enqueue(() async {
      try {
        await _player.dispose();
      } finally {
        await _directory.delete(recursive: true);
      }
    });
  }
}

String _extension(String key) {
  final dot = key.lastIndexOf('.');
  if (dot < 0) return '.mp3';
  final extension = key.substring(dot).toLowerCase();
  const supported = {'.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac'};
  return supported.contains(extension) ? extension : '.mp3';
}
