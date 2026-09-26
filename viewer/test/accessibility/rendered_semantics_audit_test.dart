/// Broad rendered-tree accessibility checks for representative viewer states.
///
/// These tests inspect Flutter semantics and exercise the specified keyboard
/// paths. They cannot prove NVDA speech or the Windows accessibility bridge;
/// those remain separate release gates in viewer/spec.md V10.
library;

import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoSlider;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';
import 'package:tasks_viewer/ui/commands.dart';
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
      await tester.tap(find.byTooltip('Show filters (Alt+F)'));
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

  testWidgets('Settings audits every scroll position and exposes volume name', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpRealViewer(tester);
      await pressControl(tester, LogicalKeyboardKey.comma);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'settings cli path',
      );
      final scrollable = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      // The original audit inspected only the first viewport, missing controls
      // clipped below it. Inspect overlapping viewports through the entire form.
      for (double offset = 0; ; offset += position.viewportDimension / 2) {
        position.jumpTo(offset.clamp(0, position.maxScrollExtent));
        await tester.pumpAndSettle();
        expectAccessibleSemantics(tester);
        if (offset >= position.maxScrollExtent) break;
      }
      final sliderNode = visibleSemanticsNodes(
        tester,
      ).singleWhere((node) => node.getSemanticsData().flagsCollection.isSlider);
      final slider = sliderNode.getSemanticsData();
      expect(slider.label, 'Bella volume (Alt+V)');
      expect(slider.value, '70%');
      expect(slider.hasAction(ui.SemanticsAction.increase), isTrue);
      expect(slider.hasAction(ui.SemanticsAction.decrease), isTrue);
      final owner = tester.binding.renderViews.single.owner!.semanticsOwner!;
      owner.performAction(sliderNode.id, ui.SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.byType(CupertinoSlider)).value, '80%');
      owner.performAction(sliderNode.id, ui.SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.byType(CupertinoSlider)).value, '70%');
      await pressAlt(tester, LogicalKeyboardKey.keyV);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings volume');
      await pressKey(tester, LogicalKeyboardKey.arrowRight);
      expect(tester.getSemantics(find.byType(CupertinoSlider)).value, '80%');
      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(find.byType(Dialog), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'Settings Tab reaches every control with visible focused semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpRealViewer(tester);
        await pressKey(tester, LogicalKeyboardKey.f1);
        final previous = FocusManager.instance.primaryFocus;
        await pressControl(tester, LogicalKeyboardKey.comma);
        final first = FocusManager.instance.primaryFocus;
        final names = <String>[];
        for (var step = 0; step < 30; step++) {
          final focused = visibleSemanticsNodes(tester)
              .where(
                (node) =>
                    node.getSemanticsData().flagsCollection.isFocused ==
                    ui.Tristate.isTrue,
              )
              .toList();
          expect(
            focused,
            hasLength(1),
            reason:
                'Tab step $step: ${FocusManager.instance.primaryFocus?.debugLabel}',
          );
          names.add(focused.single.label);
          expectAccessibleSemantics(tester);
          await pressKey(tester, LogicalKeyboardKey.tab);
          if (FocusManager.instance.primaryFocus == first) break;
        }
        expect(
          FocusManager.instance.primaryFocus,
          same(first),
          reason: 'Tab must wrap inside Settings',
        );
        expect(
          names,
          containsAll(<Matcher>[
            startsWith('Tasks CLI path'),
            startsWith('Data root'),
            startsWith('Theme'),
            startsWith('Text size'),
            startsWith('Projects %'),
            startsWith('Tasks %'),
            startsWith('Details %'),
            startsWith('Start with Windows'),
            startsWith('Announcements'),
            startsWith('Bella volume'),
            startsWith('Test voice'),
            startsWith('Cancel'),
            startsWith('Save'),
          ]),
        );
        await pressKey(tester, LogicalKeyboardKey.escape);
        expect(FocusManager.instance.primaryFocus, same(previous));
      } finally {
        semantics.dispose();
      }
    },
  );

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

  final conflict = EditorConflict(
    baseVersion: 1,
    baseFields: TaskEditFields.fromDetail(testTaskDetail(1, title: 'Base')),
    draftFields: TaskEditFields.fromDetail(testTaskDetail(1, title: 'Mine')),
    current: testTaskDetail(1, title: 'Current', version: 2),
    changedFields: const [EditorField.title],
    conflictFields: const [EditorField.title],
  );

  testWidgets('all Settings dropdown menus expose named operable options', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpRealViewer(tester);
      await pressControl(tester, LogicalKeyboardKey.comma);
      final menus = <(Finder, String, String)>[
        (
          find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<ViewerThemeMode>,
          ),
          'Theme (Alt+H)',
          'Dark',
        ),
        (
          find.byWidgetPredicate((w) => w is DropdownButtonFormField<int>),
          'Text size (Alt+Z)',
          '125%',
        ),
        (
          find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<AnnouncementMode>,
          ),
          'Announcements (Alt+A)',
          'Off',
        ),
      ];
      for (final (field, label, option) in menus) {
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        final menuButton = visibleSemanticsNodes(tester).singleWhere(
          (node) =>
              node.label.startsWith(label) &&
              node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        );
        tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
          menuButton.id,
          ui.SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expectAccessibleSemantics(tester);
        final choice = visibleSemanticsNodes(tester).singleWhere(
          (n) =>
              n.label == option &&
              n.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        );
        tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
          choice.id,
          ui.SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(tester.getSemantics(field).label, contains(option));
        expect(tester.getSemantics(field).label, contains(label));
      }
      await pressKey(tester, LogicalKeyboardKey.escape);
    } finally {
      semantics.dispose();
    }
  });
  final editorRoutes = <(String, CommandScope, Widget)>[
    (
      'Unsaved changes',
      CommandScope.unsavedChanges,
      const ViewerUnsavedChangesDialog(
        identity: 'T-001',
        title: 'Fixture task',
        question: 'Save before leaving?',
      ),
    ),
    (
      'Mark task done with unsaved changes?',
      CommandScope.markDoneDirty,
      const ViewerMarkDoneDirtyDialog(identity: 'T-001', title: 'Fixture task'),
    ),
    (
      'Version conflict',
      CommandScope.conflict,
      ViewerConflictDialog(conflict: conflict),
    ),
    (
      'Review against current',
      CommandScope.conflictReview,
      ViewerConflictReviewDialog(conflict: conflict),
    ),
    (
      'Restore draft',
      CommandScope.restoreDraft,
      const ViewerRestoreDraftDialog(
        identity: 'T-001',
        title: 'Fixture task',
        baseVersion: 1,
        currentVersion: 2,
      ),
    ),
    (
      'Save still running',
      CommandScope.slowSaveClose,
      const ViewerSlowSaveCloseDialog(identity: 'T-001'),
    ),
  ];
  for (final (title, scope, dialog) in editorRoutes) {
    testWidgets(
      'editor modal $title has named route, actions and contained focus',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final harness = await pumpRealViewer(tester);
          final completion = harness.shell.showModal<void>(
            scope,
            (_) => dialog,
          );
          await tester.pumpAndSettle();
          expect(renderedHasNamedRoute(tester, title), isTrue);
          expectAccessibleSemantics(tester);
          for (var i = 0; i < 12; i++) {
            await pressKey(tester, LogicalKeyboardKey.tab);
            expect(
              FocusManager.instance.primaryFocus?.context
                  ?.findAncestorWidgetOfExactType<Dialog>(),
              isNotNull,
            );
            expectAccessibleSemantics(tester);
          }
          await pressKey(tester, LogicalKeyboardKey.escape);
          await completion;
          expect(find.byType(Dialog), findsNothing);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
