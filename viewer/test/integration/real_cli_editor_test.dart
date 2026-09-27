/// Slice 5 real-CLI integration: the editor Save path against the release
/// `tasks.exe` (viewer/spec.md sections 4.1, 7 and 12).
///
/// Every case runs against a unique temporary data root under the system temp
/// directory (`tasks-viewer-slice5-int-<timestamp>-<random>`), seeded by the
/// real CLI in JSON mode. The live task store is never opened and the root is
/// removed again when the case finishes.
///
/// 1. `the viewer editor saves one field through the real CLI` drives the
///    production [ViewerCliClient] together with [ViewerEditorController],
///    wired exactly as `viewer/lib/ui/workspace_model.dart` wires them: the
///    client is both the detail reader and the update writer.
/// 2. `a second real writer wins the version` leaves the viewer holding draft
///    version N while a second real CLI process updates the same task, so the
///    viewer save is rejected with the CLI's `version_conflict` envelope
///    (expected/current included) and the store keeps the second writer value.
/// 3. `a lost save acknowledgement` makes the real CLI hold before its commit
///    (`TASKS_PRECOMMIT_READY_FILE` and `TASKS_HOLD_PRECOMMIT_MS`, see
///    `src/store.rs`) while the client runs with a 500 ms read timeout, so the
///    viewer gives up on the answer while the write still lands; the editor then
///    reconciles the unknown outcome against the committed record.
///
/// Each case closes with the persisted history read through the real CLI
/// (`history --limit 100`, `history --event <id>` for the stored snapshot and
/// `viewer show`): the task must carry exactly one `update` event with the final
/// field values, because no path may send a second write on its own.
///
/// Two documented client seams make this possible without touching
/// `viewer/lib`:
///
/// * [ProcessLauncher] is the injection point of `ViewerCliClient`. Neither the
///   client nor `SystemProcessLauncher` can pass environment variables to the
///   CLI, so this file supplies a launcher that starts the identical executable
///   with the two test-hook variables added to the child environment; the
///   production launcher stays untouched.
/// * On a read timeout the client kills the process it was waiting for, and a
///   write still holding before its commit does not survive that kill (the
///   store keeps the old version), so the launcher records the kill request and
///   leaves the timed-out writer alone. That is the acknowledgement-loss
///   premise: the viewer gave up on the answer, not on the write. The store runs
///   in WAL mode, where a reader concurrent with the held write sees the
///   pre-commit snapshot, so the launcher also waits for that in-flight write to
///   finish before it starts the client's next read; the reconciliation then
///   observes the committed record, as spec section 7 requires.
///
/// When the release binary (or, for case 3, its `test-hooks` build) is missing,
/// each test skips with a reason that names the missing artefact, so the file
/// can never pass by accident.
// ignore_for_file: avoid_print

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/launch_args.dart';

const String _logTag = '[slice5-real-cli]';

/// Body seeded through `tasks create --body-file`.
const String _seededBody = 'Synthetic slice-5 body.\nSecond line.';

/// Read timeout for the acknowledgement-loss case.
const Duration _lostAckReadTimeout = Duration(milliseconds: 500);

/// Pre-commit hold for the acknowledgement-loss case: six times the read
/// timeout, so the viewer is guaranteed to give up while the write is pending.
const Duration _lostAckHold = Duration(milliseconds: 3000);

