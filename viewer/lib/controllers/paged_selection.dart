/// Atomic, bounded selection and publication for the two paged workspace lists.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/models.dart';

const pagedSelectionSearchBudget = 10;

enum RetainReason { saved, other }

sealed class ListSelection<K> {
  const ListSelection();
  K? get id;
  bool get savedOrigin => switch (this) {
    NoSelection<K>() => false,
    Listed<K>(:final saved) => saved,
    Retained<K>(:final reason) => reason == RetainReason.saved,
  };
}

final class NoSelection<K> extends ListSelection<K> {
  const NoSelection();
  @override
  K? get id => null;
}

final class Listed<K> extends ListSelection<K> {
  const Listed(this.id, {this.saved = false});
  final bool saved;
  @override
  final K id;
}

final class Retained<K> extends ListSelection<K> {
  const Retained(this.id, this.reason);
  @override
  final K id;
  final RetainReason reason;
}

enum ReloadKind { restore, refilter, reorder, refresh }

enum RowLoadState { ready, failed, superseded }

final class RowLoad {
  const RowLoad.ready() : state = RowLoadState.ready, failure = null;
  const RowLoad.failed(this.failure) : state = RowLoadState.failed;
  const RowLoad.superseded() : state = RowLoadState.superseded, failure = null;
  final RowLoadState state;
  final ViewerFailure? failure;
}

final class ListFocus<K> {
  const ListFocus({this.ownsFocus = false, this.index, this.key});
  final bool ownsFocus;
  final int? index;
  final K? key;
}

final class SelectionPage<T> {
  const SelectionPage({
    required this.items,
    required this.total,
    required this.snapshot,
    required this.sampledAtMs,
    this.projectKey,
  });
  final List<T> items;
  final int total;
  final String? snapshot;
  final int sampledAtMs;
  final String? projectKey;
}

/// Frozen request parameters. Reader closures must capture values, not controls.
final class PagedSelectionSpec<T, K> {
  const PagedSelectionSpec({
    required this.filterKey,
    required this.sortKey,
    required this.direction,
    required this.emptySearch,
    required this.read,
    required this.membership,
  });
  final Object filterKey, sortKey, direction;
  final bool emptySearch;
  final Future<SelectionPage<T>> Function(int offset, String? token) read;
  final Future<SelectionPage<T>> Function(K id) membership;
}

final class PagedResult<T, K> {
  PagedResult(
    this.spec,
    this.total,
    this.snapshot,
    this.sampledAtMs,
    this._pages, {
    this.projectKey,
  });
  final String? projectKey;
  final PagedSelectionSpec<T, K> spec;
  final int total, sampledAtMs;
  final String? snapshot;
  final Map<int, List<T>> _pages;
  final List<int> _use = [];
  final Map<K, int> _index = {};
}

final class _Job<T, K> {
  _Job(this.spec, this.generation, this.userInitiated, this.hint);
  final PagedSelectionSpec<T, K> spec;
  final int generation;
  final bool userInitiated;
  final int? hint;
  final done = Completer<void>();
}

final class _PageRequest {
  _PageRequest(this.page, this.prefetch);
  final int page;
  bool prefetch;
  final done = Completer<RowLoad>();
  void complete(RowLoad result) {
    if (!done.isCompleted) done.complete(result);
  }
}

enum _Location { located, absent, present, unknown }

/// Selection lifecycle events. Reload/recovery and failed reads are identity
/// transitions; only evidence from a new publication can discharge a save.
enum _SelectionEvent {
  saved,
  reload,
  failedRead,
  commit,
  materialized,
  navigate,
  rowFocus,
  projectSwitch,
}

