/// One project's tasks as a combined, filtered, paged query
/// (viewer/spec.md sections 4.3, 5 and 6).
///
/// The controller owns the request parameters, the debounce, the page cache and
/// every failure state, so the pane stays a rendering layer. It mirrors
/// [ProjectController] deliberately: the two collections share navigation
/// semantics but not their query fields, and a shared abstraction would have to
/// parameterise every difference the CLI defines.
///
/// Safety rules:
/// * each reload bumps a generation, and an older generation can never touch
///   rows, counts or the selection;
/// * a superseded read is cancelled, so it cannot deliver a late answer;
/// * a stale snapshot keeps the last confirmed rows, drops every cached page
///   and reloads from offset zero exactly once.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';

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
       _reader = reader;

  /// Project UUID every read is routed by; never the working directory.
  final String projectId;

  final TaskReader _reader;
  final Duration debounce;
  final int pageSize;
  final int maxCachedPages;
  final int prefetchRows;

  Timer? _debounceTimer;
  int _generation = 0;
  bool _disposed = false;

  String _query = '';
  TaskScope _scope = TaskScope.open;
  final Set<String> _statuses = <String>{};
  final Set<String> _priorities = <String>{};
  List<String> _labels = const <String>[];
  TaskReadiness _readiness = TaskReadiness.any;
  TaskSort _sort = TaskSort.priority;
  SortDirection _direction = SortDirection.ascending;

  int _totalCount = 0;

  // Sparse index over the filtered result: a null entry is a row the viewer has
  // not materialised yet. Rows are small immutable DTOs, never widgets or focus
  // nodes; the bounded page cache below is what grows with navigation.
  List<TaskItem?> _rows = const <TaskItem?>[];
  final Map<int, List<TaskItem>> _pages = <int, List<TaskItem>>{};
  final List<int> _pageUse = <int>[];
  final Set<int> _pagesInFlight = <int>{};
  String? _snapshot;
  int? _sampledAtMs;
  int? _selectedTaskId;
  bool _loading = false;
  bool _staleRetryUsed = false;
  ViewerFailure? _firstLoadError;
  ViewerFailure? _refreshFailure;
  String? _notice;

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

  /// Exact filtered row count reported by the CLI, not the loaded count.
  int get totalCount => _totalCount;

  int get rowCount => _totalCount;

  /// Rows currently held for display, including retained stale rows.
  int get loadedRowCount => _rows.where((row) => row != null).length;

  /// When the last successful first-page read arrived, in local milliseconds.
  int? get sampledAtMs => _sampledAtMs;

  bool get isLoading => _loading;

  bool get hasRows => _totalCount > 0;

  /// True while any confirmed rows are on screen (possibly stale).
  bool get hasConfirmedData => loadedRowCount > 0;

  /// Set only when the first load failed and there is nothing to show.
  ViewerFailure? get firstLoadError => _firstLoadError;

  /// Set when a refresh failed; the previous rows stay visible as stale.
  ViewerFailure? get refreshFailure => _refreshFailure;

  /// A non-fatal message such as a repeated snapshot invalidation.
  String? get notice => _notice;

  int? get selectedTaskId => _selectedTaskId;

  int get cachedPageCount => _pages.length;

  String? get snapshotToken => _snapshot;

  /// How many filter groups are active, for the collapsed Filters button.
  int get activeFilterCount =>
      (query.trim().isEmpty ? 0 : 1) +
      (scope == TaskScope.open ? 0 : 1) +
      (statuses.isEmpty ? 0 : 1) +
      (priorities.isEmpty ? 0 : 1) +
      (labels.isEmpty ? 0 : 1) +
      (readiness == TaskReadiness.any ? 0 : 1);

  TaskItem? itemAt(int index) {
    if (index < 0 || index >= _rows.length) {
      return null;
    }
    return _rows[index];
  }

  bool isRowReady(int index) => itemAt(index) != null;

  /// True while the page that owns [index] is still in the bounded cache.
  bool isPageCached(int index) =>
      index >= 0 && _pages.containsKey(index ~/ pageSize);

  /// Cached page indexes, least recently used first.
  List<int> get cachedPageIndexes => List<int>.unmodifiable(_pageUse);

  int? indexOfTask(int taskId) {
    for (var index = 0; index < _rows.length; index++) {
      if (_rows[index]?.id == taskId) {
        return index;
      }
    }
    return null;
  }

  TaskItem? get selectedItem {
    final id = _selectedTaskId;
    if (id == null) {
      return null;
    }
    final index = indexOfTask(id);
    return index == null ? null : _rows[index];
  }

  int? get selectedIndex {
    final id = _selectedTaskId;
    return id == null ? null : indexOfTask(id);
  }

  TaskQuery buildQuery({required int offset}) => TaskQuery(
    query: _query.trim(),
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
    // page so a changed list becomes visible as stale_snapshot.
    snapshot: offset == 0 ? null : _snapshot,
  );

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
    selectedTaskId: _selectedTaskId,
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
    _selectedTaskId = state.selectedTaskId;
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

  /// F5 and the Refresh button: same parameters, fresh rows.
  Future<void> refresh() => reload(retainSelection: true, keepStaleRows: true);

  /// Retry after a first-load failure.
  Future<void> retry() => reload(retainSelection: true);

  /// Reloads from offset zero, discarding cached pages.
  Future<void> reload({
    bool retainSelection = false,
    bool keepStaleRows = false,
  }) {
    _debounceTimer?.cancel();
    final generation = ++_generation;
    _cancelInFlight();
    _pages.clear();
    _pageUse.clear();
    _pagesInFlight.clear();
    _snapshot = null;
    _staleRetryUsed = false;
    _notice = null;
    _loading = true;
    final previousSelectionIndex = indexOfTask(_selectedTaskId ?? -1);
    if (!keepStaleRows) {
      _rows = const <TaskItem?>[];
      _totalCount = 0;
      _sampledAtMs = null;
    }
    _notify();
    return _loadOffsetZero(
      generation,
      retainSelection: retainSelection,
      previousSelectionIndex: previousSelectionIndex,
    );
  }

  void selectIndex(int? index) {
    _selectTask(index == null ? null : itemAt(index)?.id);
  }

  void selectTaskId(int? taskId) => _selectTask(taskId);

  void _selectTask(int? taskId) {
    if (_selectedTaskId == taskId) {
      return;
    }
    _selectedTaskId = taskId;
    _notify();
  }

  // ----------------------------------------------------------------- paging

  /// Makes the page that owns [index] available, prefetching near a boundary.
  Future<void> ensureRow(int index) async {
    if (index < 0 || index >= _totalCount) {
      return;
    }
    final pageIndex = index ~/ pageSize;
    final offset = pageIndex * pageSize;
    final pending = _loadPage(pageIndex);
    if (index - offset >= pageSize - prefetchRows &&
        offset + pageSize < _totalCount) {
      unawaited(_prefetchPage(pageIndex + 1));
    }
    await pending;
  }

  Future<void> _prefetchPage(int pageIndex) async {
    if (_pages.containsKey(pageIndex) || _pagesInFlight.contains(pageIndex)) {
      return;
    }
    await _loadPage(pageIndex);
  }

  Future<void> _loadPage(int pageIndex) async {
    if (_pages.containsKey(pageIndex) || _pagesInFlight.contains(pageIndex)) {
      _touchPage(pageIndex);
      return;
    }
    final generation = _generation;
    final offset = pageIndex * pageSize;
    _pagesInFlight.add(pageIndex);
    try {
      final page = await _reader.fetchTasks(
        projectId,
        buildQuery(offset: offset),
      );
      if (generation != _generation) {
        return;
      }
      _applyPage(page, pageIndex: pageIndex);
      _firstLoadError = null;
      _refreshFailure = null;
      _notify();
    } on ViewerCancelledFailure {
      return;
    } on ViewerFailure catch (failure) {
      if (generation != _generation) {
        return;
      }
      await _handleFailure(failure, generation);
    } finally {
      _pagesInFlight.remove(pageIndex);
    }
  }

  Future<void> _loadOffsetZero(
    int generation, {
    required bool retainSelection,
    required int? previousSelectionIndex,
  }) async {
    try {
      final page = await _reader.fetchTasks(projectId, buildQuery(offset: 0));
      if (generation != _generation) {
        return;
      }
      _resetRows();
      _applyPage(page, pageIndex: 0);
      _firstLoadError = null;
      _refreshFailure = null;
      _notice = null;
      _retainOrClearSelection(
        page,
        retainSelection: retainSelection,
        previousSelectionIndex: previousSelectionIndex,
      );
    } on ViewerCancelledFailure {
      return;
    } on ViewerFailure catch (failure) {
      if (generation != _generation) {
        return;
      }
      await _handleFailure(failure, generation);
    } finally {
      if (generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Snapshot invalidation: keep the stale rows, drop the cache, reload once.
  Future<void> _handleFailure(ViewerFailure failure, int generation) async {
    if (failure is ViewerCliErrorFailure && failure.isStaleSnapshot) {
      _pages.clear();
      _pageUse.clear();
      _snapshot = null;
      if (_staleRetryUsed) {
        _notice = 'Tasks are changing. Refresh to load the latest list.';
        _loading = false;
        _notify();
        return;
      }
      _staleRetryUsed = true;
      _loading = true;
      _notify();
      await _loadOffsetZero(
        generation,
        retainSelection: true,
        previousSelectionIndex: indexOfTask(_selectedTaskId ?? -1),
      );
      return;
    }
    if (hasConfirmedData) {
      // Keep the last confirmed rows visible and label them stale.
      _refreshFailure = failure;
    } else {
      _firstLoadError = failure;
      _rows = const <TaskItem?>[];
      _totalCount = 0;
    }
    _loading = false;
    _notify();
  }

  void _applyPage(TaskPage page, {required int pageIndex}) {
    if (_totalCount != page.totalCount) {
      _totalCount = page.totalCount;
      final resized = List<TaskItem?>.filled(_totalCount, null);
      final carriedRows = _rows;
      final limit = resized.length < carriedRows.length
          ? resized.length
          : carriedRows.length;
      for (var index = 0; index < limit; index++) {
        resized[index] = carriedRows[index];
      }
      _rows = resized;
    }
    final offset = pageIndex * pageSize;
    for (var index = 0; index < page.items.length; index++) {
      final target = offset + index;
      if (target >= _rows.length) {
        break;
      }
      _rows[target] = page.items[index];
    }
    _pages[pageIndex] = page.items;
    _touchPage(pageIndex);
    if (page.snapshot != null) {
      _snapshot = page.snapshot;
    }
    if (pageIndex == 0) {
      _sampledAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    _trimPages();
  }

  void _resetRows() {
    _rows = const <TaskItem?>[];
    _totalCount = 0;
    _sampledAtMs = null;
  }

  /// Clears a selection that provably left the result set.
  ///
  /// Only page zero is authoritative after a reload: a task the viewer reached
  /// on a later page keeps its detail until the user navigates, because
  /// dropping it from an unrelated page would be a guess.
  void _retainOrClearSelection(
    TaskPage page, {
    required bool retainSelection,
    required int? previousSelectionIndex,
  }) {
    final selected = _selectedTaskId;
    if (selected == null || retainSelection) {
      return;
    }
    if (previousSelectionIndex != null && previousSelectionIndex >= pageSize) {
      return;
    }
    final stillListed = page.items.any((item) => item.id == selected);
    if (!stillListed) {
      _selectedTaskId = null;
    }
  }

  void _touchPage(int pageIndex) {
    _pageUse.remove(pageIndex);
    _pageUse.add(pageIndex);
  }

  void _trimPages() {
    while (_pages.length > maxCachedPages) {
      final candidate = _pageUse.firstWhere(
        (pageIndex) => !_pageHoldsSelection(pageIndex),
        orElse: () => -1,
      );
      if (candidate < 0) {
        return;
      }
      _pages.remove(candidate);
      _pageUse.remove(candidate);
    }
  }

  bool _pageHoldsSelection(int pageIndex) {
    final id = _selectedTaskId;
    if (id == null) {
      return false;
    }
    final items = _pages[pageIndex];
    if (items == null) {
      return false;
    }
    return items.any((item) => item.id == id);
  }

  void _cancelInFlight() {
    final reader = _reader;
    if (reader is CancellableTaskReader) {
      reader.cancelScope('tasks');
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _cancelInFlight();
    super.dispose();
  }
}
