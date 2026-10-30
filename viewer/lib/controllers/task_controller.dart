/// Query controls backed by the shared atomic paged-selection core.
library;

import 'dart:async';
import 'dart:convert';

import 'paged_selection.dart';
export 'paged_selection.dart'
    show
        ListSelection,
        NoSelection,
        Listed,
        Retained,
        RetainReason,
        RowLoad,
        RowLoadState,
        ListFocus;

import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Wall clock for the task list's sample time. Render regression tests pin
/// it so the status line is deterministic; production never replaces it.
@visibleForTesting
int Function() taskSampleClock = () => DateTime.now().millisecondsSinceEpoch;

/// Rows requested per CLI page (viewer/spec.md section 5).
const int taskPageSize = 100;

/// Pages retained per task query.
const int taskMaxCachedPages = 5;

/// Search keystrokes settle for this long before a read is issued.
const Duration taskSearchDebounce = Duration(milliseconds: 250);

/// Distance to a page boundary that triggers a prefetch.
const int taskPrefetchRows = 20;

/// One project's task-list parameters and last selection.
///
/// The workspace keeps one of these per visited project, so switching projects
/// preserves every filter, the sort and the selected task (viewer/spec.md
/// section 5) without keeping a second paged reader alive.
final class TaskListState {
  const TaskListState({
    this.query = '',
    this.scope = TaskScope.open,
    this.statuses = const <String>{},
    this.priorities = const <String>{},
    this.labels = const <String>[],
    this.readiness = TaskReadiness.any,
    this.sort = TaskSort.priority,
    this.direction = SortDirection.ascending,
    this.selectedTaskId,
    this.selectedIndexHint,
  });

  final String query;
  final TaskScope scope;
  final Set<String> statuses;
  final Set<String> priorities;
  final List<String> labels;
  final TaskReadiness readiness;
  final TaskSort sort;
  final SortDirection direction;

  /// Task the user last selected in this project, or null for none.
  final int? selectedTaskId;
  final int? selectedIndexHint;
}

/// Task list state: parameters, paged rows, selection and failures.
class TaskController extends ChangeNotifier {
  TaskController({
    required this.projectId,
    required TaskReader reader,
    this.debounce = taskSearchDebounce,
    this.pageSize = taskPageSize,
    this.maxCachedPages = taskMaxCachedPages,
    this.prefetchRows = taskPrefetchRows,
  }) : // Private field, so an initializing formal cannot name the parameter.
       // ignore: prefer_initializing_formals
       _reader = reader {
    _core.addListener(_notify);
  }

  /// Project UUID every read is routed by; never the working directory.
  final String projectId;

  final TaskReader _reader;
  final Duration debounce;
  final int pageSize;
  final int maxCachedPages;
  final int prefetchRows;

  Timer? _debounceTimer;
  bool _disposed = false;

  String _query = '';
  TaskScope _scope = TaskScope.open;
  final Set<String> _statuses = <String>{};
  final Set<String> _priorities = <String>{};
  List<String> _labels = const <String>[];
  TaskReadiness _readiness = TaskReadiness.any;
  TaskSort _sort = TaskSort.priority;
  SortDirection _direction = SortDirection.ascending;

  late final _core = PagedSelectionCore<TaskItem, int>(
    keyOf: (item) => item.id,
    cancelRead: _cancelInFlight,
    listLabel: 'Tasks',
    describe: (id, item) =>
        'Selected task ${viewerCanonicalTaskId(id, projectKey)}',
    pageSize: pageSize,
    maxCachedPages: maxCachedPages,
    prefetchRows: prefetchRows,
  );
  bool Function(int)? get isSelectionPinned => _core.isSelectionPinned;
  set isSelectionPinned(bool Function(int)? probe) =>
      _core.isSelectionPinned = probe;
  ListFocus<int> Function()? get listFocus => _core.listFocus;
  set listFocus(ListFocus<int> Function()? probe) => _core.listFocus = probe;
  ListSelection<int> get selection => _core.selection;
  ViewerFailure? get pageFailure => _core.pageFailure;
  String? get retainedText => _core.retainedText;
  String? get unplacedLabel => _core.unplacedLabel;
  int get announcementSerial => _core.announcementSerial;
  String? get announcement => _core.announcement;
  // ------------------------------------------------------------- parameters

  String get query => _query;
  TaskScope get scope => _scope;
  Set<String> get statuses => Set<String>.unmodifiable(_statuses);
  Set<String> get priorities => Set<String>.unmodifiable(_priorities);
  List<String> get labels => List<String>.unmodifiable(_labels);
  bool get needsHuman => _labels.contains(needsHumanLabel);
  TaskReadiness get readiness => _readiness;
  TaskSort get sort => _sort;
  SortDirection get direction => _direction;

