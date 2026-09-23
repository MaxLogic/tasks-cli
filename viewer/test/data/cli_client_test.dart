/// Transport faults for the viewer's only route to task data
/// (viewer/spec.md sections 3.2 and 4.1, test matrix V01).
///
/// Every case injects a fake process, so no test can start the real CLI or
/// reach a real task store.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';

const String projectUuid = '2f6f0a54-1b1a-4c3a-9a3e-6a1f7e9d1111';

/// One scripted child process.
class FakeProcessHandle implements ViewerProcessHandle {
  FakeProcessHandle({
    List<List<int>>? stdoutBytes,
    List<List<int>>? stderrBytes,
    this.exit = 0,
    this.answer = true,
  }) : _stdoutBytes = stdoutBytes ?? const <List<int>>[],
       _stderrBytes = stderrBytes ?? const <List<int>>[];

  final List<List<int>> _stdoutBytes;
  final List<List<int>> _stderrBytes;
  final int exit;

  /// False leaves the process running until it is killed.
  final bool answer;

  final List<int> stdinBytes = <int>[];
  bool stdinClosed = false;
  int killCount = 0;

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  @override
  void addStdin(List<int> bytes) => stdinBytes.addAll(bytes);

  @override
  Future<void> closeStdin() async {
    stdinClosed = true;
    if (!answer) {
      return;
    }
    // The client attaches its listeners right after closing stdin, and a
    // single-subscription controller only delivers `done` once someone
    // listens, so closing must not be awaited here.
    for (final chunk in _stdoutBytes) {
      _stdout.add(chunk);
    }
    for (final chunk in _stderrBytes) {
      _stderr.add(chunk);
    }
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    if (!_exit.isCompleted) {
      _exit.complete(exit);
    }
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill() {
    killCount += 1;
    // A killed process still reports an exit code; a cancelled read abandons
    // the drained futures instead of reading this value.
    if (!_exit.isCompleted) {
      _exit.complete(-1);
    }
    if (!_stdout.isClosed) {
      unawaited(_stdout.close());
    }
    if (!_stderr.isClosed) {
      unawaited(_stderr.close());
    }
  }
}

/// One recorded launch request.
final class LaunchedProcess {
  LaunchedProcess(this.executable, this.arguments, this.handle);

  final String executable;
  final List<String> arguments;
  final FakeProcessHandle handle;
}

/// A launcher that never touches the file system.
class ScriptedLauncher implements ProcessLauncher {
  ScriptedLauncher({this.exit = 0});

  int exit;
  List<List<int>> stdoutBytes = <List<int>>[];
  List<List<int>> stderrBytes = <List<int>>[];
  Object? startError;

  /// False makes every process hang until it is killed.
  bool answer = true;

  final List<LaunchedProcess> launches = <LaunchedProcess>[];

  /// Scripts a successful read that writes [text] to stdout.
  void replyWith(String text) {
    stdoutBytes = <List<int>>[utf8.encode(text)];
  }

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final error = startError;
    if (error != null) {
      throw error;
    }
    final handle = FakeProcessHandle(
      stdoutBytes: stdoutBytes,
      stderrBytes: stderrBytes,
      exit: exit,
      answer: answer,
    );
    launches.add(LaunchedProcess(executable, arguments, handle));
    return handle;
  }
}

String infoDocument({int protocolVersion = 1}) =>
    '{"schema_version":1,"project_id":null,"data":{"command":"viewer_info",'
    '"protocol_version":$protocolVersion,'
    '"operations":["projects","tasks","show","update"],'
    '"statuses":["draft","todo","in-progress","blocked","done","cancelled"],'
    '"priorities":["P0","P1","P2","P3"],'
    '"editable_fields":["title","body","status","priority","labels","deps"],'
    '"editable_field_limits":{'
    '"title":{"max_chars":500},'
    '"body":{"max_utf8_bytes":1048576},'
    '"status":{"values":["draft","todo","in-progress","blocked","done",'
    '"cancelled"]},'
    '"priority":{"values":["P0","P1","P2","P3"]},'
    '"labels":{"max_count":32,"item_max_chars":64,'
    '"item_allowed":"a-z0-9-_.:"},'
    '"deps":{"max_count":1000}}}}';

