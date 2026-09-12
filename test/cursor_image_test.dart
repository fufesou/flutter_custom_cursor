import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_custom_cursor/src/cursor_image.dart';

Future<ui.Image> cursorImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 7, 19),
      ui.Paint()..color = const ui.Color(0x80402010));
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(7, 19);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows
  ]) {
    for (final dpr in [1.0, 1.25, 2.0]) {
      test('$platform DPR $dpr preserves the full image and hotspot',
          () => _checkImageCase(platform, dpr));
      test('$platform DPR $dpr keeps thin cursor axes and hotspots valid',
          () => _checkThinCursor(platform, dpr));
    }
  }
  test('rejects invalid scales and source hotspots', _rejectInvalidGeometry);
  test('owns an image handle while asynchronous encoding is in progress',
      _retainImage);
}

Future<void> _checkThinCursor(TargetPlatform platform, double dpr) async {
  const longEdge = 64;
  const minimumSize = 12;
  for (final (width, height) in [(2, longEdge), (longEdge, 2)]) {
    final image = await createTestImage(width: width, height: height);
    addTearDown(image.dispose);
    final args = await encodeCursorImage(
      name: 'thin',
      image: image,
      hotSpot: ui.Offset((width - 1).toDouble(), (height - 1).toDouble()),
      scale: minimumSize / longEdge,
      devicePixelRatio: dpr,
      platform: platform,
    );
    final linux = platform == TargetPlatform.linux;
    final ratio = linux ? dpr.ceilToDouble() : dpr;
    final shortSide = linux ? ratio.toInt() : 1;
    final longSide = (minimumSize * ratio).round();
    final rasterWidth = width == longEdge ? longSide : shortSide;
    final rasterHeight = height == longEdge ? longSide : shortSide;
    expect(args['width'], linux ? longSide : rasterWidth);
    expect(args['height'], rasterHeight);
    for (final (key, pixels, source) in [
      ('hotX', rasterWidth, width),
      ('hotY', rasterHeight, height)
    ]) {
      final value = args[key] as double;
      expect(value, inInclusiveRange(0, pixels - (linux ? ratio : 0.0)));
      if (source == 2) {
        expect(value, platform == TargetPlatform.macOS ? 0.5 : 0.0);
      }
    }
  }
}

Future<void> _checkImageCase(TargetPlatform platform, double dpr) async {
  final image = await cursorImage();
  addTearDown(image.dispose);
  final args = await encodeCursorImage(
    name: 'edit',
    image: image,
    hotSpot: const ui.Offset(3, 17),
    scale: 0.75,
    devicePixelRatio: dpr,
    platform: platform,
  );
  final linux = platform == TargetPlatform.linux;
  final ratio = linux ? dpr.ceilToDouble() : dpr;
  final width = linux ? 5 * ratio.toInt() : (7 * 0.75 * dpr).round();
  final height = linux ? 14 * ratio.toInt() : (19 * 0.75 * dpr).round();
  expect(args['width'], linux ? height : width);
  expect(args['height'], height);
  final hotX = 3 * width / 7;
  final hotY = 17 * height / 19;
  if (linux) {
    expect(args['hotX'], (hotX / ratio).round() * ratio);
    expect(args['hotY'], (hotY / ratio).round() * ratio);
  } else if (platform == TargetPlatform.windows) {
    expect(args['hotX'], hotX.roundToDouble());
    expect(args['hotY'], hotY.roundToDouble());
  } else {
    expect(args['hotX'], hotX);
    expect(args['hotY'], hotY);
  }
  expect(args['imagePixelRatio'], ratio);
  await _checkPixels(args, platform);
}

Future<void> _checkPixels(
    Map<String, dynamic> args, TargetPlatform platform) async {
  final bytes = args['buffer'] as Uint8List;
  final width = args['width'] as int;
  final height = args['height'] as int;
  final linux = platform == TargetPlatform.linux;
  if (platform == TargetPlatform.windows) {
    expect(bytes.length, width * height * 4);
    expect(bytes.sublist(0, 4), [0x10, 0x20, 0x40, 0x80]);
    expect(bytes.sublist(bytes.length - 4), [0x10, 0x20, 0x40, 0x80]);
  } else {
    final codec = await ui.instantiateImageCodec(bytes);
    final decoded = (await codec.getNextFrame()).image;
    codec.dispose();
    addTearDown(decoded.dispose);
    expect(decoded.width, args['width']);
    expect(decoded.height, args['height']);
    final rgba =
        await decoded.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final bottom = ((height - 1) * decoded.width) * 4;
    expect(rgba!.buffer.asUint8List(bottom, 4), [0x40, 0x20, 0x10, 0x80]);
    if (linux) {
      final padding = (decoded.width - 1) * 4;
      expect(rgba.buffer.asUint8List(padding, 4), [0, 0, 0, 0]);
    }
  }
}

Future<void> _rejectInvalidGeometry() async {
  final image = await cursorImage();
  addTearDown(image.dispose);
  for (final scale in [0.0, -1.0, double.nan, double.infinity]) {
    await expectLater(
        encodeCursorImage(
            name: 'bad',
            image: image,
            hotSpot: ui.Offset.zero,
            scale: scale,
            devicePixelRatio: 1,
            platform: TargetPlatform.macOS),
        throwsArgumentError);
  }
  await expectLater(
      encodeCursorImage(
          name: 'bad',
          image: image,
          hotSpot: const ui.Offset(7, 0),
          scale: 1,
          devicePixelRatio: 1,
          platform: TargetPlatform.windows),
      throwsArgumentError);
}

Future<void> _retainImage() async {
  final image = await cursorImage();
  final encoding = encodeCursorImage(
      name: 'owned',
      image: image,
      hotSpot: ui.Offset.zero,
      scale: 1,
      devicePixelRatio: 2,
      platform: TargetPlatform.macOS);
  image.dispose();
  expect((await encoding)['height'], 38);
}
