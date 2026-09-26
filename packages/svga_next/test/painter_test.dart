import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:svga_next/src/model/movie_data.dart';
import 'package:svga_next/src/movie/svga_movie.dart';
import 'package:svga_next/src/player/svga_controller.dart';
import 'package:svga_next/src/player/svga_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bitmap matte keeps content only where the mask has alpha', () {
    test('mask bitmap stored without the .matte suffix', () async {
      final pixels = await _renderMatte({
        'content': await _image(const ui.Color(0xffff0000), 4),
        'mask': await _image(const ui.Color(0xffffffff), 2),
      });
      _expectLeftHalfRed(pixels);
    });

    test('mask bitmap stored under the full .matte key', () async {
      final pixels = await _renderMatte({
        'content': await _image(const ui.Color(0xffff0000), 4),
        'mask.matte': await _image(const ui.Color(0xffffffff), 2),
      });
      _expectLeftHalfRed(pixels);
    });

    test('exact .matte key wins over the stripped key', () async {
      final pixels = await _renderMatte({
        'content': await _image(const ui.Color(0xffff0000), 4),
        'mask': await _image(const ui.Color(0xffffffff), 4),
        'mask.matte': await _image(const ui.Color(0xffffffff), 2),
      });
      _expectLeftHalfRed(pixels);
    });
  });
}

Future<Uint8List> _renderMatte(Map<String, ui.Image> images) async {
  final movie = SvgaMovie.fromDecoded(
    MovieData(
      version: '2.0',
      viewBoxWidth: 4,
      viewBoxHeight: 2,
      fps: 20,
      frameCount: 1,
      sprites: [
        _sprite('mask.matte'),
        _sprite('content', matteKey: 'mask.matte'),
      ],
      audios: [],
      images: {},
      audioBytes: {},
      pathCount: 0,
    ),
    images,
  );
  addTearDown(movie.release);
  final controller = SvgaController(vsync: const TestVSync())..movie = movie;
  addTearDown(controller.dispose);

  final recorder = ui.PictureRecorder();
  SvgaPainter(controller: controller, filterQuality: ui.FilterQuality.none)
      .paint(ui.Canvas(recorder), const ui.Size(4, 2));
  final picture = recorder.endRecording();
  addTearDown(picture.dispose);
  final rendered = await picture.toImage(4, 2);
  addTearDown(rendered.dispose);
  return (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
}

void _expectLeftHalfRed(Uint8List pixels) {
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 4; x++) {
      final offset = (y * 4 + x) * 4;
      expect(
        pixels.sublist(offset, offset + 4),
        x < 2 ? [255, 0, 0, 255] : [0, 0, 0, 0],
        reason: 'pixel ($x, $y)',
      );
    }
  }
}

SpriteData _sprite(String key, {String? matteKey}) => SpriteData(
      imageKey: key,
      matteKey: matteKey,
      track: FrameTrack(
        length: 1,
        values: Float32List.fromList([1, 0, 0, 4, 2, 1, 0, 0, 1, 0, 0]),
        clips: null,
        shapes: null,
        firstVisible: 0,
        lastVisible: 0,
      ),
    );

Future<ui.Image> _image(ui.Color color, double opaqueWidth) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, opaqueWidth, 2),
    ui.Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(4, 2);
  } finally {
    picture.dispose();
  }
}
