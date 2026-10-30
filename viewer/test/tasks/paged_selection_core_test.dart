import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/paged_selection.dart';
import 'package:tasks_viewer/data/models.dart';
import '../support/model_store.dart';

class Fixture {
  Fixture({int count = 205})
    : store = ModelStore(count: count, delay: Duration.zero) {
    core = PagedSelectionCore<TaskItem, int>(
      keyOf: (t) => t.id,
      cancelRead: () => store.cancelScope('tasks'),
      listLabel: 'Tasks',
      describe: (id, _) => 'Selected task T-$id',
      prefetchRows: 0,
    );
  }
  final ModelStore store;
  late final PagedSelectionCore<TaskItem, int> core;
  PagedSelectionSpec<TaskItem, int> spec({
    String query = '',
    TaskSort sort = TaskSort.id,
    SortDirection direction = SortDirection.ascending,
    List<String> priorities = const [],
  }) {
    Future<SelectionPage<TaskItem>> read(
      int offset,
      String? token,
      String search,
    ) async {
      final p = await store.fetchTasks(
        store.projects.first.projectId,
        TaskQuery(
          query: search,
          sort: sort,
          direction: direction,
          priorities: priorities,
          offset: offset,
          snapshot: token,
        ),
      );
      return SelectionPage(
        items: p.items,
        total: p.totalCount,
        snapshot: p.snapshot,
        sampledAtMs: 49,
      );
    }

    return PagedSelectionSpec(
      filterKey: '$query/$priorities',
      sortKey: sort,
      direction: direction,
      emptySearch: query.isEmpty,
      read: (o, t) => read(o, t, query),
      membership: (id) => read(0, null, 'T-$id'),
    );
  }

  Future<void> start({int index = 150}) async {
    await core.reload(spec());
    await core.ensureRow(index);
    core.select(index + 1);
    store.reads.clear();
  }

  void close() {
    core.dispose();
    store.close();
  }
}

