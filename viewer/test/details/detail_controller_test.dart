/// Detail-controller semantics: debounce versus immediate load, late-answer
/// guards, history paging, event snapshots, find in body and the dependency
/// back stack.
///
/// Contract: viewer/spec.md sections 5 and 6 plus viewer/design.md sections 7
/// and 9. Every test drives the controller through an injected reader, so each
/// expectation is about the request the CLI would receive and the state the
/// pane would render.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart';
import 'package:tasks_viewer/data/models.dart';

const String testProjectId = '11111111-2222-3333-4444-555555555555';
const Duration _fastDebounce = Duration(milliseconds: 20);

TaskDetailController buildDetailController(
  TaskDetailReader reader, {
  Duration debounce = taskDetailDebounce,
  int historyPageSize = taskHistoryPageSize,
}) => TaskDetailController(
  projectId: testProjectId,
  reader: reader,
  debounce: debounce,
  historyPageSize: historyPageSize,
);

/// One complete detail record for a synthetic catalog.
TaskDetail detailFor(
  int id, {
  String? title,
  String body = 'body text',
  String status = 'todo',
  String priority = 'P2',
  int version = 1,
  List<String> labels = const <String>[],
  List<int> deps = const <int>[],
  List<DependencySummary> dependencySummaries = const <DependencySummary>[],
  int ruleVersion = 3,
  String rules = '# Project rules',
}) => TaskDetail(
  id: id,
  title: title ?? 'Task $id',
  body: body,
  status: status,
  priority: priority,
  version: version,
  labels: labels,
  deps: deps,
  dependencySummaries: dependencySummaries,
  ruleVersion: ruleVersion,
  rules: rules,
  createdMs: 1700000000000 + id,
  updatedMs: 1700000001000 + id,
);

/// One dependency row as `viewer show` reports it.
DependencySummary dependency(
  int id, {
  String? title,
  String status = 'todo',
  int version = 1,
}) => DependencySummary(
  id: id,
  title: title ?? 'Task $id',
  status: status,
  version: version,
);

/// One append-only event as the legacy `history` command reports it.
HistoryEvent historyEvent(
  int eventId, {
  int taskId = 5,
  String operation = 'create',
  int resultingVersion = 1,
  String? snapshot = '{"snapshot":true}',
}) => HistoryEvent(
  eventId: eventId,
  taskId: taskId,
  entityType: 'task',
  operation: operation,
  resultingVersion: resultingVersion,
  createdMs: 1700000000000 + eventId,
  snapshotJson: snapshot,
);

TaskHistoryPage historyPage(
  List<HistoryEvent> items, {
  bool hasMore = false,
  int? nextAfter,
}) => TaskHistoryPage(items: items, hasMore: hasMore, nextAfter: nextAfter);

/// The CLI error code behind a failure, for concrete assertions.
String? errorCode(ViewerFailure? failure) =>
    failure is ViewerCliErrorFailure ? failure.code : null;

/// One recorded history read, in the exact shape the controller requested.
class HistoryRequest {
  const HistoryRequest({
    required this.projectId,
    required this.taskId,
    required this.limit,
    this.after,
    this.event,
  });

  final String projectId;
  final int taskId;
  final int limit;
  final int? after;
  final int? event;
}

typedef DetailResponder =
    Future<TaskDetail> Function(String projectId, int taskId);
typedef HistoryResponder =
    Future<TaskHistoryPage> Function(
      String projectId,
      int taskId, {
      int? after,
      required int limit,
      int? event,
    });

/// Records every request and answers from the responders.
///
/// Without a responder for one operation each call waits for the test to
/// complete the matching entry of [manualDetails] or [manualHistory], so
/// in-flight behavior is observable.
class FakeDetailReader implements CancellableTaskDetailReader {
  FakeDetailReader({this.detailResponder, this.historyResponder});

