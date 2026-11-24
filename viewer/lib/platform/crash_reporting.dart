/// Optional opt-in Sentry crash reporting for Tasks Viewer.
///
/// Public builds ship with crash reporting disabled by default. Even when a
/// Sentry DSN is compiled in via `--dart-define=TASKS_VIEWER_SENTRY_DSN=...`,
/// the SDK is never initialized while the saved preference is
/// [ViewerCrashReportingMode.off], in `--test-mode`, under `flutter test`, or
/// when `TASKS_NO_SENTRY` is set.
///
/// In [ViewerCrashReportingMode.ask] mode, both Dart errors and pending Windows
/// native Breakpad minidumps are held locally until the user explicitly chooses
/// Send or Always send in the crash report dialog.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../data/settings_draft.dart';
import '../data/settings_store.dart';

/// Build-time public Sentry DSN injected by release/packaging builds.
const String viewerCompiledSentryDsn = String.fromEnvironment(
  'TASKS_VIEWER_SENTRY_DSN',
);

/// Build-time Sentry release identifier matching uploaded `.pdb` / Dart symbols.
const String viewerCompiledSentryRelease = String.fromEnvironment(
  'TASKS_VIEWER_RELEASE',
);

/// Hint key marking an event already approved by the user in `ask` mode.
const String approvedCrashReportHintKey = 'tasks_viewer_user_approved';

/// Kind of pending crash waiting for user confirmation in `ask` mode.
enum PendingCrashKind { dart, nativeMinidump }

/// One scrubbed crash report held locally for user review.
final class PendingCrashReport {
  const PendingCrashReport.dart({
    required this.id,
    required this.summary,
    required this.details,
    required this.occurredAt,
    required SentryEvent this.event,
  }) : kind = PendingCrashKind.dart,
       minidumpPath = null,
       minidumpFileName = null,
       minidumpBytes = null;

  const PendingCrashReport.nativeMinidump({
    required this.id,
    required this.summary,
    required this.details,
    required this.occurredAt,
    required String this.minidumpPath,
    required String this.minidumpFileName,
    required int this.minidumpBytes,
  }) : kind = PendingCrashKind.nativeMinidump,
       event = null;

  final String id;
  final PendingCrashKind kind;
  final String summary;
  final String details;
  final DateTime occurredAt;
  final SentryEvent? event;
  final String? minidumpPath;
  final String? minidumpFileName;
  final int? minidumpBytes;
}

/// Abstract transport boundary so unit and widget tests never load `sentry.dll`
/// or perform real network calls.
abstract interface class CrashReportBackend {
  bool get isInitialized;

  Future<void> init({
    required String dsn,
    required String? release,
    required String nativeDatabasePath,
    required SentryEvent? Function(SentryEvent event, Hint hint) beforeSend,
  });

  Future<void> captureApprovedEvent(SentryEvent event);

  Future<void> captureNativeMinidump({
    required Uint8List bytes,
    required String fileName,
    required String? release,
  });

  Future<void> close();
}

/// Production backend backed by `sentry_flutter` (Dart + Breakpad native).
class SentryFlutterCrashBackend implements CrashReportBackend {
  bool _initialized = false;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> init({
    required String dsn,
    required String? release,
    required String nativeDatabasePath,
    required SentryEvent? Function(SentryEvent event, Hint hint) beforeSend,
  }) async {
    if (_initialized) {
      return;
    }
    await Directory(nativeDatabasePath).create(recursive: true);
    await SentryFlutter.init((options) {
      options.dsn = dsn;
      if (release != null && release.isNotEmpty) {
        options.release = release;
      }
      options.sendDefaultPii = false;
      options.attachScreenshot = false;
      options.attachViewHierarchy = false;
      options.enableUserInteractionBreadcrumbs = false;
      options.enableUserInteractionTracing = false;
      options.enableAutoPerformanceTracing = false;
      options.tracesSampleRate = 0.0;
      options.maxAttachmentSize = 50 * 1024 * 1024;
      options.nativeDatabasePath = nativeDatabasePath;
      options.enableNativeCrashHandling = true;
      options.beforeSend = beforeSend;
    });
    await Sentry.configureScope((scope) {
      scope.setTag('component', 'tasks-viewer');
      scope.setTag('os', Platform.operatingSystem);
    });
    _initialized = true;
  }

  @override
  Future<void> captureApprovedEvent(SentryEvent event) async {
    if (!_initialized) {
      return;
    }
    final hint = Hint.withMap(<String, dynamic>{
      approvedCrashReportHintKey: true,
    });
    await Sentry.captureEvent(event, hint: hint);
  }

