/// One selected task: full detail, dependencies, history, project rules and
/// Find in body (viewer/spec.md section 6, viewer/design.md section 7).
///
/// The controller owns every read the details pane performs, so the pane stays
/// a rendering layer:
/// * arrow-navigation selections settle for [taskDetailDebounce] before a read
///   starts, while Enter and a dependency activation load immediately;
/// * each load bumps a generation, so a late answer for an older selection can
///   never replace the current one;
/// * history and rules never load for a task the user has not opened, and a
///   full history snapshot loads only for the event the user selects.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// How long arrow navigation settles before the detail read starts.
const Duration taskDetailDebounce = Duration(milliseconds: 150);

/// History events requested per read (viewer/spec.md section 6).
const int taskHistoryPageSize = 100;

/// The four read-only tabs of the details pane.
enum TaskDetailTab {
  details('Details', 'Details'),
  dependencies('Dependencies', 'Dependencies'),
  history('History', 'History'),
  rules('Project rules', 'Rules');

  const TaskDetailTab(this.label, this.commandSuffix);

  final String label;

  /// Suffix of the `details.tab*` command id that activates this tab.
  final String commandSuffix;

  static TaskDetailTab? fromCommandSuffix(String suffix) {
    for (final tab in values) {
      if (tab.commandSuffix == suffix) {
        return tab;
      }
    }
    return null;
  }
}

/// Selected task state: detail, tabs, find matches, history and dependency
/// back navigation.
class TaskDetailController extends ChangeNotifier {
  TaskDetailController({
    required this.projectId,
    required TaskDetailReader reader,
    this.debounce = taskDetailDebounce,
    this.historyPageSize = taskHistoryPageSize,
  }) : // Private field, so an initializing formal cannot name the parameter.
       // ignore: prefer_initializing_formals
       _reader = reader;

  /// Project UUID every read is routed by; never the working directory.
  final String projectId;

  final TaskDetailReader _reader;
  final Duration debounce;
  final int historyPageSize;

  Timer? _debounceTimer;
  int _generation = 0;
  int _eventGeneration = 0;
  bool _disposed = false;

  int? _taskId;
  TaskDetail? _detail;
  bool _loading = false;
  ViewerFailure? _loadError;
  TaskDetailTab _tab = TaskDetailTab.details;

  String _findText = '';
  List<int> _matches = const <int>[];
  int _matchIndex = -1;
  String? _findNotice;

  final List<HistoryEvent> _history = <HistoryEvent>[];
  bool _historyLoading = false;
  bool _historyLoaded = false;
  ViewerFailure? _historyError;
  int? _historyNextAfter;
  bool _historyHasMore = false;
  int? _openedEventId;
  String? _eventSnapshot;
  bool _eventLoading = false;
  ViewerFailure? _eventError;

  final List<int> _backStack = <int>[];

  // --------------------------------------------------------------- selection

  /// The task the user last selected, including while its detail loads.
  int? get taskId => _taskId;

  /// Canonical form of [taskId], or null when nothing is selected.
  String? get canonicalTaskId {
    final id = _taskId;
    return id == null ? null : viewerCanonicalTaskId(id);
  }

  TaskDetail? get detail => _detail;

  bool get hasDetail => _detail != null;

  bool get isLoading => _loading;

  ViewerFailure? get loadError => _loadError;

  TaskDetailTab get tab => _tab;

  /// True while the loaded detail still belongs to [taskId].
  bool get detailMatchesSelection => _detail?.id == _taskId;

  /// True when the visible detail is the last confirmed read of this task and
  /// the newest re-read failed (spec.md section 5: a failed refresh keeps the
  /// last confirmed data and identifies it as stale).
  bool get detailIsStale => _loadError != null && _detail?.id == _taskId;

  // ------------------------------------------------------- dependencies

  List<DependencySummary> get dependencies =>
      _detail?.dependencySummaries ?? const <DependencySummary>[];

  List<int> get backStack => List<int>.unmodifiable(_backStack);

  bool get canGoBack => _backStack.isNotEmpty;

  // --------------------------------------------------------------- history

  List<HistoryEvent> get historyEvents =>
      List<HistoryEvent>.unmodifiable(_history);

  bool get isHistoryLoading => _historyLoading;

  bool get historyLoaded => _historyLoaded;

  ViewerFailure? get historyError => _historyError;

  bool get historyHasMore => _historyHasMore;

  int? get openedEventId => _openedEventId;

  /// Complete snapshot text of the selected event, or null while it loads.
  String? get eventSnapshot => _eventSnapshot;

  bool get isEventLoading => _eventLoading;

  ViewerFailure? get eventError => _eventError;

  // ------------------------------------------------------------ find in body

  String get findText => _findText;

  int get matchCount => _matches.length;

  /// Zero-based index of the current match, or -1 when none is selected.
  int get matchIndex => _matchIndex;

