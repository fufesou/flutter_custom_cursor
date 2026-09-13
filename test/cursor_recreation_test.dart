// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_custom_cursor/cursor_manager.dart';
import 'package:flutter_custom_cursor/flutter_custom_cursor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (waitForCreation, deletions) in [
    (false, 1),
    (true, 1),
    (true, 2)
  ]) {
    test('recreate after $deletions deletions, native pending=$waitForCreation',
        () async {
      final fixture = _RecreationTest();
      await fixture.prepare();
      try {
        await fixture.check(waitForCreation, deletions);
      } finally {
        await fixture.dispose();
      }
    });
  }
}

class _RecreationTest {
  static const name = 'recreated';
  final manager = CursorManager.instance;
  final calls = <String>[];
  final nativeNames = <String>{};
  final firstCreateEntered = Completer<void>();
  final firstCreate = Completer<void>();
  final laterCreates = Completer<void>();
  final channel = Platform.isWindows
      ? SystemChannels.mouseCursor
      : const MethodChannel('flutter_custom_cursor');
  late ui.Image image;

  Future<void> prepare() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    image = await picture.toImage(4, 4);
    picture.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
  }

  Future<dynamic> handle(MethodCall call) async {
    final key = call.arguments['name'] as String;
    switch (call.method.split('/').first) {
      case 'createCustomCursor':
        if (!firstCreateEntered.isCompleted) {
          firstCreateEntered.complete();
          await firstCreate.future;
        } else {
          await laterCreates.future;
        }
        calls.add('create');
        nativeNames.add(key);
        return key;
      case 'deleteCustomCursor':
        calls.add('delete');
        return nativeNames.remove(key);
      case 'setCustomCursor':
        final exists = nativeNames.contains(key);
        calls.add(exists ? 'set' : 'set-missing');
        return exists;
    }
    throw UnsupportedError('Unexpected call: ${call.method}');
  }

  Future<String> register() => manager.registerCursorImage(
      name: name, image: image, hotSpot: const ui.Offset(1, 2));

  Future<void> check(bool waitForCreation, int count) async {
    final first = register();
    final firstToken = manager.registrationTokenFor(name);
    if (waitForCreation) await firstCreateEntered.future;
    final deletions = <Future<void>>[];
    var replacement = first;
    for (var i = 0; i < count; i++) {
      deletions.add(manager.deleteCursor(name));
      replacement = register();
    }
    final token = manager.registrationTokenFor(name);
    final session =
        FlutterCustomMemoryImageCursor(key: name, registrationToken: token)
            .createSession(1);
    final activated = session.activate();
    firstCreate.complete();
    await first;
    await deletions.first;
    // The old completion must not clear the replacement's pending future/token.
    final duplicate = register();
    final tokenAfterDeletion = manager.registrationTokenFor(name);
    var ready = false;
    final registered =
        manager.ensureCursorRegistered(name).then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    final readyBeforeCreation = ready;
    laterCreates.complete();
    await Future.wait(
        [...deletions, replacement, duplicate, registered, activated]);
    session.dispose();
    expect(replacement, isNot(same(first)));
    expect(duplicate, same(replacement));
    expect(readyBeforeCreation, isFalse);
    expect(token, isNotNull);
    expect(token, isNot(same(firstToken)));
    expect(tokenAfterDeletion, same(token));
    expect(manager.registrationTokenFor(name), same(token));
    expect(nativeNames, contains(name));
    expect(calls, [
      'create',
      for (var i = 0; i < count; i++) ...['delete', 'create'],
      'set'
    ]);
  }

  Future<void> dispose() async {
    if (!firstCreate.isCompleted) firstCreate.complete();
    if (!laterCreates.isCompleted) laterCreates.complete();
    await manager.ensureCursorRegistered(name);
    await manager.deleteCursor(name);
    image.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}