  @override
  Future<void> captureNativeMinidump({
    required Uint8List bytes,
    required String fileName,
    required String? release,
  }) async {
    if (!_initialized) {
      return;
    }
    final attachment = SentryAttachment.fromUint8List(
      bytes,
      fileName,
      contentType: 'application/octet-stream',
      attachmentType: SentryAttachment.typeMinidump,
    );
    final hint = Hint.withMap(<String, dynamic>{
      approvedCrashReportHintKey: true,
    });
    hint.attachments.add(attachment);
    final event = SentryEvent(
      level: SentryLevel.fatal,
      platform: 'native',
      release: (release != null && release.isNotEmpty) ? release : null,
      tags: <String, String>{
        'component': 'tasks-viewer',
        'crash_kind': 'native_minidump',
      },
      message: SentryMessage('Native crash minidump'),
    );
    await Sentry.captureEvent(event, hint: hint);
  }

  @override
  Future<void> close() async {
    if (!_initialized) {
      return;
    }
    _initialized = false;
    await Sentry.close();
  }
}

/// Manages the local Windows Breakpad database and staged pending minidumps.
///
/// In `ask` mode, any `.dmp` files left by a previous native crash are moved out
/// of [nativeDatabasePath] into [pendingDirectoryPath] *before* `SentryFlutter`
/// starts, preventing automatic upload before the user decides.
class PendingNativeCrashStore {
  PendingNativeCrashStore({required this.settingsRoot});

  final String settingsRoot;

  String get nativeDatabasePath =>
      joinViewerPath(settingsRoot, 'sentry-native');

  String get pendingDirectoryPath =>
      joinViewerPath(settingsRoot, 'sentry-pending');

  /// Moves any `.dmp` minidumps from `sentry-native/` into `sentry-pending/`
  /// before Sentry native initializes, then returns all staged minidumps.
  List<PendingCrashReport> stageAndListPendingMinidumps() {
    final nativeDir = Directory(nativeDatabasePath);
    final pendingDir = Directory(pendingDirectoryPath);
    if (nativeDir.existsSync()) {
      final dumps = _findMinidumpFiles(nativeDir);
      if (dumps.isNotEmpty) {
        pendingDir.createSync(recursive: true);
        for (final dump in dumps) {
          final baseName = _basename(dump.path);
          final targetPath = _uniquePath(pendingDir.path, baseName);
          try {
            dump.renameSync(targetPath);
          } on FileSystemException {
            dump.copySync(targetPath);
            try {
              dump.deleteSync();
            } on FileSystemException {
              // Best effort if locked; copy is still staged.
            }
          }
          // If Breakpad wrote the minidump inside a `<uuid>.run` directory,
          // remove any companion envelope/crash marker in that `.run` folder so
          // `sentry_init()` does not upload a duplicate on startup.
          final parent = dump.parent;
          if (_basename(parent.path).endsWith('.run') &&
              parent.path != nativeDir.path) {
            try {
              parent.deleteSync(recursive: true);
            } on FileSystemException {
              // Best effort.
            }
          }
        }
      }
    }
    return listStagedMinidumps();
  }

  /// Lists all `.dmp` minidumps currently waiting in `sentry-pending/`.
  List<PendingCrashReport> listStagedMinidumps() {
    final pendingDir = Directory(pendingDirectoryPath);
    if (!pendingDir.existsSync()) {
      return const <PendingCrashReport>[];
    }
    final files = _findMinidumpFiles(pendingDir);
    files.sort((a, b) => a.path.compareTo(b.path));
    final reports = <PendingCrashReport>[];
    for (final file in files) {
      FileStat stat;
      try {
        stat = file.statSync();
      } on FileSystemException {
        continue;
      }
      final name = _basename(file.path);
      final sizeKb = (stat.size / 1024).ceil();
      reports.add(
        PendingCrashReport.nativeMinidump(
          id: 'native:$name',
          summary: 'Tasks Viewer closed unexpectedly in native code.',
          details:
              'Crash type: Windows native crash minidump\n'
              'File: $name ($sizeKb KB)\n'
              'Captured: ${stat.modified.toUtc().toIso8601String()}\n'
              'Note: A native minidump contains thread stacks and loaded '
              'module addresses so the crash location can be symbolicated.',
          occurredAt: stat.modified.toUtc(),
          minidumpPath: file.path,
          minidumpFileName: name,
          minidumpBytes: stat.size,
        ),
      );
    }
    return List<PendingCrashReport>.unmodifiable(reports);
  }

