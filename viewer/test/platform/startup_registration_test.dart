/// The one Startup shortcut this application owns (viewer/spec.md 3.1).
///
/// Every case injects a temporary startup directory, an in-memory shortcut
/// store and a scripted policy probe, so no case can create, change or remove a
/// real Startup entry, open a window or touch an input device.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/data/settings_store.dart' show joinViewerPath;
import 'package:tasks_viewer/platform/startup_registration.dart';

/// In-memory shortcut store with injectable failures.
class FakeStartupShortcutStore implements StartupShortcutStore {
  final Map<String, StartupShortcutRecord> records =
      <String, StartupShortcutRecord>{};

  Object? readFailure;
  Object? writeFailure;
  Object? deleteFailure;

  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<StartupShortcutRecord?> read(String shortcutPath) async {
    reads.add(shortcutPath);
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
    final failure = deleteFailure;
    if (failure != null) {
      throw failure;
    }
    records.remove(shortcutPath);
  }
}

/// Scripted policy probe; records every file name it was asked about.
class FakeStartupPolicyProbe implements StartupPolicyProbe {
  FakeStartupPolicyProbe({this.disabled});

  /// What Windows/Task Manager reports: true disabled, false enabled, null
  /// unknown.
  bool? disabled;

  final List<String> probed = <String>[];

  @override
  Future<bool?> shortcutDisabledByWindows(String shortcutFileName) async {
    probed.add(shortcutFileName);
    return disabled;
  }
}

/// Installed bundle the shortcut must launch.
const String bundleExecutable =
    r'C:\Program Files\MaxLogic Tasks Viewer\tasks_viewer.exe';
const String bundleSettingsRoot =
    r'C:\Users\Pawel\AppData\Local\MaxLogic\tasks-viewer';
const String bundleDataRoot = r'C:\Users\Pawel\AppData\Local\MaxLogic\tasks';

final Object? windowsOnlySkip = Platform.isWindows
    ? null
    : 'Startup registration is a Windows feature (spec 3.1).';

ViewerStartupTarget bundleTarget() => viewerStartupTargetFor(
  executablePath: bundleExecutable,
  settingsRoot: bundleSettingsRoot,
  dataRoot: bundleDataRoot,
  tasksExe: r'C:\Program Files\MaxLogic Tasks Viewer\tasks.exe',
);