class PagedSelectionCore<T, K> extends ChangeNotifier {
  PagedSelectionCore({
    required this.keyOf,
    required this.cancelRead,
    required this.listLabel,
    required this.describe,
    this.pageSize = 100,
    this.maxCachedPages = 5,
    this.prefetchRows = 20,
  });
  final K Function(T) keyOf;
  final VoidCallback cancelRead;
  final String listLabel;
  final String Function(K, T?) describe;
  final int pageSize, maxCachedPages, prefetchRows;
  bool Function(K)? isSelectionPinned;
  ListFocus<K> Function()? listFocus;
  PagedResult<T, K>? _published;
  PagedSelectionSpec<T, K>? _requestedSpec;
  PagedResult<T, K>? get published => _published;
  ListSelection<K> _selection = NoSelection<K>();
  ListSelection<K> get selection => _selection;
  K? get selectedId => _selection.id;
  T? _selectedItem;
  T? get selectedItem => _selectedItem;

  int? get selectedIndex =>
      selectedId == null ? null : _published?._index[selectedId];
  int get totalCount => _published?.total ?? 0;
  int get loadedRowCount =>
      _published?._pages.values.fold<int>(0, (n, p) => n + p.length) ?? 0;
  String? get snapshotToken => _published?.snapshot;
  int? get sampledAtMs => _published?.sampledAtMs;
  int resultEpoch = 0, announcementSerial = 0;
  String? announcement, notice;
  ViewerFailure? firstLoadError, refreshFailure, pageFailure;
  int _generation = 0;
  bool _disposed = false, _running = false, _owedRefresh = false;
  _Job<T, K>? _nextJob, _activeJob;
  _PageRequest? _activePage;
  final List<_PageRequest> _queue = [];
  bool get isLoading => _nextJob != null || _activeJob != null;
  List<int> get cachedPageIndexes =>
      List.unmodifiable(_published?._use ?? <int>[]);
  int get cachedPageCount => _published?._pages.length ?? 0;
  int? indexOf(K id) => _published?._index[id];
  T? itemAt(int i) {
    if (i < 0 || i >= totalCount) return null;
    final page = _published?._pages[i ~/ pageSize];
    return page != null && i % pageSize < page.length
        ? page[i % pageSize]
        : null;
  }

  bool isPageCached(int i) =>
      i >= 0 && (_published?._pages.containsKey(i ~/ pageSize) ?? false);
  String? get retainedText {
    final s = _selection;
    if (s is! Retained<K>) return null;
    if (s.reason == RetainReason.saved && listLabel == 'Tasks') {
      return 'Saved task no longer matches these filters';
    }
    return '${describe(s.id, _selectedItem)} no longer matches these filters';
  }

  String? get unplacedLabel =>
      selectedId == null || selectedIndex != null || _published == null
      ? null
      : retainedText ??
            '${describe(selectedId as K, _selectedItem)} is not in the loaded rows';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _announce(String text) {
    announcement = text;
    announcementSerial++;
  }

  /// Exhaustive lifecycle transition table (TSK-049 C6).
  /// saved: capture origin for an editor/header save; list actions stay ordinary.
  /// reload/failedRead: preserve the entire state, including pending save origin.
  /// commit: found discharges; absent saved outranks focus; unknown preserves.
  /// materialized: a successful page publication discharges the saved origin.
  /// navigate/rowFocus: same identity preserves; another starts ordinary.
  /// projectSwitch: restored identity starts ordinary in the new list scope.
  void _transition(
    _SelectionEvent event, {
    K? id,
    _Location location = _Location.unknown,
    ReloadKind kind = ReloadKind.refresh,
    bool pinned = false,
    bool focused = false,
    K? fallback,
  }) {
    final current = _selection;
    final selected = current.id;
    ListSelection<K> ordinary(K? key) =>
        key == null ? NoSelection<K>() : Listed<K>(key);
    _selection = switch (event) {
      _SelectionEvent.saved =>
        id != selected ||
                selected == null ||
                (focused && !pinned && !current.savedOrigin)
            ? current
            : current is Retained<K>
            ? Retained<K>(selected, RetainReason.saved)
            : Listed<K>(selected, saved: true),
      _SelectionEvent.reload || _SelectionEvent.failedRead => current,
      _SelectionEvent.materialized =>
        selected != null && indexOf(selected) != null
            ? Listed<K>(selected)
            : current,
      _SelectionEvent.navigate ||
      _SelectionEvent.rowFocus => id == selected ? current : ordinary(id),
      _SelectionEvent.projectSwitch => ordinary(id),
      _SelectionEvent.commit =>
        selected == null
            ? current
            : switch (location) {
                _Location.located => Listed<K>(selected),
                _Location.absent when current.savedOrigin => Retained<K>(
                  selected,
                  RetainReason.saved,
                ),
                _Location.absent when pinned => Retained<K>(
                  selected,
                  RetainReason.other,
                ),
                _Location.absent when focused => ordinary(fallback),
                _Location.absent when kind == ReloadKind.refresh => Retained<K>(
                  selected,
                  RetainReason.other,
                ),
                _Location.absent => NoSelection<K>(),
                _Location.present => Listed<K>(
                  selected,
                  saved: current.savedOrigin,
                ),
                _Location.unknown when pinned => Listed<K>(
                  selected,
                  saved: current.savedOrigin,
                ),
                _Location.unknown => current,
              },
    };
  }

