/// Shared end-to-end scenarios: the real viewer over one real CLI store.
///
/// Contract: viewer/spec.md sections 3, 4, 5, 6, 7 and 11 (the V03, V04 and
/// V08 read/edit parts) with viewer/design.md sections 2..7. Two entry points
/// run these cases:
///
///  * `test/integration/viewer_e2e_headless_test.dart` — `flutter test`, the
///    headless binding. No window is created and no key, pointer or clipboard
///    event ever reaches the desktop; keys arrive through the test binding.
///  * `integration_test/viewer_test.dart` — the same cases on a real Windows
///    window (`flutter test integration_test/viewer_test.dart -d windows`),
///    which does open a window and therefore only runs with explicit approval.
///
/// Both drive the production widgets, the production [ViewerCliClient] and a
/// real `tasks.exe` over the harness-seeded throwaway store, so the rows,
/// statistics, keyboard paths and the persisted edit all come from the same
/// code the packaged application runs. Real process I/O only progresses inside
/// [WidgetTester.runAsync], so every interaction here happens in one.
///
/// The clipboard scope stays deliberately unwired: this suite must never read
/// or replace the clipboard of whoever is logged in (spec.md section 11).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/project_controller.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import 'viewer_e2e_fixture.dart';
import '../support/viewer_test_support.dart';

