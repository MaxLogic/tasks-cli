/// Remote viewer receipt tests use only scripted CLI processes and synthetic JSON.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';

import '../data/cli_client_test.dart' as fixture;

class _Reply {
  const _Reply(
    this.stdout, {
    this.stderr = '',
    this.exit = 0,
    this.render,
    this.delayed = false,
  });
  final String stdout;
  final String stderr;
  final int exit;
  final String Function(List<String>)? render;
  final bool delayed;
}

class _DelayedHandle extends fixture.FakeProcessHandle {
  _DelayedHandle({required super.stdoutBytes, required super.stderrBytes});
  final Completer<int> ended = Completer<int>();
  @override
  Future<int> get exitCode => ended.future;
}

class _Launcher extends fixture.ScriptedLauncher {
  final Queue<_Reply> replies = Queue<_Reply>();

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final reply = replies.removeFirst();
    if (arguments.contains('recovery') && launches.isNotEmpty) {
      final update = launches
          .where((launch) => launch.arguments.contains('update'))
          .lastOrNull;
      if (update != null) {
        _lastRequestId =
            (jsonDecode(utf8.decode(update.handle.stdinBytes))
                    as Map<String, dynamic>)['request_id']
                as String?;
      }
    }
    final handle = reply.delayed
        ? _DelayedHandle(
            stdoutBytes: [utf8.encode(reply.stdout)],
            stderrBytes: [utf8.encode(reply.stderr)],
          )
        : fixture.FakeProcessHandle(
            stdoutBytes: <List<int>>[
              utf8.encode(reply.render?.call(arguments) ?? reply.stdout),
            ],
            stderrBytes: <List<int>>[utf8.encode(reply.stderr)],
            exit: reply.exit,
          );
    launches.add(fixture.LaunchedProcess(executable, arguments, handle));
    return handle;
  }
}

String _envelope(
  String command,
  Map<String, Object?> data, {
  String? projectId = fixture.projectUuid,
}) => jsonEncode(<String, Object?>{
  'schema_version': 1,
  'project_id': projectId,
  'data': <String, Object?>{'command': command, ...data},
});

String _remoteInfo() {
  final document = jsonDecode(fixture.infoDocument()) as Map<String, dynamic>;
  final data = document['data'] as Map<String, dynamic>;
  data['backend'] = 'remote';
  data['receipt_recovery'] = true;
  return jsonEncode(document);
}

String _recovery(List<Map<String, Object?>> items) => _envelope(
  'viewer_recovery',
  <String, Object?>{'items': items},
  projectId: null,
);

String _ack(List<String> arguments) => _envelope(
  'viewer_acknowledge',
  <String, Object?>{'request_id': arguments.last, 'acknowledged': true},
  projectId: null,
);
String _confirmedRecovery(List<String> arguments) =>
    _recovery(<Map<String, Object?>>[
      <String, Object?>{
        'request_id': _lastRequestId,
        'project_id': fixture.projectUuid,
        'operation': 'viewer_update',
        'task_id': 42,
        'outcome_known': true,
      },
    ]);
String? _lastRequestId;

String _update({int id = 42, int version = 8}) =>
    _envelope('viewer_update', <String, Object?>{
      'protocol_version': 1,
      'id': id,
      'status': 'todo',
      'version': version,
      'event_id': 19,
    });

ViewerUpdateRequest _request() => const ViewerUpdateRequest(
  id: 42,
  expectVersion: 7,
  changes: EditorFieldChanges(title: 'Changed'),
);

Future<ViewerCliClient> _client(
  _Launcher launcher, {
  List<Map<String, Object?>> pending = const [],
  Duration? readTimeout,
}) async {
  launcher.replies
    ..add(_Reply(_remoteInfo()))
    ..add(_Reply(_recovery(pending)));
  final client = fixture.buildClient(
    launcher: launcher,
    readTimeout: readTimeout ?? const Duration(seconds: 30),
  );
  await client.probe();
  return client;
}

