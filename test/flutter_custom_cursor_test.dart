import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows
  ]) {
    test('$platform preserves the legacy buffer API', () async {
      debugDefaultTargetPlatformOverride = platform;
      final windows = platform == TargetPlatform.windows;
      final channel = windows
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
      final suffix = windows ? '/windows' : '';
      expect(calls.map((call) => call.method), [
        'createCustomCursor$suffix',
        'setCustomCursor$suffix',
        'deleteCustomCursor$suffix'
      ]);
      expect(calls.first.arguments, data.toJson());
      expect((calls.first.arguments as Map).containsKey('imagePixelRatio'),
          isFalse);
    });
  }
}
