import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';

class FlutterCustomMemoryImageCursor extends MouseCursor {
  final String? key;
  const FlutterCustomMemoryImageCursor({this.key})
      : assert((key != null && key != ""));

  @override
  MouseCursorSession createSession(int device) =>
      _FlutterCustomMemoryImageCursorSession(this, device);

  @override
  String get debugDescription =>
      objectRuntimeType(this, 'FlutterCustomMemoryImageCursor');
}

class _FlutterCustomMemoryImageCursorSession extends MouseCursorSession {
  bool _disposed = false;

  _FlutterCustomMemoryImageCursorSession(
      FlutterCustomMemoryImageCursor cursor, int device)
      : super(cursor, device);

  @override
  FlutterCustomMemoryImageCursor get cursor =>
      super.cursor as FlutterCustomMemoryImageCursor;

  @override
  Future<void> activate() async {
    try {
      await CursorManager.instance
          .ensureCursorRegistered(cursor.key.toString());
    } catch (error, stackTrace) {
      // Flutter does not await activation, so report this error explicitly.
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'flutter_custom_cursor',
        context: ErrorDescription(
            'while registering cursor "${cursor.key}" for activation'),
      ));
      return;
    }
    // The pointer may have left this region while registration was pending.
    if (_disposed) return;
    await CursorManager.instance.setSystemCursor(cursor.key.toString());
  }

  @override
  void dispose() {
    _disposed = true;
  }
}
