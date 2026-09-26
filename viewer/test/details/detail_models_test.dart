/// Task detail and history document shapes (viewer/spec.md sections 4.3 and 6).
///
/// The decoder is the only place a CLI document becomes Dart objects, so these
/// tests use complete documents: they prove that a 1 MiB body, dependency
/// summaries and the rules version survive decoding unchanged.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';

const String projectUuid = '2f6f0a54-1b1a-4c3a-9a3e-6a1f7e9d1111';

Map<String, Object?> showDocument({
  required String body,
  String id = 'T-007',
  int taskId = 7,
  String status = 'todo',
  List<Object?>? dependencySummaries,
}) => <String, Object?>{
  'schema_version': 1,
  'project_id': projectUuid,
  'data': <String, Object?>{
    'command': 'viewer_show',
    'protocol_version': 1,
    'id': taskId,
    'status': status,
    'priority': 'P1',
    'version': 3,
    'title': 'Fix $id import title parsing',
    'body': body,
    'deps': <int>[5, 6],
    'labels': <String>['ui', 'needs-human'],
    'dependency_summaries':
        dependencySummaries ??
        <Object?>[
          <String, Object?>{
            'id': 5,
            'title': 'Terminal dependency',
            'status': 'done',
            'version': 2,
          },
          <String, Object?>{
            'id': 6,
            'title': 'Open dependency',
            'status': 'in-progress',
            'version': 1,
          },
        ],
    'rule_version': 4,
    'rules': 'Rule one\nRule two\n',
    'created_ms': 1700000000000,
    'updated_ms': 1700000001000,
  },
};

TaskDetail decodeDetail(Map<String, Object?> document) {
  final envelope = ViewerEnvelope.decode(
    jsonEncode(document),
    expectedCommands: <String>{'viewer_show'},
  );
  expect(envelope.projectId, projectUuid);
  return TaskDetail.fromJson(envelope.data);
}

