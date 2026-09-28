/// Shared doubles and fixtures for viewer widget tests.
///
/// Every launch uses an injected data root, CLI path and settings root, so no
/// test can reach the real task store or the real settings folder (spec 3).
library;

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_catalog.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/project_archive.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/platform/clipboard_text.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

/// One playback request recorded by [RecordingClipPlayer].
class RecordedClip {
  const RecordedClip(this.clipId, this.volume);

  final String clipId;
  final double volume;
}

/// Clip-player double: records requests and never touches audio.
class RecordingClipPlayer implements ClipPlayer {
  final List<RecordedClip> playbacks = <RecordedClip>[];
  int stopCount = 0;
  bool disposed = false;

  @override
  Future<void> play(AnnouncementClip clip, {required double volume}) async {
    playbacks.add(RecordedClip(clip.id, volume));
  }

  @override
  Future<void> stop() async => stopCount += 1;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Counters for shell actions whose only slice-1 effect is being called.
class ViewerActionLog {
  int refreshes = 0;
  int enrichments = 0;
  int markDone = 0;
  int edits = 0;
  int saves = 0;
}

/// Test environment with all three injected paths.
ViewerEnvironment viewerTestEnvironment({String suffix = 'default'}) {
  final dataRoot = 'C:\\viewer-test\\$suffix\\data';
  final settingsRoot = 'C:\\viewer-test\\$suffix\\settings';
  const tasksExe = r'C:\viewer-test\tasks.exe';
  return ViewerEnvironment(
    launchArgs: ViewerLaunchArgs(
      dataRoot: dataRoot,
      tasksExe: tasksExe,
      settingsRoot: settingsRoot,
      testMode: true,
    ),
    settingsRoot: settingsRoot,
    dataRoot: dataRoot,
    tasksExe: tasksExe,
  );
}

/// One mounted shell under test.
class ViewerHarness {
  ViewerHarness({
    required this.shell,
    required this.announcements,
    required this.clipPlayer,
    required this.log,
  });

  final ViewerShellState shell;
  final AnnouncementController announcements;
  final RecordingClipPlayer clipPlayer;
  final ViewerActionLog log;

  ViewerRegionHandles handles(ViewerRegion region) => shell.handlesFor(region);

  VirtualListController list(ViewerRegion region) =>
      shell.handlesFor(region).list;

  /// Debug label of the focused node, for focus-target assertions.
  String? get focusedDebugLabel =>
      FocusManager.instance.primaryFocus?.debugLabel;

  /// Last text committed to the status region.
  String get statusText => announcements.statusText;

  /// Text exposed through the single live announcement channel.
  String? get liveText => announcements.liveRegionText;
}

/// Pumps the mounted viewer shell with synthetic panes.
Future<ViewerHarness> pumpViewer(
  WidgetTester tester, {
  ViewerSettingsDraft settings = const ViewerSettingsDraft(),
  ViewerActionLog? log,
  Size surface = const Size(1600, 900),
  double platformTextScale = 1,
  AnnouncementCatalog? catalog,
  AnnouncementMode mode = AnnouncementMode.nvdaOnly,
}) async {
  final actions = log ?? ViewerActionLog();
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = platformTextScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final clipPlayer = RecordingClipPlayer();
  final announcements = AnnouncementController(
    clipPlayer: clipPlayer,
    catalog: catalog,
    mode: mode,
  );
  addTearDown(announcements.dispose);

  await tester.pumpWidget(
    MaterialApp(
      // A fresh key makes every call start a brand-new shell: two pumps in one
      // test must not inherit the previous shell's focus or revealed pane.
      key: UniqueKey(),
      home: ViewerShell(
        environment: viewerTestEnvironment(),
        announcements: announcements,
        initialSettings: settings,
        workspaceBuilder: buildPrototypeWorkspace,
        actions: ViewerShellActions(
          onRefresh: () => actions.refreshes += 1,
          onEnrichClipboard: () => actions.enrichments += 1,
          onMarkDone: () => actions.markDone += 1,
          onEditTask: () => actions.edits += 1,
          onSave: () => actions.saves += 1,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ViewerHarness(
    shell: tester.state<ViewerShellState>(find.byType(ViewerShell)),
    announcements: announcements,
    clipPlayer: clipPlayer,
    log: actions,
  );
}

/// Presses one key and settles the frame.
Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.pumpAndSettle();
}

/// Presses a key with Ctrl held, as a Windows user would.
Future<void> pressControl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.pumpAndSettle();
}

/// Presses a key with Alt held, as a Windows access key.
Future<void> pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.altLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft, platform: 'windows');
  await tester.pumpAndSettle();
}

/// Presses a key with Shift held, as a Windows user would.
Future<void> pressShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.shiftLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.shiftLeft,
    platform: 'windows',
  );
  await tester.pumpAndSettle();
}