void main() {
  test('the viewer editor saves one field through the real CLI', () async {
    final missing = _missingReleaseBinary();
    if (missing != null) {
      markTestSkipped(missing);
      return;
    }

    final harness = await _Slice5Harness.start();
    await harness.client.probe();
    expect(harness.client.probePassed, isTrue);
    print(
      '$_logTag handshake protocol_version='
      '${harness.client.info?.protocolVersion}',
    );

    final taskId = await harness.seedTask(title: 'Slice 5 seeded title');
    final detail = await harness.client.fetchTaskDetail(
      harness.projectId,
      taskId,
    );
    expect(detail.version, 1);
    expect(detail.title, 'Slice 5 seeded title');
    expect(detail.body, _seededBody);
    print(
      '$_logTag viewer read ${viewerCanonicalTaskId(detail.id)} '
      'version=${detail.version} body=${jsonEncode(detail.body)}',
    );

    const editedTitle = 'Slice 5 title saved by the viewer';
    harness.controller.observeDetail(detail, projectId: harness.projectId);
    harness.controller.beginEdit();
    harness.controller.setField(EditorField.title, editedTitle);
    expect(harness.controller.saveEnabled, isTrue);

    final saved = await harness.controller.save();
    expect(saved.outcome, EditorSaveOutcome.saved, reason: saved.message);
    expect(saved.version, 2);
    expect(saved.eventId, isNotNull);
    print(
      '$_logTag viewer save outcome=${saved.outcome.name} '
      'version=${saved.version} event_id=${saved.eventId} '
      'message=${jsonEncode(saved.message)}',
    );

    final updateCall = harness.launcher.singleViewerUpdate;
    _printCall(updateCall);
    expect(updateCall.exitCode, 0, reason: updateCall.stderr);
    expect(
      jsonDecode(utf8.decode(updateCall.stdinBytes)),
      <String, Object?>{
        'id': taskId,
        'expect_version': 1,
        'changes': <String, Object?>{'title': editedTitle},
      },
      reason: 'one changed field, with the version the draft was based on',
    );
    final response = _envelopeData(updateCall);
    expect(response['command'], 'viewer_update');
    expect(response['version'], 2);
    expect(response['event_id'], saved.eventId);

    await harness.assertSingleUpdate(
      taskId: taskId,
      title: editedTitle,
      version: 2,
      body: _seededBody,
      status: 'todo',
      priority: 'P2',
    );
    harness.launcher.printSummary();
  });

  test(
    'a second real writer wins the version and the viewer save is rejected',
    () async {
      final missing = _missingReleaseBinary();
      if (missing != null) {
        markTestSkipped(missing);
        return;
      }

      final harness = await _Slice5Harness.start();
      await harness.client.probe();

      final taskId = await harness.seedTask(title: 'Slice 5 conflict seed');
      final detail = await harness.client.fetchTaskDetail(
        harness.projectId,
        taskId,
      );
      expect(detail.version, 1);

      const draftTitle = 'Slice 5 viewer draft title';
      harness.controller.observeDetail(detail, projectId: harness.projectId);
      harness.controller.beginEdit();
      harness.controller.setField(EditorField.title, draftTitle);

      const secondTitle = 'Slice 5 second writer title';
      final second = await harness.updateTask(
        taskId: taskId,
        expectVersion: detail.version,
        title: secondTitle,
      );
      expect(second.exitCode, 0, reason: second.stderr);
      final secondResponse = _envelopeData(second);
      expect(secondResponse['command'], 'viewer_update');
      expect(secondResponse['version'], 2);
      print(
        '$_logTag second real CLI process committed version '
        '${secondResponse['version']} with title ${jsonEncode(secondTitle)}',
      );

      final rejected = await harness.controller.save();
      expect(
        rejected.outcome,
        EditorSaveOutcome.conflict,
        reason: rejected.message,
      );
      final conflict = rejected.conflict;
      expect(conflict, isNotNull);
      expect(
        conflict!.baseVersion,
        1,
        reason: 'expected version the viewer sent',
      );
      expect(
        conflict.currentVersion,
        2,
        reason: 'current version in the store',
      );
      expect(conflict.current.title, secondTitle);
      expect(
        conflict.draftFields.title,
        draftTitle,
        reason: 'the draft survives the conflict',
      );
      // viewer/spec.md section 7: "Another intervening write produces another
      // conflict, never a force save", and the retry needs a separate Save
      // against the newly read version. Save therefore re-reports the open
      // conflict instead of writing; the store is not touched again.
      final replayed = await harness.controller.save();
      expect(
        replayed.outcome,
        EditorSaveOutcome.conflict,
        reason: 'an open conflict blocks another save until it is resolved',
      );
      expect(replayed.conflict?.currentVersion, 2);
      print(
        '$_logTag conflict base_version=${conflict.baseVersion} '
        'current_version=${conflict.currentVersion} conflict_fields='
        '${conflict.conflictFields.map((field) => field.wireName).toList()}',
      );

      final updateCall = harness.launcher.singleViewerUpdate;
      _printCall(updateCall);
      expect(updateCall.exitCode, 4);
      final wireEnvelope =
          jsonDecode(updateCall.stderr) as Map<String, Object?>;
      final wireError = wireEnvelope['error']! as Map<String, Object?>;
      expect(wireError['code'], 'version_conflict');
      final wireConflict = wireError['conflict']! as Map<String, Object?>;
      expect(wireConflict['expected'], 1);
      expect(wireConflict['current'], 2);

      await harness.assertSingleUpdate(
        taskId: taskId,
        title: secondTitle,
        version: 2,
        status: 'todo',
        priority: 'P2',
      );
      harness.launcher.printSummary();
    },
  );

  test('a lost save acknowledgement is reconciled against the commit', () async {
    final missing = _missingPrecommitHooks();
    if (missing != null) {
      markTestSkipped(missing);
      return;
    }

    final harness = await _Slice5Harness.start(
      readTimeout: _lostAckReadTimeout,
      precommitHold: _lostAckHold,
    );
    await harness.client.probe();

    final taskId = await harness.seedTask(title: 'Slice 5 lost ack seed');
    final detail = await harness.client.fetchTaskDetail(
      harness.projectId,
      taskId,
    );
    expect(detail.version, 1);

    const committedTitle = 'Slice 5 title committed after the timeout';
    harness.controller.observeDetail(detail, projectId: harness.projectId);
    harness.controller.beginEdit();
    harness.controller.setField(EditorField.title, committedTitle);

    final saveStartedAt = DateTime.now();
    final result = await harness.controller.save();
    final saveFinishedAt = DateTime.now();

    final updateCall = harness.launcher.singleViewerUpdate;
    _printCall(updateCall);
    expect(
      updateCall.killRequested,
      isTrue,
      reason: 'the client gave up at its read timeout and killed the read',
    );
    expect(updateCall.killRequestedAt, isNotNull);
    expect(updateCall.completedAt, isNotNull);
    expect(
      updateCall.readyMarkerAtGiveUp,
      isTrue,
      reason: 'the CLI had already reached the pre-commit hold',
    );
    expect(
      updateCall.completedAt!.isAfter(updateCall.killRequestedAt!),
      isTrue,
      reason: 'the write still had to commit after the viewer gave up',
    );
    expect(
      updateCall.completedAt!.isBefore(saveFinishedAt),
      isTrue,
      reason: 'the viewer reconciled after the commit had landed',
    );
    expect(updateCall.stderr.trim(), isEmpty);
    final writerResponse = _envelopeData(updateCall);
    expect(writerResponse['command'], 'viewer_update');
    expect(writerResponse['version'], 2);
    print(
      '$_logTag the timed-out writer still committed '
      '${jsonEncode(writerResponse)}; that answer never reached the client',
    );
    print(
      '$_logTag timeline give_up='
      '${updateCall.killRequestedAt!.difference(saveStartedAt).inMilliseconds}ms '
      'writer_exit='
      '${updateCall.completedAt!.difference(saveStartedAt).inMilliseconds}ms '
      'save_return='
      '${saveFinishedAt.difference(saveStartedAt).inMilliseconds}ms '
      '(read timeout ${_lostAckReadTimeout.inMilliseconds}ms, '
      'pre-commit hold ${_lostAckHold.inMilliseconds}ms)',
    );

    expect(
      result.outcome,
      EditorSaveOutcome.reconciled,
      reason: result.message,
    );
    expect(result.version, 2);
    expect(result.message, contains('acknowledgement was lost'));
    expect(harness.controller.isEditing, isFalse);
    print(
      '$_logTag viewer save outcome=${result.outcome.name} '
      'version=${result.version} message=${jsonEncode(result.message)}',
    );

    await harness.assertSingleUpdate(
      taskId: taskId,
      title: committedTitle,
      version: 2,
      body: _seededBody,
      status: 'todo',
      priority: 'P2',
    );
    harness.launcher.printSummary();
  });
}