  void deleteStagedFile(String path) {
    final file = File(path);
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Best effort.
      }
    }
  }

  List<File> _findMinidumpFiles(Directory root) {
    final result = <File>[];
    try {
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.dmp')) {
          result.add(entity);
        }
      }
    } on FileSystemException {
      // Ignore unreadable directories.
    }
    return result;
  }

  static String _uniquePath(String directory, String fileName) {
    var candidate = joinViewerPath(directory, fileName);
    var counter = 1;
    while (File(candidate).existsSync()) {
      counter++;
      candidate = joinViewerPath(directory, '${counter}_$fileName');
    }
    return candidate;
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final index = slash > backslash ? slash : backslash;
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// Redacts credential markers and user profile names from text diagnostics.
String scrubCrashText(String input) {
  var text = input;
  // Store reversed prefixes so AOT snapshots never embed literal
  // credential-scanner markers in `data/app.so`.
  const reversedPrefixes = <String>[
    '_uyrtns',
    '_syrtns',
    'YEK_IPA_SBALNEVELE',
    'yek-ipa-ix',
    ' reraeB',
    ' erutangiS',
  ];
  for (final reversed in reversedPrefixes) {
    final needle = String.fromCharCodes(reversed.codeUnits.reversed);
    var cursor = 0;
    while (true) {
      final start = text.indexOf(needle, cursor);
      if (start < 0) {
        break;
      }
      final after = start + needle.length;
      var end = text.length;
      for (var i = after; i < text.length; i++) {
        final code = text.codeUnitAt(i);
        if (code <= 0x20 ||
            code == 0x22 || // "
            code == 0x27 || // '
            code == 0x2C || // ,
            code == 0x3B || // ;
            code == 0x29) {
          // )
          end = i;
          break;
        }
      }
      text = '${text.substring(0, start)}[REDACTED]${text.substring(end)}';
      cursor = start + '[REDACTED]'.length;
    }
  }
  // Redact Windows user profile directory names (e.g., C:\Users\alice\...).
  text = text.replaceAllMapped(
    RegExp(r'([A-Za-z]:[\\/]Users[\\/])([^\\/\s"\x27]+)', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]',
  );
  return text;
}

bool _isSensitiveKey(String key) {
  final lower = key.toLowerCase();
  const needles = <String>[
    'auth',
    'token',
    'secret',
    'password',
    'cookie',
    'clipboard',
    'body',
    'title',
    'draft',
    'key',
    'env',
  ];
  for (final needle in needles) {
    if (lower.contains(needle)) {
      return true;
    }
  }
  return false;
}

/// Strips user identity, HTTP requests, sensitive extras, and credential tokens
/// from a [SentryEvent] before transmission or display in the review dialog.
SentryEvent scrubSentryEvent(SentryEvent event) {
  event.user = null;
  event.request = null;

  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(
      scrubCrashText(message.formatted),
      template: message.template != null
          ? scrubCrashText(message.template!)
          : null,
    );
  }

  final exceptions = event.exceptions;
  if (exceptions != null) {
    event.exceptions = <SentryException>[
      for (final exception in exceptions)
        SentryException(
          type: exception.type,
          value: exception.value != null
              ? scrubCrashText(exception.value!)
              : null,
          module: exception.module,
          stackTrace: exception.stackTrace,
          mechanism: exception.mechanism,
          threadId: exception.threadId,
        ),
    ];
  }

  // ignore: deprecated_member_use
  final extra = event.extra;
  if (extra != null) {
    // ignore: deprecated_member_use
    event.extra = <String, dynamic>{
      for (final entry in extra.entries)
        if (!_isSensitiveKey(entry.key))
          entry.key: entry.value is String
              ? scrubCrashText(entry.value as String)
              : entry.value,
    };
  }

  final breadcrumbs = event.breadcrumbs;
  if (breadcrumbs != null) {
    event.breadcrumbs = <Breadcrumb>[
      for (final crumb in breadcrumbs)
        Breadcrumb(
          message: crumb.message != null
              ? scrubCrashText(crumb.message!)
              : null,
          timestamp: crumb.timestamp,
          category: crumb.category,
          type: crumb.type,
          level: crumb.level,
          data: crumb.data == null
              ? null
              : <String, dynamic>{
                  for (final entry in crumb.data!.entries)
                    if (!_isSensitiveKey(entry.key))
                      entry.key: entry.value is String
                          ? scrubCrashText(entry.value as String)
                          : entry.value,
                },
        ),
    ];
  }

  return event;
}

