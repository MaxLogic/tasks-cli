import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/paged_selection.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';
import 'package:tasks_viewer/ui/viewer_controls.dart';
import '../support/model_store.dart';
import '../support/model_viewer_driver.dart';
import '../support/paged_selection_oracle.dart';
import '../support/viewer_test_support.dart';

enum Op {
  sort,
  reverse,
  f5,
  windowReturn,
  save,
  listStatus,
  filter,
  navigation,
  focusEntry,
  attachment,
  externalMutation,
  failure,
  projectSwitch,
  interleave,
  pendingNavigation,
  retainedTransition,
  attachmentReload,
  dirtyRefusal,
  savedRecovery,
  tabKeys,
}

/// Operations that need a second page to mean anything.
const pagedOps = {Op.pendingNavigation};

/// Multi-step sequences that keep their state between steps.
const compoundOps = {
  Op.pendingNavigation,
  Op.retainedTransition,
  Op.attachmentReload,
  Op.dirtyRefusal,
  Op.savedRecovery,
  Op.tabKeys,
};

/// The routine runs share the suite's time budget. Each of these runs under one
/// list there; fixed regressions cover the other, and the batch gate runs both.
const routineTasksOnly = {
  Op.save,
  Op.listStatus,
  Op.attachment,
  Op.attachmentReload,
  Op.pendingNavigation,
  Op.savedRecovery,
};
const routineProjectsOnly = {Op.dirtyRefusal};

const allSizes = [1, 99, 100, 101, 205, 999, 1000];
const routineSizes = [205];
const seeds = [0x49a, 0x205];

/// The routine suite runs one list size. The batch gate runs every size with
/// `PAGED_SELECTION_FULL=1` in the environment or as a `--dart-define`.
final fullMatrix =
    const bool.fromEnvironment('PAGED_SELECTION_FULL') ||
    Platform.environment['PAGED_SELECTION_FULL'] == '1';
final sizes = fullMatrix ? allSizes : routineSizes;
final requestedCount = max(
  28,
  max(
    int.fromEnvironment('PAGED_SELECTION_OPERATIONS', defaultValue: 28),
    int.tryParse(Platform.environment['PAGED_SELECTION_OPERATIONS'] ?? '') ??
        28,
  ),
);

class Before {
  Before(
    this.id,
    this.index,
    this.focused,
    this.filter,
    this.order,
    this.sort,
    this.total,
    this.state,
  );
  final Object? id;
  final int? index;
  final bool focused;
  final String filter, order;
  final Object? sort;
  final int total;
  final SelectionState state;
}

SelectionState stateOf(dynamic c) => switch (c.selection as Object) {
  NoSelection() => SelectionState.none,
  Retained(reason: RetainReason.saved) => SelectionState.saved,
  Retained() => SelectionState.other,
  _ => SelectionState.listed,
};

Map<String, Object?> filter(Map<String, Object?> q) => Map.of(q)
  ..remove('offset')
  ..remove('limit')
  ..remove('snapshot')
  ..remove('sort')
  ..remove('direction');
Before before(ModelViewerDriver d, bool projects) {
  final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
  final id = projects
      ? d.h.model.selectedProjectId
      : d.h.model.tasks!.selectedTaskId;
  final q = (c.buildQuery(offset: 0).toJson() as Map<String, Object?>);
  final token = c.snapshotToken as String?;
  final old = token == null
      ? q
      : Map<String, Object?>.from((jsonDecode(token) as List)[3] as Map);
  final list = d.h.list(projects ? ViewerRegion.projects : ViewerRegion.tasks);
  return Before(
    id,
    c.selectedIndex as int?,
    list.focusedRowIndex != null && list.focusedRowIndex == c.selectedIndex,
    jsonEncode(filter(old)),
    jsonEncode([old['sort'], old['direction']]),
    old['sort'],
    c.totalCount as int,
    stateOf(c),
  );
}

List<Object> ordered(ModelViewerDriver d, bool projects) => projects
    ? d.store
          .orderedProjects(d.h.model.projectList.buildQuery(offset: 0))
          .map<Object>((p) => p.projectId)
          .toList()
    : d.store
          .orderedTasks(
            d.h.model.tasks!.projectId,
            d.h.model.tasks!.buildQuery(offset: 0),
          )
          .map<Object>((t) => t.id)
          .toList();

/// The status bar keeps the last announcement, so scope to the list's own line.
Finder statusLineText(String text) => find.descendant(
  of: find.byType(ViewerStatusLine),
  matching: find.text(text),
);

/// The selection, highlight and visible text must equal the store oracle.
void expectSelection(
  ModelViewerDriver d,
  bool projects,
  ExpectedSelection expected,
) {
  final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
  final actual = projects
      ? d.h.model.selectedProjectId
      : d.h.model.tasks!.selectedTaskId;
  final context = 'store oracle ${d.store.step}: $expected';
  expect(actual, expected.id, reason: context);
  expect(stateOf(c), expected.state, reason: context);
  expect(c.selectedIndex, expected.index, reason: context);
  final retained =
      expected.state == SelectionState.saved ||
      expected.state == SelectionState.other;
  expect(c.retainedText != null, retained, reason: context);
  final String? text = c.unplacedLabel as String?;
  expect(
    text != null,
    expected.id != null && expected.index == null,
    reason: context,
  );
  if (text != null &&
      c.refreshFailure == null &&
      c.pageFailure == null &&
      c.notice == null) {
    expect(statusLineText(text), findsWidgets, reason: context);
  }
}

/// Oracle uses store ordering and the accepted commit table, never itemAt.
PlannedJob expectJob(
  ModelViewerDriver d,
  bool projects,
  Before old, {
  Object? savedId,
  bool exactReads = true,
}) {
  final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
  final q = c.buildQuery(offset: 0).toJson() as Map<String, Object?>;
  final refilter = old.filter != jsonEncode(filter(q));
  final reorder =
      !refilter && old.order != jsonEncode([q['sort'], q['direction']]);
  final editor = d.h.model.editor;
  final focused = old.focused;
  final planned = planJob(
    JobFacts(
      kind: refilter
          ? ReloadKind.refilter
          : reorder
          ? ReloadKind.reorder
          : ReloadKind.refresh,
      rows: ordered(d, projects),
      id: old.id,
      state: old.state,
      oldIndex: old.index,
      oldTotal: old.total,
      sameSort: old.sort == q['sort'],
      emptySearch: (q['query'] as String).isEmpty,
      focused: focused,
      focusIndex: focused ? old.index : null,
      pinned:
          old.id != null &&
          editor.isEditing &&
          (projects || editor.base?.id == old.id),
      savedId: savedId,
    ),
  );
  expectSelection(d, projects, planned.selection);
  if (exactReads) {
    final reads = d.store.reads.where(
      (r) => r.scope == (projects ? 'projects' : 'tasks'),
    );
    expect(
      [
        reads.where((r) => !r.membership).length,
        reads.where((r) => r.membership).length,
      ],
      [planned.pageReads, planned.membershipReads],
      reason: 'Exact reads ${d.store.step}: ${reads.map((r) => r.offset)}',
    );
  }
  return planned;
}

const scripted = ViewerCliErrorFailure(
  code: 'locked',
  message: 'scripted',
  exitCode: 4,
);

