// These tests drive the lifecycle normally owned by MouseTracker.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RegistrationTest testCase;
  setUp(() async {
    testCase = _RegistrationTest();
    await testCase.setUp();
  });
  tearDown(() => testCase.tearDown());
  test(
      'activation waits for native creation', () => testCase.activationWaits());
  test('a disposed session never activates a late cursor',
      () => testCase.disposedSession());
  test('deletion waits for an in-flight creation',
      () => testCase.deletionWaits());
  test('native creation failure is an explicit error',
      () => testCase.creationFailure());
  test('unawaited activation reports native creation failure',
      () => testCase.activationFailure());
  test('disposed activation reports native creation failure',
      () => testCase.activationFailure(dispose: true));
  test('unawaited activation reports invalid image geometry',
      () => testCase.activationFailure(invalidGeometry: true));
}

class _RegistrationTest {
  static final channel = Platform.isWindows
      ? SystemChannels.mouseCursor
      : const MethodChannel('flutter_custom_cursor');
  final manager = CursorManager.instance;
  final calls = <String>[];
  final createCalled = Completer<void>();
  final nativeCreation = Completer<String>();
  late ui.Image image;

  Future<void> setUp() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    image = await picture.toImage(4, 4);
    picture.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method.split('/').first);
      if (calls.last == 'createCustomCursor') {
        createCalled.complete();
        return nativeCreation.future;
      }
      return null;
    });
  }

  void tearDown() {
    image.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<void> activationWaits() async {
    final registered = manager.registerCursorImage(
        name: 'ready', image: image, hotSpot: const ui.Offset(1, 2));
    final session =
        const FlutterCustomMemoryImageCursor(key: 'ready').createSession(1);
    final activated = session.activate();
    await createCalled.future;
    final before = List<String>.of(calls);
    nativeCreation.complete('ready');
    await registered;
    await activated;
    session.dispose();
    await manager.deleteCursor('ready');
    expect(before, ['createCustomCursor']);
    expect(
        calls, ['createCustomCursor', 'setCustomCursor', 'deleteCustomCursor']);
  }

  Future<void> disposedSession() async {
    final registered = manager.registerCursorImage(
        name: 'stale', image: image, hotSpot: ui.Offset.zero);
    final session =
        const FlutterCustomMemoryImageCursor(key: 'stale').createSession(1);
    final activated = session.activate();
    session.dispose();
    await createCalled.future;
    nativeCreation.complete('stale');
    await registered;
    await activated;
    await manager.deleteCursor('stale');
    expect(calls, ['createCustomCursor', 'deleteCustomCursor']);
  }

  Future<void> deletionWaits() async {
    final registered = manager.registerCursorImage(
        name: 'delete', image: image, hotSpot: ui.Offset.zero);
    final deleted = manager.deleteCursor('delete');
    await createCalled.future;
    final before = List<String>.of(calls);
    nativeCreation.complete('delete');
    await registered;
    await deleted;
    expect(before, ['createCustomCursor']);
    expect(calls, ['createCustomCursor', 'deleteCustomCursor']);
  }

  Future<void> creationFailure() async {
    final registered = manager.registerCursorImage(
        name: 'error', image: image, hotSpot: ui.Offset.zero);
    final assertion =
        expectLater(registered, throwsA(isA<PlatformException>()));
    await createCalled.future;
    nativeCreation.complete('');
    await assertion;
  }

  Future<void> activationFailure(
      {bool dispose = false, bool invalidGeometry = false}) async {
    const name = 'activation-error';
    const device = 1;
    final reports = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = reports.add;
    addTearDown(() => FlutterError.onError = previousHandler);
    final registered = manager.registerCursorImage(
        name: name,
        image: image,
        hotSpot: invalidGeometry
            ? ui.Offset(image.width.toDouble(), 0)
            : ui.Offset.zero);
    final session =
        const FlutterCustomMemoryImageCursor(key: name).createSession(device);
    addTearDown(session.dispose);
    unawaited(session.activate());
    if (dispose) session.dispose();
    if (!invalidGeometry) {
      await createCalled.future;
      nativeCreation.complete('');
    }
    // Drain activation's asynchronous continuation without awaiting its future.
    await Future<void>.delayed(Duration.zero);
    final report = reports.single;
    expect(report.exception,
        invalidGeometry ? isA<ArgumentError>() : isA<PlatformException>());
    expect(report.stack.toString(), isNotEmpty);
    expect(report.library, 'flutter_custom_cursor');
    expect(report.context?.toDescription(), contains(name));
    expect(report.silent, isFalse);
    await registered.then<void>((_) => fail('Registration must fail.'),
        onError: (Object error, StackTrace stack) {
      expect(error, same(report.exception));
      expect(stack, same(report.stack));
    });
    expect(calls, invalidGeometry ? isEmpty : ['createCustomCursor']);
  }
}