  int get totalCount => _core.totalCount;
  int get rowCount => totalCount;
  int get loadedRowCount => _core.loadedRowCount;
  int? get sampledAtMs => _core.sampledAtMs;
  bool get isLoading => _core.isLoading;
  int get resultEpoch => _core.resultEpoch;
  bool get hasRows => totalCount > 0;
  bool get hasConfirmedData => _core.published != null;
  ViewerFailure? get firstLoadError => _core.firstLoadError;
  ViewerFailure? get refreshFailure => _core.refreshFailure;
  String? get notice => _core.notice;
  int? get selectedTaskId => _core.selectedId;
  int get cachedPageCount => _core.cachedPageCount;
  String? get snapshotToken => _core.snapshotToken;
  TaskItem? itemAt(int index) => _core.itemAt(index);
  bool isRowReady(int index) => itemAt(index) != null;
  bool isPageCached(int index) => _core.isPageCached(index);
  List<int> get cachedPageIndexes => _core.cachedPageIndexes;
  int? indexOfTask(int id) => _core.indexOf(id);
  TaskItem? get selectedItem => _core.selectedItem;
  int? get selectedIndex => _core.selectedIndex;
  int get activeFilterCount =>
      (query.trim().isEmpty ? 0 : 1) +
      (scope == TaskScope.open ? 0 : 1) +
      (statuses.isEmpty ? 0 : 1) +
      (priorities.isEmpty ? 0 : 1) +
      (labels.isEmpty ? 0 : 1) +
      (readiness == TaskReadiness.any ? 0 : 1);

  TaskQuery buildQuery({required int offset}) => TaskQuery(
    query: _searchQuery(),
    scope: _scope,
    statuses: _statuses.toList()..sort(),
    priorities: _priorities.toList()..sort(),
    labels: _labels,
    readiness: _readiness,
    sort: _sort,
    direction: _direction,
    offset: offset,
    limit: pageSize,
    // Offset zero always recounts; later pages reuse the token from the first
    // page so a changed list becomes visible as stalesnapshotToken.
    snapshot: offset == 0 ? null : snapshotToken,
  );

  String _searchQuery() {
    final text = _query.trim();
    if (RegExp(r'^[0-9]+$').hasMatch(text)) {
      final id = int.tryParse(text);
      if (id != null) {
        return viewerCanonicalTaskId(id, projectKey);
      }
    }
    return text;
  }

  // -------------------------------------------------------------- controls

  /// Everything a project switch must remember, selection included.
  TaskListState captureState() => TaskListState(
    query: _query,
    scope: _scope,
    statuses: Set<String>.unmodifiable(_statuses),
    priorities: Set<String>.unmodifiable(_priorities),
    labels: _labels,
    readiness: _readiness,
    sort: _sort,
    direction: _direction,
    selectedTaskId: selectedTaskId,
    selectedIndexHint: selectedIndex,
  );

  /// Replaces every parameter at once, for a project the user returns to.
  ///
  /// No read is issued and no debounce is armed: the caller loads once, so
  /// restoring six saved filters cannot fire six queries.
  void restoreState(TaskListState state) {
    _debounceTimer?.cancel();
    _query = state.query;
    _scope = state.scope;
    _statuses
      ..clear()
      ..addAll(state.statuses);
    _priorities
      ..clear()
      ..addAll(state.priorities);
    _labels = List<String>.unmodifiable(state.labels);
    _readiness = state.readiness;
    _sort = state.sort;
    _direction = state.direction;
    _core.select(state.selectedTaskId, projectSwitch: true);
    _restoreHint = state.selectedIndexHint;
    _notify();
  }