/// One generated run: fixtures, shared helpers and effect counters.
class Run {
  Run(this.tester, this.d, this.projects, this.random, this.size);
  final WidgetTester tester;
  final ModelViewerDriver d;
  final bool projects;
  final Random random;
  final int size;
  final modes = <String, int>{};
  void count(String mode) => modes[mode] = (modes[mode] ?? 0) + 1;
  ViewerRegion get region =>
      projects ? ViewerRegion.projects : ViewerRegion.tasks;
  dynamic get c => projects ? d.h.model.projectList : d.h.model.tasks!;
  VirtualListController get list => d.h.list(region);
  Object? get selected =>
      projects ? d.h.model.selectedProjectId : d.h.model.tasks!.selectedTaskId;
  List<Object> get published => projects
      ? d.store.projectSnapshots[c.snapshotToken]!
            .map<Object>((p) => p.projectId)
            .toList()
      : d.store.taskSnapshots[c.snapshotToken]!
            .map<Object>((t) => t.id)
            .toList();
  int get dialogs => find.byType(ViewerUnsavedChangesDialog).evaluate().length;
  T pick<T>(List<T> values) => values[random.nextInt(values.length)];
  Future<void> leaveList() async {
    d.h.handles(region).filterFocus.requestFocus();
    await d.settle();
  }

  Future<void> refreshList() => d.start(c.refresh(userInitiated: false));

  /// Puts both lists in a fixed order so a chosen row can sit beyond page 0.
  Future<void> fixedOrder() async {
    if (projects) {
      d.h.model.projectList.setSort(ProjectSort.name);
      d.h.model.projectList.setDirection(SortDirection.ascending);
    } else {
      d.h.model.tasks!.setSort(TaskSort.id);
      d.h.model.tasks!.setDirection(SortDirection.ascending);
    }
    await d.settle();
  }

  /// Clears filters and restores a selection after a sequence removed it.
  Future<void> resetFilters() async {
    if (d.h.model.editor.isEditing) await d.h.model.editor.discardDraft();
    d.h.model.projectList.clearFilters();
    await d.settle();
    if (d.h.model.projectList.selectedProjectId == null) {
      await d.select(ViewerRegion.projects, 0);
    }
    final tasks = d.h.model.tasks!;
    tasks.clearFilters();
    await d.settle();
    if (d.store.orderedTasks(tasks.projectId, const TaskQuery()).isEmpty) {
      d.store.mutate(tasks.projectId, 1, status: 'todo');
    }
    // Earlier saves can leave a paged fixture with a single page of open rows.
    final open = d.store
        .orderedTasks(tasks.projectId, const TaskQuery())
        .length;
    if (size > 100 && !projects && open <= 100) {
      final records = d.store.records[tasks.projectId]!;
      var next = records.keys.reduce(max);
      for (var i = open; i <= 100; i++) {
        records[++next] = testTaskDetail(next);
      }
      d.store.version++;
    }
    // Fixture cleanup can restore the same task externally; refresh its detail
    // too before the next operation assumes a current editor version.
    await d.start(d.h.model.refresh(userInitiated: false));
    if (tasks.selectedTaskId == null) await d.select(ViewerRegion.tasks, 0);
    // Other sequences write to the store. A stale token would cancel the next
    // jump by design, so each sequence starts from a current result.
    if (projects) await refreshList();
  }

  /// Selects a row and proves the jump arrived before a sequence depends on it.
  Future<void> selectRow(int index) async {
    await d.select(region, index);
    expect(c.selectedIndex, index, reason: 'Precondition ${d.store.step}');
  }

  /// A one-row fixture has no other row to move to.
  Future<void> ensureTwoRows() async {
    if ((c.totalCount as int) >= 2) return;
    if (projects) {
      final p = testProjectItem(2, name: 'Project 002');
      d.store.projects.add(p);
      d.store.records[p.projectId] = {1: testTaskDetail(1)};
      d.store.version++;
      await d.start(d.h.model.projectList.refresh());
    } else {
      final tasks = d.h.model.tasks!;
      final next = d.store.records[tasks.projectId]!.keys.reduce(max) + 1;
      d.store.records[tasks.projectId]![next] = testTaskDetail(next);
      d.store.version++;
      await d.start(tasks.refresh());
    }
  }

  /// Selects a row of this list with a task open, ready for the editor.
  Future<Object?> selectForEditing(int index) async {
    await selectRow(index);
    if (projects) {
      final tasks = d.h.model.tasks!;
      if (d.store.orderedTasks(tasks.projectId, const TaskQuery()).isEmpty) {
        d.store.mutate(tasks.projectId, 1, status: 'todo');
        await d.start(tasks.refresh(userInitiated: false));
      }
    }
    await d.select(ViewerRegion.tasks, 0);
    if (!projects) await selectRow(index);
    return selected;
  }

  Future<PlannedJob> setFilter(String query, {bool exactReads = true}) async {
    final old = before(d, projects);
    d.store.reads.clear();
    c.setQuery(query);
    await d.start(c.submitQuery() as Future<void>);
    return expectJob(d, projects, old, exactReads: exactReads);
  }
}

/// Keys pressed before loads finish: the newest intent always wins.
Future<void> pendingNavigation(Run r) async {
  final modes = [if (fullMatrix) 'loads', 'fails', 'recovers'];
  for (final mode in modes..shuffle(r.random)) {
    await pendingKeys(r, mode);
  }
  await staleJump(r);
  await reversedJump(r, fromEnd: false);
  // A last row near a page edge prefetches the first page only on small lists.
  final n = r.c.totalCount as int;
  if (neighbourPage(n - 1, n) != 0) await reversedJump(r, fromEnd: true);
  await keyAfterJump(r);
}

/// The opposite end key arrives while the first jump's read is outstanding.
/// `pressKey` would settle frames and let the read finish, so keys are raw.
Future<void> reversedJump(Run r, {required bool fromEnd}) async {
  final d = r.d, list = r.list, n = r.c.totalCount as int;
  r.count('navigation:reversed');
  final row = fromEnd ? n - 1 : 0;
  await r.selectRow(row);
  await r.refreshList();
  final id = r.selected;
  await r.tester.sendKeyEvent(
    fromEnd ? LogicalKeyboardKey.home : LogicalKeyboardKey.end,
    platform: 'windows',
  );
  await d.pump(10);
  expect(list.hasPendingTarget, isTrue, reason: 'The read must be outstanding');
  await r.tester.sendKeyEvent(
    fromEnd ? LogicalKeyboardKey.end : LogicalKeyboardKey.home,
    platform: 'windows',
  );
  await d.settle();
  expect(r.selected, id, reason: 'The newer key wins: ${d.store.step}');
  expect(list.focusedRowIndex, row);
  expect(list.selectedIndex, row);
  expect(list.hasPendingTarget, isFalse);
}

