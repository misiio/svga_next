import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:isolate';
import 'dart:typed_data';

import '../errors.dart';
import '../model/movie_data.dart';
import '../parser/svga_parser.dart';

// Each entry point captures only plain data, so the closure is cheap to send.
// The returned MovieData leaves the worker via Isolate.exit (zero-copy).

Future<MovieData> parseBytesInBackground(Uint8List bytes, {required bool keepAudio}) =>
    Isolate.run(() => parseSvgaBytes(bytes, keepAudio: keepAudio), debugName: 'svga:parse');

Future<MovieData> parseFileInBackground(String path, {required bool keepAudio}) => Isolate.run(
      () async => parseSvgaBytes(await File(path).readAsBytes(), keepAudio: keepAudio),
      debugName: 'svga:file',
    );

/// Download (+ optional disk cache) + inflate + decode, all off the UI
/// isolate: the downloaded bytes never touch the main heap.
///
/// Note: `HttpOverrides.global` (proxies, custom certs) is per-isolate. If you
/// rely on it, use `SvgaSource.memory` with your own client instead.
Future<MovieData> parseNetworkInBackground(
  String url, {
  required Map<String, String>? headers,
  required String? diskCacheDir,
  required Duration timeout,
  required bool keepAudio,
}) =>
    Isolate.run(() async {
      final cacheFile = diskCacheDir == null ? null : File('$diskCacheDir/${_fnv1a64(url)}.svga');
      Uint8List? bytes;
      if (cacheFile != null && await cacheFile.exists()) {
        try {
          bytes = await cacheFile.readAsBytes();
        } catch (_) {}
      }
      final fromDisk = bytes != null;
      final Uint8List payload = bytes ?? await _httpGet(url, headers, timeout);
      final MovieData data;
      try {
        data = parseSvgaBytes(payload, keepAudio: keepAudio);
      } catch (_) {
        if (fromDisk) {
          try {
            await cacheFile!.delete(); // corrupt cache entry
          } catch (_) {}
        }
        rethrow;
      }
      if (!fromDisk && cacheFile != null) {
        try {
          await cacheFile.parent.create(recursive: true);
          final tmp = File('${cacheFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
          await tmp.writeAsBytes(payload, flush: true);
          await tmp.rename(cacheFile.path); // atomic publish
        } catch (_) {}
      }
      return data;
    }, debugName: 'svga:net');

Future<Uint8List> _httpGet(String url, Map<String, String>? headers, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != HttpStatus.ok) {
      throw SvgaException('HTTP ${res.statusCode}', url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(timeout)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } on SvgaException {
    rethrow;
  } catch (e) {
    throw SvgaException('Download failed: $url', e.toString());
  } finally {
    client.close(force: true);
  }
}

String _fnv1a64(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return (h >>> 32).toRadixString(16).padLeft(8, '0') +
      (h & 0xffffffff).toRadixString(16).padLeft(8, '0');
}