/// Resizes the surface of the mounted viewer without restarting it.
Future<void> resizeViewer(WidgetTester tester, Size surface) async {
  tester.view.physicalSize = surface;
  await tester.pumpAndSettle();
}

/// One scriptable read surface for the real workspace.
///
/// Implements the project catalog, the task browser and task detail/history at
/// once, so a widget test injects one double and every request stays visible in
/// its recorded lists. Nothing here can reach a real task store.
class FakeWorkspaceReads
    implements
        CancellableProjectReader,
        CancellableTaskReader,
        CancellableTaskDetailReader {
  FakeWorkspaceReads({
    List<ProjectItem>? projects,
    Map<String, List<TaskItem>>? tasks,
    Map<int, TaskDetail>? details,
    Map<int, List<HistoryEvent>>? history,
    this.latency = Duration.zero,
  }) : projects = projects ?? <ProjectItem>[],
       tasks = tasks ?? <String, List<TaskItem>>{},
       details = details ?? <int, TaskDetail>{},
       history = history ?? <int, List<HistoryEvent>>{};

  final List<ProjectItem> projects;
  final Map<String, List<TaskItem>> tasks;
  final Map<int, TaskDetail> details;
  final Map<int, List<HistoryEvent>> history;

  /// Delay before every answer, so a test can observe loading feedback.
  Duration latency;

  /// When set, the read of that scope fails; clear the field to let Retry
  /// succeed.
  ViewerFailure? projectFailure;
  ViewerFailure? taskFailure;
  ViewerFailure? detailFailure;
  ViewerFailure? historyFailure;

  /// When set, the `viewer info` handshake fails.
  ViewerFailure? probeFailure;
  int probeRuns = 0;

  final List<ProjectQuery> projectRequests = <ProjectQuery>[];
  final List<TaskQuery> taskRequests = <TaskQuery>[];
  final List<String> taskProjectIds = <String>[];
  final List<int> detailRequests = <int>[];
  final List<int> eventRequests = <int>[];
  final List<String> cancelledScopes = <String>[];

  ProjectQuery get lastProjectRequest => projectRequests.last;
  TaskQuery get lastTaskRequest => taskRequests.last;

  Future<ViewerInfo> probe({bool force = false}) async {
    probeRuns += 1;
    final failure = probeFailure;
    if (failure != null) {
      throw failure;
    }
    return testViewerInfo();
  }

  Future<void> _pause() async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
  }

  @override
  Future<ProjectPage> fetchProjects(ProjectQuery query) async {
    projectRequests.add(query);
    await _pause();
    final failure = projectFailure;
    if (failure != null) {
      throw failure;
    }
    final matched = <ProjectItem>[
      for (final item in projects)
        if (_matchesProject(item, query)) item,
    ];
    if (query.sort == ProjectSort.name &&
        query.direction == SortDirection.descending) {
      matched.sort((a, b) => b.name.compareTo(a.name));
    }
    return ProjectPage(
      protocolVersion: 1,
      items: _slice(matched, query.offset, query.limit),
      totalCount: matched.length,
      offset: query.offset,
      limit: query.limit,
      hasMore: query.offset + query.limit < matched.length,
      nextOffset: query.offset + query.limit < matched.length
          ? query.offset + query.limit
          : null,
      snapshot: 'projects.snapshot',
    );
  }

  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) async {
    taskProjectIds.add(projectId);
    taskRequests.add(query);
    await _pause();
    final failure = taskFailure;
    if (failure != null) {
      throw failure;
    }
    final matched = <TaskItem>[
      for (final item in tasks[projectId] ?? const <TaskItem>[])
        if (_matchesTask(item, query)) item,
    ];
    if (query.sort == TaskSort.id) {
      matched.sort(
        (a, b) => query.direction == SortDirection.descending
            ? b.id.compareTo(a.id)
            : a.id.compareTo(b.id),
      );
    }
    final items = _slice(matched, query.offset, query.limit);
    final next = query.offset + items.length;
    return TaskPage(
      protocolVersion: 1,
      items: items,
      totalCount: matched.length,
      offset: query.offset,
      limit: query.limit,
      hasMore: next < matched.length,
      nextOffset: next < matched.length ? next : null,
      snapshot: 'tasks.snapshot',
    );
  }

  @override
  Future<TaskDetail> fetchTaskDetail(String projectId, int taskId) async {
    detailRequests.add(taskId);
    await _pause();
    final failure = detailFailure;
    if (failure != null) {
      throw failure;
    }
    final detail = details[taskId];
    if (detail == null) {
      throw ViewerCliErrorFailure(
        code: 'not_found',
        message: 'task $taskId does not exist',
        exitCode: 5,
      );
    }
    return detail;
  }

  @override
  Future<TaskHistoryPage> fetchTaskHistory(
    String projectId,
    int taskId, {
    int? after,
    int limit = 100,
    int? event,
  }) async {
    if (event != null) {
      eventRequests.add(event);
    }
    await _pause();
    final failure = historyFailure;
    if (failure != null) {
      throw failure;
    }
    final events = history[taskId] ?? const <HistoryEvent>[];
    if (event != null) {
      return TaskHistoryPage(
        items: <HistoryEvent>[
          for (final candidate in events)
            if (candidate.eventId == event) candidate,
        ],
        hasMore: false,
        nextAfter: null,
      );
    }
    final start = after ?? 0;
    final items = _slice(events, start, limit);
    final next = start + items.length;
    return TaskHistoryPage(
      items: items,
      hasMore: next < events.length,
      nextAfter: next < events.length ? next : null,
    );
  }

  @override
  void cancelScope(String scopeKey) => cancelledScopes.add(scopeKey);

  static bool _matchesProject(ProjectItem item, ProjectQuery query) {
    final text = query.query.trim().toLowerCase();
    if (text.isNotEmpty &&
        !item.name.toLowerCase().contains(text) &&
        !item.roots.any((root) => root.toLowerCase().contains(text))) {
      return false;
    }
    final stats = item.stats;
    if (query.state != ProjectStateFilter.archived &&
        item.archivedAtMs != null) {
      return false;
    }
    return switch (query.state) {
      ProjectStateFilter.all => true,
      ProjectStateFilter.active => item.archivedAtMs == null,
      ProjectStateFilter.archived => item.archivedAtMs != null,
      ProjectStateFilter.hasOpen => stats != null && stats.open > 0,
      ProjectStateFilter.hasBlocked => stats != null && stats.blocked > 0,
      ProjectStateFilter.complete =>
        stats != null && stats.open == 0 && stats.total > 0,
      ProjectStateFilter.empty => stats != null && stats.total == 0,
      ProjectStateFilter.unavailable => stats == null,
    };
  }

  static bool _matchesTask(TaskItem item, TaskQuery query) {
    final text = query.query.trim().toLowerCase();
    if (text.isNotEmpty &&
        !item.title.toLowerCase().contains(text) &&
        !item.canonicalId.toLowerCase().contains(text)) {
      return false;
    }
    if (query.scope == TaskScope.open &&
        (item.status == 'done' || item.status == 'cancelled')) {
      return false;
    }
    if (query.statuses.isNotEmpty && !query.statuses.contains(item.status)) {
      return false;
    }
    if (query.priorities.isNotEmpty &&
        !query.priorities.contains(item.priority)) {
      return false;
    }
    if (query.labels.isNotEmpty &&
        !item.labels.toSet().containsAll(query.labels)) {
      return false;
    }
    return switch (query.readiness) {
      TaskReadiness.any => true,
      TaskReadiness.waiting => item.waitingDependencyCount > 0,
      TaskReadiness.runnable => item.blockingDependencyCount == 0,
    };
  }

  static List<T> _slice<T>(List<T> items, int offset, int limit) {
    if (offset >= items.length || limit <= 0) {
      return <T>[];
    }
    final end = math.min(items.length, offset + limit);
    return items.sublist(offset, end);
  }
}