  /// Types into the search field: the read waits for the debounce.
  void setQuery(String value) {
    if (_query == value) {
      return;
    }
    _query = value;
    _notify();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(reload()));
  }

  /// Enter in the search field: submit without waiting for the debounce.
  Future<void> submitQuery() {
    _debounceTimer?.cancel();
    return reload();
  }

  /// Adds or removes one status filter.
  ///
  /// Returns true when selecting the status also moved the scope to all tasks,
  /// so the pane can announce that change exactly once (design.md section 5).
  bool toggleStatus(String status) {
    final wasScope = _scope;
    if (_statuses.contains(status)) {
      _statuses.remove(status);
    } else {
      _statuses.add(status);
      if (viewerStatusIsTerminal(status)) {
        _scope = TaskScope.all;
      }
    }
    final scopeChanged = _scope != wasScope;
    _notify();
    unawaited(reload());
    return scopeChanged;
  }

  /// Selects every status across both scopes, or restores the open-task default.
  void setAllStatuses(bool selected) {
    _scope = selected ? TaskScope.all : TaskScope.open;
    _statuses
      ..clear()
      ..addAll(selected ? viewerTaskStatuses : const <String>[]);
    _notify();
    unawaited(reload());
  }

  void togglePriority(String priority) {
    if (!_priorities.remove(priority)) {
      _priorities.add(priority);
    }
    _notify();
    unawaited(reload());
  }

  void setScope(TaskScope value) {
    if (_scope == value) {
      return;
    }
    _scope = value;
    _notify();
    unawaited(reload());
  }

  /// Replaces the label filter with normalized, deduplicated, sorted labels.
  void setLabels(Iterable<String> labels) {
    final normalized = <String>{};
    for (final label in labels) {
      final trimmed = label.trim().toLowerCase();
      if (trimmed.isNotEmpty) {
        normalized.add(trimmed);
      }
    }
    final sorted = normalized.toList()..sort();
    if (listEquals(sorted, _labels)) {
      return;
    }
    _labels = List<String>.unmodifiable(sorted);
    _notify();
    unawaited(reload());
  }

  /// The Needs-human checkbox is the `needs-human` label filter.
  void setNeedsHuman(bool value) {
    setLabels(<String>[
      for (final label in _labels)
        if (label != needsHumanLabel) label,
      if (value) needsHumanLabel,
    ]);
  }

  void setReadiness(TaskReadiness value) {
    if (_readiness == value) {
      return;
    }
    _readiness = value;
    _notify();
    unawaited(reload());
  }

  void setSort(TaskSort value) {
    if (_sort == value) {
      return;
    }
    _sort = value;
    _direction = value.defaultDirection;
    _notify();
    unawaited(reload());
  }

  void setDirection(SortDirection value) {
    if (_direction == value) {
      return;
    }
    _direction = value;
    _notify();
    unawaited(reload());
  }

  /// Clear filters returns Open scope, no statuses, priorities or labels, Any
  /// readiness and empty text, keeping the chosen sort (design.md section 5).
  void clearFilters() {
    _debounceTimer?.cancel();
    final alreadyClear =
        _query.trim().isEmpty &&
        _scope == TaskScope.open &&
        _statuses.isEmpty &&
        _priorities.isEmpty &&
        _labels.isEmpty &&
        _readiness == TaskReadiness.any;
    if (alreadyClear) {
      return;
    }
    _query = '';
    _scope = TaskScope.open;
    _statuses.clear();
    _priorities.clear();
    _labels = const <String>[];
    _readiness = TaskReadiness.any;
    _notify();
    unawaited(reload());
  }

  /// Preserve TSK-063 attachment version checks and deferred refresh.
  void applyAttachmentWrite(
    TaskDetail detail,
    int count, {
    required int baseVersion,
  }) {
    final older = cachedPageIndexes.any(
      (p) => List.generate(
        pageSize,
        (i) => itemAt(p * pageSize + i),
      ).any((r) => r?.id == detail.id && r!.version < baseVersion),
    );
    _core.patch(
      (row) => row.id == detail.id && row.version == baseVersion
          ? row.withAttachmentWrite(detail, count)
          : row,
      needsRefresh: older,
    );
  }

  String? get projectKey => _core.published?.projectKey;
  int? _restoreHint;
  PagedSelectionSpec<TaskItem, int> _spec() {
    final q = buildQuery(offset: 0);
    var key = projectKey;
    Future<SelectionPage<TaskItem>> read(
      int offset,
      String? token,
      String query,
    ) async {
      final page = await _reader.fetchTasks(
        projectId,
        TaskQuery(
          query: query,
          scope: q.scope,
          statuses: q.statuses,
          priorities: q.priorities,
          labels: q.labels,
          readiness: q.readiness,
          sort: q.sort,
          direction: q.direction,
          offset: offset,
          limit: pageSize,
          snapshot: token,
        ),
      );
      key = page.projectKey;
      return SelectionPage(
        items: page.items,
        total: page.totalCount,
        snapshot: page.snapshot,
        sampledAtMs: taskSampleClock(),
        projectKey: page.projectKey,
      );
    }

    return PagedSelectionSpec(
      filterKey: jsonEncode([
        q.query,
        q.scope.wireValue,
        q.statuses,
        q.priorities,
        q.labels,
        q.readiness.wireValue,
      ]),
      sortKey: q.sort,
      direction: q.direction,
      emptySearch: q.query.isEmpty,
      read: (offset, token) => read(offset, token, q.query),
      membership: (id) => read(0, null, viewerCanonicalTaskId(id, key)),
    );
  }

  Future<void> refresh({bool userInitiated = true, int? savedId}) {
    _debounceTimer?.cancel();
    return _core.reload(
      _spec(),
      userInitiated: userInitiated,
      savedId: savedId,
      restoreHint: _restoreHint,
    );
  }

  Future<void> retry() => refresh();
  Future<void> reload() => refresh();
  void selectIndex(int? index) =>
      _core.select(index == null ? null : itemAt(index)?.id, rowFocus: true);
  void selectTaskId(int? id) => _core.select(id);
  Future<RowLoad> ensureRow(int index) => _core.ensureRow(index);
  void _cancelInFlight() {
    final reader = _reader;
    if (reader is CancellableTaskReader) reader.cancelScope('tasks');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _core.removeListener(_notify);
    _core.dispose();
    super.dispose();
  }
}
