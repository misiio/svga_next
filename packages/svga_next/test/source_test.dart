import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/svga_next.dart';

import 'support/svga_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('file sources with the same cacheKey share a movie across paths',
      () async {
    final directory = await Directory.systemTemp.createTemp('svga-source-');
    addTearDown(() => directory.delete(recursive: true));
    final file =
        await File('${directory.path}/first.svga').writeAsBytes(svgaBytes());
    final cache = SvgaCache();
    addTearDown(cache.clear);
    final first = SvgaSource.file(file.path, cacheKey: 'animation');
    final second = SvgaSource.file('${directory.path}/missing.svga',
        cacheKey: 'animation');

    final movie = await SvgaLoader.load(first, cache: cache);
    addTearDown(movie.release);
    final cached = await SvgaLoader.load(second, cache: cache);
    addTearDown(cached.release);

    expect(cached, same(movie));
    expect(cache.length, 1);
    expect(first.cacheKey, 'file:animation');
    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });

  test('file sources without cacheKey still share by path', () async {
    final directory = await Directory.systemTemp.createTemp('svga-source-');
    addTearDown(() => directory.delete(recursive: true));
    final firstFile =
        await File('${directory.path}/first.svga').writeAsBytes(svgaBytes());
    final secondFile =
        await File('${directory.path}/second.svga').writeAsBytes(svgaBytes());
    final cache = SvgaCache();
    addTearDown(cache.clear);
    final first = SvgaSource.file(firstFile.path);
    final samePath = SvgaSource.file(firstFile.path);
    final second = SvgaSource.file(secondFile.path);

    final movie = await SvgaLoader.load(first, cache: cache);
    addTearDown(movie.release);
    final cached = await SvgaLoader.load(samePath, cache: cache);
    addTearDown(cached.release);
    final other = await SvgaLoader.load(second, cache: cache);
    addTearDown(other.release);

    expect(first.cacheKey, 'file:${firstFile.path}');
    expect(first, samePath);
    expect(first.hashCode, samePath.hashCode);
    expect(first, isNot(second));
    expect(cached, same(movie));
    expect(other, isNot(same(movie)));
    expect(cache.length, 2);
  });

  test('file equality follows the effective cache key', () {
    const pathKey = SvgaSource.file('animation');
    const explicitKey = SvgaSource.file('another', cacheKey: 'animation');
    const differentKey = SvgaSource.file('animation', cacheKey: 'different');

    expect(pathKey, explicitKey);
    expect(pathKey.hashCode, explicitKey.hashCode);
    expect(pathKey, isNot(differentKey));
  });
}
