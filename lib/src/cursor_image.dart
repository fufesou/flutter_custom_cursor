import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

// GTK uses integer logical cursor dimensions and an integer buffer scale.
// Returned hotspots are in buffer pixels; macOS and GTK convert them to logical
// coordinates using imagePixelRatio. Always derive them from the rounded raster.
Future<Map<String, dynamic>> encodeCursorImage({
  required String name,
  required ui.Image image,
  required ui.Offset hotSpot,
  required double scale,
  required double devicePixelRatio,
  required TargetPlatform platform,
}) async {
  _validateGeometry(
      image: image,
      hotSpot: hotSpot,
      scale: scale,
      devicePixelRatio: devicePixelRatio);
  final linux = platform == TargetPlatform.linux;
  final ratio = linux ? devicePixelRatio.ceilToDouble() : devicePixelRatio;
  // A thin axis must survive rounding, including GTK's logical-pixel rounding
  // before applying the buffer scale. Hotspots below use these actual dimensions.
  const minRasterSize = 1;
  int pixels(int value) => linux
      ? math.max(minRasterSize, (value * scale).round()) * ratio.toInt()
      : math.max(minRasterSize, (value * scale * ratio).round());
  final width = pixels(image.width);
  final height = pixels(image.height);
  final ownedImage = image.clone();
  final bufferWidth = linux ? math.max(width, height) : width;
  try {
    final raster = await _rasterize(
        image: ownedImage,
        width: width,
        height: height,
        bufferWidth: bufferWidth);
    try {
      return <String, dynamic>{
        'name': name,
        'buffer': await _encode(raster, platform),
        'width': bufferWidth,
        'height': height,
        'hotX': _hotspot(hotSpot.dx * width / image.width,
            pixels: width, ratio: ratio, platform: platform),
        'hotY': _hotspot(hotSpot.dy * height / image.height,
            pixels: height, ratio: ratio, platform: platform),
        'imagePixelRatio': ratio,
      };
    } finally {
      raster.dispose();
    }
  } finally {
    ownedImage.dispose();
  }
}

void _validateGeometry(
    {required ui.Image image,
    required ui.Offset hotSpot,
    required double scale,
    required double devicePixelRatio}) {
  if (!scale.isFinite ||
      scale <= 0 ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0) {
    throw ArgumentError(
        'Cursor scale and devicePixelRatio must be positive and finite.');
  }
  if (!hotSpot.dx.isFinite ||
      !hotSpot.dy.isFinite ||
      hotSpot.dx < 0 ||
      hotSpot.dy < 0 ||
      hotSpot.dx >= image.width ||
      hotSpot.dy >= image.height) {
    throw ArgumentError.value(
        hotSpot, 'hotSpot', 'Must be inside the source image.');
  }
}

double _hotspot(double value,
    {required int pixels,
    required double ratio,
    required TargetPlatform platform}) {
  if (platform == TargetPlatform.linux) {
    return math.min((value / ratio).round(), pixels ~/ ratio - 1) * ratio;
  }
  if (platform == TargetPlatform.windows) {
    return math.min(value.round(), pixels - 1).toDouble();
  }
  return value;
}

Future<ui.Image> _rasterize(
    {required ui.Image image,
    required int width,
    required int height,
    required int bufferWidth}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // Keep tall Linux cursors complete on hardware cursor planes by padding
  // the right edge with transparency, without stretching or moving the art.
  canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(bufferWidth, height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _encode(ui.Image image, TargetPlatform platform) async {
  final windows = platform == TargetPlatform.windows;
  final data = await image.toByteData(
      format: windows
          ? ui.ImageByteFormat.rawStraightRgba
          : ui.ImageByteFormat.png);
  if (data == null) {
    throw StateError('Could not encode the cursor image.');
  }
  final buffer = Uint8List.sublistView(data);
  if (windows) {
    const channels = 4;
    const blue = 2;
    for (var offset = 0; offset < buffer.length; offset += channels) {
      final red = buffer[offset];
      buffer[offset] = buffer[offset + blue];
      buffer[offset + blue] = red;
    }
  }
  return buffer;
}