/// Formats a concise, readable, already-scrubbed preview for the crash dialog.
String formatScrubbedEventDetails(SentryEvent event) {
  final lines = <String>[
    'Event ID: ${event.eventId}',
    if (event.release != null) 'Release: ${event.release}',
    if (event.level != null) 'Level: ${event.level!.name}',
  ];
  final exceptions = event.exceptions;
  if (exceptions != null && exceptions.isNotEmpty) {
    for (final exception in exceptions) {
      final header = [
        if (exception.type != null) exception.type!,
        if (exception.value != null && exception.value!.isNotEmpty)
          exception.value!,
      ].join(': ');
      if (header.isNotEmpty) {
        lines.add('');
        lines.add(header);
      }
      final frames = exception.stackTrace?.frames;
      if (frames != null && frames.isNotEmpty) {
        for (final frame in frames.reversed.take(16)) {
          final location = [
            if (frame.fileName != null) frame.fileName!,
            if (frame.lineNo != null) '${frame.lineNo}',
          ].join(':');
          final fn = frame.function ?? '<anonymous>';
          lines.add('  at $fn${location.isEmpty ? '' : ' ($location)'}');
        }
      }
    }
  } else if (event.message != null) {
    lines.add('');
    lines.add(event.message!.formatted);
  }
  return lines.join('\n');
}

String _summaryForEvent(SentryEvent event) {
  final exceptions = event.exceptions;
  if (exceptions != null && exceptions.isNotEmpty) {
    final first = exceptions.first;
    final type = first.type ?? 'Unhandled error';
    final value = first.value;
    if (value != null && value.isNotEmpty) {
      return '$type: $value';
    }
    return type;
  }
  final msg = event.message?.formatted;
  if (msg != null && msg.isNotEmpty) {
    return msg;
  }
  return 'An unexpected error occurred in Tasks Viewer.';
}

/// Coordinates Sentry initialization, consent changes, scrubbing, and
/// confirmation-gated crash uploads for one viewer process.
class ViewerCrashReporter extends ChangeNotifier {
  ViewerCrashReporter({
    required String settingsRoot,
    required ViewerCrashReportingMode initialMode,
    required this.enabledForLaunch,
    String dsn = viewerCompiledSentryDsn,
    String release = viewerCompiledSentryRelease,
    Map<String, String>? environment,
    CrashReportBackend? backend,
    PendingNativeCrashStore? nativeStore,
  }) : _mode = initialMode,
       _dsn = dsn.trim(),
       _release = release.trim(),
       _environment = environment ?? Platform.environment,
       _backend = backend ?? SentryFlutterCrashBackend(),
       _nativeStore =
           nativeStore ?? PendingNativeCrashStore(settingsRoot: settingsRoot);

  static const int _maxPendingReports = 5;

  final bool enabledForLaunch;
  final String _dsn;
  final String _release;
  final Map<String, String> _environment;
  final CrashReportBackend _backend;
  final PendingNativeCrashStore _nativeStore;

  ViewerCrashReportingMode _mode;
  final List<PendingCrashReport> _pendingReports = <PendingCrashReport>[];
  int _dartReportSequence = 0;

  ViewerCrashReportingMode get mode => _mode;

  bool get isInitialized => _backend.isInitialized;

  List<PendingCrashReport> get pendingReports =>
      List<PendingCrashReport>.unmodifiable(_pendingReports);

  bool get hasPendingReports => _pendingReports.isNotEmpty;

  PendingCrashReport? get nextPendingReport =>
      _pendingReports.isEmpty ? null : _pendingReports.first;

  bool get isKillSwitched {
    final raw = (_environment['TASKS_NO_SENTRY'] ?? '').trim().toLowerCase();
    return raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on';
  }

  /// True when this process is permitted to initialize Sentry if opted in.
  bool get canInitialize =>
      enabledForLaunch && !isKillSwitched && _dsn.isNotEmpty;

  /// Initializes crash reporting according to the saved preference.
  Future<void> initialize() async {
    if (!canInitialize || _mode == ViewerCrashReportingMode.off) {
      return;
    }
    if (_mode == ViewerCrashReportingMode.ask) {
      final staged = _nativeStore.stageAndListPendingMinidumps();
      if (staged.isNotEmpty) {
        for (final report in staged) {
          _enqueueUnique(report);
        }
        notifyListeners();
      }
    }
    await _ensureBackendInitialized();
    if (_mode == ViewerCrashReportingMode.always) {
      final leftover = _nativeStore.listStagedMinidumps();
      for (final report in leftover) {
        await _uploadNativeReport(report);
      }
    }
  }

