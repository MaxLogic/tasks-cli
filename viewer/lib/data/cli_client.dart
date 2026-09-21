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

import '../app_environment.dart';
import 'models.dart';
import 'settings_draft.dart';
import 'settings_store.dart' show joinViewerPath;

/// Protocol request size limit (viewer/spec.md section 4.1).
const int viewerRequestByteLimit = 8 * 1024 * 1024;

/// Read timeout for one CLI invocation.
const Duration viewerReadTimeout = Duration(seconds: 30);

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
class ViewerCliClient implements CancellableProjectReader {
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
    final envelope = await _runViewerCommand(
      scopeKey: 'probe',
      arguments: const <String>['--format', 'json', 'viewer', 'info'],
      request: null,
      expectedCommands: const <String>{'viewer_info'},
    );
    final decoded = ViewerInfo.fromJson(envelope.data);
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
    final dataRoot = environment.dataRoot;
    if (dataRoot == null || dataRoot.isEmpty) {
      throw const ViewerCliErrorFailure(
        code: 'no_store',
        message:
            'No task data root is configured. Choose one in Settings before '
            'loading projects.',
        exitCode: 2,
      );
    }
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

  Future<ViewerEnvelope> _runViewerCommand({
    required String scopeKey,
    required List<String> arguments,
    required Map<String, Object?>? request,
    required Set<String>? expectedCommands,
  }) async {
    final resolution = resolveExecutable();
    final executable = resolution.executable;
    if (executable == null) {
      throw ViewerExecutableNotFoundFailure(resolution.attemptedPaths);
    }

    // The size check happens before a process exists.
    final requestBytes = request == null
        ? null
        : utf8.encode(jsonEncode(request));
    if (requestBytes != null && requestBytes.length > requestByteLimit) {
      throw ViewerRequestTooLargeFailure(
        byteLength: requestBytes.length,
        limitBytes: requestByteLimit,
      );
    }

    _activeReads[scopeKey]?.cancel();
    final active = _ActiveRead();
    _activeReads[scopeKey] = active;

    final ViewerProcessHandle handle;
    try {
      handle = await _launcher.start(executable, arguments);
    } on ProcessException catch (error) {
      _release(scopeKey, active);
      throw ViewerProcessStartFailure(
        'Could not start "$executable": ${error.message}',
      );
    } on Object catch (error) {
      _release(scopeKey, active);
      throw ViewerProcessStartFailure('Could not start "$executable": $error');
    }
    active.handle = handle;
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
      results = await drained.timeout(readTimeout);
    } on TimeoutException {
      active.cancelled = true;
      _abandon(drained);
      handle.kill();
      _release(scopeKey, active);
      throw ViewerTimeoutFailure(readTimeout);
    } on Object catch (error) {
      _abandon(drained);
      handle.kill();
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

  void cancel() {
    if (cancelled) {
      return;
    }
    cancelled = true;
    handle?.kill();
  }
}