/// Finds one text field by the label shown above it.
/// Label text fields carry the same label in more than one pane, so [within]
/// lets a caller scope the search to the region it means.
Finder textFieldWithLabel(String label, {Finder? within}) {
  final field = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
    description: 'TextField labelled "$label"',
  );
  return within == null ? field : find.descendant(of: within, matching: field);
}

// ------------------------------------------------ real workspace harness

/// One mounted real workspace: the shell, the model above it and the doubles.
class RealViewerHarness {
  RealViewerHarness({
    required this.shell,
    required this.announcements,
    required this.clipPlayer,
    required this.reads,
    required this.model,
  });

  final ViewerShellState shell;
  final AnnouncementController announcements;
  final RecordingClipPlayer clipPlayer;
  final FakeWorkspaceReads reads;
  final ViewerWorkspaceModel model;

  ViewerRegionHandles handles(ViewerRegion region) => shell.handlesFor(region);

  VirtualListController list(ViewerRegion region) =>
      shell.handlesFor(region).list;

  /// Debug label of the focused node, for focus-target assertions.
  String? get focusedDebugLabel =>
      FocusManager.instance.primaryFocus?.debugLabel;

  /// Last text committed to the status region.
  String get statusText => announcements.statusText;

  /// Text exposed through the single live announcement channel.
  String? get liveText => announcements.liveRegionText;
}

