import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List svgaBytes({
  List<Map<String, Object>> sprites = const [],
  Map<String, Uint8List> images = const {},
}) {
  final spec = utf8.encode(jsonEncode({
    'ver': '1.0',
    'movie': {
      'viewBox': {'width': 100, 'height': 100},
      'fps': 20,
    },
    'sprites': sprites,
    'images': {for (final key in images.keys) key: '$key.png'},
  }));
  final archive = Archive()
    ..addFile(ArchiveFile('movie.spec', spec.length, spec));
  for (final entry in images.entries) {
    archive.addFile(ArchiveFile(
      '${entry.key}.png',
      entry.value.length,
      entry.value,
    ));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Object> frame({
  double alpha = 1,
  double width = 40,
  double height = 20,
}) =>
    {
      'alpha': alpha,
      'layout': {'x': 7, 'y': 9, 'width': width, 'height': height},
      'transform': {'a': 3, 'b': 0, 'c': 0, 'd': 4, 'tx': 11, 'ty': 13},
    };
