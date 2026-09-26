import 'dart:typed_data';

import '../model/movie_data.dart';

/// Parses an SVG path `d` string into absolute verbs/points. Runs in the
/// background isolate (`ui.Path` cannot be built there), so the main isolate
/// only replays pre-parsed numbers.
///
/// Supports M L H V C S Q T A Z, absolute and relative, implicit repeats and
/// compact number syntax ("1.5.5", "1e-3", "10-5"). Lenient: a malformed tail
/// is dropped rather than failing the whole file.
PathData parseSvgPath(String d, int id) {
  final p = _SvgPathParser(d);
  try {
    p.run();
  } on FormatException {
    // Keep the well-formed prefix.
  }
  return PathData(id, Uint8List.fromList(p.verbs), Float32List.fromList(p.points));
}

final class _SvgPathParser {
  _SvgPathParser(this.s) : n = s.length;

  final String s;
  final int n;
  int i = 0;

  final List<int> verbs = [];
  final List<double> points = [];

  double cx = 0, cy = 0; // current point
  double sx = 0, sy = 0; // sub-path start
  double ctrlX = 0, ctrlY = 0; // last control point (for S / T)
  int last = 0; // lower-case code of previous command

  void run() {
    var cmd = 0;
    while (true) {
      _skipSeparators();
      if (i >= n) return;
      final c = s.codeUnitAt(i);
      if (_isCommand(c)) {
        cmd = c;
        i++;
      } else if (cmd == 0 || (cmd | 0x20) == 0x7a) {
        throw const FormatException('Unexpected token in path');
      } else if (cmd == 0x4d) {
        cmd = 0x4c; // implicit M -> L
      } else if (cmd == 0x6d) {
        cmd = 0x6c; // implicit m -> l
      }
      _segment(cmd);
    }
  }

  void _segment(int cmd) {
    final rel = cmd >= 0x61;
    final ox = rel ? cx : 0.0;
    final oy = rel ? cy : 0.0;
    final lower = cmd | 0x20;
    switch (lower) {
      case 0x6d: // m
        final x = _num() + ox, y = _num() + oy;
        verbs.add(PathData.moveTo);
        points
          ..add(x)
          ..add(y);
        cx = sx = x;
        cy = sy = y;
      case 0x6c: // l
        final x = _num() + ox, y = _num() + oy;
        _lineTo(x, y);
      case 0x68: // h
        _lineTo(_num() + ox, cy);
      case 0x76: // v
        _lineTo(cx, _num() + oy);
      case 0x63: // c
        final x1 = _num() + ox, y1 = _num() + oy;
        final x2 = _num() + ox, y2 = _num() + oy;
        final x = _num() + ox, y = _num() + oy;
        _cubic(x1, y1, x2, y2, x, y);
      case 0x73: // s
        final smooth = last == 0x63 || last == 0x73;
        final x1 = smooth ? 2 * cx - ctrlX : cx;
        final y1 = smooth ? 2 * cy - ctrlY : cy;
        final x2 = _num() + ox, y2 = _num() + oy;
        final x = _num() + ox, y = _num() + oy;
        _cubic(x1, y1, x2, y2, x, y);
      case 0x71: // q
        final x1 = _num() + ox, y1 = _num() + oy;
        final x = _num() + ox, y = _num() + oy;
        _quad(x1, y1, x, y);
      case 0x74: // t
        final smooth = last == 0x71 || last == 0x74;
        final x1 = smooth ? 2 * cx - ctrlX : cx;
        final y1 = smooth ? 2 * cy - ctrlY : cy;
        final x = _num() + ox, y = _num() + oy;
        _quad(x1, y1, x, y);
      case 0x61: // a
        final rx = _num().abs(), ry = _num().abs(), rot = _num();
        final large = _flag(), sweep = _flag();
        final x = _num() + ox, y = _num() + oy;
        verbs.add(PathData.arcTo);
        points.addAll([x, y, rx, ry, rot, large ? 1.0 : 0.0, sweep ? 1.0 : 0.0]);
        cx = x;
        cy = y;
      case 0x7a: // z
        verbs.add(PathData.close);
        cx = sx;
        cy = sy;
    }
    if (lower != 0x63 && lower != 0x73 && lower != 0x71 && lower != 0x74) {
      ctrlX = cx;
      ctrlY = cy;
    }
    last = lower;
  }

  void _lineTo(double x, double y) {
    verbs.add(PathData.lineTo);
    points
      ..add(x)
      ..add(y);
    cx = x;
    cy = y;
  }

  void _cubic(double x1, double y1, double x2, double y2, double x, double y) {
    verbs.add(PathData.cubicTo);
    points.addAll([x1, y1, x2, y2, x, y]);
    ctrlX = x2;
    ctrlY = y2;
    cx = x;
    cy = y;
  }

  void _quad(double x1, double y1, double x, double y) {
    verbs.add(PathData.quadTo);
    points.addAll([x1, y1, x, y]);
    ctrlX = x1;
    ctrlY = y1;
    cx = x;
    cy = y;
  }

  static bool _isCommand(int c) => switch (c | 0x20) {
        0x6d || 0x6c || 0x68 || 0x76 || 0x63 || 0x73 || 0x71 || 0x74 || 0x61 || 0x7a => true,
        _ => false,
      };

  void _skipSeparators() {
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x2c || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c) {
        i++;
      } else {
        break;
      }
    }
  }

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  double _num() {
    _skipSeparators();
    final start = i;
    if (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x2b || c == 0x2d) i++;
    }
    var digits = false, dot = false;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (_digit(c)) {
        digits = true;
        i++;
      } else if (c == 0x2e && !dot) {
        dot = true;
        i++;
      } else {
        break;
      }
    }
    if (!digits) {
      i = start;
      throw const FormatException('Expected number');
    }
    if (i < n && (s.codeUnitAt(i) | 0x20) == 0x65) {
      var j = i + 1;
      if (j < n && (s.codeUnitAt(j) == 0x2b || s.codeUnitAt(j) == 0x2d)) j++;
      if (j < n && _digit(s.codeUnitAt(j))) {
        i = j;
        while (i < n && _digit(s.codeUnitAt(i))) {
          i++;
        }
      }
    }
    var text = s.substring(start, i);
    if (text.endsWith('.')) text = '${text}0';
    return double.parse(text);
  }

  bool _flag() {
    _skipSeparators();
    if (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x30 || c == 0x31) {
        i++;
        return c == 0x31;
      }
    }
    throw const FormatException('Expected arc flag');
  }
}