  int? get matchStart => _matchIndex < 0 ? null : _matches[_matchIndex];

  int? get matchEnd =>
      _matchIndex < 0 ? null : _matches[_matchIndex] + _findText.trim().length;

  /// Visible count next to the Find in body field.
  String get findSummary {
    if (_findText.trim().isEmpty) {
      return '';
    }
    return _matches.isEmpty ? 'No matches' : '${_matches.length} matches';
  }

  /// Wrap or no-match message for the pane to announce; cleared on the next
  /// non-wrapping step and whenever the search text changes.
  String? get findNotice => _findNotice;

  // ------------------------------------------------------------------ loads

  /// Arrow navigation: the selection changes now, the read waits for the
  /// debounce so a run of arrow keys issues one read.
  void selectTask(int? taskId) {
    if (taskId == null) {
      clearSelection();
      return;
    }
    if (taskId == _taskId) {
      return;
    }
    _backStack.clear();
    _taskId = taskId;
    _detail = null;
    _loadError = null;
    _loading = true;
    _resetHistory();
    _resetFind();
    _notify();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_load(taskId)));
  }

  /// Enter on a task row: load immediately without waiting for the debounce.
  Future<void> openTask(int taskId) {
    _backStack.clear();
    _beginSelection(taskId);
    return _load(taskId);
  }

  /// Re-reads the current selection, for Retry and after a refresh.
  Future<void> reload() {
    final id = _taskId;
    if (id == null) {
      return Future<void>.value();
    }
    return _load(id);
  }

  void clearSelection() {
    _debounceTimer?.cancel();
    _generation++;
    _cancelInFlight();
    _taskId = null;
    _detail = null;
    _loading = false;
    _loadError = null;
    _backStack.clear();
    _resetHistory();
    _resetFind();
    _notify();
  }

  void _beginSelection(int taskId) {
    _debounceTimer?.cancel();
    if (_taskId != taskId) {
      _detail = null;
    }
    _taskId = taskId;
    _loadError = null;
    _loading = true;
    _resetHistory();
    _resetFind();
    _notify();
  }

  Future<void> _load(int taskId) async {
    final generation = ++_generation;
    _cancelInFlight();
    // A history read superseded here can no longer clear this flag itself.
    _historyLoading = false;
    // A Retry or refresh clears the previous error and shows its own progress;
    // the error returns if the read fails again.
    _loadError = null;
    if (!_loading) {
      _loading = true;
      _notify();
    }
    try {
      final detail = await _reader.fetchTaskDetail(projectId, taskId);
      if (generation != _generation) {
        return;
      }
      _detail = detail;
      _loading = false;
      _loadError = null;
      _recomputeMatches();
      _notify();
      if (_historyLoaded) {
        unawaited(reloadHistory());
      } else if (_tab == TaskDetailTab.history) {
        unawaited(ensureHistoryLoaded());
      }
    } on ViewerCancelledFailure {
      return;
    } on ViewerFailure catch (failure) {
      if (generation != _generation) {
        return;
      }
      if (_detail?.id != taskId) {
        _detail = null;
      }
      _loading = false;
      _loadError = failure;
      _notify();
    }
  }

  // ------------------------------------------------------------------ tabs

  /// Activates one tab. History loads the first page on its first activation.
  void setTab(TaskDetailTab value) {
    if (_tab == value) {
      return;
    }
    _tab = value;
    _notify();
    if (value == TaskDetailTab.history) {
      unawaited(ensureHistoryLoaded());
    }
  }

  // --------------------------------------------------------------- history

  /// Loads the first history page for the selected task, once.
  Future<void> ensureHistoryLoaded() async {
    if (_historyLoaded || _historyLoading || _taskId == null) {
      return;
    }
    await _loadHistory(reset: true);
  }

  /// Re-reads the first history page after a refresh, so newly appended events
  /// appear. Only called for a task whose history the user already loaded.
  Future<void> reloadHistory() async {
    if (_taskId == null || _historyLoading) {
      return;
    }
    await _loadHistory(reset: true);
  }

  /// Loads the next page of history events.
  Future<void> loadMoreHistory() async {
    if (!_historyHasMore || _historyLoading) {
      return;
    }
    await _loadHistory(reset: false);
  }

  Future<void> _loadHistory({required bool reset}) async {
    final taskId = _taskId;
    if (taskId == null) {
      return;
    }
    final generation = _generation;
    _historyLoading = true;
    _historyError = null;
    _notify();
    try {
      final page = await _reader.fetchTaskHistory(
        projectId,
        taskId,
        after: reset ? null : _historyNextAfter,
        limit: historyPageSize,
      );
      if (generation != _generation) {
        return;
      }
      if (reset) {
        _history.clear();
      }
      _history.addAll(page.items);
      _historyLoaded = true;
      _historyHasMore = page.hasMore;
      _historyNextAfter = page.nextAfter;
      _historyError = null;
    } on ViewerCancelledFailure {
      return;
    } on ViewerFailure catch (failure) {
      if (generation != _generation) {
        return;
      }
      _historyError = failure;
      if (reset) {
        _historyLoaded = false;
      }
    } finally {
      if (generation == _generation) {
        _historyLoading = false;
        _notify();
      }
    }
  }

  /// Loads the complete snapshot text of one event through `--event`.
  Future<void> selectEvent(int eventId) async {
    final taskId = _taskId;
    if (taskId == null) {
      return;
    }
    final generation = ++_eventGeneration;
    _openedEventId = eventId;
    _eventSnapshot = null;
    _eventError = null;
    _eventLoading = true;
    _notify();
    try {
      final page = await _reader.fetchTaskHistory(
        projectId,
        taskId,
        event: eventId,
        limit: 1,
      );
      if (generation != _eventGeneration) {
        return;
      }
      final event = page.items.isEmpty ? null : page.items.first;
      _eventSnapshot = event?.snapshotJson ?? '';
      _eventError = null;
    } on ViewerCancelledFailure {
      return;
    } on ViewerFailure catch (failure) {
      if (generation != _eventGeneration) {
        return;
      }
      _eventSnapshot = null;
      _eventError = failure;
    } finally {
      if (generation == _eventGeneration) {
        _eventLoading = false;
        _notify();
      }
    }
  }

  void _resetHistory() {
    _history.clear();
    _historyLoading = false;
    _historyLoaded = false;
    _historyError = null;
    _historyNextAfter = null;
    _historyHasMore = false;
    _eventGeneration++;
    _openedEventId = null;
    _eventSnapshot = null;
    _eventLoading = false;
    _eventError = null;
  }

  // ------------------------------------------------------------ find in body

  /// Sets the literal search text and recomputes the matches.
  void setFindText(String value) {
    if (_findText == value) {
      return;
    }
    _findText = value;
    _recomputeMatches();
    _notify();
  }

  void findNext() => _step(1);

  void findPrevious() => _step(-1);

  void clearFind() {
    if (_findText.isEmpty && _findNotice == null && _matchIndex < 0) {
      return;
    }
    _findText = '';
    _recomputeMatches();
    _notify();
  }

  void _step(int delta) {
    if (_matches.isEmpty) {
      _findNotice = 'No matches';
      _notify();
      return;
    }
    final next = _matchIndex < 0
        ? (delta > 0 ? 0 : _matches.length - 1)
        : _matchIndex + delta;
    if (next >= _matches.length) {
      _matchIndex = 0;
      _findNotice = 'Wrapped to the first match';
    } else if (next < 0) {
      _matchIndex = _matches.length - 1;
      _findNotice = 'Wrapped to the last match';
    } else {
      _matchIndex = next;
      _findNotice = null;
    }
    _notify();
  }

  void _resetFind() {
    _matches = const <int>[];
    _matchIndex = -1;
    _findNotice = null;
  }

  /// Literal, case-insensitive search of the body.
  ///
  /// Dart's `toLowerCase` maps code unit by code unit, so folded offsets still
  /// index the original body. Overlapping occurrences are reported, as a text
  /// editor does. Only the body is searched: the title has its own meaning.
  void _recomputeMatches() {
    final needle = _findText.trim().toLowerCase();
    final body = _detail?.body ?? '';
    if (needle.isEmpty || body.isEmpty) {
      _matches = const <int>[];
      _matchIndex = -1;
      _findNotice = null;
      return;
    }
    final haystack = body.toLowerCase();
    final found = <int>[];
    var from = haystack.indexOf(needle);
    while (from >= 0) {
      found.add(from);
      from = haystack.indexOf(needle, from + 1);
    }
    _matches = List<int>.unmodifiable(found);
    _matchIndex = found.isEmpty ? -1 : 0;
    _findNotice = null;
  }

  // ------------------------------------------------------- dependency stack

  /// Opens a dependency in the same project, remembering the current task for
  /// Back (viewer/spec.md section 6).
  Future<void> openDependency(int taskId) {
    if (taskId == _taskId) {
      return Future<void>.value();
    }
    final current = _taskId;
    if (current != null) {
      _backStack.add(current);
    }
    _beginSelection(taskId);
    return _load(taskId);
  }

  /// Returns to the task the user arrived from.
  Future<void> goBack() {
    if (_backStack.isEmpty) {
      return Future<void>.value();
    }
    final previous = _backStack.removeLast();
    _beginSelection(previous);
    return _load(previous);
  }

  // --------------------------------------------------------------- plumbing

  void _cancelInFlight() {
    final reader = _reader;
    if (reader is CancellableTaskDetailReader) {
      reader.cancelScope('detail');
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
