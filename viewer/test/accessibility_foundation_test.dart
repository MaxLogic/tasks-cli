/// Slice 1 proof: the Windows accessibility foundation.
///
/// Contract: viewer/spec.md sections 5 and 9, viewer/design.md sections 2, 6 and
/// 9 with walkthrough A. These tests drive the real shell over the synthetic
/// 10,000-row prototype: generated Hotkey help, F1/F2/F3 and Ctrl+F/Ctrl+H focus
/// targets, virtual-list focus beyond row 100, empty-list container focus,
/// Ctrl+E list-only routing, modal isolation with focus restoration, labelled
/// field/enum/status semantics and text scaling.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/keyboard_help_dialog.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';

import 'support/viewer_test_support.dart';

void main() {
  group('command registry', () {
    test('ids are unique and every entry is described', () {
      final ids = commandRegistry.map((spec) => spec.id).toList();
      expect(ids.length, greaterThanOrEqualTo(100));
      expect(ids.toSet(), hasLength(ids.length));
      for (final spec in commandRegistry) {
        expect(spec.label, isNotEmpty, reason: spec.id);
        expect(spec.description, isNotEmpty, reason: spec.id);
        expect(spec.shortcutLabel, isNotEmpty, reason: spec.id);
      }
    });

    test('every activator resolves to its own command inside its scope', () {
      for (final spec in commandRegistry) {
        final shortcuts = shortcutMapForScope(spec.scope);
        for (final activator in spec.activators) {
          final intent = shortcuts[activator];
          final described = '${spec.id} (${describeActivator(activator)})';
          expect(intent, isA<CommandIntent>(), reason: described);
          expect((intent! as CommandIntent).id, spec.id, reason: described);
        }
      }
    });

    test('every dialog scope binds Escape and F10', () {
      for (final scope in CommandScope.values.where(isDialogScope)) {
        final shortcuts = shortcutMapForScope(scope);
        expect(
          shortcuts.values.map((intent) => (intent as CommandIntent).id),
          contains('dialogs.dismiss'),
          reason: scope.name,
        );
        expect(
          shortcuts.values.map((intent) => (intent as CommandIntent).id),
          contains('dialogs.hotkeyHelp'),
          reason: scope.name,
        );
      }
    });

    test('Hotkey help lists every group and is searchable', () {
      final entries = helpEntriesFor(CommandScope.projects);
      expect(
        entries.map((entry) => entry.group).toSet(),
        containsAll(HelpGroup.values),
      );
      expect(
        searchHelpEntries(entries, 'F1').map((entry) => entry.spec.id),
        contains('global.focusProjects'),
      );
      expect(
        searchHelpEntries(
          entries,
          'focus text filter',
        ).map((entry) => entry.spec.id),
        contains('global.focusFilter'),
      );
      expect(
        searchHelpEntries(entries, 'ctrl+d').map((entry) => entry.spec.id),
        contains('global.markDone'),
      );
      expect(searchHelpEntries(entries, 'zzz-no-such-command'), isEmpty);
    });
  });

  group('region focus', () {
    testWidgets('a launch starts in the Projects region', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      expect(harness.shell.activeRegion, ViewerRegion.projects);
      expect(harness.list(ViewerRegion.projects).selectedIndex, 0);
      expect(harness.list(ViewerRegion.projects).focusedRowIndex, 0);
    });

    testWidgets('F1, F2 and F3 focus their labelled targets', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(harness.shell.activeRegion, ViewerRegion.tasks);
      expect(harness.list(ViewerRegion.tasks).focusedRowIndex, 0);
      expect(harness.list(ViewerRegion.projects).focusedRowIndex, isNull);

      await pressKey(tester, LogicalKeyboardKey.f1);
      expect(harness.shell.activeRegion, ViewerRegion.projects);
      expect(harness.list(ViewerRegion.projects).focusedRowIndex, 0);
      expect(harness.list(ViewerRegion.tasks).focusedRowIndex, isNull);

      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.shell.activeRegion, ViewerRegion.details);
      expect(harness.focusedDebugLabel, 'details description');
    });

    testWidgets('Ctrl+F follows the focused collection, Ctrl+H finds in body', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      await pressControl(tester, LogicalKeyboardKey.keyF);
      expect(harness.focusedDebugLabel, 'projects filter');

      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressControl(tester, LogicalKeyboardKey.keyF);
      expect(harness.focusedDebugLabel, 'tasks filter');

      // Task details is not a collection, so the last collection wins.
      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressControl(tester, LogicalKeyboardKey.keyF);
      expect(harness.focusedDebugLabel, 'tasks filter');

      await pressControl(tester, LogicalKeyboardKey.keyH);
      expect(harness.focusedDebugLabel, 'details find');
      expect(harness.shell.activeRegion, ViewerRegion.details);
    });
  });

  group('virtual collections', () {
    testWidgets('list focus travels past row 100 with a position label', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpViewer(tester);
        final projects = harness.list(ViewerRegion.projects);

        projects.goToIndex(150);
        await tester.pumpAndSettle();

        expect(projects.selectedIndex, 150);
        expect(projects.focusedRowIndex, 150);
        expect(projects.hasListFocus, isTrue);
        final row = find.bySemanticsLabel(RegExp(r'^Project 00151\. Root '));
        expect(row, findsOneWidget);
        // design.md section 6: the position travels as one nonduplicating
        // label, spoken after the row name and never spliced into it.
        expect(tester.getSemantics(row).value, 'row 151 of 10000');
        expect(find.text('Selected project: Project 00151'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('End reaches the last row of the 10,000-row list', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);
      final projects = harness.list(ViewerRegion.projects);

      await pressKey(tester, LogicalKeyboardKey.end);

      expect(projects.selectedIndex, 9999);
      expect(projects.focusedRowIndex, 9999);
    });

    testWidgets('an empty collection focuses its list container', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpViewer(tester);

        await tester.enterText(
          textFieldWithLabel('Search projects (Ctrl+F)'),
          'zzz-no-such-project',
        );
        await tester.pumpAndSettle();

        // The empty container carries the collection name and the reason in
        // one accessible name, so nothing has to be discovered by hovering.
        expect(
          find.bySemanticsLabel(RegExp('No projects match these filters')),
          findsWidgets,
        );

        await pressKey(tester, LogicalKeyboardKey.f2);
        await pressKey(tester, LogicalKeyboardKey.f1);

        final projects = harness.list(ViewerRegion.projects);
        expect(projects.focusedRowIndex, isNull);
        expect(projects.hasFocus, isTrue);
        expect(harness.focusedDebugLabel, 'list-region');
        expect(harness.shell.activeRegion, ViewerRegion.projects);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Ctrl+E acts only from the Projects list itself', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      // The launch focus is the Projects list, so the action runs.
      await pressControl(tester, LogicalKeyboardKey.keyE);
      expect(harness.log.enrichments, 1);

      // From the Projects filter the key is not a list action.
      await pressControl(tester, LogicalKeyboardKey.keyF);
      expect(harness.focusedDebugLabel, 'projects filter');
      await pressControl(tester, LogicalKeyboardKey.keyE);
      expect(harness.log.enrichments, 1);

      // Nor is it one from the Tasks collection.
      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressControl(tester, LogicalKeyboardKey.keyE);
      expect(harness.log.enrichments, 1);
    });
  });

  group('modals', () {
    testWidgets('Ctrl+D opens the dirty mark-done modal and Escape restores '
        'focus', (WidgetTester tester) async {
      final harness = await pumpViewer(tester);

      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.focusedDebugLabel, 'details description');

      await pressControl(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      const dialogTitle = 'Mark task done with unsaved changes?';
      expect(find.text(dialogTitle), findsOneWidget);
      expect(harness.shell.modalDepth, 1);
      // design.md section 8: a dialog opens on its safe action.
      expect(harness.focusedDebugLabel, isNull);
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);

      // F1 must not reach the Projects list behind the modal.
      await pressKey(tester, LogicalKeyboardKey.f1);
      expect(harness.list(ViewerRegion.projects).hasListFocus, isFalse);
      expect(find.text(dialogTitle), findsOneWidget);

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(find.text(dialogTitle), findsNothing);
      expect(harness.shell.modalDepth, 0);
      expect(harness.focusedDebugLabel, 'details description');
    });

    testWidgets('a modal makes the window dispatch refuse background work', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressControl(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(harness.shell.modalDepth, 1);

      final result = harness.shell.dispatchFromScope(
        CommandScope.global,
        'global.enrichClipboard',
      );
      expect(result, KeyEventResult.handled);
      expect(harness.log.enrichments, 0);
    });

    testWidgets('Settings opens on its first setting and keeps Alt keys', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);

      await pressControl(tester, LogicalKeyboardKey.comma);
      await tester.pumpAndSettle();

      expect(find.text('Save (Ctrl+S)'), findsOneWidget);
      expect(harness.focusedDebugLabel, 'settings cli path');

      await pressAlt(tester, LogicalKeyboardKey.keyD);
      expect(harness.focusedDebugLabel, 'settings data root');

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(find.text('Save (Ctrl+S)'), findsNothing);
      expect(harness.shell.modalDepth, 0);
    });
  });

  group('labels and scaling', () {
    testWidgets('collection, field, enum and status controls are labelled', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpViewer(tester);

        expect(
          find.bySemanticsLabel(RegExp(r'Search projects \(Ctrl\+F\)')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp(r'Projects')), findsWidgets);
        expect(
          find.bySemanticsLabel(RegExp(r'Description \(F3\)')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp('Status')), findsWidgets);
        expect(
          find.bySemanticsLabel(RegExp(r'Find in body \(Ctrl\+H\)')),
          findsOneWidget,
        );

        // design.md section 9: F6 moves to the next region in order and
        // Shift+F6 reverses it.
        await pressKey(tester, LogicalKeyboardKey.f6);
        expect(harness.shell.activeRegion, ViewerRegion.tasks);
        expect(harness.focusedDebugLabel, 'list-row-0');

        await pressKey(tester, LogicalKeyboardKey.f6);
        expect(harness.shell.activeRegion, ViewerRegion.details);

        await pressKey(tester, LogicalKeyboardKey.f6);
        expect(harness.shell.activeRegion, ViewerRegion.status);
        expect(harness.focusedDebugLabel, 'status region');

        await pressShift(tester, LogicalKeyboardKey.f6);
        expect(harness.shell.activeRegion, ViewerRegion.details);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a larger text size moves the layout to fewer panes', (
      WidgetTester tester,
    ) async {
      final wide = await pumpViewer(tester);
      expect(wide.shell.layoutMode, ViewerLayoutMode.threePane);

      final scaled = await pumpViewer(
        tester,
        surface: const Size(1600, 900),
        platformTextScale: 1.5,
      );
      expect(scaled.shell.layoutMode, ViewerLayoutMode.twoPane);
      // The region shortcuts still work in the reduced layout.
      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(scaled.shell.activeRegion, ViewerRegion.details);
      expect(scaled.focusedDebugLabel, 'details description');

      final narrow = await pumpViewer(
        tester,
        surface: const Size(1000, 900),
        platformTextScale: 2,
      );
      expect(narrow.shell.layoutMode, ViewerLayoutMode.singlePane);
      expect(find.byType(SegmentedButton<ViewerRegion>), findsOneWidget);
      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(narrow.shell.activeRegion, ViewerRegion.tasks);
      expect(narrow.list(ViewerRegion.tasks).focusedRowIndex, 0);
    });

    testWidgets('row extent follows the active text scale', (
      WidgetTester tester,
    ) async {
      // design.md section 2: the extent is derived, never a fixed height that
      // clips scaled text.
      double projectsExtent() => tester
          .widget<AccessibleVirtualList>(
            find.descendant(
              of: find.byType(PrototypeProjectsPane),
              matching: find.byType(AccessibleVirtualList),
            ),
          )
          .itemExtent;

      await pumpViewer(tester);
      expect(projectsExtent(), 56);

      // The same pane at 200% text: the rows must grow, and a clipped row
      // would fail this test with a RenderFlex overflow.
      await pumpViewer(tester, platformTextScale: 2);
      expect(projectsExtent(), greaterThan(56));
      expect(find.text('Project 00001'), findsOneWidget);
    });

    testWidgets('reduced layouts keep pane state without hidden focus', (
      WidgetTester tester,
    ) async {
      final harness = await pumpViewer(tester);
      expect(harness.shell.layoutMode, ViewerLayoutMode.threePane);

      harness.list(ViewerRegion.projects).goToIndex(42);
      await tester.pumpAndSettle();
      expect(find.text('Selected project: Project 00043'), findsOneWidget);

      await resizeViewer(tester, const Size(1100, 900));
      expect(harness.shell.layoutMode, ViewerLayoutMode.twoPane);
      expect(harness.list(ViewerRegion.projects).selectedIndex, 42);

      // Task details replaces the Tasks pane here. The replaced pane keeps its
      // state but must leave the focus tree, and the reveal still lands focus.
      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.shell.activeRegion, ViewerRegion.details);
      expect(harness.focusedDebugLabel, 'details description');
      expect(harness.handles(ViewerRegion.tasks).regionFocus.hasFocus, isFalse);
      expect(harness.list(ViewerRegion.tasks).hasListFocus, isFalse);

      await resizeViewer(tester, const Size(900, 900));
      expect(harness.shell.layoutMode, ViewerLayoutMode.singlePane);
      expect(harness.focusedDebugLabel, 'details description');
      expect(harness.list(ViewerRegion.projects).selectedIndex, 42);

      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(harness.shell.activeRegion, ViewerRegion.tasks);
      expect(harness.list(ViewerRegion.tasks).focusedRowIndex, 0);
    });
  });
}