/// Registers every end-to-end case; both entry points call this once.
void viewerE2eScenarios() {
  final (fixture, reason) = ViewerE2eFixture.load();
  group('viewer end-to-end over a real CLI store', () {
    testWidgets(
      'the seeded catalog reaches the Projects pane with its statistics',
      (WidgetTester tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final window = await pumpViewerOverRealStore(tester, fixture!);
          await tester.runAsync(() async {
            await waitForRealWork(
              tester,
              () => window.projects.loadedRowCount >= fixture.projects.length,
              reason: 'the first project page never arrived from the real CLI',
            );
            expect(window.client.probePassed, isTrue);
            expect(window.projects.firstLoadError, isNull);
            expect(window.projects.totalCount, fixture.projects.length);
            for (final project in fixture.projects) {
              final row = find.bySemanticsLabel(
                RegExp('^${RegExp.escape(project.displayName)}\\. '),
              );
              expect(
                row,
                findsOneWidget,
                reason: 'project ${project.name} should be listed',
              );
              expect(
                tester.getSemantics(row).label,
                contains('${project.taskCount} total'),
                reason: 'the statistics must come from the seeded store',
              );
              expect(
                tester.getSemantics(row).label,
                contains('${project.openTaskCount} open,'),
                reason: 'the open count must come from the seeded store too',
              );
            }
          });
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets('F1..F3 and the arrow keys read a real task and its body', (
      WidgetTester tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final window = await pumpViewerOverRealStore(tester, fixture!);
        await tester.runAsync(() async {
          await waitForRealWork(
            tester,
            () => window.projects.loadedRowCount >= 1,
            reason: 'the project list never arrived',
          );
          await pressKeyFast(tester, LogicalKeyboardKey.f1);
          final alphaIndex = window.projects.indexOfProject(
            fixture.alpha.projectId,
          );
          expect(alphaIndex, isNotNull);
          window.model.openProjectIndex(alphaIndex!);
          await waitForRealWork(
            tester,
            () => (window.tasks?.loadedRowCount ?? 0) >= 1,
            reason: 'the first task page never arrived',
          );
          expect(window.tasks!.totalCount, fixture.alpha.openTaskCount);

          final firstRow = find.bySemanticsLabel(
            RegExp('^${fixture.checks.firstRowId}, '),
          );
          expect(firstRow, findsOneWidget);
          expect(
            tester.getSemantics(firstRow).label,
            contains(fixture.checks.firstRowTitle),
          );

          // F2 focuses the task list, ArrowDown moves the selection and Enter
          // opens the row without the arrow debounce, exactly as design.md
          // describes; F3 then focuses the body control.
          await pressKeyFast(tester, LogicalKeyboardKey.f2);
          await pressKeyFast(tester, LogicalKeyboardKey.arrowDown);
          await pressKeyFast(tester, LogicalKeyboardKey.enter);
          await pressKeyFast(tester, LogicalKeyboardKey.f3);
          await waitForRealWork(
            tester,
            () => find
                .textContaining(fixture.checks.detailBodyMarker)
                .evaluate()
                .isNotEmpty,
            reason: 'the seeded body never reached the details pane',
          );
          expect(window.tasks!.selectedTaskId, 2);
          expect(
            find.textContaining(fixture.checks.detailBodyMarker),
            findsOneWidget,
          );
        });
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('the text filter is a literal search over the real store', (
      WidgetTester tester,
    ) async {
      final window = await pumpViewerOverRealStore(tester, fixture!);
      await tester.runAsync(() async {
        await waitForRealWork(
          tester,
          () => window.projects.loadedRowCount >= 1,
          reason: 'the project list never arrived',
        );
        window.model.openProjectIndex(
          window.projects.indexOfProject(fixture.alpha.projectId)!,
        );
        await waitForRealWork(
          tester,
          () => (window.tasks?.loadedRowCount ?? 0) >= 1,
          reason: 'the first task page never arrived',
        );
        final before = window.tasks!.totalCount;

        await tester.enterText(
          textFieldWithLabel('Search tasks (Ctrl+F)'),
          fixture.checks.searchQuery,
        );
        await pressKeyFast(tester, LogicalKeyboardKey.enter);
        await waitForRealWork(
          tester,
          () =>
              window.tasks!.totalCount == fixture.checks.searchExpectedCount &&
              !window.tasks!.isLoading,
          reason: 'the literal search never settled',
        );

        expect(
          before,
          greaterThan(fixture.checks.searchExpectedCount),
          reason: 'the unfiltered list must be larger than the search result',
        );
        expect(
          find.bySemanticsLabel(RegExp('^[A-Z][A-Z0-9]*-\\d{3}, ')),
          findsWidgets,
        );
        final visible = <String>[
          for (var index = 0; index < window.tasks!.loadedRowCount; index += 1)
            if (window.tasks!.itemAt(index) != null)
              window.tasks!.itemAt(index)!.title,
        ];
        expect(visible, contains(fixture.checks.searchExpectedTitle));
        expect(
          visible,
          isNot(contains(fixture.checks.firstRowTitle)),
          reason: 'a task without the literal text must not match',
        );
      });
    });

    testWidgets('Ctrl+S saves one field that a second CLI process reads back', (
      WidgetTester tester,
    ) async {
      final window = await pumpViewerOverRealStore(tester, fixture!);
      await tester.runAsync(() async {
        await waitForRealWork(
          tester,
          () => window.projects.loadedRowCount >= 1,
          reason: 'the project list never arrived',
        );
        window.model.openProjectIndex(
          window.projects.indexOfProject(fixture.alpha.projectId)!,
        );
        await waitForRealWork(
          tester,
          () => (window.tasks?.loadedRowCount ?? 0) >= 1,
          reason: 'the first task page never arrived',
        );
        await window.model.openTaskIndex(0);
        await waitForRealWork(
          tester,
          () => window.model.detail?.hasDetail ?? false,
          reason: 'the task detail never arrived',
        );
        await pressKeyFast(tester, LogicalKeyboardKey.f4);
        await tester.enterText(
          textFieldWithLabel('Title (Alt+T)'),
          fixture.checks.saveNewTitle,
        );
        await pressControlFast(tester, LogicalKeyboardKey.keyS);
        await waitForRealWork(
          tester,
          () => !window.model.editor.isEditing,
          reason: 'the editor never left edit mode after Save',
        );
        expect(window.statusText, contains('Saved'));

        // The proof is the store, read by a second real CLI process.
        final shown = await runSeededCli(fixture, <String>[
          'viewer',
          'show',
          fixture.checks.saveTaskId,
        ]);
        final detail = shown['data']! as Map<String, Object?>;
        expect(detail['title'], fixture.checks.saveNewTitle);
        expect(detail['version'], 2);

        final history = await runSeededCli(fixture, <String>[
          'history',
          fixture.checks.saveTaskId,
          '--limit',
          '100',
        ]);
        final items =
            ((history['data']! as Map<String, Object?>)['items']!
                    as List<Object?>)
                .cast<Map<String, Object?>>();
        final updates = items
            .where((item) => item['operation'] == 'update')
            .toList(growable: false);
        expect(
          updates,
          hasLength(1),
          reason: 'one Save must leave exactly one update event',
        );
        expect(updates.single['resulting_version'], 2);
      });
    });

    testWidgets('F5 refreshes from the real store and keeps the selection', (
      WidgetTester tester,
    ) async {
      final window = await pumpViewerOverRealStore(tester, fixture!);
      await tester.runAsync(() async {
        await waitForRealWork(
          tester,
          () => window.projects.loadedRowCount >= 1,
          reason: 'the project list never arrived',
        );
        window.model.openProjectIndex(
          window.projects.indexOfProject(fixture.alpha.projectId)!,
        );
        await waitForRealWork(
          tester,
          () => (window.tasks?.loadedRowCount ?? 0) >= 1,
          reason: 'the first task page never arrived',
        );
        await window.model.openTaskIndex(1);
        await waitForRealWork(
          tester,
          () => window.model.detail?.hasDetail ?? false,
          reason: 'the task detail never arrived',
        );
        final selected = window.tasks!.selectedTaskId;

        await pressKeyFast(tester, LogicalKeyboardKey.f5);
        await waitForRealWork(
          tester,
          () =>
              !window.model.isRefreshing &&
              (window.tasks?.loadedRowCount ?? 0) >= 1 &&
              (window.model.detail?.hasDetail ?? false),
          reason: 'the refresh never came back from the real store',
        );
        expect(window.tasks!.totalCount, fixture.alpha.openTaskCount);
        expect(window.tasks!.selectedTaskId, selected);
      });
    });
  }, skip: reason);
}

/// One mounted viewer window over the real store.
class ViewerE2eWindow {
  const ViewerE2eWindow({
    required this.model,
    required this.client,
    required this.announcements,
  });

  final ViewerWorkspaceModel model;
  final ViewerCliClient client;
  final AnnouncementController announcements;

  ProjectController get projects => model.projectList;
  TaskController? get tasks => model.tasks;
  String get statusText => announcements.statusText;
}

/// Pumps the real workspace host with the production CLI client.
///
/// The first read starts inside `runAsync`, because a future created in the
/// fake async zone would never observe the child process exit.
Future<ViewerE2eWindow> pumpViewerOverRealStore(
  WidgetTester tester,
  ViewerE2eFixture fixture,
) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final announcements = AnnouncementController(clipPlayer: SilentClipPlayer());
  addTearDown(announcements.dispose);

  final environment = ViewerEnvironment(
    launchArgs: ViewerLaunchArgs(
      dataRoot: fixture.dataRoot,
      tasksExe: fixture.cliPath,
      settingsRoot: fixture.settingsRoot,
      testMode: true,
    ),
    settingsRoot: fixture.settingsRoot,
    dataRoot: fixture.dataRoot,
    tasksExe: fixture.cliPath,
  );
  final client = ViewerCliClient(
    environment: environment,
    savedSettings: () => const ViewerSettingsDraft(),
  );
  final drafts = MemoryDraftSink();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerWorkspaceHost(
          environment: environment,
          readers: ViewerDataReader(
            projects: client,
            tasks: client,
            detail: client,
            update: client,
            probe: client.probe,
            drafts: drafts,
          ),
          announcements: announcements,
          viewerClipboard: FakeViewerClipboard(),
          drafts: drafts,
        ),
      ),
    );
  });
  return ViewerE2eWindow(
    model: tester
        .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
        .model,
    client: client,
    announcements: announcements,
  );
}