/// A key in the frame after a jump finished outranks that jump's focus check.
Future<void> keyAfterJump(Run r) async {
  final d = r.d, list = r.list, n = r.c.totalCount as int;
  r.count('navigation:immediate');
  await r.selectRow(0);
  await r.refreshList();
  final id = r.selected;
  await r.tester.sendKeyEvent(LogicalKeyboardKey.end, platform: 'windows');
  for (var f = 0; f < 40 && list.focusedRowIndex != n - 1; f++) {
    await r.tester.pump(const Duration(milliseconds: 20));
  }
  expect(list.focusedRowIndex, n - 1, reason: 'The first jump must finish');
  await r.tester.sendKeyEvent(LogicalKeyboardKey.home, platform: 'windows');
  await d.settle();
  expect(r.selected, id, reason: 'The newer key wins: ${d.store.step}');
  expect(list.focusedRowIndex, 0);
}

/// An external write cancels the pending jump, then one refresh recovers.
Future<void> staleJump(Run r) async {
  final d = r.d, list = r.list, n = r.c.totalCount as int;
  r.count('navigation:stale');
  await r.selectRow(0);
  await r.refreshList();
  final id = r.selected, scope = r.projects ? 'projects' : 'tasks';
  d.store.version++;
  d.store.reads.clear();
  await pressKey(r.tester, LogicalKeyboardKey.end);
  await d.settle();
  expect(
    d.store.reads.where((read) => read.scope == scope).map((x) => x.outcome),
    ['stale_snapshot', 'ok'],
  );
  expect(list.hasPendingTarget, isFalse);
  expect(r.selected, id);
  expect(list.focusedRowIndex, 0);
  expect(r.c.pageFailure, isNull);
  expect(r.c.notice, isNull);
  // The refreshed result takes the same key without a restart.
  await pressKey(r.tester, LogicalKeyboardKey.end);
  await d.settle();
  expect(list.focusedRowIndex, n - 1);
  expect(r.selected, r.published[n - 1]);
}

Future<void> pendingKeys(Run r, String mode) async {
  final d = r.d, list = r.list, n = r.c.totalCount as int;
  expect(n, greaterThan(100), reason: 'Paged navigation needs a second page');
  final atEnd = (n - 1) % 100 >= 20 && r.random.nextBool();
  await r.selectRow(atEnd ? n - 1 : 0);
  await r.refreshList();
  final rows = r.published;
  final toward = atEnd ? LogicalKeyboardKey.home : LogicalKeyboardKey.end;
  final back = atEnd ? LogicalKeyboardKey.end : LogicalKeyboardKey.home;
  const pool = [
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  ];
  final keys = [
    toward,
    r.random.nextBool() ? back : r.pick(pool),
    for (var i = r.random.nextInt(3); i > 0; i--) r.pick(pool),
  ];
  r.count('navigation:$mode');
  final scope = r.projects ? 'projects' : 'tasks';
  if (mode != 'loads') {
    d.store.failure = (read) => read.scope == scope ? scripted : null;
  }
  d.store.reads.clear();
  int? intent;
  var pending = 0, moves = 0;
  for (var i = 0; i < keys.length; i++) {
    final cursor =
        list.pendingTargetIndex ?? list.focusedRowIndex ?? r.c.selectedIndex;
    final key = keys[i];
    final page = list.pageRows;
    final target = switch (key) {
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => n - 1,
      LogicalKeyboardKey.pageUp => cursor - page,
      LogicalKeyboardKey.pageDown => cursor + page,
      LogicalKeyboardKey.arrowUp => cursor - 1,
      _ => cursor + 1,
    };
    final moved = target != cursor && target >= 0 && target < n;
    if (moved) {
      intent = target as int;
      moves++;
      if (!(r.c.isRowReady(target) as bool)) pending++;
    }
    if (i == keys.length - 1 && mode == 'recovers') d.store.failure = null;
    await pressKey(r.tester, key);
    await d.pump(r.pick(const [10, 50, 120]));
  }
  expect(pending, greaterThan(0), reason: 'Sequence must reach an open page');
  await d.settle();
  expect(list.hasPendingTarget, isFalse);
  expect(list.focusedRowIndex, r.c.selectedIndex);
  expect(r.selected, rows[r.c.selectedIndex as int]);
  expect(
    d.store.reads.where((read) => read.scope == scope).length,
    lessThanOrEqualTo(2 * moves),
    reason: 'Paging budget ${d.store.step} $keys',
  );
  if (r.c.isRowReady(intent!) as bool) {
    expect(r.selected, rows[intent], reason: '${d.store.step} $keys');
  } else {
    expect(mode, isNot('loads'), reason: 'Only a failed read may lose a move');
    expect(r.c.pageFailure, isNotNull);
    if (mode == 'fails') {
      expect(d.h.liveText, contains('Could not load row ${intent + 1}'));
    }
    // A later user action retries without a restart.
    d.store.failure = null;
    list.goToIndex(intent);
    await d.settle();
    expect(r.selected, rows[intent]);
    expect(list.focusedRowIndex, intent);
    expect(r.c.pageFailure, isNull);
  }
  d.store.failure = null;
}

/// Retained, then unknown, then materialized by paging, then excluded.
Future<void> retainedTransition(Run r) async {
  if (r.projects || fullMatrix) await retainedSequence(r, saved: false);
  if (!r.projects) {
    await r.resetFilters();
    await retainedSequence(r, saved: true);
  }
}