// --------------------------------------------------------------- prerequisites

/// Reason the release binary is unusable, or null when it can be executed.
String? _missingReleaseBinary() {
  final path = _releaseExecutablePath();
  if (!File(path).existsSync()) {
    return 'the release CLI $path is missing: build it from the repository '
        'root with cargo build --release --locked';
  }
  return null;
}

/// Reason the release binary cannot hold a write before its commit, or null.
///
/// The hold is a `test-hooks` build feature (`src/store.rs`); a default build
/// ignores both variables, so the acknowledgement-loss case cannot run at all.
String? _missingPrecommitHooks() {
  final missingBinary = _missingReleaseBinary();
  if (missingBinary != null) {
    return missingBinary;
  }
  final path = _releaseExecutablePath();
  final text = String.fromCharCodes(File(path).readAsBytesSync());
  const hooks = <String>[
    'TASKS_PRECOMMIT_READY_FILE',
    'TASKS_HOLD_PRECOMMIT_MS',
  ];
  for (final hook in hooks) {
    if (!text.contains(hook)) {
      return 'the release CLI $path has no $hook test hook, so it was built '
          'without the test-hooks feature: rebuild it with cargo build '
          '--release --locked --features test-hooks';
    }
  }
  return null;
}

/// Absolute path of the release CLI this run must exercise.
///
/// `--dart-define=TASKS_VIEWER_TEST_CLI=<path>` wins; `verify-windows.ps1`
/// passes its own build so it never rebuilds the installed `target/release`
/// binary. Otherwise `flutter test` runs with the viewer package as the working
/// directory, which puts the binary one directory up; running from the
/// repository root is accepted as well, and the expected path is returned when
/// neither exists so the skip reason names it.
String _releaseExecutablePath() {
  const override = String.fromEnvironment('TASKS_VIEWER_TEST_CLI');
  if (override.isNotEmpty) {
    return override;
  }
  final cwd = Directory.current.path;
  final candidates = <String>[
    _join(_join(cwd, '..'), _join('target', 'release')),
    _join(cwd, _join('target', 'release')),
  ];
  for (final directory in candidates) {
    final path = _join(directory, 'tasks.exe');
    if (File(path).existsSync()) {
      return path;
    }
  }
  return _join(candidates.first, 'tasks.exe');
}

