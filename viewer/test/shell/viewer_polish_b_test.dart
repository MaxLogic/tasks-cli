/// Look-and-feel regressions, second batch: the selected-project footer, the
/// type scale, the Task details empty state and the compact Filters button.
///
/// Contract: viewer/design.md sections 2, 4, 5 and 7.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/details_pane.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';

import '../support/viewer_test_support.dart';

Finder _inPane(Type pane, Finder matching) =>
    find.descendant(of: find.byType(pane), matching: matching);

void main() {
  for (final size in const <Size>[Size(1280, 720), Size(1600, 800)]) {
    testWidgets(
      'selected-project actions stay on screen at ${size.width.toInt()}x'
      '${size.height.toInt()}',
      (tester) async {
        final harness = await pumpRealViewer(tester, surface: size);
        harness.model.selectProjectIndex(0);
        await tester.pumpAndSettle();
        final pane = tester.getRect(find.byType(ViewerProjectsPane));
        for (final label in <String>[
          'Copy project ID (Alt+Y)',
          'Enrich clipboard (Alt+E)',
          'Preview enrichment (Alt+P)',
        ]) {
          final button = _inPane(
            ViewerProjectsPane,
            find.widgetWithText(FilledButton, label),
          );
          expect(button, findsOneWidget, reason: label);
        }
        // The test font is far wider than Segoe UI, so the pane wraps every
        // label; the primary action must still be on screen. The golden test
        // checks all three with the real font.
        final copy = tester.getRect(
          find.widgetWithText(FilledButton, 'Copy project ID (Alt+Y)'),
        );
        expect(copy.bottom, lessThanOrEqualTo(pane.bottom));
        expect(copy.top, greaterThanOrEqualTo(pane.top));
        // Label and value sit in two aligned columns.
        final uuidLabel = tester.getRect(
          _inPane(ViewerProjectsPane, find.text('UUID')),
        );
        final tasksLabel = tester.getRect(
          _inPane(ViewerProjectsPane, find.text('Counts')),
        );
        expect(uuidLabel.left, tasksLabel.left);
      },
    );
  }

  testWidgets('the app theme uses the viewer type scale', (tester) async {
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(suffix: 'type-scale'),
        initialSettings: const ViewerSettingsDraft(
          themeMode: ViewerThemeMode.highContrastDark,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(ViewerShell)));
    expect(theme.textTheme.bodySmall!.fontSize, 13);
    expect(theme.textTheme.bodyMedium!.fontSize, 14);
    expect(theme.textTheme.titleLarge!.fontSize, 20);
    // High contrast survives the type scale.
    expect(theme.dividerTheme.thickness, 2);
  });

  testWidgets('Task details empty state is a top-aligned keyboard hint', (
    tester,
  ) async {
    await pumpRealViewer(tester);
    final pane = tester.getRect(find.byType(ViewerDetailsPane));
    final hint = _inPane(
      ViewerDetailsPane,
      find.text('Select a task to read its details.'),
    );
    expect(hint, findsOneWidget);
    expect(tester.getRect(hint).top, lessThan(pane.top + 80));
    expect(
      _inPane(ViewerDetailsPane, find.textContaining('F4')),
      findsOneWidget,
    );
  });

  testWidgets('Filters button shows a count badge and a scope chip', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final harness = await pumpRealViewer(tester);
    harness.model.selectProjectIndex(0);
    await tester.pumpAndSettle();
    final button = find.byTooltip('Show filters (Alt+F)');
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('Filters')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: button, matching: find.text('Open tasks')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: button, matching: find.byType(Badge)),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Filters \(Open tasks\)')),
      findsOneWidget,
    );

    harness.model.tasks!.setReadiness(
      TaskReadiness.values.firstWhere((value) => value != TaskReadiness.any),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: button, matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Filters \(Open tasks, 1 active\)')),
      findsOneWidget,
    );
    expect(_inPane(ViewerTasksPane, find.byType(Badge)), findsOneWidget);
    handle.dispose();
  });
}
