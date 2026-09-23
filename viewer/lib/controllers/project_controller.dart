/// Projects as a searchable, sorted, paged catalog (viewer/spec.md sections 4.2
/// and 5, viewer/design.md sections 4 and 6).
///
/// The controller owns the request parameters, the debounce, the page cache and
/// every failure state so the pane can stay a rendering layer. Two rules make
/// the asynchronous reads safe:
/// * each reload bumps a generation, and a response from an older generation is
///   dropped before it can touch rows, counts or the selection;
/// * a superseded read is cancelled, so it cannot deliver a late result at all.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Rows requested per CLI page.
const int projectPageSize = 100;

/// Pages retained per project query (viewer/spec.md section 5).
const int projectMaxCachedPages = 5;

/// Search keystrokes settle for this long before a read is issued.
const Duration projectSearchDebounce = Duration(milliseconds: 250);

/// Distance to a page boundary that triggers a prefetch.
const int projectPrefetchRows = 20;

/// Projects list state: parameters, paged rows, selection and failures.
class ProjectController extends ChangeNotifier {
  ProjectController({
    required ProjectReader reader,
    this.debounce = projectSearchDebounce,
    this.pageSize = projectPageSize,
    this.maxCachedPages = projectMaxCachedPages,
    this.prefetchRows = projectPrefetchRows,
  }) : // Private field, so an initializing formal cannot name the parameter.
       // ignore: prefer_initializing_formals
       _reader = reader;

  final ProjectReader _reader;
  final Duration debounce;
  final int pageSize;
  final int maxCachedPages;
  final int prefetchRows;

  Timer? _debounceTimer;
  int _generation = 0;
  bool _disposed = false;

  String _query = '';
  ProjectStateFilter _stateFilter = ProjectStateFilter.all;
  ProjectSort _sort = ProjectSort.name;
  SortDirection _direction = SortDirection.ascending;

  int _totalCount = 0;

  // Sparse index over the filtered catalog: a null entry is a row the viewer
  // has not materialised yet. These are small immutable DTOs, never widgets or
  // focus nodes; project rows are held so that arrow navigation stays O(1)
  // once a row has been seen. The bounded cache below is what grows with the
  // user's navigation, and it is what the renderer reads pages from.
  List<ProjectItem?> _rows = const <ProjectItem?>[];
  final Map<int, List<ProjectItem>> _pages = <int, List<ProjectItem>>{};
  final List<int> _pageUse = <int>[];
  final Set<int> _pagesInFlight = <int>{};
  String? _snapshot;
  int? _sampledAtMs;
  String? _selectedProjectId;
  bool _loading = false;
  bool _staleRetryUsed = false;
  ViewerFailure? _firstLoadError;
  ViewerFailure? _refreshFailure;
  String? _notice;

  // ------------------------------------------------------------- parameters

  String get query => _query;
  ProjectStateFilter get stateFilter => _stateFilter;
  ProjectSort get sort => _sort;
  SortDirection get direction => _direction;

  /// Exact filtered row count reported by the CLI, not the loaded count.
  int get totalCount => _totalCount;

  int get rowCount => _totalCount;

  /// Rows currently held for display, including retained stale rows.
  int get loadedRowCount => _rows.where((row) => row != null).length;

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

  String? get selectedProjectId => _selectedProjectId;

  int get cachedPageCount => _pages.length;

  String? get snapshotToken => _snapshot;

  ProjectItem? itemAt(int index) {
    if (index < 0 || index >= _rows.length) {
      return null;
    }
    return _rows[index];
  }

  bool isRowReady(int index) => itemAt(index) != null;

  /// True while the page that owns [index] is still in the bounded cache.
  ///
  /// Section 5 caps retained pages at five and never evicts the page that
  /// holds the focused row.
  bool isPageCached(int index) =>
      index >= 0 && _pages.containsKey(index ~/ pageSize);

  /// Cached page indexes, least recently used first.
  List<int> get cachedPageIndexes => List<int>.unmodifiable(_pageUse);

  int? indexOfProject(String projectId) {
    for (var index = 0; index < _rows.length; index++) {
      if (_rows[index]?.projectId == projectId) {
        return index;
      }
    }
    return null;
  }