Future<void> retainedSequence(Run r, {required bool saved}) async {
  final d = r.d, projects = r.projects;
  await r.fixedOrder();
  var rows = ordered(d, projects);
  final index = rows.length > 100
      ? 100 + r.random.nextInt(rows.length - 100)
      : r.random.nextInt(rows.length);
  await r.selectRow(index);
  final id = r.selected!;
  final project = projects ? null : d.h.model.tasks!.projectId;
  r.count('retained:${saved ? 'saved' : 'other'}');
  ProjectItem? removed;

  void remove() {
    if (projects) {
      removed = d.store.projects.firstWhere((p) => p.projectId == id);
      d.store.projects.remove(removed);
      d.store.version++;
    } else {
      d.store.mutate(project!, id as int, status: 'done');
    }
  }

  void restore() {
    if (projects) {
      d.store.projects.add(removed!);
      d.store.version++;
    } else {
      d.store.mutate(project!, id as int, status: 'todo');
    }
  }

  Future<void> externalRefresh() async {
    final old = before(d, projects);
    d.store.reads.clear();
    await d.start(r.c.refresh() as Future<void>);
    expectJob(d, projects, old);
  }

  if (saved) {
    await pressKey(r.tester, LogicalKeyboardKey.f2);
    await d.settle();
    await pressKey(r.tester, LogicalKeyboardKey.f4);
    await d.settle();
    d.h.model.editor.setField(EditorField.status, 'done');
    final old = before(d, false);
    d.store.reads.clear();
    await pressControl(r.tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(d.store.records[project]![id]!.status, 'done');
    expectJob(d, false, old, savedId: id);
  } else {
    await r.leaveList();
    remove();
    await externalRefresh();
    expect(stateOf(r.c), SelectionState.other);
  }
  await r.leaveList();
  for (var i = r.random.nextInt(3); i > 0; i--) {
    if (r.random.nextBool()) {
      await externalRefresh();
    } else {
      // Rule 4 keeps a saved selection; rule 7 clears any other one.
      if (!saved) break;
      await r.setFilter('zz-no-match');
      expect(stateOf(r.c), SelectionState.saved);
      await r.setFilter('');
    }
  }
  restore();
  await r.setFilter(projects ? 'Project' : 'body');
  rows = ordered(d, projects);
  if (r.c.selectedIndex == null) {
    expect(rows.length, greaterThan(100));
    expect(r.c.retainedText, isNotNull);
    r.count('retained:materialized');
    r.list.goToIndex(rows.indexOf(id));
    await d.settle();
    expectSelection(
      d,
      projects,
      ExpectedSelection(id, SelectionState.listed, rows.indexOf(id)),
    );
    expect(
      statusLineText('Saved task no longer matches these filters'),
      findsNothing,
    );
  }
  await r.leaveList();
  final excluded = await r.setFilter('zz-no-match');
  expect(excluded.selection.state, SelectionState.none);
}

/// Attachment replies owed across every way a reload can end.
Future<void> attachmentReload(Run r) async {
  final d = r.d, store = d.store;
  Future<TaskDetail> prepare() async {
    final tasks = d.h.model.tasks!;
    await d.settle();
    final n = tasks.totalCount;
    await d.select(
      ViewerRegion.tasks,
      n > 20 ? 20 + r.random.nextInt(min(n - 20, 60)) : r.random.nextInt(n),
    );
    await d.start(tasks.refresh(userInitiated: false));
    store.reads.clear();
    return store.records[tasks.projectId]![tasks.selectedTaskId]!;
  }

  TaskDetail reply(TaskDetail base, {bool patched = false}) {
    final tasks = d.h.model.tasks!;
    final updated = base.withAttachmentWrite(
      version: base.version + 1,
      updatedMs: base.updatedMs + 1,
      attachments: base.attachments,
    );
    store.records[tasks.projectId]![base.id] = updated;
    store.version++;
    if (patched) {
      store.attachmentRows.putIfAbsent(
        tasks.snapshotToken!,
        () => {},
      )[base.id] = store.row(
        updated,
      );
    }
    d.h.model.applyAttachmentWrite(
      tasks.projectId,
      updated,
      0,
      base.version,
      historyVisible: false,
    );
    return updated;
  }

  void failNext(int count) {
    store.failure = (read) {
      if (read.scope != 'tasks' || count == 0) return null;
      count--;
      return scripted;
    };
  }

  List<String> outcomes() => store.reads
      .where((x) => x.scope == 'tasks')
      .map((x) => x.outcome)
      .toList();
  void expectConfirmed(TaskDetail updated) {
    final tasks = d.h.model.tasks!;
    expect(tasks.isLoading, isFalse);
    expect(tasks.itemAt(tasks.selectedIndex!)!.version, updated.version);
    expect(tasks.selectedTaskId, updated.id);
  }

  final modes = [
    'successful',
    'failed',
    'failedTwice',
    'superseded',
    if (d.h.model.tasks!.totalCount > 100) 'inFlightPage',
  ]..shuffle(r.random);
  for (final mode in modes) {
    r.count('attachment:$mode');
    final base = await prepare();
    final tasks = d.h.model.tasks!;
    switch (mode) {
      case 'successful':
        unawaited(tasks.refresh(userInitiated: false));
        await d.pump(75);
        expect(store.activeReads, greaterThan(0));
        final updated = reply(base);
        await d.settle();
        expect(outcomes(), ['ok', 'ok']);
        expectConfirmed(updated);
      case 'failed':
        failNext(1);
        unawaited(tasks.refresh());
        await d.pump(75);
        final updated = reply(base);
        await d.settle();
        expect(outcomes(), ['scripted', 'ok']);
        expect(tasks.refreshFailure, isNull);
        expectConfirmed(updated);
      case 'failedTwice':
        failNext(2);
        unawaited(tasks.refresh(userInitiated: false));
        await d.pump(75);
        final updated = reply(base);
        await d.settle();
        expect(outcomes(), ['scripted', 'scripted']);
        expect(tasks.refreshFailure, isNotNull);
        store.failure = null;
        await d.start(tasks.refresh(userInitiated: false));
        expect(tasks.refreshFailure, isNull);
        expectConfirmed(updated);
      case 'superseded':
        unawaited(tasks.refresh(userInitiated: false));
        await d.pump(75);
        final updated = reply(base);
        unawaited(tasks.refresh(userInitiated: false));
        await d.settle();
        expect(outcomes(), ['cancelled', 'ok', 'ok']);
        expectConfirmed(updated);
      case 'inFlightPage':
        final last = tasks.totalCount - 1;
        expect(tasks.isRowReady(last), isFalse);
        final epoch = tasks.resultEpoch;
        d.h.list(ViewerRegion.tasks).goToIndex(last);
        await d.pump(50);
        expect(store.activeReads, greaterThan(0));
        final updated = reply(base, patched: true);
        expect(tasks.resultEpoch, epoch, reason: 'A patch is not a commit');
        await d.settle();
        // The real token changes with the write, so the re-queued page is
        // stale and recovers through one refresh.
        expect(outcomes().take(2), ['cancelled', 'stale_snapshot']);
        expect(outcomes().where((o) => o == 'ok'), isNotEmpty);
        expect(d.h.list(ViewerRegion.tasks).hasPendingTarget, isFalse);
        expectConfirmed(updated);
    }
    store.failure = null;
  }
}

/// A refused move never traps the keyboard, whatever the selection state.
Future<void> dirtyRefusal(Run r) async {
  final d = r.d, store = d.store, projects = r.projects;
  Future<void> attempt(String mode) async {
    r.count('refusal:$mode');
    await r.resetFilters();
    await r.ensureTwoRows();
    await r.fixedOrder();
    final rows = ordered(d, projects);
    final index = mode == 'unlocated'
        ? 100 + r.random.nextInt(rows.length - 100)
        : r.random.nextInt(rows.length);
    final id = await r.selectForEditing(index);
    await pressKey(r.tester, LogicalKeyboardKey.f4);
    await d.settle();
    await r.tester.enterText(textFieldWithLabel('Title (Alt+T)'), 'Dirty');
    await d.settle();
    if (mode != 'located') {
      final other = rows.firstWhere((row) => row != id);
      final query = mode == 'unlocated'
          ? (projects ? 'Project' : 'body')
          : projects
          ? store.projects.firstWhere((p) => p.projectId == other).name
          : 'T-$other';
      // An ID search looks like a membership read in the store's log.
      await r.setFilter(query, exactReads: mode == 'unlocated' || projects);
      expect(r.c.selectedIndex, isNull);
      expect(r.c.unplacedLabel, isNotNull);
      expect(
        stateOf(r.c),
        mode == 'retained' ? SelectionState.other : SelectionState.listed,
      );
    }
    await pressKey(
      r.tester,
      projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2,
    );
    await d.settle();
    final state = stateOf(r.c);
    final n = r.c.totalCount as int;
    for (var i = 0; i < 2; i++) {
      final located = r.c.selectedIndex as int?;
      final key = located == null
          ? r.pick(const [
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.home,
              LogicalKeyboardKey.end,
              LogicalKeyboardKey.pageDown,
            ])
          : r.pick([
              if (located < n - 1) LogicalKeyboardKey.arrowDown,
              if (located > 0) LogicalKeyboardKey.arrowUp,
              if (located > 0) LogicalKeyboardKey.home,
              if (located < n - 1) LogicalKeyboardKey.end,
            ]);
      final target = located == null
          ? (key == LogicalKeyboardKey.end ? n - 1 : 0)
          : switch (key) {
              LogicalKeyboardKey.arrowDown => located + 1,
              LogicalKeyboardKey.arrowUp => located - 1,
              LogicalKeyboardKey.home => 0,
              _ => n - 1,
            };
      // A jump that lands on the selection itself leaves nothing to guard.
      final asks = ordered(d, projects)[target] != id;
      store.reads.clear();
      await pressKey(r.tester, key);
      await d.settle();
      expect(r.dialogs, asks ? 1 : 0, reason: '${store.step} $mode $key');
      expect(store.overlaps, 0);
      final scope = projects ? 'projects' : 'tasks';
      expect(
        store.reads.where((read) => read.scope == scope).length,
        lessThanOrEqualTo(2),
      );
      if (asks) {
        await pressKey(r.tester, LogicalKeyboardKey.escape);
        await d.settle();
      }
      expect(r.dialogs, 0, reason: 'Escape closes the guard: $mode $key');
      expect(r.selected, id);
      expect(stateOf(r.c), state);
      expect(d.h.model.editor.draft?.title, 'Dirty');
      expect(r.list.hasListFocus, isTrue, reason: '$mode $key');
      // A page read for the refused move may have located the selection.
      expect(r.list.focusedRowIndex, r.c.selectedIndex, reason: '$mode $key');
    }
    await d.h.model.editor.discardDraft();
    await d.settle();
  }

  final modes = [
    'located',
    'retained',
    if ((r.c.totalCount as int) > 100) 'unlocated',
  ]..shuffle(r.random);
  for (final mode in modes) {
    await attempt(mode);
  }
}

/// A failed post-save read must not lose the saved origin, however the user
/// recovers, until they choose another task.
Future<void> savedRecovery(Run r) async {
  final modes = [
    if (fullMatrix) ...['retry', 'filter'],
    'reverse',
    'owed',
  ];
  for (final mode in modes..shuffle(r.random)) {
    await r.resetFilters();
    for (final focused in [false, true]) {
      await savedSequence(r, mode, focused: focused);
    }
  }
}

Future<void> savedSequence(Run r, String mode, {required bool focused}) async {
  final d = r.d, store = d.store, tester = r.tester;
  r.count('saved:$mode');
  await r.fixedOrder();
  final tasks = d.h.model.tasks!;
  await d.select(ViewerRegion.tasks, r.random.nextInt(tasks.totalCount));
  final id = tasks.selectedTaskId!;
  await pressKey(tester, LogicalKeyboardKey.f2);
  await d.settle();
  await pressKey(tester, LogicalKeyboardKey.f4);
  await d.settle();
  d.h.model.editor.setField(EditorField.status, 'done');
  store.failure = (read) => read.scope == 'tasks' ? scripted : null;
  await pressControl(tester, LogicalKeyboardKey.keyS);
  await d.settle();
  expect(store.records[tasks.projectId]![id]!.status, 'done');
  expect(tasks.refreshFailure, isNotNull);
  expect(tasks.selectedTaskId, id);
  if (focused) {
    await pressKey(tester, LogicalKeyboardKey.f2);
    await d.settle();
    expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, isNotNull);
  } else {
    d.h.handles(ViewerRegion.tasks).filterFocus.requestFocus();
    await d.settle();
  }
  final old = before(d, false);
  store.reads.clear();
  void expectRecovered() => expectJob(d, false, old, savedId: id);
  switch (mode) {
    case 'retry':
      store.failure = null;
      await d.start(tasks.retry());
      expectRecovered();
    case 'reverse':
      store.failure = null;
      tasks.setDirection(
        tasks.direction == SortDirection.ascending
            ? SortDirection.descending
            : SortDirection.ascending,
      );
      await d.settle();
      expectRecovered();
    case 'filter':
      store.failure = null;
      tasks.setQuery('body');
      await d.start(tasks.submitQuery());
      expectRecovered();
    default:
      // An owed attachment refresh recovers on its own, once.
      var failures = 1;
      store.failure = (read) {
        if (read.scope != 'tasks' || failures == 0) return null;
        failures--;
        return scripted;
      };
      unawaited(tasks.refresh(userInitiated: false));
      await d.pump(75);
      final base = store.records[tasks.projectId]![id]!;
      d.h.model.applyAttachmentWrite(
        tasks.projectId,
        base,
        0,
        base.version,
        historyVisible: false,
      );
      await d.settle();
      expect(store.reads.first.outcome, 'scripted');
      expect(stateOf(tasks), SelectionState.saved);
  }
  d.h.handles(ViewerRegion.tasks).filterFocus.requestFocus();
  await d.settle();
  // This sequence is about the Tasks list, whichever list the run generates.
  Future<void> filterTasks(String query) async {
    final prior = before(d, false);
    store.reads.clear();
    tasks.setQuery(query);
    await d.start(tasks.submitQuery());
    expectJob(d, false, prior, savedId: id);
  }

  // Proven absence now keeps the identity, whatever the next trigger is.
  await filterTasks('zz-no-match');
  expect(stateOf(tasks), SelectionState.saved);
  await filterTasks('');
  expect(stateOf(tasks), SelectionState.saved);
  final flip = before(d, false);
  store.reads.clear();
  tasks.setDirection(
    tasks.direction == SortDirection.ascending
        ? SortDirection.descending
        : SortDirection.ascending,
  );
  await d.settle();
  expectJob(d, false, flip, savedId: id);
  expect(stateOf(tasks), SelectionState.saved);
  expect(d.h.model.detail?.taskId, id);
  expect(
    statusLineText('Saved task no longer matches these filters'),
    findsOneWidget,
  );
  // Choosing another task ends the retention and its notice.
  if (tasks.totalCount > 0) {
    await d.select(ViewerRegion.tasks, 0);
    expect(tasks.selectedTaskId, isNot(id));
    expect(tasks.retainedText, isNull);
  }
  // With one row the detail stays open on this task, so it must see the write.
  store.mutate(tasks.projectId, id, status: 'todo');
  await d.start(d.h.model.refresh());
}