/// Pumps the real three-pane workspace over [FakeWorkspaceReads].
///
/// The default fixture is two projects with three tasks each; pass [reads] to
/// script a different catalog, failures or latency. [settle] is off when the
/// test wants to observe a running read or the first frame only.
Future<RealViewerHarness> pumpRealViewer(
  WidgetTester tester, {
  FakeWorkspaceReads? reads,
  ViewerSettingsDraft settings = const ViewerSettingsDraft(),
  Size surface = const Size(1600, 900),
  AnnouncementMode mode = AnnouncementMode.nvdaOnly,
  TaskUpdateWriter? update,
  ProjectArchiveWriter? projectArchive,
  ClipboardEnricher? enricher,
  ViewerClipboard? clipboard,
  RecoveryDraftSink? drafts,
  ViewerCloseGuard? closeGuard,
  bool settle = true,
}) async {
  final backend = reads ?? fakeWorkspaceReads();
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final clipPlayer = RecordingClipPlayer();
  final announcements = AnnouncementController(
    clipPlayer: clipPlayer,
    mode: mode,
  );
  addTearDown(announcements.dispose);

  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      home: ViewerWorkspaceHost(
        environment: viewerTestEnvironment(),
        readers: ViewerDataReader(
          projects: backend,
          tasks: backend,
          detail: backend,
          probe: backend.probe,
          update: update,
          projectArchive: projectArchive,
          clipboard: enricher,
          drafts: drafts,
        ),
        announcements: announcements,
        initialSettings: settings,
        viewerClipboard: clipboard,
        drafts: drafts,
        closeGuard: closeGuard,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return RealViewerHarness(
    shell: tester.state<ViewerShellState>(find.byType(ViewerShell)),
    announcements: announcements,
    clipPlayer: clipPlayer,
    reads: backend,
    model: tester
        .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
        .model,
  );
}

/// The default synthetic catalog: two projects, three tasks each.
FakeWorkspaceReads fakeWorkspaceReads({
  List<ProjectItem>? projects,
  Map<String, List<TaskItem>>? tasks,
  Map<int, TaskDetail>? details,
  Map<int, List<HistoryEvent>>? history,
  Duration latency = Duration.zero,
}) {
  final catalog =
      projects ?? <ProjectItem>[testProjectItem(1), testProjectItem(2)];
  return FakeWorkspaceReads(
    projects: catalog,
    tasks:
        tasks ??
        <String, List<TaskItem>>{
          for (final project in catalog)
            project.projectId: <TaskItem>[
              testTaskItem(1, title: 'First task'),
              testTaskItem(2, title: 'Second task'),
              testTaskItem(3, title: 'Third task'),
            ],
        },
    details:
        details ??
        <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task'),
          2: testTaskDetail(2, title: 'Second task'),
          3: testTaskDetail(3, title: 'Third task'),
        },
    history: history ?? <int, List<HistoryEvent>>{},
    latency: latency,
  );
}

// ------------------------------------------------ real workspace fixtures

/// One synthetic project row with readable statistics.
ProjectItem testProjectItem(
  int index, {
  String? projectId,
  String? name,
  int total = 3,
  int open = 3,
  int blocked = 0,
  bool unavailable = false,
  int? archivedAtMs,
}) => ProjectItem(
  archivedAtMs: archivedAtMs,
  projectId:
      projectId ??
      '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  name: name ?? 'Project $index',
  roots: <String>['C:\\work\\project-$index'],
  availability: unavailable
      ? ProjectAvailability.error
      : ProjectAvailability.available,
  error: unavailable
      ? const ProjectErrorInfo(code: 'locked', message: 'database is locked')
      : null,
  sampledAtMs: 1700000000000 + index,
  stats: unavailable
      ? null
      : ProjectStats(
          total: total,
          open: open,
          blocked: blocked,
          done: 0,
          cancelled: 0,
          startedMs: null,
          lastWriteMs: null,
          progressPercent: null,
        ),
);