// -------------------------------------------------------------------- fixtures

/// One real CLI process, with the bytes it saw and produced.
final class _CliCall {
  _CliCall(this.executable, this.arguments, {this.environment});

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;

  final List<int> stdinBytes = <int>[];
  final List<int> stdoutBytes = <int>[];
  final List<int> stderrBytes = <int>[];

  int? exitCode;
  DateTime? startedAt;
  DateTime? completedAt;

  /// True once the viewer's client killed this process after a read timeout.
  bool killRequested = false;
  DateTime? killRequestedAt;

  /// Whether the CLI had already written its pre-commit marker when the client
  /// gave up on the answer.
  bool readyMarkerAtGiveUp = false;

  String get commandLine => '$executable ${arguments.join(' ')}';
  String get stdout => utf8.decode(stdoutBytes, allowMalformed: true);
  String get stderr => utf8.decode(stderrBytes, allowMalformed: true);
  bool get isViewerUpdate =>
      arguments.contains('viewer') && arguments.contains('update');
}

/// The launcher the viewer's client uses: a real process, plus the two seams
/// described at the top of this file.
final class _RecordingLauncher implements ProcessLauncher {
  _RecordingLauncher({this.precommitHold, this.readyMarkerPath});

  /// When set, every CLI process the client starts carries the documented
  /// pre-commit hold. Only writes are affected: reads never call the hook.
  final Duration? precommitHold;
  final String? readyMarkerPath;

  final List<_CliCall> invocations = <_CliCall>[];
  Completer<void>? _writerExit;

  /// The one `viewer update` the client sent; a retry would show up here.
  _CliCall get singleViewerUpdate {
    final updates = <_CliCall>[
      for (final call in invocations)
        if (call.isViewerUpdate) call,
    ];
    expect(
      updates.length,
      1,
      reason: 'the viewer must send exactly one viewer update',
    );
    return updates.single;
  }

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final hold = precommitHold;
    final marker = readyMarkerPath;
    final environment = hold == null
        ? null
        : <String, String>{
            'TASKS_HOLD_PRECOMMIT_MS': '${hold.inMilliseconds}',
            'TASKS_PRECOMMIT_READY_FILE': ?marker,
          };
    final call = _CliCall(executable, arguments, environment: environment);
    invocations.add(call);

