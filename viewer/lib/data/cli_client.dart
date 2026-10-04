/// The viewer's only route to task data: one short-lived `tasks` process per
/// read (viewer/spec.md sections 3.2 and 4.1).
///
/// Rules implemented here:
/// * the executable is resolved from the launch argument, the saved setting and
///   the bundle beside the viewer; PATH is never searched;
/// * the request document travels as UTF-8 JSON on stdin and stdin is closed
///   right after the write, so no command-line length limit applies;
/// * stdout and stderr are drained concurrently and the whole read is bounded
///   by a timeout;
/// * `probe()` (`viewer info`) must pass before any data command runs;
/// * a superseded read is killed, and nothing else ever is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../app_environment.dart';
import 'editor_models.dart';
import 'models.dart';
import 'project_archive.dart';
import 'settings_draft.dart';
import 'settings_store.dart' show joinViewerPath;

/// Protocol request size limit (viewer/spec.md section 4.1).
const int viewerRequestByteLimit = 8 * 1024 * 1024;

/// Read timeout for one CLI invocation.
const Duration viewerReadTimeout = Duration(seconds: 30);

/// Minimal CLI-owned receipt metadata. No request body is stored in Dart.
final class ViewerPendingReceipt {
  const ViewerPendingReceipt(
    this.requestId,
    this.projectId,
    this.operation, {
    this.taskId,
    this.archived,
    this.outcomeKnown = false,
  });

  final String requestId;
  final String? projectId;
  final String operation;
  final int? taskId;
  final bool? archived;
  final bool outcomeKnown;

  factory ViewerPendingReceipt.fromJson(Map<String, Object?> json) {
    final id = json['request_id'];
    final projectId = json['project_id'];
    final operation = json['operation'];
    final taskId = json['task_id'];
    final archived = json['archived'];
    final known = json['outcome_known'];
    if (id is! String ||
        (projectId != null && projectId is! String) ||
        operation is! String ||
        (taskId != null && taskId is! int) ||
        (archived != null && archived is! bool) ||
        known is! bool) {
      throw const ViewerMalformedResponseFailure(
        'invalid pending receipt metadata',
      );
    }
    return ViewerPendingReceipt(
      id,
      projectId as String?,
      operation,
      taskId: taskId as int?,
      archived: archived as bool?,
      outcomeKnown: known,
    );
  }
}

/// One running CLI process, as far as the client needs it.
///
/// Implemented by [SystemProcessLauncher]; tests supply their own so fault
/// injection never starts a real process.
abstract interface class ViewerProcessHandle {
  /// Appends one already-encoded request document to the process stdin.
  void addStdin(List<int> bytes);

  /// Closes stdin so the CLI sees end of input.
  Future<void> closeStdin();

  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<int> get exitCode;

  /// Terminates the process. Only ever called for a viewer-owned read that was
  /// superseded or that timed out.
  void kill();
}

/// Starts CLI processes. Injected so tests can fault-inject.
abstract interface class ProcessLauncher {
  Future<ViewerProcessHandle> start(String executable, List<String> arguments);
}

/// The production launcher: an argument array, never a shell command line.
class SystemProcessLauncher implements ProcessLauncher {
  const SystemProcessLauncher();

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    return _SystemProcessHandle(process);
  }
}

class _SystemProcessHandle implements ViewerProcessHandle {
  _SystemProcessHandle(this._process);

  final Process _process;

  @override
  void addStdin(List<int> bytes) => _process.stdin.add(bytes);

  @override
  Future<void> closeStdin() => _process.stdin.close();

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// Which executable the client resolved and what it considered first.
final class ViewerCliResolution {
  const ViewerCliResolution({
    required this.executable,
    required this.attemptedPaths,
  });