/// One synthetic task row.
TaskItem testTaskItem(
  int id, {
  String? title,
  String status = 'todo',
  String priority = 'P2',
  List<String> labels = const <String>[],
  int dependencyCount = 0,
  int waitingDependencyCount = 0,
  int verifyingDependencyCount = 0,
  String? displayId,
}) => TaskItem(
  id: id,
  displayId: displayId,
  title: title ?? 'Task $id',
  status: status,
  priority: priority,
  version: 1,
  labels: labels,
  dependencyCount: dependencyCount,
  waitingDependencyCount: waitingDependencyCount,
  verifyingDependencyCount: verifyingDependencyCount,
  createdMs: 1700000000000 + id,
  updatedMs: 1700000001000 + id,
);

/// One complete detail record.
TaskDetail testTaskDetail(
  int id, {
  String? title,
  String body = 'body text',
  String status = 'todo',
  String priority = 'P2',
  int version = 1,
  List<String> labels = const <String>[],
  List<int> deps = const <int>[],
  List<DependencySummary> dependencySummaries = const <DependencySummary>[],
  int ruleVersion = 3,
  String rules = '# Project rules',
  String? projectKey,
}) => TaskDetail(
  id: id,
  projectKey: projectKey,
  title: title ?? 'Task $id',
  body: body,
  status: status,
  priority: priority,
  version: version,
  labels: labels,
  deps: deps,
  dependencySummaries: dependencySummaries,
  ruleVersion: ruleVersion,
  rules: rules,
  createdMs: 1700000000000 + id,
  updatedMs: 1700000001000 + id,
);

/// One dependency row as `viewer show` reports it.
DependencySummary testDependency(
  int id, {
  String? title,
  String status = 'todo',
}) => DependencySummary(
  id: id,
  title: title ?? 'Task $id',
  status: status,
  version: 1,
);

/// One append-only history event.
HistoryEvent testHistoryEvent(
  int eventId, {
  int taskId = 5,
  String operation = 'create',
  int resultingVersion = 1,
  String? snapshot = '{"snapshot":true}',
}) => HistoryEvent(
  eventId: eventId,
  taskId: taskId,
  entityType: 'task',
  operation: operation,
  resultingVersion: resultingVersion,
  createdMs: 1700000000000 + eventId,
  snapshotJson: snapshot,
);

/// A valid `viewer info` payload for the handshake.
ViewerInfo testViewerInfo() => const ViewerInfo(
  protocolVersion: 1,
  operations: <String>['projects', 'tasks', 'show', 'history', 'update'],
  statuses: viewerTaskStatuses,
  priorities: <String>['P0', 'P1', 'P2', 'P3'],
  editableFields: <String>[
    'title',
    'body',
    'status',
    'priority',
    'labels',
    'deps',
  ],
  editableFieldLimits: ViewerEditableFieldLimits(
    titleMaxChars: 500,
    bodyMaxUtf8Bytes: 1048576,
    statusValues: viewerTaskStatuses,
    priorityValues: <String>['P0', 'P1', 'P2', 'P3'],
    labelsMaxCount: 32,
    labelsItemMaxChars: 64,
    labelsItemAllowed: 'a-z A-Z 0-9 -_.:',
    depsMaxCount: 1000,
  ),
);

// ------------------------------------------------------- editor fixtures

/// One scriptable `viewer update` surface.
///
/// Records every request, then answers with a canned result or throws an
/// injected failure. Nothing here can reach a real task store.
class FakeTaskWriter implements TaskUpdateWriter {
  final List<ViewerUpdateRequest> requests = <ViewerUpdateRequest>[];
  final List<String> projectIds = <String>[];

  /// Version reported for the next confirmed write.
  int nextVersion = 2;

  /// Event id reported for the next confirmed write; null means a no-op.
  int? nextEventId = 100;

  /// Status the store reports after a confirmed write.
  String nextStatus = 'todo';

  /// Delay before every answer, so a test can observe the busy state.
  Duration latency = Duration.zero;

  /// When set, the next call throws it once and clears the field.
  ViewerFailure? failure;

