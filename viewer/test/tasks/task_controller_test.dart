/// Task-list controller semantics: query parameters, paging, cache bounds,
/// selection and failure states.
///
/// Contract: viewer/spec.md sections 4.3, 5 and 6 plus viewer/design.md
/// sections 5 and 6. Every test drives the controller through an injected
/// reader, so each expectation is about the request the CLI would receive and
/// the state the pane would render.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/models.dart';

const String testProjectId = '11111111-2222-3333-4444-555555555555';
const Duration _fastDebounce = Duration(milliseconds: 20);

TaskController buildTaskController(
  TaskReader reader, {
  Duration debounce = taskSearchDebounce,
  int pageSize = taskPageSize,
  int maxCachedPages = taskMaxCachedPages,
  int prefetchRows = taskPrefetchRows,
}) => TaskController(
  projectId: testProjectId,
  reader: reader,
  debounce: debounce,
  pageSize: pageSize,
  maxCachedPages: maxCachedPages,
  prefetchRows: prefetchRows,
);

/// One task row for a synthetic catalog.
TaskItem taskItem(
  int id, {
  String? title,
  String status = 'todo',
  String priority = 'P2',
  List<String> labels = const <String>[],
  int dependencyCount = 0,
  int waitingDependencyCount = 0,
}) => TaskItem(
  id: id,
  title: title ?? 'Task $id',
  status: status,
  priority: priority,
  version: 1,
  labels: labels,
  dependencyCount: dependencyCount,
  waitingDependencyCount: waitingDependencyCount,
  createdMs: 1700000000000 + id,
  updatedMs: 1700000001000 + id,
);

/// One page for a synthetic catalog of [total] tasks: row `index` holds the
/// task with id `index + 1`, so a jump can be checked by canonical ID.
TaskPage syntheticPage(
  int total, {
  required int offset,
  required int limit,
  String? snapshot = 'token',
  List<TaskItem>? items,
}) {
  final pageItems =
      items ??
      <TaskItem>[
        for (
          var index = offset;
          index < offset + limit && index < total;
          index++
        )
          taskItem(index + 1),
      ];
  final next = offset + pageItems.length;
  return TaskPage(
    protocolVersion: 1,
    items: pageItems,
    totalCount: total,
    offset: offset,
    limit: limit,
    hasMore: next < total,
    nextOffset: next < total ? next : null,
    snapshot: snapshot,
  );
}

/// Records every request and answers from [responder].
///
/// In [manualMode] each call waits for the test to complete the matching
/// entry of [manual], so in-flight behaviour is observable.
class FakeTaskReader implements CancellableTaskReader {
  FakeTaskReader([this.responder]);

  Future<TaskPage> Function(String projectId, TaskQuery query)? responder;
  final List<TaskQuery> requests = <TaskQuery>[];
  final List<String> cancelledScopes = <String>[];
  final List<Completer<TaskPage>> manual = <Completer<TaskPage>>[];
  bool manualMode = false;

  TaskQuery get lastRequest => requests.last;

  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) {
    requests.add(query);
    if (manualMode) {
      final completer = Completer<TaskPage>();
      manual.add(completer);
      return completer.future;
    }
    final handler = responder;
    if (handler == null) {
      throw StateError('no responder and not in manual mode');
    }
    return handler(projectId, query);
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);
}

/// Answers from a fixed catalog, failing the first [staleFailures] reads with
/// `stale_snapshot` and echoing the validated token afterwards.
class StaleFirstReader implements CancellableTaskReader {
  StaleFirstReader(this.total, {this.staleFailures = 0});

  final int total;
  int staleFailures;
  final List<TaskQuery> requests = <TaskQuery>[];
  final List<String> cancelledScopes = <String>[];

  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) async {
    requests.add(query);
    if (staleFailures > 0) {
      staleFailures -= 1;
      throw const ViewerCliErrorFailure(
        code: 'stale_snapshot',
        message: 'the task list changed since this page was requested',
        exitCode: 4,
      );
    }
    return syntheticPage(
      total,
      offset: query.offset,
      limit: query.limit,
      snapshot: query.snapshot ?? 'token',
    );
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);
}

