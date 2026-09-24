/// Broad rendered-tree accessibility checks for representative viewer states.
///
/// These tests inspect Flutter semantics only. They cannot prove NVDA speech,
/// focus order, or the Windows accessibility bridge; those remain live release
/// gates in viewer/spec.md V10.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';

import '../helpers/semantics_audit.dart';
import '../support/viewer_test_support.dart';

void main() {
  testWidgets('the audit reports unnamed and inoperable controls and routes', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Semantics(
              label: 'Audit fixture',
              namesRoute: true,
              child: Column(
                children: <Widget>[
                  Semantics(
                    button: true,
                    enabled: true,
                    label: 'Named but broken',
                    child: const SizedBox(width: 48, height: 48),
                  ),
                  Semantics(
                    button: true,
                    onTap: () {},
                    tooltip: 'Tooltip without a name',
                    child: const SizedBox(width: 48, height: 48),
                  ),
                  Semantics(
                    button: true,
                    enabled: false,
                    tooltip: 'Disabled tooltip without a name',
                    child: const SizedBox(width: 48, height: 48),
                  ),
                  const TextField(),
                  Semantics(
                    scopesRoute: true,
                    explicitChildNodes: true,
                    child: const Text('Dialog content without a route name'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final problems = auditRenderedSemantics(
        tester,
      ).map((failure) => failure.problem).toList();
      expect(problems, contains('enabled button or link has no tap action'));
      expect(problems, contains('interactive control has no accessible name'));
      expect(
        problems.where(
          (problem) => problem == 'interactive control has no accessible name',
        ),
        hasLength(3), // Two buttons plus the unnamed editable field.
      );
      expect(problems, contains('text field has no accessible name'));
      expect(problems, contains('route scope has no accessible name'));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'the populated default workspace exposes operable named controls',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpRealViewer(tester);

        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        expectAccessibleSemantics(tester);

        for (final label in <String>[
          'Refresh (F5)',
          'Settings (Ctrl+,)',
          'Hotkey help (F10)',
        ]) {
          final button = tester
              .getSemantics(
                find.descendant(
                  of: find.byTooltip(label),
                  matching: find.byType(IconButton),
                ),
              )
              .getSemanticsData();
          expect(button.label, label);
          expect(button.flagsCollection.isButton, isTrue);
          expect(button.flagsCollection.isFocused, isNot(ui.Tristate.none));
          expect(button.hasAction(ui.SemanticsAction.tap), isTrue);
        }

        final project = tester.getSemantics(
          find.bySemanticsLabel(RegExp(r'^Project 1\.')),
        );
        expect(project.value, 'row 1 of 2');
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('the initial loading state passes the rendered semantics audit', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpRealViewer(
        tester,
        reads: fakeWorkspaceReads(latency: const Duration(seconds: 2)),
        settle: false,
      );

      expect(find.bySemanticsLabel('Loading projects'), findsOneWidget);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('an expanded dropdown passes the rendered semantics audit', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filters (Open tasks)'));
      await tester.pumpAndSettle();
      expectAccessibleSemantics(tester);

      final readiness = find.descendant(
        of: find.byType(ViewerTasksPane),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButtonFormField<TaskReadiness>,
        ),
      );
      await tester.ensureVisible(readiness);
      await tester.pumpAndSettle();
      await tester.tap(readiness);
      await tester.pumpAndSettle();

      expect(find.text('Waiting for dependencies'), findsOneWidget);
      final dropdown = tester.getSemantics(readiness).getSemanticsData();
      expect(dropdown.flagsCollection.isExpanded, ui.Tristate.isTrue);
      expect(dropdown.hasAction(ui.SemanticsAction.tap), isTrue);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the clean editor exposes Save as a named disabled button', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = await pumpRealViewer(tester, update: FakeTaskWriter());
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      await harness.model.openTaskIndex(0);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.f4);

      final saveFinder = find.widgetWithText(FilledButton, 'Save (Ctrl+S)');
      final save = tester.getSemantics(saveFinder).getSemanticsData();
      expect(save.label, 'Save (Ctrl+S)');
      expect(save.flagsCollection.isButton, isTrue);
      expect(save.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(save.hasAction(ui.SemanticsAction.tap), isFalse);

      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('settings and keyboard-help dialogs pass the rendered audit', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpRealViewer(tester);

      final settings = tester.getSemantics(
        find.descendant(
          of: find.byTooltip('Settings (Ctrl+,)'),
          matching: find.byType(IconButton),
        ),
      );
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        settings.id,
        ui.SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(renderedHasNamedRoute(tester, 'Settings'), isTrue);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final help = tester.getSemantics(
        find.descendant(
          of: find.byTooltip('Hotkey help (F10)'),
          matching: find.byType(IconButton),
        ),
      );
      tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
        help.id,
        ui.SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.text('Keyboard help'), findsOneWidget);
      expect(renderedHasNamedRoute(tester, 'Keyboard help'), isTrue);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the first-load error state exposes named recovery actions', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final reads = fakeWorkspaceReads()
        ..projectFailure = const ViewerCliErrorFailure(
          code: 'locked',
          message: 'database is locked',
          exitCode: 4,
        );
      await pumpRealViewer(tester, reads: reads);

      expect(find.text('database is locked'), findsOneWidget);
      expect(find.bySemanticsLabel('Retry'), findsOneWidget);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expectAccessibleSemantics(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('empty collections do not offer invalid row navigation', (
    WidgetTester tester,
  ) async {
    await pumpRealViewer(
      tester,
      reads: fakeWorkspaceReads(projects: const <ProjectItem>[]),
    );

    expect(find.text('Go to row'), findsNothing);
    expect(find.text('1 to 0'), findsNothing);
  });
}