    // A read the client starts while the held write is still running would see
    // the pre-commit WAL snapshot, so the client's next read waits for that
    // write to finish. Nothing else can start in this window: the client is
    // still awaiting the timed-out update when it reconciles.
    final pending = _writerExit;
    if (pending != null && !call.isViewerUpdate) {
      print('$_logTag holding the client read until the lost write committed');
      await pending.future;
    }

    call.startedAt = DateTime.now();
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      environment: environment,
    );
    if (hold != null && call.isViewerUpdate) {
      final exit = Completer<void>();
      _writerExit = exit;
      unawaited(
        process.exitCode.then((code) {
          call.exitCode ??= code;
          call.completedAt ??= DateTime.now();
          if (identical(_writerExit, exit)) {
            _writerExit = null;
          }
          if (!exit.isCompleted) {
            exit.complete();
          }
        }),
      );
    }
    return _RealCliHandle(process, call, this);
  }

  /// True for the write whose answer this scenario deliberately lost.
  bool leavesTimedOutWriterAlive(_CliCall call) =>
      precommitHold != null && call.isViewerUpdate;

  void printSummary() {
    print(
      '$_logTag viewer client started ${invocations.length} CLI processes:',
    );
    for (final call in invocations) {
      print(
        '$_logTag   ${call.commandLine} -> exit=${call.exitCode} '
        'kill_requested=${call.killRequested}',
      );
    }
  }
}

/// One running CLI process the viewer's client owns.
final class _RealCliHandle implements ViewerProcessHandle {
  _RealCliHandle(this._process, this._call, this._launcher);

  final Process _process;
  final _CliCall _call;
  final _RecordingLauncher _launcher;

  @override
  void addStdin(List<int> bytes) {
    _call.stdinBytes.addAll(bytes);
    _process.stdin.add(bytes);
  }

  @override
  Future<void> closeStdin() => _process.stdin.close();

  @override
  Stream<List<int>> get stdout => _process.stdout.map((chunk) {
    _call.stdoutBytes.addAll(chunk);
    return chunk;
  });

  @override
  Stream<List<int>> get stderr => _process.stderr.map((chunk) {
    _call.stderrBytes.addAll(chunk);
    return chunk;
  });

  @override
  Future<int> get exitCode async {
    final code = await _process.exitCode;
    _call.exitCode ??= code;
    _call.completedAt ??= DateTime.now();
    return code;
  }

  @override
  void kill() {
    _call.killRequested = true;
    _call.killRequestedAt = DateTime.now();
    final marker = _launcher.readyMarkerPath;
    if (marker != null) {
      _call.readyMarkerAtGiveUp = File(marker).existsSync();
    }
    if (_launcher.leavesTimedOutWriterAlive(_call)) {
      return;
    }
    _process.kill();
  }
}

/// One temporary store, the real client, and the editor over it.
final class _Slice5Harness {
  _Slice5Harness({
    required this.root,
    required this.executable,
    required this.projectId,
    required this.launcher,
    required this.client,
    required this.controller,
  });

  final Directory root;
  final String executable;
  final String projectId;
  final _RecordingLauncher launcher;
  final ViewerCliClient client;
  final ViewerEditorController controller;

  String get storeRoot => _join(root.path, 'store');

