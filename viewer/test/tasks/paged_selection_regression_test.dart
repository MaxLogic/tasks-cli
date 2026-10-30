import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import '../support/model_viewer_driver.dart';
import '../support/viewer_test_support.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/controllers/project_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import '../support/model_store.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';
import 'package:tasks_viewer/ui/viewer_controls.dart';

void main() {
  testWidgets(
    'UX1 Projects sorted and unlocated selection keeps summary and Tasks binding',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(
          count: 2,
          projectCount: 205,
          delay: const Duration(milliseconds: 150),
        ),
      );
      await d.mount();
      await d.select(ViewerRegion.projects, 150);
      final c = d.h.model.projectList,
          id = c.selectedProjectId,
          name = c.selectedItem!.name;
      c.setDirection(SortDirection.descending);
      await d.settle();
      expect(c.selectedProjectId, id);
      expect(d.h.list(ViewerRegion.projects).selectedIndex, 54);
      expect(d.h.model.tasks!.projectId, id);
      expect(find.text('Tasks in $name'), findsWidgets);
      c.setDirection(SortDirection.ascending);
      await d.settle();
      await d.focus(ViewerRegion.tasks);
      d.store.reads.clear();
      c.setQuery('Project');
      await d.start(c.submitQuery());
      expect(c.selectedIndex, isNull);
      expect(c.selectedItem!.name, name);
      expect(d.h.model.tasks!.projectId, id);
      expect(find.text('Tasks in $name'), findsWidgets);
      expect(d.store.reads.length, 1);
      await d.close();
    },
  );
  testWidgets('Pinned dirty draft survives externally removed selection', (
    tester,
  ) async {
    final d = ModelViewerDriver(
      tester,
      ModelStore(delay: const Duration(milliseconds: 150)),
    );
    await d.mount();
    await d.select(ViewerRegion.tasks, 150);
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    await tester.enterText(
      textFieldWithLabel('Title (Alt+T)'),
      'Unsaved draft',
    );
    d.store.mutate(d.h.model.selectedProjectId!, 151, status: 'done');
    await pressKey(tester, LogicalKeyboardKey.f5);
    await d.settle();
    expect(d.h.model.tasks!.selectedTaskId, 151);
    expect(d.h.model.editor.isEditing, isTrue);
    expect(d.h.model.editor.draft!.title, 'Unsaved draft');
    expect(d.h.list(ViewerRegion.tasks).selectedIndex, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    await d.close();
  });
  testWidgets(
    'U2 failed F5 and twelve failed page keys settle; next key recovers',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(count: 1000, delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 999);
      d.store.failure = (r) => r.scope == 'tasks'
          ? const ViewerCliErrorFailure(
              code: 'locked',
              message: 'locked',
              exitCode: 4,
            )
          : null;
      await d.select(ViewerRegion.tasks, 900);
      final c = d.h.model.tasks!,
          node = FocusManager.instance.primaryFocus,
          token = c.snapshotToken;
      d.store.failure = (r) => r.scope == 'tasks'
          ? const ViewerCliErrorFailure(
              code: 'locked',
              message: 'locked',
              exitCode: 4,
            )
          : null;
      await pressKey(tester, LogicalKeyboardKey.f5);
      await d.settle();
      expect(c.snapshotToken, token);
      expect(c.refreshFailure, isNotNull);
      for (var i = 0; i < 12; i++) {
        final revision = d.h.announcements.liveRegionRevision;
        await pressKey(tester, LogicalKeyboardKey.pageUp);
        await d.settle();
        expect(d.h.list(ViewerRegion.tasks).hasPendingTarget, isFalse);
        expect(FocusManager.instance.primaryFocus, node);
        expect(c.selectedTaskId, 901);
        expect(d.h.announcements.liveRegionRevision - revision, 1);
        expect(d.h.liveText, startsWith('Could not load row'));
        await d.pump(1100);
        expect(d.h.announcements.liveRegionRevision - revision, 1);
      }
      d.store.failure = null;
      await pressKey(tester, LogicalKeyboardKey.pageUp);
      await d.settle();
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, lessThan(900));
      expect(c.selectedTaskId, isNot(901));
      await pressKey(tester, LogicalKeyboardKey.f5);
      await d.settle();
      expect(c.refreshFailure, isNull);
      expect(d.store.overlaps, 0);
      await d.close();
    },
  );
  testWidgets(
    'C1 failed distant sort stays atomic through navigation and retry',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 1);
      final c = d.h.model.tasks!, token = c.snapshotToken;
      d.store.failure = (r) => r.scope == 'tasks' && r.offset == 200
          ? const ViewerCliErrorFailure(
              code: 'locked',
              message: 'locked',
              exitCode: 4,
            )
          : null;
      c.setDirection(SortDirection.descending);
      await d.settle();
      expect(c.refreshFailure, isNotNull);
      expect(c.snapshotToken, token);
      expect(c.itemAt(1)?.id, 2);
      await d.start(c.ensureRow(1));
      expect(c.refreshFailure, isNotNull);
      expect(c.itemAt(1)?.id, 2);
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      await d.settle();
      expect(c.selectedTaskId, 3);
      expect(c.itemAt(2)?.id, 3);
      await d.select(ViewerRegion.tasks, 1);
      d.store.failure = null;
      await pressKey(tester, LogicalKeyboardKey.f5);
      await d.settle();
      expect(c.selectedTaskId, 2);
      expect(c.selectedIndex, 203);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 203);
      await d.close();
    },
  );
  testWidgets('UX2/P3 proven absence clears highlight and F2 picks row zero', (
    tester,
  ) async {
    final d = ModelViewerDriver(
      tester,
      ModelStore(count: 99, delay: const Duration(milliseconds: 150)),
    );
    await d.mount();
    await d.select(ViewerRegion.tasks, 0);
    await d.focus(ViewerRegion.projects);
    final c = d.h.model.tasks!;
    c.setQuery('needle');
    await d.start(c.submitQuery());
    expect(c.selectedTaskId, isNull);
    expect(d.h.list(ViewerRegion.tasks).selectedIndices, isEmpty);
    await pressKey(tester, LogicalKeyboardKey.f2);
    await d.settle();
    expect(c.selectedTaskId, 2);
    expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 0);
    await d.close();
  });
  testWidgets('C2-keep distant real save keeps highlight and costs one read', (
    tester,
  ) async {
    final d = ModelViewerDriver(
      tester,
      ModelStore(delay: const Duration(milliseconds: 150)),
    );
    await d.mount();
    await d.select(ViewerRegion.tasks, 150);
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    await tester.enterText(textFieldWithLabel('Title (Alt+T)'), 'Kept task');
    d.store.reads.clear();
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(d.store.writer.requests.length, 1);
    expect(d.h.model.detail!.detail!.title, 'Kept task');
    expect(d.h.model.tasks!.selectedIndex, 150);
    expect(d.h.list(ViewerRegion.tasks).selectedIndex, 150);
    expect(
      d.store.reads.where((r) => r.scope == 'tasks').map((r) => r.offset),
      [100],
    );
    await d.close();
  });
  testWidgets('Restore project switch reads the saved selection page once', (
    tester,
  ) async {
    final d = ModelViewerDriver(
      tester,
      ModelStore(delay: const Duration(milliseconds: 150)),
    );
    await d.mount();
    await d.select(ViewerRegion.tasks, 150);
    final id = d.h.model.selectedProjectId;
    await d.select(ViewerRegion.projects, 1);
    d.store.reads.clear();
    await d.select(ViewerRegion.projects, 0);
    expect(d.h.model.selectedProjectId, id);
    expect(d.h.model.tasks!.selectedIndex, 150);
    expect(d.h.list(ViewerRegion.tasks).selectedIndex, 150);
    expect(
      d.store.reads.where((r) => r.scope == 'tasks').map((r) => r.offset),
      [100],
    );
    await d.close();
  });
  for (final projects in [false, true]) {
    testWidgets(
      'UX4/UX5 ${projects ? 'Projects F1' : 'Tasks F2'} distant F5 keeps focus and detail',
      (tester) async {
        final d = ModelViewerDriver(
          tester,
          ModelStore(
            count: projects ? 2 : 205,
            projectCount: projects ? 205 : 2,
            delay: const Duration(milliseconds: 150),
          ),
        );
        await d.mount();
        final region = projects ? ViewerRegion.projects : ViewerRegion.tasks;
        await d.select(region, 150);
        final id = projects
            ? d.h.model.selectedProjectId
            : d.h.model.tasks!.selectedTaskId;
        final node = FocusManager.instance.primaryFocus;
        d.store.reads.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.f5, platform: 'windows');
        await d.settle();
        final reads = d.store.reads
            .where((r) => r.scope == (projects ? 'projects' : 'tasks'))
            .toList();
        expect(reads.map((r) => r.offset), [100]);
        expect(d.h.list(region).selectedIndex, 150);
        expect(d.h.list(region).focusedRowIndex, 150);
        expect(FocusManager.instance.primaryFocus, node);
        await tester.sendKeyEvent(
          projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2,
          platform: 'windows',
        );
        await d.settle();
        expect(
          projects
              ? d.h.model.selectedProjectId
              : d.h.model.tasks!.selectedTaskId,
          id,
        );
        if (projects) {
          expect(d.h.model.selectedProject?.projectId, id);
          expect(d.h.model.tasks!.projectId, id);
        } else {
          expect(d.h.model.detail!.detail?.id, id);
        }
        await d.close();
      },
    );
  }
  testWidgets(
    'UX3 Alt+I distant row keeps same FocusNode and no intermediate speech',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 7);
      final node = FocusManager.instance.primaryFocus;
      final sequence = <FocusNode?>[];
      void record() => sequence.add(FocusManager.instance.primaryFocus);
      FocusManager.instance.addListener(record);
      final revision = d.h.announcements.liveRegionRevision;
      d.store.reads.clear();
      await pressAlt(tester, LogicalKeyboardKey.keyI);
      await d.settle();
      expect(d.h.model.tasks!.selectedTaskId, 8);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 197);
      expect(FocusManager.instance.primaryFocus, node);
      expect(sequence.where((n) => n != node), isEmpty);
      expect(d.h.announcements.liveRegionRevision, revision);
      expect(
        d.store.reads.where((r) => r.scope == 'tasks').map((r) => r.offset),
        [100, 200],
      );
      FocusManager.instance.removeListener(record);
      await d.close();
    },
  );
  testWidgets(
    'C2 real editor save leaving Open retains saved detail and announces once',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(count: 205, delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 150);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await d.settle();
      await tester.enterText(
        textFieldWithLabel('Title (Alt+T)'),
        'Edited distant task',
      );
      await d.pump();
      d.h.model.editor.setField(EditorField.status, 'done');
      d.store.reads.clear();
      final revision = d.h.announcements.liveRegionRevision;
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      expect(d.store.writer.requests.length, 1);
      expect(
        d.store.records[d.h.model.selectedProjectId]![151]!.title,
        'Edited distant task',
      );
      expect(d.h.model.tasks!.selectedTaskId, 151);
      expect(d.h.model.detail!.detail?.id, 151);
      expect(d.h.model.detail!.detail?.title, 'Edited distant task');
      expect(d.h.list(ViewerRegion.tasks).selectedIndex, isNull);
      expect(
        find.text('Saved task no longer matches these filters'),
        findsWidgets,
      );
      expect(d.store.reads.where((r) => r.scope == 'tasks').length, 2);
      expect(d.h.announcements.liveRegionRevision - revision, 2);
      await d.close();
    },
  );
  for (final last in [false, true]) {
    testWidgets(
      'C2-list D selects ${last ? 'previous at end' : 'next survivor'}',
      (tester) async {
        final d = ModelViewerDriver(
          tester,
          ModelStore(count: 99, delay: const Duration(milliseconds: 150)),
        );
        await d.mount();
        await d.select(ViewerRegion.tasks, last ? 98 : 5);
        await pressKey(tester, LogicalKeyboardKey.keyD);
        await d.settle();
        expect(d.store.writer.requests.length, 1);
        expect(d.h.model.tasks!.selectedTaskId, last ? 98 : 7);
        expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, last ? 97 : 5);
        expect(d.h.model.detail!.detail?.id, last ? 98 : 7);
        await d.close();
      },
    );
  }

  test('UX4 tasks: refresh reads the selected page once', () async {
    final store = ModelStore(delay: Duration.zero);
    final c = TaskController(
      projectId: store.projects.first.projectId,
      reader: store,
      prefetchRows: 0,
    );
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.restoreState(const TaskListState(sort: TaskSort.id));
    await c.reload();
    await c.ensureRow(150);
    c.selectIndex(150);
    store.reads.clear();
    await c.refresh();
    expect(c.selectedTaskId, 151);
    expect(c.selectedIndex, 150);
    expect(store.reads.map((r) => r.offset), [100]);
  });
  test(
    'UX4 UX5 projects: refresh preserves DTO and located selection',
    () async {
      final store = ModelStore(
        count: 1,
        projectCount: 205,
        delay: Duration.zero,
      );
      final c = ProjectController(
        reader: store,
        initialSort: ProjectSort.name,
        initialDirection: SortDirection.ascending,
        prefetchRows: 0,
      );
      addTearDown(() {
        c.dispose();
        store.close();
      });
      await c.reload();
      await c.ensureRow(150);
      c.selectIndex(150);
      final id = c.selectedProjectId;
      store.reads.clear();
      await c.refresh();
      expect(c.selectedProjectId, id);
      expect(c.selectedItem?.projectId, id);
      expect(c.selectedIndex, 150);
      expect(store.reads.map((r) => r.offset), [100]);
    },
  );
  test('U1 search keeps unknown membership and uses one read', () async {
    final store = ModelStore(count: 1000, delay: Duration.zero);
    final c = TaskController(
      projectId: store.projects.first.projectId,
      reader: store,
      prefetchRows: 0,
    );
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.restoreState(const TaskListState(sort: TaskSort.id));
    await c.reload();
    c.selectIndex(0);
    store.reads.clear();
    c.setQuery('needle');
    await c.submitQuery();
    expect(c.selectedTaskId, 1);
    expect(c.selectedIndex, isNull);
    expect(store.reads.length, 1);
  });
  test('UX2 proven absence clears selection', () async {
    final store = ModelStore(count: 99, delay: Duration.zero);
    final c = TaskController(
      projectId: store.projects.first.projectId,
      reader: store,
    );
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.restoreState(const TaskListState(sort: TaskSort.id));
    await c.reload();
    c.selectIndex(0);
    c.setQuery('needle');
    await c.submitQuery();
    expect(c.selectedTaskId, isNull);
    expect(c.selectedIndex, isNull);
  });
  testWidgets(
    'Budget unlocated identity keeps detail and focuses labelled container',
    (tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(count: 5000, delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 4999);
      d.store.reads.clear();
      d.h.model.tasks!.setSort(TaskSort.priority);
      await d.settle();
      expect(d.h.model.tasks!.selectedTaskId, 5000);
      expect(d.h.model.tasks!.selectedIndex, isNull);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, isNull);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-region');
      expect(d.h.model.detail!.detail!.id, 5000);
      expect(d.h.model.tasks!.selectedItem?.id, 5000);
      expect(d.store.reads.where((r) => r.scope == 'tasks').length, 11);
      await d.close();
    },
  );

  for (final projects in [false, true]) {
    final region = projects ? ViewerRegion.projects : ViewerRegion.tasks;
    final name = projects ? 'Projects' : 'Tasks';
    Object? selectedOf(ModelViewerDriver d) => projects
        ? d.h.model.projectList.selectedProjectId
        : d.h.model.tasks!.selectedTaskId;
    ModelStore pagedStore() => ModelStore(
      count: projects ? 2 : 1000,
      projectCount: projects ? 1000 : 2,
      delay: const Duration(milliseconds: 350),
    );
    Future<void> refreshList(ModelViewerDriver d) => d.start(
      projects
          ? d.h.model.projectList.refresh(userInitiated: false)
          : d.h.model.tasks!.refresh(userInitiated: false),
    );
    for (final fromEnd in [false, true]) {
      testWidgets(
        'C3 $name ${fromEnd ? 'End' : 'Home'} supersedes the pending opposite jump',
        (tester) async {
          final d = ModelViewerDriver(tester, pagedStore());
          await d.mount();
          final row = fromEnd ? 999 : 0;
          await d.select(region, row);
          await refreshList(d);
          final selected = selectedOf(d);
          await pressKey(
            tester,
            fromEnd ? LogicalKeyboardKey.home : LogicalKeyboardKey.end,
          );
          await d.pump();
          expect(d.h.list(region).hasPendingTarget, isTrue);
          await pressKey(
            tester,
            fromEnd ? LogicalKeyboardKey.end : LogicalKeyboardKey.home,
          );
          await d.settle();
          expect(selectedOf(d), selected);
          expect(d.h.list(region).focusedRowIndex, row);
          expect(d.h.list(region).selectedIndex, row);
          expect(d.h.list(region).hasPendingTarget, isFalse);
          await d.close();
        },
      );
    }
    testWidgets('C3 $name key right after a finished jump is not overridden', (
      tester,
    ) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(
          count: projects ? 2 : 205,
          projectCount: projects ? 205 : 2,
          delay: const Duration(milliseconds: 150),
        ),
      );
      await d.mount();
      await d.select(region, 0);
      await refreshList(d);
      final first = selectedOf(d), list = d.h.list(region);
      await tester.sendKeyEvent(LogicalKeyboardKey.end, platform: 'windows');
      for (var f = 0; f < 40 && list.focusedRowIndex != 204; f++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(list.focusedRowIndex, 204);
      await tester.sendKeyEvent(LogicalKeyboardKey.home, platform: 'windows');
      await d.settle();
      expect(selectedOf(d), first);
      expect(list.focusedRowIndex, 0);
      expect(list.selectedIndex, 0);
      await d.close();
    });
    testWidgets('C3 $name failed superseded jump stays silent', (tester) async {
      final d = ModelViewerDriver(tester, pagedStore());
      await d.mount();
      await d.select(region, 0);
      await refreshList(d);
      d.store.failure = (r) => const ViewerCliErrorFailure(
        code: 'locked',
        message: 'locked',
        exitCode: 4,
      );
      await pressKey(tester, LogicalKeyboardKey.end);
      await d.pump();
      await pressKey(tester, LogicalKeyboardKey.home);
      await d.settle();
      d.store.failure = null;
      expect(d.h.list(region).focusedRowIndex, 0);
      expect(d.h.liveText ?? '', isNot(contains('Could not load row')));
      await d.close();
    });
    for (final retained in [false, true]) {
      testWidgets(
        'UX6 $name Escape from a refused move out of ${retained ? 'a retained' : 'an unlocated'} selection is not a trap',
        (tester) async {
          final d = ModelViewerDriver(
            tester,
            ModelStore(
              count: projects ? 5 : 300,
              projectCount: projects ? 300 : 2,
              delay: const Duration(milliseconds: 150),
            ),
          );
          await d.mount();
          await d.select(ViewerRegion.projects, projects ? 150 : 0);
          await d.select(ViewerRegion.tasks, projects ? 1 : 150);
          await pressKey(tester, LogicalKeyboardKey.f4);
          await d.settle();
          await tester.enterText(
            textFieldWithLabel('Title (Alt+T)'),
            'Unsaved',
          );
          await d.settle();
          final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
          final id = selectedOf(d);
          c.setQuery(
            retained
                ? (projects ? 'Project 002' : 'T-2')
                : (projects ? 'Project' : 'body'),
          );
          await d.start(c.submitQuery() as Future<void>);
          expect(c.selectedIndex, isNull);
          await pressKey(
            tester,
            projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2,
          );
          await d.settle();
          for (var attempt = 0; attempt < 2; attempt++) {
            await pressKey(tester, LogicalKeyboardKey.arrowDown);
            await d.settle();
            expect(
              find.byType(ViewerUnsavedChangesDialog),
              findsOneWidget,
              reason: 'attempt $attempt',
            );
            await pressKey(tester, LogicalKeyboardKey.escape);
            await d.settle();
            expect(
              find.byType(ViewerUnsavedChangesDialog),
              findsNothing,
              reason: 'Escape must close the guard, attempt $attempt',
            );
            final list = d.h.list(region);
            expect(list.hasListFocus, isTrue);
            expect(list.focusedRowIndex, isNull);
            expect(selectedOf(d), id);
            expect(d.h.model.editor.draft?.title, 'Unsaved');
          }
          await d.h.model.editor.discardDraft();
          await d.close();
        },
      );
    }
    testWidgets(
      'UX7 $name unlocated selection shows its text in the status line',
      (tester) async {
        final d = ModelViewerDriver(
          tester,
          ModelStore(
            count: projects ? 2 : 300,
            projectCount: projects ? 300 : 2,
            delay: const Duration(milliseconds: 150),
          ),
        );
        await d.mount();
        await d.select(region, 150);
        final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
        final text = projects
            ? 'Selected project ${d.h.model.projectList.selectedItem!.name} is not in the loaded rows'
            : 'Selected task T-151 is not in the loaded rows';
        expect(find.text(text), findsNothing);
        final speech = d.h.liveText;
        c.setQuery(projects ? 'Project' : 'body');
        await d.start(c.submitQuery() as Future<void>);
        expect(c.selectedIndex, isNull);
        expect(find.text(text), findsOneWidget);
        expect(d.h.liveText, speech, reason: 'The notice is visible only');
        await d.close();
      },
    );
  }
  test(
    'C4 reply during a failed reload owes one refresh after the failure',
    () async {
      final store = ModelStore(count: 205, delay: Duration.zero);
      final project = store.projects.first.projectId;
      final c = TaskController(
        projectId: project,
        reader: store,
        prefetchRows: 0,
      );
      addTearDown(() {
        c.dispose();
        store.close();
      });
      c.restoreState(const TaskListState(sort: TaskSort.id));
      await c.reload();
      await c.ensureRow(150);
      c.selectIndex(150);
      store.reads.clear();
      var failures = 1;
      store.failure = (r) {
        if (failures == 0) return null;
        failures--;
        return const ViewerCliErrorFailure(
          code: 'locked',
          message: 'locked',
          exitCode: 4,
        );
      };
      final job = c.refresh();
      final base = store.records[project]![151]!;
      final confirmed = base.withAttachmentWrite(
        version: base.version + 1,
        updatedMs: base.updatedMs + 1,
        attachments: base.attachments,
      );
      store.records[project]![151] = confirmed;
      store.version++;
      c.applyAttachmentWrite(confirmed, 0, baseVersion: base.version);
      await job;
      await pumpEventQueue();
      expect(store.reads.map((r) => r.outcome), ['locked', 'ok']);
      expect(c.itemAt(150)!.version, confirmed.version);
      expect(c.refreshFailure, isNull);
      expect(c.isLoading, isFalse);
    },
  );
  test('C4 failed follow-up does not repeat the owed refresh', () async {
    final store = ModelStore(count: 205, delay: Duration.zero);
    final project = store.projects.first.projectId;
    final c = TaskController(
      projectId: project,
      reader: store,
      prefetchRows: 0,
    );
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.restoreState(const TaskListState(sort: TaskSort.id));
    await c.reload();
    c.selectIndex(5);
    store.reads.clear();
    store.failure = (r) => const ViewerCliErrorFailure(
      code: 'locked',
      message: 'locked',
      exitCode: 4,
    );
    final job = c.refresh();
    final base = store.records[project]![6]!;
    c.applyAttachmentWrite(
      base.withAttachmentWrite(
        version: base.version + 1,
        updatedMs: base.updatedMs + 1,
        attachments: base.attachments,
      ),
      0,
      baseVersion: base.version,
    );
    await job;
    await pumpEventQueue();
    expect(store.reads.map((r) => r.outcome), ['locked', 'locked']);
    expect(c.refreshFailure, isNotNull);
    expect(c.isLoading, isFalse);
  });
  testWidgets('C6 saved detail and notice survive a failed read and recovery', (
    tester,
  ) async {
    final d = ModelViewerDriver(
      tester,
      ModelStore(delay: const Duration(milliseconds: 150)),
    );
    await d.mount();
    await d.select(ViewerRegion.tasks, 150);
    final tasks = d.h.model.tasks!;
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    d.h.model.editor.setField(EditorField.status, 'done');
    d.store.failure = (r) => r.scope == 'tasks'
        ? const ViewerCliErrorFailure(
            code: 'locked',
            message: 'locked',
            exitCode: 4,
          )
        : null;
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(tasks.refreshFailure, isNotNull);
    d.store.failure = null;
    await d.start(tasks.refresh());
    tasks.setDirection(SortDirection.descending);
    await d.settle();
    expect(tasks.selectedTaskId, 151);
    expect(d.h.model.detail?.taskId, 151);
    final selection = tasks.selection;
    expect(selection, isA<Retained<int>>());
    expect((selection as Retained<int>).reason, RetainReason.saved);
    expect(
      find.descendant(
        of: find.byType(ViewerStatusLine),
        matching: find.text('Saved task no longer matches these filters'),
      ),
      findsOneWidget,
    );
    await d.close();
  });
  for (final projects in [false, true]) {
    for (final dirty in [false, true]) {
      for (final mode in ['located', 'unlocated', 'retained']) {
        final region = projects ? ViewerRegion.projects : ViewerRegion.tasks;
        final entry = projects ? LogicalKeyboardKey.f1 : LogicalKeyboardKey.f2;
        testWidgets(
          'UX8 ${projects ? 'Projects' : 'Tasks'} ${dirty ? 'dirty' : 'clean'} '
          '$mode: Tab and Shift+Tab select nothing and leave the list',
          (tester) async {
            final d = ModelViewerDriver(
              tester,
              ModelStore(
                count: projects ? 5 : 300,
                projectCount: projects ? 300 : 2,
                delay: const Duration(milliseconds: 150),
              ),
            );
            await d.mount();
            await d.select(ViewerRegion.projects, projects ? 150 : 0);
            await d.select(ViewerRegion.tasks, projects ? 1 : 150);
            final model = d.h.model, list = d.h.list(region);
            final dynamic c = projects ? model.projectList : model.tasks!;
            Object? selected() => projects
                ? model.projectList.selectedProjectId
                : model.tasks!.selectedTaskId;
            final id = selected();
            final project = model.tasks!.projectId;
            if (dirty) {
              await pressKey(tester, LogicalKeyboardKey.f4);
              await d.settle();
              await tester.enterText(
                textFieldWithLabel('Title (Alt+T)'),
                'Unsaved',
              );
              await d.settle();
            }
            if (mode == 'unlocated') {
              c.setQuery(projects ? 'Project' : 'body');
              await d.start(c.submitQuery() as Future<void>);
              await d.scrollToTop(region);
            } else if (mode == 'retained' && dirty) {
              c.setQuery(projects ? 'Project 002' : 'T-2');
              await d.start(c.submitQuery() as Future<void>);
            } else if (mode == 'retained') {
              d.h.handles(region).filterFocus.requestFocus();
              await d.settle();
              if (projects) {
                d.store.projects.removeWhere((p) => p.projectId == id);
                d.store.version++;
              } else {
                d.store.mutate(project, id! as int, status: 'done');
              }
              await d.start(c.refresh() as Future<void>);
            }
            final located = mode == 'located' ? list.selectedIndex : null;
            expect(c.selectedIndex, located);
            void unchanged(String step) {
              expect(selected(), id, reason: step);
              expect(
                find.byType(ViewerUnsavedChangesDialog),
                findsNothing,
                reason: step,
              );
              if (!projects) expect(model.detail?.taskId, id, reason: step);
              if (dirty) expect(model.editor.draft?.title, 'Unsaved');
            }

            Future<void> enter() async {
              await pressKey(tester, entry);
              await d.settle();
              expect(list.hasListFocus, isTrue);
              expect(list.focusedRowIndex, located);
            }

            await enter();
            await pressKey(tester, LogicalKeyboardKey.tab);
            await d.settle();
            unchanged('Tab');
            if (located != null) {
              expect(list.focusedRowIndex, located, reason: 'Actions stop');
              expect(
                FocusManager.instance.primaryFocus?.debugLabel,
                isNot('list-row-$located'),
              );
              await pressShift(tester, LogicalKeyboardKey.tab);
              await d.settle();
              unchanged('Shift+Tab from Actions');
              expect(
                FocusManager.instance.primaryFocus?.debugLabel,
                'list-row-$located',
              );
              await pressKey(tester, LogicalKeyboardKey.tab);
              await d.settle();
              await pressKey(tester, LogicalKeyboardKey.tab);
              await d.settle();
              unchanged('Tab past Actions');
            }
            expect(list.hasListFocus, isFalse, reason: 'Tab leaves the list');
            await enter();
            await pressShift(tester, LogicalKeyboardKey.tab);
            await d.settle();
            unchanged('Shift+Tab');
            expect(
              list.hasListFocus,
              isFalse,
              reason: 'Shift+Tab leaves the list',
            );
            if (dirty) await model.editor.discardDraft();
            await d.close();
          },
        );
      }
    }
  }
}