  final String? executable;
  final List<String> attemptedPaths;
}

/// Reads task data by running the CLI once per request.
class ViewerCliClient
    implements
        CancellableProjectReader,
        CancellableTaskReader,
        CancellableTaskDetailReader,
        TaskUpdateWriter,
        TaskWriteReconciler,
        ClipboardEnricher,
        ProjectArchiveWriter {
  ViewerCliClient({
    required this.environment,
    ViewerSettingsDraftSource? savedSettings,
    ProcessLauncher launcher = const SystemProcessLauncher(),
    String? bundledExecutableDirectory,
    bool Function(String path)? executableExists,
    this.readTimeout = viewerReadTimeout,
    this.requestByteLimit = viewerRequestByteLimit,
  }) : // Private fields cannot be named parameters, so the lint cannot apply.
       // ignore: prefer_initializing_formals
       _savedSettings = savedSettings,
       // ignore: prefer_initializing_formals
       _launcher = launcher,
       _bundledExecutableDirectory =
           bundledExecutableDirectory ??
           File(Platform.resolvedExecutable).parent.path,
       _executableExists = executableExists ?? _defaultExecutableExists;

  /// Resolved launch configuration: the data root and the CLI candidates.
  final ViewerEnvironment environment;

  final Duration readTimeout;
  final int requestByteLimit;

  final ViewerSettingsDraftSource? _savedSettings;
  final ProcessLauncher _launcher;
  final String _bundledExecutableDirectory;
  final bool Function(String path) _executableExists;

  final Map<String, _ActiveRead> _activeReads = <String, _ActiveRead>{};

  bool _probePassed = false;
  ViewerInfo? _info;
  final List<ViewerPendingReceipt> _pendingReceipts = <ViewerPendingReceipt>[];
  final Map<String, ViewerUpdateResult> _confirmedTaskResults =
      <String, ViewerUpdateResult>{};
  final Map<String, bool> _originalWriteExited = <String, bool>{};
  final Set<String> _timedOutWrites = <String>{};
  Future<int>? _localWriterExit;

  List<ViewerPendingReceipt> get pendingReceipts =>
      List<ViewerPendingReceipt>.unmodifiable(_pendingReceipts);

  bool get hasPendingReceipt => _pendingReceipts.isNotEmpty;
  @override
  bool get usesRemoteReceipts => _info?.isRemote ?? false;

  @override
  bool hasPendingTask(String projectId, int taskId) => _pendingReceipts.any(
    (receipt) =>
        receipt.projectId?.toLowerCase() == projectId.toLowerCase() &&
        receipt.taskId == taskId &&
        receipt.operation == 'viewer_update',
  );

  /// True once `viewer info` decoded with a supported protocol version.
  bool get probePassed => _probePassed;

  /// The last successful handshake payload.
  ViewerInfo? get info => _info;

  /// Name of the executable bundled beside the viewer.
  static String get bundledExecutableName =>
      Platform.isWindows ? 'tasks.exe' : 'tasks';

  static bool _defaultExecutableExists(String path) => File(path).existsSync();

  /// Resolves the CLI in the documented order; PATH is never a candidate.
  ViewerCliResolution resolveExecutable() {
    final attempted = <String>[];
    void consider(String? candidate) {
      if (candidate == null || candidate.isEmpty) {
        return;
      }
      if (!attempted.contains(candidate)) {
        attempted.add(candidate);
      }
    }

    consider(environment.tasksExe);
    consider(_savedSettings?.call().cliPath);
    final bundled = joinViewerPath(
      _bundledExecutableDirectory,
      bundledExecutableName,
    );
    consider(bundled);

    for (final candidate in attempted) {
      if (_executableExists(candidate)) {
        return ViewerCliResolution(
          executable: candidate,
          attemptedPaths: List<String>.unmodifiable(attempted),
        );
      }
    }
    return ViewerCliResolution(
      executable: null,
      attemptedPaths: List<String>.unmodifiable(attempted),
    );
  }

  /// Runs `viewer info`; a passing probe is required before any data action.
  Future<ViewerInfo> probe({bool force = false}) async {
    final cached = _info;
    if (_probePassed && !force && cached != null) {
      return cached;
    }
    final dataRoot = environment.dataRoot;
    final envelope = await _runViewerCommand(
      scopeKey: 'probe',
      arguments: <String>[
        if (dataRoot != null && dataRoot.isNotEmpty) ...<String>[
          '--data-root',
          dataRoot,
        ],
        '--format',
        'json',
        'viewer',
        'info',
      ],
      request: null,
      expectedCommands: const <String>{'viewer_info'},
    );
    final decoded = ViewerInfo.fromJson(envelope.data);
    if (decoded.isRemote) {
      if (!decoded.receiptRecovery) {
        throw const ViewerMalformedResponseFailure(
          'remote CLI does not support viewer receipt recovery',
        );
      }
      await _refreshPendingReceipts();
    } else {
      _pendingReceipts.clear();
    }
    _info = decoded;
    _probePassed = true;
    return decoded;
  }

  /// Loads one page of the project catalog.
  @override
  Future<ProjectPage> fetchProjects(ProjectQuery query) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final dataRoot = _requireDataRoot('loading projects');
    final envelope = await _runViewerCommand(
      scopeKey: 'projects',
      arguments: <String>[
        '--data-root',
        dataRoot,
        '--format',
        'json',
        'viewer',
        'projects',
        '--request-file',
        '-',
      ],
      request: query.toJson(),
      expectedCommands: const <String>{'viewer_projects'},
    );
    return ProjectPage.fromJson(envelope.data);
  }

