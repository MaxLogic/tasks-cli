import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/platform/crash_reporting.dart';
import 'package:tasks_viewer/ui/crash_report_dialog.dart';

class _RecordingBackend implements CrashReportBackend {
  bool _initialized = false;
  final List<SentryEvent> sentEvents = <SentryEvent>[];
  final List<String> sentMinidumps = <String>[];

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> init({
    required String dsn,
    required String? release,
    required String nativeDatabasePath,
    required SentryEvent? Function(SentryEvent event, Hint hint) beforeSend,
  }) async {
    _initialized = true;
  }

  @override
  Future<void> captureApprovedEvent(SentryEvent event) async {
    sentEvents.add(event);
  }

  @override
  Future<void> captureNativeMinidump({
    required Uint8List bytes,
    required String fileName,
    required String? release,
  }) async {
    sentMinidumps.add(fileName);
  }

  @override
  Future<void> close() async {
    _initialized = false;
  }
}

Future<void> _pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

Future<void> _pressControl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('viewer-crash-dialog-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  ViewerEnvironment configuredEnv() => ViewerEnvironment(
    launchArgs: const ViewerLaunchArgs(),
    settingsRoot: root.path,
    dataRoot: root.path,
    tasksExe: r'C:\Tools\tasks.exe',
  );

  testWidgets(
    'ask mode shows confirmation dialog and Always send persists preference',
    (tester) async {
      final backend = _RecordingBackend();
      final reporter = ViewerCrashReporter(
        settingsRoot: root.path,
        initialMode: ViewerCrashReportingMode.ask,
        enabledForLaunch: true,
        dsn: 'https://abc123@o1.ingest.de.sentry.io/42',
        backend: backend,
        environment: const <String, String>{},
      );
      await reporter.initialize();

      ViewerSettingsDraft? persisted;
      await tester.pumpWidget(
        TasksViewerApp(
          environment: configuredEnv(),
          initialSettings: const ViewerSettingsDraft(
            crashReporting: ViewerCrashReportingMode.ask,
          ),
          crashReporter: reporter,
          onSettingsPersist: (draft) async {
            persisted = draft;
          },
        ),
      );
      await tester.pumpAndSettle();

      // Trigger a Dart error held in ask mode.
      reporter.handleBeforeSend(
        SentryEvent(
          exceptions: <SentryException>[
            SentryException(type: 'StateError', value: 'Boom in test'),
          ],
        ),
        Hint(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ViewerCrashReportDialog), findsOneWidget);
      expect(find.text('Tasks Viewer encountered an error'), findsOneWidget);
      expect(find.textContaining('Boom in test'), findsAtLeastNWidgets(1));

      // Alt+I focuses the read-only details field.
      await _pressAlt(tester, LogicalKeyboardKey.keyI);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'crash report details',
      );

      // Alt+A chooses Always send.
      await _pressAlt(tester, LogicalKeyboardKey.keyA);

      expect(find.byType(ViewerCrashReportDialog), findsNothing);
      expect(backend.sentEvents, hasLength(1));
      expect(reporter.mode, ViewerCrashReportingMode.always);
      expect(persisted?.crashReporting, ViewerCrashReportingMode.always);
    },
  );

  testWidgets('Escape discards crash report without sending', (tester) async {
    final backend = _RecordingBackend();
    final reporter = ViewerCrashReporter(
      settingsRoot: root.path,
      initialMode: ViewerCrashReportingMode.ask,
      enabledForLaunch: true,
      dsn: 'https://abc123@o1.ingest.de.sentry.io/42',
      backend: backend,
      environment: const <String, String>{},
    );
    await reporter.initialize();

    await tester.pumpWidget(
      TasksViewerApp(
        environment: configuredEnv(),
        initialSettings: const ViewerSettingsDraft(
          crashReporting: ViewerCrashReportingMode.ask,
        ),
        crashReporter: reporter,
      ),
    );
    await tester.pumpAndSettle();

    reporter.handleBeforeSend(
      SentryEvent(message: SentryMessage('Should not send')),
      Hint(),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ViewerCrashReportDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ViewerCrashReportDialog), findsNothing);
    expect(backend.sentEvents, isEmpty);
    expect(reporter.hasPendingReports, isFalse);
  });

  testWidgets('Settings Alt+U focuses Crash reporting and saves selection', (
    tester,
  ) async {
    final backend = _RecordingBackend();
    final reporter = ViewerCrashReporter(
      settingsRoot: root.path,
      initialMode: ViewerCrashReportingMode.off,
      enabledForLaunch: true,
      dsn: 'https://abc123@o1.ingest.de.sentry.io/42',
      backend: backend,
      environment: const <String, String>{},
    );
    ViewerSettingsDraft? persisted;

    await tester.pumpWidget(
      TasksViewerApp(
        environment: configuredEnv(),
        initialSettings: const ViewerSettingsDraft(
          crashReporting: ViewerCrashReportingMode.off,
        ),
        crashReporter: reporter,
        onSettingsPersist: (draft) async {
          persisted = draft;
        },
      ),
    );
    await tester.pumpAndSettle();

    await _pressControl(tester, LogicalKeyboardKey.comma);
    expect(find.text('Crash reporting (Alt+U)'), findsOneWidget);

    await _pressAlt(tester, LogicalKeyboardKey.keyU);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'settings crash reporting',
    );

    final dropdown = find.byWidgetPredicate(
      (widget) => widget is DropdownButtonFormField<ViewerCrashReportingMode>,
    );
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always send').last);
    await tester.pumpAndSettle();

    await _pressControl(tester, LogicalKeyboardKey.keyS);
    expect(persisted?.crashReporting, ViewerCrashReportingMode.always);
    expect(reporter.mode, ViewerCrashReportingMode.always);
    expect(backend.isInitialized, isTrue);
  });
}
