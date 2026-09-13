import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('unchanged keys retain the active mouse cursor session', () async {
    final channel = Platform.isWindows
        ? SystemChannels.mouseCursor
        : const MethodChannel('flutter_custom_cursor');
    final activated = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method.split('/').first, 'setCustomCursor');
      activated.add(call.arguments['name'] as String);
      return null;
    });
    addTearDown(() => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final mouse = MouseCursorManager(SystemMouseCursors.basic);
    for (final key in ['first', 'first', 'first', 'second', 'second', 'first']) {
      // Rebuilds create distinct objects for the same already-registered bitmap.
      mouse.handleDeviceCursorUpdate(
          1, null, [FlutterCustomMemoryImageCursor(key: key)]);
      await Future<void>.delayed(Duration.zero);
    }
    expect(activated, ['first', 'second', 'first']);
  });
  test('legacy buffer calls keep the native OS channel and units', () async {
    debugDefaultTargetPlatformOverride =
        Platform.isWindows ? TargetPlatform.macOS : TargetPlatform.windows;
    final channel = Platform.isWindows
        ? SystemChannels.mouseCursor
        : const MethodChannel('flutter_custom_cursor');
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return call.method.startsWith('createCustomCursor') ? 'legacy' : null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    final data = CursorData()
      ..name = 'legacy'
      ..buffer = Uint8List(4)
      ..width = 1
      ..height = 1
      ..hotX = 0
      ..hotY = 0;
    final manager = CursorManager.instance;
    expect(await manager.registerCursor(data), 'legacy');
    await manager.setSystemCursor('legacy');
    await manager.deleteCursor('legacy');
    final suffix = Platform.isWindows ? '/windows' : '';
    expect(calls.map((call) => call.method), [
      'createCustomCursor$suffix',
      'setCustomCursor$suffix',
      'deleteCustomCursor$suffix'
    ]);
    expect(calls.first.arguments, data.toJson());
  });
}
