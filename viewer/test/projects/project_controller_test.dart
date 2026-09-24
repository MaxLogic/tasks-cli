/// Project catalog semantics: query, paging, cache bounds and failure states
/// (viewer/spec.md sections 4.2 and 5, test matrix V02/V07).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/project_controller.dart';
import 'package:tasks_viewer/data/models.dart';

const Duration _fastDebounce = Duration(milliseconds: 20);

ProjectItem projectItem(int index) => ProjectItem(
  projectId: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  name: 'Project $index',
  roots: <String>['C:\\work\\project-$index'],
  availability: ProjectAvailability.available,
  error: null,
  sampledAtMs: 1700000000000 + index,
  stats: ProjectStats(
    total: index,
    open: index ~/ 2,
    blocked: 0,
    done: 0,
    cancelled: 0,
    startedMs: null,
    lastWriteMs: null,
    progressPercent: null,
  ),
);

ProjectItem unavailableItem(int index, {String code = 'locked'}) => ProjectItem(
  projectId: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  name: 'Project $index',
  roots: <String>['C:\\work\\project-$index'],
  availability: ProjectAvailability.error,
  error: ProjectErrorInfo(code: code, message: 'database is locked'),
  sampledAtMs: 1700000000000 + index,
  stats: null,
);

/// A syntactically valid page for any request.
ProjectPage syntheticPage(
  ProjectQuery query, {
  required int total,
  String snapshot = 'p1.cafebabe',
  int? itemCount,
  bool unavailable = false,
}) {
  final count = math.min(query.limit, math.max(0, total - query.offset));
  final items = <ProjectItem>[
    for (var index = 0; index < count; index++)
      unavailable
          ? unavailableItem(query.offset + index)
          : projectItem(query.offset + index),
  ];
  final resolved = itemCount == null
      ? items
      : items.take(itemCount).toList(growable: false);
  final nextOffset = query.offset + resolved.length;
  return ProjectPage(
    protocolVersion: 1,
    items: resolved,
    totalCount: total,
    offset: query.offset,
    limit: query.limit,
    hasMore: nextOffset < total,
    nextOffset: nextOffset < total ? nextOffset : null,
    snapshot: snapshot,
  );
}

/// Records every request and answers from a scripted responder.
class RecordingReader implements CancellableProjectReader {
  RecordingReader({this.responder});

  Future<ProjectPage> Function(ProjectQuery query)? responder;
  final List<ProjectQuery> requests = <ProjectQuery>[];
  final List<String> cancelledScopes = <String>[];
  final List<Completer<ProjectPage>> manual = <Completer<ProjectPage>>[];

  /// When true, each call waits for the test to complete a completer.
  bool manualMode = false;

  int get callCount => requests.length;

  ProjectQuery get lastRequest => requests.last;

  @override
  Future<ProjectPage> fetchProjects(ProjectQuery query) {
    requests.add(query);
    if (manualMode) {
      final completer = Completer<ProjectPage>();
      manual.add(completer);
      return completer.future;
    }
    final handler = responder;
    if (handler == null) {
      throw StateError('no responder and not in manual mode');
    }
    return handler(query);
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);
}

/// A reader that answers from a fixed catalog, failing the first [staleFailures]
/// reads with `stale_snapshot`.
class CataloGReader implements CancellableProjectReader {
  CataloGReader(this.total, {this.staleFailures = 0});

  final int total;
  int staleFailures;
  final List<ProjectQuery> requests = <ProjectQuery>[];
  final List<String> cancelledScopes = <String>[];

  @override
  Future<ProjectPage> fetchProjects(ProjectQuery query) async {
    requests.add(query);
    if (staleFailures > 0) {
      staleFailures -= 1;
      throw const ViewerCliErrorFailure(
        code: 'stale_snapshot',
        message: 'the page is no longer valid',
        exitCode: 4,
      );
    }
    return syntheticPage(query, total: total);
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);
}