void main() {
  group('argument quoting', () {
    test('round-trips every shape the bundle writes', () {
      final cases = <List<String>>[
        <String>[],
        <String>['--startup'],
        <String>['--data-root', r'C:\Users\Pawel Nowak\My Data\tasks'],
        <String>[
          '--settings-root',
          r'D:\Bundles\MaxLogic Tasks Viewer\settings',
        ],
        <String>['a"b'],
        <String>[r'C:\trailing\\'],
        <String>[''],
        <String>['two\twords'],
        <String>['Grüße, Wrocław'],
      ];
      for (final arguments in cases) {
        final line = formatWindowsArguments(arguments);
        expect(parseWindowsArguments(line), arguments, reason: line);
      }
    });

    test('quotes only what the Windows parser requires', () {
      expect(quoteWindowsArgument('--startup'), '--startup');
      expect(
        quoteWindowsArgument(r'C:\bundle\tasks.exe'),
        r'C:\bundle\tasks.exe',
      );
      expect(quoteWindowsArgument(''), '""');
      expect(
        quoteWindowsArgument(r'C:\Program Files\viewer'),
        r'"C:\Program Files\viewer"',
      );
      expect(quoteWindowsArgument('say "hi"'), '"say \\"hi\\""');
    });

    test('an unterminated quote is refused instead of guessed', () {
      expect(parseWindowsArguments('"unterminated'), isNull);
      expect(parseWindowsArguments('"unterminated" "open'), isNull);
    });
  });

  group('viewerStartupTargetFor', () {
    test('stores the resolved paths as separate argument values', () {
      final target = bundleTarget();
      expect(
        target.workingDirectory,
        r'C:\Program Files\MaxLogic Tasks Viewer',
      );
      expect(target.arguments, <String>[
        '--startup',
        '--settings-root',
        bundleSettingsRoot,
        '--data-root',
        bundleDataRoot,
        '--tasks-exe',
        r'C:\Program Files\MaxLogic Tasks Viewer\tasks.exe',
      ]);
      expect(parseWindowsArguments(target.argumentLine), target.arguments);
    });

    test('omits the data and CLI paths a plain launch never resolved', () {
      final target = viewerStartupTargetFor(
        executablePath: r'C:\bundle\viewer.exe',
        settingsRoot: r'C:\bundle\settings',
      );
      expect(target.arguments, <String>[
        '--startup',
        '--settings-root',
        r'C:\bundle\settings',
      ]);
      expect(target.workingDirectory, r'C:\bundle');
    });
  });

  group('StartupRegistrar', () {
    late Directory startupDirectory;
    late FakeStartupShortcutStore store;
    late FakeStartupPolicyProbe policy;
    late StartupRegistrar registrar;

    setUp(() {
      startupDirectory = Directory.systemTemp.createTempSync(
        'viewer-startup-test-',
      );
      addTearDown(() {
        if (startupDirectory.existsSync()) {
          startupDirectory.deleteSync(recursive: true);
        }
      });
      store = FakeStartupShortcutStore();
      policy = FakeStartupPolicyProbe();
      registrar = StartupRegistrar(
        startupDirectory: startupDirectory.path,
        target: bundleTarget(),
        store: store,
        policy: policy,
      );
    });

    test(
      'a missing shortcut is reported without consulting Windows',
      () async {
        final report = await registrar.inspect();
        expect(report.state, StartupShortcutState.missing);
        expect(report.isRegistered, isFalse);
        expect(report.needsUserAction, isFalse);
        expect(report.windowsDisabled, isNull);
        expect(policy.probed, isEmpty);
        expect(
          report.shortcutPath,
          joinViewerPath(startupDirectory.path, viewerStartupShortcutFileName),
        );
      },
      skip: windowsOnlySkip,
    );

    test(
      'registration writes the owned record and verifies it',
      () async {
        final report = await registrar.ensureRegistered();
        expect(report.state, StartupShortcutState.registered);
        expect(report.failure, isNull);
        expect(store.writes, <String>[registrar.shortcutPath]);
        final record = store.records[registrar.shortcutPath]!;
        expect(record.target, bundleExecutable);
        expect(
          record.workingDirectory,
          r'C:\Program Files\MaxLogic Tasks Viewer',
        );
        expect(record.description, viewerStartupShortcutDescription);
        final arguments = parseWindowsArguments(record.arguments ?? '');
        expect(arguments, bundleTarget().arguments);

        // A second launch is a no-op instead of rewriting the same file.
        expect((await registrar.ensureRegistered()).isRegistered, isTrue);
        expect(store.writes, hasLength(1));
      },
      skip: windowsOnlySkip,
    );

    test('a bundle that moved is refreshed on the next launch', () async {
      store.records[registrar.shortcutPath] = StartupShortcutRecord(
        target: r'D:\Old Bundle\tasks_viewer.exe',
        arguments: formatWindowsArguments(<String>[
          '--startup',
          '--settings-root',
          bundleSettingsRoot,
        ]),
        workingDirectory: r'D:\Old Bundle',
        description: viewerStartupShortcutDescription,
      );
      expect(
        (await registrar.inspect()).state,
        StartupShortcutState.needsUpdate,
      );

      final report = await registrar.ensureRegistered();
      expect(report.state, StartupShortcutState.registered);
      final record = store.records[registrar.shortcutPath]!;
      expect(record.target, bundleExecutable);
      expect(record.arguments, bundleTarget().argumentLine);
    }, skip: windowsOnlySkip);

    test('changed paths make the owned shortcut stale', () async {
      store.records[registrar.shortcutPath] = StartupShortcutRecord(
        target: bundleExecutable,
        arguments: formatWindowsArguments(<String>[
          '--startup',
          '--settings-root',
          r'C:\Somewhere Else',
        ]),
        workingDirectory: r'C:\Program Files\MaxLogic Tasks Viewer',
        description: viewerStartupShortcutDescription,
      );
      expect(
        (await registrar.inspect()).state,
        StartupShortcutState.needsUpdate,
      );
      expect(
        (await registrar.ensureRegistered()).state,
        StartupShortcutState.registered,
      );
    }, skip: windowsOnlySkip);

    test('a foreign shortcut is reported and left untouched', () async {
      store.records[registrar.shortcutPath] = const StartupShortcutRecord(
        target: r'C:\Other App\other.exe',
        arguments: '--tray',
        workingDirectory: r'C:\Other App',
        description: 'Other App',
      );

      final inspected = await registrar.inspect();
      expect(inspected.state, StartupShortcutState.foreign);
      expect(inspected.needsUserAction, isTrue);

      final ensured = await registrar.ensureRegistered();
      expect(ensured.state, StartupShortcutState.foreign);
      expect(ensured.failure, contains('another program'));
      expect(store.writes, isEmpty);

      final removed = await registrar.removeOwned();
      expect(removed.state, StartupShortcutState.foreign);
      expect(store.deletes, isEmpty);
      expect(store.records, contains(registrar.shortcutPath));
    }, skip: windowsOnlySkip);

    test(
      'a same-named executable without our marker stays foreign',
      () async {
        store.records[registrar.shortcutPath] = const StartupShortcutRecord(
          target: r'D:\Somebody Else\tasks_viewer.exe',
          arguments: '--profile work',
          workingDirectory: r'D:\Somebody Else',
        );
        expect((await registrar.inspect()).state, StartupShortcutState.foreign);
        expect(store.writes, isEmpty);
      },
      skip: windowsOnlySkip,
    );

    test('an unreadable shortcut is never overwritten', () async {
      store.records[registrar.shortcutPath] = const StartupShortcutRecord(
        description: 'something we cannot read',
      );
      final inspected = await registrar.inspect();
      expect(inspected.state, StartupShortcutState.unreadable);
      expect(inspected.needsUserAction, isTrue);

      final ensured = await registrar.ensureRegistered();
      expect(ensured.state, StartupShortcutState.unreadable);
      expect(ensured.hasFailure, isTrue);
      expect(store.writes, isEmpty);
    }, skip: windowsOnlySkip);

    test('a store read failure is reported with the path', () async {
      store.readFailure = const FileSystemException('access denied');
      final report = await registrar.inspect();
      expect(report.state, StartupShortcutState.unreadable);
      expect(report.failure, contains(registrar.shortcutPath));
      expect(report.needsUserAction, isTrue);
    }, skip: windowsOnlySkip);

    test('a write failure never claims registration', () async {
      store.writeFailure = const FileSystemException('read-only folder');
      final report = await registrar.ensureRegistered();
      expect(report.state, StartupShortcutState.missing);
      expect(report.isRegistered, isFalse);
      expect(report.hasFailure, isTrue);
      expect(report.failure, contains(registrar.shortcutPath));
    }, skip: windowsOnlySkip);

    test(
      'a Windows-disabled entry is reported, never re-enabled',
      () async {
        await registrar.ensureRegistered();
        store.writes.clear();
        policy.probed.clear();
        policy.disabled = true;

        final report = await registrar.inspect();
        expect(report.state, StartupShortcutState.registered);
        expect(report.windowsDisabled, isTrue);
        expect(report.needsUserAction, isTrue);
        expect(policy.probed, <String>[viewerStartupShortcutFileName]);

        // The only policy surface the viewer has is read-only, so a refresh of
        // the shortcut cannot flip the Windows/Task Manager switch either.
        final refreshed = await registrar.ensureRegistered();
        expect(refreshed.windowsDisabled, isTrue);
        expect(store.writes, isEmpty);
      },
      skip: windowsOnlySkip,
    );

    test(
      'removal deletes the owned shortcut and verifies it is gone',
      () async {
        await registrar.ensureRegistered();
        final removed = await registrar.removeOwned();
        expect(removed.state, StartupShortcutState.missing);
        expect(removed.windowsDisabled, isNull);
        expect(store.deletes, <String>[registrar.shortcutPath]);
        expect(store.records, isEmpty);

        expect(
          (await registrar.removeOwned()).state,
          StartupShortcutState.missing,
        );
        expect(store.deletes, hasLength(1));
      },
      skip: windowsOnlySkip,
    );
  });

  group('platform support', () {
    test('a platform without the Startup folder reports unsupported', () async {
      final directory = Directory.systemTemp.createTempSync(
        'viewer-startup-platform-',
      );
      addTearDown(() {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final store = FakeStartupShortcutStore();
      final policy = FakeStartupPolicyProbe();
      final registrar = StartupRegistrar(
        startupDirectory: directory.path,
        target: bundleTarget(),
        store: store,
        policy: policy,
      );

      final report = await registrar.inspect();
      if (Platform.isWindows) {
        // The same call on Windows reads the injected store instead.
        expect(report.state, StartupShortcutState.missing);
        expect(store.reads, hasLength(1));
      } else {
        expect(report.state, StartupShortcutState.unsupported);
        expect(report.isSupported, isFalse);
        expect(report.needsUserAction, isFalse);
        expect(store.reads, isEmpty);
        expect(policy.probed, isEmpty);
      }
    });
  });
}
