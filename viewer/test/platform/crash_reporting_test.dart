import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/platform/crash_reporting.dart';

const String _sampleDsn = 'https://abc123@o1.ingest.de.sentry.io/42';

class _FakeCrashBackend implements CrashReportBackend {
  bool _initialized = false;
  int initCalls = 0;
  int closeCalls = 0;
  String? lastDsn;
  String? lastRelease;
  String? lastNativeDbPath;
  List<String> filesInNativeDbAtInit = const <String>[];
  final List<SentryEvent> approvedEvents = <SentryEvent>[];
  final List<({String fileName, Uint8List bytes, String? release})>
  uploadedMinidumps = <({String fileName, Uint8List bytes, String? release})>[];

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> init({
    required String dsn,
    required String? release,
    required String nativeDatabasePath,
    required SentryEvent? Function(SentryEvent event, Hint hint) beforeSend,
  }) async {
    initCalls++;
    lastDsn = dsn;
    lastRelease = release;
    lastNativeDbPath = nativeDatabasePath;
    final dir = Directory(nativeDatabasePath);
    if (await dir.exists()) {
      filesInNativeDbAtInit = dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path)
          .toList(growable: false);
    }
    _initialized = true;
  }

  @override
  Future<void> captureApprovedEvent(SentryEvent event) async {
    approvedEvents.add(event);
  }

  @override
  Future<void> captureNativeMinidump({
    required Uint8List bytes,
    required String fileName,
    required String? release,
  }) async {
    uploadedMinidumps.add((fileName: fileName, bytes: bytes, release: release));
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _initialized = false;
  }
}

