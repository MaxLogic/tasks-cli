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
import '../controllers/announcement_controller.dart';
import '../controllers/clipboard_controller.dart';
import '../controllers/detail_controller.dart';
import '../controllers/editor_controller.dart';
import '../controllers/project_controller.dart';
import '../controllers/task_controller.dart';
import '../data/editor_models.dart';
import '../data/models.dart';
import '../data/project_archive.dart';
import '../data/settings_store.dart';
import '../data/settings_draft.dart';
import '../platform/clipboard_text.dart';
import 'editor_dialogs.dart';

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
    this.update,
    this.drafts,
    this.probe,
    this.clipboard,
    this.projectArchive,
  });

  final ProjectReader projects;
  final TaskReader tasks;
  final TaskDetailReader detail;

  /// The one write path the editor uses; null on a reader bundle without one.
  final TaskUpdateWriter? update;

  /// Recovery-draft persistence; null keeps the editor's drafts in memory.
  final RecoveryDraftSink? drafts;

  /// Runs `viewer info` before the first data read; null when the reader needs
  /// no handshake (test doubles, and any reader that cannot fail one).
  final ViewerProbe? probe;

  /// The one clipboard scope (spec.md section 8); null in a reader bundle that
  /// cannot enrich, which disables both clipboard actions with a reason.
  final ClipboardEnricher? clipboard;

  /// Project archive commands; null for a read-only workspace.
  final ProjectArchiveWriter? projectArchive;
}

/// Project catalog, task browser and detail state for one window.
class ViewerWorkspaceModel extends ChangeNotifier {
  ViewerWorkspaceModel({
    required this.environment,
    required this.readers,
    required this.announcements,
    this.initialSettings = const ViewerSettingsDraft(),
    ViewerClipboard? viewerClipboard,
    this.staleRefreshAfter = viewerStaleRefreshAfter,
  }) : clipboard = ClipboardController(
         enricher: readers.clipboard,
         clipboard: viewerClipboard ?? const SystemViewerClipboard(),
         announcements: announcements,
         dataRoot: environment.dataRoot,
       ) {
    projectList.addListener(_onProjectListChanged);
    editor.addListener(_onEditorChanged);
    clipboard.addListener(_notify);
  }

  /// Launch configuration the panes describe in their summaries.
  final ViewerEnvironment environment;

  /// Reader bundle; one CLI client serves all three scopes.
  final ViewerDataReader readers;

  /// The one announcement channel this window speaks through.
  final AnnouncementController announcements;
  final ViewerSettingsDraft initialSettings;

  /// Clipboard enrichment state, speech and the captured project scope.
  final ClipboardController clipboard;

  /// Age after which a regained window focus refreshes the workspace.
  final Duration staleRefreshAfter;

  /// The project catalog; its selection decides what the other panes show.
  late final ProjectController projectList = ProjectController(
    reader: readers.projects,
    initialState: initialSettings.projectState,
    initialSort: initialSettings.projectSort,
    initialDirection: initialSettings.projectDirection,
  );

  /// The one editor for this window; a pane rebuild never loses a draft.
  late final ViewerEditorController editor = ViewerEditorController(
    writer: readers.update,
    detailReader: readers.detail,
    drafts: readers.drafts,
    dataRoot: environment.dataRoot,
  );

  /// The pane that can show the editor's dialogs; the Details pane sets this
  /// while it is mounted, so a headless model simply cannot ask.
  ViewerEditorHost? editorHost;

  final Map<String, TaskListState> _taskStates = <String, TaskListState>{};

  TaskController? _tasks;
  TaskDetailController? _detail;
  String? _appliedProjectId;
  int? _appliedTaskId;
  final Set<String> _offeredDrafts = <String>{};
  bool _leaving = false;
  bool _started = false;
  bool _disposed = false;
  ViewerFailure? _startupError;

  /// Task list of the selected project, or null while none is selected.
  TaskController? get tasks => _tasks;

  /// Detail controller of the selected project, or null without a project.
  TaskDetailController? get detail => _detail;

  /// Project the panes show, or null when the catalog has no selection.
  ProjectItem? get selectedProject => projectList.selectedItem;

  bool get canArchiveProjects => readers.projectArchive != null;

  Future<void> setProjectArchived(
    ProjectItem project, {
    required bool archived,
  }) async {
    final writer = readers.projectArchive;
    if (writer == null) {
      throw StateError('Project archive commands are unavailable.');
    }
    await writer.setProjectArchived(project.projectId, archived: archived);
    await projectList.refresh();
  }

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
    // The recovery index is read after the first catalog read so a failing CLI
    // reports its own problem first.
    unawaited(editor.loadRecoveryDrafts());
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
    editor.removeListener(_onEditorChanged);
    editor.dispose();
    clipboard.removeListener(_notify);
    clipboard.dispose();
    _tasks?.removeListener(_onTasksChanged);
    _tasks?.dispose();
    _detail?.removeListener(_onDetailChanged);
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

  // ---------------------------------------------------------------- editor

  /// Asks before an action that would drop a dirty draft.
  ///
  /// False when the user cancelled, and also when no pane can ask: without a
  /// Details pane there is no dialog, so the draft wins over the navigation.
  Future<bool> requestLeave(EditorLeaveReason reason) async {
    if (!editor.isEditing || !editor.isDirty) {
      return true;
    }
    final host = editorHost;
    if (host == null || _leaving) {
      return false;
    }
    _leaving = true;
    try {
      return await host.confirmLeave(reason);
    } finally {
      _leaving = false;
    }
  }

