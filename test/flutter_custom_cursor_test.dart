import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
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