/// Sends one key through the test binding and renders the result.
///
/// This never touches the real keyboard: `sendKeyEvent` posts the event to the
/// widget tree the test binding owns.
Future<void> pressKeyFast(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.pump();
}

/// Sends `Ctrl+<key>` through the test binding, as a Windows user would.
Future<void> pressControlFast(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.pump();
}

/// Polls inside `runAsync` until [ready] holds or [timeout] expires.
///
/// Real CLI reads finish on the platform event loop, so waiting means pumping
/// frames while the real loop runs; a plain `pumpAndSettle` would only spin the
/// fake clock and let pending real work stay invisible.
Future<void> waitForRealWork(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after ${timeout.inSeconds} s: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}

/// Runs the seeded CLI against the fixture store and decodes its JSON.
Future<Map<String, Object?>> runSeededCli(
  ViewerE2eFixture fixture,
  List<String> arguments,
) async {
  final result = await Process.run(fixture.cliPath, <String>[
    '--data-root',
    fixture.dataRoot,
    '--project',
    fixture.alpha.projectId,
    '--format',
    'json',
    ...arguments,
  ]);
  expect(
    result.exitCode,
    0,
    reason:
        'tasks.exe ${arguments.join(' ')} failed with '
        '${result.exitCode}: ${result.stderr}',
  );
  return jsonDecode(result.stdout as String) as Map<String, Object?>;
}