void main() {
  test(
    'missing executable after probe clears the provisional receipt',
    () async {
      final launcher = _Launcher();
      bool exists = true;
      launcher.replies
        ..add(_Reply(_remoteInfo()))
        ..add(_Reply(_recovery(const [])));
      final client = fixture.buildClient(
        launcher: launcher,
        exists: (_) => exists,
      );
      await client.probe();
      exists = false;
      await expectLater(
        client.updateTask(fixture.projectUuid, _request()),
        throwsA(isA<ViewerExecutableNotFoundFailure>()),
      );
      expect(client.pendingReceipts, isEmpty);
      expect(launcher.launches.length, 2);
    },
  );
  test('CLI crash without a stored receipt keeps Save usable', () async {
    final launcher = _Launcher();
    final client = await _client(launcher);
    final editor = ViewerEditorController(writer: client, detailReader: client);
    final base = TaskDetail.fromJson(
      (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
          as Map<String, dynamic>,
    );
    editor.observeDetail(base, projectId: fixture.projectUuid);
    editor.beginEdit();
    editor.setField(EditorField.title, 'Changed');
    launcher.replies
      ..add(const _Reply('', exit: 5))
      ..add(_Reply(_recovery(const [])));
    expect((await editor.save()).outcome, EditorSaveOutcome.failed);
    expect(editor.isAwaitingReconciliation, isFalse);
    expect(editor.saveEnabled, isTrue);
    expect(editor.draft!.title, 'Changed');
    expect(client.pendingReceipts, isEmpty);
    editor.dispose();
  });
  test('confirmed reconciliation retries only the failed detail read', () async {
    final launcher = _Launcher();
    final client = await _client(launcher);
    final editor = ViewerEditorController(writer: client, detailReader: client);
    final base = TaskDetail.fromJson(
      (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
          as Map<String, dynamic>,
    );
    editor.observeDetail(base, projectId: fixture.projectUuid);
    editor.beginEdit();
    editor.setField(EditorField.title, 'Changed');
    launcher.replies.add(_Reply(_update(id: 99)));
    await editor.save();
    launcher.replies
      ..add(_Reply(_update()))
      ..add(const _Reply('', render: _ack))
      ..add(
        const _Reply(
          '',
          exit: 5,
          stderr:
              '{"schema_version":1,"error":{"code":"service_unavailable","message":"Outage"}}',
        ),
      );
    expect(
      (await editor.retryReconciliation()).outcome,
      EditorSaveOutcome.failed,
    );
    expect(editor.isAwaitingReconciliation, isTrue);
    expect(client.pendingReceipts, isEmpty);
    final fresh =
        jsonDecode(fixture.showDocument(title: 'Changed'))
            as Map<String, dynamic>;
    (fresh['data'] as Map<String, dynamic>)['version'] = 8;
    launcher.replies.add(_Reply(jsonEncode(fresh)));
    expect(
      (await editor.retryReconciliation()).outcome,
      EditorSaveOutcome.reconciled,
    );
    expect(
      launcher.launches
          .where((launch) => launch.arguments.contains('reconcile'))
          .length,
      1,
    );
    expect(editor.isEditing, isFalse);
    editor.dispose();
  });
  test('completed preflight outage leaves no false pending write', () async {
    final launcher = _Launcher();
    final client = await _client(launcher);
    launcher.replies
      ..add(
        const _Reply(
          '',
          exit: 5,
          stderr:
              '{"schema_version":1,"error":{"code":"service_unavailable","message":"Service unavailable"}}',
        ),
      )
      ..add(_Reply(_recovery(const [])));
    await expectLater(
      client.updateTask(fixture.projectUuid, _request()),
      throwsA(isA<ViewerCliErrorFailure>()),
    );
    expect(client.pendingReceipts, isEmpty);
    expect(launcher.launches.last.arguments, contains('recovery'));
  });
  test(
    'lost acknowledgement stdout checks only local cleanup evidence',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('invalid acknowledgement stdout'))
        ..add(_Reply(_recovery(const [])));
      expect(
        (await client.updateTask(fixture.projectUuid, _request())).version,
        8,
      );
      expect(client.pendingReceipts, isEmpty);
      expect(
        launcher.launches
            .where((launch) => launch.arguments.contains('update'))
            .length,
        1,
      );
      expect(
        launcher.launches.any(
          (launch) => launch.arguments.contains('reconcile'),
        ),
        isFalse,
      );
    },
  );
  test(
    'remote probe uses configured root and discovers restart receipts',
    () async {
      final launcher = _Launcher();
      final client = await _client(
        launcher,
        pending: <Map<String, Object?>>[
          <String, Object?>{
            'request_id': '11111111-1111-4111-8111-111111111111',
            'project_id': fixture.projectUuid,
            'operation': 'archive',
            'archived': true,
            'outcome_known': false,
          },
          <String, Object?>{
            'request_id': '22222222-2222-4222-8222-222222222222',
            'project_id': null,
            'operation': 'init',
            'outcome_known': true,
          },
        ],
      );
      expect(client.info!.isRemote, isTrue);
      expect(client.pendingReceipts.first.operation, 'archive');
      expect(client.pendingReceipts.last.projectId, isNull);
      expect(
        launcher.launches.first.arguments,
        containsAllInOrder(<String>[
          '--data-root',
          r'C:\store',
          '--format',
          'json',
          'viewer',
          'info',
        ]),
      );
      expect(launcher.launches.last.arguments, contains('recovery'));
      await expectLater(
        client.updateTask(fixture.projectUuid, _request()),
        throwsA(isA<ViewerPendingReceiptFailure>()),
      );
      expect(launcher.launches.length, 2);
    },
  );

  test(
    'valid update acknowledges only after matching result validation',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack));
      final result = await client.updateTask(fixture.projectUuid, _request());
      expect(result.version, 8);
      final request =
          jsonDecode(utf8.decode(launcher.launches[2].handle.stdinBytes))
              as Map<String, dynamic>;
      final id = request['request_id'] as String;
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(launcher.launches[3].arguments.last, id);
      expect(client.pendingReceipts, isEmpty);
    },
  );

  test(
    'invalid result keeps receipt; explicit reconciliation uses same ID',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      launcher.replies.add(_Reply(_update(id: 99)));
      await expectLater(
        client.updateTask(fixture.projectUuid, _request()),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
      final id = client.pendingReceipts.single.requestId;
      expect(launcher.launches.length, 3, reason: 'no acknowledgement yet');
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack));
      final result = await client.reconcileTaskWrite(fixture.projectUuid, 42);
      expect(result.id, 42);
      expect(launcher.launches[3].arguments.last, id);
      expect(client.pendingReceipts, isEmpty);
    },
  );

  test('archive passes UUID and waits for acknowledgement', () async {
    final launcher = _Launcher();
    final client = await _client(launcher);
    launcher.replies
      ..add(
        _Reply(
          _envelope('viewer_archive', <String, Object?>{
            'archived_at_ms': 1700000000000,
          }),
        ),
      )
      ..add(const _Reply('', render: _ack));
    expect(
      await client.setProjectArchived(fixture.projectUuid, archived: true),
      1700000000000,
    );
    final archiveArgs = launcher.launches[2].arguments;
    final id = archiveArgs[archiveArgs.indexOf('--request-id') + 1];
    expect(id, launcher.launches[3].arguments.last);
    expect(client.pendingReceipts, isEmpty);
  });

  test(
    'a timed-out preflight waits for process exit before clearing absent evidence',
    () async {
      final launcher = _Launcher();
      final client = await _client(
        launcher,
        readTimeout: const Duration(milliseconds: 25),
      );
      final editor = ViewerEditorController(
        writer: client,
        detailReader: client,
      );
      final base = TaskDetail.fromJson(
        (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>,
      );
      editor.observeDetail(base, projectId: fixture.projectUuid);
      editor.beginEdit();
      editor.setField(EditorField.title, 'Changed');
      launcher.replies.add(const _Reply('', delayed: true));
      await editor.save();
      final original = launcher.launches.last.handle as _DelayedHandle;
      expect(editor.isAwaitingReconciliation, isTrue);
      final early = await editor.retryReconciliation();
      expect(early.message, contains('still running'));
      expect(editor.isAwaitingReconciliation, isTrue);
      expect(original.killCount, 0);
      original.ended.complete(5);
      await Future<void>.delayed(Duration.zero);
      launcher.replies
        ..add(_Reply(_recovery(const [])))
        ..add(_Reply(fixture.showDocument()));
      await editor.retryReconciliation();
      expect(editor.isAwaitingReconciliation, isFalse);
      expect(editor.draft!.title, 'Changed');
      expect(editor.saveEnabled, isTrue);
      expect(client.pendingReceipts, isEmpty);
      expect(
        launcher.launches.where((p) => p.arguments.contains('reconcile')),
        isEmpty,
      );
      editor.dispose();
    },
  );

  test(
    'a timed-out dispatched write checks its receipt after original exit',
    () async {
      final launcher = _Launcher();
      final client = await _client(
        launcher,
        readTimeout: const Duration(milliseconds: 25),
      );
      launcher.replies.add(_Reply(_update(), delayed: true));
      await expectLater(
        client.updateTask(fixture.projectUuid, _request()),
        throwsA(isA<ViewerTimeoutFailure>()),
      );
      final original = launcher.launches.last.handle as _DelayedHandle;
      final id = client.pendingReceipts.single.requestId;
      await expectLater(
        client.reconcileTaskWrite(fixture.projectUuid, 42),
        throwsA(isA<ViewerPendingReceiptFailure>()),
      );
      expect(original.killCount, 0);
      original.ended.complete(0);
      await Future<void>.delayed(Duration.zero);
      launcher.replies
        ..add(const _Reply('', render: _confirmedRecovery))
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack));
      expect(
        (await client.reconcileTaskWrite(fixture.projectUuid, 42)).version,
        8,
      );
      expect(
        launcher.launches.where((p) => p.arguments.contains('update')),
        hasLength(1),
      );
      expect(
        launcher.launches
            .where((p) => p.arguments.contains('reconcile'))
            .single
            .arguments
            .last,
        id,
      );
      expect(client.pendingReceipts, isEmpty);
    },
  );

  test(
    'an outage during receipt check keeps the editor draft and pending state',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      final editor = ViewerEditorController(
        writer: client,
        detailReader: client,
      );
      final base = TaskDetail.fromJson(
        (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>,
      );
      editor.observeDetail(base, projectId: fixture.projectUuid);
      editor.beginEdit();
      editor.setField(EditorField.title, 'Changed');
      launcher.replies.add(_Reply(_update(id: 99)));
      await editor.save();
      launcher.replies.add(
        const _Reply(
          '',
          stderr:
              '{"schema_version":1,"error":{"code":"service_unavailable",'
              '"message":"Service unavailable"}}',
          exit: 5,
        ),
      );
      await editor.retryReconciliation();
      expect(editor.isAwaitingReconciliation, isTrue);
      expect(editor.draft!.title, 'Changed');
      expect(editor.saveEnabled, isFalse);
      expect(client.pendingReceipts, hasLength(1));
      expect(launcher.launches.last.arguments, contains('reconcile'));
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack))
        ..add(_Reply(fixture.showDocument(title: 'Changed')));
      expect(
        (await editor.retryReconciliation()).outcome,
        EditorSaveOutcome.conflict,
      );
      expect(client.pendingReceipts, isEmpty);
      editor.dispose();
    },
  );

  test(
    'terminal refusal acknowledges and preserves structured error',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      launcher.replies
        ..add(
          const _Reply(
            '',
            stderr:
                '{"schema_version":1,"error":'
                '{"code":"validation","message":"Invalid title"}}',
            exit: 2,
          ),
        )
        ..add(const _Reply('', render: _confirmedRecovery))
        ..add(const _Reply('', render: _ack));
      await expectLater(
        client.updateTask(fixture.projectUuid, _request()),
        throwsA(
          isA<ViewerCliErrorFailure>().having(
            (error) => error.code,
            'code',
            'validation',
          ),
        ),
      );
      expect(client.pendingReceipts, isEmpty);
    },
  );

  test(
    'reconciled terminal refusal clears receipt and keeps the editable draft',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      final editor = ViewerEditorController(
        writer: client,
        detailReader: client,
      );
      final base = TaskDetail.fromJson(
        (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>,
      );
      editor.observeDetail(base, projectId: fixture.projectUuid);
      editor.beginEdit();
      editor.setField(EditorField.title, 'Changed');
      launcher.replies.add(_Reply(_update(id: 99)));
      await editor.save();
      launcher.replies
        ..add(
          const _Reply(
            '',
            stderr:
                '{"schema_version":1,"error":{"code":"validation",'
                '"message":"Original refusal"}}',
            exit: 2,
          ),
        )
        ..add(const _Reply('', render: _ack))
        ..add(_Reply(fixture.showDocument()));
      final checked = await editor.retryReconciliation();
      expect(checked.message, contains('Original refusal'));
      expect(editor.isAwaitingReconciliation, isFalse);
      expect(editor.draft!.title, 'Changed');
      expect(editor.saveEnabled, isTrue);
      expect(client.pendingReceipts, isEmpty);
      final count = launcher.launches.length;
      await editor.retryReconciliation();
      expect(launcher.launches.length, count);
      expect(
        launcher.launches.where((p) => p.arguments.contains('update')),
        hasLength(1),
      );
      expect(
        launcher.launches.where((p) => p.arguments.contains('reconcile')),
        hasLength(1),
      );
      editor.dispose();
    },
  );

  test(
    'editor retains draft until explicit receipt check and fresh detail',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      final editor = ViewerEditorController(
        writer: client,
        detailReader: client,
      );
      final base = TaskDetail.fromJson(
        (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>,
      );
      editor.observeDetail(base, projectId: fixture.projectUuid);
      editor.beginEdit();
      editor.setField(EditorField.title, 'Changed');
      launcher.replies.add(_Reply(_update(id: 99)));
      final first = await editor.save();
      expect(first.outcome, EditorSaveOutcome.failed);
      expect(editor.isAwaitingReconciliation, isTrue);
      expect(editor.draft!.title, 'Changed');
      expect(editor.saveEnabled, isFalse);
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack))
        ..add(_Reply(fixture.showDocument(title: 'Changed')));
      // The fresh show fixture reports the updated title but an older version.
      // It must leave the draft for conflict review, never close it by title.
      final checked = await editor.retryReconciliation();
      expect(checked.outcome, EditorSaveOutcome.conflict);
      expect(editor.draft!.title, 'Changed');
      editor.dispose();
    },
  );

  test(
    'confirmed receipt closes editor only after fresh matching version',
    () async {
      final launcher = _Launcher();
      final client = await _client(launcher);
      final editor = ViewerEditorController(
        writer: client,
        detailReader: client,
      );
      final base = TaskDetail.fromJson(
        (jsonDecode(fixture.showDocument()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>,
      );
      editor.observeDetail(base, projectId: fixture.projectUuid);
      editor.beginEdit();
      editor.setField(EditorField.title, 'Changed');
      launcher.replies.add(_Reply(_update(id: 99)));
      await editor.save();
      final fresh =
          jsonDecode(fixture.showDocument(title: 'Changed'))
              as Map<String, dynamic>;
      (fresh['data'] as Map<String, dynamic>)['version'] = 8;
      launcher.replies
        ..add(_Reply(_update()))
        ..add(const _Reply('', render: _ack))
        ..add(_Reply(jsonEncode(fresh)));
      final checked = await editor.retryReconciliation();
      expect(checked.outcome, EditorSaveOutcome.reconciled);
      expect(editor.isEditing, isFalse);
      expect(client.pendingReceipts, isEmpty);
      editor.dispose();
    },
  );

  test(
    'legacy history accepts null attribution and displays typed context',
    () {
      final legacy = HistoryEvent.fromJson(<String, Object?>{
        'event_id': 1,
        'operation': 'update',
        'resulting_version': 2,
        'created_ms': 3,
      }, path: r'$.items[0]');
      expect(legacy.attribution, isNull);
      final attributed = HistoryEvent.fromJson(<String, Object?>{
        'event_id': 2,
        'operation': 'update',
        'resulting_version': 3,
        'created_ms': 4,
        'attribution': <String, Object?>{
          'actor_name': 'Pawel',
          'machine_name': 'Laptop',
          'harness': 'codex',
          'session_id': 'session-1',
          'model': 'gpt-6',
          'machine_id': 'installation-1',
          'request_id': 'request-1',
          'context_source': <String, Object?>{'model': 'hook'},
        },
      }, path: r'$.items[1]');
      expect(
        attributed.attribution!.summary,
        contains('Actor Pawel, Machine Laptop, Harness codex'),
      );
      expect(
        attributed.attribution!.detailText,
        contains('Installation ID: installation-1'),
      );
      expect(
        attributed.attribution!.detailText,
        contains('Request ID: request-1'),
      );
      expect(
        attributed.attribution!.detailText,
        contains('model source: hook'),
      );
    },
  );
}