/// One Tab stop per collection, whatever the selection and editor state.
Future<void> tabKeys(Run r) async {
  final paged = (r.c.totalCount as int) > 100;
  final combos = fullMatrix
      ? [
          for (final dirty in [false, true])
            for (final mode in ['located', 'retained', if (paged) 'unlocated'])
              (dirty, mode),
        ]
      : [(r.projects, 'unlocated'), if (r.projects) (false, 'located')];
  for (final (dirty, mode) in combos..shuffle(r.random)) {
    await r.resetFilters();
    await r.ensureTwoRows();
    await tabSequence(r, mode, dirty: dirty);
  }
}

Future<void> tabSequence(Run r, String mode, {required bool dirty}) async {
  final d = r.d, store = d.store, projects = r.projects, tester = r.tester;
  r.count('tab:${dirty ? 'dirty' : 'clean'}:$mode');
  await r.fixedOrder();
  final rows = ordered(d, projects);
  final id = await r.selectForEditing(
    mode == 'unlocated'
        ? 100 + r.random.nextInt(rows.length - 100)
        : r.random.nextInt(rows.length),
  );
  final project = d.h.model.tasks!.projectId;
  if (dirty) {
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    await tester.enterText(textFieldWithLabel('Title (Alt+T)'), 'Dirty');
    await d.settle();
  }
  ProjectItem? hidden;
  var hiddenTask = false;
  if (mode == 'unlocated') {
    await r.setFilter(projects ? 'Project' : 'body');
    // Loaded rows must be mounted, or there is no row control to reach.
    await d.scrollToTop(r.region);
  } else if (mode == 'retained' && dirty) {
    final other = rows.firstWhere((row) => row != id);
    await r.setFilter(
      projects
          ? store.projects.firstWhere((p) => p.projectId == other).name
          : 'T-$other',
      exactReads: projects,
    );
  } else if (mode == 'retained') {
    await r.leaveList();
    if (projects) {
      hidden = store.projects.firstWhere((p) => p.projectId == id);
      store.projects.remove(hidden);
      store.version++;
    } else {
      hiddenTask = true;
      store.mutate(project, id! as int, status: 'done');
    }
    await d.start(r.c.refresh() as Future<void>);
  }
  final state = stateOf(r.c);
  final located = r.c.selectedIndex as int?;
  expect(located != null, mode == 'located', reason: '${store.step} $mode');
  final context = '${store.step} $mode dirty=$dirty';
  void unchanged() {
    expect(r.selected, id, reason: context);
    expect(stateOf(r.c), state, reason: context);
    expect(r.dialogs, 0, reason: 'No guard from Tab: $context');
    if (dirty) expect(d.h.model.editor.draft?.title, 'Dirty');
  }

  final entry = projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2;
  Future<void> enter() async {
    await pressKey(tester, entry);
    await d.settle();
    expect(r.list.hasListFocus, isTrue, reason: context);
    expect(r.list.focusedRowIndex, located, reason: context);
  }

  await enter();
  await pressKey(tester, LogicalKeyboardKey.tab);
  await d.settle();
  unchanged();
  if (located != null) {
    expect(r.list.focusedRowIndex, located, reason: 'Actions stop: $context');
    await pressShift(tester, LogicalKeyboardKey.tab);
    await d.settle();
    unchanged();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'list-row-$located',
      reason: 'Shift+Tab from Actions: $context',
    );
    await pressKey(tester, LogicalKeyboardKey.tab);
    await d.settle();
    await pressKey(tester, LogicalKeyboardKey.tab);
    await d.settle();
    unchanged();
  }
  expect(r.list.hasListFocus, isFalse, reason: 'Tab leaves: $context');
  await enter();
  await pressShift(tester, LogicalKeyboardKey.tab);
  await d.settle();
  unchanged();
  expect(r.list.hasListFocus, isFalse, reason: 'Shift+Tab leaves: $context');
  if (dirty) await d.h.model.editor.discardDraft();
  await d.settle();
  if (hidden != null) {
    store.projects.add(hidden);
    store.version++;
  }
  if (hiddenTask) store.mutate(project, id! as int, status: 'todo');
}