  /// Creates a synthetic project in a fresh temp data root and hands back the
  /// client and editor the viewer application would use.
  static Future<_Slice5Harness> start({
    Duration readTimeout = viewerReadTimeout,
    Duration? precommitHold,
  }) async {
    final executable = _releaseExecutablePath();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final root = Directory.systemTemp.createTempSync(
      'tasks-viewer-slice5-int-$stamp-',
    );
    final store = _join(root.path, 'store');
    final project = _join(root.path, 'project');
    final settings = _join(root.path, 'settings');
    Directory(project).createSync(recursive: true);
    Directory(settings).createSync(recursive: true);

    print('$_logTag temp data root ${root.path}');
    print('$_logTag release CLI $executable');
    final stat = File(executable).statSync();
    print(
      '$_logTag release CLI bytes=${stat.size} '
      'modified=${stat.modified.toIso8601String()}',
    );
    final version = await _runRealCli(executable, const <String>['--version']);
    expect(version.exitCode, 0, reason: version.stderr);
    expect(version.stdout.trim(), startsWith('tasks '));

    final launcher = _RecordingLauncher(
      precommitHold: precommitHold,
      readyMarkerPath: precommitHold == null
          ? null
          : _join(root.path, 'precommit-ready.txt'),
    );
    final environment = ViewerEnvironment(
      launchArgs: ViewerLaunchArgs(
        dataRoot: store,
        tasksExe: executable,
        settingsRoot: settings,
        testMode: true,
      ),
      settingsRoot: settings,
      dataRoot: store,
      tasksExe: executable,
    );
    final client = ViewerCliClient(
      environment: environment,
      launcher: launcher,
      readTimeout: readTimeout,
    );
    final controller = ViewerEditorController(
      writer: client,
      detailReader: client,
      dataRoot: store,
    );

    final init = await _runRealCli(executable, <String>[
      'init',
      '--root',
      project,
      '--data-root',
      store,
      '--format',
      'json',
    ]);
    expect(init.exitCode, 0, reason: init.stderr);
    final projectId = _envelopeData(init)['project_id'];
    expect(projectId, isA<String>());
    print('$_logTag seeded synthetic project $projectId in the temp store');

    addTearDown(() {
      controller.dispose();
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
        print('$_logTag removed temp data root ${root.path}');
      }
    });

    return _Slice5Harness(
      root: root,
      executable: executable,
      projectId: projectId! as String,
      launcher: launcher,
      client: client,
      controller: controller,
    );
  }

  /// Seeds one task with the real CLI and returns its numeric id.
  Future<int> seedTask({required String title}) async {
    final bodyPath = _join(root.path, 'seed-body.md');
    File(bodyPath).writeAsStringSync(_seededBody);
    final call = await _runRealCli(executable, <String>[
      'create',
      '--data-root',
      storeRoot,
      '--project',
      projectId,
      '--title',
      title,
      '--body-file',
      bodyPath,
      '--status',
      'todo',
      '--priority',
      'P2',
      '--format',
      'json',
    ]);
    expect(call.exitCode, 0, reason: call.stderr);
    final command = _envelopeData(call)['command'];
    expect(command, 'create');
    final id = _envelopeData(call)['id'];
    expect(id, isA<int>());
    return id! as int;
  }

  /// One `viewer update` from a plain second writer (not the viewer client).
  Future<_CliCall> updateTask({
    required int taskId,
    required int expectVersion,
    required String title,
  }) {
    return _runRealCli(
      executable,
      <String>[
        '--data-root',
        storeRoot,
        '--project',
        projectId,
        '--format',
        'json',
        'viewer',
        'update',
        '--request-file',
        '-',
      ],
      stdin: jsonEncode(<String, Object?>{
        'id': taskId,
        'expect_version': expectVersion,
        'changes': <String, Object?>{'title': title},
      }),
    );
  }

  /// Reads the task through `viewer show`.
  Future<Map<String, Object?>> showTask(int taskId) async {
    final call = await _runRealCli(executable, <String>[
      '--data-root',
      storeRoot,
      '--project',
      projectId,
      '--format',
      'json',
      'viewer',
      'show',
      viewerCanonicalTaskId(taskId),
    ]);
    return _envelopeData(call);
  }

  /// Reads one task's append-only events through `history`.
  Future<List<Map<String, Object?>>> historyEvents(int taskId) async {
    final call = await _runRealCli(executable, <String>[
      '--data-root',
      storeRoot,
      '--project',
      projectId,
      '--format',
      'json',
      'history',
      viewerCanonicalTaskId(taskId),
      '--limit',
      '100',
    ]);
    final data = _envelopeData(call);
    expect(data['command'], 'history');
    final items = data['items'];
    expect(items, isA<List<Object?>>());
    return <Map<String, Object?>>[
      for (final item in items! as List<Object?>) item! as Map<String, Object?>,
    ];
  }

  /// Reads one stored event snapshot through `history --event`.
  Future<Map<String, Object?>> eventSnapshot(int taskId, int eventId) async {
    final call = await _runRealCli(executable, <String>[
      '--data-root',
      storeRoot,
      '--project',
      projectId,
      '--format',
      'json',
      'history',
      viewerCanonicalTaskId(taskId),
      '--limit',
      '100',
      '--event',
      '$eventId',
    ]);
    final items = _envelopeData(call)['items']! as List<Object?>;
    expect(items.length, 1);
    final event = items.single! as Map<String, Object?>;
    final raw = event['snapshot'];
    expect(
      raw,
      isA<Map<String, Object?>>(),
      reason: 'history --event must return the persisted snapshot object',
    );
    return raw! as Map<String, Object?>;
  }

  /// Asserts the case left exactly one update event with the final values.
  Future<Map<String, Object?>> assertSingleUpdate({
    required int taskId,
    required String title,
    required int version,
    String? body,
    String? status,
    String? priority,
  }) async {
    final events = await historyEvents(taskId);
    expect(
      <Object?>[for (final event in events) event['operation']],
      <Object?>['create', 'update'],
      reason:
          'one save must add exactly one update event, and no retry may '
          'add another',
    );
    final update = events.last;
    expect(update['resulting_version'], version);
    final eventId = update['event_id'];
    expect(eventId, isA<int>());
    final snapshot = await eventSnapshot(taskId, eventId! as int);
    final shown = await showTask(taskId);
    for (final entry in <String, String?>{
      'title': title,
      'body': body,
    }.entries) {
      final expected = entry.value;
      if (expected == null) {
        continue;
      }
      expect(snapshot[entry.key], expected, reason: 'stored snapshot');
      expect(shown[entry.key], expected, reason: 'current record');
    }
    expect(snapshot['version'], version);
    expect(shown['version'], version);
    if (status != null) {
      expect(snapshot['status'], status);
      expect(shown['status'], status);
    }
    if (priority != null) {
      expect(snapshot['priority'], priority);
      expect(shown['priority'], priority);
    }
    print(
      '$_logTag persisted history for ${viewerCanonicalTaskId(taskId)}: '
      'create plus exactly one update (event $eventId), title='
      '${jsonEncode(title)} version=$version',
    );
    return shown;
  }
}