  ProjectItem? get selectedItem {
    final id = _selectedProjectId;
    if (id == null) {
      return null;
    }
    final index = indexOfProject(id);
    return index == null ? null : _rows[index];
  }

  int? get selectedIndex {
    final id = _selectedProjectId;
    return id == null ? null : indexOfProject(id);
  }

  ProjectQuery buildQuery({required int offset}) => ProjectQuery(
    query: _query,
    state: _stateFilter,
    sort: _sort,
    direction: _direction,
    offset: offset,
    limit: pageSize,
    // Offset zero always recounts; later pages reuse the token from the first
    // page so a changed catalog becomes visible as stale_snapshot.
    snapshot: offset == 0 ? null : _snapshot,
  );

  // -------------------------------------------------------------- controls

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

  void setState(ProjectStateFilter value) {
    if (_stateFilter == value) {
      return;
    }
    _stateFilter = value;
    _notify();
    unawaited(reload());
  }

  void setSort(ProjectSort value) {
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

  /// Clear filters resets query and state, preserving the chosen sort.
  void clearFilters() {
    _debounceTimer?.cancel();
    if (_query.isEmpty && _stateFilter == ProjectStateFilter.all) {
      return;
    }
    _query = '';
    _stateFilter = ProjectStateFilter.all;
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
    if (!keepStaleRows) {
      _rows = const <ProjectItem?>[];
      _totalCount = 0;
      _sampledAtMs = null;
    }
    _notify();
    return _loadOffsetZero(generation, retainSelection: retainSelection);
  }

  void selectIndex(int? index) {
    _selectProject(index == null ? null : itemAt(index)?.projectId);
  }

  void selectProjectId(String? projectId) => _selectProject(projectId);

  void _selectProject(String? projectId) {
    if (_selectedProjectId == projectId) {
      return;
    }
    _selectedProjectId = projectId;
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
      final page = await _reader.fetchProjects(buildQuery(offset: offset));
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
  }) async {
    try {
      final page = await _reader.fetchProjects(buildQuery(offset: 0));
      if (generation != _generation) {
        return;
      }
      _resetRows();
      _applyPage(page, pageIndex: 0);
      _firstLoadError = null;
      _refreshFailure = null;
      _notice = null;
      _retainOrClearSelection(page, retainSelection: retainSelection);
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
        _notice = 'Projects are changing. Refresh to load the latest list.';
        _loading = false;
        _notify();
        return;
      }
      _staleRetryUsed = true;
      _loading = true;
      _notify();
      await _loadOffsetZero(generation, retainSelection: true);
      return;
    }
    if (hasConfirmedData) {
      // Keep the last confirmed rows visible and label them stale.
      _refreshFailure = failure;
    } else {
      _firstLoadError = failure;
      _rows = const <ProjectItem?>[];
      _totalCount = 0;
    }
    _loading = false;
    _notify();
  }

  void _applyPage(ProjectPage page, {required int pageIndex}) {
    if (_totalCount != page.totalCount) {
      _totalCount = page.totalCount;
      final resized = List<ProjectItem?>.filled(_totalCount, null);
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
    for (final item in page.items) {
      final sampled = item.sampledAtMs;
      if (_sampledAtMs == null || sampled > _sampledAtMs!) {
        _sampledAtMs = sampled;
      }
    }
    _trimPages();
  }

  void _resetRows() {
    _rows = const <ProjectItem?>[];
    _totalCount = 0;
    _sampledAtMs = null;
  }

  void _retainOrClearSelection(
    ProjectPage page, {
    required bool retainSelection,
  }) {
    final selected = _selectedProjectId;
    if (selected == null) {
      return;
    }
    if (retainSelection) {
      return;
    }
    final stillListed = page.items.any((item) => item.projectId == selected);
    if (!stillListed) {
      _selectedProjectId = null;
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
    final id = _selectedProjectId;
    if (id == null) {
      return false;
    }
    final items = _pages[pageIndex];
    if (items == null) {
      return false;
    }
    return items.any((item) => item.projectId == id);
  }

  void _cancelInFlight() {
    final reader = _reader;
    if (reader is CancellableProjectReader) {
      reader.cancelScope('projects');
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