  /// Updates the active consent mode when Settings is saved or when the user
  /// picks "Always send" in the crash dialog.
  Future<void> applyMode(ViewerCrashReportingMode nextMode) async {
    if (_mode == nextMode) {
      if (nextMode == ViewerCrashReportingMode.always &&
          _pendingReports.isNotEmpty) {
        await _flushPendingReports();
      }
      return;
    }
    _mode = nextMode;
    if (nextMode == ViewerCrashReportingMode.off) {
      _pendingReports.clear();
      notifyListeners();
      await _backend.close();
      return;
    }
    if (!canInitialize) {
      return;
    }
    if (nextMode == ViewerCrashReportingMode.ask && !_backend.isInitialized) {
      final staged = _nativeStore.stageAndListPendingMinidumps();
      for (final report in staged) {
        _enqueueUnique(report);
      }
    }
    await _ensureBackendInitialized();
    if (nextMode == ViewerCrashReportingMode.always) {
      await _flushPendingReports();
      final leftover = _nativeStore.listStagedMinidumps();
      for (final report in leftover) {
        await _uploadNativeReport(report);
      }
    }
    notifyListeners();
  }

  /// Sentry `beforeSend` hook (exposed for direct unit testing).
  @visibleForTesting
  SentryEvent? handleBeforeSend(SentryEvent event, Hint hint) {
    final scrubbed = scrubSentryEvent(event);
    if (_mode == ViewerCrashReportingMode.off) {
      return null;
    }
    if (_mode == ViewerCrashReportingMode.always) {
      return scrubbed;
    }
    if (hint.get(approvedCrashReportHintKey) == true) {
      return scrubbed;
    }
    if (_pendingReports.length < _maxPendingReports) {
      _dartReportSequence++;
      _pendingReports.add(
        PendingCrashReport.dart(
          id: 'dart:$_dartReportSequence:${scrubbed.eventId}',
          summary: _summaryForEvent(scrubbed),
          details: formatScrubbedEventDetails(scrubbed),
          occurredAt: (scrubbed.timestamp ?? DateTime.now()).toUtc(),
          event: scrubbed,
        ),
      );
      notifyListeners();
    }
    return null;
  }

  /// Sends one pending crash report after the user approved it.
  Future<void> sendPendingReport(PendingCrashReport report) async {
    _pendingReports.removeWhere((item) => item.id == report.id);
    notifyListeners();
    if (!canInitialize) {
      return;
    }
    await _ensureBackendInitialized();
    if (report.kind == PendingCrashKind.dart) {
      final event = report.event;
      if (event != null) {
        await _backend.captureApprovedEvent(event);
      }
    } else {
      await _uploadNativeReport(report);
    }
  }

  /// Discards one pending crash report and deletes any staged minidump file.
  Future<void> discardPendingReport(PendingCrashReport report) async {
    _pendingReports.removeWhere((item) => item.id == report.id);
    notifyListeners();
    final path = report.minidumpPath;
    if (path != null) {
      _nativeStore.deleteStagedFile(path);
    }
  }

  /// Cleanly closes Sentry on normal window shutdown.
  Future<void> close() async {
    await _backend.close();
  }

  Future<void> _ensureBackendInitialized() async {
    if (_backend.isInitialized || !canInitialize) {
      return;
    }
    await _backend.init(
      dsn: _dsn,
      release: _release.isEmpty ? null : _release,
      nativeDatabasePath: _nativeStore.nativeDatabasePath,
      beforeSend: handleBeforeSend,
    );
  }

  Future<void> _flushPendingReports() async {
    final batch = List<PendingCrashReport>.of(_pendingReports);
    _pendingReports.clear();
    notifyListeners();
    for (final report in batch) {
      await sendPendingReport(report);
    }
  }

  Future<void> _uploadNativeReport(PendingCrashReport report) async {
    final path = report.minidumpPath;
    final name = report.minidumpFileName;
    if (path == null || name == null) {
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      return;
    }
    final bytes = file.readAsBytesSync();
    await _backend.captureNativeMinidump(
      bytes: bytes,
      fileName: name,
      release: _release.isEmpty ? null : _release,
    );
    _nativeStore.deleteStagedFile(path);
  }

  void _enqueueUnique(PendingCrashReport report) {
    if (_pendingReports.length >= _maxPendingReports) {
      return;
    }
    if (_pendingReports.any((item) => item.id == report.id)) {
      return;
    }
    _pendingReports.add(report);
  }
}
