import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/svga_next.dart';

import 'support/svga_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SvgaCache cache;
  late _GatedAssetBundle bundle;
  late List<Future<SvgaMovie>> loads;
  late int previousLimit;

  setUp(() {
    previousLimit = SvgaConfig.maxConcurrentLoads;
    SvgaConfig.maxConcurrentLoads = 1;
    cache = SvgaCache();
    bundle = _GatedAssetBundle();
    loads = [];
  });

  tearDown(() async {
    bundle.openAll();
    for (final load in loads) {
      try {
        (await load).release();
      } catch (_) {
        // Failed loads have no movie to release.
      }
    }
    cache.clear();
    SvgaConfig.maxConcurrentLoads = previousLimit;
  });

  Future<SvgaMovie> load(String key, {SvgaCache? targetCache}) {
    final future = SvgaLoader.load(
      SvgaSource.asset(key, bundle: bundle),
      cache: targetCache ?? cache,
    );
    loads.add(future);
    return future;
  }

  test('a load waits until the previous movie finishes decoding its images',
      () async {
    final bytes = svgaBytes(images: {'avatar': await _png()});
    final events = <String>[];
    bundle.onLoad = (key) => events.add('load $key');
    final previousOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (_) => events.add('decoded');
    addTearDown(() => ui.Image.onCreate = previousOnCreate);

    final first = load('first');
    await bundle.whenRequested('first');
    final second = load('second');
    await Future<void>.delayed(Duration.zero);
    expect(events, ['load first']);

    bundle.open('first', bytes);
    await bundle.whenRequested('second');
    expect(events, ['load first', 'decoded', 'load second']);
    expect((await first).imageFor('avatar'), isNotNull);
    bundle.open('second');
    await second;
  });

  test('cache hits complete while the only load slot is busy', () async {
    bundle.open('cached');
    final cached = await load('cached');
    final busy = load('busy');
    await bundle.whenRequested('busy');

    expect(
        await load('cached').timeout(const Duration(seconds: 2)), same(cached));
    expect(bundle.requested, ['cached', 'busy']);
    bundle.open('busy');
    await busy;
  });

  test('a parse error releases the slot for the next load', () async {
    final broken = load('broken');
    final failure = expectLater(broken, throwsA(isA<SvgaException>()));
    await bundle.whenRequested('broken');
    final next = load('next');
    bundle.open('broken', Uint8List(0));

    await failure;
    await bundle.whenRequested('next');
    bundle.open('next');
    expect((await next).size, const ui.Size(100, 100));
  });

  test('in-flight requests share one of the two default slots', () async {
    expect(previousLimit, 2);
    SvgaConfig.maxConcurrentLoads = previousLimit;
    final first = load('first');
    await bundle.whenRequested('first');
    final duplicate = load('first');
    final secondCache = SvgaCache();
    addTearDown(secondCache.clear);
    final second = load('second', targetCache: secondCache);
    await bundle.whenRequested('second');
    final third = load('third');
    await Future<void>.delayed(Duration.zero);
    expect(bundle.requested, ['first', 'second']);

    bundle.open('first');
    expect(await duplicate, same(await first));
    await bundle.whenRequested('third');
    bundle.openAll();
    await Future.wait([second, third]);
    expect(bundle.requested, ['first', 'second', 'third']);
  });

  test('uncached loads start in FIFO order', () async {
    final first = load('first');
    await bundle.whenRequested('first');
    final second = load('second');
    final third = load('third');
    bundle.open('third');
    await Future<void>.delayed(Duration.zero);
    expect(bundle.requested, ['first']);

    bundle.open('first');
    await bundle.whenRequested('second');
    expect(bundle.requested, ['first', 'second']);
    bundle.open('second');
    await Future.wait([first, second, third]);
    expect(bundle.requested, ['first', 'second', 'third']);
  });

  test('memory sources without a cache key occupy a slot through decoding',
      () async {
    final bytes = svgaBytes(images: {'avatar': await _png()});
    final events = <String>[];
    bundle.onLoad = (key) => events.add('load $key');
    final previousOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (_) => events.add('decoded');
    addTearDown(() => ui.Image.onCreate = previousOnCreate);

    final memory = SvgaLoader.load(SvgaSource.memory(bytes));
    loads.add(memory);
    final next = load('next');
    await bundle.whenRequested('next');
    expect(events, ['decoded', 'load next']);
    expect((await memory).imageFor('avatar'), isNotNull);
    bundle.open('next');
    await next;
  });

  test('lowering the limit lets active loads finish before starting another',
      () async {
    SvgaConfig.maxConcurrentLoads = 2;
    final first = load('first');
    final second = load('second');
    await bundle.whenRequested('second');
    SvgaConfig.maxConcurrentLoads = 1;
    final third = load('third');
    bundle.open('first');
    await first;
    expect(bundle.requested, ['first', 'second']);

    bundle.open('second');
    await bundle.whenRequested('third');
    bundle.open('third');
    await Future.wait([second, third]);
    expect(bundle.requested, ['first', 'second', 'third']);
  });

  test('the load limit rejects nonpositive values without changing the limit',
      () {
    for (final value in [0, -1]) {
      expect(() => SvgaConfig.maxConcurrentLoads = value, throwsRangeError);
      expect(SvgaConfig.maxConcurrentLoads, 1);
    }
  });
}

class _GatedAssetBundle extends CachingAssetBundle {
  final _gates = <String, Completer<ByteData>>{};
  final _requests = <String, Completer<void>>{};
  final requested = <String>[];
  void Function(String)? onLoad;
  bool _allOpen = false;

  Future<void> whenRequested(String key) =>
      (_requests[key] ??= Completer<void>())
          .future
          .timeout(const Duration(seconds: 5));

  @override
  Future<ByteData> load(String key) {
    requested.add(key);
    onLoad?.call(key);
    final request = _requests[key] ??= Completer<void>();
    if (!request.isCompleted) request.complete();
    final gate = _gates[key] ??= Completer<ByteData>();
    if (_allOpen && !gate.isCompleted) open(key);
    return gate.future;
  }

  void open(String key, [Uint8List? bytes]) {
    final gate = _gates[key] ??= Completer<ByteData>();
    if (!gate.isCompleted) {
      gate.complete(ByteData.sublistView(bytes ?? svgaBytes()));
    }
  }

  void openAll() {
    _allOpen = true;
    for (final key in _gates.keys) {
      open(key);
    }
  }
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
