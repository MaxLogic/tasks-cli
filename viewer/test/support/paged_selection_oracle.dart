/// Reference plan for one replacement job, derived from the TSK-049 design.
///
/// Generated tests feed it store ordering only. It never reads production
/// rows, so a page or selection defect cannot agree with itself here.
library;

import 'package:tasks_viewer/controllers/paged_selection.dart';

const oraclePageSize = 100;
const oracleEdgeRows = 20;
const oracleCachedPages = 5;

enum SelectionState { none, listed, saved, other }

class ExpectedSelection {
  const ExpectedSelection(this.id, this.state, this.index);
  const ExpectedSelection.none() : this(null, SelectionState.none, null);
  final Object? id;
  final SelectionState state;
  final int? index;
  @override
  String toString() => 'ExpectedSelection($id, ${state.name}, $index)';
}

class JobFacts {
  const JobFacts({
    required this.kind,
    required this.rows,
    required this.id,
    required this.state,
    required this.oldIndex,
    required this.oldTotal,
    required this.sameSort,
    required this.emptySearch,
    this.focused = false,
    this.focusIndex,
    this.pinned = false,
    this.savedId,
    this.hint,
  });
  final ReloadKind kind;
  final List<Object> rows;
  final Object? id;
  final SelectionState state;
  final int? oldIndex, oldTotal, focusIndex, hint;
  final bool sameSort, emptySearch, focused, pinned;
  final Object? savedId;
}

class PlannedJob {
  const PlannedJob(this.pageReads, this.membershipReads, this.selection);

  /// Search, focus and neighbour pages, each counted once.
  final int pageReads;
  final int membershipReads;
  final ExpectedSelection selection;
}

enum _Outcome { located, absent, present, unknown }

/// Pages a commit keeps: selection, anchor, first page, then nearest staged.
Set<int> _cachedPages(List<int> read, int? selectionPage, int anchorPage) {
  final near = read.toList()
    ..sort((a, b) => (a - anchorPage).abs().compareTo((b - anchorPage).abs()));
  return <int>{
    ?selectionPage,
    anchorPage,
    if (read.contains(0)) 0,
    ...near,
  }.take(oracleCachedPages).toSet();
}

/// The neighbour page a located row asks for, if it sits near a page edge.
int? neighbourPage(int index, int total) {
  final page = index ~/ oraclePageSize;
  final offset = index % oraclePageSize;
  if (offset >= oraclePageSize - oracleEdgeRows &&
      (page + 1) * oraclePageSize < total) {
    return page + 1;
  }
  return offset < oracleEdgeRows && page > 0 ? page - 1 : null;
}

PlannedJob planJob(JobFacts f) {
  final total = f.rows.length;
  final count = (total + oraclePageSize - 1) ~/ oraclePageSize;
  final index = f.id == null ? -1 : f.rows.indexOf(f.id!);
  final anchor = switch (f.kind) {
    ReloadKind.refresh => f.oldIndex,
    ReloadKind.restore => f.hint,
    ReloadKind.reorder when f.sameSort && f.oldIndex != null =>
      f.oldTotal! - 1 - f.oldIndex!,
    _ => null,
  };
  final anchorPage = (anchor ?? 0) ~/ oraclePageSize;
  final read = <int>[anchorPage];
  var pageReads = 1, membershipReads = 0;
  bool found() => index >= 0 && read.contains(index ~/ oraclePageSize);
  bool complete() => read.where((p) => p < count).length >= count;
  _Outcome? outcome;
  if (f.id == null) {
    outcome = _Outcome.unknown;
  } else if (found()) {
    outcome = _Outcome.located;
  } else if (complete()) {
    outcome = _Outcome.absent;
  } else if (f.kind == ReloadKind.refilter) {
    if (f.emptySearch) {
      membershipReads = 1;
      outcome = index >= 0 ? _Outcome.present : _Outcome.absent;
    } else {
      outcome = _Outcome.unknown;
    }
  } else {
    if (f.kind != ReloadKind.reorder && f.emptySearch) {
      membershipReads = 1;
      if (index < 0) outcome = _Outcome.absent;
    }
    if (outcome == null) {
      final order = <int>[];
      void add(int page) {
        if (page >= 0 &&
            page < count &&
            !read.contains(page) &&
            !order.contains(page)) {
          order.add(page);
        }
      }

      if (f.kind != ReloadKind.reorder) {
        add(0);
        add(count - 1);
      }
      final center = anchorPage.clamp(0, count - 1);
      for (var d = 0; d <= count; d++) {
        add(center - d);
        add(center + d);
      }
      for (final page in order) {
        if (pageReads >= pagedSelectionSearchBudget || found()) break;
        read.add(page);
        pageReads++;
      }
      outcome = found()
          ? _Outcome.located
          : complete()
          ? _Outcome.absent
          : membershipReads == 1
          ? _Outcome.present
          : _Outcome.unknown;
    }
  }
  final fallback = total == 0
      ? null
      : f.kind == ReloadKind.refilter
      ? 0
      : (f.focusIndex ?? f.oldIndex ?? 0).clamp(0, total - 1);
  if (f.id != null &&
      outcome != _Outcome.located &&
      f.focused &&
      fallback != null &&
      !read.contains(fallback ~/ oraclePageSize)) {
    read.add(fallback ~/ oraclePageSize);
    pageReads++;
    if (found()) outcome = _Outcome.located;
  }
  ExpectedSelection listed(Object id) {
    final i = f.rows.indexOf(id);
    final page = i ~/ oraclePageSize;
    return ExpectedSelection(
      id,
      SelectionState.listed,
      i >= 0 && read.contains(page) ? i : null,
    );
  }

  final ExpectedSelection selection;
  final retained = ExpectedSelection(f.id, f.state, null);
  if (f.id == null) {
    selection = const ExpectedSelection.none();
  } else if (outcome == _Outcome.located) {
    selection = listed(f.id!);
  } else if (outcome == _Outcome.absent &&
      (f.state == SelectionState.saved || f.savedId == f.id)) {
    // The saved detail contract precedes row-focus fallback on every recovery.
    selection = ExpectedSelection(f.id, SelectionState.saved, null);
  } else if (f.pinned) {
    selection = outcome == _Outcome.absent
        ? ExpectedSelection(
            f.id,
            f.state == SelectionState.saved || f.savedId == f.id
                ? SelectionState.saved
                : SelectionState.other,
            null,
          )
        : ExpectedSelection(f.id, SelectionState.listed, null);
  } else if (outcome == _Outcome.absent && f.focused) {
    selection = fallback == null
        ? const ExpectedSelection.none()
        : listed(f.rows[fallback]);
  } else if (outcome == _Outcome.absent) {
    if (f.state == SelectionState.saved) {
      selection = retained;
    } else if (f.savedId == f.id) {
      selection = ExpectedSelection(f.id, SelectionState.saved, null);
    } else if (f.kind == ReloadKind.refresh) {
      selection = ExpectedSelection(f.id, SelectionState.other, null);
    } else {
      selection = const ExpectedSelection.none();
    }
  } else if (outcome == _Outcome.present) {
    selection = ExpectedSelection(f.id, SelectionState.listed, null);
  } else {
    selection = retained;
  }
  final located = selection.index;
  if (located != null) {
    final neighbour = neighbourPage(located, total);
    final cached = _cachedPages(read, located ~/ oraclePageSize, anchorPage);
    if (neighbour != null && !cached.contains(neighbour)) pageReads++;
  }
  return PlannedJob(pageReads, membershipReads, selection);
}
