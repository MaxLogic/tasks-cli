/// Screenshot regression for the real three-pane layout.
///
/// Renders the workspace with the Windows platform behaviour (desktop
/// scrollbars, Segoe UI typography) in the standard and high-contrast dark
/// themes at the two reference window sizes, and compares against committed
/// goldens. The goldens depend on the host's Segoe UI files and time zone, so
/// the test skips on a host without them; regenerate with
/// `flutter test --update-goldens test/golden`.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import '../support/viewer_test_support.dart';

const List<String> _segoeFiles = <String>[
  r'C:\Windows\Fonts\segoeui.ttf',
  r'C:\Windows\Fonts\segoeuib.ttf',
  r'C:\Windows\Fonts\seguisb.ttf',
];

/// Fixed wall clock: 21 September 2026 16:13 UTC.
const int _fixedNowMs = 1790007180000;

const String _goldenBaseline = String.fromEnvironment(
  'TASKS_VIEWER_GOLDEN_BASELINE',
  defaultValue: 'windows-11',
);

bool get _hostHasFonts =>
    Platform.isWindows && _segoeFiles.every((path) => File(path).existsSync());

Future<void> _loadFonts() async {
  final segoe = FontLoader('Segoe UI');
  for (final path in _segoeFiles) {
    final bytes = File(path).readAsBytesSync();
    segoe.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  }
  await segoe.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

ProjectItem _project(
  int index,
  String name,
  double progress, {
  String? projectKey,
}) => ProjectItem(
  projectKey: projectKey,
  archivedAtMs: null,
  projectId: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  name: name,
  roots: <String>['\\\\?\\F:\\projects\\MaxLogic\\$name'],
  availability: ProjectAvailability.available,
  error: null,
  sampledAtMs: _fixedNowMs,
  stats: ProjectStats(
    total: 120,
    open: 17,
    blocked: 2,
    done: 103,
    cancelled: 0,
    startedMs: 1779962400000,
    lastWriteMs: _fixedNowMs,
    progressPercent: progress,
  ),
);

enum _Scene {
  /// The selected project has tasks, but none match the default filters.
  noMatches,

  /// The selected project lists tasks and one is open in Task details.
  taskOpen,

  /// A task waits only on a to-verify prerequisite; Mark done was refused.
  verifyRefused,

  /// [taskOpen] in a project with the longest key and 5-digit task IDs.
  taskOpenKeyed,

  /// An open task with several unfinished prerequisites: the Mark done hint
  /// is long enough to wrap onto its own line under the button.
  markDoneHintWrap,

  /// The task list's context menu, open on a row whose task is loaded and
  /// carries a Mark done hint.
  taskMenuHint,
}

/// File-name stem of a scene's goldens.
String _sceneName(_Scene scene) => switch (scene) {
  _Scene.taskOpenKeyed => 'taskOpen_keyed',
  _Scene.markDoneHintWrap => 'markDoneHint_wrap',
  _Scene.taskMenuHint => 'taskMenu_hint',
  _ => scene.name,
};

/// Scenes that need only the smaller reference size.
const Set<_Scene> _narrowScenes = <_Scene>{
  _Scene.verifyRefused,
  _Scene.taskOpenKeyed,
  _Scene.markDoneHintWrap,
  _Scene.taskMenuHint,
};

/// Window sizes each scene renders at; the refusal, keyed and Mark done hint
/// scenes need only the smaller reference size.
List<Size> _sizes(_Scene scene) => _narrowScenes.contains(scene)
    ? const <Size>[Size(1280, 720)]
    : const <Size>[Size(2000, 800), Size(1280, 720)];

/// A 6-character key with 5-digit IDs: the widest keyed ID the CLI renders.
FakeWorkspaceReads _keyedReads() {
  const key = 'ABCDEF';
  String id(int number) => viewerCanonicalTaskId(number, key);
  final projects = <ProjectItem>[
    _project(1, 'eye-health-training', 85.8, projectKey: key),
    _project(2, 'tasks-cli', 42.5, projectKey: 'TCLI'),
    _project(3, 'DelphiAiKit', 12),
  ];
  final tasks = <TaskItem>[
    testTaskItem(
      12000,
      title: 'Render goldens on Windows',
      priority: 'P1',
      dependencyCount: 1,
      displayId: id(12000),
    ),
    testTaskItem(
      12001,
      title: 'Paste a ticket ID into the task search',
      labels: const <String>['viewer', 'keyboard'],
      displayId: id(12001),
    ),
    testTaskItem(
      12002,
      title: 'Wait for the CLI protocol change',
      status: 'blocked',
      waitingDependencyCount: 1,
      displayId: id(12002),
    ),
  ];
  return fakeWorkspaceReads(
    projects: projects,
    tasks: <String, List<TaskItem>>{
      for (final project in projects) project.projectId: tasks,
    },
    details: <int, TaskDetail>{
      12000: testTaskDetail(
        12000,
        title: 'Render goldens on Windows',
        priority: 'P1',
        body: 'Keep the layout regression deterministic. See ${id(12001)}.',
        deps: const <int>[12001],
        projectKey: key,
        dependencySummaries: <DependencySummary>[
          DependencySummary(
            id: 12001,
            displayId: id(12001),
            title: 'Paste a ticket ID into the task search',
            status: 'todo',
            version: 1,
          ),
        ],
      ),
    },
  );
}

/// The completion guard's structured refusal for T-002.
const ViewerCliErrorFailure _refusal = ViewerCliErrorFailure(
  code: 'validation',
  message: 'validation: update T-002: cannot mark done',
  exitCode: 2,
  openPrerequisites: <ViewerOpenPrerequisite>[
    ViewerOpenPrerequisite(id: 1, status: 'to-verify'),
  ],
);

/// An open task with several unfinished prerequisites, so the Mark done hint
/// is long enough to wrap under the button and shows up in the list context
/// menu once the task's detail is loaded.
FakeWorkspaceReads _hintedReads(List<ProjectItem> projects) {
  final prerequisites = <DependencySummary>[
    testDependency(2, title: 'Draft the migration plan', status: 'todo'),
    testDependency(
      3,
      title: 'Review the storage layout',
      status: 'in-progress',
    ),
    testDependency(4, title: 'Confirm the backup policy', status: 'blocked'),
    testDependency(5, title: 'Update the release notes', status: 'draft'),
  ];
  return fakeWorkspaceReads(
    projects: projects,
    tasks: <String, List<TaskItem>>{
      for (final project in projects)
        project.projectId: <TaskItem>[
          testTaskItem(
            1,
            title: 'Render goldens on Windows',
            priority: 'P1',
            dependencyCount: prerequisites.length,
            waitingDependencyCount: prerequisites.length,
          ),
        ],
    },
    details: <int, TaskDetail>{
      1: testTaskDetail(
        1,
        title: 'Render goldens on Windows',
        priority: 'P1',
        body: 'Keep the layout regression deterministic.',
        deps: const <int>[2, 3, 4, 5],
        dependencySummaries: prerequisites,
      ),
    },
  );
}

FakeWorkspaceReads _reads(_Scene scene) {
  if (scene == _Scene.taskOpenKeyed) {
    return _keyedReads();
  }
  final projects = <ProjectItem>[
    _project(1, 'eye-health-training', 85.8),
    _project(2, 'tasks-cli', 42.5),
    _project(3, 'DelphiAiKit', 12),
  ];
  if (scene == _Scene.markDoneHintWrap || scene == _Scene.taskMenuHint) {
    return _hintedReads(projects);
  }
  if (scene == _Scene.verifyRefused) {
    return fakeWorkspaceReads(
      projects: projects,
      tasks: <String, List<TaskItem>>{
        for (final project in projects)
          project.projectId: <TaskItem>[
            testTaskItem(
              2,
              title: 'Build on the verified status',
              status: 'in-progress',
              priority: 'P1',
              dependencyCount: 1,
              waitingDependencyCount: 1,
              verifyingDependencyCount: 1,
            ),
            testTaskItem(
              1,
              title: 'Add the to-verify status',
              status: 'to-verify',
            ),
          ],
      },
      details: <int, TaskDetail>{
        2: testTaskDetail(
          2,
          title: 'Build on the verified status',
          status: 'in-progress',
          priority: 'P1',
          body: 'Waits for the batch gate of T-001.',
          deps: const <int>[1],
          dependencySummaries: <DependencySummary>[
            testDependency(
              1,
              title: 'Add the to-verify status',
              status: 'to-verify',
            ),
          ],
        ),
      },
    );
  }
  final tasks = scene == _Scene.noMatches
      ? <TaskItem>[testTaskItem(1, title: 'Shipped task', status: 'done')]
      : <TaskItem>[
          testTaskItem(1, title: 'Render goldens on Windows', priority: 'P1'),
          testTaskItem(
            2,
            title: 'Paste a ticket ID into the task search',
            labels: const <String>['viewer', 'keyboard'],
          ),
          testTaskItem(
            3,
            title: 'Wait for the CLI protocol change',
            status: 'blocked',
            waitingDependencyCount: 1,
          ),
        ];
  return fakeWorkspaceReads(
    projects: projects,
    tasks: <String, List<TaskItem>>{
      for (final project in projects) project.projectId: tasks,
    },
    details: <int, TaskDetail>{
      1: testTaskDetail(
        1,
        title: 'Render goldens on Windows',
        priority: 'P1',
        body: 'Keep the layout regression deterministic.',
      ),
    },
  );
}

void main() {
  final goldenDirectory = switch (_goldenBaseline) {
    'windows-11' => 'goldens',
    'windows-server-2022' => 'goldens/windows-server-2022',
    _ => throw ArgumentError('Unknown golden baseline: $_goldenBaseline'),
  };
  final skip = !_hostHasFonts;

  setUpAll(() async {
    if (!skip) {
      await _loadFonts();
    }
  });

  for (final scene in _Scene.values) {
    for (final highContrast in <bool>[false, true]) {
      for (final size in _sizes(scene)) {
        final name =
            '${_sceneName(scene)}_${highContrast ? 'hc' : 'std'}_'
            '${size.width.toInt()}x${size.height.toInt()}';
        testWidgets(
          'layout $name',
          (tester) async {
            final clock = taskSampleClock;
            taskSampleClock = () => _fixedNowMs;
            addTearDown(() => taskSampleClock = clock);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final announcements = AnnouncementController(
              clipPlayer: RecordingClipPlayer(),
              mode: AnnouncementMode.nvdaOnly,
            );
            addTearDown(announcements.dispose);
            final reads = _reads(scene);
            await tester.pumpWidget(
              TasksViewerApp(
                environment: viewerTestEnvironment(suffix: 'golden'),
                announcements: announcements,
                readers: ViewerDataReader(
                  projects: reads,
                  tasks: reads,
                  detail: reads,
                  probe: reads.probe,
                  update: FakeTaskWriter()..persistentFailure = _refusal,
                ),
                initialSettings: ViewerSettingsDraft(
                  themeMode: highContrast
                      ? ViewerThemeMode.highContrastDark
                      : ViewerThemeMode.dark,
                ),
              ),
            );
            await tester.pumpAndSettle();
            final model = tester
                .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
                .model;
            model.selectProjectIndex(0);
            await tester.pumpAndSettle();
            if (scene == _Scene.taskOpen || scene == _Scene.taskOpenKeyed) {
              await model.selectTaskRow(0);
              await tester.pumpAndSettle();
              await model.openTaskIndex(0);
              await tester.pumpAndSettle();
            }
            if (scene == _Scene.verifyRefused) {
              await model.selectTaskRow(0);
              await tester.pumpAndSettle();
              await model.openTaskIndex(0);
              await tester.pumpAndSettle();
              await tester.tap(
                find.ancestor(
                  of: find.text('Mark done'),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is ButtonStyleButton,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(
                find.textContaining(
                  'T-002 was not marked done. Finish or cancel T-001 '
                  '(To verify) first.',
                ),
                findsWidgets,
              );
            }
            if (scene == _Scene.taskOpenKeyed) {
              expect(find.textContaining('ABCDEF-12000'), findsWidgets);
              expect(find.textContaining('ABCDEF-12001'), findsWidgets);
              expect(find.textContaining('T-12000'), findsNothing);
            }
            if (scene == _Scene.markDoneHintWrap ||
                scene == _Scene.taskMenuHint) {
              await model.selectTaskRow(0);
              await tester.pumpAndSettle();
              await model.openTaskIndex(0);
              await tester.pumpAndSettle();
              const hint = 'Needs T-002, T-003, T-004 and T-005 done first';
              expect(find.text(hint), findsOneWidget);
              if (scene == _Scene.taskMenuHint) {
                await tester.tap(find.byTooltip('Actions for T-001'));
                await tester.pumpAndSettle();
                expect(find.text('Mark done (D)'), findsOneWidget);
                expect(find.text(hint), findsNWidgets(2));
              }
            }
            // With the real font every selected-project action is on screen
            // inside the Projects pane, even at 720 pixels.
            final pane = tester.getRect(find.byType(ViewerProjectsPane));
            for (final label in <String>[
              'Copy project ID (Alt+Y)',
              'Enrich clipboard (Alt+E)',
              'Preview enrichment (Alt+P)',
            ]) {
              final rect = tester.getRect(
                find.widgetWithText(FilledButton, label),
              );
              expect(
                rect.bottom,
                lessThanOrEqualTo(pane.bottom),
                reason: label,
              );
              expect(rect.top, greaterThanOrEqualTo(pane.top), reason: label);
            }
            await expectLater(
              find.byType(TasksViewerApp),
              matchesGoldenFile('$goldenDirectory/$name.png'),
            );
          },
          skip: skip,
          variant: TargetPlatformVariant.only(TargetPlatform.windows),
        );
      }
    }
  }
}