  /// Failure thrown by every call while set.
  ViewerFailure? persistentFailure;

  ViewerUpdateRequest get lastRequest => requests.last;

  @override
  Future<ViewerUpdateResult> updateTask(
    String projectId,
    ViewerUpdateRequest request,
  ) async {
    requests.add(request);
    projectIds.add(projectId);
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final persistent = persistentFailure;
    if (persistent != null) {
      throw persistent;
    }
    final failure = this.failure;
    if (failure != null) {
      this.failure = null;
      throw failure;
    }
    final eventId = nextEventId;
    return ViewerUpdateResult(
      id: request.id,
      status: nextStatus,
      version: eventId == null ? request.expectVersion : nextVersion,
      eventId: eventId,
    );
  }
}

/// In-memory recovery drafts with injectable disk failures.
/// Scriptable clipboard for the preview route: the direct action never uses it.
class FakeViewerClipboard implements ViewerClipboard {
  FakeViewerClipboard({this.text});

  /// Plain text the clipboard holds; null stands for a non-text clipboard.
  String? text;

  /// While set, the read stays pending until a test completes it.
  Completer<void>? gate;

  /// While set, every read throws it, the way a locked clipboard does.
  ViewerFailure? failure;

  int reads = 0;

  @override
  Future<String?> readText() async {
    reads += 1;
    final pending = gate;
    if (pending != null) {
      await pending.future;
    }
    final broken = failure;
    if (broken != null) {
      throw broken;
    }
    return text;
  }
}

/// One scriptable `enrich` / `enrich-clipboard` surface.
///
/// Records the captured project UUID of every call, so a test can prove the
/// scope of a running action did not follow a later selection change.
class FakeClipboardEnricher implements ClipboardEnricher {
  final List<String> directProjectIds = <String>[];
  final List<String> textProjectIds = <String>[];
  final List<String> texts = <String>[];

  /// Delay before every answer, so a test can observe the busy state.
  Duration latency = Duration.zero;

  /// When set, the next call throws it once and clears the field.
  ViewerFailure? failure;

  /// Answer for the next successful call.
  ClipboardEnrichment answer = testClipboardEnrichment();

  int get calls => directProjectIds.length + textProjectIds.length;

  @override
  Future<ClipboardEnrichment> enrichClipboard(String projectId) async {
    directProjectIds.add(projectId);
    return _answer();
  }

  @override
  Future<ClipboardEnrichment> enrichText(String projectId, String text) async {
    textProjectIds.add(projectId);
    texts.add(text);
    return _answer();
  }

  Future<ClipboardEnrichment> _answer() async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final pending = failure;
    if (pending != null) {
      failure = null;
      throw pending;
    }
    return answer;
  }
}

/// One enrichment answer with the counts a test cares about.
ClipboardEnrichment testClipboardEnrichment({
  String text = '',
  int replacements = 0,
  List<int> unknownIds = const <int>[],
  List<String> unknownRefs = const <String>[],
  bool clipboard = false,
}) => ClipboardEnrichment(
  text: text,
  replacements: replacements,
  unknownIds: List<int>.unmodifiable(unknownIds),
  unknownRefs: List<String>.unmodifiable(unknownRefs),
  clipboard: clipboard,
);

/// In-memory recovery drafts with injectable disk failures.
class MemoryDraftSink implements RecoveryDraftSink {
  final Map<String, ViewerRecoveryDraft> drafts =
      <String, ViewerRecoveryDraft>{};

  /// Raised by every [loadAll] while set.
  Object? loadFailure;

  /// Raised by every [save] while set.
  Object? saveFailure;

  /// Raised by every [delete] while set.
  Object? deleteFailure;

  int loads = 0;
  int saves = 0;
  int deletes = 0;

  @override
  Future<List<ViewerRecoveryDraft>> loadAll() async {
    loads += 1;
    final failure = loadFailure;
    if (failure != null) {
      throw failure;
    }
    return List<ViewerRecoveryDraft>.unmodifiable(drafts.values);
  }

  @override
  Future<void> save(ViewerRecoveryDraft draft) async {
    saves += 1;
    final failure = saveFailure;
    if (failure != null) {
      throw failure;
    }
    drafts[draft.draftId] = draft;
  }

  @override
  Future<void> delete(String draftId) async {
    deletes += 1;
    final failure = deleteFailure;
    if (failure != null) {
      throw failure;
    }
    drafts.remove(draftId);
  }
}