// -------------------------------------------------------------------- plumbing

/// Runs the real CLI with an optional request document on stdin.
Future<_CliCall> _runRealCli(
  String executable,
  List<String> arguments, {
  String? stdin,
  Map<String, String>? environment,
}) async {
  final call = _CliCall(executable, arguments, environment: environment);
  if (stdin != null) {
    call.stdinBytes.addAll(utf8.encode(stdin));
  }
  call.startedAt = DateTime.now();
  final process = await Process.start(
    executable,
    arguments,
    runInShell: false,
    environment: environment,
  );
  if (stdin != null) {
    process.stdin.write(stdin);
  }
  await process.stdin.close();
  final chunks = await Future.wait(<Future<String>>[
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
  ]);
  call.stdoutBytes.addAll(utf8.encode(chunks[0]));
  call.stderrBytes.addAll(utf8.encode(chunks[1]));
  call.exitCode = await process.exitCode;
  call.completedAt = DateTime.now();
  _printCall(call);
  return call;
}

Map<String, Object?> _envelopeData(_CliCall call) {
  expect(call.exitCode, 0, reason: call.stderr);
  final envelope = jsonDecode(call.stdout) as Map<String, Object?>;
  expect(envelope['schema_version'], 1);
  return envelope['data']! as Map<String, Object?>;
}

/// Prints one invocation so the recorded log quotes the exact CLI traffic.
void _printCall(_CliCall call) {
  print('$_logTag \$ ${call.commandLine}');
  final environment = call.environment;
  if (environment != null && environment.isNotEmpty) {
    final pairs = <String>[
      for (final entry in environment.entries) '${entry.key}=${entry.value}',
    ];
    print('$_logTag   env ${pairs.join(' ')}');
  }
  if (call.stdinBytes.isNotEmpty) {
    print('$_logTag   stdin ${utf8.decode(call.stdinBytes)}');
  }
  final out = call.stdout.trim();
  if (out.isNotEmpty) {
    print('$_logTag   stdout $out');
  }
  final err = call.stderr.trim();
  if (err.isNotEmpty) {
    print('$_logTag   stderr $err');
  }
  print(
    '$_logTag   exit=${call.exitCode} kill_requested=${call.killRequested}',
  );
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';