  void select(K? id, {bool projectSwitch = false, bool rowFocus = false}) {
    final previous = _selection;
    _transition(
      projectSwitch
          ? _SelectionEvent.projectSwitch
          : rowFocus
          ? _SelectionEvent.rowFocus
          : _SelectionEvent.navigate,
      id: id,
    );
    if (identical(previous, _selection)) return;
    _selectedItem = id == null
        ? null
        : (indexOf(id) == null ? null : itemAt(indexOf(id)!));
    _notify();
  }

  Future<void> reload(
    PagedSelectionSpec<T, K> spec, {
    bool userInitiated = true,
    K? savedId,
    int? restoreHint,
  }) {
    if (_disposed) return Future.value();
    _requestedSpec = spec;
    final focus = listFocus?.call() ?? ListFocus<K>();
    _transition(
      savedId == null ? _SelectionEvent.reload : _SelectionEvent.saved,
      id: savedId,
      pinned:
          selectedId != null &&
          (isSelectionPinned?.call(selectedId as K) ?? false),
      focused:
          focus.ownsFocus && focus.key == selectedId && focus.index != null,
    );
    _nextJob?.done.complete();
    final job = _Job<T, K>(spec, ++_generation, userInitiated, restoreHint);
    _nextJob = job;
    cancelRead();
    _notify();
    unawaited(_drain());
    return job.done.future;
  }

