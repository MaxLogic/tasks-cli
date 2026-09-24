/// Real Task details read views: tab semantics, dependency navigation, history
/// snapshots, Find in body and the read-only empty/failure states.
///
/// Contract: viewer/spec.md section 6 with viewer/design.md section 7 and the
/// Task details rows of section 9. Every launch injects the synthetic reader
/// and a temporary settings root, so no test can reach the real task store
/// (spec.md section 3).
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/details_pane.dart';

import '../support/viewer_test_support.dart';

/// Project UUID the default synthetic catalog uses.
const String firstProjectId = '00000000-0000-4000-8000-000000000001';

/// Opens the first task of the first project, so each test starts from the
/// read view the user would see after Enter on a task row.
Future<RealViewerHarness> pumpTaskDetails(
  WidgetTester tester, {
  FakeWorkspaceReads? reads,
  int index = 0,
}) async {
  final harness = await pumpRealViewer(tester, reads: reads);
  harness.model.selectProjectIndex(0);
  await tester.pumpAndSettle();
  await harness.model.openTaskIndex(index);
  await tester.pumpAndSettle();
  return harness;
}

/// One tab of the details pane; its own label lives on the merged tab node.
Finder detailsTab(String label) => find.descendant(
  of: find.byType(ViewerDetailsPane),
  matching: find.text(label),
);

/// Semantics of one tab, reached the way a screen reader reaches it.
SemanticsData tabData(WidgetTester tester, String label) =>
    tester.getSemantics(detailsTab(label)).getSemanticsData();

/// One labelled control of the details pane.
Finder detailsField(String label) => find.descendant(
  of: find.byType(ViewerDetailsPane),
  matching: textFieldWithLabel(label),
);

/// One labelled row of the details pane.
Finder detailsRow(Pattern label) => find.descendant(
  of: find.byType(ViewerDetailsPane),
  matching: find.bySemanticsLabel(label),
);

/// The read-only body control of the Details tab.
TextField bodyField(WidgetTester tester) => tester.widget<TextField>(
  find.byKey(const ValueKey<String>('details-body')),
);