String projectsDocument({String availability = 'available'}) =>
    '{"schema_version":1,"project_id":null,"data":{"command":'
    '"viewer_projects","protocol_version":1,"items":[{"project_id":'
    '"$projectUuid","name":"Alpha","roots":["C:\\\\work\\\\alpha"],'
    '"availability":"$availability","error":null,'
    '"sampled_at_ms":1700000002000,"stats":{"total":3,"open":1,"blocked":0,'
    '"done":2,"cancelled":0,"started_ms":1700000000000,'
    '"last_write_ms":1700000001000,"progress_percent":66.7}}],'
    '"total_count":1,"offset":0,"limit":100,"has_more":false,'
    '"next_offset":null,"snapshot":"p1.abc"}}';

/// One `viewer tasks` page for slice 4; [projectId] is overridable so a
/// routing mismatch can be exercised.
String tasksDocument({String projectId = projectUuid}) =>
    '{"schema_version":1,"project_id":"$projectId","data":{"command":'
    '"viewer_tasks","protocol_version":1,"items":[{"id":42,'
    '"title":"Parser rewrite","status":"todo","priority":"P1","version":7,'
    '"labels":["ui"],"dependency_count":2,"waiting_dependency_count":1,'
    '"created_ms":1700000000000,"updated_ms":1700000001000}],'
    '"total_count":1,"offset":0,"limit":100,"has_more":false,'
    '"next_offset":null,"snapshot":"t1.abc"}}';

/// One `viewer show` document with a real, complete body.
String showDocument({
  String projectId = projectUuid,
  String body = 'Full body\ntext',
  String title = 'Parser rewrite',
}) => jsonEncode(<String, Object?>{
  'schema_version': 1,
  'project_id': projectId,
  'data': <String, Object?>{
    'command': 'viewer_show',
    'protocol_version': 1,
    'id': 42,
    'title': title,
    'body': body,
    'status': 'todo',
    'priority': 'P1',
    'version': 7,
    'deps': <int>[9],
    'labels': <String>['ui'],
    'dependency_summaries': <Map<String, Object?>>[
      <String, Object?>{
        'id': 9,
        'status': 'in-progress',
        'version': 2,
        'title': 'Lexer',
      },
    ],
    'rule_version': 3,
    'rules': '# Rules',
    'created_ms': 1700000000000,
    'updated_ms': 1700000001000,
  },
});

/// One legacy `history` page; [projectId] is overridable for routing checks.
String historyDocument({
  String projectId = projectUuid,
  int id = 42,
  List<Map<String, Object?>>? items,
  bool hasMore = false,
  int? nextAfter,
}) => jsonEncode(<String, Object?>{
  'schema_version': 1,
  'project_id': projectId,
  'data': <String, Object?>{
    'command': 'history',
    'id': id,
    'items':
        items ??
        <Map<String, Object?>>[
          <String, Object?>{
            'event_id': 11,
            'task_id': 42,
            'entity_type': 'task',
            'operation': 'update',
            'resulting_version': 7,
            'created_ms': 1700000001000,
            'snapshot_json': '{"version":7}',
          },
        ],
    'has_more': hasMore,
    'next_after': nextAfter,
  },
});

ViewerEnvironment viewerEnvironmentForTest({
  String? dataRoot = r'C:\store',
  String? tasksExe = r'C:\tools\tasks.exe',
  String settingsRoot = r'C:\settings',
}) => ViewerEnvironment(
  launchArgs: ViewerLaunchArgs(
    dataRoot: dataRoot,
    tasksExe: tasksExe,
    settingsRoot: settingsRoot,
    testMode: true,
  ),
  settingsRoot: settingsRoot,
  dataRoot: dataRoot,
  tasksExe: tasksExe,
);

ViewerCliClient buildClient({
  ProcessLauncher? launcher,
  ViewerEnvironment? environment,
  ViewerSettingsDraft? saved,
  String bundledDirectory = r'C:\bundle',
  Duration readTimeout = viewerReadTimeout,
  int requestByteLimit = viewerRequestByteLimit,
  bool Function(String)? exists,
}) => ViewerCliClient(
  environment: environment ?? viewerEnvironmentForTest(),
  savedSettings: saved == null ? null : () => saved,
  launcher: launcher ?? ScriptedLauncher(),
  bundledExecutableDirectory: bundledDirectory,
  executableExists: exists ?? (String path) => true,
  readTimeout: readTimeout,
  requestByteLimit: requestByteLimit,
);

