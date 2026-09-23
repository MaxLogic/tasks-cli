/// Settings ↔ startup registration, driven headlessly (viewer/spec.md 3.1).
///
/// The dialog is pumped as a widget over an injected registrar whose store is
/// in memory, so these cases create no shortcut, open no window and send no
/// input to the desktop; keys are delivered through the test binding only.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/platform/startup_registration.dart';
import 'package:tasks_viewer/platform/viewer_startup.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/settings_dialog.dart';

import '../support/viewer_test_support.dart';

/// In-memory shortcut store with one recorded file.
class ScriptedStartupStore implements StartupShortcutStore {
  StartupShortcutRecord? record;

  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<StartupShortcutRecord?> read(String shortcutPath) async {
    reads.add(shortcutPath);
    return record;
  }

  @override
  Future<void> write(String shortcutPath, StartupShortcutRecord next) async {
    writes.add(shortcutPath);
    record = next;
  }

  @override
  Future<void> delete(String shortcutPath) async {
    deletes.add(shortcutPath);
    record = null;
  }
}

/// Policy probe that always reports "not disabled by Windows".
class NotDisabledPolicyProbe implements StartupPolicyProbe {
  @override
  Future<bool?> shortcutDisabledByWindows(String shortcutFileName) async =>
      false;
}

const String retryButtonLabel = 'Retry registration (Alt+G)';

Finder retryButton() => find.widgetWithText(TextButton, retryButtonLabel);

