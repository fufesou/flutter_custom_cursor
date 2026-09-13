import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'src/cursor_image.dart';

class CursorData {
  late String name;
  late Uint8List buffer;
  late double hotX;
  late double hotY;
  late int width;
  late int height;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'buffer': buffer,
      'hotX': hotX,
      'hotY': hotY,
      'width': width,
      'height': height
    };
  }
}

/// The cursor manager
class CursorManager {
  static const channel = SystemChannels.mouseCursor;
  static const createCursorKey = "createCustomCursor";
  static const setCursorMethod = "setCustomCursor";
  static const deleteCursorMethod = "deleteCustomCursor";

  CursorManager._();
  static CursorManager instance = CursorManager._();
  // Encoding runs before the platform call. Channel FIFO alone cannot order
  // activation or deletion against an image whose encoding is still pending.
  final _pendingImages = <String, Future<String>>{};
  final _pendingDeletions = <String, Future<void>>{};
  final _registrationTokens = <String, Object>{};

  /// Stable for an image registration; a retry after failure gets a new token.
  Object? registrationTokenFor(String name) => _registrationTokens[name];

  /// Registers [image] at [scale] logical pixels per source pixel.
  /// [hotSpot] is in source pixels; [devicePixelRatio] is the controller view's
  /// current DPR. Artwork and hotspot are scaled together. GTK quantizes the
  /// result to logical pixels; Windows quantizes to physical pixels.
  /// Use a different [name] whenever the image, scale or DPR changes.
  Future<String> registerCursorImage({
    required String name,
    required ui.Image image,
    required ui.Offset hotSpot,
    double scale = 1,
    double devicePixelRatio = 1,
  }) {
    final pending = _pendingImages[name];
    if (pending != null) return pending;
    final deletion = _pendingDeletions[name];
    late final Future<String> registration;
    registration = encodeCursorImage(
            name: name,
            image: image,
            hotSpot: hotSpot,
            scale: scale,
            devicePixelRatio: devicePixelRatio,
            platform: switch (Platform.operatingSystem) {
              'macos' => TargetPlatform.macOS,
              'linux' => TargetPlatform.linux,
              'windows' => TargetPlatform.windows,
              _ =>
                throw UnsupportedError('Image cursors require a desktop OS.'),
            })
        .then((arguments) async {
      await deletion;
      final cursorName = await _getMethodChannel()
          .invokeMethod<String>(_getMethod(createCursorKey), arguments);
      if (cursorName != name) {
        throw PlatformException(
            code: 'cursor_creation_failed',
            message: 'The native backend did not register cursor $name.');
      }
      return name;
    }).catchError((Object error, StackTrace stack) {
      if (identical(_pendingImages[name], registration)) {
        _registrationTokens.remove(name);
      }
      Error.throwWithStackTrace(error, stack);
    }).whenComplete(() {
      if (identical(_pendingImages[name], registration)) {
        _pendingImages.remove(name);
      }
    });
    _registrationTokens[name] = Object();
    _pendingImages[name] = registration;
    return registration;
  }

  /// Waits for image encoding and native creation, if still in progress.
  Future<void> ensureCursorRegistered(String name) async {
    await _pendingImages[name];
  }

  /// [Note]
  /// The documentation from `engine/shell/platform/cursor_handler.cc`.
  ///
  /// // This method allows creating a custom cursor with rawBGRA buffer, returns a
  /// string to identify the cursor.
  ///
  /// static constexpr char kCreateCustomCursorMethod[] =
  ///     "createCustomCursor/windows";
  ///
  /// // A string, the custom cursor's name.
  ///
  /// static constexpr char kCustomCursorNameKey[] = "name";
  ///
  /// // A list of bytes, the custom cursor's rawBGRA buffer.
  ///
  /// static constexpr char kCustomCursorBufferKey[] = "buffer";
  ///
  /// // A double, the x coordinate of the custom cursor's hotspot, starting from
  /// left.
  ///
  /// static constexpr char kCustomCursorHotXKey[] = "hotX";
  ///
  /// // A double, the y coordinate of the custom cursor's hotspot, starting from top.
  ///
  /// static constexpr char kCustomCursorHotYKey[] = "hotY";
  ///
  /// // An int value for the width of the custom cursor.
  ///
  /// static constexpr char kCustomCursorWidthKey[] = "width";
  ///
  /// // An int value for the height of the custom cursor.
  ///
  /// static constexpr char kCustomCursorHeightKey[] = "height";
  ///
  /// // This method allows setting a custom cursor with a unique int64_t key of the
  /// custom cursor.
  ///
  /// static constexpr char kSetCustomCursorMethod[] = "setCustomCursor/windows";
  ///
  /// This method allows deleting a custom cursor with a string key.
  ///
  /// static constexpr char kDeleteCustomCursorMethod[] =
  ///     "deleteCustomCursor/windows";
  Future<String> registerCursor(CursorData data) async {
    final cursorName = await _getMethodChannel()
        .invokeMethod<String>(_getMethod(createCursorKey), data.toJson());
    assert(cursorName == data.name);
    return cursorName!;
  }

  Future<void> deleteCursor(String name) {
    // Detach this generation now. A later registration must wait for deletion
    // and create a new cursor, rather than reuse the image being deleted.
    final registration = _pendingImages.remove(name);
    final previousDeletion = _pendingDeletions[name];
    _registrationTokens.remove(name);
    late final Future<void> deletion;
    deletion = Future.wait([
      if (registration != null) registration,
      if (previousDeletion != null) previousDeletion,
    ]).then<void>((_) async {
      await _getMethodChannel()
          .invokeMethod(_getMethod(deleteCursorMethod), {"name": name});
    }).whenComplete(() {
      if (identical(_pendingDeletions[name], deletion)) {
        _pendingDeletions.remove(name);
      }
    });
    _pendingDeletions[name] = deletion;
    return deletion;
  }

  Future<void> setSystemCursor(String name) async {
    await _getMethodChannel()
        .invokeMethod(_getMethod(setCursorMethod), {"name": name});
  }

  MethodChannel _getMethodChannel() {
    if (Platform.isWindows) {
      return SystemChannels.mouseCursor;
    } else {
      return const MethodChannel('flutter_custom_cursor');
    }
  }

  String _getMethod(String method) {
    if (Platform.isWindows) {
      return "$method/windows";
    } else {
      return method;
    }
  }
}
