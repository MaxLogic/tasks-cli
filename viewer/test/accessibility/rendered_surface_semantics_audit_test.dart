/// Whole-tree accessibility checks for popup and reduced-workspace states.
///
/// The checks assert Flutter's rendered semantics tree. They do not establish
/// native Windows accessibility or screen-reader speech.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/details_pane.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';

import '../helpers/semantics_audit.dart';
import '../support/viewer_test_support.dart';

void main() {
  testWidgets('project and task menus and filters expose named semantics', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await pumpRealViewer(tester);

      await pressKey(tester, LogicalKeyboardKey.contextMenu);
      expect(find.text('Open in Explorer (E)'), findsOneWidget);
      expectAccessibleSemantics(tester);
      expect(
        tester.getSemantics(find.text('Open in Explorer (E)')).label,
        'Open in Explorer (E)',
      );
      await pressKey(tester, LogicalKeyboardKey.escape);

      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressKey(tester, LogicalKeyboardKey.contextMenu);
      expect(find.text('Copy ID and name (C)'), findsOneWidget);
      expectAccessibleSemantics(tester);
      expect(
        tester.getSemantics(find.text('Copy ID and name (C)')).label,
        'Copy ID and name (C)',
      );
      await pressKey(tester, LogicalKeyboardKey.escape);

      await tester.tap(find.text('Filters (Open tasks)'));
      await tester.pumpAndSettle();
      final projectState = find.descendant(
        of: find.byType(ViewerProjectsPane),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButtonFormField<ProjectStateFilter>,
        ),
      );
      await tester.ensureVisible(projectState);
      await tester.tap(projectState);
      await tester.pumpAndSettle();
      expect(find.text('All projects (Alt+1)'), findsOneWidget);
      expectAccessibleSemantics(tester);
      await pressKey(tester, LogicalKeyboardKey.escape);

      final projectSort = find.descendant(
        of: find.byType(ViewerProjectsPane),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButtonFormField<ProjectSort>,
        ),
      );
      await tester.tap(projectSort);
      await tester.pumpAndSettle();
      expect(find.text('Open tasks'), findsWidgets);
      expectAccessibleSemantics(tester);
      await pressKey(tester, LogicalKeyboardKey.escape);

      final taskSort = find.descendant(
        of: find.byType(ViewerTasksPane),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButtonFormField<TaskSort>,
        ),
      );
      await tester.ensureVisible(taskSort);
      await tester.tap(taskSort);
      await tester.pumpAndSettle();
      expect(find.text('Priority'), findsWidgets);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('enrichment preview exposes its text and close action', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final enricher = FakeClipboardEnricher()
        ..answer = testClipboardEnrichment(
          text: 'T-1: First task and T-404',
          replacements: 1,
          unknownIds: const <int>[404],
        );
      final harness = await pumpRealViewer(
        tester,
        enricher: enricher,
        clipboard: FakeViewerClipboard(text: 'T-1 and T-404'),
      );
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.f1);
      await pressAlt(tester, LogicalKeyboardKey.keyP);

      expect(find.text('Enrichment preview'), findsOneWidget);
      expect(renderedHasNamedRoute(tester, 'Enrichment preview'), isTrue);
      expect(
        find.bySemanticsLabel('Original clipboard text (Alt+O)'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Enriched text (Alt+R)'), findsOneWidget);
      expect(find.bySemanticsLabel('Close (Alt+C)'), findsOneWidget);
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('each details tab state passes the rendered semantics audit', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await harness.model.openTaskIndex(0);
      await tester.pumpAndSettle();

      const shortcuts = <LogicalKeyboardKey>[
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ];
      for (final key in shortcuts) {
        await pressAlt(tester, key);
        expect(find.byType(ViewerDetailsPane), findsOneWidget);
        expectAccessibleSemantics(tester);
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('narrow workspace and task recovery states pass the audit', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final reads = fakeWorkspaceReads()
        ..taskFailure = const ViewerCliErrorFailure(
          code: 'locked',
          message: 'task database is locked',
          exitCode: 4,
        );
      final harness = await pumpRealViewer(
        tester,
        reads: reads,
        surface: const Size(900, 800),
      );
      expect(harness.shell.layoutMode, ViewerLayoutMode.singlePane);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);

      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(find.text('task database is locked'), findsOneWidget);
      expectAccessibleSemantics(tester);

      await resizeViewer(tester, const Size(1100, 800));
      expect(harness.shell.layoutMode, ViewerLayoutMode.twoPane);
      expectAccessibleSemantics(tester);

      // A first-run setup launch also presents the Settings form as a modal.
      final announcements = AnnouncementController(
        clipPlayer: RecordingClipPlayer(),
        mode: AnnouncementMode.nvdaOnly,
      );
      addTearDown(announcements.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerShell(
            environment: const ViewerEnvironment(
              launchArgs: ViewerLaunchArgs(),
              settingsRoot: r'C:\viewer-test\setup',
              dataRoot: null,
              tasksExe: null,
            ),
            announcements: announcements,
            workspaceBuilder: buildPrototypeWorkspace,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Set up Tasks Viewer'), findsOneWidget);
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });
}
