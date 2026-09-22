/// Shared state of the three real panes.
///
/// Contract: viewer/spec.md sections 4.2, 4.3, 5 and 6 with viewer/design.md
/// sections 4 to 7. One model owns the controllers, the per-project task
/// parameters and the cross-pane wiring, so the panes stay rendering layers
/// and the shell stays a layout and command dispatcher.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_environment.dart';
import '../controllers/detail_controller.dart';
import '../controllers/project_controller.dart';
import '../controllers/task_controller.dart';
import '../data/models.dart';

/// How long a read may age before a regained window focus refreshes it
/// (viewer/spec.md section 5).
const Duration viewerStaleRefreshAfter = Duration(seconds: 30);

/// One-time handshake a reader may need before its first data read.
typedef ViewerProbe = Future<ViewerInfo> Function({bool force});

/// The read surface one workspace uses, as one injectable bundle.
///
/// The three scopes are separate interfaces so each controller depends only on
/// what it reads; the real client satisfies all three at once.
class ViewerDataReader {
  const ViewerDataReader({
    required this.projects,
    required this.tasks,
    required this.detail,
    this.probe,
  });

  final ProjectReader projects;
  final TaskReader tasks;
  final TaskDetailReader detail;

  /// Runs `viewer info` before the first data read; null when the reader needs
  /// no handshake (test doubles, and any reader that cannot fail one).
  final ViewerProbe? probe;
}

/// Project catalog, task browser and detail state for one window.
class ViewerWorkspaceModel extends ChangeNotifier {
  ViewerWorkspaceModel({
    required this.environment,
    required this.readers,
    this.staleRefreshAfter = viewerStaleRefreshAfter,
  }) {
    projectList.addListener(_onProjectListChanged);
  }

  /// Launch configuration the panes describe in their summaries.
  final ViewerEnvironment environment;

  /// Reader bundle; one CLI client serves all three scopes.
  final ViewerDataReader readers;

  /// Age after which a regained window focus refreshes the workspace.
  final Duration staleRefreshAfter;

  /// The project catalog; its selection decides what the other panes show.
  late final ProjectController projectList = ProjectController(
    reader: readers.projects,
  );

  final Map<String, TaskListState> _taskStates = <String, TaskListState>{};

  TaskController? _tasks;
  TaskDetailController? _detail;
  String? _appliedProjectId;
  int? _appliedTaskId;
  bool _started = false;
  bool _disposed = false;
  ViewerFailure? _startupError;

  /// Task list of the selected project, or null while none is selected.
  TaskController? get tasks => _tasks;

  /// Detail controller of the selected project, or null without a project.
  TaskDetailController? get detail => _detail;

  /// Project the panes show, or null when the catalog has no selection.
  ProjectItem? get selectedProject => projectList.selectedItem;

  String? get selectedProjectId => projectList.selectedProjectId;

  /// Project name for the task heading, or a neutral placeholder.
  String get selectedProjectName => selectedProject?.name ?? 'No project';

  /// Failure from the handshake or the first project read.
  ViewerFailure? get startupError => _startupError;

  /// True while the catalog or the task list is re-reading.
  bool get isRefreshing =>
      projectList.isLoading || (_tasks?.isLoading ?? false);

  /// True while the newest catalog read is older than [staleRefreshAfter].
  bool isStaleAt(DateTime now) {
    final sampled = <int>[
      if (projectList.sampledAtMs != null) projectList.sampledAtMs!,
      if (_tasks?.sampledAtMs != null) _tasks!.sampledAtMs!,
    ];
    if (sampled.isEmpty) {
      return false;
    }
    final newest = sampled.reduce(math.max);
    return now.millisecondsSinceEpoch - newest >=
        staleRefreshAfter.inMilliseconds;
  }

  /// Filters, sort and selection a project the user left had in effect.
  TaskListState? savedTaskStateFor(String projectId) => _taskStates[projectId];

  bool get canGoBack => _detail?.canGoBack ?? false;

  // ------------------------------------------------------------- life cycle