/// A client whose probe already succeeded against [launcher].
Future<ViewerCliClient> probedClient(
  ScriptedLauncher launcher, {
  ViewerEnvironment? environment,
  int requestByteLimit = viewerRequestByteLimit,
}) async {
  launcher.replyWith(infoDocument());
  final client = buildClient(
    launcher: launcher,
    environment: environment,
    requestByteLimit: requestByteLimit,
  );
  await client.probe();
  return client;
}

void main() {
  group('executable resolution', () {
    test('the launch argument wins and PATH is never a candidate', () {
      final client = buildClient(
        saved: const ViewerSettingsDraft(cliPath: r'C:\saved\tasks.exe'),
      );
      final resolution = client.resolveExecutable();
      expect(resolution.executable, r'C:\tools\tasks.exe');
      expect(resolution.attemptedPaths, <String>[
        r'C:\tools\tasks.exe',
        r'C:\saved\tasks.exe',
        r'C:\bundle\tasks.exe',
      ]);
      expect(
        resolution.attemptedPaths.every((path) => path.contains(r'\')),
        isTrue,
        reason: 'a bare executable name would be resolved through PATH',
      );
    });

    test('the saved setting and then the bundled copy are the fallbacks', () {
      final saved = buildClient(
        environment: viewerEnvironmentForTest(tasksExe: null),
        saved: const ViewerSettingsDraft(cliPath: r'C:\saved\tasks.exe'),
      );
      expect(saved.resolveExecutable().executable, r'C:\saved\tasks.exe');

      final bundled = buildClient(
        environment: viewerEnvironmentForTest(tasksExe: null),
        bundledDirectory: r'C:\bundle dir\Podfolder ąćę',
      );
      expect(
        bundled.resolveExecutable().executable,
        'C:\\bundle dir\\Podfolder ąćę\\tasks.exe',
      );
    });

    test('a missing executable lists every attempted path', () {
      final client = buildClient(exists: (String path) => false);
      final resolution = client.resolveExecutable();
      expect(resolution.executable, isNull);
      expect(resolution.attemptedPaths.length, 2);
      expect(
        const ViewerExecutableNotFoundFailure(<String>[
          r'C:\a\tasks.exe',
        ]).message,
        contains('never searches PATH'),
      );
    });
  });

  group('handshake', () {
    test('a probe is required before any data command', () async {
      final launcher = ScriptedLauncher();
      final client = buildClient(launcher: launcher);
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(isA<ViewerProbeRequiredFailure>()),
      );
      expect(launcher.launches, isEmpty);
    });

    test('a passing probe is cached and is a plain viewer info call', () async {
      final launcher = ScriptedLauncher();
      launcher.replyWith(infoDocument());
      final client = buildClient(launcher: launcher);
      final info = await client.probe();
      expect(info.protocolVersion, 1);
      expect(info.statuses, contains('cancelled'));
      expect(info.editableFieldLimits.bodyMaxUtf8Bytes, 1048576);
      expect(info.editableFieldLimits.depsMaxCount, 1000);
      expect(await client.probe(), same(info));
      expect(launcher.launches.length, 1);
      expect(launcher.launches.single.arguments, <String>[
        '--format',
        'json',
        'viewer',
        'info',
      ]);
    });

    test('a future protocol version fails the handshake', () async {
      final launcher = ScriptedLauncher()
        ..replyWith(infoDocument(protocolVersion: 2));
      final client = buildClient(launcher: launcher);
      await expectLater(
        client.probe(),
        throwsA(isA<ViewerProtocolMismatchFailure>()),
      );
      expect(client.probePassed, isFalse);
      expect(client.info, isNull);
    });

    test('a missing executable fails before a process is attempted', () async {
      final launcher = ScriptedLauncher();
      final client = buildClient(
        launcher: launcher,
        exists: (String path) => false,
      );
      await expectLater(
        client.probe(),
        throwsA(
          isA<ViewerExecutableNotFoundFailure>().having(
            (failure) => failure.attemptedPaths.length,
            'attempted paths',
            2,
          ),
        ),
      );
      expect(launcher.launches, isEmpty);
    });

    test('a process that cannot start is an actionable failure', () async {
      final launcher = ScriptedLauncher()
        ..startError = const ProcessException(
          'tasks.exe',
          <String>[],
          'The system cannot find the file specified.',
          2,
        );
      final client = buildClient(launcher: launcher);
      await expectLater(
        client.probe(),
        throwsA(
          isA<ViewerProcessStartFailure>().having(
            (failure) => failure.message,
            'message',
            allOf(contains('Could not start'), contains('tasks.exe')),
          ),
        ),
      );
    });
  });

  group('requests', () {
    test('archive and unarchive send the selected UUID to the CLI', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(
        '{"schema_version":1,"project_id":"$projectUuid","data":'
        '{"command":"viewer_archive","protocol_version":1,'
        '"archived_at_ms":1700000003000}}',
      );

      expect(
        await client.setProjectArchived(projectUuid, archived: true),
        1700000003000,
      );
      expect(launcher.launches.last.arguments, <String>[
        '--data-root',
        r'C:\store',
        '--project',
        projectUuid,
        '--format',
        'json',
        'viewer',
        'archive',
      ]);

      launcher.replyWith(
        '{"schema_version":1,"project_id":"$projectUuid","data":'
        '{"command":"viewer_archive","protocol_version":1,'
        '"archived_at_ms":null}}',
      );
      expect(
        await client.setProjectArchived(projectUuid, archived: false),
        isNull,
      );
      expect(launcher.launches.last.arguments.last, '--unarchive');
    });

    test(
      'the request travels as UTF-8 JSON on stdin, which is closed',
      () async {
        final launcher = ScriptedLauncher();
        final client = await probedClient(launcher);
        launcher.replyWith(projectsDocument());

        final page = await client.fetchProjects(
          const ProjectQuery(query: 'Żółć', offset: 100, snapshot: 'p1.abc'),
        );
        expect(page.items.single.name, 'Alpha');

        final dataLaunch = launcher.launches.last;
        expect(dataLaunch.executable, r'C:\tools\tasks.exe');
        expect(dataLaunch.arguments, <String>[
          '--data-root',
          r'C:\store',
          '--format',
          'json',
          'viewer',
          'projects',
          '--request-file',
          '-',
        ]);
        expect(dataLaunch.handle.stdinClosed, isTrue);
        final sent =
            jsonDecode(utf8.decode(dataLaunch.handle.stdinBytes))
                as Map<String, Object?>;
        expect(sent, <String, Object?>{
          'query': 'Żółć',
          'state': 'all',
          'sort': 'name',
          'direction': 'asc',
          'offset': 100,
          'limit': 100,
          'snapshot': 'p1.abc',
        });
      },
    );

    test('a Unicode data root survives the argument array unchanged', () async {
      final launcher = ScriptedLauncher();
      const root = r'C:\Użytkownicy\Pawel\Zadań store';
      final client = await probedClient(
        launcher,
        environment: viewerEnvironmentForTest(dataRoot: root),
      );
      launcher.replyWith(projectsDocument());
      await client.fetchProjects(const ProjectQuery());
      expect(launcher.launches.last.arguments, contains(root));
      expect(launcher.launches.last.executable, r'C:\tools\tasks.exe');
    });

    test('an oversized request fails before a process exists', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher, requestByteLimit: 16);
      final launchesAfterProbe = launcher.launches.length;

      await expectLater(
        client.fetchProjects(ProjectQuery(query: 'x' * 64)),
        throwsA(
          isA<ViewerRequestTooLargeFailure>()
              .having((failure) => failure.limitBytes, 'limit', 16)
              .having(
                (failure) => failure.message,
                'message',
                contains('8 MiB'),
              ),
        ),
      );
      expect(launcher.launches.length, launchesAfterProbe);
    });

    test('a missing data root is refused without running the CLI', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(
        launcher,
        environment: viewerEnvironmentForTest(dataRoot: null),
      );
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(
          isA<ViewerCliErrorFailure>()
              .having((failure) => failure.code, 'code', 'no_store')
              .having(
                (failure) => failure.message,
                'message',
                contains('Choose one in Settings'),
              ),
        ),
      );
      expect(launcher.launches.length, 1, reason: 'only the probe ran');
    });
  });

  group('responses', () {
    test(
      'a nonzero exit with a JSON error envelope is not a success',
      () async {
        final launcher = ScriptedLauncher();
        final client = await probedClient(launcher);
        launcher
          ..exit = 4
          ..stdoutBytes = <List<int>>[utf8.encode(projectsDocument())]
          ..stderrBytes = <List<int>>[
            utf8.encode(
              '{"schema_version":1,"error":{"code":"stale_snapshot",'
              '"message":"the page is no longer valid"}}',
            ),
          ];

        await expectLater(
          client.fetchProjects(const ProjectQuery()),
          throwsA(
            isA<ViewerCliErrorFailure>()
                .having((failure) => failure.code, 'code', 'stale_snapshot')
                .having((failure) => failure.exitCode, 'exit code', 4)
                .having((failure) => failure.isStaleSnapshot, 'stale', isTrue),
          ),
        );
      },
    );

    test(
      'a conflict error reports both versions without losing the code',
      () async {
        final launcher = ScriptedLauncher();
        final client = await probedClient(launcher);
        launcher
          ..exit = 4
          ..stderrBytes = <List<int>>[
            utf8.encode(
              '{"schema_version":1,"error":{"code":"version_conflict",'
              '"message":"expected 3, found 4",'
              '"conflict":{"expected":3,"current":4}}}',
            ),
          ];

        await expectLater(
          client.runViewerCommand(
            scopeKey: 'update',
            arguments: const <String>['viewer', 'update'],
          ),
          throwsA(
            isA<ViewerCliErrorFailure>()
                .having((failure) => failure.code, 'code', 'version_conflict')
                .having((failure) => failure.conflictExpected, 'expected', 3)
                .having((failure) => failure.conflictCurrent, 'current', 4),
          ),
        );
      },
    );

    test(
      'a nonzero exit with unusable stderr reports its first line',
      () async {
        final launcher = ScriptedLauncher();
        final client = await probedClient(launcher);
        launcher
          ..exit = 2
          ..stderrBytes = <List<int>>[
            utf8.encode('\n\n  something went wrong  \nmore detail'),
          ];

        await expectLater(
          client.fetchProjects(const ProjectQuery()),
          throwsA(
            isA<ViewerCliErrorFailure>()
                .having((failure) => failure.code, 'code', 'unparsed_error')
                .having(
                  (failure) => failure.message,
                  'message',
                  'something went wrong',
                ),
          ),
        );
      },
    );

    test(
      'exit code zero with malformed stdout is never a phantom success',
      () async {
        final launcher = ScriptedLauncher();
        final client = await probedClient(launcher);
        launcher.replyWith('{"schema_version":1,"data":{"command":');
        await expectLater(
          client.fetchProjects(const ProjectQuery()),
          throwsA(isA<ViewerMalformedResponseFailure>()),
        );
      },
    );

    test('exit code zero with duplicate keys is rejected', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(
        projectsDocument().replaceFirst(
          '"total_count":1',
          '"total_count":1,"total_count":1',
        ),
      );
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('an invalid enum value is an error, not an empty catalog', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(projectsDocument(availability: 'partially-broken'));
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('a wrong command tag is rejected', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(
        projectsDocument().replaceFirst('viewer_projects', 'viewer_tasks'),
      );
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });
  });

  group('output streams', () {
    test('stdout and stderr are drained concurrently', () async {
      // 512 KiB on stderr while stdout carries the answer: a client that read
      // one stream to completion first would stall here.
      final launcher = ScriptedLauncher()
        ..replyWith(infoDocument())
        ..stderrBytes = <List<int>>[utf8.encode('${'x' * 512}\n' * 1024)];
      final client = buildClient(launcher: launcher);
      expect((await client.probe()).protocolVersion, 1);
    });

    test('multi-chunk stdout decodes as one document', () async {
      final document = infoDocument();
      final launcher = ScriptedLauncher()
        ..stdoutBytes = <List<int>>[
          utf8.encode(document.substring(0, 10)),
          utf8.encode(document.substring(10, 40)),
          utf8.encode(document.substring(40)),
        ];
      final client = buildClient(launcher: launcher);
      expect((await client.probe()).operations, contains('projects'));
    });

    test('an invalid UTF-8 byte cannot become a phantom success', () async {
      final launcher = ScriptedLauncher()
        ..stdoutBytes = <List<int>>[
          <int>[0x7B, 0xFF, 0x7D],
        ];
      final client = buildClient(launcher: launcher);
      await expectLater(
        client.probe(),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });
  });

  group('timing and cancellation', () {
    test('a read that outlives the timeout is killed and reported', () async {
      final launcher = ScriptedLauncher();
      final client = buildClient(
        launcher: launcher,
        readTimeout: const Duration(milliseconds: 80),
      );
      launcher
        ..replyWith(infoDocument())
        ..answer = true;
      await client.probe();

      launcher.answer = false;
      await expectLater(
        client.fetchProjects(const ProjectQuery()),
        throwsA(
          isA<ViewerTimeoutFailure>()
              .having(
                (failure) => failure.timeout,
                'timeout',
                const Duration(milliseconds: 80),
              )
              .having(
                (failure) => failure.message,
                'message',
                contains('Retry the read'),
              ),
        ),
      );
      expect(launcher.launches.last.handle.killCount, 1);
    });

    test('a superseded read is cancelled and its process killed', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.answer = false;

      final pending = client.fetchProjects(const ProjectQuery());
      // The handler is attached before the cancel, so the deliberate
      // cancellation is never reported as an unhandled error.
      final outcome = expectLater(
        pending,
        throwsA(isA<ViewerCancelledFailure>()),
      );
      client.cancelScope('projects');
      await pumpEventQueue();
      expect(launcher.launches.last.handle.killCount, 1);
      await outcome;
    });

    test('cancelling a scope with no read is harmless', () {
      final client = buildClient();
      expect(() => client.cancelScope('projects'), returnsNormally);
    });
  });

  group('task and detail reads', () {
    test('viewer tasks routes by project UUID and sends the query', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(tasksDocument());

      final page = await client.fetchTasks(
        projectUuid,
        const TaskQuery(
          query: 'parser',
          scope: TaskScope.all,
          statuses: <String>['todo'],
          priorities: <String>['P1'],
          labels: <String>['ui'],
          readiness: TaskReadiness.waiting,
          sort: TaskSort.updated,
          direction: SortDirection.descending,
          offset: 400,
          limit: 100,
          snapshot: 't1.abc',
        ),
      );

      expect(page.totalCount, 1);
      expect(page.items.single.canonicalId, 'T-042');
      expect(page.items.single.waitingDependencyCount, 1);
      expect(page.snapshot, 't1.abc');

      final launch = launcher.launches.last;
      expect(launch.executable, r'C:\tools\tasks.exe');
      expect(launch.arguments, <String>[
        '--data-root',
        r'C:\store',
        '--project',
        projectUuid,
        '--format',
        'json',
        'viewer',
        'tasks',
        '--request-file',
        '-',
      ]);
      expect(launch.handle.stdinClosed, isTrue);
      final sent =
          jsonDecode(utf8.decode(launch.handle.stdinBytes))
              as Map<String, Object?>;
      expect(sent, <String, Object?>{
        'query': 'parser',
        'scope': 'all',
        'statuses': <String>['todo'],
        'priorities': <String>['P1'],
        'labels': <String>['ui'],
        'readiness': 'waiting',
        'sort': 'updated',
        'direction': 'desc',
        'offset': 400,
        'limit': 100,
        'snapshot': 't1.abc',
      });
    });

    test('viewer show reads the canonical id and keeps a 1 MiB body', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      final body = 'line\n' * 209715 + 'x';
      expect(utf8.encode(body), hasLength(1048576));
      launcher.replyWith(showDocument(body: body));

      final detail = await client.fetchTaskDetail(projectUuid, 42);

      expect(detail.canonicalId, 'T-042');
      expect(detail.body, body);
      expect(detail.dependencySummaries.single.canonicalId, 'T-009');
      expect(detail.dependencySummaries.single.preventsReadiness, isTrue);
      expect(detail.ruleVersion, 3);
      expect(detail.rules, '# Rules');
      expect(launcher.launches.last.arguments, <String>[
        '--data-root',
        r'C:\store',
        '--project',
        projectUuid,
        '--format',
        'json',
        'viewer',
        'show',
        'T-042',
      ]);
      expect(launcher.launches.last.handle.stdinClosed, isTrue);
      expect(launcher.launches.last.handle.stdinBytes, isEmpty);
    });

    test('history pages carry --limit and --after', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(historyDocument(hasMore: true, nextAfter: 11));

      final page = await client.fetchTaskHistory(
        projectUuid,
        42,
        after: 7,
        limit: 100,
      );

      expect(page.items.single.eventId, 11);
      expect(page.items.single.operation, 'update');
      expect(page.items.single.snapshotJson, '{"version":7}');
      expect(page.hasMore, isTrue);
      expect(page.nextAfter, 11);
      expect(launcher.launches.last.arguments, <String>[
        '--data-root',
        r'C:\store',
        '--project',
        projectUuid,
        '--format',
        'json',
        'history',
        'T-042',
        '--limit',
        '100',
        '--after',
        '7',
      ]);
    });

    test('one selected event is read with --event and no --after', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);
      launcher.replyWith(historyDocument());

      final page = await client.fetchTaskHistory(
        projectUuid,
        42,
        event: 11,
        limit: 1,
      );

      expect(page.items.single.eventId, 11);
      expect(page.hasMore, isFalse);
      expect(page.nextAfter, isNull);
      expect(launcher.launches.last.arguments, <String>[
        '--data-root',
        r'C:\store',
        '--project',
        projectUuid,
        '--format',
        'json',
        'history',
        'T-042',
        '--limit',
        '1',
        '--event',
        '11',
      ]);
    });

    test('an answer for another project UUID is rejected', () async {
      const other = '99999999-8888-7777-6666-555555555555';
      final launcher = ScriptedLauncher();
      final client = await probedClient(launcher);

      launcher.replyWith(tasksDocument(projectId: other));
      await expectLater(
        client.fetchTasks(projectUuid, const TaskQuery()),
        throwsA(
          isA<ViewerMalformedResponseFailure>().having(
            (failure) => failure.message,
            'message',
            contains(other),
          ),
        ),
      );

      launcher.replyWith(showDocument(projectId: other));
      await expectLater(
        client.fetchTaskDetail(projectUuid, 42),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );

      launcher.replyWith(historyDocument(projectId: other));
      await expectLater(
        client.fetchTaskHistory(projectUuid, 42, limit: 100),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('every read requires a passing probe first', () async {
      final launcher = ScriptedLauncher();
      final client = buildClient(launcher: launcher);
      launcher.replyWith(tasksDocument());

      await expectLater(
        client.fetchTasks(projectUuid, const TaskQuery()),
        throwsA(isA<ViewerProbeRequiredFailure>()),
      );
      await expectLater(
        client.fetchTaskDetail(projectUuid, 42),
        throwsA(isA<ViewerProbeRequiredFailure>()),
      );
      await expectLater(
        client.fetchTaskHistory(projectUuid, 42, limit: 100),
        throwsA(isA<ViewerProbeRequiredFailure>()),
      );
      expect(launcher.launches, isEmpty, reason: 'no process before a probe');
    });

    test('a missing data root is reported before a process starts', () async {
      final launcher = ScriptedLauncher();
      final client = await probedClient(
        launcher,
        environment: viewerEnvironmentForTest(dataRoot: null),
      );
      final launchesAfterProbe = launcher.launches.length;

      await expectLater(
        client.fetchTasks(projectUuid, const TaskQuery()),
        throwsA(
          isA<ViewerCliErrorFailure>()
              .having((failure) => failure.code, 'code', 'no_store')
              .having(
                (failure) => failure.message,
                'message',
                contains('Settings'),
              ),
        ),
      );
      expect(launcher.launches, hasLength(launchesAfterProbe));
    });
  });
}