List<Object?> taskValues(TaskItem t) => [
  t.id,
  t.displayId,
  t.title,
  t.status,
  t.priority,
  t.version,
  t.labels,
  t.dependencyCount,
  t.waitingDependencyCount,
  t.verifyingDependencyCount,
  t.createdMs,
  t.updatedMs,
  t.attachmentCount,
];
void invariants(ModelViewerDriver d) {
  final h = d.h;
  for (final projects in [false, true]) {
    final dynamic c = projects ? h.model.projectList : h.model.tasks;
    if (c == null) continue;
    final list = h.list(projects ? ViewerRegion.projects : ViewerRegion.tasks);
    final id = projects
        ? h.model.selectedProjectId
        : h.model.tasks!.selectedTaskId;
    final highlight = list.selectedIndex;
    if (highlight != null) {
      final dynamic row = c.itemAt(highlight);
      expect(
        row,
        isNotNull,
        reason:
            'Highlight projects=$projects h=$highlight id=$id total=${c.totalCount} step=${d.store.step}',
      );
      expect(projects ? row.projectId : row.id, id);
    }
    if (id == null) expect(highlight, isNull);
    // I3 exempts the frames a guard question is open over the refused row.
    final guarded = d.h.model.editor.isDirty;
    if (list.focusedRowIndex case final focused? when !guarded) {
      final dynamic row = c.itemAt(focused);
      expect(row, isNotNull, reason: 'Focused row must remain materialized');
      expect(
        projects ? row.projectId : row.id,
        id,
        reason: 'Focus and identity: ${d.store.step}',
      );
    }
    final token = c.snapshotToken as String?;
    if (token != null) {
      final List<dynamic>? snapshot = projects
          ? d.store.projectSnapshots[token]
          : d.store.taskSnapshots[token];
      expect(snapshot, isNotNull);
      for (var i = 0; i < (c.totalCount as int); i++) {
        final dynamic row = c.itemAt(i);
        if (row == null) continue;
        final dynamic stored = snapshot![i];
        expect(
          projects ? row.projectId : row.id,
          projects ? stored.projectId : stored.id,
          reason: 'Store order ${d.store.step} at $i',
        );
        if (projects) {
          expect(
            (row as ProjectItem).toJson(),
            (stored as ProjectItem).toJson(),
            reason: 'Full project DTO ${d.store.step} at $i',
          );
        } else {
          final expected =
              d.store.attachmentRows[token]?[row.id] ?? stored as TaskItem;
          expect(
            taskValues(row as TaskItem),
            taskValues(expected),
            reason: 'Full task DTO ${d.store.step} at $i',
          );
        }
      }
    }
  }
  expect(d.store.overlaps, 0, reason: 'Only one read per scope');
}

void settledInvariants(ModelViewerDriver d) {
  invariants(d);
  final h = d.h;
  expect(h.model.selectedProject?.projectId, h.model.selectedProjectId);
  if (h.model.selectedProjectId != null) {
    expect(h.model.tasks?.projectId, h.model.selectedProjectId);
  }
  expect(h.model.detail?.taskId, h.model.tasks?.selectedTaskId);
  if (h.model.tasks?.selectedTaskId != null) {
    expect(h.model.detail?.detail?.id, h.model.tasks?.selectedTaskId);
  }
}

