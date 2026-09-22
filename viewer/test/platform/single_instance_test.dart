/// One viewer per user and settings root (viewer/spec.md 3.1).
///
/// The activation channel is a real loopback socket but the settings root is a
/// throwaway directory under the system temp directory, so these cases cannot
/// lock, activate or delete anything that belongs to a running viewer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/data/settings_store.dart' show joinViewerPath;
import 'package:tasks_viewer/platform/single_instance.dart';

late Directory _root;

Directory _newRoot(String name) {
  final directory = Directory.systemTemp.createTempSync('viewer-$name-');
  addTearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });
  return directory;
}

String _lockPath(String settingsRoot) =>
    joinViewerPath(settingsRoot, ViewerSingleInstance.lockFileName);

String _portPath(String settingsRoot) =>
    joinViewerPath(settingsRoot, ViewerSingleInstance.portFileName);

void main() {
  setUp(() {
    _root = _newRoot('instance');
  });

  test(
    'the first claim owns the slot and publishes its activation port',
    () async {
      final claim = await ViewerInstance.claim(
        settingsRoot: _root.path,
        onActivate: () async {},
      );
      addTearDown(() => claim.instance!.dispose());

      expect(claim.isPrimary, isTrue);
      final instance = claim.instance!;
      expect(instance.port, greaterThan(0));
      expect(instance.settingsRoot, _root.path);
      expect(File(instance.lockPath).existsSync(), isTrue);
      expect(File(instance.portPath).existsSync(), isTrue);

      final document =
          jsonDecode(File(instance.portPath).readAsStringSync())
              as Map<String, Object?>;
      expect(document['port'], instance.port);
      expect(document['pid'], isA<int>());
    },
  );

  test(
    'a second launch activates the owner instead of opening a window',
    () async {
      final activated = Completer<void>();
      final primary = await ViewerInstance.claim(
        settingsRoot: _root.path,
        onActivate: () async {
          if (!activated.isCompleted) {
            activated.complete();
          }
        },
      );
      addTearDown(() => primary.instance!.dispose());

      final second = await ViewerInstance.claim(
        settingsRoot: _root.path,
        onActivate: () async {},
      );
      expect(second.isPrimary, isFalse);
      expect(second.instance, isNull);
      await activated.future.timeout(const Duration(seconds: 5));
    },
  );

  test('a burst of launches runs one activation at a time', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
    var running = 0;
    var peak = 0;
    var activations = 0;

    final primary = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {
        running += 1;
        peak = math.max(peak, running);
        activations += 1;
        if (!started.isCompleted) {
          started.complete();
        }
        await release.future;
        running -= 1;
      },
    );
    addTearDown(() => primary.instance!.dispose());

    // Both ring the running window while the first activation is still busy.
    await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    await started.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(peak, 1, reason: 'a burst must not stack activations');
    expect(activations, 1, reason: 'a burst coalesces into one activation');
    release.complete();
  });

  test(
    'a lock whose owner never answered is cleared once, then reported',
    () async {
      // An owner crashed after taking the lock but before publishing its port.
      File(_lockPath(_root.path)).writeAsStringSync('');
      final claim = await ViewerInstance.claim(
        settingsRoot: _root.path,
        onActivate: () async {},
        staleWait: const Duration(milliseconds: 150),
        retryDelay: const Duration(milliseconds: 20),
      );
      addTearDown(() => claim.instance!.dispose());
      expect(claim.isPrimary, isTrue);
    },
  );

  test(
    'a lock that cannot be cleared fails instead of opening a second window',
    () async {
      // A directory can never be removed by the stale-lock path, so the claim
      // must stop with a message rather than risk two windows on one backlog.
      Directory(_lockPath(_root.path)).createSync(recursive: true);
      await expectLater(
        ViewerInstance.claim(
          settingsRoot: _root.path,
          onActivate: () async {},
          staleWait: const Duration(milliseconds: 100),
          retryDelay: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<ViewerInstanceUnavailable>().having(
            (error) => error.message,
            'message',
            contains('did not answer'),
          ),
        ),
      );
    },
  );

  test('a stale activation document never blocks a new owner', () async {
    File(_portPath(_root.path)).writeAsStringSync(
      jsonEncode(<String, Object?>{'port': 1, 'pid': 999999}),
    );
    final claim = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    addTearDown(() => claim.instance!.dispose());
    expect(claim.isPrimary, isTrue);
    final document =
        jsonDecode(File(_portPath(_root.path)).readAsStringSync())
            as Map<String, Object?>;
    expect(document['port'], claim.instance!.port);
  });

  test('a corrupt activation document is ignored', () async {
    File(_portPath(_root.path)).writeAsStringSync('{not json');
    final claim = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    addTearDown(() => claim.instance!.dispose());
    expect(claim.isPrimary, isTrue);
  });

  test('disposing an owner removes only its own registry files', () async {
    final unrelated = File(joinViewerPath(_root.path, 'unrelated.txt'))
      ..writeAsStringSync('keep me');
    final claim = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    final instance = claim.instance!;
    await instance.dispose();

    expect(File(instance.lockPath).existsSync(), isFalse);
    expect(File(instance.portPath).existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
    expect(unrelated.readAsStringSync(), 'keep me');

    await instance.dispose();
    expect(File(instance.lockPath).existsSync(), isFalse);
  });

  test('the slot is free again once the owner has closed', () async {
    final first = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    await first.instance!.dispose();

    final second = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    addTearDown(() => second.instance!.dispose());
    expect(second.isPrimary, isTrue);
  });

  test('a different settings root is a different instance slot', () async {
    final other = _newRoot('instance-other');
    final first = await ViewerInstance.claim(
      settingsRoot: _root.path,
      onActivate: () async {},
    );
    final second = await ViewerInstance.claim(
      settingsRoot: other.path,
      onActivate: () async {},
    );
    addTearDown(() async {
      await first.instance!.dispose();
      await second.instance!.dispose();
    });
    expect(first.isPrimary, isTrue);
    expect(second.isPrimary, isTrue);
    expect(first.instance!.port, isNot(second.instance!.port));
  });
}
