import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/src/model/movie_data.dart';
import 'package:svga_next/src/parser/proto_reader.dart';
import 'package:svga_next/src/parser/svg_path_parser.dart';

void main() {
  group('svg path', () {
    test('absolute + close', () {
      final p = parseSvgPath('M0 0L10 10Z', 0);
      expect(p.verbs, [PathData.moveTo, PathData.lineTo, PathData.close]);
      expect(p.points, [0, 0, 10, 10]);
    });

    test('relative with implicit lineTo', () {
      final p = parseSvgPath('m1 1 2 2', 0);
      expect(p.verbs, [PathData.moveTo, PathData.lineTo]);
      expect(p.points, [1, 1, 3, 3]);
    });

    test('compact numbers', () {
      final p = parseSvgPath('M1e2-1L.5.5', 0);
      expect(p.points, [100, -1, 0.5, 0.5]);
    });

    test('smooth cubic reflects control point', () {
      final p = parseSvgPath('M0 0C0 10 10 10 10 0S20 -10 20 0', 0);
      expect(p.verbs.last, PathData.cubicTo);
      expect(p.points.sublist(8, 10), [10, -10]);
    });

    test('malformed tail is dropped, prefix kept', () {
      final p = parseSvgPath('M0 0L5 5L', 0);
      expect(p.verbs, [PathData.moveTo, PathData.lineTo]);
    });
  });

  group('proto reader', () {
    test('varint / negative int32 / float', () {
      final bd = ByteData(4)..setFloat32(0, 1.5, Endian.little);
      final bytes = Uint8List.fromList([
        0x96, 0x01, // 150
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, // -1
        ...bd.buffer.asUint8List(),
      ]);
      final r = ProtoReader(bytes);
      expect(r.readVarint(), 150);
      expect(r.readInt32(), -1);
      expect(r.readFloat(), 1.5);
      expect(r.hasMore, isFalse);
    });
  });
}