void main() {
  for (final projects in [false, true]) {
    for (final size in sizes) {
      final seed = seeds[projects ? 1 : 0] ^ size;
      testWidgets('store property ${projects ? 'Projects' : 'Tasks'} size=$size seed=$seed', (
        tester,
      ) async {
        final elapsed = Stopwatch()..start();
        final random = Random(seed), trace = <String>[];
        final d = ModelViewerDriver(
          tester,
          ModelStore(
            count: projects ? 2 : size,
            projectCount: projects ? size : 2,
            seed: seed,
          ),
        );
        await d.mount();
        d.onPump = () => invariants(d);
        final run = Run(tester, d, projects, random, size);
        final kinds = [
          for (final op in Op.values)
            if ((size > 100 || !pagedOps.contains(op)) &&
                (fullMatrix ||
                    !(projects ? routineTasksOnly : routineProjectsOnly)
                        .contains(op)))
              op,
        ];
        final effective = {for (final op in kinds) op: 0};
        final repeats = fullMatrix ? 2 : 1;
        final ops = [for (var i = 0; i < repeats; i++) ...kinds]
          ..shuffle(random);
        while (fullMatrix && ops.length < max(28, requestedCount)) {
          ops.add(kinds[random.nextInt(kinds.length)]);
        }
        try {
          for (var step = 0; step < ops.length; step++) {
            final op = ops[step];
            trace.add('$step:${op.name}');
            d.store.step = 'prepare $step';
            d.store.failure = null;
            if (d.h.model.editor.isEditing) {
              await d.h.model.editor.discardDraft();
              await d.settle();
            }
            if (compoundOps.contains(op)) {
              await run.resetFilters();
              d.store.step =
                  '$seed/$size/${projects ? 'projects' : 'tasks'}/$step:${op.name}';
              await switch (op) {
                Op.pendingNavigation => pendingNavigation(run),
                Op.retainedTransition => retainedTransition(run),
                Op.attachmentReload => attachmentReload(run),
                Op.dirtyRefusal => dirtyRefusal(run),
                Op.savedRecovery => savedRecovery(run),
                _ => tabKeys(run),
              };
              await run.resetFilters();
              effective[op] = effective[op]! + 1;
              settledInvariants(d);
              continue;
            }
            // Preconditions are real operations too, logged separately from the
            // generated trigger. They never overwrite controller result internals.
            d.h.model.projectList.clearFilters();
            await d.settle();
            if (d.h.model.selectedProjectId == null) {
              await d.select(ViewerRegion.projects, 0);
            }
            var tasks = d.h.model.tasks!;
            if (d.store
                .orderedTasks(tasks.projectId, const TaskQuery())
                .isEmpty) {
              d.store.mutate(tasks.projectId, 1, status: 'todo');
            }
            tasks.clearFilters();
            await d.start(tasks.refresh(userInitiated: false));
            await d.select(
              ViewerRegion.tasks,
              random.nextInt(tasks.totalCount),
            );
            final region = projects
                ? ViewerRegion.projects
                : ViewerRegion.tasks;
            await d.select(
              region,
              random.nextInt(
                projects ? d.h.model.projectList.totalCount : tasks.totalCount,
              ),
            );
            tasks = d.h.model.tasks!;
            if (projects) {
              if (d.store
                  .orderedTasks(tasks.projectId, const TaskQuery())
                  .isEmpty) {
                d.store.mutate(tasks.projectId, 1, status: 'todo');
              }
              tasks.clearFilters();
              await d.start(tasks.refresh(userInitiated: false));
              await d.select(
                ViewerRegion.tasks,
                random.nextInt(tasks.totalCount),
              );
              await d.focus(region);
            }
            final dynamic c = projects ? d.h.model.projectList : tasks;
            d.store.step =
                '$seed/$size/${projects ? 'projects' : 'tasks'}/$step:${op.name}';
            final old = before(d, projects);
            d.store.reads.clear();
            switch (op) {
              case Op.sort:
                if (projects) {
                  final prior = d.h.model.projectList.sort;
                  d.h.model.projectList.setSort(
                    prior == ProjectSort.name
                        ? ProjectSort.lastWrite
                        : ProjectSort.name,
                  );
                  expect(d.h.model.projectList.sort, isNot(prior));
                } else {
                  final prior = tasks.sort;
                  tasks.setSort(
                    TaskSort.values[(prior.index + 1) % TaskSort.values.length],
                  );
                  expect(tasks.sort, isNot(prior));
                }
                await d.settle();
                expectJob(d, projects, old);
              case Op.reverse:
                final prior = c.direction;
                await pressAlt(tester, LogicalKeyboardKey.keyI);
                await d.settle();
                expect(c.direction, isNot(prior));
                expectJob(d, projects, old);
              case Op.f5:
                await pressKey(tester, LogicalKeyboardKey.f5);
                await d.settle();
                expect(d.store.reads, isNotEmpty);
                expectJob(d, projects, old);
                expect(c.selectedIndex, isNotNull);
              case Op.windowReturn:
                // The sampling clock is injected; age the last sample by 31 seconds,
                // then send the real lifecycle resume event.
                final clock = taskSampleClock;
                taskSampleClock = () =>
                    DateTime.now().millisecondsSinceEpoch - 31000;
                await d.start(tasks.refresh(userInitiated: false));
                taskSampleClock = clock;
                d.store.reads.clear();
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.inactive,
                );
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.resumed,
                );
                await d.settle();
                expect(d.store.reads, isNotEmpty);
                expectJob(d, projects, old);
              case Op.save:
                await pressKey(tester, LogicalKeyboardKey.f2);
                await d.settle();
                await pressKey(tester, LogicalKeyboardKey.f4);
                await d.settle();
                final id = tasks.selectedTaskId!;
                final count = d.store.writer.requests.length;
                await tester.enterText(
                  textFieldWithLabel('Title (Alt+T)'),
                  'Generated $seed step $step',
                );
                if (step.isEven) {
                  d.h.model.editor.setField(EditorField.status, 'done');
                }
                final taskOld = before(d, false);
                d.store.reads.clear();
                await pressControl(tester, LogicalKeyboardKey.keyS);
                await d.settle();
                expect(d.store.writer.requests.length, count + 1);
                expect(
                  d.store.records[tasks.projectId]![id]!.title,
                  'Generated $seed step $step',
                );
                expectJob(d, false, taskOld, savedId: id);
              case Op.listStatus:
                await d.focus(ViewerRegion.tasks);
                final taskOld = before(d, false);
                final count = d.store.writer.requests.length;
                await pressKey(tester, LogicalKeyboardKey.keyD);
                await d.settle();
                expect(d.store.writer.requests.length, count + 1);
                expect(
                  d.store.records[tasks.projectId]![taskOld.id]!.status,
                  'done',
                );
                expectJob(d, false, taskOld);
              case Op.filter:
                d.h.handles(region).filterFocus.requestFocus();
                await d.settle();
                final unfocused = before(d, projects);
                if (projects) {
                  d.h.model.projectList.setQuery('Project 00');
                  await d.start(d.h.model.projectList.submitQuery());
                } else {
                  tasks.setQuery('needle');
                  await d.start(tasks.submitQuery());
                }
                expect(c.query, isNotEmpty);
                expectJob(d, projects, unfocused);
              case Op.navigation:
                // Navigation must be effective even for the one-row fixture.
                await run.ensureTwoRows();
                final prior = projects
                    ? d.h.model.selectedProjectId
                    : tasks.selectedTaskId;
                final rows = projects
                    ? d.store.projectSnapshots[c.snapshotToken]!
                          .map<Object>((p) => p.projectId)
                          .toList()
                    : d.store.taskSnapshots[c.snapshotToken]!
                          .map<Object>((t) => t.id)
                          .toList();
                final target = rows.first == prior ? rows.length - 1 : 0;
                final neighbour = neighbourPage(target, rows.length);
                final expectedReads =
                    (c.isRowReady(target) as bool ? 0 : 1) +
                    (neighbour != null &&
                            !(c.isPageCached(neighbour * 100) as bool)
                        ? 1
                        : 0);
                d.store.reads.clear();
                await pressKey(
                  tester,
                  target == 0
                      ? LogicalKeyboardKey.home
                      : LogicalKeyboardKey.end,
                );
                await d.settle();
                expect(
                  projects ? d.h.model.selectedProjectId : tasks.selectedTaskId,
                  rows[target],
                );
                expect(rows[target], isNot(prior));
                expect(
                  d.store.reads.where(
                    (r) => r.scope == (projects ? 'projects' : 'tasks'),
                  ),
                  hasLength(expectedReads),
                  reason: 'Exact navigation reads ${d.store.step}',
                );
              case Op.focusEntry:
                final id = projects
                    ? d.h.model.selectedProjectId
                    : tasks.selectedTaskId;
                await d.focus(
                  projects ? ViewerRegion.tasks : ViewerRegion.projects,
                );
                expect(d.h.list(region).hasListFocus, isFalse);
                await pressKey(
                  tester,
                  projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2,
                );
                await d.settle();
                expect(d.h.list(region).hasListFocus, isTrue);
                expect(
                  projects ? d.h.model.selectedProjectId : tasks.selectedTaskId,
                  id,
                );
              case Op.attachment:
                final id = tasks.selectedTaskId!;
                final base = d.store.records[tasks.projectId]![id]!;
                final updated = base.withAttachmentWrite(
                  version: base.version + 1,
                  updatedMs: base.updatedMs + 1,
                  attachments: base.attachments,
                );
                d.store.records[tasks.projectId]![id] = updated;
                d.store.version++;
                final epoch = tasks.resultEpoch;
                final reads = d.store.reads.length;
                d.store.attachmentRows.putIfAbsent(
                  tasks.snapshotToken!,
                  () => {},
                )[id] = d.store.row(
                  updated,
                );
                d.h.model.applyAttachmentWrite(
                  tasks.projectId,
                  updated,
                  0,
                  base.version,
                  historyVisible: false,
                );
                await d.settle();
                expect(
                  tasks.itemAt(tasks.selectedIndex!)!.version,
                  base.version + 1,
                );
                expect(tasks.resultEpoch, epoch);
                expect(d.store.reads.length, reads);
                expect(tasks.selectedTaskId, id);
              case Op.externalMutation:
                final id = tasks.selectedTaskId!;
                final version = d.store.version;
                d.store.mutate(
                  tasks.projectId,
                  id,
                  title: 'External $seed/$step',
                );
                await d.start(d.h.model.refresh());
                expect(d.store.version, version + 1);
                expect(d.h.model.detail?.taskId, id);
                expect(tasks.selectedItem?.title, 'External $seed/$step');
              case Op.failure:
                final token = c.snapshotToken;
                d.store.failure = (r) =>
                    r.scope == (projects ? 'projects' : 'tasks')
                    ? const ViewerCliErrorFailure(
                        code: 'locked',
                        message: 'scripted',
                        exitCode: 4,
                      )
                    : null;
                await d.start(c.refresh() as Future<void>);
                expect(c.refreshFailure, isNotNull);
                expect(c.snapshotToken, token);
                expect(
                  projects ? d.h.model.selectedProjectId : tasks.selectedTaskId,
                  old.id,
                );
                d.store.failure = null;
                d.store.reads.clear();
                await d.start(c.retry() as Future<void>);
                expect(c.refreshFailure, isNull);
                expectJob(d, projects, old);
              case Op.projectSwitch:
                // Saves may have changed last-write ordering since the displayed token.
                // Establish the latest catalog before choosing positions from the store.
                await d.start(d.h.model.projectList.refresh());
                if (d.h.model.projectList.totalCount < 2) {
                  final p = testProjectItem(2, name: 'Project 002');
                  d.store.projects.add(p);
                  d.store.records[p.projectId] = {1: testTaskDetail(1)};
                  d.store.version++;
                  await d.start(d.h.model.projectList.refresh());
                }
                final id = d.h.model.selectedProjectId;
                final taskId = d.h.model.tasks!.selectedTaskId;
                final rows = ordered(d, true);
                final away = rows.indexOf(id!) == 0 ? 1 : 0;
                await d.select(ViewerRegion.projects, away);
                expect(d.h.model.selectedProjectId, isNot(id));
                await d.select(ViewerRegion.projects, rows.indexOf(id));
                expect(d.h.model.selectedProjectId, id);
                expect(d.h.model.tasks!.selectedTaskId, taskId);
              case Op.interleave:
                final prior = c.direction;
                c.setDirection(
                  prior == SortDirection.ascending
                      ? SortDirection.descending
                      : SortDirection.ascending,
                );
                await d.pump(75);
                expect(d.store.activeReads, greaterThan(0));
                // A newer navigation intent during the job retargets staged rows.
                final list = d.h.list(region);
                final selected = c.selectedIndex as int?;
                if (selected != null && c.totalCount > 1) {
                  list.goToIndex(selected == 0 ? 1 : 0);
                  await d.pump(25);
                } else {
                  final superseding = c.refresh() as Future<void>;
                  await d.pump(25);
                  expect(
                    d.store.reads.where((r) => r.outcome == 'cancelled'),
                    isNotEmpty,
                  );
                  unawaited(superseding);
                }
                final retarget = before(d, projects);
                await d.settle();
                expect(c.direction, isNot(prior));
                expect(
                  projects
                      ? d.h.model.selectedProjectId
                      : d.h.model.tasks!.selectedTaskId,
                  retarget.id,
                );
              default:
                fail('Compound operations run before the generic setup');
            }
            effective[op] = effective[op]! + 1;
            settledInvariants(d);
          }
          for (final count in effective.entries) {
            expect(
              count.value,
              greaterThanOrEqualTo(repeats),
              reason: 'Every operation effective: ${count.key}',
            );
          }
          final paged = size > 100;
          final tasksRun = fullMatrix || !projects;
          final projectsRun = fullMatrix || projects;
          for (final mode in [
            if (tasksRun) ...[
              'attachment:successful',
              'attachment:failed',
              'attachment:failedTwice',
              'attachment:superseded',
            ],
            if (projectsRun) ...['refusal:located', 'refusal:retained'],
            if (tasksRun) ...['saved:reverse', 'saved:owed'],
            if (fullMatrix) ...[
              'saved:retry',
              'saved:filter',
              'tab:clean:located',
              'tab:clean:retained',
              'tab:dirty:located',
              'tab:dirty:retained',
            ],
            if (projectsRun) 'retained:other',
            if (!projects) 'retained:saved',
            if (paged) ...[
              'retained:materialized',
              if (tasksRun) ...[
                if (fullMatrix) 'navigation:loads',
                'navigation:fails',
                'navigation:recovers',
                'navigation:stale',
                'navigation:reversed',
                'navigation:immediate',
              ],
              if (projectsRun) 'refusal:unlocated',
              if (!projects) 'attachment:inFlightPage',
            ],
          ]) {
            expect(run.modes[mode], isNotNull, reason: 'Mode $mode never ran');
          }
        } catch (e, st) {
          debugPrint(
            'FAILING INPUT seed=$seed size=$size projects=$projects count=${ops.length}\n${trace.join('\n')}\n$e\n$st',
          );
          rethrow;
        } finally {
          await d.close();
          elapsed.stop();
          debugPrint(
            'PROPERTY_RUNTIME seed=$seed size=$size projects=$projects operations=${ops.length} effective=$effective modes=${run.modes} seconds=${elapsed.elapsedMilliseconds / 1000}',
          );
        }
      });
    }
  }
}