  /// Arrow navigation across task rows, with the leaving guard in front.
  ///
  /// False means the guard cancelled, so the pane can put its row highlight
  /// back on the task the editor still has open.
  Future<bool> selectTaskRow(int index) async {
    final tasks = _tasks;
    if (tasks == null) {
      return false;
    }
    final id = tasks.itemAt(index)?.id;
    if (id == null || id == tasks.selectedTaskId) {
      return true;
    }
    if (!await requestLeave(EditorLeaveReason.taskSwitch)) {
      return false;
    }
    editor.exitEdit();
    tasks.selectIndex(index);
    return true;
  }

  /// Arrow navigation across project rows, with the leaving guard in front.
  Future<bool> selectProjectRow(int index) async {
    final id = projectList.itemAt(index)?.projectId;
    if (id == null || id == projectList.selectedProjectId) {
      return true;
    }
    if (!await requestLeave(EditorLeaveReason.projectSwitch)) {
      return false;
    }
    editor.exitEdit();
    projectList.selectIndex(index);
    return true;
  }

  /// Re-reads what a confirmed write changed: the task and its list row.
  Future<void> noteConfirmedRead() async {
    final detail = _detail;
    await _tasks?.refresh();
    await detail?.reload();
  }

  /// F4 from anywhere in the window; the pane owns focus and speech.
  Future<void> beginEditTask() async {
    await editorHost?.beginEdit();
  }

  /// Ctrl+D from anywhere in the window.
  Future<void> markDoneTask() async {
    await editorHost?.markDone();
  }

  /// Context-menu status changes use the editor's versioned save workflow.
  Future<void> changeTaskStatus(String status) async {
    if (!editor.canWrite || editor.isSaving || editorHost == null) return;
    final original = editor.base;
    final projectId = selectedProjectId;
    if (original == null || original.status == status) return;
    if (!await requestLeave(EditorLeaveReason.leaveEditMode)) return;
    if (selectedProjectId != projectId ||
        editor.base?.id != original.id ||
        editor.isSaving) {
      return;
    }
    editor.beginEdit();
    editor.setField(EditorField.status, status);
    await editorHost?.save();
  }

  /// Ctrl+S from anywhere in the window; a no-op without an open editor.
  Future<void> saveTask() async {
    await editorHost?.save();
  }

  // ------------------------------------------------------------- clipboard

  /// Ctrl+E and the Enrich clipboard button share this one handler.
  ///
  /// The selection is captured here, when the action starts.
  Future<void> enrichClipboard() => clipboard.enrichClipboard(selectedProject);

  /// The Preview enrichment button and Alt+P; null when nothing can be shown.
  ///
  /// The pane renders the returned preview in its dialog, so the reading and
  /// the speech rules stay in one place and the clipboard is never written.
  Future<ClipboardPreview?> previewEnrichment() =>
      clipboard.previewEnrichment(selectedProject);

  /// Why the clipboard toolbar is disabled, or null when both actions can run.
  String? get clipboardBlockedReason =>
      clipboard.blockedReason(selectedProject);

  /// The window asks before it closes (spec.md section 7).
  Future<bool> closeWindow() async {
    if (!await requestLeave(EditorLeaveReason.windowClose)) {
      return false;
    }
    final host = editorHost;
    if (host != null && !await host.settleBeforeClose()) {
      return false;
    }
    return true;
  }

  /// Settings asked for another task store (spec.md section 7).
  ///
  /// Swapping the reader bundle belongs to the settings slice; this call owns
  /// the guard, so a requested change can never quietly drop a draft.
  Future<bool> requestStoreChange(String? dataRoot) async {
    if (dataRoot == environment.dataRoot) {
      return true;
    }
    return requestLeave(EditorLeaveReason.storeChange);
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

  /// The confirmed record changed: mirror it into the editor, then offer any
  /// recovery draft that belongs to it.
  void _onDetailChanged() {
    editor.observeDetail(
      _detail?.detail,
      projectId: _detail?.projectId ?? _appliedProjectId,
    );
    _maybeOfferDraft();
    _notify();
  }

  void _onEditorChanged() {
    _maybeOfferDraft();
    _notify();
  }

  /// Offers the persisted draft that belongs to the open task, once.
  ///
  /// The prompt is the restart path in spec.md section 7: Restore draft or
  /// Discard, with Restore as the default.
  void _maybeOfferDraft() {
    final host = editorHost;
    final detail = _detail?.detail;
    final projectId = _detail?.projectId ?? _appliedProjectId;
    if (host == null || detail == null || projectId == null) {
      return;
    }
    if (editor.isEditing) {
      return;
    }
    for (final draft in editor.pendingDrafts) {
      if (draft.projectId != projectId || draft.taskId != detail.canonicalId) {
        continue;
      }
      if (!_offeredDrafts.add(draft.draftId)) {
        continue;
      }
      unawaited(host.offerDraftRestore(draft));
      return;
    }
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
    _detail?.removeListener(_onDetailChanged);
    _detail?.dispose();
    _tasks = null;
    _detail = null;
    // The new project has no confirmed record yet, so no editor can be based
    // on the previous project's task.
    editor.observeDetail(null, projectId: projectId);
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
    detail.addListener(_onDetailChanged);
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