const locked = ViewerCliErrorFailure(
  code: 'locked',
  message: 'locked',
  exitCode: 4,
);
void main() {
  test('refresh and reverse use one anchor read', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    expect(f.core.kindFor(f.spec()), ReloadKind.refresh);
    await f.core.reload(f.spec());
    expect(f.store.reads.map((r) => r.offset), [100]);
    expect(f.core.selectedIndex, 150);
    f.store.reads.clear();
    await f.core.reload(f.spec(direction: SortDirection.descending));
    expect(f.store.reads.map((r) => r.offset), [0]);
    expect(f.core.selectedIndex, 54);
  });
  test(
    'refilter search unknown costs one; membership absence costs two',
    () async {
      final f = Fixture(count: 1000);
      addTearDown(f.close);
      await f.start(index: 0);
      await f.core.reload(f.spec(query: 'needle'));
      expect(f.store.reads.length, 1);
      expect(f.core.selectedId, 1);
      expect(f.core.selectedIndex, isNull);
      f.store.reads.clear();
      await f.core.reload(f.spec(priorities: ['P0']));
      expect(f.store.reads.length, 2);
      expect(f.store.reads.last.membership, isTrue);
      expect(f.core.selectedId, isNull);
    },
  );
  test(
    'C1 failed lookup preserves publication and frozen paging spec',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start(index: 1);
      final token = f.core.snapshotToken;
      f.store.failure = (r) => r.token != null ? locked : null;
      await f.core.reload(
        f.spec(sort: TaskSort.title, direction: SortDirection.descending),
      );
      expect(f.core.refreshFailure, isNotNull);
      expect(f.core.snapshotToken, token);
      expect(f.core.itemAt(1)?.id, 2);
      f.store.failure = null;
      await f.core.ensureRow(204);
      expect(f.core.itemAt(204)?.id, 205);
      expect(f.core.refreshFailure, isNotNull);
      await f.core.reload(
        f.spec(sort: TaskSort.title, direction: SortDirection.descending),
      );
      expect(f.core.selectedIndex, isNotNull);
    },
  );
  test('C2 saved absence retained until selected or located again', () async {
    final f = Fixture(count: 99);
    addTearDown(f.close);
    await f.start(index: 5);
    final p = f.store.projects.first.projectId;
    f.store.mutate(p, 6, status: 'done');
    await f.core.reload(f.spec(), savedId: 6);
    expect(f.core.selection, isA<Retained<int>>());
    expect((f.core.selection as Retained<int>).reason, RetainReason.saved);
    expect(f.core.selectedItem?.id, 6);
    await f.core.reload(f.spec(query: 'needle'));
    expect(f.core.selectedId, 6);
    await f.core.reload(f.spec());
    expect(f.core.selectedId, 6);
    f.store.mutate(p, 6, status: 'todo');
    await f.core.reload(f.spec());
    expect(f.core.selection, isA<Listed<int>>());
  });
  test(
    'focused save uses next or previous; pinned selection takes precedence',
    () async {
      for (final index in [5, 98]) {
        final f = Fixture(count: 99);
        await f.start(index: index);
        f.core.listFocus = () =>
            ListFocus(ownsFocus: true, index: index, key: index + 1);
        f.store.mutate(
          f.store.projects.first.projectId,
          index + 1,
          status: 'done',
        );
        await f.core.reload(f.spec(), savedId: index + 1);
        expect(f.core.selectedId, index == 98 ? 98 : 7);
        f.close();
      }
      final f = Fixture(count: 99);
      addTearDown(f.close);
      await f.start(index: 5);
      f.core.listFocus = () =>
          const ListFocus(ownsFocus: true, index: 5, key: 6);
      f.core.isSelectionPinned = (_) => true;
      f.store.mutate(f.store.projects.first.projectId, 6, status: 'done');
      await f.core.reload(f.spec());
      expect(f.core.selectedId, 6);
      expect(f.core.selection, isA<Retained<int>>());
    },
  );
  test('U2 paging failures settle and retry; no overlap', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 999);
    f.store.failure = (_) => locked;
    await f.core.reload(f.spec());
    for (var i = 0; i < 12; i++) {
      expect((await f.core.ensureRow(799)).state, RowLoadState.failed);
    }
    expect(f.core.selectedId, 1000);
    expect(f.core.itemAt(999)?.id, 1000);
    f.store.failure = null;
    expect((await f.core.ensureRow(799)).state, RowLoadState.ready);
    expect(f.core.refreshFailure, isNotNull);
    await f.core.reload(f.spec());
    expect(f.core.refreshFailure, isNull);
    expect(f.store.overlaps, 0);
  });
  test('budget bounded and restore hint uses one read', () async {
    final f = Fixture(count: 5000);
    addTearDown(f.close);
    await f.start(index: 4999);
    await f.core.reload(f.spec(sort: TaskSort.priority));
    expect(f.store.reads.length, lessThanOrEqualTo(10));
    expect(f.core.selectedId, 5000);
    final g = Fixture();
    addTearDown(g.close);
    g.core.select(151);
    await g.core.reload(g.spec(), restoreHint: 150);
    expect(g.store.reads.map((r) => r.offset), [100]);
    expect(g.core.selectedIndex, 150);
  });
  test('queued paging discarded on commit, runs on failure', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 0);
    final reload = f.core.reload(f.spec(direction: SortDirection.descending));
    final page = f.core.ensureRow(450);
    await reload;
    expect((await page).state, RowLoadState.superseded);
    f.store.failure = (r) => r.token == null ? locked : null;
    final failed = f.core.reload(f.spec());
    final next = f.core.ensureRow(450);
    await failed;
    expect((await next).state, RowLoadState.ready);
    expect(f.store.overlaps, 0);
  });
  test(
    'attachment zero reads idle; exactly one owed refresh during job',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      final epoch = f.core.resultEpoch, token = f.core.snapshotToken;
      f.core.patch((r) => r);
      expect(f.store.reads, isEmpty);
      expect(f.core.resultEpoch, epoch);
      expect(f.core.snapshotToken, token);
      final job = f.core.reload(f.spec());
      f.core.patch((r) => r);
      await job;
      while (f.core.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(f.store.reads.length, 2);
      expect(f.store.overlaps, 0);
    },
  );
  test('stale restarts once then notices without publication', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start(index: 1);
    final token = f.core.snapshotToken;
    f.store.failure = (r) => r.token != null
        ? const ViewerCliErrorFailure(
            code: 'stale_snapshot',
            message: 'changed',
            exitCode: 4,
          )
        : null;
    await f.core.reload(
      f.spec(sort: TaskSort.title, direction: SortDirection.descending),
    );
    expect(f.core.notice, contains('Tasks are changing'));
    expect(f.core.snapshotToken, token);
    expect(f.store.reads.where((r) => r.token == null).length, 2);
  });
  test('lane loads target and neighbour without overlap', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 0);
    final a = f.core.ensureRow(450);
    final b = f.core.ensureRow(550);
    expect((await a).state, RowLoadState.ready);
    expect((await b).state, RowLoadState.ready);
    expect(f.store.reads.map((r) => r.offset), [400, 500]);
    expect(f.store.overlaps, 0);
  });
  test('attachment during paging cancels and requeues wanted page', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 0);
    final epoch = f.core.resultEpoch, token = f.core.snapshotToken;
    final page = f.core.ensureRow(450);
    f.core.patch((r) => r);
    expect((await page).state, RowLoadState.ready);
    expect(f.core.itemAt(450)?.id, 451);
    expect(f.store.reads.map((r) => r.outcome), ['cancelled', 'ok']);
    expect(f.core.resultEpoch, epoch);
    expect(f.core.snapshotToken, token);
    expect(f.store.overlaps, 0);
  });
  test('paging stale after failed sort recovers requested order', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 1);
    final requested = f.spec(
      sort: TaskSort.title,
      direction: SortDirection.descending,
    );
    f.store.failure = (_) => locked;
    await f.core.reload(requested);
    expect(f.core.refreshFailure, isNotNull);
    f.store.failure = null;
    f.store.mutate(f.store.projects.first.projectId, 800, title: 'external');
    expect((await f.core.ensureRow(450)).state, RowLoadState.failed);
    while (f.core.isLoading) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(f.core.published!.spec.sortKey, TaskSort.title);
    expect(f.core.published!.spec.direction, SortDirection.descending);
    expect(f.core.refreshFailure, isNull);
    expect(f.store.overlaps, 0);
  });

  test(
    'actual external mutations between reads restart once then notice',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start(index: 1);
      final token = f.core.snapshotToken;
      f.store.afterRead = (r) {
        if (r.token == null) {
          f.store.mutate(
            f.store.projects.first.projectId,
            100,
            title: 'write ${f.store.version}',
          );
        }
      };
      await f.core.reload(
        f.spec(sort: TaskSort.title, direction: SortDirection.descending),
      );
      expect(f.store.reads.map((r) => r.outcome), [
        'ok',
        'stale_snapshot',
        'ok',
        'stale_snapshot',
      ]);
      expect(f.core.snapshotToken, token);
      expect(f.core.notice, contains('Tasks are changing'));
      expect(f.store.overlaps, 0);
    },
  );
  test(
    'reorder anchor outside a shrunken result still locates identity',
    () async {
      final f = Fixture(count: 1000);
      addTearDown(f.close);
      await f.start(index: 0);
      final records = f.store.records[f.store.projects.first.projectId]!;
      records.removeWhere((id, _) => id != 1 && id != 1000);
      f.store.version++;
      await f.core.reload(f.spec(direction: SortDirection.descending));
      expect(f.core.selectedId, 1);
      expect(f.core.selectedIndex, 1);
      expect(f.store.reads.map((r) => r.offset), [900, 0]);
    },
  );

  test('C4 owed follow-up keeps the saved origin of a failed job', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    f.store.mutate(f.store.projects.first.projectId, 151, status: 'done');
    var failures = 1;
    f.store.failure = (_) {
      if (failures == 0) return null;
      failures--;
      return locked;
    };
    final job = f.core.reload(f.spec(), savedId: 151);
    f.core.patch((r) => r);
    await job;
    await pumpEventQueue();
    final selection = f.core.selection;
    expect(selection, isA<Retained<int>>());
    expect((selection as Retained<int>).reason, RetainReason.saved);
  });
  group('C6 saved origin across a failed post-save read', () {
    Future<Fixture> failedSave() async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      f.store.mutate(f.store.projects.first.projectId, 151, status: 'done');
      f.store.failure = (_) => locked;
      await f.core.reload(f.spec(), savedId: 151);
      expect(f.core.refreshFailure, isNotNull);
      expect(f.core.selection, isA<Listed<int>>());
      f.store.failure = null;
      return f;
    }

    void expectSaved(Fixture f) {
      final selection = f.core.selection;
      expect(selection, isA<Retained<int>>());
      expect((selection as Retained<int>).reason, RetainReason.saved);
      expect(selection.id, 151);
      expect(f.core.retainedText, 'Saved task no longer matches these filters');
    }

    test('F5 keeps it, and a later reverse keeps the detail', () async {
      final f = await failedSave();
      await f.core.reload(f.spec());
      expectSaved(f);
      await f.core.reload(f.spec(direction: SortDirection.descending));
      expectSaved(f);
    });
    test('a reverse without F5 keeps it', () async {
      final f = await failedSave();
      await f.core.reload(f.spec(direction: SortDirection.descending));
      expectSaved(f);
    });
    test('a filter that proves absence keeps it', () async {
      final f = await failedSave();
      await f.core.reload(f.spec(priorities: const ['P9']));
      expectSaved(f);
    });
    test('a second failure keeps it for the next recovery', () async {
      final f = await failedSave();
      f.store.failure = (_) => locked;
      await f.core.reload(f.spec());
      f.store.failure = null;
      await f.core.reload(f.spec());
      expectSaved(f);
    });
    test('selecting another row ends it', () async {
      final f = await failedSave();
      f.core.select(150);
      f.core.select(151);
      await f.core.reload(f.spec());
      expect((f.core.selection as Retained<int>).reason, RetainReason.other);
    });
    test('finding the task again ends it', () async {
      final f = await failedSave();
      final project = f.store.projects.first.projectId;
      f.store.mutate(project, 151, status: 'todo');
      await f.core.reload(f.spec());
      expect(f.core.selection, isA<Listed<int>>());
      f.store.mutate(project, 151, status: 'done');
      await f.core.reload(f.spec());
      expect((f.core.selection as Retained<int>).reason, RetainReason.other);
    });
  });
  test('C5 paging materializes a retained selection as listed', () async {
    final f = Fixture(count: 1000);
    addTearDown(f.close);
    await f.start(index: 949);
    final project = f.store.projects.first.projectId;
    f.store.mutate(project, 950, status: 'done');
    await f.core.reload(f.spec(), savedId: 950);
    expect(f.core.selection, isA<Retained<int>>());
    f.store.mutate(project, 950, status: 'todo');
    await f.core.reload(f.spec(query: 'Task'));
    expect(f.core.selection, isA<Retained<int>>());
    expect(f.core.selectedIndex, isNull);
    final index = f.store
        .orderedTasks(
          project,
          const TaskQuery(query: 'Task', sort: TaskSort.id),
        )
        .indexWhere((t) => t.id == 950);
    expect(index, greaterThanOrEqualTo(100));
    await f.core.ensureRow(index);
    expect(f.core.selectedIndex, index);
    expect(f.core.selection, isA<Listed<int>>());
    expect(f.core.retainedText, isNull);
    expect(f.core.unplacedLabel, isNull);
    await f.core.reload(f.spec(query: 'not-present-anywhere'));
    expect(f.core.selection, isA<NoSelection<int>>());
    expect(f.core.retainedText, isNull);
  });
}
