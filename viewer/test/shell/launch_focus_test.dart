/// Focus while the first project read is still running.
///
/// Contract: viewer/design.md section 6 and section 9. The list keeps the
/// focus inside its own region while the target row is loading, and the row
/// that finally takes focus *is* the selection the panes read. A selection
/// seeded while the list was empty must still reach the model, or Task details
/// shows nothing and F3 has no body to focus.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';

import '../support/viewer_test_support.dart';

const String firstProjectId = '00000000-0000-4000-8000-000000000001';

Future<RealViewerHarness> pumpSlowFirstRead(WidgetTester tester) async {
  final reads = fakeWorkspaceReads(
    latency: const Duration(milliseconds: 400),
  );
  final harness = await pumpRealViewer(tester, reads: reads, settle: false);
  // The first frame has no rows yet, so the focus sits in the list region
  // instead of falling to the window root.
  expect(harness.focusedDebugLabel, 'list-region');
  expect(harness.list(ViewerRegion.projects).selectedIndex, isNull);

  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  return harness;
}

/// Lets the reads a selection starts (Tasks, Task details) finish so the test
/// does not end on a pending timer.
Future<void> drainReads(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// The Projects list, so a semantics walk covers one list instead of the whole
/// shell (the Tasks list is mounted beside it).
Finder projectsList() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is AccessibleVirtualList && widget.listLabel == 'Projects',
);

/// Semantics nodes that tell the platform they hold the keyboard focus.
///
/// The platform takes the focused element it reports from these flags, so a
/// collection whose container and row both claim focus hands the container to
/// the screen reader even though F1/F2 landed on the row (viewer/design.md
/// section 9).
List<SemanticsNode> focusedSemanticsNodes(WidgetTester tester) {
  // The test binding keeps one semantics tree per view and hands out no root
  // node, so start at the list under test and climb to the root.
  var root = tester.getSemantics(projectsList());
  SemanticsNode? parent = root.parent;
  while (parent != null) {
    root = parent;
    parent = root.parent;
  }
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isFocused == Tristate.isTrue) {
      nodes.add(node);
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return nodes;
}

void dumpSemantics(SemanticsNode node, [int depth = 0]) {
  final SemanticsData data = node.getSemanticsData();
  debugPrint(
    '${'  ' * depth}${data.label} | ${data.flagsCollection}',
  );
  node.visitChildren((SemanticsNode child) {
    dumpSemantics(child, depth + 1);
    return true;
  });
}

void main() {
  group('launch focus', () {
    testWidgets('the row focus after a slow load still reaches the model', (
      WidgetTester tester,
    ) async {
      final harness = await pumpSlowFirstRead(tester);

      // The rows arrived while the list held its container, so the seed index
      // never travelled to the model on its own.
      expect(harness.focusedDebugLabel, 'list-region');
      expect(harness.model.selectedProjectId, isNull);

      await pressKey(tester, LogicalKeyboardKey.f1);

      expect(harness.focusedDebugLabel, 'list-row-0');
      expect(harness.list(ViewerRegion.projects).focusedRowIndex, 0);
      expect(harness.model.selectedProjectId, firstProjectId);

      await drainReads(tester);
    });

    testWidgets('Ctrl+F works from the list container before any row focus', (
      WidgetTester tester,
    ) async {
      final harness = await pumpSlowFirstRead(tester);
      expect(harness.focusedDebugLabel, 'list-region');

      await pressControl(tester, LogicalKeyboardKey.keyF);

      expect(harness.focusedDebugLabel, 'projects filter');
    });

    testWidgets('the row alone claims focus after F1 from the container', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final harness = await pumpSlowFirstRead(tester);
      // The empty list parked the focus on the container, and the rows that
      // arrived later did not take it back on their own.
      expect(harness.focusedDebugLabel, 'list-region');
      final before = focusedSemanticsNodes(tester);
      dumpSemantics(tester.getSemantics(projectsList()));
      expect(before.map((node) => node.label), <String>['Projects']);

      await pressKey(tester, LogicalKeyboardKey.f1);
      expect(harness.focusedDebugLabel, 'list-row-0');

      // The container callback is ancestor-inclusive and also fires when a row
      // takes focus, so re-flagging the container there would leave two nodes
      // claiming the focus the platform reports.
      final after = focusedSemanticsNodes(tester);
      expect(after, hasLength(1));
      expect(after.single.label, contains('Project 1'));

      handle.dispose();
      await drainReads(tester);
    });
  });
}