  DetailResponder? detailResponder;
  HistoryResponder? historyResponder;
  final List<String> detailProjectIds = <String>[];
  final List<int> detailRequests = <int>[];
  final List<HistoryRequest> historyRequests = <HistoryRequest>[];
  final List<String> cancelledScopes = <String>[];
  final List<Completer<TaskDetail>> manualDetails = <Completer<TaskDetail>>[];
  final List<Completer<TaskHistoryPage>> manualHistory =
      <Completer<TaskHistoryPage>>[];

  @override
  Future<TaskDetail> fetchTaskDetail(String projectId, int taskId) {
    detailProjectIds.add(projectId);
    detailRequests.add(taskId);
    final responder = detailResponder;
    if (responder != null) {
      return responder(projectId, taskId);
    }
    final completer = Completer<TaskDetail>();
    manualDetails.add(completer);
    return completer.future;
  }

  @override
  Future<TaskHistoryPage> fetchTaskHistory(
    String projectId,
    int taskId, {
    int? after,
    int limit = 100,
    int? event,
  }) {
    historyRequests.add(
      HistoryRequest(
        projectId: projectId,
        taskId: taskId,
        limit: limit,
        after: after,
        event: event,
      ),
    );
    final responder = historyResponder;
    if (responder != null) {
      return responder(
        projectId,
        taskId,
        after: after,
        limit: limit,
        event: event,
      );
    }
    final completer = Completer<TaskHistoryPage>();
    manualHistory.add(completer);
    return completer.future;
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);
}

