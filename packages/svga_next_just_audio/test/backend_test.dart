import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:svga_next_just_audio/svga_next_just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isolates files and cancels a play overtaken by stop', () async {
    final platform = _Platform();
    JustAudioPlatform.instance = platform;
    const backend = SvgaJustAudioBackend();

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

    final player = platform.players.last;
    player.seekGate = Completer<void>();
    final play = second.play(const Duration(milliseconds: 300));
    await player.seekEntered.future;
    final stop = second.stop();
    player.seekGate!.complete();
    await Future.wait([play, stop]);
    expect(player.calls, isNot(contains('play')));

    await second.dispose();
    expect(await File(platform.paths[1]).exists(), isFalse);
  });

  test('seeks before starting playback and forwards controls', () async {
    const audioSessionChannel = MethodChannel('com.ryanheise.audio_session');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(audioSessionChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(audioSessionChannel, null);
    });

    final platform = _Platform();
    JustAudioPlatform.instance = platform;
    final track = await const SvgaJustAudioBackend().createTrack(
      'cue.mp3',
      Uint8List.fromList([1, 2]),
    );
    final player = platform.players.single;
    player.calls.clear();

    await track.setVolume(0.5);
    await track.play(const Duration(milliseconds: 200));
    await player.playEntered.future.timeout(const Duration(seconds: 1));
    expect(player.calls.take(3), ['volume', 'seek', 'play']);

    await track.pause();
    expect(player.calls, contains('pause'));
    await track.stop();
    await track.dispose();
  });

  test('removes the file when source preparation fails', () async {
    final platform = _Platform()..failLoad = true;
    JustAudioPlatform.instance = platform;

    await expectLater(
      const SvgaJustAudioBackend().createTrack(
        'cue.mp3',
        Uint8List.fromList([1, 2]),
      ),
      throwsStateError,
    );
    expect(platform.paths, hasLength(1));
    expect(await File(platform.paths.single).exists(), isFalse);
  });
}

class _Platform extends JustAudioPlatform {
  final paths = <String>[];
  final players = <_Player>[];
  bool failLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = _Player(request.id, paths, failLoad);
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    final player = players.where((player) => player.id == request.id).last;
    await player.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends AudioPlayerPlatform {
  _Player(super.id, this.paths, this.failLoad);

  final List<String> paths;
  final bool failLoad;
  final calls = <String>[];
  final playbackEvents = StreamController<PlaybackEventMessage>.broadcast();
  final playerData = StreamController<PlayerDataMessage>.broadcast();
  final seekEntered = Completer<void>();
  final playEntered = Completer<void>();
  Completer<void>? seekGate;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      playbackEvents.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => playerData.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final playlist =
        request.audioSourceMessage as ConcatenatingAudioSourceMessage;
    final source = playlist.children.first as UriAudioSourceMessage;
    paths.add(Uri.parse(source.uri).toFilePath());
    if (failLoad) throw StateError('source failed');
    playbackEvents.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 1),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(seconds: 1));
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      _recordVolume();

  SetVolumeResponse _recordVolume() {
    calls.add('volume');
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async =>
      SetShuffleOrderResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek');
    if (seekGate case final gate?) {
      seekEntered.complete();
      await gate.future;
    }
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    if (!playEntered.isCompleted) playEntered.complete();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    return PauseResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    calls.add('dispose');
    await playbackEvents.close();
    await playerData.close();
    return DisposeResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
