/// Slice 6 real-CLI integration: the clipboard preview route against the
/// release `tasks.exe` (viewer/spec.md section 8 and viewer/design.md
/// walkthrough D).
///
/// Every case runs against a unique temporary data root under the system temp
/// directory (`tasks-viewer-slice6-int-<timestamp>-<random>`), seeded by the
/// real CLI in JSON mode, and removes the root again when the case finishes.
/// The live task store and the live clipboard are never touched: these cases
/// drive the production [ViewerCliClient] down the preview route
/// (`enrich --file -` on stdin, the exact argv the viewer sends) and read the
/// persisted history back through a real CLI process to prove enrichment never
/// mutates a task. The writing route (`enrich-clipboard`) stays on the
/// controlled desktop, because an automated case would replace the user's
/// clipboard and still could not prove what the clipboard held.
///
/// 1. `the preview route annotates stdin without touching a task` proves the
///    public `enrich` subcommand accepts the viewer's `--data-root`,
///    `--project` and `--format json` argv, annotates every occurrence of a
///    known reference, reports the unknown ID untouched, and leaves the task's
///    history at its single `create` event.
/// 2. `a second pass over enriched text changes nothing` re-sends the enriched
///    text through the same route: zero replacements, identical text, the same
///    unknown ID - the idempotence the direct action's text check relies on.
///
/// When the release binary is missing, each test skips with a reason that
/// names the missing artefact, so the file can never pass by accident.
// ignore_for_file: avoid_print

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/launch_args.dart';

const String _logTag = '[slice6-real-cli]';

/// Titles seeded through `tasks create`.
const String _firstTitle = 'Slice 6 first task';
const String _secondTitle = 'Slice 6 second task';

/// Body seeded through `tasks create --body-file`.
const String _seededBody = 'Synthetic slice-6 body.\nSecond line.';

/// Numeric task ID the synthetic input refers to but the store never had.
const int _unknownId = 404;

void main() {
  test('the preview route annotates stdin without touching a task', () async {
    final missing = _missingReleaseBinary();
    if (missing != null) {
      markTestSkipped(missing);
      return;
    }

    final harness = await _Slice6Harness.start();
    await harness.client.probe();
    expect(harness.client.probePassed, isTrue);
    print(
      '$_logTag handshake protocol_version='
      '${harness.client.info?.protocolVersion}',
    );

    final first = await harness.seedTask(title: _firstTitle);
    final second = await harness.seedTask(title: _secondTitle);
    expect(first, isNot(_unknownId));
    expect(second, isNot(_unknownId));
    final input =
        'T-$first and T-$second and T-$first again. '
        'T-$_unknownId stays.\n';
    final before = await harness.historyEvents(first);
    expect(
      <Object?>[for (final event in before) event['operation']],
      <Object?>['create'],
    );

    final result = await harness.client.enrichText(harness.projectId, input);

    print(
      '$_logTag preview result replacements=${result.replacements} '
      'unknown_ids=${result.unknownIds} clipboard=${result.clipboard}',
    );
    print('$_logTag enriched text ${jsonEncode(result.text)}');
    expect(result.clipboard, isFalse);
    expect(result.replacements, 3);
    expect(result.unknownIds, <int>[_unknownId]);
    expect(
      result.text,
      'T-$first ($_firstTitle) and T-$second ($_secondTitle) and '
      'T-$first ($_firstTitle) again. T-$_unknownId stays.\n',
    );

    final after = await harness.historyEvents(first);
    expect(
      after,
      before,
      reason: 'enrichment is a read-only command: no task may gain an event',
    );
    print(
      '$_logTag history unchanged: ${before.length} event(s) before and '
      'after, still ${jsonEncode(after.single['operation'])} at version '
      '${after.single['resulting_version']}',
    );
    harness.printInvocations();
  });

  test('a second pass over enriched text changes nothing', () async {
    final missing = _missingReleaseBinary();
    if (missing != null) {
      markTestSkipped(missing);
      return;
    }

    final harness = await _Slice6Harness.start();
    await harness.client.probe();
    expect(harness.client.probePassed, isTrue);

    final first = await harness.seedTask(title: _firstTitle);
    final input = 'T-$first and T-$_unknownId.\n';
    final enriched = await harness.client.enrichText(harness.projectId, input);
    expect(enriched.replacements, 1);
    expect(enriched.text, 'T-$first ($_firstTitle) and T-$_unknownId.\n');

    final again = await harness.client.enrichText(
      harness.projectId,
      enriched.text,
    );

    print(
      '$_logTag second pass replacements=${again.replacements} '
      'unknown_ids=${again.unknownIds}',
    );
    expect(again.replacements, 0);
    expect(again.text, enriched.text);
    expect(again.unknownIds, <int>[_unknownId]);
    harness.printInvocations();
  });
}

// ------------------------------------------------------------------- fixtures