void main() {
  group('SettingsStore crash_reporting persistence', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('viewer-crash-settings-');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('defaults missing crash_reporting field to off', () {
      final draft = decodeSettingsDocument('{"schema_version": 1}');
      expect(draft.crashReporting, ViewerCrashReportingMode.off);
    });

    test('round-trips off, ask and always modes', () async {
      final store = SettingsStore(settingsRoot: root.path);
      for (final mode in ViewerCrashReportingMode.values) {
        await store.save(ViewerSettingsDraft(crashReporting: mode));
        final loaded = await store.load();
        expect(loaded.hasWarning, isFalse);
        expect(loaded.draft.crashReporting, mode);
      }
    });

    test('rejects unknown crash_reporting values as corrupt', () {
      expect(
        () => decodeSettingsDocument(
          '{"schema_version": 1, "crash_reporting": "sometimes"}',
        ),
        throwsFormatException,
      );
    });
  });

  group('scrubCrashText and scrubSentryEvent', () {
    test('redacts tokens, bearer headers, and Windows profile usernames', () {
      final raw =
          r'Failed Bearer secret_tok with sntryu_deadbeef123 at C:\Users\pawel\AppData\Local\tasks.db';
      final cleaned = scrubCrashText(raw);
      expect(cleaned, isNot(contains('secret_tok')));
      expect(cleaned, isNot(contains('sntryu_deadbeef123')));
      expect(cleaned, isNot(contains('pawel')));
      expect(cleaned, contains('[REDACTED]'));
      expect(cleaned, contains(r'C:\Users\[REDACTED]\AppData'));
    });

    test('strips user, request, sensitive extra and breadcrumb keys', () {
      final event = SentryEvent(
        message: SentryMessage('boom sntrys_supersecret'),
        user: SentryUser(email: 'private@example.com'),
        request: SentryRequest(url: 'https://private.internal/tasks'),
        exceptions: <SentryException>[
          SentryException(
            type: 'StateError',
            value: r'Clipboard Bearer xyz in C:\Users\alice\secret.txt',
          ),
        ],
        // ignore: deprecated_member_use
        extra: <String, dynamic>{
          'clipboard_text': 'sensitive clipboard content',
          'task_body': 'private task description',
          'auth_header': 'Bearer abc',
          'safe_count': 7,
        },
        breadcrumbs: <Breadcrumb>[
          Breadcrumb(
            message: 'Opened Bearer topsecret',
            data: <String, dynamic>{
              'task_title': 'secret title',
              'pane': 'tasks',
            },
          ),
        ],
      );

      final cleaned = scrubSentryEvent(event);
      expect(cleaned.user, isNull);
      expect(cleaned.request, isNull);
      expect(cleaned.message?.formatted, isNot(contains('sntrys_')));
      expect(cleaned.exceptions?.single.value, isNot(contains('xyz')));
      expect(cleaned.exceptions?.single.value, isNot(contains('alice')));
      // ignore: deprecated_member_use
      expect(cleaned.extra, <String, dynamic>{'safe_count': 7});
      expect(cleaned.breadcrumbs?.single.message, isNot(contains('topsecret')));
      expect(cleaned.breadcrumbs?.single.data, <String, dynamic>{
        'pane': 'tasks',
      });
    });
  });

  group('ViewerCrashReporter', () {
    late Directory root;
    late _FakeCrashBackend backend;

    setUp(() {
      root = Directory.systemTemp.createTempSync('viewer-crash-reporter-');
      backend = _FakeCrashBackend();
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test(
      'never initializes in off mode, test mode, kill switch, or empty DSN',
      () async {
        final cases = <ViewerCrashReporter>[
          ViewerCrashReporter(
            settingsRoot: root.path,
            initialMode: ViewerCrashReportingMode.off,
            enabledForLaunch: true,
            dsn: _sampleDsn,
            backend: backend,
            environment: const <String, String>{},
          ),
          ViewerCrashReporter(
            settingsRoot: root.path,
            initialMode: ViewerCrashReportingMode.always,
            enabledForLaunch: false,
            dsn: _sampleDsn,
            backend: backend,
            environment: const <String, String>{},
          ),
          ViewerCrashReporter(
            settingsRoot: root.path,
            initialMode: ViewerCrashReportingMode.always,
            enabledForLaunch: true,
            dsn: _sampleDsn,
            backend: backend,
            environment: const <String, String>{'TASKS_NO_SENTRY': '1'},
          ),
          ViewerCrashReporter(
            settingsRoot: root.path,
            initialMode: ViewerCrashReportingMode.always,
            enabledForLaunch: true,
            dsn: '',
            backend: backend,
            environment: const <String, String>{},
          ),
        ];

        for (final reporter in cases) {
          await reporter.initialize();
          expect(reporter.isInitialized, isFalse);
        }
        expect(backend.initCalls, 0);
      },
    );

    test(
      'stages native minidumps before native init in ask mode and uploads only on approval',
      () async {
        final runDir = Directory(
          joinViewerPath(
            joinViewerPath(root.path, 'sentry-native'),
            'abc123.run',
          ),
        )..createSync(recursive: true);
        final dumpFile = File(joinViewerPath(runDir.path, 'crash-1.dmp'))
          ..writeAsBytesSync(<int>[0x4D, 0x44, 0x4D, 0x50, 1, 2, 3, 4]);

        final reporter = ViewerCrashReporter(
          settingsRoot: root.path,
          initialMode: ViewerCrashReportingMode.ask,
          enabledForLaunch: true,
          dsn: _sampleDsn,
          release: 'tasks-viewer@0.1.0+abc123',
          backend: backend,
          environment: const <String, String>{},
        );

        await reporter.initialize();

        expect(backend.initCalls, 1);
        expect(
          backend.filesInNativeDbAtInit.where((p) => p.endsWith('.dmp')),
          isEmpty,
          reason:
              'Minidump must be staged out of sentry-native before native init',
        );
        expect(dumpFile.existsSync(), isFalse);
        expect(reporter.pendingReports, hasLength(1));
        final pending = reporter.pendingReports.single;
        expect(pending.kind, PendingCrashKind.nativeMinidump);
        expect(pending.minidumpFileName, 'crash-1.dmp');
        expect(backend.uploadedMinidumps, isEmpty);

        await reporter.sendPendingReport(pending);
        expect(backend.uploadedMinidumps, hasLength(1));
        expect(backend.uploadedMinidumps.single.fileName, 'crash-1.dmp');
        expect(
          backend.uploadedMinidumps.single.bytes,
          Uint8List.fromList(<int>[0x4D, 0x44, 0x4D, 0x50, 1, 2, 3, 4]),
        );
        expect(File(pending.minidumpPath!).existsSync(), isFalse);
        expect(reporter.hasPendingReports, isFalse);
      },
    );

    test('discards staged minidump without uploading', () async {
      final nativeDir = Directory(joinViewerPath(root.path, 'sentry-native'))
        ..createSync(recursive: true);
      File(
        joinViewerPath(nativeDir.path, 'crash-discard.dmp'),
      ).writeAsBytesSync(<int>[0x4D, 0x44, 0x4D, 0x50]);

      final reporter = ViewerCrashReporter(
        settingsRoot: root.path,
        initialMode: ViewerCrashReportingMode.ask,
        enabledForLaunch: true,
        dsn: _sampleDsn,
        backend: backend,
        environment: const <String, String>{},
      );
      await reporter.initialize();
      final pending = reporter.pendingReports.single;

      await reporter.discardPendingReport(pending);
      expect(backend.uploadedMinidumps, isEmpty);
      expect(File(pending.minidumpPath!).existsSync(), isFalse);
      expect(reporter.hasPendingReports, isFalse);
    });

    test(
      'queues Dart errors in ask mode and passes through in always mode',
      () async {
        final reporter = ViewerCrashReporter(
          settingsRoot: root.path,
          initialMode: ViewerCrashReportingMode.ask,
          enabledForLaunch: true,
          dsn: _sampleDsn,
          backend: backend,
          environment: const <String, String>{},
        );
        await reporter.initialize();

        final dartEvent = SentryEvent(
          exceptions: <SentryException>[
            SentryException(type: 'RangeError', value: 'Bearer hidden_secret'),
          ],
        );
        // Unapproved Dart event is held locally and dropped from auto-send.
        expect(reporter.handleBeforeSend(dartEvent, Hint()), isNull);
        expect(reporter.pendingReports, hasLength(1));
        expect(
          reporter.pendingReports.single.details,
          isNot(contains('hidden_secret')),
        );

        // User approves sending.
        await reporter.sendPendingReport(reporter.pendingReports.single);
        expect(backend.approvedEvents, hasLength(1));
        expect(reporter.hasPendingReports, isFalse);

        // Approved hint passes through beforeSend cleanly.
        final approved = reporter.handleBeforeSend(
          SentryEvent(message: SentryMessage('approved')),
          Hint.withMap(<String, dynamic>{approvedCrashReportHintKey: true}),
        );
        expect(approved, isNotNull);

        // Switching to always passes through immediately.
        await reporter.applyMode(ViewerCrashReportingMode.always);
        final immediate = reporter.handleBeforeSend(
          SentryEvent(message: SentryMessage('auto')),
          Hint(),
        );
        expect(immediate, isNotNull);

        // Switching to off closes the backend.
        await reporter.applyMode(ViewerCrashReportingMode.off);
        expect(backend.closeCalls, 1);
        expect(reporter.isInitialized, isFalse);
      },
    );
  });
}
