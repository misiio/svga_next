import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/src/dynamic/svga_dynamic_entity.dart';
import 'package:svga_next/src/player/svga_player.dart';

// Both fixtures are 8x8 and loop forever: red, green, blue, 100 ms each.
final Uint8List _gif = File('test/fixtures/animated.gif').readAsBytesSync();
final Uint8List _webp = File('test/fixtures/animated.webp').readAsBytesSync();
// 400x300, red then green, looping.
final Uint8List _bigGif = File('test/fixtures/animated_400x300.gif').readAsBytesSync();

const _key = 'avatar';

void main() {
  tearDown(() {
    imageCache
      ..clear()
      ..clearLiveImages();
  });

  _testEntity('animate: false keeps the first frame of an animated image', (tester, entity) async {
    entity.registerPlayer(_player);
    final frames = _Frames(entity);

    expect(await _set(tester, entity, MemoryImage(_gif)), isTrue);
    await _advance(tester, const Duration(milliseconds: 400));

    expect(await frames.colours(tester), ['red']);
    expect(_listened(MemoryImage(_gif)), isFalse);
  });

  for (final (name, bytes) in [('GIF', () => _gif), ('WebP', () => _webp)]) {
    _testEntity('animate: true plays every frame of an animated $name', (tester, entity) async {
      entity.registerPlayer(_player);
      final frames = _Frames(entity);

      expect(await _set(tester, entity, MemoryImage(bytes()), animate: true), isTrue);
      expect(await frames.colours(tester), ['red'], reason: 'ready on the first frame');

      await _advance(tester, const Duration(milliseconds: 400));
      expect(await frames.colours(tester), containsAllInOrder(['red', 'green', 'blue', 'red']));
    });
  }

  _testEntity('frames advance only while a player is registered', (tester, entity) async {
    final provider = MemoryImage(_gif);
    final frames = _Frames(entity); // a plain addListener, which must not count

    expect(await _set(tester, entity, provider, animate: true), isTrue);
    await _advance(tester, const Duration(milliseconds: 400));
    expect(await frames.colours(tester), ['red']);
    expect(_listened(provider), isFalse);

    entity.registerPlayer(_player);
    await _advance(tester, const Duration(milliseconds: 400));
    expect(frames.count, greaterThanOrEqualTo(3));
    expect(_listened(provider), isTrue);

    entity.unregisterPlayer(_player);
    final shown = frames.count;
    await _advance(tester, const Duration(milliseconds: 400));
    expect(frames.count, shown);
    expect(_listened(provider), isFalse);
  });

  _testEntity('an image evicted while paused restarts when a player registers', (tester, entity) async {
    final frames = _Frames(entity);
    expect(await _set(tester, entity, MemoryImage(_gif), animate: true), isTrue);
    imageCache.clear(); // nothing listens, so Flutter disposes the stream

    entity.registerPlayer(_player);
    await _advance(tester, const Duration(milliseconds: 400));
    expect(await frames.colours(tester), containsAllInOrder(['red', 'green', 'blue']));
  });

  _testEntity('frames advance until the last of several players leaves', (tester, entity) async {
    final provider = _ControlledProvider();
    final other = Object();
    entity
      ..registerPlayer(_player)
      ..registerPlayer(other);
    entity.setImageProvider(_key, provider: provider, animate: true);
    provider.emit('red');

    entity.unregisterPlayer(_player);
    expect(provider.listened, isTrue);
    entity.unregisterPlayer(other);
    expect(provider.listened, isFalse);
  });

  _testEntity('a player registered before the first frame keeps listening', (tester, entity) async {
    final provider = _ControlledProvider();
    final ready = entity.setImageProvider(_key, provider: provider, animate: true);
    entity.registerPlayer(_player);
    provider.emit('red');

    expect(await ready, isTrue);
    expect(provider.listened, isTrue);
  });

  _testEntity('a re-attached stream resumes from its current frame', (tester, entity) async {
    final provider = _ControlledProvider();
    entity.setImageProvider(_key, provider: provider, animate: true);
    provider
      ..emit('red')
      ..emit('green'); // while nothing listens

    var notified = 0;
    entity.addListener(() => notified++);
    entity.registerPlayer(_player);

    expect(await _Frames(entity).colours(tester), ['green']);
    expect(notified, 0, reason: 'a registering player may be building');
  });

  for (final (name, change) in <(String, void Function(SvgaDynamicEntity))>[
    ('remove', (e) => e.remove(_key)),
    ('clear', (e) => e.clear()),
    ('setImageProvider', (e) => e.setImageProvider(_key, provider: _ControlledProvider())),
    ('setImageProvider(animate: true)',
        (e) => e.setImageProvider(_key, provider: _ControlledProvider(), animate: true)),
  ]) {
    _testEntity('$name stops the earlier animation', (tester, entity) async {
      final provider = _ControlledProvider();
      entity
        ..registerPlayer(_player)
        ..setImageProvider(_key, provider: provider, animate: true);
      provider.emit('red');

      change(entity);
      final shown = entity.imageFor(_key)?.image;
      expect(provider.listened, isFalse);
      provider.emit('green');
      expect(entity.imageFor(_key)?.image, same(shown));
    });
  }

  _testEntity('setImage stops the earlier animation', (tester, entity) async {
    final provider = _ControlledProvider();
    entity
      ..registerPlayer(_player)
      ..setImageProvider(_key, provider: provider, animate: true);
    provider.emit('red');

    final blue = _solid('blue');
    entity.setImage(_key, image: blue);
    blue.dispose();
    expect(provider.listened, isFalse);
    provider.emit('green');

    expect(await _Frames(entity).colours(tester), ['blue']);
  });

  testWidgets('dispose stops the animation', (tester) async {
    final entity = SvgaDynamicEntity();
    final provider = _ControlledProvider();
    entity
      ..registerPlayer(_player)
      ..setImageProvider(_key, provider: provider, animate: true);
    provider.emit('red');

    entity.dispose();
    expect(provider.listened, isFalse);
    provider.emit('green');
    entity.unregisterPlayer(_player); // a player unmounting after its entity
  });

  _testEntity('a superseded animation completes with false', (tester, entity) async {
    final ready = entity.setImageProvider(_key, provider: _ControlledProvider(), animate: true);
    entity.remove(_key);

    expect(await ready, isFalse);
  });

  _testEntity('a first frame replaced while notifying still completes with true', (tester, entity) async {
    final provider = _ControlledProvider();
    final ready = entity.setImageProvider(_key, provider: provider, animate: true);
    void replace() {
      entity
        ..removeListener(replace)
        ..remove(_key);
    }

    entity.addListener(replace);
    provider.emit('red');

    expect(await ready, isTrue);
    expect(provider.listened, isFalse);
  });

  _testEntity('an error before the first frame completes with false', (tester, entity) async {
    final provider = _ControlledProvider();
    final ready = entity.setImageProvider(_key, provider: provider, animate: true);
    provider.fail();

    expect(await ready, isFalse);
    expect(entity.imageFor(_key), isNull);
  });

  _testEntity('an error after the first frame keeps the last frame', (tester, entity) async {
    final provider = _ControlledProvider();
    final frames = _Frames(entity);
    entity
      ..registerPlayer(_player)
      ..setImageProvider(_key, provider: provider, animate: true);
    provider
      ..emit('red')
      ..emit('green')
      ..fail();

    expect(provider.listened, isFalse);
    entity
      ..unregisterPlayer(_player)
      ..registerPlayer(_player);
    expect(provider.listened, isFalse, reason: 'the failed key stays detached');
    provider.emit('blue');
    expect(await frames.colours(tester), ['red', 'green']);
  });

  group('maxImageDimension', () {
    _testEntity('caps an oversized first frame, keeping its aspect ratio', (tester, entity) async {
      final provider = _ControlledProvider();
      final ready = entity.setImageProvider(_key, provider: provider, animate: true, maxImageDimension: 4);
      provider.emit('red', width: 8, height: 6);

      expect(await tester.runAsync(() => ready), isTrue);
      expect(_size(entity), [4, 3]);
      expect(await _Frames(entity).colours(tester), ['red']);
    });

    _testEntity('caps an oversized later frame', (tester, entity) async {
      final provider = _ControlledProvider();
      final frames = _Frames(entity);
      entity
        ..registerPlayer(_player)
        ..setImageProvider(_key, provider: provider, animate: true, maxImageDimension: 4);
      provider.emit('red', width: 8, height: 6);
      await _until(tester, () => frames.count == 1);

      provider.emit('green', width: 6, height: 12);
      await _until(tester, () => frames.count == 2);
      expect(_size(entity), [2, 4]);
      expect(await frames.colours(tester), ['red', 'green']);
    });

    _testEntity('leaves a frame within the cap unchanged', (tester, entity) async {
      final provider = _ControlledProvider();
      entity
        ..registerPlayer(_player)
        ..setImageProvider(_key, provider: provider, animate: true, maxImageDimension: 4);
      final source = _solid('red', width: 4, height: 3);
      final kept = source.clone();
      addTearDown(kept.dispose);
      provider.emitImage(source);

      expect(entity.imageFor(_key)?.image.isCloneOf(kept), isTrue, reason: 'stored as it arrives, without a resize');
    });

    for (final animate in [false, true]) {
      _testEntity('keeps no handle to an oversized frame (animate: $animate)', (tester, entity) async {
        final provider = _ControlledProvider();
        final source = _solid('red', width: 8, height: 6);
        final kept = source.clone();
        addTearDown(kept.dispose);
        final ready = entity.setImageProvider(_key, provider: provider, animate: animate, maxImageDimension: 4);
        provider.emitImage(source);
        expect(await tester.runAsync(() => ready), isTrue);

        final handles = kept.debugGetOpenHandleStackTraces()!;
        expect(handles.where((stack) => '$stack'.contains('package:svga_next/')), isEmpty);
      });
    }

    _testEntity('caps a still image', (tester, entity) async {
      final provider = _ControlledProvider();
      final ready = entity.setImageProvider(_key, provider: provider, maxImageDimension: 4);
      provider.emit('red', width: 8, height: 6);

      expect(await tester.runAsync(() => ready), isTrue);
      expect(_size(entity), [4, 3]);
    });

    _testEntity('caps every frame of a decoded animated image', (tester, entity) async {
      entity.registerPlayer(_player);
      final frames = _Frames(entity);
      final sizes = <String>{};
      entity.addListener(() => sizes.add('${_size(entity)}'));

      final ready = entity.setImageProvider(_key, provider: MemoryImage(_bigGif), animate: true, maxImageDimension: 40);
      await _until(tester, () => frames.count >= 3);

      expect(await tester.runAsync(() => ready), isTrue);
      expect(await frames.colours(tester), containsAllInOrder(['red', 'green', 'red']));
      expect(sizes, {'[40, 30]'});
    });

    _testEntity('setting the key again uses the new cap', (tester, entity) async {
      final first = _ControlledProvider();
      final ready = entity.setImageProvider(_key, provider: first, maxImageDimension: 4);
      first.emit('red', width: 8, height: 4);
      expect(await tester.runAsync(() => ready), isTrue);
      expect(_size(entity), [4, 2]);

      final second = _ControlledProvider();
      final again = entity.setImageProvider(_key, provider: second, maxImageDimension: 2);
      second.emit('red', width: 8, height: 4);
      expect(await tester.runAsync(() => again), isTrue);
      expect(_size(entity), [2, 1]);
    });

    _testEntity('setting the key again with the same stream applies the new cap', (tester, entity) async {
      final provider = _ControlledProvider();
      entity.setImageProvider(_key, provider: provider, animate: true);
      provider.emit('red', width: 8, height: 4);
      expect(_size(entity), [8, 4]);

      final again = entity.setImageProvider(_key, provider: provider, animate: true, maxImageDimension: 4);
      expect(await tester.runAsync(() => again), isTrue);
      expect(_size(entity), [4, 2]);
    });

    for (final animate in [false, true]) {
      _testEntity('a key changed during a resize keeps the change (animate: $animate)', (tester, entity) async {
        final provider = _ControlledProvider();
        final ready = entity.setImageProvider(_key, provider: provider, animate: animate, maxImageDimension: 4);
        provider.emit('red', width: 8, height: 6);
        entity.remove(_key);

        await _advance(tester, const Duration(milliseconds: 100));
        expect(entity.imageFor(_key), isNull);
        expect(await tester.runAsync(() => ready), animate ? isFalse : isTrue);
      });
    }

    _testEntity('without a cap an oversized frame is stored as it arrives', (tester, entity) async {
      final provider = _ControlledProvider();
      entity.setImageProvider(_key, provider: provider, animate: true);
      provider.emit('red', width: 8, height: 6);

      expect(_size(entity), [8, 6]);
    });
  });

  group('SvgaPlayer', () {
    Widget player(SvgaDynamicEntity? entity) =>
        Directionality(textDirection: TextDirection.ltr, child: SvgaPlayer(dynamicEntity: entity));

    /// An entity showing a frame of an animated image, with no player yet.
    (SvgaDynamicEntity, _ControlledProvider) animated() {
      final entity = SvgaDynamicEntity();
      addTearDown(entity.dispose);
      final provider = _ControlledProvider();
      entity.setImageProvider(_key, provider: provider, animate: true);
      provider.emit('red');
      return (entity, provider);
    }

    testWidgets('animates while mounted', (tester) async {
      final (entity, provider) = animated();
      expect(provider.listened, isFalse);

      await tester.pumpWidget(player(entity));
      expect(provider.listened, isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(provider.listened, isFalse);
    });

    testWidgets('moves its registration when the entity changes', (tester) async {
      final (first, firstProvider) = animated();
      final (second, secondProvider) = animated();

      await tester.pumpWidget(player(first));
      await tester.pumpWidget(player(second));
      expect(firstProvider.listened, isFalse);
      expect(secondProvider.listened, isTrue);

      await tester.pumpWidget(player(null));
      expect(secondProvider.listened, isFalse);

      await tester.pumpWidget(player(first));
      expect(firstProvider.listened, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps the entity animating while another player is mounted', (tester) async {
      final (entity, provider) = animated();

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [SvgaPlayer(dynamicEntity: entity), SvgaPlayer(dynamicEntity: entity)]),
      ));
      await tester.pumpWidget(player(entity));
      expect(provider.listened, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Whether anything listens to the stream Flutter caches for [provider].
bool _listened(ImageProvider provider) =>
    provider.resolve(ImageConfiguration.empty).completer!.hasListeners;

/// Stands in for a mounted `SvgaPlayer`.
final Object _player = Object();

/// A widget test with a fresh entity, disposed before the test ends so no
/// image stream timers outlive it.
void _testEntity(String description, Future<void> Function(WidgetTester, SvgaDynamicEntity) body) {
  testWidgets(description, (tester) async {
    final entity = SvgaDynamicEntity();
    try {
      await body(tester, entity);
    } finally {
      entity.dispose();
    }
  });
}

/// Calls `setImageProvider` and lets real decoding run until it settles.
Future<bool> _set(
  WidgetTester tester,
  SvgaDynamicEntity entity,
  ImageProvider provider, {
  bool animate = false,
}) async {
  final ready = entity.setImageProvider(_key, provider: provider, animate: animate);
  var settled = false;
  ready.whenComplete(() => settled = true);
  for (var i = 0; i < 100 && !settled; i++) {
    await _advance(tester, const Duration(milliseconds: 10));
  }
  return ready;
}

/// Lets real decoding and resizing run until [done], for at most a second.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await _advance(tester, const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'timed out');
}

/// The width and height of the image shown for [_key].
List<int>? _size(SvgaDynamicEntity entity) {
  final image = entity.imageFor(_key)?.image;
  return image == null ? null : [image.width, image.height];
}

/// Lets real decoding and Flutter's frame scheduling run for [duration].
Future<void> _advance(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 10);
  for (var elapsed = Duration.zero; elapsed < duration; elapsed += step) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump(step);
  }
}

/// An image stream whose frames and errors the test sends by hand.
class _ControlledProvider extends ImageProvider<_ControlledProvider> {
  final _ControlledCompleter _completer = _ControlledCompleter();

  bool get listened => _completer.hasListeners;

  void emit(String colour, {int width = 2, int height = 2}) =>
      emitImage(_solid(colour, width: width, height: height));

  void emitImage(ui.Image image) => _completer.emit(image);

  void fail() => _completer.fail();

  @override
  Future<_ControlledProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ControlledProvider key, ImageDecoderCallback decode) => _completer;
}

class _ControlledCompleter extends ImageStreamCompleter {
  void emit(ui.Image image) => setImage(ImageInfo(image: image));

  void fail() => reportError(exception: StateError('broken frame'), silent: true);
}

/// An image of [colour] ('red', 'green' or 'blue'), 2x2 by default.
ui.Image _solid(String colour, {int width = 2, int height = 2}) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(
    switch (colour) {
      'red' => const ui.Color(0xffff0000),
      'green' => const ui.Color(0xff00ff00),
      _ => const ui.Color(0xff0000ff),
    },
    ui.BlendMode.src,
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
}

/// Clones every distinct image the entity shows for [_key], so their colours
/// can be read after the entity has disposed them.
class _Frames {
  _Frames(this.entity) {
    entity.addListener(_onChange);
    _onChange();
    addTearDown(() {
      for (final image in _images) {
        image.dispose();
      }
    });
  }

  final SvgaDynamicEntity entity;
  final List<ui.Image> _images = [];

  void _onChange() {
    final image = entity.imageFor(_key)?.image;
    if (image == null || (_images.isNotEmpty && image.isCloneOf(_images.last))) return;
    _images.add(image.clone());
  }

  int get count => _images.length;

  Future<List<String>> colours(WidgetTester tester) async => [
        for (final image in _images) _name((await tester.runAsync<ByteData?>(() => image.toByteData()))!),
      ];

  static String _name(ByteData rgba) => switch ((rgba.getUint8(0), rgba.getUint8(1), rgba.getUint8(2))) {
        (255, 0, 0) => 'red',
        (0, 255, 0) => 'green',
        (0, 0, 255) => 'blue',
        final rgb => '$rgb',
      };
}