/// A responder that answers any request with a [total]-task catalog.
Future<TaskPage> Function(String, TaskQuery) catalogResponder(int total) =>
    (projectId, query) async =>
        syntheticPage(total, offset: query.offset, limit: query.limit);

void main() {
  test(
    'date sorts show newest first and priority shows highest first',
    () async {
      final controller = buildTaskController(
        FakeTaskReader(catalogResponder(3)),
      );
      addTearDown(controller.dispose);
      controller.setSort(TaskSort.updated);
      expect(controller.direction, SortDirection.descending);
      controller.setSort(TaskSort.created);
      expect(controller.direction, SortDirection.descending);
      controller.setSort(TaskSort.priority);
      expect(controller.direction, SortDirection.ascending);
      await pumpEventQueue();
    },
  );

  group('parameters', () {
    test(
      'the first load uses open scope, priority ascending and one page',
      () async {
        final reader = FakeTaskReader(catalogResponder(3));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);

        await controller.reload();

        expect(reader.requests, hasLength(1));
        final query = reader.requests.single;
        expect(query.query, isEmpty);
        expect(query.scope, TaskScope.open);
        expect(query.statuses, isEmpty);
        expect(query.priorities, isEmpty);
        expect(query.labels, isEmpty);
        expect(query.readiness, TaskReadiness.any);
        expect(query.sort, TaskSort.priority);
        expect(query.direction, SortDirection.ascending);
        expect(query.offset, 0);
        expect(query.limit, taskPageSize);
        expect(query.snapshot, isNull);
        expect(controller.totalCount, 3);
        expect(controller.loadedRowCount, 3);
        expect(controller.itemAt(0)?.canonicalId, 'T-001');
        expect(controller.sampledAtMs, isNotNull);
        expect(controller.isLoading, isFalse);
      },
    );

    test('typing debounces and only the last text is read', () async {
      final reader = FakeTaskReader(catalogResponder(3));
      final controller = buildTaskController(reader, debounce: _fastDebounce);
      addTearDown(controller.dispose);

      controller.setQuery('par');
      controller.setQuery('parser');
      expect(reader.requests, isEmpty, reason: 'no read before the debounce');

      await Future<void>.delayed(_fastDebounce * 3);
      expect(reader.requests, hasLength(1));
      expect(reader.requests.single.query, 'parser');
      expect(controller.query, 'parser');
    });

    test('Enter submits immediately and trims the text', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(
        reader,
        debounce: const Duration(seconds: 10),
      );
      addTearDown(controller.dispose);

      controller.setQuery('  parser  ');
      await controller.submitQuery();

      expect(reader.requests, hasLength(1));
      expect(reader.requests.single.query, 'parser');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        reader.requests,
        hasLength(1),
        reason: 'Enter cancels the pending debounce',
      );
    });

    test('filter groups intersect in one request document', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      controller.toggleStatus('in-progress');
      controller.togglePriority('P1');
      controller.setLabels(<String>['UI', 'urgent', 'ui']);
      controller.setReadiness(TaskReadiness.waiting);
      await pumpEventQueue();
      reader.requests.clear();

      await controller.reload();

      expect(reader.requests, hasLength(1));
      final query = reader.requests.single;
      expect(query.statuses, <String>['in-progress']);
      expect(query.priorities, <String>['P1']);
      expect(query.labels, <String>['ui', 'urgent']);
      expect(query.readiness, TaskReadiness.waiting);
      expect(query.offset, 0);
      expect(query.limit, taskPageSize);
    });

    test('labels are trimmed, lowercased, deduplicated and sorted', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      controller.setLabels(<String>[' UI ', 'urgent', 'ui', '', '   ']);

      expect(controller.labels, <String>['ui', 'urgent']);
    });

    test('the needs-human checkbox is the needs-human label', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      expect(controller.needsHuman, isFalse);
      controller.setNeedsHuman(true);
      expect(controller.needsHuman, isTrue);
      expect(controller.labels, <String>[needsHumanLabel]);

      controller.setLabels(<String>['ui', needsHumanLabel]);
      expect(controller.needsHuman, isTrue);

      controller.setNeedsHuman(false);
      expect(controller.needsHuman, isFalse);
      expect(controller.labels, <String>['ui']);
    });

    test(
      'choosing a terminal status moves the scope to all tasks once',
      () async {
        final reader = FakeTaskReader(catalogResponder(0));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);

        expect(controller.scope, TaskScope.open);
        expect(
          controller.toggleStatus('done'),
          isTrue,
          reason: 'the pane announces the scope change exactly once',
        );
        expect(controller.scope, TaskScope.all);
        expect(controller.statuses, contains('done'));
        await pumpEventQueue();
        reader.requests.clear();

        await controller.reload();

        expect(reader.requests.single.scope, TaskScope.all);
        expect(reader.requests.single.statuses, <String>['done']);
        expect(
          controller.toggleStatus('done'),
          isFalse,
          reason: 'clearing a status never moves the scope back',
        );
        expect(controller.scope, TaskScope.all);
        expect(controller.statuses, isEmpty);
      },
    );

    test('to-verify is an open status filter with a readable label', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      expect(viewerTaskStatuses, contains('to-verify'));
      expect(
        viewerTaskStatuses.indexOf('to-verify'),
        viewerTaskStatuses.indexOf('in-progress') + 1,
      );
      expect(viewerStatusLabel('to-verify'), 'To verify');
      expect(viewerStatusIsTerminal('to-verify'), isFalse);
      expect(
        controller.toggleStatus('to-verify'),
        isFalse,
        reason: 'a nonterminal status keeps the open scope',
      );
      await pumpEventQueue();
      reader.requests.clear();

      await controller.reload();

      expect(reader.requests.single.scope, TaskScope.open);
      expect(reader.requests.single.statuses, <String>['to-verify']);
    });

    test(
      'All status selects every status and clearing it restores open tasks',
      () async {
        final reader = FakeTaskReader(catalogResponder(0));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);

        expect(controller.scope, TaskScope.open);
        expect(controller.statuses, isEmpty);
        controller.setAllStatuses(true);
        await pumpEventQueue();
        expect(controller.scope, TaskScope.all);
        expect(controller.statuses, containsAll(viewerTaskStatuses));
        expect(reader.requests.last.statuses, containsAll(viewerTaskStatuses));

        controller.setAllStatuses(false);
        await pumpEventQueue();
        expect(controller.scope, TaskScope.open);
        expect(controller.statuses, isEmpty);
        expect(reader.requests.last.scope, TaskScope.open);
        expect(reader.requests.last.statuses, isEmpty);
      },
    );

    test(
      'clear filters returns the open default while keeping the sort',
      () async {
        final reader = FakeTaskReader(catalogResponder(0));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);

        controller.setQuery('parser');
        controller.setSort(TaskSort.updated);
        controller.setDirection(SortDirection.descending);
        controller.setNeedsHuman(true);
        controller.setReadiness(TaskReadiness.runnable);
        controller.toggleStatus('done');
        expect(controller.activeFilterCount, greaterThan(0));
        await pumpEventQueue();

        controller.clearFilters();
        await pumpEventQueue();
        reader.requests.clear();

        await controller.reload();

        final query = reader.requests.single;
        expect(query.query, isEmpty);
        expect(query.scope, TaskScope.open);
        expect(query.statuses, isEmpty);
        expect(query.priorities, isEmpty);
        expect(query.labels, isEmpty);
        expect(query.readiness, TaskReadiness.any);
        expect(query.sort, TaskSort.updated);
        expect(query.direction, SortDirection.descending);
        expect(controller.activeFilterCount, 0);
        expect(controller.needsHuman, isFalse);
      },
    );

    test('the collapsed filter count follows the active groups', () async {
      final reader = FakeTaskReader(catalogResponder(0));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      expect(controller.activeFilterCount, 0);
      controller.setQuery('parser');
      expect(controller.activeFilterCount, 1);
      controller.toggleStatus('todo');
      expect(controller.activeFilterCount, 2);
      controller.setScope(TaskScope.all);
      expect(controller.activeFilterCount, 3);
      controller.toggleStatus('todo');
      expect(controller.activeFilterCount, 2);
      controller.clearFilters();
      expect(controller.activeFilterCount, 0);
    });
  });

  group('paging', () {
    test(
      'a jump loads the page that owns the row, not every page before it',
      () async {
        final reader = FakeTaskReader(catalogResponder(1000));
        final controller = buildTaskController(reader, pageSize: 10);
        addTearDown(controller.dispose);

        await controller.reload();
        reader.requests.clear();

        await controller.ensureRow(999);

        expect(
          reader.requests,
          hasLength(1),
          reason: 'one read, not a hundred',
        );
        expect(reader.requests.single.offset, 990);
        expect(controller.itemAt(999)?.canonicalId, 'T-1000');
        expect(
          controller.isRowReady(500),
          isFalse,
          reason: 'intervening rows stay unloaded placeholders',
        );
        expect(
          controller.isRowReady(0),
          isTrue,
          reason: 'page zero is still materialized',
        );
      },
    );

    test(
      'a later page reuses the snapshot token from the first page',
      () async {
        final reader = FakeTaskReader(catalogResponder(500));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);
        await controller.reload();

        await controller.ensureRow(150);

        expect(reader.requests, hasLength(2));
        expect(reader.requests.first.snapshot, isNull);
        expect(reader.requests.last.offset, 100);
        expect(reader.requests.last.snapshot, 'token');
        expect(controller.isRowReady(150), isTrue);
      },
    );

    test('rows near a page boundary prefetch the next page', () async {
      final reader = FakeTaskReader(catalogResponder(1000));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();

      reader.requests.clear();
      await controller.ensureRow(taskPageSize - taskPrefetchRows);
      await pumpEventQueue();

      expect(
        reader.requests.map((query) => query.offset),
        <int>[taskPageSize],
        reason: 'the boundary row prefetches the next page',
      );
      expect(controller.isPageCached(taskPageSize), isTrue);

      reader.requests.clear();
      await controller.ensureRow(taskPageSize ~/ 2);
      await pumpEventQueue();
      expect(
        reader.requests,
        isEmpty,
        reason: 'a mid-page row neither reloads nor prefetches',
      );
    });

    test('an in-flight page is never requested twice', () async {
      final reader = FakeTaskReader()..manualMode = true;
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      final reload = controller.reload();
      expect(reader.requests, hasLength(1));
      reader.manual.first.complete(
        syntheticPage(
          300,
          offset: reader.lastRequest.offset,
          limit: reader.lastRequest.limit,
        ),
      );
      await reload;

      await controller.ensureRow(10);
      expect(
        reader.requests,
        hasLength(1),
        reason: 'page zero is already loaded',
      );

      final second = controller.ensureRow(150);
      final third = controller.ensureRow(150);
      expect(
        reader.requests,
        hasLength(2),
        reason: 'one read serves both requests for the page',
      );
      reader.manual.last.complete(
        syntheticPage(
          300,
          offset: reader.lastRequest.offset,
          limit: reader.lastRequest.limit,
        ),
      );
      await Future.wait(<Future<void>>[second, third]);

      expect(controller.isRowReady(150), isTrue);
    });

    test(
      'the cache keeps at most five pages and never the selected one',
      () async {
        final reader = FakeTaskReader(catalogResponder(100000));
        final controller = buildTaskController(reader);
        addTearDown(controller.dispose);
        await controller.reload();
        controller.selectTaskId(1);

        for (final index in <int>[2000, 4000, 6000, 8000, 10000, 12000]) {
          await controller.ensureRow(index);
        }

        expect(
          controller.cachedPageCount,
          lessThanOrEqualTo(taskMaxCachedPages),
        );
        expect(
          controller.isPageCached(1),
          isTrue,
          reason: 'the selected row is pinned',
        );
        expect(
          controller.isPageCached(12000),
          isTrue,
          reason: 'the newest page stays',
        );
        expect(
          controller.isPageCached(2000),
          isFalse,
          reason: 'the least recently used unselected page is evicted',
        );
        expect(
          controller.cachedPageIndexes,
          containsAll(<int>[0, 120]),
          reason: 'the pinned page and the focused page survive',
        );
        expect(
          controller.cachedPageIndexes.length,
          lessThanOrEqualTo(taskMaxCachedPages),
        );
      },
    );

    test('a row index outside the count is ignored', () async {
      final reader = FakeTaskReader(catalogResponder(5));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();

      await controller.ensureRow(5);
      await controller.ensureRow(-1);

      expect(reader.requests, hasLength(1));
      expect(controller.isLoading, isFalse);
    });
  });

  group('selection', () {
    test('selection carries the task ID, not the row position', () async {
      final reader = FakeTaskReader(catalogResponder(10));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();

      controller.selectIndex(3);
      expect(controller.selectedIndex, 3);
      expect(controller.selectedTaskId, 4);
      expect(controller.selectedItem?.id, 4);

      controller.selectIndex(null);
      expect(controller.selectedTaskId, isNull);
    });

    test('a reload drops a selection that left the result set', () async {
      var total = 10;
      final reader = FakeTaskReader(
        (projectId, query) async =>
            syntheticPage(total, offset: query.offset, limit: query.limit),
      );
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();
      controller.selectIndex(5);

      total = 2;
      await controller.reload();

      expect(controller.selectedTaskId, isNull);
      expect(controller.rowCount, 2);
    });

    test('a reload keeps a selection reached on a later page', () async {
      final reader = FakeTaskReader(catalogResponder(300));
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();

      await controller.ensureRow(250);
      controller.selectIndex(250);
      expect(controller.selectedTaskId, 251);

      await controller.reload();

      expect(
        controller.selectedTaskId,
        251,
        reason: 'only page zero is authoritative; dropping it would be a guess',
      );
      expect(
        controller.selectedIndex,
        isNull,
        reason: 'the row is not materialized again until it is requested',
      );
    });
  });

  group('failures', () {
    test('a first-load failure is an error view, not an empty list', () async {
      final reader = FakeTaskReader(
        (projectId, query) async => throw const ViewerCliErrorFailure(
          code: 'database',
          message: 'database is locked',
          exitCode: 3,
        ),
      );
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);

      await controller.reload();

      expect(
        controller.firstLoadError?.message,
        contains('database is locked'),
      );
      expect(controller.refreshFailure, isNull);
      expect(controller.rowCount, 0);
      expect(controller.hasConfirmedData, isFalse);
      expect(controller.isLoading, isFalse);

      reader.responder = catalogResponder(2);
      await controller.retry();

      expect(controller.firstLoadError, isNull);
      expect(controller.hasRows, isTrue);
    });

    test('a failed page keeps the confirmed rows visible as stale', () async {
      var fail = false;
      final reader = FakeTaskReader((projectId, query) async {
        if (fail) {
          throw const ViewerCliErrorFailure(
            code: 'database',
            message: 'database is locked',
            exitCode: 3,
          );
        }
        return syntheticPage(300, offset: query.offset, limit: query.limit);
      });
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();

      fail = true;
      await controller.ensureRow(150);

      expect(controller.itemAt(0)?.id, 1, reason: 'the confirmed row stays');
      expect(controller.loadedRowCount, 100);
      expect(
        controller.refreshFailure?.message,
        contains('database is locked'),
      );
      expect(controller.firstLoadError, isNull);
      expect(controller.isRowReady(150), isFalse);
      expect(controller.isLoading, isFalse);
    });

    test(
      'a stale snapshot reloads from zero once and then reports a notice',
      () async {
        final once = StaleFirstReader(300, staleFailures: 1);
        final controller = buildTaskController(once);
        addTearDown(controller.dispose);

        await controller.reload();

        expect(
          once.requests.map((query) => query.offset),
          <int>[0, 0],
          reason: 'exactly one automatic retry from offset zero',
        );
        expect(controller.notice, isNull);
        expect(controller.firstLoadError, isNull);
        expect(controller.cachedPageCount, 1);
        expect(controller.hasRows, isTrue);

        final repeat = StaleFirstReader(300, staleFailures: 2);
        final repeated = buildTaskController(repeat);
        addTearDown(repeated.dispose);

        await repeated.reload();

        expect(repeated.notice, contains('Tasks are changing'));
        expect(repeated.notice, contains('Refresh to load the latest list'));
        expect(repeated.isLoading, isFalse);
        expect(
          repeated.firstLoadError,
          isNull,
          reason: 'a changing list is not a hard failure',
        );
        expect(repeated.cachedPageCount, 0);
      },
    );

    test('a repeated invalidation keeps the stale rows on screen', () async {
      var stale = false;
      final reader = FakeTaskReader((projectId, query) async {
        if (stale) {
          throw const ViewerCliErrorFailure(
            code: 'stale_snapshot',
            message: 'the task list changed since this page was requested',
            exitCode: 4,
          );
        }
        return syntheticPage(300, offset: query.offset, limit: query.limit);
      });
      final controller = buildTaskController(reader);
      addTearDown(controller.dispose);
      await controller.reload();
      controller.selectIndex(4);
      expect(controller.selectedTaskId, 5);

      stale = true;
      await controller.refresh();

      expect(controller.notice, contains('Tasks are changing'));
      expect(controller.isLoading, isFalse);
      expect(
        controller.refreshFailure,
        isNull,
        reason: 'a stale snapshot is not a hard failure',
      );
      expect(controller.firstLoadError, isNull);
      expect(
        controller.hasConfirmedData,
        isTrue,
        reason: 'the last confirmed rows stay visible as stale',
      );
      expect(controller.isRowReady(0), isTrue);
      expect(controller.loadedRowCount, 100);
      expect(controller.hasRows, isTrue);
      expect(
        controller.cachedPageCount,
        0,
        reason: 'every cached page is dropped for the retry',
      );
      expect(
        controller.selectedTaskId,
        5,
        reason: 'the detail is preserved by ID',
      );
      expect(controller.sampledAtMs, isNotNull);
    });

    test('a superseded read is cancelled instead of being applied', () async {
      final first = Completer<TaskPage>();
      final reader = FakeTaskReader((projectId, query) {
        if (query.query == 'slow') {
          return first.future;
        }
        return Future<TaskPage>.value(
          syntheticPage(
            1,
            offset: 0,
            limit: 100,
            items: <TaskItem>[taskItem(9)],
          ),
        );
      });
      final controller = buildTaskController(reader, debounce: Duration.zero);
      addTearDown(controller.dispose);

      controller.setQuery('slow');
      await Future<void>.delayed(Duration.zero);
      expect(reader.requests.map((query) => query.query), <String>['slow']);
      expect(controller.isLoading, isTrue);

      controller.setQuery('fast');
      await controller.submitQuery();
      expect(controller.isLoading, isFalse);

      first.complete(syntheticPage(1, offset: 0, limit: 100));
      await pumpEventQueue();

      expect(
        reader.cancelledScopes,
        contains('tasks'),
        reason: 'the superseded scope is abandoned, not awaited',
      );
      expect(controller.totalCount, 1);
      expect(controller.itemAt(0)?.id, 9);
      expect(controller.selectedTaskId, isNull);
      expect(controller.notice, isNull);
    });

    test(
      'dispose cancels the in-flight read and stops notifications',
      () async {
        final reader = FakeTaskReader()..manualMode = true;
        final controller = buildTaskController(reader);
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        unawaited(controller.reload());
        await pumpEventQueue();
        final before = notifications;

        controller.dispose();

        expect(reader.cancelledScopes, contains('tasks'));
        expect(notifications, before);
      },
    );
  });
}