void main() {
  late Directory startupDirectory;
  late ScriptedStartupStore store;
  late ViewerStartupController controller;

  setUp(() {
    startupDirectory = Directory.systemTemp.createTempSync(
      'viewer-settings-startup-',
    );
    addTearDown(() {
      if (startupDirectory.existsSync()) {
        startupDirectory.deleteSync(recursive: true);
      }
    });
    store = ScriptedStartupStore();
    final registrar = StartupRegistrar(
      startupDirectory: startupDirectory.path,
      target: viewerStartupTargetFor(
        executablePath: r'C:\bundle\tasks_viewer.exe',
        settingsRoot: r'C:\bundle\settings',
      ),
      store: store,
      policy: NotDisabledPolicyProbe(),
    );
    controller = ViewerStartupController(registrar: registrar);
    addTearDown(controller.dispose);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    ViewerStartupController? startup,
    ViewerSettingsDraft settings = const ViewerSettingsDraft(),
    SettingsConnectionTester? connectionTester,
  }) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
      mode: AnnouncementMode.nvdaOnly,
    );
    addTearDown(announcements.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsDialog(
          environment: viewerTestEnvironment(),
          announcements: announcements,
          initial: settings,
          startup: startup,
          connectionTester: connectionTester,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a launch that may not register says so instead of guessing', (
    WidgetTester tester,
  ) async {
    await pumpSettings(tester, startup: null);

    expect(
      find.textContaining('applied by the packaged release'),
      findsOneWidget,
    );
    expect(retryButton(), findsNothing);
  });

  testWidgets('an unavailable controller shows its own wording', (
    WidgetTester tester,
  ) async {
    final unavailable = ViewerStartupController.unavailable(
      note: 'Packaged release only.',
    );
    addTearDown(unavailable.dispose);
    await pumpSettings(tester, startup: unavailable);

    expect(find.text('Packaged release only.'), findsOneWidget);
    expect(retryButton(), findsNothing);
  });

  testWidgets(
    'a conflicting shortcut is reported and Retry never overwrites it',
    (WidgetTester tester) async {
      store.record = const StartupShortcutRecord(
        target: r'C:\Other App\other.exe',
        arguments: '--tray',
        workingDirectory: r'C:\Other App',
        description: 'Other App',
      );
      await pumpSettings(tester, startup: controller);

      expect(find.textContaining('belongs to another program'), findsOneWidget);
      expect(retryButton(), findsOneWidget);

      await tester.ensureVisible(retryButton());
      await tester.tap(retryButton());
      await tester.pumpAndSettle();

      expect(
        store.writes,
        isEmpty,
        reason: 'a foreign file is never overwritten',
      );
      expect(
        find.textContaining('already belongs to another program'),
        findsOneWidget,
      );
      expect(retryButton(), findsOneWidget);
    },
  );

  testWidgets('Retry registers the shortcut once the conflict is gone', (
    WidgetTester tester,
  ) async {
    store.record = const StartupShortcutRecord(
      target: r'C:\Other App\other.exe',
      arguments: '--tray',
      workingDirectory: r'C:\Other App',
      description: 'Other App',
    );
    await pumpSettings(tester, startup: controller);
    expect(retryButton(), findsOneWidget);

    // The user renames the other program's shortcut, as the dialog asks.
    store.record = null;
    await tester.ensureVisible(retryButton());
    await tester.tap(retryButton());
    await tester.pumpAndSettle();

    expect(store.writes, hasLength(1));
    expect(store.record!.target, r'C:\bundle\tasks_viewer.exe');
    expect(find.textContaining('Registered'), findsOneWidget);
    expect(retryButton(), findsNothing);
  });

  testWidgets('Alt+G runs the same retry without a pointer', (
    WidgetTester tester,
  ) async {
    store.record = const StartupShortcutRecord(
      target: r'C:\Other App\other.exe',
      arguments: '--tray',
      workingDirectory: r'C:\Other App',
      description: 'Other App',
    );
    await pumpSettings(tester, startup: controller);
    expect(retryButton(), findsOneWidget);

    store.record = null;
    await pressAlt(tester, LogicalKeyboardKey.keyG);

    expect(store.writes, hasLength(1));
    expect(find.textContaining('Registered'), findsOneWidget);
  });

  testWidgets('the switch explains when the preference is applied', (
    WidgetTester tester,
  ) async {
    await pumpSettings(tester, startup: controller);
    expect(find.text('Start with Windows (Alt+W)'), findsOneWidget);
    expect(
      find.textContaining('Applied when Settings is saved'),
      findsOneWidget,
    );
  });

  testWidgets('Test connection runs the protocol probe and reports success', (
    WidgetTester tester,
  ) async {
    String? testedPath;
    await pumpSettings(
      tester,
      connectionTester: (path) async {
        testedPath = path;
        return const ViewerInfo(
          protocolVersion: 1,
          operations: <String>[],
          statuses: <String>[],
          priorities: <String>[],
          editableFields: <String>[],
          editableFieldLimits: ViewerEditableFieldLimits(
            titleMaxChars: 1,
            bodyMaxUtf8Bytes: 1,
            statusValues: <String>[],
            priorityValues: <String>[],
            labelsMaxCount: 0,
            labelsItemMaxChars: 1,
            labelsItemAllowed: '',
            depsMaxCount: 0,
          ),
        );
      },
    );

    await tester.ensureVisible(find.text('Test connection (Alt+T)'));
    await tester.tap(find.text('Test connection (Alt+T)'));
    await tester.pumpAndSettle();

    expect(testedPath, r'C:\viewer-test\tasks.exe');
    expect(
      find.text('Connection succeeded. Protocol version 1.'),
      findsOneWidget,
    );
  });

  test('the command registry binds the retry to Alt+G in the dialog scope', () {
    final spec = commandSpecById('settings.retryStartup');
    expect(spec, isNotNull);
    expect(spec!.scope, CommandScope.settings);
    final altG = spec.activators.whereType<SingleActivator>().where(
      (activator) =>
          activator.trigger == LogicalKeyboardKey.keyG &&
          activator.alt &&
          !activator.control &&
          !activator.shift,
    );
    expect(altG, hasLength(1));
    expect(spec.description, isNotEmpty);
    expect(spec.label, isNotEmpty);
  });
}
