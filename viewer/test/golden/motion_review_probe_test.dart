// Opt-in review screenshots; no checked-in reference images.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import 'package:tasks_viewer/ui/viewer_motion.dart';
import '../support/viewer_test_support.dart';

const _out = String.fromEnvironment('TASKS_VIEWER_MOTION_RENDER_ROOT');
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
  for (final (theme, name) in [
    (ViewerThemeMode.dark, 'dark'),
    (ViewerThemeMode.highContrastDark, 'hc'),
    (ViewerThemeMode.light, 'light'),
  ]) {
    for (final size in [const Size(1280, 720), const Size(2000, 830)]) {
      testWidgets(
        'review $name $size',
        (tester) async {
          await _fonts();
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final project = testProjectItem(
            1,
            name: 'Tasks viewer',
            total: 1000,
            open: 1000,
          );
          final reads = fakeWorkspaceReads(
            projects: [project],
            tasks: {
              project.projectId: [
                for (var i = 1; i <= 1000; i++)
                  testTaskItem(
                    i,
                    title: 'Keep keyboard focus and NVDA names stable, task $i',
                  ),
              ],
            },
            details: {
              1: testTaskDetail(
                1,
                title: 'Button icons and transitions',
                body:
                    'Use the keyboard to find a project, read its tasks, and edit a task.\n\nAnimations follow Windows. Focus and announcements take effect immediately.\n\nThis is synthetic review data.',
                rules:
                    '# Viewer rules\nPreserve names, focus and stored task data.',
              ),
            },
          );
          await tester.pumpWidget(
            TasksViewerApp(
              environment: viewerTestEnvironment(suffix: 'review'),
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
          final stem = '${name}_${size.width.toInt()}x${size.height.toInt()}';
          Future<void> capture(String state) async {
            if (_out.isEmpty) return;
            await expectLater(
              find.byType(TasksViewerApp),
              matchesGoldenFile(Uri.file('$_out/${stem}_$state.png')),
            );
          }

          await capture('settled');
          model.showTab(TaskDetailTab.rules);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          expect(
            tester
                .widgetList<FadeTransition>(
                  find.descendant(
                    of: find.byType(ViewerEnterTransition),
                    matching: find.byType(FadeTransition),
                  ),
                )
                .any((f) => f.alwaysIncludeSemantics && f.opacity.value < 1),
            isTrue,
          );
          await capture('tab_60ms');
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Show filters (Alt+F)'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          await capture('filters_60ms');
          await tester.pumpAndSettle();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }
}