  bool _current(int gen) => !_disposed && gen == _generation;
  Future<void> _drain() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (!_disposed) {
        final job = _nextJob;
        if (job != null) {
          _nextJob = null;
          _activeJob = job;
          await _runJob(job);
          _activeJob = null;
          if (!job.done.isCompleted) job.done.complete();
          _notify();
          _consumeOwedRefresh(job);
          continue;
        }
        if (_queue.isEmpty) break;
        final request = _queue.removeAt(0);
        _activePage = request;
        await _runPage(request);
        _activePage = null;
      }
    } finally {
      _running = false;
    }
  }

  /// A newer job inherits the debt; otherwise exactly one follow-up runs, even
  /// when the job that owed it failed.
  void _consumeOwedRefresh(_Job<T, K> job) {
    if (!_owedRefresh || _nextJob != null || _disposed) return;
    _owedRefresh = false;
    unawaited(reload(_requestedSpec ?? job.spec, userInitiated: false));
  }

  ReloadKind kindFor(PagedSelectionSpec<T, K> spec) {
    final old = _published?.spec;
    if (old == null) return ReloadKind.restore;
    if (old.filterKey != spec.filterKey) return ReloadKind.refilter;
    if (old.sortKey != spec.sortKey || old.direction != spec.direction) {
      return ReloadKind.reorder;
    }
    return ReloadKind.refresh;
  }

  Future<void> _runJob(_Job<T, K> job) async {
    for (var attempt = 0; attempt < 2 && _current(job.generation); attempt++) {
      try {
        await _stage(job);
        return;
      } on ViewerCancelledFailure {
        return;
      } on ViewerFailure catch (failure) {
        if (!_current(job.generation)) return;
        _transition(_SelectionEvent.failedRead);
        if (failure is ViewerCliErrorFailure && failure.isStaleSnapshot) {
          if (attempt == 0) continue;
          notice = '$listLabel are changing. Refresh to load the latest list.';
          if (job.userInitiated) _announce(notice!);
        } else {
          if (_published == null) {
            firstLoadError = failure;
          } else {
            refreshFailure = failure;
          }
          if (job.userInitiated) {
            _announce('Refresh failed: ${failure.message}');
          }
        }
        return;
      }
    }
  }

  Future<void> _stage(_Job<T, K> job) async {
    final kind = kindFor(job.spec);
    final old = _published;
    final oldIndex = selectedIndex;
    int? anchor = switch (kind) {
      ReloadKind.restore => job.hint,
      ReloadKind.refresh => oldIndex,
      ReloadKind.reorder
          when old?.spec.sortKey == job.spec.sortKey && oldIndex != null =>
        old!.total - 1 - oldIndex,
      _ => null,
    };
    final anchorPage = (anchor ?? 0) ~/ pageSize;
    final pages = <int, List<T>>{};
    var first = await job.spec.read(anchorPage * pageSize, null);
    if (!_current(job.generation)) return;
    final total = first.total, token = first.snapshot;
    pages[anchorPage] = first.items;
    int? locate() {
      final target = selectedId;
      if (target == null) return null;
      for (final entry in pages.entries) {
        final i = entry.value.indexWhere((t) => keyOf(t) == target);
        if (i >= 0) return entry.key * pageSize + i;
      }
      return null;
    }

    final count = (total + pageSize - 1) ~/ pageSize;
    var reads = 1;
    K? membershipId;
    bool? member;
    var outcome = _Location.unknown;
    final order = <int>[];
    void add(int p) {
      if (p >= 0 &&
          p < count &&
          !pages.containsKey(p) &&
          !order.contains(p) &&
          order.length < pagedSelectionSearchBudget) {
        order.add(p);
      }
    }

    if (kind == ReloadKind.refresh || kind == ReloadKind.restore) {
      add(0);
      add(count - 1);
    }
    // The old anchor can lie beyond a result shortened by an external write.
    // Its nearest valid page is still first in distance order. Only construct
    // enough candidates to spend the read budget, even for very large lists.
    final center = count == 0 ? 0 : anchorPage.clamp(0, count - 1);
    for (
      var d = 0;
      d <= count && order.length < pagedSelectionSearchBudget;
      d++
    ) {
      add(center - d);
      add(center + d);
    }
    while (selectedId != null) {
      if (locate() != null) {
        outcome = _Location.located;
        break;
      }
      if (pages.keys.where((p) => p < count).length >= count) {
        outcome = _Location.absent;
        break;
      }
      if (kind != ReloadKind.reorder &&
          job.spec.emptySearch &&
          member == null) {
        membershipId = selectedId;
        final membership = await job.spec.membership(membershipId as K);
        if (!_current(job.generation)) return;
        member = membership.items.any((t) => keyOf(t) == membershipId);
        continue;
      }
      if (member == false && membershipId == selectedId) {
        outcome = _Location.absent;
        break;
      }
      outcome = member == true && membershipId == selectedId
          ? _Location.present
          : _Location.unknown;
      if (kind == ReloadKind.refilter || reads >= pagedSelectionSearchBudget) {
        break;
      }
      final remaining = order.where((p) => !pages.containsKey(p));
      if (remaining.isEmpty) break;
      final next = remaining.first;
      final page = await job.spec.read(next * pageSize, token);
      if (!_current(job.generation)) return;
      pages[next] = page.items;
      reads++;
    }
    var located = locate();
    var id = selectedId;
    var focus = listFocus?.call() ?? ListFocus<K>();
    var focused =
        id != null && focus.ownsFocus && focus.key == id && focus.index != null;
    var fallback = total == 0
        ? null
        : kind == ReloadKind.refilter
        ? 0
        : (focus.index ?? oldIndex ?? 0).clamp(0, total - 1);
    if (id != null &&
        located == null &&
        focused &&
        fallback != null &&
        !pages.containsKey(fallback ~/ pageSize)) {
      final page = await job.spec.read(
        (fallback ~/ pageSize) * pageSize,
        token,
      );
      if (!_current(job.generation)) return;
      pages[fallback ~/ pageSize] = page.items;
      located = locate();
      // Selection can change while the one extra focus-page read is pending.
      // Evidence and focus for the earlier target must never overwrite it.
      if (id != selectedId) {
        id = selectedId;
        outcome = pages.keys.where((p) => p < count).length >= count
            ? _Location.absent
            : membershipId == id && member != null
            ? (member ? _Location.present : _Location.absent)
            : _Location.unknown;
        focus = listFocus?.call() ?? ListFocus<K>();
        focused =
            id != null &&
            focus.ownsFocus &&
            focus.key == id &&
            focus.index != null;
        fallback = total == 0
            ? null
            : kind == ReloadKind.refilter
            ? 0
            : (focus.index ?? oldIndex ?? 0).clamp(0, total - 1);
      }
    }
    final pinned = id != null && (isSelectionPinned?.call(id) ?? false);
    if (located != null) outcome = _Location.located;
    final before = retainedText;
    final fallbackRow = fallback == null
        ? null
        : pages[fallback ~/ pageSize]?.elementAtOrNull(fallback % pageSize);
    _transition(
      _SelectionEvent.commit,
      location: outcome,
      kind: kind,
      pinned: pinned,
      focused: focused,
      fallback: fallbackRow == null ? null : keyOf(fallbackRow),
    );
    final result = PagedResult<T, K>(
      job.spec,
      total,
      token,
      first.sampledAtMs,
      {},
      projectKey: first.projectKey,
    );
    // Keep selected/fallback and first page, then nearest staged pages.
    int? selectionPage;
    for (final entry in pages.entries) {
      if (entry.value.any((t) => keyOf(t) == selectedId)) {
        selectionPage = entry.key;
      }
    }
    final priority = <int>{
      ?selectionPage,
      anchorPage,
      if (pages.containsKey(0)) 0,
      ...pages.keys.toList()..sort(
        (a, b) => (a - anchorPage).abs().compareTo((b - anchorPage).abs()),
      ),
    };
    for (final p in priority.take(maxCachedPages)) {
      result._pages[p] = pages[p]!;
      result._use.add(p);
    }
    _published = result;
    _reindex();
    if (selectedId == null) _selectedItem = null;
    resultEpoch++;
    firstLoadError = null;
    refreshFailure = null;
    pageFailure = null;
    notice = null;
    for (final request in _queue) {
      request.complete(const RowLoad.superseded());
    }
    _queue.clear();
    if (job.userInitiated && retainedText != null && retainedText != before) {
      _announce(retainedText!);
    }
    _notify();
    _prefetchNear(selectedIndex);
  }

  void _reindex() {
    final p = _published;
    if (p == null) return;
    p._index.clear();
    for (final entry in p._pages.entries) {
      for (var i = 0; i < entry.value.length; i++) {
        final row = entry.value[i];
        final id = keyOf(row);
        p._index[id] = entry.key * pageSize + i;
        if (id == selectedId) _selectedItem = row;
      }
    }
  }

  void _touch(int page) {
    final use = _published!._use;
    use.remove(page);
    use.add(page);
  }

  void _trim() {
    final p = _published!;
    while (p._pages.length > maxCachedPages) {
      final remove = p._use.firstWhere(
        (n) => n != (selectedIndex == null ? -1 : selectedIndex! ~/ pageSize),
      );
      p._use.remove(remove);
      p._pages.remove(remove);
    }
    _reindex();
  }

  Future<RowLoad> ensureRow(int index) {
    if (_disposed || index < 0 || index >= totalCount) {
      return Future.value(const RowLoad.superseded());
    }
    final result = _enqueue(index ~/ pageSize, false);
    unawaited(
      result.then((r) {
        if (r.state == RowLoadState.ready) _prefetchNear(index);
      }),
    );
    return result;
  }

  Future<RowLoad> _enqueue(int page, bool prefetch) {
    if (_published?._pages.containsKey(page) ?? false) {
      _touch(page);
      return Future.value(const RowLoad.ready());
    }
    if (_activePage?.page == page) {
      if (!prefetch) _activePage!.prefetch = false;
      return _activePage!.done.future;
    }
    for (final queued in _queue.toList()) {
      if (queued.page == page) {
        if (!prefetch) queued.prefetch = false;
        return queued.done.future;
      }
      if (!prefetch) {
        queued.complete(const RowLoad.superseded());
        _queue.remove(queued);
      }
    }
    final request = _PageRequest(page, prefetch);
    _queue.add(request);
    unawaited(_drain());
    return request.done.future;
  }

  void _prefetchNear(int? index) {
    if (index == null || prefetchRows <= 0) return;
    final p = index ~/ pageSize;
    final distance = prefetchRows.clamp(0, pageSize ~/ 2);
    if (index % pageSize >= pageSize - distance &&
        (p + 1) * pageSize < totalCount) {
      unawaited(_enqueue(p + 1, true));
    } else if (index % pageSize < distance && p > 0) {
      unawaited(_enqueue(p - 1, true));
    }
  }

  Future<void> _runPage(_PageRequest request) async {
    final p = _published;
    if (p == null || request.page * pageSize >= p.total) {
      request.complete(const RowLoad.superseded());
      return;
    }
    final gen = _generation;
    try {
      final page = await p.spec.read(request.page * pageSize, p.snapshot);
      if (!_current(gen)) {
        _requeue(request);
        return;
      }
      p._pages[request.page] = page.items;
      _touch(request.page);
      _trim();
      _transition(_SelectionEvent.materialized);
      pageFailure = null;
      _notify();
      request.complete(const RowLoad.ready());
    } on ViewerCancelledFailure {
      if (_disposed) {
        request.complete(const RowLoad.superseded());
      } else {
        _requeue(request);
      }
    } on ViewerFailure catch (failure) {
      if (!_current(gen)) {
        _requeue(request);
        return;
      }
      _transition(_SelectionEvent.failedRead);
      pageFailure = failure;
      request.complete(RowLoad.failed(failure));
      _notify();
      if (failure is ViewerCliErrorFailure && failure.isStaleSnapshot) {
        unawaited(reload(_requestedSpec ?? p.spec, userInitiated: false));
      }
    }
  }

  void _requeue(_PageRequest r) {
    if (!_disposed && !r.done.isCompleted) {
      _queue.insert(0, r);
    } else {
      r.complete(const RowLoad.superseded());
    }
  }

  /// Attachment-only writes never change membership, epoch or token.
  void patch(T Function(T) transform, {bool needsRefresh = false}) {
    if (_disposed) return;
    if (isLoading) {
      _owedRefresh = true;
      return;
    }
    final p = _published;
    if (p == null) return;
    if (needsRefresh) {
      unawaited(reload(_requestedSpec ?? p.spec, userInitiated: false));
      return;
    }
    _generation++;
    cancelRead();
    for (final n in p._pages.keys.toList()) {
      p._pages[n] = p._pages[n]!.map(transform).toList();
    }
    if (_selectedItem != null) _selectedItem = transform(_selectedItem as T);
    _reindex();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    cancelRead();
    _nextJob?.done.complete();
    _nextJob = null;
    for (final r in [..._queue, ?_activePage]) {
      r.complete(const RowLoad.superseded());
    }
    _queue.clear();
    super.dispose();
  }
}