void main() {
  test('project list starts with open tasks and newest task write first', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 5),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();
    expect(reader.lastRequest.state, ProjectStateFilter.hasOpen);
    expect(reader.lastRequest.sort, ProjectSort.lastWrite);
    expect(reader.lastRequest.direction, SortDirection.descending);
  });

  test(
    'changing project sort selects useful direction and reversal persists',
    () async {
      final controller = ProjectController(
        reader: RecordingReader(
          responder: (query) async => syntheticPage(query, total: 5),
        ),
      );
      addTearDown(controller.dispose);
      controller.setSort(ProjectSort.lastWrite);
      expect(controller.direction, SortDirection.descending);
      controller.setDirection(SortDirection.ascending);
      controller.setSort(ProjectSort.lastWrite);
      expect(controller.direction, SortDirection.ascending);
      controller.setSort(ProjectSort.open);
      expect(controller.direction, SortDirection.descending);
      controller.setSort(ProjectSort.name);
      expect(controller.direction, SortDirection.ascending);
      await pumpEventQueue();
    },
  );

  test(
    'the first load publishes rows, an exact count and the sample time',
    () async {
      final reader = RecordingReader(
        responder: (query) async => syntheticPage(query, total: 250),
      );
      final controller = ProjectController(reader: reader);
      addTearDown(controller.dispose);

      await controller.reload();

      expect(controller.totalCount, 250);
      expect(
        controller.rowCount,
        250,
        reason: 'the CLI count is the row bound',
      );
      expect(controller.loadedRowCount, 100);
      expect(controller.isRowReady(99), isTrue);
      expect(controller.isRowReady(100), isFalse);
      expect(controller.hasRows, isTrue);
      expect(controller.isLoading, isFalse);
      expect(reader.lastRequest.limit, projectPageSize);
      expect(reader.lastRequest.offset, 0);
      expect(reader.lastRequest.snapshot, isNull);
    },
  );

  test('typing debounces and only the last text is read', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 3),
    );
    final controller = ProjectController(
      reader: reader,
      debounce: _fastDebounce,
    );
    addTearDown(controller.dispose);

    controller.setQuery('al');
    controller.setQuery('alp');
    controller.setQuery('alpha');
    expect(reader.callCount, 0, reason: 'no read before the debounce');

    await Future<void>.delayed(_fastDebounce * 3);
    expect(reader.callCount, 1);
    expect(reader.lastRequest.query, 'alpha');
    expect(controller.query, 'alpha');
  });

  test('Enter submits immediately without waiting for the debounce', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 3),
    );
    final controller = ProjectController(
      reader: reader,
      debounce: const Duration(seconds: 10),
    );
    addTearDown(controller.dispose);

    controller.setQuery('beta');
    await controller.submitQuery();
    expect(reader.callCount, 1);
    expect(reader.lastRequest.query, 'beta');
    // The pending debounce must not fire a second read later.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(reader.callCount, 1);
  });

  test('state, sort and direction reload with the new parameters', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 5),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);

    await controller.reload();
    controller.setState(ProjectStateFilter.hasBlocked);
    controller.setSort(ProjectSort.progress);
    controller.setDirection(SortDirection.descending);
    await pumpEventQueue();

    expect(reader.lastRequest.state, ProjectStateFilter.hasBlocked);
    expect(reader.lastRequest.sort, ProjectSort.progress);
    expect(reader.lastRequest.direction, SortDirection.descending);
    expect(reader.lastRequest.offset, 0);
  });

  test(
    'clear filters resets text and state but keeps the chosen sort',
    () async {
      final reader = RecordingReader(
        responder: (query) async => syntheticPage(query, total: 5),
      );
      final controller = ProjectController(
        reader: reader,
        debounce: _fastDebounce,
      );
      addTearDown(controller.dispose);

      controller.setSort(ProjectSort.lastWrite);
      controller.setState(ProjectStateFilter.empty);
      controller.setQuery('x');
      await Future<void>.delayed(_fastDebounce * 3);
      controller.clearFilters();
      await pumpEventQueue();

      expect(controller.query, isEmpty);
      expect(controller.stateFilter, ProjectStateFilter.all);
      expect(reader.lastRequest.query, isEmpty);
      expect(reader.lastRequest.state, ProjectStateFilter.all);
      expect(reader.lastRequest.sort, ProjectSort.lastWrite);
    },
  );

  test('selecting carries the project UUID, not the row position', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 10),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();

    controller.selectIndex(3);
    expect(controller.selectedIndex, 3);
    expect(controller.selectedItem?.projectId, projectItem(3).projectId);
    expect(controller.indexOfProject(projectItem(3).projectId), 3);
    controller.selectIndex(null);
    expect(controller.selectedProjectId, isNull);
  });

  test('a later page reuses the snapshot token from the first page', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 500),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();

    await controller.ensureRow(150);
    expect(reader.lastRequest.offset, 100);
    expect(reader.lastRequest.snapshot, 'p1.cafebabe');
    expect(controller.isRowReady(150), isTrue);
  });

  test('a direct jump to the last row fetches only that page', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 100000),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();

    await controller.ensureRow(99999);
    expect(reader.callCount, 2, reason: 'offset 0 and the final page only');
    expect(reader.lastRequest.offset, 99900);
    expect(controller.isRowReady(99999), isTrue);
    expect(controller.isRowReady(500), isFalse);
  });

  test('rows near a page boundary prefetch the next page', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 500),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();

    await controller.ensureRow(projectPageSize - projectPrefetchRows);
    await pumpEventQueue();
    expect(
      reader.requests.map((request) => request.offset),
      contains(projectPageSize),
    );
  });

  test('an in-flight page is never requested twice', () async {
    final reader = RecordingReader()..manualMode = true;
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);

    final reload = controller.reload();
    expect(reader.callCount, 1);
    reader.manual.first.complete(syntheticPage(reader.lastRequest, total: 300));
    await reload;

    final first = controller.ensureRow(10);
    expect(reader.callCount, 1, reason: 'page zero is already loaded');
    await first;

    final second = controller.ensureRow(150);
    final third = controller.ensureRow(150);
    expect(reader.callCount, 2, reason: 'one read for the shared page');
    reader.manual.last.complete(syntheticPage(reader.lastRequest, total: 300));
    await Future.wait(<Future<void>>[second, third]);
    expect(controller.isRowReady(150), isTrue);
  });

  test(
    'the cache keeps at most five pages and never the selected one',
    () async {
      final reader = RecordingReader(
        responder: (query) async => syntheticPage(query, total: 100000),
      );
      final controller = ProjectController(reader: reader);
      addTearDown(controller.dispose);
      await controller.reload();

      controller.selectIndex(1);
      for (final index in <int>[200, 400, 600, 800, 1000, 1200]) {
        await controller.ensureRow(index);
      }

      expect(
        controller.cachedPageCount,
        lessThanOrEqualTo(projectMaxCachedPages),
      );
      expect(controller.isPageCached(1), isTrue, reason: 'selection is pinned');
      expect(
        controller.isPageCached(1200),
        isTrue,
        reason: 'the newest page stays',
      );
      expect(
        controller.isPageCached(200),
        isFalse,
        reason: 'the least recently used unselected page is evicted',
      );
      expect(
        controller.cachedPageIndexes.length,
        lessThanOrEqualTo(projectMaxCachedPages),
      );
      expect(
        controller.cachedPageIndexes,
        containsAll(<int>[0, 12]),
        reason: 'the pinned page and the focused page survive',
      );
    },
  );

  test('a first load failure is an error view, not an empty catalog', () async {
    final reader = RecordingReader(
      responder: (query) async => throw const ViewerCliErrorFailure(
        code: 'registry',
        message: 'the registry is unreadable',
        exitCode: 3,
      ),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);

    await controller.reload();
    expect(controller.firstLoadError, isNotNull);
    expect(controller.firstLoadError!.message, 'the registry is unreadable');
    expect(controller.refreshFailure, isNull);
    expect(controller.hasRows, isFalse);
    expect(controller.isLoading, isFalse);

    reader.responder = (query) async => syntheticPage(query, total: 2);
    await controller.retry();
    expect(controller.firstLoadError, isNull);
    expect(controller.hasRows, isTrue);
  });

  test(
    'a failed refresh keeps the confirmed rows and labels them stale',
    () async {
      var fail = false;
      final reader = RecordingReader(
        responder: (query) async {
          if (fail) {
            throw const ViewerCliErrorFailure(
              code: 'unavailable',
              message: 'the store is offline',
              exitCode: 5,
            );
          }
          return syntheticPage(query, total: 40);
        },
      );
      final controller = ProjectController(reader: reader);
      addTearDown(controller.dispose);
      await controller.reload();
      controller.selectIndex(2);

      fail = true;
      await controller.refresh();
      expect(controller.refreshFailure, isNotNull);
      expect(controller.firstLoadError, isNull);
      expect(
        controller.loadedRowCount,
        40,
        reason: 'last confirmed rows remain',
      );
      expect(
        controller.selectedIndex,
        2,
        reason: 'refresh keeps the selection',
      );

      fail = false;
      await controller.refresh();
      expect(controller.refreshFailure, isNull);
      expect(controller.selectedIndex, 2);
    },
  );

  test(
    'a stale snapshot reloads once and then reports a calm notice',
    () async {
      final reader = CataloGReader(120, staleFailures: 1);
      final controller = ProjectController(reader: reader);
      addTearDown(controller.dispose);

      await controller.reload();
      expect(controller.notice, isNull);
      expect(controller.hasRows, isTrue);
      expect(
        reader.requests.map((request) => request.offset),
        <int>[0, 0],
        reason: 'exactly one automatic retry from offset zero',
      );

      final repeat = CataloGReader(120, staleFailures: 2);
      final repeated = ProjectController(reader: repeat);
      addTearDown(repeated.dispose);
      await repeated.reload();
      expect(repeated.notice, contains('Refresh to load the latest list'));
      expect(repeated.isLoading, isFalse);
    },
  );

  test('a reload drops the previous selection when it is gone', () async {
    var total = 10;
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: total),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();
    controller.selectIndex(5);

    total = 2;
    await controller.reload();
    expect(controller.selectedProjectId, isNull);
    expect(controller.rowCount, 2);
  });

  test('a manual refresh keeps a selection that is still present', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 10),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();
    controller.selectIndex(7);

    await controller.refresh();
    expect(controller.selectedIndex, 7);
  });

  test(
    'an unavailable project is a row with an error detail, not a gap',
    () async {
      final reader = RecordingReader(
        responder: (query) async =>
            syntheticPage(query, total: 3, unavailable: true),
      );
      final controller = ProjectController(reader: reader);
      addTearDown(controller.dispose);
      await controller.reload();

      final row = controller.itemAt(1);
      expect(row, isNotNull);
      expect(row!.isAvailable, isFalse);
      expect(row.error?.code, 'locked');
      expect(row.stats, isNull);
    },
  );

  test('a requested row outside the count is ignored', () async {
    final reader = RecordingReader(
      responder: (query) async => syntheticPage(query, total: 5),
    );
    final controller = ProjectController(reader: reader);
    addTearDown(controller.dispose);
    await controller.reload();

    await controller.ensureRow(5);
    await controller.ensureRow(-1);
    expect(reader.callCount, 1);
  });

  test('dispose cancels the in-flight read and stops notifications', () async {
    final reader = RecordingReader()..manualMode = true;
    final controller = ProjectController(reader: reader);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    unawaited(controller.reload());
    await pumpEventQueue();
    final before = notifications;
    controller.dispose();
    expect(reader.cancelledScopes, contains('projects'));
    expect(identical(notifications, before), isTrue);
  });
}
