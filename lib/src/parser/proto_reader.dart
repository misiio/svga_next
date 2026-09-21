import 'dart:convert';
import 'dart:typed_data';

/// Minimal protobuf wire-format reader.
///
/// `package:protobuf` generated classes materialise a full object tree (a
/// GeneratedMessage + FieldSet for every frame of every sprite). For a
/// 200-frame, 40-sprite gift that is tens of thousands of short-lived objects
/// and the main source of GC pressure in flutter_svga. This reader streams
/// fields directly into compact typed arrays, so there is no protobuf tree to
/// purge in the first place.
final class ProtoReader {
  ProtoReader(Uint8List buffer)
      : this._(buffer, ByteData.sublistView(buffer), 0, buffer.length);

  ProtoReader._(this._buf, this._view, this._pos, this._end);

  final Uint8List _buf;
  final ByteData _view;
  int _pos;
  final int _end;

  bool get hasMore => _pos < _end;

  int readTag() => readVarint();

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) throw const FormatException('Truncated varint');
      final b = _buf[_pos++];
      if (shift < 64) result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 70) throw const FormatException('Malformed varint');
    }
  }

  int readInt32() => readVarint().toSigned(32);

  double readFloat() {
    _need(4);
    final v = _view.getFloat32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  /// Zero-copy view into the underlying buffer.
  Uint8List readBytesView() {
    final len = readVarint();
    _need(len);
    final v = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return v;
  }

  String readString() {
    final len = readVarint();
    if (len == 0) return '';
    _need(len);
    final s = utf8.decode(Uint8List.sublistView(_buf, _pos, _pos + len), allowMalformed: true);
    _pos += len;
    return s;
  }

  /// Reader over an embedded (length-delimited) message.
  ProtoReader sub() {
    final len = readVarint();
    _need(len);
    final r = ProtoReader._(_buf, _view, _pos, _pos + len);
    _pos += len;
    return r;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _need(8);
        _pos += 8;
      case 2:
        final len = readVarint();
        _need(len);
        _pos += len;
      case 5:
        _need(4);
        _pos += 4;
      default:
        throw FormatException('Unsupported wire type $wireType');
    }
  }

  void _need(int n) {
    if (n < 0 || _pos + n > _end) throw const FormatException('Truncated message');
  }
}
