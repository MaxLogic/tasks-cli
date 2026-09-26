/// Look-and-feel regressions of the real workspace: empty-state actions,
/// spacing between labelled fields, compact combo values, row action targets,
/// displayed paths, heading alignment and high-contrast dividers.
///
/// Contract: viewer/design.md sections 2, 4, 5 and 6.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';
import 'package:tasks_viewer/ui/viewer_format.dart';

import '../support/viewer_test_support.dart';

/// A catalog whose selected project has tasks but none open, so the default
/// Open-tasks scope matches nothing.
FakeWorkspaceReads _noOpenTasks() {
  final project = testProjectItem(1);
  return fakeWorkspaceReads(
    projects: <ProjectItem>[project],
    tasks: <String, List<TaskItem>>{
      project.projectId: <TaskItem>[testTaskItem(1, status: 'done')],
    },
  );
}

Finder _inPane(Type pane, Finder matching) =>
    find.descendant(of: find.byType(pane), matching: matching);

void main() {
  group('viewerDisplayPath', () {
    test('drops the Win32 verbatim prefix from a drive path', () {
      expect(viewerDisplayPath(r'\\?\F:\projects\x'), r'F:\projects\x');
    });
    test('turns a verbatim UNC path back into a UNC path', () {
      expect(viewerDisplayPath(r'\\?\UNC\server\share\x'), r'\\server\share\x');
    });
    test('keeps ordinary paths unchanged', () {
      expect(viewerDisplayPath(r'C:\work\a'), r'C:\work\a');
      expect(viewerDisplayPath(r'\\server\share'), r'\\server\share');
      expect(viewerDisplayPath('/home/user/x'), '/home/user/x');
    });
  });

  testWidgets('tasks empty state carries Clear filters inside the list', (
    tester,
  ) async {
    final harness = await pumpRealViewer(tester, reads: _noOpenTasks());
    harness.model.selectProjectIndex(0);
    await tester.pumpAndSettle();

    final list = _inPane(ViewerTasksPane, find.byType(AccessibleVirtualList));
    final clear = find.descendant(
      of: list,
      matching: find.widgetWithText(TextButton, 'Clear filters'),
    );
    expect(clear, findsOneWidget);
    // The reason is stated once, by the list, not again by the status line.
    expect(
      _inPane(ViewerTasksPane, find.text('No tasks match these filters')),
      findsOneWidget,
    );

    // Keyboard: the button is the next stop after the empty list itself.
    harness.list(ViewerRegion.tasks).focusRegion();
    await tester.pumpAndSettle();
    await pressKey(tester, LogicalKeyboardKey.tab);
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: clear,
        matching: find.byElementPredicate((element) => element == focused),
      ),
      findsOneWidget,
    );

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(harness.reads.lastTaskRequest.scope, TaskScope.open);
  });

  testWidgets('project filters leave room under helper text and between rows', (
    tester,
  ) async {
    await pumpRealViewer(tester);
    final helper = tester.getRect(
      _inPane(ViewerProjectsPane, find.text('Search name, path or project ID')),
    );
    final stateLabel = tester.getRect(
      _inPane(ViewerProjectsPane, find.text('State filter (Alt+S)')),
    );
    expect(stateLabel.top, greaterThanOrEqualTo(helper.bottom + 4));

    final stateBox = tester.getRect(
      _inPane(
        ViewerProjectsPane,
        find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<ProjectStateFilter>,
        ),
      ),
    );
    final sortLabel = tester.getRect(
      _inPane(ViewerProjectsPane, find.text('Sort (Alt+O)')),
    );
    if (sortLabel.top > stateBox.top + 4) {
      // Wrapped onto its own run: the floating label must not touch the box
      // above it.
      expect(sortLabel.top, greaterThanOrEqualTo(stateBox.bottom + 4));
    }
  });

  testWidgets('state combo shows its value without the access key', (
    tester,
  ) async {
    await pumpRealViewer(tester);
    final combo = _inPane(
      ViewerProjectsPane,
      find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField<ProjectStateFilter>,
      ),
    );
    expect(
      find.descendant(of: combo, matching: find.text('With open tasks')),
      findsOneWidget,
    );
    await tester.tap(combo);
    await tester.pumpAndSettle();
    expect(find.text('All projects (Alt+1)'), findsOneWidget);
    await pressKey(tester, LogicalKeyboardKey.escape);
  });

  testWidgets('project row action button is a 32px target beside the text', (
    tester,
  ) async {
    await pumpRealViewer(tester);
    final button = find.byTooltip('Actions for Project 1');
    final rect = tester.getRect(button);
    expect(rect.width, greaterThanOrEqualTo(32));
    expect(rect.height, greaterThanOrEqualTo(32));
    final progress = tester.getRect(find.text('Not applicable').first);
    expect(rect.left, greaterThanOrEqualTo(progress.right + 8));
  });

  testWidgets('verbatim roots are displayed without the \\\\?\\ prefix', (
    tester,
  ) async {
    const raw = r'\\?\F:\projects\verbatim';
    final project = ProjectItem(
      archivedAtMs: null,
      projectId: '00000000-0000-4000-8000-000000000009',
      name: 'Verbatim',
      roots: const <String>[raw],
      availability: ProjectAvailability.available,
      error: null,
      sampledAtMs: 1700000000000,
      stats: const ProjectStats(
        total: 1,
        open: 1,
        blocked: 0,
        done: 0,
        cancelled: 0,
        startedMs: null,
        lastWriteMs: null,
        progressPercent: null,
      ),
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final harness = await pumpRealViewer(
      tester,
      reads: fakeWorkspaceReads(projects: <ProjectItem>[project]),
    );
    harness.model.selectProjectIndex(0);
    await tester.pumpAndSettle();
    expect(find.textContaining(r'\\?\'), findsNothing);
    expect(find.textContaining(r'F:\projects\verbatim'), findsWidgets);
    await pressKey(tester, LogicalKeyboardKey.f1);
    await pressKey(tester, LogicalKeyboardKey.keyF);
    expect(copied, r'F:\projects\verbatim');
  });

  testWidgets('pane headings share one baseline', (tester) async {
    final harness = await pumpRealViewer(tester);
    harness.model.selectProjectIndex(0);
    await tester.pumpAndSettle();
    final projects = tester.getRect(find.text('Projects').first);
    final tasks = tester.getRect(find.text('Tasks in Project 1'));
    final details = tester.getRect(find.text('Task details').first);
    expect(tasks.top, projects.top);
    expect(details.top, projects.top);
  });

  testWidgets('high-contrast shell dividers are as tall as they are thick', (
    tester,
  ) async {
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(suffix: 'hc-dividers'),
        initialSettings: const ViewerSettingsDraft(
          themeMode: ViewerThemeMode.highContrastDark,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final thickness = Theme.of(
      tester.element(find.byType(ViewerShell)),
    ).dividerTheme.thickness!;
    expect(thickness, 2);
    final dividers = tester.widgetList<Divider>(
      find.descendant(
        of: find.byType(ViewerShell),
        matching: find.byType(Divider),
      ),
    );
    expect(dividers, isNotEmpty);
    for (final divider in dividers) {
      expect(divider.height, greaterThanOrEqualTo(thickness));
    }
  });
}
