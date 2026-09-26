import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:svga_next/svga_next.dart';

/// An [SvgaAudioBackend] powered by audioplayers.
final class SvgaAudioplayersBackend implements SvgaAudioBackend {
  const SvgaAudioplayersBackend();

  @override
  Future<SvgaAudioTrack> createTrack(String key, Uint8List bytes) async {
    final directory = await Directory.systemTemp.createTemp('svga_next_audio_');
    final file = File('${directory.path}/audio${_extension(key)}');
    AudioPlayer? player;
    try {
      await file.writeAsBytes(bytes, flush: true);
      player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSource(DeviceFileSource(file.path));
      return _AudioplayersTrack(player, directory);
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

class _AudioplayersTrack implements SvgaAudioTrack {
  _AudioplayersTrack(this._player, this._directory);

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

  @override
  Future<void> play(Duration position) {
    if (_disposed) return Future<void>.value();
    final generation = ++_generation;
    return _enqueue(() async {
      if (generation != _generation) return;
      await _player.seek(position);
      if (generation == _generation) await _player.resume();
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
    return _enqueue(() {
      if (generation != _generation) return Future<void>.value();
      return _player.resume();
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
