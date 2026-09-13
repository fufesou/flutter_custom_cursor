import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';
import 'package:flutter_test/flutter_test.dart';

enum _Target { outside, text, remote, otherDevice }

void main() {
  for (final target in _Target.values) {
    testWidgets(
        'pending cursor registration after pointer exit: $target',
        (tester) => tester.runAsync(() async {
              final testCase = _PointerRemovalTest();
              await testCase.setUp(tester);
              try {
                await testCase.check(tester, target);
              } finally {
                await testCase.tearDown(tester);
              }
            }));
  }
}

class _PointerRemovalTest {
  static const name = 'pointer-removal';
  static const remotePosition = Offset(100, 100);
  static const textPosition = Offset(600, 100);
  static const device = 1;
  static const otherDevice = 2;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final manager = CursorManager.instance;
  final pointer = TestPointer(device, ui.PointerDeviceKind.mouse, device);
  final created = Completer<void>();
  final nativeCreation = Completer<String>();
  final calls = <String>[];
  final channel = Platform.isWindows
      ? SystemChannels.mouseCursor
      : const MethodChannel('flutter_custom_cursor');
  late ui.Image image;
  late Future<String> registration;
  late int routeCount;

  Future<void> setUp(WidgetTester tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    image = await picture.toImage(4, 4);
    picture.dispose();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handleCall);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.mouseCursor, _handleCall);
    routeCount = binding.pointerRouter.debugGlobalRouteCount;
    registration = manager.registerCursorImage(
        name: name, image: image, hotSpot: ui.Offset.zero);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Row(children: [
        _region(FlutterCustomMemoryImageCursor(
            key: name, registrationToken: manager.registrationTokenFor(name))),
        _region(SystemMouseCursors.text),
      ]),
    ));
  }

  Widget _region(MouseCursor cursor) => Expanded(
      child: MouseRegion(cursor: cursor, child: const SizedBox.expand()));

  Future<dynamic> _handleCall(MethodCall call) async {
    final method = call.method.split('/').first;
    if (method == 'createCustomCursor') {
      created.complete();
      return nativeCreation.future;
    }
    if (method == 'setCustomCursor') calls.add('custom');
    if (method == 'activateSystemCursor') {
      calls.add(call.arguments['kind'] as String);
    }
    return null;
  }

  Future<void> check(WidgetTester tester, _Target target) async {
    await tester
        .sendEventToBinding(pointer.addPointer(location: remotePosition));
    await tester.pump();
    await created.future;
    if (target == _Target.otherDevice) {
      final other =
          TestPointer(otherDevice, ui.PointerDeviceKind.mouse, otherDevice);
      await tester.sendEventToBinding(other.addPointer(location: textPosition));
      await tester.sendEventToBinding(other.removePointer());
    } else {
      await tester.sendEventToBinding(pointer.removePointer());
      expect(binding.mouseTracker.debugDeviceActiveCursor(device), isNull);
      if (target != _Target.outside) {
        await tester.sendEventToBinding(pointer.addPointer(
            location: target == _Target.text ? textPosition : remotePosition));
      }
    }
    await tester.pump();
    nativeCreation.complete(name);
    await registration;
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
    final shouldActivate =
        target == _Target.remote || target == _Target.otherDevice;
    expect(calls.where((call) => call == 'custom'),
        hasLength(shouldActivate ? 1 : 0));
    expect(binding.pointerRouter.debugGlobalRouteCount, routeCount);
    if (target == _Target.text || target == _Target.remote) {
      final before = List<String>.of(calls);
      final position = target == _Target.text ? textPosition : remotePosition;
      for (final dx in [1.0, 2.0, 3.0]) {
        await tester
            .sendEventToBinding(pointer.hover(position + Offset(dx, 0)));
        await tester.pump();
      }
      expect(calls, before);
      expect(calls.last, target == _Target.text ? 'text' : 'custom');
    }
  }

  Future<void> tearDown(WidgetTester tester) async {
    if (!nativeCreation.isCompleted) nativeCreation.complete(name);
    await registration;
    await tester.pumpWidget(const SizedBox());
    await manager.deleteCursor(name);
    image.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.mouseCursor, null);
  }
}
