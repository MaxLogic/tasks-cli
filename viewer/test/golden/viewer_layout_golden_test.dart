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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
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

ProjectItem _project(int index, String name, double progress) => ProjectItem(
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
}

FakeWorkspaceReads _reads(_Scene scene) {
  final projects = <ProjectItem>[
    _project(1, 'eye-health-training', 85.8),
    _project(2, 'tasks-cli', 42.5),
    _project(3, 'DelphiAiKit', 12),
  ];
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
  final skip = !_hostHasFonts;

  setUpAll(() async {
    if (!skip) {
      await _loadFonts();
    }
  });

  for (final scene in _Scene.values) {
    for (final highContrast in <bool>[false, true]) {
      for (final size in const <Size>[Size(2000, 800), Size(1280, 720)]) {
        final name =
            '${scene.name}_${highContrast ? 'hc' : 'std'}_'
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
            if (scene == _Scene.taskOpen) {
              await model.selectTaskRow(0);
              await tester.pumpAndSettle();
              await model.openTaskIndex(0);
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byType(TasksViewerApp),
              matchesGoldenFile('goldens/$name.png'),
            );
          },
          skip: skip,
          variant: TargetPlatformVariant.only(TargetPlatform.windows),
        );
      }
    }
  }
}