  /// Runs the handshake and the first catalog read exactly once.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final probe = readers.probe;
    if (probe != null) {
      try {
        await probe(force: false);
      } on ViewerFailure catch (failure) {
        _startupError = failure;
        _notify();
        return;
      }
    }
    _startupError = null;
    await projectList.reload();
  }

  /// Retry for a failed handshake or a failed first catalog read.
  Future<void> retryStartup() async {
    if (_startupError == null) {
      await projectList.retry();
      return;
    }
    _startupError = null;
    _started = false;
    await start();
  }

  /// F5 and the Refresh button: every visible scope reads again.
  Future<void> refresh() async {
    if (_startupError != null) {
      await retryStartup();
      return;
    }
    final tasks = _tasks;
    final reads = <Future<void>>[
      projectList.refresh(),
      if (tasks != null) tasks.refresh(),
    ];
    await Future.wait<void>(reads);
    await _detail?.reload();
  }

  /// Refreshes after a regained window focus when the newest read has aged.
  ///
  /// Nothing is read before the first successful load, so a window that was
  /// never used cannot turn focus into a network of CLI calls.
  Future<void> refreshIfStale() async {
    if (!isStaleAt(DateTime.now())) {
      return;
    }
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    projectList.removeListener(_onProjectListChanged);
    _tasks?.removeListener(_onTasksChanged);
    _tasks?.dispose();
    _detail?.removeListener(_notify);
    _detail?.dispose();
    projectList.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- selection

  /// Arrow navigation in the project list.
  void selectProjectIndex(int? index) => projectList.selectIndex(index);

  /// Enter on a project row: the same selection, revealed by the pane.
  void openProjectIndex(int index) => projectList.selectIndex(index);

  /// Arrow navigation in the task list.
  void selectTaskIndex(int? index) => _tasks?.selectIndex(index);

  /// Enter on a task row: reads the detail without the arrow debounce.
  Future<void> openTaskIndex(int index) async {
    final tasks = _tasks;
    if (tasks == null) {
      return;
    }
    final item = tasks.itemAt(index);
    if (item == null) {
      return;
    }
    tasks.selectIndex(index);
    await _detail?.openTask(item.id);
  }

  /// Makes the page that owns [index] available for a virtual jump.
  Future<void> ensureProjectRow(int index) => projectList.ensureRow(index);

  /// Makes the page that owns [index] available for a virtual jump.
  Future<void> ensureTaskRow(int index) async {
    await _tasks?.ensureRow(index);
  }

  /// Activates one details tab; History loads its first page on first use.
  void showTab(TaskDetailTab tab) => _detail?.setTab(tab);

  /// Returns to the task the user arrived from in the dependency stack.
  Future<void> goBack() => _detail?.goBack() ?? Future<void>.value();

  /// Loads the complete snapshot of one history event.
  Future<void> selectHistoryEvent(int eventId) =>
      _detail?.selectEvent(eventId) ?? Future<void>.value();

  /// Retry for a failed task read.
  Future<void> retryDetail() => _detail?.reload() ?? Future<void>.value();

  /// Retry for a failed first task read.
  Future<void> retryTasks() async {
    await _tasks?.retry();
  }

  // --------------------------------------------------------------- plumbing

  void _onProjectListChanged() {
    final id = projectList.selectedProjectId;
    if (id != _appliedProjectId) {
      _activateProject(id);
    }
    _notify();
  }

  void _onTasksChanged() {
    final id = _tasks?.selectedTaskId;
    if (id != _appliedTaskId) {
      _appliedTaskId = id;
      final detail = _detail;
      if (detail != null) {
        if (id == null) {
          detail.clearSelection();
        } else {
          detail.selectTask(id);
        }
      }
    }
    _notify();
  }

  /// Swaps the per-project controllers and re-reads the new project.
  void _activateProject(String? projectId) {
    _saveTaskState();
    _appliedProjectId = projectId;
    _appliedTaskId = null;
    final previous = _tasks;
    if (previous != null) {
      previous.removeListener(_onTasksChanged);
      previous.dispose();
    }
    _detail?.removeListener(_notify);
    _detail?.dispose();
    _tasks = null;
    _detail = null;
    if (projectId == null) {
      return;
    }
    final tasks = TaskController(projectId: projectId, reader: readers.tasks);
    final detail = TaskDetailController(
      projectId: projectId,
      reader: readers.detail,
    );
    _tasks = tasks;
    _detail = detail;
    tasks.addListener(_onTasksChanged);
    detail.addListener(_notify);
    final saved = _taskStates[projectId];
    if (saved != null) {
      tasks.restoreState(saved);
      _appliedTaskId = saved.selectedTaskId;
      final selected = saved.selectedTaskId;
      if (selected != null) {
        detail.selectTask(selected);
      }
    }
    unawaited(tasks.reload());
  }

  void _saveTaskState() {
    final id = _appliedProjectId;
    final tasks = _tasks;
    if (id == null || tasks == null) {
      return;
    }
    _taskStates[id] = tasks.captureState();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