/// One real CLI process the viewer client started, and the bytes it saw.
final class _ViewerCall {
  _ViewerCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
  final List<int> stdinBytes = <int>[];

  String get commandLine => '$executable ${arguments.join(' ')}';
}

/// Starts the real executable and records the viewer's exact argv and stdin.
final class _RecordingLauncher implements ProcessLauncher {
  final List<_ViewerCall> calls = <_ViewerCall>[];

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final call = _ViewerCall(executable, arguments);
    calls.add(call);
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    return _RecordingHandle(process, call);
  }

  void printSummary() {
    print('$_logTag viewer client started ${calls.length} CLI processes:');
    for (final call in calls) {
      print('$_logTag   \$ ${call.commandLine}');
      if (call.stdinBytes.isNotEmpty) {
        print('$_logTag     stdin ${jsonEncode(utf8.decode(call.stdinBytes))}');
      }
    }
  }
}

final class _RecordingHandle implements ViewerProcessHandle {
  _RecordingHandle(this._process, this._call);

  final Process _process;
  final _ViewerCall _call;

  @override
  void addStdin(List<int> bytes) {
    _call.stdinBytes.addAll(bytes);
    _process.stdin.add(bytes);
  }

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

/// One temporary store, the real client, and the calls it already made.
final class _Slice6Harness {
  _Slice6Harness({
    required this.root,
    required this.executable,
    required this.projectId,
    required this.launcher,
    required this.client,
  });

  final Directory root;
  final String executable;
  final String projectId;
  final _RecordingLauncher launcher;
  final ViewerCliClient client;

  String get storeRoot => _join(root.path, 'store');

  /// Creates a synthetic project in a fresh temp data root and hands back the
  /// client the viewer application would use.
  static Future<_Slice6Harness> start() async {
    final executable = _releaseExecutablePath();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final root = Directory.systemTemp.createTempSync(
      'tasks-viewer-slice6-int-$stamp-',
    );
    final store = _join(root.path, 'store');
    final project = _join(root.path, 'project');
    final settings = _join(root.path, 'settings');
    Directory(project).createSync(recursive: true);
    Directory(settings).createSync(recursive: true);

    print('$_logTag temp data root ${root.path}');
    final version = await _runRealCli(executable, const <String>['--version']);
    expect(version.exitCode, 0, reason: version.stderr);
    expect(version.stdout.trim(), startsWith('tasks '));
    final stat = File(executable).statSync();
    print(
      '$_logTag release CLI $executable version=${version.stdout.trim()} '
      'bytes=${stat.size} modified=${stat.modified.toIso8601String()}',
    );

    final launcher = _RecordingLauncher();
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
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
        print('$_logTag removed temp data root ${root.path}');
      }
    });

    return _Slice6Harness(
      root: root,
      executable: executable,
      projectId: projectId! as String,
      launcher: launcher,
      client: client,
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
    final data = _envelopeData(call);
    expect(data['command'], 'create');
    final id = data['id'];
    expect(id, isA<int>());
    return id! as int;
  }

  /// Reads one task's persisted history through a real CLI process.
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

  void printInvocations() => launcher.printSummary();
}

// -------------------------------------------------------------------- plumbing

String? _missingReleaseBinary() {
  final path = _releaseExecutablePath();
  if (!File(path).existsSync()) {
    return 'the release CLI $path is missing: build it from the repository '
        'root with cargo build --release --locked';
  }
  return null;
}

/// Absolute path of the release CLI this run must exercise.
///
/// `flutter test` runs with the viewer package as the working directory, which
/// puts the binary one directory up; running from the repository root is
/// accepted as well, and the expected path is returned when neither exists so
/// the skip reason names it.
String _releaseExecutablePath() {
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

/// Runs the real CLI once and prints its exact traffic.
Future<_CliCall> _runRealCli(String executable, List<String> arguments) async {
  final call = _CliCall(executable, arguments);
  final process = await Process.start(executable, arguments, runInShell: false);
  await process.stdin.close();
  final chunks = await Future.wait(<Future<String>>[
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
  ]);
  call.stdout = chunks[0];
  call.stderr = chunks[1];
  call.exitCode = await process.exitCode;
  print('$_logTag \$ ${call.commandLine}');
  print('$_logTag   exit=${call.exitCode} stdout=${call.stdout.trim()}');
  if (call.stderr.trim().isNotEmpty) {
    print('$_logTag   stderr=${call.stderr.trim()}');
  }
  return call;
}

/// One real CLI invocation outside the viewer client.
final class _CliCall {
  _CliCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  String stdout = '';
  String stderr = '';
  int? exitCode;

  String get commandLine => '$executable ${arguments.join(' ')}';
}

Map<String, Object?> _envelopeData(_CliCall call) {
  expect(call.exitCode, 0, reason: call.stderr);
  final envelope = jsonDecode(call.stdout) as Map<String, Object?>;
  expect(envelope['schema_version'], 1);
  return envelope['data']! as Map<String, Object?>;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';
