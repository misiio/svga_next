import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../model/movie_data.dart';
import 'background.dart';
import 'svga_decode_options.dart';

/// Where an SVGA comes from. Sources with a [cacheKey] are shared through
/// `SvgaCache` (and concurrent loads of the same key are de-duplicated).
sealed class SvgaSource {
  const SvgaSource();

  const factory SvgaSource.network(String url, {Map<String, String>? headers}) =
      NetworkSvgaSource;
  const factory SvgaSource.asset(String name, {AssetBundle? bundle, String? package}) =
      AssetSvgaSource;
  const factory SvgaSource.file(String path) = FileSvgaSource;
  const factory SvgaSource.memory(Uint8List bytes, {String? cacheKey}) = MemorySvgaSource;

  String? get cacheKey;

  /// Produces isolate-parsed data. Heavy work never runs on the UI isolate.
  Future<MovieData> parse(SvgaDecodeOptions options);
}

final class NetworkSvgaSource extends SvgaSource {
  const NetworkSvgaSource(this.url, {this.headers});

  final String url;
  final Map<String, String>? headers;

  @override
  String get cacheKey => 'net:$url';

  @override
  Future<MovieData> parse(SvgaDecodeOptions options) => parseNetworkInBackground(
        url,
        headers: headers,
        diskCacheDir: SvgaConfig.diskCacheDirectory,
        timeout: SvgaConfig.networkTimeout,
        keepAudio: options.enableAudio,
      );

  @override
  bool operator ==(Object other) =>
      other is NetworkSvgaSource && other.url == url && mapEquals(other.headers, headers);

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'SvgaSource.network($url)';
}

final class AssetSvgaSource extends SvgaSource {
  const AssetSvgaSource(this.name, {this.bundle, this.package});

  final String name;
  final AssetBundle? bundle;
  final String? package;

  String get _key => package == null ? name : 'packages/$package/$name';

  @override
  String get cacheKey => 'asset:$_key';

  @override
  Future<MovieData> parse(SvgaDecodeOptions options) async {
    // rootBundle is only reachable from the root isolate; the bytes are
    // copied once into the worker and everything else happens there.
    final data = await (bundle ?? rootBundle).load(_key);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return parseBytesInBackground(bytes, keepAudio: options.enableAudio);
  }

  @override
  bool operator ==(Object other) =>
      other is AssetSvgaSource && other._key == _key && other.bundle == bundle;

  @override
  int get hashCode => _key.hashCode;

  @override
  String toString() => 'SvgaSource.asset($_key)';
}

final class FileSvgaSource extends SvgaSource {
  const FileSvgaSource(this.path);

  final String path;

  @override
  String get cacheKey => 'file:$path';

  @override
  Future<MovieData> parse(SvgaDecodeOptions options) =>
      parseFileInBackground(path, keepAudio: options.enableAudio);

  @override
  bool operator ==(Object other) => other is FileSvgaSource && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'SvgaSource.file($path)';
}

final class MemorySvgaSource extends SvgaSource {
  const MemorySvgaSource(this.bytes, {String? cacheKey}) : _cacheKey = cacheKey;

  final Uint8List bytes;
  final String? _cacheKey;

  @override
  String? get cacheKey => _cacheKey == null ? null : 'mem:$_cacheKey';

  @override
  Future<MovieData> parse(SvgaDecodeOptions options) =>
      parseBytesInBackground(bytes, keepAudio: options.enableAudio);

  @override
  bool operator ==(Object other) =>
      other is MemorySvgaSource &&
      (identical(other.bytes, bytes) || (_cacheKey != null && other._cacheKey == _cacheKey));

  @override
  int get hashCode => _cacheKey?.hashCode ?? identityHashCode(bytes);

  @override
  String toString() => 'SvgaSource.memory(${bytes.lengthInBytes} bytes)';
}
