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
    this.initialState = ProjectStateFilter.hasOpen,
    this.initialSort = ProjectSort.lastWrite,
    this.initialDirection = SortDirection.descending,
  }) : // Private field, so an initializing formal cannot name the parameter.
       // ignore: prefer_initializing_formals
       _reader = reader {
    _core.addListener(_notify);
  }

  final ProjectReader _reader;
  final Duration debounce;
  final int pageSize;
  final int maxCachedPages;
  final int prefetchRows;
  final ProjectStateFilter initialState;
  final ProjectSort initialSort;
  final SortDirection initialDirection;

  Timer? _debounceTimer;
  bool _disposed = false;

  String _query = '';
  late ProjectStateFilter _stateFilter = initialState;
  late ProjectSort _sort = initialSort;
  late SortDirection _direction = initialDirection;

  late final _core = PagedSelectionCore<ProjectItem, String>(
    keyOf: (item) => item.projectId,
    cancelRead: _cancelInFlight,
    listLabel: 'Projects',
    describe: (id, item) => 'Selected project ${item?.name ?? id}',
    pageSize: pageSize,
    maxCachedPages: maxCachedPages,
    prefetchRows: prefetchRows,
  );
  bool Function(String)? get isSelectionPinned => _core.isSelectionPinned;
  set isSelectionPinned(bool Function(String)? probe) =>
      _core.isSelectionPinned = probe;
  ListFocus<String> Function()? get listFocus => _core.listFocus;
  set listFocus(ListFocus<String> Function()? probe) => _core.listFocus = probe;
  ListSelection<String> get selection => _core.selection;
  ViewerFailure? get pageFailure => _core.pageFailure;
  String? get retainedText => _core.retainedText;
  String? get unplacedLabel => _core.unplacedLabel;
  int get announcementSerial => _core.announcementSerial;
  String? get announcement => _core.announcement;
  // ------------------------------------------------------------- parameters

  String get query => _query;
  ProjectStateFilter get stateFilter => _stateFilter;
  ProjectSort get sort => _sort;
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
  String? get selectedProjectId => _core.selectedId;
  int get cachedPageCount => _core.cachedPageCount;
  String? get snapshotToken => _core.snapshotToken;
  ProjectItem? itemAt(int index) => _core.itemAt(index);
  bool isRowReady(int index) => itemAt(index) != null;
  bool isPageCached(int index) => _core.isPageCached(index);
  List<int> get cachedPageIndexes => _core.cachedPageIndexes;
  int? indexOfProject(String id) => _core.indexOf(id);
  ProjectItem? get selectedItem => _core.selectedItem;
  int? get selectedIndex => _core.selectedIndex;

  ProjectQuery buildQuery({required int offset}) => ProjectQuery(
    query: _query,
    state: _stateFilter,
    sort: _sort,
    direction: _direction,
    offset: offset,
    limit: pageSize,
    // Offset zero always recounts; later pages reuse the token from the first
    // page so a changed catalog becomes visible as stalesnapshotToken.
    snapshot: offset == 0 ? null : snapshotToken,
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

  PagedSelectionSpec<ProjectItem, String> _spec() {
    final q = buildQuery(offset: 0);
    Future<SelectionPage<ProjectItem>> read(
      int offset,
      String? token,
      String query,
    ) async {
      final page = await _reader.fetchProjects(
        q.copyWith(
          query: query,
          offset: offset,
          snapshot: token,
          clearSnapshot: token == null,
        ),
      );
      return SelectionPage(
        items: page.items,
        total: page.totalCount,
        snapshot: page.snapshot,
        sampledAtMs: page.items.fold<int>(
          0,
          (n, p) => p.sampledAtMs > n ? p.sampledAtMs : n,
        ),
      );
    }

    return PagedSelectionSpec(
      filterKey: jsonEncode([q.query, q.state.wireValue]),
      sortKey: q.sort,
      direction: q.direction,
      emptySearch: q.query.trim().isEmpty,
      read: (offset, token) => read(offset, token, q.query),
      membership: (id) => read(0, null, id),
    );
  }

  Future<void> refresh({bool userInitiated = true, String? savedId}) {
    _debounceTimer?.cancel();
    return _core.reload(
      _spec(),
      userInitiated: userInitiated,
      savedId: savedId,
    );
  }

  Future<void> retry() => refresh();
  Future<void> reload() => refresh();
  void selectIndex(int? index) => _core.select(
    index == null ? null : itemAt(index)?.projectId,
    rowFocus: true,
  );
  void selectProjectId(String? id) => _core.select(id);
  Future<RowLoad> ensureRow(int index) => _core.ensureRow(index);
  void _cancelInFlight() {
    final reader = _reader;
    if (reader is CancellableProjectReader) reader.cancelScope('projects');
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
