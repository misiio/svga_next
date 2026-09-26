import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/svga_next.dart';

import 'support/svga_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('layoutSizeOf uses the first visible frame without its transform',
      () async {
    final movie = await SvgaLoader.load(SvgaSource.memory(svgaBytes(sprites: [
      {
        'imageKey': 'avatar',
        'frames': [
          frame(alpha: 0, width: 90, height: 80),
          frame(width: 40, height: 20),
          frame(width: 60, height: 30),
        ],
      },
    ])));
    addTearDown(movie.release);

    expect(movie.layoutSizeOf('avatar'), const Size(40, 20));
  });

  test('layoutSizeOf returns null for a missing key', () async {
    final movie = await SvgaLoader.load(SvgaSource.memory(svgaBytes()));
    addTearDown(movie.release);

    expect(movie.layoutSizeOf('missing'), isNull);
  });

  for (final entry in {
    'zero size throughout': [frame(width: 0), frame(height: 0)],
    'invisible throughout': [frame(alpha: 0)],
    'no frames': <Map<String, Object>>[],
  }.entries) {
    test('layoutSizeOf returns null with ${entry.key}', () async {
      final movie = await SvgaLoader.load(SvgaSource.memory(svgaBytes(sprites: [
        {'imageKey': 'avatar', 'frames': entry.value},
      ])));
      addTearDown(movie.release);

      expect(movie.layoutSizeOf('avatar'), isNull);
    });
  }

  test('layoutSizeOf skips unusable sizes and uses only the first sprite',
      () async {
    final movie = await SvgaLoader.load(SvgaSource.memory(svgaBytes(sprites: [
      {
        'imageKey': 'avatar',
        'frames': [
          frame(width: 0),
          frame(alpha: 0, width: 90),
          frame(height: -1),
          frame(width: 40, height: 20),
        ],
      },
      {
        'imageKey': 'avatar',
        'frames': [frame(width: 80, height: 70)]
      },
    ])));
    addTearDown(movie.release);

    expect(movie.layoutSizeOf('avatar'), const Size(40, 20));
  });

  test('layoutSizeOf does not fall back to a later sprite with the same key',
      () async {
    final movie = await SvgaLoader.load(SvgaSource.memory(svgaBytes(sprites: [
      {
        'imageKey': 'avatar',
        'frames': [frame(width: 0)]
      },
      {
        'imageKey': 'avatar',
        'frames': [frame()]
      },
    ])));
    addTearDown(movie.release);

    expect(movie.layoutSizeOf('avatar'), isNull);
  });
}
