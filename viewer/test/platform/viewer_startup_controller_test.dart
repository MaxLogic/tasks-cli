/// Desired versus effective startup registration (viewer/spec.md 3.1).
///
/// The controller never touches the real Startup folder here: the registrar
/// runs over an in-memory store and an injected temporary directory, and every
/// failure is scripted.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/platform/startup_registration.dart';
import 'package:tasks_viewer/platform/viewer_startup.dart';

final Object? windowsOnlySkip = Platform.isWindows
    ? null
    : 'Startup registration is a Windows feature (spec 3.1).';

/// In-memory shortcut store; one record per path, plus injectable failures.
class MemoryStartupStore implements StartupShortcutStore {
  final Map<String, StartupShortcutRecord> records =
      <String, StartupShortcutRecord>{};

  Object? readFailure;
  Object? writeFailure;

  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<StartupShortcutRecord?> read(String shortcutPath) async {
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    return records[shortcutPath];
  }

  @override
  Future<void> write(String shortcutPath, StartupShortcutRecord record) async {
    writes.add(shortcutPath);
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    records[shortcutPath] = record;
  }

  @override
  Future<void> delete(String shortcutPath) async {
    deletes.add(shortcutPath);
    records.remove(shortcutPath);
  }
}

void main() {
  late Directory startupDirectory;
  late MemoryStartupStore store;
  late StartupRegistrar registrar;
  late ViewerStartupController controller;

  setUp(() {
    startupDirectory = Directory.systemTemp.createTempSync(
      'viewer-startup-controller-',
    );
    addTearDown(() {
      if (startupDirectory.existsSync()) {
        startupDirectory.deleteSync(recursive: true);
      }
    });
    store = MemoryStartupStore();
    registrar = StartupRegistrar(
      startupDirectory: startupDirectory.path,
      target: viewerStartupTargetFor(
        executablePath: r'C:\bundle\tasks_viewer.exe',
        settingsRoot: r'C:\bundle\settings',
      ),
      store: store,
      policy: _StaticPolicyProbe(),
    );
    controller = ViewerStartupController(registrar: registrar);
    addTearDown(controller.dispose);
  });

  test('the summary starts unknown and reports what it read', () async {
    expect(controller.supported, isTrue);
    expect(controller.report, isNull);
    expect(controller.summary, contains('has not been read yet'));

    final report = await controller.refresh();
    expect(report!.state, StartupShortcutState.missing);
    expect(controller.summary, contains('No startup shortcut'));
    expect(controller.failure, isNull);
    expect(controller.busy, isFalse);
  }, skip: windowsOnlySkip);

  test(
    'applying the preference on registers and reports the shortcut',
    () async {
      final report = await controller.applyDesired(true);
      expect(report!.state, StartupShortcutState.registered);
      expect(store.writes, <String>[registrar.shortcutPath]);
      expect(controller.summary, contains('Registered'));
      expect(controller.windowsDisabled, isFalse);
    },
    skip: windowsOnlySkip,
  );

  test(
    'applying the preference off removes the owned shortcut',
    () async {
      await controller.applyDesired(true);
      final report = await controller.applyDesired(false);
      expect(report!.state, StartupShortcutState.missing);
      expect(store.records, isEmpty);
      expect(controller.summary, contains('No startup shortcut'));
    },
    skip: windowsOnlySkip,
  );

  test(
    'a failure keeps its own wording next to the preference',
    () async {
      store.writeFailure = const FileSystemException('read-only folder');
      final report = await controller.applyDesired(true);
      expect(report!.state, StartupShortcutState.missing);
      expect(controller.failure, contains('read-only folder'));
      expect(controller.summary, contains('No startup shortcut'));

      // The next attempt succeeds once the folder is writable again.
      store.writeFailure = null;
      expect((await controller.applyDesired(true))!.isRegistered, isTrue);
      expect(controller.failure, isNull);
    },
    skip: windowsOnlySkip,
  );

  test(
    'an unreadable store is wording, not an escaped exception',
    () async {
      store.readFailure = StateError('registry exploded');
      final report = await controller.refresh();
      expect(report!.state, StartupShortcutState.unreadable);
      expect(controller.failure, contains('registry exploded'));
    },
    skip: windowsOnlySkip,
  );

  test('an unexpected registrar failure becomes wording too', () async {
    final throwing = ViewerStartupController(
      registrar: _ThrowingRegistrar(startupDirectory.path),
    );
    addTearDown(throwing.dispose);
    expect(await throwing.refresh(), isNull);
    expect(throwing.failure, contains('registry exploded'));
    expect(await throwing.applyDesired(true), isNull);
    expect(throwing.failure, contains('registry exploded'));
  }, skip: windowsOnlySkip);

  test('an unavailable controller says so and changes nothing', () async {
    final unavailable = ViewerStartupController.unavailable(
      note: 'Packaged release only.',
    );
    addTearDown(unavailable.dispose);

    expect(unavailable.supported, isFalse);
    expect(unavailable.summary, 'Packaged release only.');
    expect(await unavailable.refresh(), isNull);
    expect(await unavailable.applyDesired(true), isNull);
    expect(unavailable.failure, isNull);
    expect(unavailable.report, isNull);
  });

  test('the default unavailable wording explains debug and test launches', () {
    final unavailable = ViewerStartupController.unavailable();
    addTearDown(unavailable.dispose);
    expect(unavailable.summary, contains('packaged release'));
    expect(unavailable.summary, contains('Debug and test launches'));
  });
}

/// Policy probe that always reports "not disabled by Windows".
class _StaticPolicyProbe implements StartupPolicyProbe {
  @override
  Future<bool?> shortcutDisabledByWindows(String shortcutFileName) async =>
      false;
}

/// Registrar whose inspections always blow up, to prove the wording survives.
class _ThrowingRegistrar extends StartupRegistrar {
  _ThrowingRegistrar(String startupDirectory)
    : super(
        startupDirectory: startupDirectory,
        target: viewerStartupTargetFor(
          executablePath: r'C:\bundle\tasks_viewer.exe',
          settingsRoot: r'C:\bundle\settings',
        ),
        store: MemoryStartupStore(),
        policy: _StaticPolicyProbe(),
      );

  @override
  Future<StartupRegistrationReport> inspect() async =>
      throw StateError('registry exploded');

  @override
  Future<StartupRegistrationReport> ensureRegistered() async =>
      throw StateError('registry exploded');
}