void main() {
  test('a complete show document decodes every field', () {
    final detail = decodeDetail(showDocument(body: 'Body text\n'));

    expect(detail.id, 7);
    expect(detail.canonicalId, 'T-007');
    expect(detail.title, 'Fix T-007 import title parsing');
    expect(detail.status, 'todo');
    expect(detail.priority, 'P1');
    expect(detail.version, 3);
    expect(detail.labels, <String>['ui', 'needs-human']);
    expect(detail.deps, <int>[5, 6]);
    expect(detail.ruleVersion, 4);
    expect(detail.rules, 'Rule one\nRule two\n');
    expect(detail.createdMs, 1700000000000);
    expect(detail.updatedMs, 1700000001000);
  });

  test('a 1 MiB body decodes without truncation', () {
    final source = StringBuffer();
    var line = 0;
    while (source.length < 1024 * 1024) {
      source.writeln('line ${line++} with body text');
    }
    final body = source.toString();

    final detail = decodeDetail(showDocument(body: body));

    expect(body.length, greaterThanOrEqualTo(1024 * 1024));
    expect(detail.body.length, body.length);
    expect(detail.body, body);
    expect(detail.body.endsWith('\n'), isTrue);
  });

  test(
    'dependency summaries keep terminal dependencies but not as blockers',
    () {
      final detail = decodeDetail(showDocument(body: 'Body\n'));

      expect(detail.dependencySummaries, hasLength(2));
      final terminal = detail.dependencySummaries.first;
      expect(terminal.canonicalId, 'T-005');
      expect(terminal.title, 'Terminal dependency');
      expect(terminal.status, 'done');
      expect(
        terminal.preventsReadiness,
        isFalse,
        reason: 'a terminal dependency is shown but no longer blocks',
      );
      expect(detail.dependencySummaries.last.preventsReadiness, isTrue);
    },
  );

  test('an unsupported status is an error, not a guessed value', () {
    expect(
      () => decodeDetail(showDocument(body: 'Body\n', status: 'paused')),
      throwsA(isA<ViewerMalformedResponseFailure>()),
    );
  });

  test('a missing dependency summary field is an error', () {
    expect(
      () => decodeDetail(
        showDocument(
          body: 'Body\n',
          dependencySummaries: <Object?>[
            <String, Object?>{'id': 5, 'title': 'Missing status', 'version': 2},
          ],
        ),
      ),
      throwsA(isA<ViewerMalformedResponseFailure>()),
    );
  });

  test('a history page decodes events with and without snapshots', () {
    final envelope = ViewerEnvelope.decode(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'project_id': projectUuid,
        'data': <String, Object?>{
          'command': 'history',
          'id': 7,
          'items': <Object?>[
            <String, Object?>{
              'event_id': 42,
              'task_id': 7,
              'entity_type': 'task',
              'operation': 'update',
              'resulting_version': 4,
              'created_ms': 1700000002000,
              'snapshot_json': '{\n  "title": "Fix import"\n}\n',
            },
            <String, Object?>{
              'event_id': 41,
              'task_id': 7,
              'entity_type': 'task',
              'operation': 'create',
              'resulting_version': 1,
              'created_ms': 1700000000000,
              'snapshot_json': null,
            },
          ],
          'has_more': true,
          'next_after': 41,
        },
      }),
      expectedCommands: <String>{'history'},
    );

    final page = TaskHistoryPage.fromJson(envelope.data);

    expect(page.items, hasLength(2));
    expect(page.items.first.eventId, 42);
    expect(page.items.first.operation, 'update');
    expect(page.items.first.resultingVersion, 4);
    expect(page.items.first.snapshotJson, contains('Fix import'));
    expect(page.items.last.snapshotJson, isNull);
    expect(page.hasMore, isTrue);
    expect(page.nextAfter, 41);
  });

  test('a lean history page decodes nested snapshots and changed fields', () {
    final envelope = ViewerEnvelope.decode(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'project_id': projectUuid,
        'data': <String, Object?>{
          'command': 'history',
          'id': 7,
          'items': <Object?>[
            <String, Object?>{
              'event_id': 41,
              'operation': 'create',
              'resulting_version': 1,
              'created_ms': 1700000000000,
            },
            <String, Object?>{
              'event_id': 42,
              'operation': 'update',
              'resulting_version': 2,
              'created_ms': 1700000002000,
              'changed_fields': <Object?>['status', 'labels'],
              'snapshot': <String, Object?>{'title': 'Fix import'},
            },
          ],
          'has_more': false,
          'next_after': 42,
        },
      }),
      expectedCommands: <String>{'history'},
    );

    final page = TaskHistoryPage.fromJson(envelope.data);

    expect(page.items.first.snapshotJson, isNull);
    expect(page.items.first.changedFields, isNull);
    expect(page.items.first.entityType, 'task');
    expect(page.items.last.changedFields, <String>['status', 'labels']);
    expect(jsonDecode(page.items.last.snapshotJson!), <String, Object?>{
      'title': 'Fix import',
    });
  });

  test('one event document keeps the complete snapshot text', () {
    final snapshot = StringBuffer();
    while (snapshot.length < 100000) {
      snapshot.writeln('snapshot line');
    }
    final envelope = ViewerEnvelope.decode(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'project_id': projectUuid,
        'data': <String, Object?>{
          'command': 'history',
          'id': 7,
          'items': <Object?>[
            <String, Object?>{
              'event_id': 99,
              'task_id': 7,
              'entity_type': 'task',
              'operation': 'update',
              'resulting_version': 5,
              'created_ms': 1700000003000,
              'snapshot_json': snapshot.toString(),
            },
          ],
          'has_more': false,
          'next_after': null,
        },
      }),
      expectedCommands: <String>{'history'},
    );

    final page = TaskHistoryPage.fromJson(envelope.data);

    expect(page.items.single.snapshotJson, snapshot.toString());
    expect(page.hasMore, isFalse);
    expect(page.nextAfter, isNull);
  });

  test('the task query document carries every filter field', () {
    const query = TaskQuery(
      query: 'parse',
      scope: TaskScope.all,
      statuses: <String>['done'],
      priorities: <String>['P1'],
      labels: <String>['ui'],
      readiness: TaskReadiness.waiting,
      sort: TaskSort.updated,
      direction: SortDirection.descending,
      offset: 100,
      limit: 100,
      snapshot: 'p1.abc',
    );

    expect(query.toJson(), <String, Object?>{
      'query': 'parse',
      'scope': 'all',
      'statuses': <String>['done'],
      'priorities': <String>['P1'],
      'labels': <String>['ui'],
      'readiness': 'waiting',
      'sort': 'updated',
      'direction': 'desc',
      'offset': 100,
      'limit': 100,
      'snapshot': 'p1.abc',
    });
  });
}
