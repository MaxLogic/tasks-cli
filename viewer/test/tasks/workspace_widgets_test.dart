/// Real three-pane workspace widgets: task rows, the cross-page jump, loading
/// feedback, focus retention and the reduced-layout rule.
///
/// Contract: viewer/spec.md sections 4.3, 5, 6 and 9 with viewer/design.md
/// sections 2, 5 and 6. Every launch injects the synthetic reader and a
/// temporary settings root, so no test can reach the real task store
/// (spec.md section 3).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';

import '../support/viewer_test_support.dart';

/// Project UUID the default synthetic catalog uses.
const String firstProjectId = '00000000-0000-4000-8000-000000000001';

/// One page of synthetic tasks for [count] rows, ids `1..count`.
List<TaskItem> _taskRange(int count) => <TaskItem>[
  for (var id = 1; id <= count; id++) testTaskItem(id, title: 'Task $id'),
];

/// Pumps the real workspace with the first project selected and its tasks
/// loaded, so each test starts from the browser the user would see.
Future<RealViewerHarness> pumpTaskBrowser(
  WidgetTester tester, {
  FakeWorkspaceReads? reads,
  Size surface = const Size(1600, 900),
  double textScale = 1,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = await pumpRealViewer(tester, reads: reads, surface: surface);
  harness.model.selectProjectIndex(0);
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets(
    'task heading is contextual and All status toggles every status',
    (tester) async {
      final harness = await pumpTaskBrowser(tester);
      expect(find.text('Tasks'), findsNothing);
      expect(find.text('Tasks in Project 1'), findsOneWidget);
      expect(harness.model.tasks!.scope, TaskScope.open);
      expect(harness.model.tasks!.statuses, isEmpty);
      await tester.tap(find.text('Filters (Open tasks)'));
      await tester.pumpAndSettle();

      final allRow = find
          .ancestor(of: find.text('All'), matching: find.byType(Row))
          .first;
      final allCheckbox = find.descendant(
        of: allRow,
        matching: find.byType(Checkbox),
      );
      await tester.tap(allCheckbox);
      await tester.pumpAndSettle();
      expect(harness.model.tasks!.scope, TaskScope.all);
      expect(harness.model.tasks!.statuses, containsAll(viewerTaskStatuses));

      await tester.tap(allCheckbox);
      await tester.pumpAndSettle();
      expect(harness.model.tasks!.scope, TaskScope.open);
      expect(harness.model.tasks!.statuses, isEmpty);
    },
  );

  testWidgets(
    'compact task filters leave search available and reveal shortcuts',
    (tester) async {
      final harness = await pumpTaskBrowser(tester);
      expect(find.text('Filters (Open tasks)'), findsOneWidget);
      expect(find.text('Search tasks (Ctrl+F)'), findsOneWidget);
      expect(find.text('Scope (Alt+S)'), findsNothing);
      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressAlt(tester, LogicalKeyboardKey.keyT);
      expect(find.text('Status (Alt+T)'), findsOneWidget);
      expect(harness.focusedDebugLabel, 'tasks status all');
      await tester.tap(find.text('Hide filters'));
      await tester.pumpAndSettle();
      expect(harness.focusedDebugLabel, 'tasks filters toggle');
      expect(find.text('Scope (Alt+S)'), findsNothing);
      expect(find.text('Search tasks (Ctrl+F)'), findsOneWidget);
      await pressAlt(tester, LogicalKeyboardKey.keyO);
      expect(
        find.descendant(
          of: find.byType(ViewerTasksPane),
          matching: find.text('Sort (Alt+O)'),
        ),
        findsOneWidget,
      );
      expect(harness.focusedDebugLabel, 'tasks sort');
    },
  );

  testWidgets('project row menu exposes compact actions and copies its path', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
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
    await pumpRealViewer(tester);
    expect(find.bySemanticsLabel('Actions for Project 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Actions for Project 1'));
    await tester.pumpAndSettle();
    expect(find.text('Open in Explorer'), findsOneWidget);
    expect(find.text('Open in Alacritty'), findsOneWidget);
    expect(find.text('Open in Terminal'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Copy project ID'), findsOneWidget);
    expect(find.text('Enrich clipboard'), findsWidgets);

    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();
    expect(copied, testProjectItem(1).roots.first);
    semantics.dispose();
  });

  testWidgets('clicking a project row loads its tasks', (tester) async {
    final harness = await pumpRealViewer(
      tester,
      reads: fakeWorkspaceReads(
        tasks: {
          firstProjectId: [testTaskItem(7, title: 'Clicked project task')],
        },
      ),
      surface: const Size(1600, 900),
    );
    await tester.tap(find.text('Project 1').first);
    await tester.pumpAndSettle();
    expect(harness.model.tasks?.projectId, firstProjectId);
    expect(find.text('Clicked project task'), findsOneWidget);
  });

  group('task rows', () {
    testWidgets('a row speaks its identifying fields and its position', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = await pumpTaskBrowser(
          tester,
          reads: fakeWorkspaceReads(
            tasks: {
              firstProjectId: [
                testTaskItem(
                  7,
                  title: 'Repair the viewer',
                  status: 'blocked',
                  priority: 'P1',
                  labels: ['ui', 'a11y'],
                  waitingDependencyCount: 2,
                ),
              ],
            },
          ),
        );
        expect(harness.model.tasks!.totalCount, 1);

        final row = find.bySemanticsLabel(
          RegExp(r'^T-007, P1, Blocked, Repair the viewer'),
        );
        expect(row, findsOneWidget);
        expect(
          tester.getSemantics(row).label,
          'T-007, P1, Blocked, Repair the viewer. Labels ui, a11y. '
          'Waiting on 2 dependencies',
        );
        expect(tester.getSemantics(row).value, 'row 1 of 1');
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a cross-page jump loads and focuses the row it names', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final reads = fakeWorkspaceReads(
          tasks: {firstProjectId: _taskRange(250)},
        );
        final harness = await pumpTaskBrowser(tester, reads: reads);
        expect(harness.model.tasks!.totalCount, 250);

        await tester.enterText(tasksGoToRowField(), '200');
        await tester.tap(tasksGoButton());
        await tester.pumpAndSettle();

        final list = harness.list(ViewerRegion.tasks);
        expect(list.selectedIndex, 199);
        expect(list.focusedRowIndex, 199);
        final row = find.bySemanticsLabel(RegExp(r'^T-200,'));
        expect(row, findsOneWidget);
        expect(tester.getSemantics(row).value, 'row 200 of 250');
        expect(
          reads.taskRequests.map((query) => query.offset),
          containsAll(<int>[0, 100, 200]),
          reason: 'the jump reads the page that owns row 200',
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a row number outside the list is refused without moving', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskBrowser(tester);
      final before = harness.list(ViewerRegion.tasks).selectedIndex;

      await tester.enterText(tasksGoToRowField(), '900');
      await tester.tap(tasksGoButton());
      await tester.pumpAndSettle();

      const message = 'Enter a row number from 1 to 3. Nothing moved.';
      expect(
        find.descendant(
          of: find.byType(ViewerTasksPane),
          matching: find.text(message),
        ),
        findsOneWidget,
        reason: 'the refusal stays visible next to the Go to row control',
      );
      expect(harness.liveText, message);
      expect(harness.list(ViewerRegion.tasks).selectedIndex, before);
      expect(harness.model.tasks!.selectedTaskId, isNull);
    });

    testWidgets('a refused row reaches the engine announce channel', (
      WidgetTester tester,
    ) async {
      final log = <Map<dynamic, dynamic>>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            dynamic message,
          ) async {
            log.add(message as Map<dynamic, dynamic>);
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );

      await pumpTaskBrowser(tester);
      await tester.enterText(tasksGoToRowField(), '900');
      await tester.tap(tasksGoButton());
      await tester.pumpAndSettle();

      // The Windows bridge drops SemanticsFlag.isLiveRegion, so the status
      // message must leave through the engine announce channel once.
      const message = 'Enter a row number from 1 to 3. Nothing moved.';
      final announced = log
          .where((entry) => entry['type'] == 'announce')
          .map((entry) => (entry['data'] as Map<dynamic, dynamic>)['message'])
          .where((text) => text == message);
      expect(announced, hasLength(1));
    });
  });

  group('keyboard path', () {
    testWidgets('F2 focuses the Task list and Enter opens Task details', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskBrowser(tester);

      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(harness.shell.activeRegion, ViewerRegion.tasks);
      expect(harness.focusedDebugLabel, 'list-row-0');
      expect(harness.list(ViewerRegion.tasks).selectedIndex, 0);

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(harness.reads.detailRequests, <int>[1]);
      expect(harness.model.detail!.taskId, 1);
      expect(find.text('body text'), findsOneWidget);
      expect(find.text('Dependencies'), findsOneWidget);
      expect(
        harness.list(ViewerRegion.tasks).focusedRowIndex,
        0,
        reason: 'opening a task does not move the Task list focus',
      );
    });

    testWidgets('F5 refresh keeps the Task list selection and focus', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskBrowser(tester);
      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      expect(harness.list(ViewerRegion.tasks).focusedRowIndex, 1);
      expect(harness.model.tasks!.selectedTaskId, 2);

      await pressKey(tester, LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();

      final list = harness.list(ViewerRegion.tasks);
      expect(list.selectedIndex, 1);
      expect(list.focusedRowIndex, 1);
      expect(harness.model.tasks!.selectedTaskId, 2);
      expect(harness.shell.activeRegion, ViewerRegion.tasks);
    });
  });

  group('loading feedback', () {
    testWidgets('a task read under 500 ms keeps the live channel quiet', (
      WidgetTester tester,
    ) async {
      final harness = await pumpTaskBrowser(tester);
      await harness.model.openTaskIndex(0);
      await tester.pumpAndSettle();

      expect(harness.model.detail!.hasDetail, isTrue);
      expect(harness.liveText, isNull);
    });

    testWidgets('a slow task read announces loading after half a second', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        latency: const Duration(milliseconds: 800),
      );
      final harness = await pumpRealViewer(tester, reads: reads, settle: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      harness.model.selectProjectIndex(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(harness.model.tasks!.totalCount, 3);

      unawaited(harness.model.openTaskIndex(0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        harness.liveText,
        isNull,
        reason: 'a read that may still finish quickly stays silent',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.statusText, 'Loading task T-001');
      expect(harness.liveText, 'Loading task T-001');

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('body text'), findsOneWidget);
    });

    testWidgets('a slow row jump announces the row it waits for', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        tasks: {firstProjectId: _taskRange(250)},
        latency: const Duration(milliseconds: 1500),
      );
      final harness = await pumpRealViewer(tester, reads: reads, settle: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      harness.model.selectProjectIndex(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(harness.model.tasks!.totalCount, 250);

      await tester.enterText(tasksGoToRowField(), '200');
      await tester.tap(tasksGoButton());
      await tester.pump(const Duration(milliseconds: 500));
      expect(harness.statusText, 'Loading row 200');
      expect(
        harness.liveText,
        isNull,
        reason: 'progress is coalesced behind the announcement delay',
      );

      await tester.pump(const Duration(milliseconds: 600));
      expect(harness.liveText, 'Loading row 200');
      expect(harness.list(ViewerRegion.tasks).hasPendingTarget, isTrue);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(harness.list(ViewerRegion.tasks).focusedRowIndex, 199);
    });

    testWidgets('End reaches the last row after its page loads', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final reads = fakeWorkspaceReads(
          tasks: {firstProjectId: _taskRange(250)},
          latency: const Duration(milliseconds: 1500),
        );
        final harness = await pumpRealViewer(
          tester,
          reads: reads,
          settle: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1500));
        harness.model.selectProjectIndex(0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1500));
        expect(harness.model.tasks!.totalCount, 250);

        final list = harness.list(ViewerRegion.tasks);
        list.focusRegion();
        await tester.pump();
        expect(list.focusedRowIndex, 0);

        // The last row is still a placeholder when End is pressed. The page that
        // owns it arrives while the focus request is in flight, so the loaded
        // row replaces the placeholder under a different item key.
        await tester.sendKeyEvent(LogicalKeyboardKey.end, platform: 'windows');
        await tester.pump(const Duration(milliseconds: 16));
        expect(list.selectedIndex, 249, reason: 'selection moves immediately');

        await tester.pump(const Duration(milliseconds: 2000));
        await tester.pumpAndSettle();

        expect(list.selectedIndex, 249);
        expect(
          list.focusedRowIndex,
          249,
          reason: 'an End jump lands on the row it had to load first',
        );
        final row = find.bySemanticsLabel(RegExp(r'^T-250,'));
        expect(row, findsOneWidget);
        expect(tester.getSemantics(row).value, 'row 250 of 250');

        // Home is the same contract in the other direction: the first filtered
        // row, with focus, from wherever the list happens to be.
        await tester.sendKeyEvent(LogicalKeyboardKey.home, platform: 'windows');
        await tester.pump(const Duration(milliseconds: 16));
        expect(list.selectedIndex, 0, reason: 'selection moves immediately');

        await tester.pump(const Duration(milliseconds: 2000));
        await tester.pumpAndSettle();

        expect(list.selectedIndex, 0);
        expect(list.focusedRowIndex, 0, reason: 'Home selects the first row');
        expect(
          tester.getSemantics(find.bySemanticsLabel(RegExp(r'^T-001,'))).value,
          'row 1 of 250',
        );
      } finally {
        semantics.dispose();
      }
    });
  });

  group('layout', () {
    testWidgets(
      'the reduced layout keeps hidden panes mounted but unspeaking',
      (WidgetTester tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final harness = await pumpTaskBrowser(
            tester,
            surface: const Size(800, 600),
          );
          expect(harness.shell.layoutMode, ViewerLayoutMode.singlePane);
          expect(harness.shell.activeRegion, ViewerRegion.projects);
          expect(harness.model.tasks!.totalCount, 3);

          expect(
            find.bySemanticsLabel('Search projects (Ctrl+F)'),
            findsOneWidget,
          );
          expect(find.bySemanticsLabel('Search tasks (Ctrl+F)'), findsNothing);
          expect(
            find.text('Search tasks (Ctrl+F)', skipOffstage: false),
            findsOneWidget,
            reason: 'a hidden pane keeps its state without taking speech',
          );

          await pressKey(tester, LogicalKeyboardKey.f2);
          expect(harness.shell.activeRegion, ViewerRegion.tasks);
          expect(
            find.bySemanticsLabel('Search tasks (Ctrl+F)'),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel('Search projects (Ctrl+F)'),
            findsNothing,
          );
          expect(harness.model.tasks!.totalCount, 3);
        } finally {
          semantics.dispose();
        }
      },
    );

    const cases = <String, (Size, double)>{
      '1600x900 at 100 percent text': (Size(1600, 900), 1),
      '800x600 at 100 percent text': (Size(800, 600), 1),
      '800x600 at 200 percent text': (Size(800, 600), 2),
      '1600x900 at 200 percent text': (Size(1600, 900), 2),
    };
    for (final entry in cases.entries) {
      final (size, scale) = entry.value;
      testWidgets('the workspace paints at ${entry.key} without overflow', (
        WidgetTester tester,
      ) async {
        final harness = await pumpTaskBrowser(
          tester,
          surface: size,
          textScale: scale,
        );
        await harness.model.openTaskIndex(0);
        await tester.pumpAndSettle();

        final errors = <String>[];
        for (var attempt = 0; attempt < 8; attempt++) {
          final failure = tester.takeException();
          if (failure == null) {
            break;
          }
          errors.add(failure.toString().replaceAll(RegExp(r'\s+'), ' ').trim());
        }
        expect(errors, isEmpty);
        expect(find.text('Tasks Viewer'), findsOneWidget);
        expect(find.text('Select a task to read its details.'), findsNothing);
      });
    }
  });
}
