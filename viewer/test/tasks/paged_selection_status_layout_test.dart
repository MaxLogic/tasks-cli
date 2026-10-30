import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/viewer_controls.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import '../support/model_store.dart';
import '../support/viewer_test_support.dart';

/// The shipped font wraps these lines; the test font would measure another app.
Future<void> loadSegoe() async {
  final font = FontLoader('Segoe UI');
  for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
    final file = File('C:/Windows/Fonts/$name');
    if (file.existsSync()) {
      font.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await font.load();
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
  await tester.pump(const Duration(milliseconds: 500));
}

/// The whole line, count and detail, fits the region without scrolling.
void expectReadable(WidgetTester tester, String text, String context) {
  final detail = find.descendant(
    of: find.byType(ViewerStatusLine),
    matching: find.text(text),
  );
  expect(detail, findsOneWidget, reason: context);
  final line = find.ancestor(
    of: detail,
    matching: find.byType(ViewerStatusLine),
  );
  final region = find.ancestor(
    of: line,
    matching: find.byType(ViewerPaneRegion),
  );
  expect(
    tester.getSize(region).height,
    greaterThanOrEqualTo(tester.getSize(line).height - 0.5),
    reason: '$context: "$text" is clipped',
  );
}

Future<void> checkStatus(
  WidgetTester tester,
  ViewerThemeMode theme,
  Size size, {
  required bool projects,
}) async {
  await loadSegoe();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = ModelStore(
    count: 1000,
    projectCount: 300,
    delay: Duration.zero,
  );
  await tester.pumpWidget(
    TasksViewerApp(
      environment: viewerTestEnvironment(
        suffix: 'status-${theme.name}-${size.width.toInt()}-$projects',
      ),
      windowsAnimationsEnabled: () => false,
      initialSettings: ViewerSettingsDraft(
        themeMode: theme,
        projectState: ProjectStateFilter.all,
        projectSort: ProjectSort.name,
        projectDirection: SortDirection.ascending,
      ),
      readers: ViewerDataReader(
        projects: store,
        tasks: store,
        detail: store,
        probe: store.probe,
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  final model = tester
      .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
      .model;
  final shell = tester.state<ViewerShellState>(find.byType(ViewerShell));
  await pumpUntil(tester, () => model.projectList.totalCount > 0);
  model.selectProjectIndex(0);
  await pumpUntil(tester, () => model.tasks != null);
  model.tasks!.restoreState(const TaskListState(sort: TaskSort.id));
  unawaited(model.tasks!.reload());
  await pumpUntil(tester, () => model.tasks!.totalCount == 1000);
  final region = projects ? ViewerRegion.projects : ViewerRegion.tasks;
  final list = shell.handlesFor(region).list;
  list.focusRegion();
  await tester.pump(const Duration(milliseconds: 200));
  list.goToIndex(150);
  await tester.pump(const Duration(seconds: 1));
  final dynamic c = projects ? model.projectList : model.tasks!;
  final id = c.selectedIndex == null ? null : c.selection.id;
  expect(id, isNotNull);
  final context = '${theme.name} $size projects=$projects';

  c.setQuery(projects ? 'Project' : 'needle');
  unawaited(c.submitQuery() as Future<void>);
  await pumpUntil(tester, () => c.unplacedLabel != null);
  expectReadable(tester, c.unplacedLabel as String, '$context unlocated');

  store.failure = (_) => const ViewerCliErrorFailure(
    code: 'locked',
    message: 'The task store is locked',
    exitCode: 4,
  );
  unawaited(c.refresh() as Future<void>);
  await pumpUntil(tester, () => c.refreshFailure != null);
  store.failure = null;
  expectReadable(
    tester,
    'Refresh failed: The task store is locked The rows below are the last '
        'confirmed data.',
    '$context failure',
  );

  if (projects) {
    store.projects.removeWhere((p) => p.projectId == id);
    store.version++;
  }
  unawaited(c.refresh() as Future<void>);
  await pumpUntil(tester, () => c.retainedText != null);
  expectReadable(tester, c.retainedText as String, '$context retained');

  await tester.pumpWidget(const SizedBox());
  store.close();
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  for (final theme in [
    ViewerThemeMode.light,
    ViewerThemeMode.highContrastLight,
  ]) {
    for (final size in const [
      Size(1600, 900),
      Size(1366, 768),
      Size(1100, 620),
    ]) {
      for (final projects in [false, true]) {
        testWidgets(
          'UX9 ${projects ? 'Projects' : 'Tasks'} status stays readable '
          '${theme.name} ${size.width.toInt()}',
          (tester) => checkStatus(tester, theme, size, projects: projects),
          variant: TargetPlatformVariant.only(TargetPlatform.windows),
        );
      }
    }
  }
}