void main() {
  group('selection', () {
    test('arrow selection waits for the debounce and reads once', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
      );
      final controller = buildDetailController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.selectTask(5);
      controller.selectTask(6);
      controller.selectTask(7);
      expect(reader.detailRequests, isEmpty, reason: 'still settling');
      expect(controller.taskId, 7);
      expect(controller.isLoading, isTrue);

      await Future<void>.delayed(_fastDebounce * 3);
      expect(reader.detailRequests, <int>[7]);
      expect(reader.detailProjectIds.single, testProjectId);
      expect(controller.detail?.id, 7);
      expect(controller.isLoading, isFalse);
    });

    test('Enter opens without waiting for the debounce', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
      );
      final controller = buildDetailController(
        reader,
        debounce: const Duration(seconds: 10),
      );
      addTearDown(controller.dispose);

      await controller.openTask(5);

      expect(reader.detailRequests, <int>[5]);
      expect(controller.detail?.id, 5);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reader.detailRequests, <int>[
        5,
      ], reason: 'Enter cancels the pending debounce');
    });

    test('selecting the same row again does not re-read it', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
      );
      final controller = buildDetailController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);
      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);

      expect(reader.detailRequests, <int>[5]);
    });

    test('a late answer for an old selection is ignored', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);
      final pending = controller.openTask(7);
      expect(reader.detailRequests, <int>[5, 7]);

      reader.manualDetails[0].complete(detailFor(5, title: 'Old selection'));
      await pumpEventQueue();
      expect(controller.taskId, 7);
      expect(controller.isLoading, isTrue, reason: 'task 7 is still loading');
      expect(controller.detail, isNull);

      reader.manualDetails[1].complete(detailFor(7, title: 'New selection'));
      await pending;
      expect(controller.detail?.title, 'New selection');
      expect(controller.detailMatchesSelection, isTrue);
    });

    test('changing the selection cancels the superseded read', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      reader.cancelledScopes.clear();
      await controller.openTask(7);
      expect(reader.cancelledScopes, contains('detail'));
    });

    test('clearSelection drops the selection and cancels in flight', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);
      controller.clearSelection();

      expect(controller.taskId, isNull);
      expect(controller.canonicalTaskId, isNull);
      expect(controller.detail, isNull);
      expect(controller.isLoading, isFalse);
      expect(reader.cancelledScopes, contains('detail'));

      reader.manualDetails[0].complete(detailFor(5));
      await pumpEventQueue();
      expect(controller.detail, isNull);
      expect(controller.isLoading, isFalse);
    });
  });

  group('failures', () {
    test('a failed first read is an error with a working Retry', () async {
      var failNext = true;
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async {
          if (failNext) {
            failNext = false;
            throw const ViewerCliErrorFailure(
              code: 'not_found',
              message: 'task T-005 does not exist',
              exitCode: 4,
            );
          }
          return detailFor(taskId);
        },
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      expect(controller.detail, isNull);
      expect(controller.isLoading, isFalse);
      expect(errorCode(controller.loadError), 'not_found');
      expect(controller.detailIsStale, isFalse);

      await controller.reload();
      expect(controller.loadError, isNull);
      expect(controller.detail?.id, 5);
    });

    test('a failed re-read keeps the last confirmed detail as stale', () async {
      var failNext = false;
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async {
          if (failNext) {
            throw const ViewerCliErrorFailure(
              code: 'timeout',
              message: 'the store is busy',
              exitCode: 5,
            );
          }
          return detailFor(taskId, title: 'Confirmed');
        },
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      failNext = true;
      await controller.reload();

      expect(controller.detail?.title, 'Confirmed');
      expect(errorCode(controller.loadError), 'timeout');
      expect(controller.detailIsStale, isTrue);
      expect(controller.isLoading, isFalse);
    });

    test('a failure for another task never replaces this task text', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);
      final pending = controller.openTask(7);
      reader.manualDetails[0].completeError(
        const ViewerProcessStartFailure('the CLI could not start'),
      );
      await pumpEventQueue();
      reader.manualDetails[1].complete(detailFor(7));
      await pending;

      expect(controller.detail?.id, 7);
      expect(controller.loadError, isNull);
    });
  });

  group('history', () {
    FakeDetailReader historyReader({int totalEvents = 3}) => FakeDetailReader(
      detailResponder: (projectId, taskId) async => detailFor(
        taskId,
        deps: const <int>[9],
        dependencySummaries: <DependencySummary>[dependency(9)],
      ),
      historyResponder:
          (projectId, taskId, {after, required limit, event}) async {
            if (event != null) {
              return historyPage(<HistoryEvent>[
                historyEvent(event, snapshot: 'snapshot $event'),
              ]);
            }
            final start = after ?? 0;
            final items = <HistoryEvent>[
              for (
                var id = start + 1;
                id <= start + limit && id <= totalEvents;
                id++
              )
                historyEvent(id, snapshot: '{"id":$id}'),
            ];
            final last = start + items.length;
            return historyPage(
              items,
              hasMore: last < totalEvents,
              nextAfter: last < totalEvents ? last : null,
            );
          },
    );

    test('history loads once on activation, then pages with after', () async {
      final reader = historyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      expect(
        reader.historyRequests,
        isEmpty,
        reason: 'history must not load for every row',
      );

      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(reader.historyRequests, hasLength(1));
      expect(reader.historyRequests.single.taskId, 5);
      expect(reader.historyRequests.single.after, isNull);
      expect(reader.historyRequests.single.limit, taskHistoryPageSize);
      expect(controller.historyEvents, hasLength(3));
      expect(controller.historyLoaded, isTrue);
      expect(controller.historyHasMore, isFalse);

      await controller.loadMoreHistory();
      expect(
        reader.historyRequests,
        hasLength(1),
        reason: 'the last page has nothing more to load',
      );
    });

    test('the next page continues from next_after', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async {
              final start = after ?? 0;
              return historyPage(
                <HistoryEvent>[historyEvent(start + 1)],
                hasMore: start + 1 < 3,
                nextAfter: start + 1 < 3 ? start + 1 : null,
              );
            },
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(reader.historyRequests.single.after, isNull);
      expect(controller.historyHasMore, isTrue);

      await controller.loadMoreHistory();
      expect(reader.historyRequests, hasLength(2));
      expect(reader.historyRequests.last.after, 1);
      expect(controller.historyEvents.map((event) => event.eventId), <int>[
        1,
        2,
      ]);
      expect(controller.historyHasMore, isTrue);

      await controller.loadMoreHistory();
      expect(reader.historyRequests.last.after, 2);
      expect(controller.historyHasMore, isFalse);
      await controller.loadMoreHistory();
      expect(reader.historyRequests, hasLength(3));
    });

    test('opening a task on the History tab loads that task history', () async {
      final reader = historyReader(totalEvents: 1);
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(reader.historyRequests, isEmpty, reason: 'nothing is selected');

      await controller.openTask(5);
      await pumpEventQueue();
      expect(reader.historyRequests, hasLength(1));
      expect(reader.historyRequests.single.taskId, 5);
    });

    test('a new selection drops the previous history', () async {
      final reader = historyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(controller.historyEvents, isNotEmpty);

      await controller.openTask(6);
      expect(controller.historyEvents, isEmpty);
      expect(controller.historyLoaded, isFalse);
      await pumpEventQueue();
      expect(reader.historyRequests.last.taskId, 6);
      expect(reader.historyRequests.last.after, isNull);
    });

    test('history loads once; switching tabs does not re-read', () async {
      final reader = historyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      controller.setTab(TaskDetailTab.rules);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();

      expect(reader.historyRequests, hasLength(1));
    });

    test('a history failure is reported and Retry can load it', () async {
      var failNext = true;
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async {
              if (failNext) {
                failNext = false;
                throw const ViewerCliErrorFailure(
                  code: 'not_found',
                  message: 'task T-005 does not exist',
                  exitCode: 4,
                );
              }
              return historyPage(<HistoryEvent>[historyEvent(1)]);
            },
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(errorCode(controller.historyError), 'not_found');
      expect(controller.historyLoaded, isFalse);

      await controller.ensureHistoryLoaded();
      expect(controller.historyError, isNull);
      expect(controller.historyEvents, hasLength(1));
    });
  });

  group('events', () {
    test('selecting an event asks for exactly that event', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async =>
                historyPage(<HistoryEvent>[
                  historyEvent(event ?? 1, snapshot: 'text of event $event'),
                ]),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.selectEvent(42);

      expect(reader.historyRequests.single.event, 42);
      expect(reader.historyRequests.single.limit, 1);
      expect(reader.historyRequests.single.after, isNull);
      expect(controller.openedEventId, 42);
      expect(controller.eventSnapshot, 'text of event 42');
      expect(controller.isEventLoading, isFalse);
      expect(controller.eventError, isNull);
    });

    test('a late snapshot for an earlier event is ignored', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      unawaited(controller.selectEvent(1));
      unawaited(controller.selectEvent(2));
      expect(controller.isEventLoading, isTrue);
      expect(controller.eventSnapshot, isNull);

      reader.manualHistory[0].complete(
        historyPage(<HistoryEvent>[historyEvent(1, snapshot: 'first')]),
      );
      await pumpEventQueue();
      expect(controller.openedEventId, 2);
      expect(controller.isEventLoading, isTrue);
      expect(controller.eventSnapshot, isNull);

      reader.manualHistory[1].complete(
        historyPage(<HistoryEvent>[historyEvent(2, snapshot: 'second')]),
      );
      await pumpEventQueue();
      expect(controller.openedEventId, 2);
      expect(controller.eventSnapshot, 'second');
      expect(controller.isEventLoading, isFalse);
    });

    test('an event error is reported and can be retried', () async {
      var failNext = true;
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async {
              if (failNext) {
                failNext = false;
                throw const ViewerCliErrorFailure(
                  code: 'not_found',
                  message: 'event 42 does not exist',
                  exitCode: 4,
                );
              }
              return historyPage(<HistoryEvent>[
                historyEvent(event ?? 0, snapshot: 'recovered'),
              ]);
            },
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.selectEvent(42);
      expect(errorCode(controller.eventError), 'not_found');
      expect(controller.openedEventId, 42);
      expect(controller.eventSnapshot, isNull);

      await controller.selectEvent(42);
      expect(controller.eventError, isNull);
      expect(controller.eventSnapshot, 'recovered');
    });

    test('switching tasks clears the open event', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async => detailFor(taskId),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async =>
                historyPage(<HistoryEvent>[historyEvent(event ?? 1)]),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.selectEvent(42);
      await controller.openTask(6);

      expect(controller.openedEventId, isNull);
      expect(controller.eventSnapshot, isNull);
    });
  });

  group('find in body', () {
    Future<TaskDetailController> openWithBody(String body) async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async =>
            detailFor(taskId, title: 'Alpha title', body: body),
      );
      final controller = buildDetailController(reader);
      await controller.openTask(5);
      return controller;
    }

    test('matching is literal, case-insensitive and body-only', () async {
      final controller = await openWithBody('Alpha beta ALPHA\n');
      addTearDown(controller.dispose);

      controller.setFindText('alpha');
      expect(controller.matchCount, 2);
      expect(controller.matchIndex, 0);
      expect(controller.matchStart, 0);
      expect(controller.matchEnd, 5);
      expect(controller.findSummary, '2 matches');

      controller.setFindText('  beta  ');
      expect(controller.matchCount, 1);
      expect(controller.matchStart, 6);
      expect(controller.matchEnd, 10);

      controller.setFindText('title');
      expect(
        controller.matchCount,
        0,
        reason: 'the title is shown separately and is not searched',
      );
      expect(controller.findSummary, 'No matches');
    });

    test('overlapping occurrences are all reported', () async {
      final controller = await openWithBody('aaaa');
      addTearDown(controller.dispose);

      controller.setFindText('aa');
      expect(controller.matchCount, 3);
    });

    test(
      'Next wraps from the last match and Previous from the first',
      () async {
        final controller = await openWithBody('one two one two');
        addTearDown(controller.dispose);

        controller.setFindText('one');
        expect(controller.matchCount, 2);
        controller.findNext();
        expect(controller.matchIndex, 1);
        expect(controller.findNotice, isNull);
        controller.findNext();
        expect(controller.matchIndex, 0);
        expect(controller.findNotice, 'Wrapped to the first match');
        controller.findPrevious();
        expect(controller.matchIndex, 1);
        expect(controller.findNotice, 'Wrapped to the last match');
        controller.findPrevious();
        expect(controller.matchIndex, 0);
        expect(controller.findNotice, isNull);
        controller.findPrevious();
        expect(controller.matchIndex, 1);
        expect(controller.findNotice, 'Wrapped to the last match');
      },
    );

    test('no matches is reported and stepping stays put', () async {
      final controller = await openWithBody('one two one');
      addTearDown(controller.dispose);

      controller.setFindText('missing');
      expect(controller.matchCount, 0);
      expect(controller.matchIndex, -1);
      controller.findNext();
      expect(controller.matchIndex, -1);
      expect(controller.findNotice, 'No matches');
      controller.findPrevious();
      expect(controller.findNotice, 'No matches');
    });

    test('matches recompute for a newly loaded task body', () async {
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async =>
            detailFor(taskId, body: 'needle for $taskId'),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      controller.setFindText('needle');
      expect(controller.matchCount, 0, reason: 'nothing is loaded yet');
      await controller.openTask(5);
      expect(controller.matchCount, 1);
      expect(controller.matchStart, 0);
    });
  });

  group('dependencies', () {
    FakeDetailReader dependencyReader() => FakeDetailReader(
      detailResponder: (projectId, taskId) async => detailFor(
        taskId,
        deps: const <int>[9, 11],
        dependencySummaries: <DependencySummary>[
          dependency(9, title: 'Parser rewrite', status: 'in-progress'),
          dependency(11, title: 'Shipped step', status: 'done'),
        ],
      ),
    );

    test('the detail exposes every dependency with readiness', () async {
      final reader = dependencyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);

      expect(controller.dependencies, hasLength(2));
      expect(controller.dependencies.first.canonicalId, 'T-009');
      expect(controller.dependencies.first.preventsReadiness, isTrue);
      expect(
        controller.dependencies.last.preventsReadiness,
        isFalse,
        reason: 'a terminal dependency is still shown but cannot block',
      );
      expect(controller.canGoBack, isFalse);
    });

    test('opening a dependency pushes Back and Back restores it', () async {
      final reader = dependencyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.openDependency(9);

      expect(reader.detailRequests, <int>[5, 9]);
      expect(controller.taskId, 9);
      expect(controller.detail?.id, 9);
      expect(controller.backStack, <int>[5]);
      expect(controller.canGoBack, isTrue);

      await controller.goBack();
      expect(reader.detailRequests, <int>[5, 9, 5]);
      expect(controller.taskId, 5);
      expect(controller.detail?.id, 5);
      expect(controller.canGoBack, isFalse);

      await controller.goBack();
      expect(reader.detailRequests, <int>[
        5,
        9,
        5,
      ], reason: 'Back on an empty stack does nothing');
    });

    test('opening the current task is ignored', () async {
      final reader = dependencyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.openDependency(5);

      expect(reader.detailRequests, <int>[5]);
      expect(controller.canGoBack, isFalse);
    });

    test('a new row selection clears the dependency back stack', () async {
      final reader = dependencyReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      await controller.openDependency(9);
      await controller.openTask(6);

      expect(controller.canGoBack, isFalse);
      expect(controller.backStack, isEmpty);
    });
  });

  group('refresh and lifecycle', () {
    test('refresh re-reads the task and its already loaded history', () async {
      var body = 'first';
      var events = 1;
      final reader = FakeDetailReader(
        detailResponder: (projectId, taskId) async =>
            detailFor(taskId, body: body),
        historyResponder:
            (projectId, taskId, {after, required limit, event}) async =>
                historyPage(<HistoryEvent>[
                  for (var id = 1; id <= events; id++) historyEvent(id),
                ]),
      );
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.openTask(5);
      controller.setTab(TaskDetailTab.history);
      await pumpEventQueue();
      expect(controller.historyEvents, hasLength(1));

      body = 'second';
      events = 2;
      await controller.reload();
      await pumpEventQueue();

      expect(controller.detail?.body, 'second');
      expect(reader.historyRequests, hasLength(2));
      expect(reader.historyRequests.last.after, isNull);
      expect(controller.historyEvents, hasLength(2));
    });

    test('refresh keeps the confirmed body visible while re-reading', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      unawaited(controller.openTask(5));
      reader.manualDetails[0].complete(detailFor(5, body: 'confirmed'));
      await pumpEventQueue();

      final pending = controller.reload();
      expect(controller.detail?.body, 'confirmed');
      expect(controller.isLoading, isTrue);

      reader.manualDetails[1].complete(detailFor(5, body: 'newer'));
      await pending;
      expect(controller.detail?.body, 'newer');
      expect(controller.isLoading, isFalse);
    });

    test('reload without a selection does nothing', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader);
      addTearDown(controller.dispose);

      await controller.reload();
      expect(reader.detailRequests, isEmpty);
    });

    test('dispose cancels the read and stops notifying', () async {
      final reader = FakeDetailReader();
      final controller = buildDetailController(reader, debounce: _fastDebounce);

      var notifications = 0;
      controller.addListener(() => notifications += 1);
      controller.selectTask(5);
      await Future<void>.delayed(_fastDebounce * 3);
      final before = notifications;

      controller.dispose();
      expect(reader.cancelledScopes, contains('detail'));

      reader.manualDetails[0].complete(detailFor(5));
      await pumpEventQueue();
      expect(notifications, before);
    });
  });

  group('tabs', () {
    test('every tab has the command suffix its access key uses', () {
      expect(TaskDetailTab.details.commandSuffix, 'Details');
      expect(TaskDetailTab.dependencies.commandSuffix, 'Dependencies');
      expect(TaskDetailTab.history.commandSuffix, 'History');
      expect(TaskDetailTab.rules.commandSuffix, 'Rules');
      expect(TaskDetailTab.fromCommandSuffix('History'), TaskDetailTab.history);
      expect(TaskDetailTab.fromCommandSuffix('Rules'), TaskDetailTab.rules);
      expect(TaskDetailTab.fromCommandSuffix('Nope'), isNull);
      expect(TaskDetailTab.details.label, 'Details');
      expect(TaskDetailTab.rules.label, 'Project rules');
    });

    test('the initial tab is Details', () {
      final controller = buildDetailController(FakeDetailReader());
      addTearDown(controller.dispose);
      expect(controller.tab, TaskDetailTab.details);
    });
  });
}