  @override
  Future<int?> setProjectArchived(
    String projectId, {
    required bool archived,
  }) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final remote = _info?.isRemote ?? false;
    if (remote) _requireNoPendingReceipt();
    if (remote) {
      _originalWriteExited.clear();
      _timedOutWrites.clear();
    }
    final requestId = remote ? _newRequestId() : null;
    if (requestId != null) {
      _pendingReceipts.add(
        ViewerPendingReceipt(
          requestId,
          projectId,
          'archive',
          archived: archived,
        ),
      );
    }
    final ViewerEnvelope envelope;
    try {
      envelope = await _runViewerCommand(
        scopeKey: 'project-archive',
        arguments: <String>[
          '--data-root',
          _requireDataRoot('changing the project archive state'),
          '--project',
          projectId,
          '--format',
          'json',
          'viewer',
          'archive',
          if (requestId != null) ...<String>['--request-id', requestId],
          if (!archived) '--unarchive',
        ],
        request: null,
        expectedCommands: const <String>{'viewer_archive'},
        cancellable: false,
        originalWriteId: requestId,
        localMutation: !remote,
      );
      _requireProjectEcho(envelope, projectId);
    } on ViewerCliErrorFailure catch (error) {
      if (requestId != null) await _settleRemoteWriteError(requestId, error);
      rethrow;
    } on ViewerRequestTooLargeFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    } on ViewerProcessStartFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    } on ViewerExecutableNotFoundFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    }
    final value = envelope.data['archived_at_ms'];
    if (value != null && value is! int) {
      throw const ViewerMalformedResponseFailure(
        'viewer archive returned an invalid archived_at_ms',
      );
    }
    if ((archived && value == null) || (!archived && value != null)) {
      throw const ViewerMalformedResponseFailure(
        'viewer archive returned the wrong archive state',
      );
    }
    if (requestId != null) await _acknowledge(requestId);
    return value as int?;
  }

  /// Loads one page of the combined task query for [projectId].
  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final envelope = await _runViewerCommand(
      scopeKey: 'tasks',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('loading tasks'),
        '--project',
        projectId,
        '--format',
        'json',
        'viewer',
        'tasks',
        '--request-file',
        '-',
      ],
      request: query.toJson(),
      expectedCommands: const <String>{'viewer_tasks'},
    );
    _requireProjectEcho(envelope, projectId);
    return TaskPage.fromJson(envelope.data);
  }

  /// Loads the complete record for one task.
  @override
  Future<TaskDetail> fetchTaskDetail(String projectId, int taskId) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final envelope = await _runViewerCommand(
      scopeKey: 'detail',
      waitForLocalWriter: true,
      arguments: <String>[
        '--data-root',
        _requireDataRoot('loading a task'),
        '--project',
        projectId,
        '--format',
        'json',
        'viewer',
        'show',
        viewerCanonicalTaskId(taskId),
      ],
      request: null,
      expectedCommands: const <String>{'viewer_show'},
    );
    _requireProjectEcho(envelope, projectId);
    return TaskDetail.fromJson(envelope.data);
  }

  /// Loads one page of a task's append-only history.
  ///
  /// History reuses the existing `history` command: the viewer protocol has no
  /// history operation, and the legacy command already returns complete
  /// snapshot text for one event.
  @override
  Future<TaskHistoryPage> fetchTaskHistory(
    String projectId,
    int taskId, {
    int? after,
    int limit = 100,
    int? event,
  }) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final envelope = await _runViewerCommand(
      scopeKey: 'history',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('loading task history'),
        '--project',
        projectId,
        '--format',
        'json',
        'history',
        viewerCanonicalTaskId(taskId),
        '--limit',
        '$limit',
        if (after != null) ...<String>['--after', '$after'],
        if (event != null) ...<String>['--event', '$event'],
      ],
      request: null,
      expectedCommands: const <String>{'history'},
    );
    _requireProjectEcho(envelope, projectId);
    return TaskHistoryPage.fromJson(envelope.data);
  }

  /// Applies one version-checked edit (viewer/spec.md section 7).
  ///
  /// The request travels on stdin, so a large body or dependency list never
  /// hits a command-line length limit. A rejected update arrives as a
  /// [ViewerCliErrorFailure] with its `validation` or `version_conflict` code
  /// and the conflict versions intact.
  @override
  Future<ViewerUpdateResult> updateTask(
    String projectId,
    ViewerUpdateRequest request,
  ) async {
    final remote = _info?.isRemote ?? false;
    if (remote) _requireNoPendingReceipt();
    if (remote) _confirmedTaskResults.clear();
    if (remote) {
      _originalWriteExited.clear();
      _timedOutWrites.clear();
    }
    final requestId = remote ? _newRequestId() : null;
    final effectiveRequest = requestId == null
        ? request
        : ViewerUpdateRequest(
            id: request.id,
            expectVersion: request.expectVersion,
            changes: request.changes,
            requestId: requestId,
          );
    if (requestId != null) {
      _pendingReceipts.add(
        ViewerPendingReceipt(
          requestId,
          projectId,
          'viewer_update',
          taskId: request.id,
        ),
      );
    }
    try {
      final envelope = await _updateTaskEnvelope(projectId, effectiveRequest);
      _requireProjectEcho(envelope, projectId);
      final result = ViewerUpdateResult.fromJson(envelope.data);
      if (result.id != request.id ||
          result.version !=
              request.expectVersion + (result.eventId == null ? 0 : 1) ||
          (request.changes.status != null &&
              result.status != request.changes.status)) {
        throw const ViewerMalformedResponseFailure(
          'viewer update returned a mismatched task or version',
        );
      }
      if (requestId != null) await _acknowledge(requestId);
      return result;
    } on ViewerCliErrorFailure catch (error) {
      if (requestId != null) await _settleRemoteWriteError(requestId, error);
      rethrow;
    } on ViewerRequestTooLargeFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    } on ViewerProcessStartFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    } on ViewerExecutableNotFoundFailure {
      if (requestId != null) {
        _pendingReceipts.removeWhere((item) => item.requestId == requestId);
      }
      rethrow;
    }
  }

  Future<ViewerEnvelope> _updateTaskEnvelope(
    String projectId,
    ViewerUpdateRequest request,
  ) {
    if (!_probePassed) {
      return Future<ViewerEnvelope>.error(const ViewerProbeRequiredFailure());
    }
    return _runViewerCommand(
      scopeKey: 'update',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('saving a task'),
        '--project',
        projectId,
        '--format',
        'json',
        'viewer',
        'update',
        '--request-file',
        '-',
      ],
      request: request.toJson(),
      expectedCommands: const <String>{'viewer_update'},
      cancellable: false,
      originalWriteId: request.requestId,
      localMutation: request.requestId == null,
    );
  }

  /// Runs `enrich-clipboard` for one captured project scope.
  ///
  /// The CLI reads the clipboard, checks it still matches before replacing it
  /// and reports the counts; this client never reads or writes the clipboard
  /// itself, so no read-transform-write logic is duplicated in Dart.
  @override
  Future<ClipboardEnrichment> enrichClipboard(String projectId) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final envelope = await _runViewerCommand(
      scopeKey: 'clipboard',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('enriching the clipboard'),
        '--project',
        projectId,
        '--format',
        'json',
        'enrich-clipboard',
      ],
      request: null,
      expectedCommands: const <String>{'enrich'},
    );
    _requireProjectEcho(envelope, projectId);
    return ClipboardEnrichment.fromJson(envelope.data);
  }

  /// Runs `enrich --file -` with [text] on stdin.
  ///
  /// The preview route: the caller already read the plain-text clipboard, and
  /// nothing here writes it back. The CLI owns the 16 MiB input and 10,000
  /// distinct-reference limits and reports them as ordinary validation errors.
  @override
  Future<ClipboardEnrichment> enrichText(String projectId, String text) async {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    final envelope = await _runViewerCommand(
      scopeKey: 'clipboard',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('previewing enrichment'),
        '--project',
        projectId,
        '--format',
        'json',
        'enrich',
        '--file',
        '-',
      ],
      request: null,
      rawStdin: utf8.encode(text),
      expectedCommands: const <String>{'enrich'},
    );
    _requireProjectEcho(envelope, projectId);
    return ClipboardEnrichment.fromJson(envelope.data);
  }

  String _requireDataRoot(String action) {
    final dataRoot = environment.dataRoot;
    if (dataRoot == null || dataRoot.isEmpty) {
      throw ViewerCliErrorFailure(
        code: 'no_store',
        message:
            'No task data root is configured. Choose one in Settings before '
            '$action.',
        exitCode: 2,
      );
    }
    return dataRoot;
  }

  /// Rejects a response that belongs to another project UUID.
  ///
  /// Every project-scoped read passes its UUID explicitly, so an answer for a
  /// different project is a routing bug, not usable data.
  void _requireProjectEcho(ViewerEnvelope envelope, String projectId) {
    final echo = envelope.projectId;
    if (echo == null) {
      throw const ViewerMalformedResponseFailure(
        'a project-scoped response did not echo its project_id',
      );
    }
    if (echo.toLowerCase() != projectId.toLowerCase()) {
      throw ViewerMalformedResponseFailure(
        'the tasks CLI answered for project $echo instead of $projectId',
      );
    }
  }

  void _requireNoPendingReceipt() {
    if (_pendingReceipts.isNotEmpty) {
      throw ViewerPendingReceiptFailure(_pendingReceipts.first.requestId);
    }
  }

  static bool _isTerminalRefusal(ViewerCliErrorFailure error) =>
      error.exitCode == 2 || error.exitCode == 3 || error.exitCode == 4;

  Future<void> _settleRemoteWriteError(
    String requestId,
    ViewerCliErrorFailure error,
  ) async {
    // The CLI exited. Its local receipt distinguishes a preflight outage from
    // a dispatched write; the next request does not contact the service.
    try {
      await _refreshPendingReceipts();
    } on ViewerFailure catch (failure) {
      throw ViewerPendingReceiptFailure(requestId, failure.message);
    }
    final pending = _pendingReceipts
        .where((item) => item.requestId == requestId)
        .firstOrNull;
    if (pending == null) {
      if (error.code == 'unparsed_error') {
        throw ViewerCliErrorFailure(
          code: 'write_not_dispatched',
          message:
              'The CLI exited without retaining a request. The draft is preserved: ${error.message}',
          exitCode: error.exitCode,
        );
      }
      return;
    }
    if (_isTerminalRefusal(error) && pending.outcomeKnown) {
      await _acknowledge(requestId);
      return;
    }
    throw ViewerPendingReceiptFailure(requestId, error.message);
  }

  Future<void> _refreshPendingReceipts() async {
    final envelope = await _runViewerCommand(
      scopeKey: 'receipt-recovery',
      arguments: <String>[
        '--data-root',
        _requireDataRoot('checking pending changes'),
        '--format',
        'json',
        'viewer',
        'recovery',
      ],
      request: null,
      expectedCommands: const <String>{'viewer_recovery'},
    );
    final items = envelope.data['items'];
    if (items is! List<Object?>) {
      throw const ViewerMalformedResponseFailure('viewer recovery needs items');
    }
    final parsed = <ViewerPendingReceipt>[];
    for (final item in items) {
      if (item is! Map<String, Object?>) {
        throw const ViewerMalformedResponseFailure(
          'invalid viewer recovery item',
        );
      }
      parsed.add(ViewerPendingReceipt.fromJson(item));
    }
    _pendingReceipts
      ..clear()
      ..addAll(parsed);
  }

  Future<void> _acknowledge(String requestId) async {
    try {
      final envelope = await _runViewerCommand(
        scopeKey: 'receipt-acknowledge',
        arguments: <String>[
          '--data-root',
          _requireDataRoot('acknowledging a change'),
          '--format',
          'json',
          'viewer',
          'acknowledge',
          requestId,
        ],
        request: null,
        expectedCommands: const <String>{'viewer_acknowledge'},
        cancellable: false,
      );
      if (envelope.data['request_id'] != requestId ||
          envelope.data['acknowledged'] != true) {
        throw const ViewerMalformedResponseFailure('invalid acknowledgement');
      }
      _pendingReceipts.removeWhere((item) => item.requestId == requestId);
    } on ViewerFailure catch (error) {
      // The original result was already validated. Lost cleanup stdout needs
      // a local receipt check, never a resend of the original mutation.
      try {
        await _refreshPendingReceipts();
        if (!_pendingReceipts.any((item) => item.requestId == requestId)) {
          return;
        }
      } on ViewerFailure {
        // Retain the known result and its cleanup uncertainty.
      }
      throw ViewerPendingReceiptFailure(
        requestId,
        'The result was confirmed, but its receipt could not be cleared: ${error.message}',
      );
    }
  }

  /// Checks exactly the stored remote request, then clears its confirmed receipt.
  @override
  Future<ViewerUpdateResult> reconcileTaskWrite(
    String projectId,
    int taskId,
  ) async {
    final cacheKey = '${projectId.toLowerCase()}:$taskId';
    final matching = _pendingReceipts
        .where(
          (item) =>
              item.projectId?.toLowerCase() == projectId.toLowerCase() &&
              item.taskId == taskId &&
              item.operation == 'viewer_update',
        )
        .toList();
    if (matching.length != 1) {
      final confirmed = _confirmedTaskResults[cacheKey];
      if (matching.isEmpty && confirmed != null) return confirmed;
      throw const ViewerMalformedResponseFailure(
        'expected one pending update receipt for this task',
      );
    }
    final receipt = matching.single;
    await _checkOriginalWriteState(receipt.requestId);
    try {
      final envelope = await _runViewerCommand(
        scopeKey: 'receipt-reconcile',
        arguments: <String>[
          '--data-root',
          _requireDataRoot('checking a pending change'),
          '--format',
          'json',
          'viewer',
          'reconcile',
          receipt.requestId,
        ],
        request: null,
        expectedCommands: const <String>{'viewer_update'},
        cancellable: false,
      );
      _requireProjectEcho(envelope, projectId);
      final result = ViewerUpdateResult.fromJson(envelope.data);
      if (result.id != taskId) {
        throw const ViewerMalformedResponseFailure(
          'reconciled task ID differs',
        );
      }
      _confirmedTaskResults
        ..clear()
        ..[cacheKey] = result;
      await _acknowledge(receipt.requestId);
      return result;
    } on ViewerCliErrorFailure catch (error) {
      if (_isTerminalRefusal(error)) {
        await _acknowledge(receipt.requestId);
        rethrow;
      }
      throw ViewerPendingReceiptFailure(receipt.requestId, error.message);
    }
  }

  /// Explicit recovery action for a pending archive or another CLI receipt.
  Future<void> checkPendingChange(String requestId) async {
    final receipt = _pendingReceipts
        .where((item) => item.requestId == requestId)
        .firstOrNull;
    if (receipt == null) {
      throw const ViewerMalformedResponseFailure(
        'pending receipt was not found',
      );
    }
    await _checkOriginalWriteState(requestId);
    try {
      final envelope = await _runViewerCommand(
        scopeKey: 'receipt-reconcile',
        arguments: <String>[
          '--data-root',
          _requireDataRoot('checking a pending change'),
          '--format',
          'json',
          'viewer',
          'reconcile',
          requestId,
        ],
        request: null,
        expectedCommands: <String>{
          receipt.operation == 'archive' ? 'viewer_archive' : receipt.operation,
        },
        cancellable: false,
      );
      if (receipt.projectId != null) {
        _requireProjectEcho(envelope, receipt.projectId!);
      }
      if (receipt.operation == 'viewer_update') {
        final result = ViewerUpdateResult.fromJson(envelope.data);
        if (result.id != receipt.taskId) {
          throw const ViewerMalformedResponseFailure(
            'reconciled task ID differs',
          );
        }
      } else if (receipt.operation == 'archive') {
        final archivedAt = envelope.data['archived_at_ms'];
        if (archivedAt != null && archivedAt is! int) {
          throw const ViewerMalformedResponseFailure('invalid archive result');
        }
        if (receipt.archived != null &&
            (receipt.archived! ? archivedAt == null : archivedAt != null)) {
          throw const ViewerMalformedResponseFailure(
            'reconciled archive state differs from the request',
          );
        }
      }
      await _acknowledge(requestId);
    } on ViewerCliErrorFailure catch (error) {
      if (_isTerminalRefusal(error)) {
        await _acknowledge(requestId);
        rethrow;
      }
      throw ViewerPendingReceiptFailure(requestId, error.message);
    }
  }

  static String _newRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _checkOriginalWriteState(String requestId) async {
    if (!_timedOutWrites.contains(requestId)) return;
    if (_originalWriteExited[requestId] != true) {
      throw ViewerPendingReceiptFailure(
        requestId,
        'The original CLI is still running. Wait for it to exit before checking this change.',
      );
    }
    // Only an exited original process can establish that no request was saved.
    // This is a local receipt query, not a second service mutation.
    await _refreshPendingReceipts();
    _timedOutWrites.remove(requestId);
    _originalWriteExited.remove(requestId);
    if (!_pendingReceipts.any((item) => item.requestId == requestId)) {
      throw const ViewerCliErrorFailure(
        code: 'write_not_dispatched',
        message:
            'The original CLI exited without retaining a request. The draft is preserved.',
        exitCode: 6,
      );
    }
  }

  /// Runs an arbitrary `viewer` subcommand; slice 4 and 5 build on it.
  Future<ViewerEnvelope> runViewerCommand({
    required String scopeKey,
    required List<String> arguments,
    Map<String, Object?>? request,
    Set<String>? expectedCommands,
  }) {
    if (!_probePassed) {
      throw const ViewerProbeRequiredFailure();
    }
    return _runViewerCommand(
      scopeKey: scopeKey,
      arguments: arguments,
      request: request,
      expectedCommands: expectedCommands,
    );
  }

  /// Kills the in-flight read for [scopeKey], if any.
  ///
  /// Only this client's own process is ever killed; the caller treats the
  /// resulting [ViewerCancelledFailure] as "superseded, ignore".
  @override
  void cancelScope(String scopeKey) {
    _activeReads[scopeKey]?.cancel();
  }

  // A WAL read can still see the old version while our timed-out writer runs.
  // Wait for its exit before reconciliation or dispatching another local write.
  Future<void> _waitForLocalWriter(Duration timeout, _ActiveRead active) async {
    final exit = _localWriterExit;
    if (exit == null) return;
    try {
      await Future.any<int>(<Future<int>>[
        exit.timeout(timeout),
        active.cancellation.future.then<int>(
          (_) => throw const ViewerCancelledFailure(),
        ),
      ]);
    } on TimeoutException {
      throw ViewerTimeoutFailure(readTimeout);
    } on ViewerCancelledFailure {
      rethrow;
    } on Object catch (error) {
      throw ViewerMalformedResponseFailure(
        'could not observe the local writer exit: $error',
      );
    }
  }

  void _finishLocalWriter(Completer<int>? reservation, int code) {
    if (reservation == null) return;
    if (!reservation.isCompleted) reservation.complete(code);
    if (identical(_localWriterExit, reservation.future)) {
      _localWriterExit = null;
    }
  }

  Future<ViewerEnvelope> _runViewerCommand({
    required String scopeKey,
    required List<String> arguments,
    required Map<String, Object?>? request,
    required Set<String>? expectedCommands,
    List<int>? rawStdin,
    bool cancellable = true,
    String? originalWriteId,
    bool localMutation = false,
    bool waitForLocalWriter = false,
  }) async {
    final resolution = resolveExecutable();
    final executable = resolution.executable;
    if (executable == null) {
      throw ViewerExecutableNotFoundFailure(resolution.attemptedPaths);
    }

    // The size check happens before a process exists. A raw payload is
    // already-encoded caller text: the CLI owns its own limits and this
    // transport adds none.
    final requestBytes =
        rawStdin ?? (request == null ? null : utf8.encode(jsonEncode(request)));
    if (rawStdin == null &&
        requestBytes != null &&
        requestBytes.length > requestByteLimit) {
      throw ViewerRequestTooLargeFailure(
        byteLength: requestBytes.length,
        limitBytes: requestByteLimit,
      );
    }

    final active = _ActiveRead();
    if (cancellable) {
      _activeReads[scopeKey]?.cancel();
      _activeReads[scopeKey] = active;
    }
    final budget = readTimeout;
    final elapsed = Stopwatch()..start();
    Duration remainingBudget() {
      final remaining = budget - elapsed.elapsed;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    Completer<int>? localReservation;
    try {
      if (waitForLocalWriter || localMutation) {
        while (_localWriterExit != null) {
          await _waitForLocalWriter(remainingBudget(), active);
        }
      }
      if (active.cancelled) throw const ViewerCancelledFailure();
      if (localMutation) {
        // Reserve before process launch yields, so another mutation cannot pass
        // the exit wait while this process is still being created.
        localReservation = Completer<int>();
        _localWriterExit = localReservation.future;
      }
    } on Object {
      _release(scopeKey, active);
      rethrow;
    }

    final ViewerProcessHandle handle;
    try {
      handle = await _launcher.start(executable, arguments);
    } on ProcessException catch (error) {
      _finishLocalWriter(localReservation, -1);
      _release(scopeKey, active);
      throw ViewerProcessStartFailure(
        'Could not start "$executable": ${error.message}',
      );
    } on Object catch (error) {
      _finishLocalWriter(localReservation, -1);
      _release(scopeKey, active);
      throw ViewerProcessStartFailure('Could not start "$executable": $error');
    }
    active.handle = handle;
    if (localMutation) {
      unawaited(
        handle.exitCode.then<void>((code) {
          _finishLocalWriter(localReservation, code);
        }, onError: (Object _) {}),
      );
    }
    if (originalWriteId != null) {
      _originalWriteExited[originalWriteId] = false;
      unawaited(
        handle.exitCode.then<void>((_) {
          if (_originalWriteExited.containsKey(originalWriteId)) {
            _originalWriteExited[originalWriteId] = true;
          }
        }, onError: (Object _) {}),
      );
    }
    if (active.cancelled) {
      handle.kill();
      throw const ViewerCancelledFailure();
    }

    if (requestBytes != null) {
      handle.addStdin(requestBytes);
    }
    try {
      await handle.closeStdin();
    } on Object {
      // A process that died before reading stdin reports the real problem on
      // its exit code and stderr; a broken pipe here is not the outcome.
    }

    final drained = Future.wait<Object?>(<Future<Object?>>[
      _drain(handle.stdout),
      _drain(handle.stderr),
      handle.exitCode,
    ]);
    final List<Object?> results;
    try {
      results = await drained.timeout(remainingBudget());
    } on TimeoutException {
      if (originalWriteId != null) _timedOutWrites.add(originalWriteId);
      active.cancelled = cancellable;
      _abandon(drained);
      if (cancellable) handle.kill();
      _release(scopeKey, active);
      throw ViewerTimeoutFailure(readTimeout);
    } on Object catch (error) {
      _abandon(drained);
      if (cancellable) handle.kill();
      _release(scopeKey, active);
      throw ViewerMalformedResponseFailure(
        'could not read the tasks CLI output: $error',
      );
    }
    _release(scopeKey, active);
    if (active.cancelled) {
      throw const ViewerCancelledFailure();
    }

    final stdout = utf8.decode(results[0]! as List<int>, allowMalformed: true);
    final stderr = utf8.decode(results[1]! as List<int>, allowMalformed: true);
    final exitCode = results[2]! as int;

    if (exitCode != 0) {
      final error = ViewerErrorEnvelope.tryDecode(stderr);
      if (error != null) {
        throw error.asFailure(exitCode);
      }
      throw ViewerCliErrorFailure(
        code: 'unparsed_error',
        message:
            _firstLine(stderr) ??
            'The tasks CLI exited with code $exitCode and no diagnostic '
                'message.',
        exitCode: exitCode,
      );
    }
    return ViewerEnvelope.decode(stdout, expectedCommands: expectedCommands);
  }

  void _release(String scopeKey, _ActiveRead active) {
    if (identical(_activeReads[scopeKey], active)) {
      _activeReads.remove(scopeKey);
    }
  }

  /// Keeps a superseded or timed-out drain from surfacing as an uncaught error.
  static void _abandon(Future<Object?> drained) {
    unawaited(drained.then<void>((_) {}, onError: (Object _) {}));
  }

  static Future<List<int>> _drain(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static String? _firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed.length > 500
            ? '${trimmed.substring(0, 500)}...'
            : trimmed;
      }
    }
    return null;
  }
}

/// Supplies the saved settings the resolver reads for its CLI candidate.
typedef ViewerSettingsDraftSource = ViewerSettingsDraft Function();

class _ActiveRead {
  ViewerProcessHandle? handle;
  bool cancelled = false;
  final cancellation = Completer<void>();

  void cancel() {
    if (cancelled) {
      return;
    }
    cancelled = true;
    cancellation.complete();
    handle?.kill();
  }
}
