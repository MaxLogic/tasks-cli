/// Mid-animation regression for short-list reversal, using production panes.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import '../support/viewer_test_support.dart';

const _baseline = String.fromEnvironment(
  'TASKS_VIEWER_GOLDEN_BASELINE',
  defaultValue: 'windows-11',
);
const _out = String.fromEnvironment('TASKS_VIEWER_REORDER_RENDER_ROOT');

Future<void> _fonts() async {
  final font = FontLoader('Segoe UI');
  for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
    font.addFont(
      Future.value(
        ByteData.sublistView(File('C:/Windows/Fonts/$name').readAsBytesSync()),
      ),
    );
  }
  await font.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

void main() {
  final directory = switch (_baseline) {
    'windows-11' => 'goldens',
    'windows-server-2022' => 'goldens/windows-server-2022',
    _ => throw ArgumentError('Unknown golden baseline: $_baseline'),
  };
  for (final (theme, name) in [
    (ViewerThemeMode.light, 'light'),
    (ViewerThemeMode.highContrastLight, 'hc_light'),
  ]) {
    testWidgets(
      'reversal at 110ms: tasks and projects $name',
      (tester) async {
        await _fonts();
        final previousClock = taskSampleClock;
        taskSampleClock = () => 1790007180000;
        addTearDown(() => taskSampleClock = previousClock);
        tester.view.physicalSize = const Size(2000, 830);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
          const names = [
            'Alpha',
            'Bravo',
            'Charlie',
            'Delta',
            'Echo',
            'Foxtrot',
          ];
          final projects = [
            for (var i = 1; i <= 6; i++)
              testProjectItem(i, name: names[i - 1], total: 6, open: 6),
          ];
          final reads = fakeWorkspaceReads(
            projects: projects,
            tasks: {
              for (final p in projects)
                p.projectId: [
                  for (var i = 1; i <= 6; i++)
                    testTaskItem(i, title: 'Task number $i'),
                ],
            },
            details: {1: testTaskDetail(1)},
          );
          await tester.pumpWidget(
            TasksViewerApp(
              environment: viewerTestEnvironment(suffix: 'reversal-golden'),
              windowsAnimationsEnabled: () => true,
              initialSettings: ViewerSettingsDraft(themeMode: theme),
              readers: ViewerDataReader(
                projects: reads,
                tasks: reads,
                detail: reads,
                probe: reads.probe,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final model = tester
              .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
              .model;
          model.selectProjectIndex(0);
          await tester.pumpAndSettle();
          await model.openTaskIndex(0);
          await tester.pumpAndSettle();
          Future<void> capture(String kind, Type pane) async {
            final list = find.descendant(
              of: find.byType(pane),
              matching: find.byType(AccessibleVirtualList),
            );
            final fades = tester.widgetList<FadeTransition>(
              find.descendant(of: list, matching: find.byType(FadeTransition)),
            );
            expect(
              fades.any(
                (f) =>
                    f.alwaysIncludeSemantics &&
                    f.opacity.value > 0 &&
                    f.opacity.value < 1,
              ),
              isTrue,
            );
            final file = 'reversal_${kind}_${name}_110ms_2000x830.png';
            await expectLater(
              find.byType(TasksViewerApp),
              matchesGoldenFile('$directory/$file'),
            );
            if (_out.isNotEmpty) {
              await expectLater(
                find.byType(TasksViewerApp),
                matchesGoldenFile(Uri.file('$_out/$file')),
              );
            }
          }

          model.tasks!.setSort(TaskSort.id);
          await tester.pumpAndSettle();
          model.tasks!.setDirection(SortDirection.descending);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 110));
          await capture('tasks', ViewerTasksPane);
          await tester.pumpAndSettle();
          model.projectList.setSort(ProjectSort.name);
          await tester.pumpAndSettle();
          model.projectList.setDirection(SortDirection.descending);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 110));
          await capture('projects', ViewerProjectsPane);
          await tester.pumpAndSettle();
        } finally {
          semantics.dispose();
        }
      },
      skip: !Platform.isWindows,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
