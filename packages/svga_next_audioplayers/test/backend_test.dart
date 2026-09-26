import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next_audioplayers/svga_next_audioplayers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GlobalAudioplayersPlatformInterface.instance = _GlobalPlatform();

  test('isolates files and cancels a play overtaken by stop', () async {
    final platform = _PlayerPlatform();
    AudioplayersPlatformInterface.instance = platform;
    const backend = SvgaAudioplayersBackend();

    final first =
        await backend.createTrack('cue.mp3', Uint8List.fromList([1, 2]));
    final second =
        await backend.createTrack('cue.mp3', Uint8List.fromList([3, 4]));
    expect(platform.paths, hasLength(2));
    expect(platform.paths[0], isNot(platform.paths[1]));
    expect(await File(platform.paths[0]).readAsBytes(), [1, 2]);
    expect(await File(platform.paths[1]).readAsBytes(), [3, 4]);

    await first.dispose();
    expect(await File(platform.paths[0]).exists(), isFalse);
    expect(await File(platform.paths[1]).exists(), isTrue);
    platform.calls.clear();

    await second.setVolume(0.5);
    await second.play(const Duration(milliseconds: 200));
    await second.pause();
    await second.resume();
    expect(platform.calls, ['volume', 'seek', 'resume', 'pause', 'resume']);
    await second.stop();
    platform.calls.clear();

    platform.seekGate = Completer<void>();
    final play = second.play(const Duration(milliseconds: 300));
    await platform.seekEntered.future;
    final stop = second.stop();
    platform.seekGate!.complete();
    await Future.wait([play, stop]);
    expect(platform.calls.where((call) => call == 'resume'), isEmpty);
    expect(platform.calls.last, 'stop');

    await second.dispose();
    expect(await File(platform.paths[1]).exists(), isFalse);
  });

  test('removes the file when source preparation fails', () async {
    final platform = _PlayerPlatform()..failSource = true;
    AudioplayersPlatformInterface.instance = platform;

    await expectLater(
      const SvgaAudioplayersBackend().createTrack(
        'cue.mp3',
        Uint8List.fromList([1, 2]),
      ),
      throwsStateError,
    );
    expect(platform.paths, hasLength(1));
    expect(await File(platform.paths.single).exists(), isFalse);
  });
}

class _GlobalPlatform extends GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlayerPlatform extends AudioplayersPlatformInterface {
  final paths = <String>[];
  final calls = <String>[];
  final events = <String, StreamController<AudioEvent>>{};
  final seekEntered = Completer<void>();
  Completer<void>? seekGate;
  bool failSource = false;

  @override
  Future<void> create(String playerId) async {
    events[playerId] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) =>
      events[playerId]!.stream;

  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async {}

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    paths.add(url);
    events[playerId]!.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
    if (failSource) throw StateError('source failed');
  }

  @override
  Future<int?> getCurrentPosition(String playerId) async => 0;

  @override
  Future<void> seek(String playerId, Duration position) async {
    calls.add('seek');
    if (seekGate case final gate?) {
      seekEntered.complete();
      await gate.future;
    }
    events[playerId]!
        .add(const AudioEvent(eventType: AudioEventType.seekComplete));
  }

  @override
  Future<void> resume(String playerId) async => calls.add('resume');

  @override
  Future<void> pause(String playerId) async => calls.add('pause');

  @override
  Future<void> stop(String playerId) async => calls.add('stop');

  @override
  Future<void> setVolume(String playerId, double volume) async =>
      calls.add('volume');

  @override
  Future<void> release(String playerId) async {}

  @override
  Future<void> dispose(String playerId) async {
    await events[playerId]!.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
