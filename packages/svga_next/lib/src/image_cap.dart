import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

/// The size that brings the longest side of a [width]x[height] image down to
/// [maxDimension] pixels, keeping its aspect ratio, or `null` when the image
/// already fits or there is no cap.
({int width, int height})? cappedSize(
    int width, int height, int? maxDimension) {
  if (maxDimension == null) return null;
  final longest = math.max(width, height);
  if (longest <= maxDimension) return null;
  final scale = maxDimension / longest;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// A clone of [image], downscaled when its longest side exceeds
/// [maxDimension]. Synchronous when it fits.
FutureOr<ui.Image> cappedClone(ui.Image image, int? maxDimension) {
  final size = cappedSize(image.width, image.height, maxDimension);
  if (size == null) return image.clone();
  return downscale(image.clone(), size.width, size.height);
}

/// Redraws [image] at [width]x[height] and disposes it.
Future<ui.Image> downscale(ui.Image image, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
    image.dispose();
  }
}