void main() {
  testWidgets('short task body fills the available details height', (
    tester,
  ) async {
    await pumpTaskDetails(tester);
    final size = tester.getSize(
      find.byKey(const ValueKey<String>('details-body')),
    );
    expect(size.height, greaterThan(300));
    expect(bodyField(tester).readOnly, isTrue);
  });

  group('tabs', () {
    testWidgets('the tab bar exposes four selectable tabs', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpTaskDetails(tester);

        final details = tabData(tester, 'Details');
        expect(details.role, SemanticsRole.tab);
        expect(details.flagsCollection.isSelected, Tristate.isTrue);
        expect(
          details.label,
          contains('Details'),
          reason: 'the tab names itself and its access key',
        );
        for (final label in <String>[
          'Dependencies',
          'History',
          'Project rules',
        ]) {
          final tab = tabData(tester, label);
          expect(tab.role, SemanticsRole.tab, reason: '$label is a tab');
          expect(
            tab.flagsCollection.isSelected,
            Tristate.isFalse,
            reason: '$label is not the active view',
          );
        }
        expect(
          tester
              .getSemantics(detailsTab('Details'))
              .parent
              ?.getSemanticsData()
              .role,
          SemanticsRole.tabBar,
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('the active view lives in a tab panel', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpTaskDetails(tester);
        final body = tester.getSemantics(
          find.byKey(const ValueKey<String>('details-body')),
        );
        expect(body.getSemanticsData().role, SemanticsRole.tabPanel);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Alt+1..Alt+4 switch views and keep focus on the tab', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskDetails(tester);
      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.focusedDebugLabel, 'details description');

      final shortcuts = <LogicalKeyboardKey, TaskDetailTab>{
        LogicalKeyboardKey.digit2: TaskDetailTab.dependencies,
        LogicalKeyboardKey.digit3: TaskDetailTab.history,
        LogicalKeyboardKey.digit4: TaskDetailTab.rules,
        LogicalKeyboardKey.digit1: TaskDetailTab.details,
      };
      for (final entry in shortcuts.entries) {
        await pressAlt(tester, entry.key);
        expect(harness.model.detail!.tab, entry.value);
        expect(
          harness.focusedDebugLabel,
          'details tab tab',
          reason: 'activating a view leaves focus on its tab',
        );
      }
    });

    testWidgets('arrow keys move the tab focus and Enter activates it', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpTaskDetails(tester);
        await pressKey(tester, LogicalKeyboardKey.f3);
        await pressAlt(tester, LogicalKeyboardKey.digit1);

        await pressKey(tester, LogicalKeyboardKey.arrowRight);
        expect(
          tabData(tester, 'Dependencies').flagsCollection.isFocused,
          Tristate.isTrue,
        );
        expect(
          harness.model.detail!.tab,
          TaskDetailTab.details,
          reason: 'moving the tab focus does not activate the view',
        );

        await pressKey(tester, LogicalKeyboardKey.enter);
        expect(harness.model.detail!.tab, TaskDetailTab.dependencies);
        expect(
          tabData(tester, 'Dependencies').flagsCollection.isSelected,
          Tristate.isTrue,
        );
      } finally {
        semantics.dispose();
      }
    });
  });

  group('dependencies', () {
    testWidgets('a row speaks its identity, readiness and position', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final reads = fakeWorkspaceReads(
          details: <int, TaskDetail>{
            1: testTaskDetail(
              1,
              title: 'First task',
              deps: <int>[7, 9],
              dependencySummaries: <DependencySummary>[
                testDependency(
                  7,
                  title: 'Repair the parser',
                  status: 'blocked',
                ),
                testDependency(9, title: 'Ship the fix', status: 'done'),
              ],
            ),
          },
        );
        await pumpTaskDetails(tester, reads: reads);
        await pressKey(tester, LogicalKeyboardKey.f3);
        await pressAlt(tester, LogicalKeyboardKey.digit2);

        final blocked = detailsRow(
          RegExp(r'^T-007, Blocked, Repair the parser\. Waiting'),
        );
        expect(blocked, findsOneWidget);
        expect(tester.getSemantics(blocked).value, 'row 1 of 2');

        final done = detailsRow(
          RegExp(r'^T-009, Done, Ship the fix\. Does not withhold readiness'),
        );
        expect(done, findsOneWidget);
        expect(tester.getSemantics(done).value, 'row 2 of 2');
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Alt+L reaches the list; Alt+O opens it and Alt+Left returns', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{
          1: testTaskDetail(
            1,
            title: 'First task',
            deps: <int>[2],
            dependencySummaries: <DependencySummary>[testDependency(2)],
          ),
          2: testTaskDetail(2, title: 'Second task'),
        },
      );
      final harness = await pumpTaskDetails(tester, reads: reads);
      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressAlt(tester, LogicalKeyboardKey.keyL);

      expect(harness.model.detail!.tab, TaskDetailTab.dependencies);
      expect(
        harness.list(ViewerRegion.details).focusedRowIndex,
        0,
        reason: 'Alt+L lands on the dependency list, not just its tab',
      );
      expect(harness.list(ViewerRegion.details).selectedIndex, 0);

      await pressAlt(tester, LogicalKeyboardKey.keyO);
      expect(harness.reads.detailRequests, <int>[1, 2]);
      expect(harness.model.detail!.taskId, 2);
      expect(harness.model.canGoBack, isTrue);
      expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.arrowLeft);
      expect(harness.reads.detailRequests, <int>[1, 2, 1]);
      expect(harness.model.detail!.taskId, 1);
      expect(harness.model.canGoBack, isFalse);
      expect(harness.model.detail!.hasDetail, isTrue);
      expect(find.widgetWithText(TextButton, 'Back'), findsNothing);
    });

    testWidgets('a task without dependencies says so', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpTaskDetails(tester);
        await pressKey(tester, LogicalKeyboardKey.f3);
        await pressAlt(tester, LogicalKeyboardKey.digit2);

        expect(harness.model.detail!.dependencies, isEmpty);
        expect(
          detailsRow(RegExp(r'^Dependencies of T-001\. No dependencies$')),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    });
  });

  group('history', () {
    testWidgets('history pages, opens a snapshot and loads more', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final reads = fakeWorkspaceReads(
          history: <int, List<HistoryEvent>>{
            1: <HistoryEvent>[
              for (var id = 1; id <= 250; id++)
                testHistoryEvent(id, snapshot: '{"event":$id}'),
            ],
          },
        );
        final harness = await pumpTaskDetails(tester, reads: reads);

        await pressKey(tester, LogicalKeyboardKey.f3);
        await pressAlt(tester, LogicalKeyboardKey.digit3);
        expect(harness.model.detail!.historyEvents.length, 100);
        expect(harness.model.detail!.historyHasMore, isTrue);
        expect(find.text('100 events loaded'), findsOneWidget);

        final first = detailsRow(RegExp(r'^Event 1, create, version 1, '));
        expect(first, findsOneWidget);
        expect(tester.getSemantics(first).value, 'row 1 of 100');

        await pressAlt(tester, LogicalKeyboardKey.keyV);
        expect(harness.list(ViewerRegion.details).focusedRowIndex, 0);
        await pressKey(tester, LogicalKeyboardKey.arrowDown);
        await pressKey(tester, LogicalKeyboardKey.enter);
        expect(harness.reads.eventRequests, <int>[2]);
        expect(harness.model.detail!.openedEventId, 2);
        expect(find.text('{"event":2}'), findsOneWidget);

        await tester.tap(find.text('Load more events'));
        await tester.pumpAndSettle();
        final events = harness.model.detail!.historyEvents;
        expect(events.length, 200);
        expect(events.first.eventId, 1);
        expect(events[100].eventId, 101);
        expect(events.last.eventId, 200);
        expect(harness.model.detail!.historyHasMore, isTrue);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a task without history says so and offers no more', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpTaskDetails(tester);
        await pressKey(tester, LogicalKeyboardKey.f3);
        await pressAlt(tester, LogicalKeyboardKey.digit3);

        expect(harness.model.detail!.historyEvents, isEmpty);
        expect(harness.model.detail!.historyHasMore, isFalse);
        expect(
          detailsRow(RegExp(r'^History of T-001\. No history events$')),
          findsOneWidget,
        );
        expect(find.text('No more events'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Alt+E and Alt+R reach the snapshot and the rules text', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        history: <int, List<HistoryEvent>>{
          1: <HistoryEvent>[testHistoryEvent(1, snapshot: '{"event":1}')],
        },
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task', rules: '# Rules body'),
        },
      );
      final harness = await pumpTaskDetails(tester, reads: reads);
      await pressKey(tester, LogicalKeyboardKey.f3);

      await pressAlt(tester, LogicalKeyboardKey.keyE);
      expect(
        harness.liveText,
        'Select a history event before reading its snapshot.',
        reason: 'the key explains itself before a snapshot exists',
      );

      await harness.model.selectHistoryEvent(1);
      await tester.pumpAndSettle();
      harness.model.showTab(TaskDetailTab.details);
      await tester.pumpAndSettle();

      await pressAlt(tester, LogicalKeyboardKey.keyE);
      expect(harness.model.detail!.tab, TaskDetailTab.history);
      expect(harness.focusedDebugLabel, 'details snapshot');
      expect(find.text('{"event":1}'), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyR);
      expect(harness.model.detail!.tab, TaskDetailTab.rules);
      expect(harness.focusedDebugLabel, 'details rules');
      expect(find.text('# Rules body'), findsOneWidget);
      expect(find.text('Rules version 3'), findsOneWidget);
    });
  });

  group('find in body', () {
    testWidgets('Ctrl+H focuses Find, and Escape returns to the body', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task', body: 'alpha beta alpha'),
        },
      );
      final harness = await pumpTaskDetails(tester, reads: reads);

      await pressControl(tester, LogicalKeyboardKey.keyH);
      expect(harness.focusedDebugLabel, 'details find');
      final findField = detailsField('Find in body (Ctrl+H)');
      expect(findField, findsOneWidget);

      await tester.enterText(findField, 'alpha');
      await tester.pumpAndSettle();
      expect(harness.model.detail!.matchCount, 2);
      expect(find.text('2 matches'), findsOneWidget);

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(harness.focusedDebugLabel, 'details description');
    });

    testWidgets('Next match walks the matches, reports count and wraps', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task', body: 'alpha beta alpha'),
        },
      );
      final harness = await pumpTaskDetails(tester, reads: reads);
      await pressKey(tester, LogicalKeyboardKey.f3);
      await tester.enterText(detailsField('Find in body (Ctrl+H)'), 'alpha');
      await tester.pumpAndSettle();

      await pressAlt(tester, LogicalKeyboardKey.keyN);
      expect(harness.liveText, 'Match 2 of 2');
      expect(
        bodyField(tester).controller!.selection,
        const TextSelection(baseOffset: 11, extentOffset: 16),
      );
      expect(harness.focusedDebugLabel, 'details description');

      await pressAlt(tester, LogicalKeyboardKey.keyN);
      expect(harness.liveText, 'Wrapped to the first match');
      expect(
        bodyField(tester).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );

      await pressAlt(tester, LogicalKeyboardKey.keyP);
      expect(harness.liveText, 'Wrapped to the last match');
      expect(
        bodyField(tester).controller!.selection,
        const TextSelection(baseOffset: 11, extentOffset: 16),
      );

      await pressAlt(tester, LogicalKeyboardKey.keyP);
      expect(harness.liveText, 'Match 1 of 2');
    });

    testWidgets('a search with no match says so without moving the caret', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task', body: 'alpha beta alpha'),
        },
      );
      final harness = await pumpTaskDetails(tester, reads: reads);
      await pressKey(tester, LogicalKeyboardKey.f3);
      await tester.enterText(detailsField('Find in body (Ctrl+H)'), 'gamma');
      await tester.pumpAndSettle();

      expect(find.text('No matches'), findsOneWidget);
      final caret = bodyField(tester).controller!.selection;
      await pressAlt(tester, LogicalKeyboardKey.keyN);
      expect(harness.model.detail!.matchCount, 0);
      expect(
        bodyField(tester).controller!.selection,
        caret,
        reason: 'a body that was never searched keeps its original caret',
      );
      expect(find.text('body text'), findsNothing);
      expect(bodyField(tester).controller!.text, 'alpha beta alpha');
      expect(bodyField(tester).readOnly, isTrue);
    });
  });

  group('body line endings', () {
    // A Windows-authored body: the store keeps its CRLF pairs, and the reader
    // must show every line without handing U+000D to the paragraph engine.
    final String crlfBody = <String>[
      for (int index = 1; index <= 60; index++)
        'line $index of a Windows-authored body\r\n',
      'MARKER-42\r\n',
    ].join();

    FakeWorkspaceReads crlfReads() => fakeWorkspaceReads(
      details: <int, TaskDetail>{
        1: testTaskDetail(1, title: 'First task', body: crlfBody),
      },
    );

    testWidgets('every line is laid out without carriage returns', (
      WidgetTester tester,
    ) async {
      await pumpTaskDetails(tester, reads: crlfReads());

      final String shown = bodyField(tester).controller!.text;
      expect(shown.contains('\r'), isFalse);
      expect(shown, crlfBody.replaceAll('\r\n', '\n'));
      expect(shown.split('\n').length, crlfBody.split('\r\n').length);
      expect(shown.endsWith('MARKER-42\n'), isTrue);
    });

    testWidgets('Find near the end selects the marker in the body', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskDetails(tester, reads: crlfReads());

      await pressKey(tester, LogicalKeyboardKey.f3);
      await tester.enterText(
        detailsField('Find in body (Ctrl+H)'),
        'MARKER-42',
      );
      await tester.pumpAndSettle();
      await pressAlt(tester, LogicalKeyboardKey.keyN);

      expect(harness.model.detail!.matchCount, 1);
      final TextEditingController controller = bodyField(tester).controller!;
      final TextSelection selection = controller.selection;
      expect(
        controller.text.substring(selection.start, selection.end),
        'MARKER-42',
      );
      expect(harness.focusedDebugLabel, 'details description');
    });

    testWidgets('Ctrl+C copies the selection with the stored line endings', (
      WidgetTester tester,
    ) async {
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpTaskDetails(tester, reads: crlfReads());
      await pressKey(tester, LogicalKeyboardKey.f3);

      final TextEditingController controller = bodyField(tester).controller!;
      final int start = controller.text.indexOf('line 60 ');
      controller.selection = TextSelection(
        baseOffset: start,
        extentOffset: controller.text.indexOf('MARKER-42') + 'MARKER-42'.length,
      );
      await tester.pump();
      await pressControl(tester, LogicalKeyboardKey.keyC);

      final MethodCall copy = platformCalls.firstWhere(
        (MethodCall call) => call.method == 'Clipboard.setData',
      );
      expect(
        (copy.arguments as Map<Object?, Object?>)['text'],
        'line 60 of a Windows-authored body\r\nMARKER-42',
      );
    });
  });

  group('actions and recovery', () {
    testWidgets('F4 opens the real editor on the selected task', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskDetails(tester);
      await pressKey(tester, LogicalKeyboardKey.f3);

      await pressKey(tester, LogicalKeyboardKey.f4);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.focusedDebugLabel, 'editor title');
      expect(harness.liveText, contains('Editing T-001'));

      await pressAlt(tester, LogicalKeyboardKey.keyC);
      expect(
        harness.model.editor.isEditing,
        isFalse,
        reason: 'Cancel on a clean draft leaves without a prompt',
      );
    });

    testWidgets(
      'Ctrl+D without a writable CLI keeps the read view and says so',
      (WidgetTester tester) async {
        final harness = await pumpTaskDetails(tester);
        await pressKey(tester, LogicalKeyboardKey.f3);

        await pressControl(tester, LogicalKeyboardKey.keyD);
        expect(harness.liveText, contains('No tasks CLI is available'));
        expect(harness.model.editor.isEditing, isFalse);
      },
    );

    testWidgets('Alt+C copies the task reference as plain text', (
      WidgetTester tester,
    ) async {
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final harness = await pumpTaskDetails(tester);
      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(harness.liveText, 'Task reference copied');
      final copy = platformCalls.firstWhere(
        (call) => call.method == 'Clipboard.setData',
      );
      expect(
        (copy.arguments as Map<Object?, Object?>)['text'],
        'T-001: First task',
      );
    });

    testWidgets('an unselected workspace asks for a task first', (
      WidgetTester tester,
    ) async {
      final harness = await pumpRealViewer(tester);
      expect(harness.model.detail?.taskId, isNull);
      expect(find.text('Select a task to read its details.'), findsOneWidget);
    });

    testWidgets('a failed read offers Retry and recovers on demand', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      reads.detailFailure = const ViewerCliErrorFailure(
        code: 'locked',
        message: 'database is locked',
        exitCode: 4,
      );
      final harness = await pumpTaskDetails(tester, reads: reads);

      expect(harness.model.detail!.hasDetail, isFalse);
      expect(find.text('Could not load task'), findsOneWidget);
      expect(find.text('database is locked'), findsOneWidget);

      reads.detailFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(harness.model.detail!.hasDetail, isTrue);
      expect(find.text('body text'), findsOneWidget);
      expect(find.text('Could not load task'), findsNothing);
    });
  });
}
