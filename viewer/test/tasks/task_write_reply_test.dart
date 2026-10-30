import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';
import '../support/model_store.dart';
import '../support/model_viewer_driver.dart';
import '../support/viewer_test_support.dart';

class DelayedTaskWriter implements TaskUpdateWriter {
  DelayedTaskWriter(this.inner);
  final TaskUpdateWriter inner;
  final release = Completer<void>();
  ViewerUpdateResult? reply;
  @override
  Future<ViewerUpdateResult> updateTask(
    String project,
    ViewerUpdateRequest request,
  ) async {
    reply = await inner.updateTask(project, request);
    await release.future;
    return reply!;
  }
}

Map<String, Object?> completeDetail(TaskDetail t) => {
  ...detailJson(t),
  'dependency_summaries': [
    for (final dep in t.dependencySummaries)
      {
        'id': dep.id,
        'display_id': dep.displayId,
        'title': dep.title,
        'status': dep.status,
        'version': dep.version,
      },
  ],
  'attachments': t.attachments,
};

void main() {
  for (final metadata in ['rules', 'dependency', 'key', 'task']) {
    for (final order in ['read-first', 'reply-first', 'replay']) {
      testWidgets('L5-9a $metadata $order preserves confirmed metadata', (
        tester,
      ) async {
        final store = ModelStore(count: 2)..writer.includeTaskState = true;
        if (metadata == 'dependency') {
          for (final project in store.projects) {
            final initial = detailJson(store.records[project.projectId]![1]!);
            initial['deps'] = [2];
            initial['dependency_summaries'] = [
              {
                'id': 2,
                'title': 'Initial dependency',
                'status': 'todo',
                'version': 1,
              },
            ];
            store.records[project.projectId]![1] = TaskDetail.fromJson(initial);
          }
        }
        final writer = DelayedTaskWriter(store.writer);
        final d = ModelViewerDriver(tester, store);
        d.h = await pumpRealViewer(
          tester,
          reads: store,
          update: writer,
          drafts: MemoryDraftSink(),
          settle: false,
        );
        await d.settle();
        d.h.model.selectProjectIndex(0);
        await d.settle();
        d.h.model.tasks!.setSort(TaskSort.id);
        await d.settle();
        try {
          await d.select(ViewerRegion.tasks, 0);
          final model = d.h.model, tasks = model.tasks!, detail = model.detail!;
          final base = detail.detail!, project = tasks.projectId;
          await pressKey(tester, LogicalKeyboardKey.f4);
          await d.settle();
          model.editor.setField(EditorField.title, 'Saved while waiting');
          await pressControl(tester, LogicalKeyboardKey.keyS);
          await d.pump(20);
          expect(writer.reply, isNotNull);
          expect(model.editor.isSaving, isTrue);
          final json = detailJson(store.records[project]![base.id]!);
          switch (metadata) {
            case 'rules':
              json['rule_version'] = base.ruleVersion + 1;
              json['rules'] = 'Newer project rules';
            case 'dependency':
              final other = base.id == 1 ? 2 : 1;
              expect(json['deps'], [other]);
              store.mutate(
                project,
                other,
                title: 'Newer dependency title',
                status: 'done',
              );
              json['dependency_summaries'] = [
                {
                  'id': other,
                  'title': 'Newer dependency title',
                  'status': 'done',
                  'version': 2,
                },
              ];
            case 'key':
              store.projectKey = 'NEW';
              json['project_key'] = 'NEW';
              json['display_id'] = 'NEW-${base.id.toString().padLeft(3, '0')}';
            case 'task':
              json['version'] = (json['version']! as int) + 1;
              json['body'] = 'Newer task body';
          }
          final current = TaskDetail.fromJson(json);
          store.records[project]![base.id] = current;
          store.version++;
          if (order != 'reply-first') {
            await pressKey(tester, LogicalKeyboardKey.f5);
            await d.settle();
            expect(completeDetail(detail.detail!), completeDetail(current));
          }
          store.reads.clear();
          store.detailRequests.clear();
          writer.release.complete();
          await d.settle();
          expect(store.reads, hasLength(1));
          expect(store.detailRequests, isEmpty);
          if (order == 'reply-first') {
            await pressKey(tester, LogicalKeyboardKey.f5);
            await d.settle();
          }
          if (order == 'replay') {
            store.reads.clear();
            store.detailRequests.clear();
            await d.start(
              model.applyTaskWriteReply(
                writer.reply,
                base,
                project,
                savedTaskId: base.id,
              ),
            );
            expect(store.reads, hasLength(1));
            expect(store.detailRequests, isEmpty);
          }
          expect(completeDetail(detail.detail!), completeDetail(current));
          expect(completeDetail(model.editor.base!), completeDetail(current));
          expect(tasks.selectedTaskId, base.id);
          expect(model.editor.isEditing, isFalse);
          expect(model.editor.isDirty, isFalse);
          expect(store.writer.requests, hasLength(1));
        } finally {
          if (!writer.release.isCompleted) writer.release.complete();
          await d.close();
        }
      });
    }
  }

  for (final action in [
    'B',
    'X',
    'D',
    'menu-block',
    'menu-cancel',
    'menu-done',
  ]) {
    for (final dismiss in ['escape', 'return', 'cancel-review']) {
      testWidgets('L5-9b $action $dismiss announces only unsaved status', (
        tester,
      ) async {
        final store = ModelStore(count: 2)..writer.includeTaskState = true;
        final d = ModelViewerDriver(tester, store);
        await d.mount();
        try {
          await d.select(ViewerRegion.tasks, 0);
          final tasks = d.h.model.tasks!, id = tasks.selectedTaskId!;
          store.mutate(tasks.projectId, id, title: 'Changed elsewhere');
          if (action.startsWith('menu')) {
            await pressKey(tester, LogicalKeyboardKey.contextMenu);
            await d.settle();
          }
          await pressKey(tester, switch (action) {
            'B' || 'menu-block' => LogicalKeyboardKey.keyB,
            'X' || 'menu-cancel' => LogicalKeyboardKey.keyX,
            _ => LogicalKeyboardKey.keyD,
          });
          await d.settle();
          expect(find.byType(ViewerConflictDialog), findsOneWidget);
          final announcements = d.h.announcements;
          var revision = announcements.liveRegionRevision;
          final speech = <String>[];
          void record() {
            if (announcements.liveRegionRevision != revision) {
              revision = announcements.liveRegionRevision;
              if (announcements.liveRegionText case final text?) {
                speech.add(text);
              }
            }
          }

          announcements.addListener(record);
          try {
            if (dismiss == 'cancel-review') {
              await pressAlt(tester, LogicalKeyboardKey.keyV);
              await d.settle();
              expect(find.byType(ViewerConflictReviewDialog), findsOneWidget);
              await pressAlt(tester, LogicalKeyboardKey.keyC);
            } else if (dismiss == 'return') {
              await pressAlt(tester, LogicalKeyboardKey.keyE);
            } else {
              await pressKey(tester, LogicalKeyboardKey.escape);
            }
            await d.settle();
          } finally {
            announcements.removeListener(record);
          }
          expect(speech, [
            'T-${id.toString().padLeft(3, '0')} changed in the store. No status change was saved.',
          ]);
          expect(d.h.model.editor.isEditing, isFalse);
          expect(d.h.model.editor.isDirty, isFalse);
          expect(tasks.selectedTaskId, id);
          expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 0);
          expect(store.writer.requests, hasLength(1));
        } finally {
          await d.close();
        }
      });
    }
  }

  testWidgets('explicit editor conflict Escape keeps the visible draft', (
    tester,
  ) async {
    final store = ModelStore(count: 2)..writer.includeTaskState = true;
    final d = ModelViewerDriver(tester, store);
    await d.mount();
    await d.select(ViewerRegion.tasks, 0);
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    final tasks = d.h.model.tasks!;
    d.h.model.editor.setField(EditorField.title, 'Keep this draft');
    store.mutate(tasks.projectId, tasks.selectedTaskId!, title: 'External');
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(find.byType(ViewerConflictDialog), findsOneWidget);
    await pressKey(tester, LogicalKeyboardKey.escape);
    await d.settle();
    expect(d.h.model.editor.isEditing, isTrue);
    expect(d.h.model.editor.isDirty, isTrue);
    expect(d.h.model.editor.draft!.title, 'Keep this draft');
    await d.close();
  });

  testWidgets('L5-1 saved body recomputes Find before Next match', (
    tester,
  ) async {
    final store = ModelStore(count: 2)..writer.includeTaskState = true;
    for (final project in store.projects) {
      store.records[project.projectId]![1] = testTaskDetail(
        1,
        body: 'prefix alpha alpha alpha alpha alpha alpha',
      );
    }
    final d = ModelViewerDriver(tester, store);
    await d.mount();
    await d.select(ViewerRegion.tasks, 0);
    final detail = d.h.model.detail!;
    detail.setFindText('alpha');
    expect(detail.matchCount, 6);
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    d.h.model.editor.setField(EditorField.body, 'short');
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    final next = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Next match'),
        matching: find.byType(TextButton),
      ),
    );
    Object? error;
    try {
      next.onPressed!();
    } catch (e) {
      error = e;
    }
    await tester.pump();
    expect(
      error,
      isNull,
      reason: 'Find must not select offsets beyond the committed body',
    );
    expect(detail.findText, 'alpha');
    expect(detail.matchCount, 0);
    expect(detail.matchStart, isNull);
    expect(d.h.handles(ViewerRegion.details).bodyFocus.hasFocus, isTrue);
    expect(d.h.model.editor.isEditing, isFalse);
    expect(d.h.model.editor.isDirty, isFalse);
    await d.close();
  });

  for (final trigger in ['save', 'status', 'done']) {
    testWidgets('$trigger refreshes the snapshot before End', (tester) async {
      final store = ModelStore(count: 205)..writer.includeTaskState = true;
      final d = ModelViewerDriver(tester, store);
      await d.mount();
      final tasks = d.h.model.tasks!;
      tasks.setScope(TaskScope.all);
      await d.settle();
      await d.select(ViewerRegion.tasks, 150);
      if (trigger == 'save') {
        await pressKey(tester, LogicalKeyboardKey.f4);
        await d.settle();
        d.h.model.editor.setField(EditorField.title, 'Stable save before jump');
        await pressControl(tester, LogicalKeyboardKey.keyS);
        await d.settle();
        await d.focus(ViewerRegion.tasks);
      } else if (trigger == 'done') {
        await pressControl(tester, LogicalKeyboardKey.keyD);
        await d.settle();
      } else {
        await pressKey(tester, LogicalKeyboardKey.keyB);
        await d.settle();
      }
      expect(tasks.isRowReady(204), isFalse);
      store.reads.clear();
      final speech = <String>[];
      void recordSpeech() => speech.add(d.h.announcements.liveRegionText ?? '');
      d.h.announcements.addListener(recordSpeech);
      await pressKey(tester, LogicalKeyboardKey.end);
      await d.settle();
      d.h.announcements.removeListener(recordSpeech);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 204);
      expect(tasks.selectedIndex, 204);
      expect(tasks.selectedTaskId, 205);
      expect(
        speech.where((text) => text.contains('Could not load row')),
        isEmpty,
      );
      expect(
        store.reads.map((read) => read.outcome),
        isNot(contains('stale_snapshot')),
      );
      expect(store.reads, hasLength(1));
      expect(tasks.pageFailure, isNull);
      expect(store.overlaps, 0);
      await d.close();
    });
  }

  testWidgets('main attachment patch keeps zero reads and stale End behavior', (
    tester,
  ) async {
    final store = ModelStore(count: 205);
    final d = ModelViewerDriver(tester, store);
    await d.mount();
    try {
      await d.select(ViewerRegion.tasks, 150);
      final tasks = d.h.model.tasks!, base = d.h.model.detail!.detail!;
      final token = tasks.snapshotToken;
      final updated = base.withAttachmentWrite(
        version: base.version + 1,
        updatedMs: base.updatedMs + 1,
        attachments: base.attachments,
      );
      store.records[tasks.projectId]![base.id] = updated;
      store.version++;
      store.reads.clear();
      store.detailRequests.clear();
      d.h.model.applyAttachmentWrite(
        tasks.projectId,
        updated,
        0,
        base.version,
        historyVisible: false,
      );
      await d.settle();
      expect(store.reads, isEmpty);
      expect(store.detailRequests, isEmpty);
      expect(tasks.snapshotToken, token);
      final speech = <String>[];
      void recordSpeech() => speech.add(d.h.announcements.liveRegionText ?? '');
      d.h.announcements.addListener(recordSpeech);
      try {
        await pressKey(tester, LogicalKeyboardKey.end);
        await d.settle();
      } finally {
        d.h.announcements.removeListener(recordSpeech);
      }
      expect(store.reads.map((r) => r.outcome), ['stale_snapshot', 'ok']);
      expect(
        speech,
        contains(contains('Could not load row 205: store changed')),
      );
      expect(tasks.selectedIndex, 150);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 150);
      store.reads.clear();
      await pressKey(tester, LogicalKeyboardKey.end);
      await d.settle();
      expect(store.reads.map((r) => r.outcome), ['ok']);
      expect(tasks.selectedIndex, 204);
      expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 204);
    } finally {
      await d.close();
    }
  });

  for (final action in ['B', 'X', 'menu-block', 'menu-cancel']) {
    testWidgets(
      'L5-3 $action conflict Escape closes only the implicit editor',
      (tester) async {
        final store = ModelStore(count: 205)..writer.includeTaskState = true;
        final d = ModelViewerDriver(tester, store);
        await d.mount();
        await d.select(ViewerRegion.tasks, 150);
        final tasks = d.h.model.tasks!, id = tasks.selectedTaskId!;
        store.mutate(tasks.projectId, id, title: 'Changed elsewhere');
        store.reads.clear();
        store.detailRequests.clear();
        if (action.startsWith('menu')) {
          await pressKey(tester, LogicalKeyboardKey.contextMenu);
          await d.settle();
        }
        await pressKey(
          tester,
          action == 'B' || action == 'menu-block'
              ? LogicalKeyboardKey.keyB
              : LogicalKeyboardKey.keyX,
        );
        await d.settle();
        expect(find.byType(ViewerConflictDialog), findsOneWidget);
        expect(store.writer.requests, hasLength(1));
        expect(store.reads, isEmpty);
        expect(
          store.detailRequests,
          hasLength(1),
          reason: 'Only conflict reconciliation reads the current task',
        );
        await pressKey(tester, LogicalKeyboardKey.escape);
        await d.settle();
        expect(d.h.model.editor.isEditing, isFalse);
        expect(d.h.model.editor.isDirty, isFalse);
        expect(d.h.model.editor.conflict, isNull);
        expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 150);
        expect(tasks.selectedTaskId, id);
        await d.close();
      },
    );
  }

  testWidgets('L5-4 stable save retries a failed refresh', (tester) async {
    final store = ModelStore(count: 2)..writer.includeTaskState = true;
    final d = ModelViewerDriver(tester, store);
    await d.mount();
    await d.select(ViewerRegion.tasks, 0);
    final tasks = d.h.model.tasks!;
    store.failure = (_) => const ViewerCliErrorFailure(
      code: 'locked',
      message: 'locked',
      exitCode: 4,
    );
    await d.start(tasks.refresh());
    expect(tasks.refreshFailure, isNotNull);
    store.failure = null;
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    d.h.model.editor.setField(EditorField.title, 'Fresh after failed refresh');
    store.reads.clear();
    store.detailRequests.clear();
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(tasks.refreshFailure, isNull);
    expect(store.reads, hasLength(1));
    expect(store.detailRequests, isEmpty);
    await d.close();
  });

  testWidgets(
    'save observes changed prerequisites in the committed Runnable row',
    (tester) async {
      final store = ModelStore(count: 2)..writer.includeTaskState = true;
      for (final project in store.projects) {
        store.records[project.projectId]![1] = testTaskDetail(1, deps: [2]);
        store.mutate(project.projectId, 2, status: 'done');
      }
      final d = ModelViewerDriver(tester, store);
      await d.mount();
      final tasks = d.h.model.tasks!;
      tasks.setReadiness(TaskReadiness.runnable);
      await d.settle();
      await d.select(ViewerRegion.tasks, 0);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await d.settle();
      d.h.model.editor.setField(
        EditorField.title,
        'Dependency changed meanwhile',
      );
      store.mutate(tasks.projectId, 2, status: 'todo');
      store.reads.clear();
      store.detailRequests.clear();
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      expect(tasks.retainedText, 'Saved task no longer matches these filters');
      expect(tasks.selectedTaskId, 1);
      expect(tasks.selectedIndex, isNull);
      expect(store.reads, hasLength(1));
      expect(store.detailRequests, isEmpty);
      await d.close();
    },
  );

  testWidgets('needs-human save leaves Runnable and retains saved details', (
    tester,
  ) async {
    final store = ModelStore(count: 2)..writer.includeTaskState = true;
    final d = ModelViewerDriver(tester, store);
    await d.mount();
    final tasks = d.h.model.tasks!;
    tasks.setReadiness(TaskReadiness.runnable);
    await d.settle();
    await d.select(ViewerRegion.tasks, 0);
    final id = tasks.selectedTaskId!;
    await pressKey(tester, LogicalKeyboardKey.f4);
    await d.settle();
    d.h.model.editor.setField(EditorField.labels, 'needs-human');
    store.reads.clear();
    store.detailRequests.clear();
    await pressControl(tester, LogicalKeyboardKey.keyS);
    await d.settle();
    expect(tasks.retainedText, 'Saved task no longer matches these filters');
    expect(tasks.selectedTaskId, id);
    expect(tasks.selectedIndex, isNull);
    expect(store.reads, hasLength(1));
    expect(store.detailRequests, isEmpty);
    expect(d.h.model.editor.base!.labels, ['needs-human']);
    await d.close();
  });

  testWidgets(
    'save supersedes an active prewrite reload without publishing stale rows',
    (tester) async {
      final store = ModelStore(
        count: 205,
        delay: const Duration(milliseconds: 150),
      )..writer.includeTaskState = true;
      final d = ModelViewerDriver(tester, store);
      await d.mount();
      await d.select(ViewerRegion.tasks, 150);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await d.settle();
      final tasks = d.h.model.tasks!, id = tasks.selectedTaskId!;
      d.h.model.editor.setField(EditorField.title, 'After active reload');
      store.reads.clear();
      store.detailRequests.clear();
      unawaited(tasks.refresh());
      await d.pump(10);
      expect(tasks.isLoading, isTrue);
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      expect(store.writer.requests, hasLength(1));
      expect(store.detailRequests, isEmpty);
      expect(
        store.reads.where((r) => r.scope == 'tasks' && r.outcome == 'ok'),
        hasLength(1),
      );
      expect(store.overlaps, 0);
      expect(tasks.itemAt(tasks.selectedIndex!)!.title, 'After active reload');
      expect(
        d.h.model.editor.base!.version,
        store.records[tasks.projectId]![id]!.version,
      );
      await d.close();
    },
  );

  for (final mutation in [
    'missing',
    'truncated',
    'identity',
    'version',
    'row',
    'attachments',
  ]) {
    testWidgets(
      '$mutation optional state falls back without resending the mutation',
      (tester) async {
        final store = ModelStore(count: 2)..writer.includeTaskState = true;
        store.writer.taskStateTransform = (raw) {
          if (mutation == 'missing') return null;
          final state = raw! as Map<String, Object?>;
          final detail = state['detail']! as Map<String, Object?>;
          final row = state['row']! as Map<String, Object?>;
          switch (mutation) {
            case 'truncated':
              detail.remove('body');
            case 'identity':
              detail['id'] = 999;
            case 'version':
              row['version'] = 999;
            case 'row':
              row['title'] = 'Wrong title';
            case 'attachments':
              detail.remove('attachments');
          }
          return state;
        };
        final d = ModelViewerDriver(tester, store);
        await d.mount();
        await d.select(ViewerRegion.tasks, 0);
        await pressKey(tester, LogicalKeyboardKey.f4);
        await d.settle();
        d.h.model.editor.setField(EditorField.title, 'Fallback saved');
        store.reads.clear();
        store.detailRequests.clear();
        await pressControl(tester, LogicalKeyboardKey.keyS);
        await d.settle();
        expect(store.writer.requests, hasLength(1));
        expect(store.reads, hasLength(1));
        expect(store.detailRequests, hasLength(1));
        expect(d.h.model.editor.base!.title, 'Fallback saved');
        await d.close();
      },
    );
  }

  for (final sort in TaskSort.values) {
    for (final direction in SortDirection.values) {
      testWidgets(
        'save preserves row identity under ${sort.name} ${direction.name}',
        (tester) async {
          final store = ModelStore(count: 205)..writer.includeTaskState = true;
          final d = ModelViewerDriver(tester, store);
          await d.mount();
          final tasks = d.h.model.tasks!;
          tasks.setScope(TaskScope.all);
          tasks.setSort(sort);
          tasks.setDirection(direction);
          await d.settle();
          await d.select(ViewerRegion.tasks, 150);
          final id = tasks.selectedTaskId!;
          await pressKey(tester, LogicalKeyboardKey.f4);
          await d.settle();
          d.h.model.editor.setField(EditorField.title, 'ZZZ moved');
          d.h.model.editor.setField(EditorField.priority, 'P0');
          d.h.model.editor.setField(EditorField.status, 'blocked');
          store.reads.clear();
          store.detailRequests.clear();
          await pressControl(tester, LogicalKeyboardKey.keyS);
          await d.settle();
          final expected = store.orderedTasks(
            tasks.projectId,
            tasks.buildQuery(offset: 0),
          );
          expect(tasks.selectedTaskId, id);
          expect(tasks.selectedIndex, expected.indexWhere((t) => t.id == id));
          expect(tasks.itemAt(tasks.selectedIndex!)!.title, 'ZZZ moved');
          expect(store.detailRequests, isEmpty);
          expect(store.writer.requests, hasLength(1));
          final newIndex = expected.indexWhere((t) => t.id == id);
          // The existing anchor-first refresh locates identity, never guesses
          // its new row. Outside page 1 it reads membership and page 0 first.
          final expectedReads = newIndex >= 100 && newIndex < 200
              ? 1
              : newIndex < 100
              ? 3
              : 4;
          expect(store.reads, hasLength(expectedReads));
          await d.close();
        },
      );
    }
  }

  for (final action in ['save', 'status', 'done']) {
    testWidgets(
      '$action applies committed reply with one write and one list read',
      (tester) async {
        final store = ModelStore(count: 205)..writer.includeTaskState = true;
        final d = ModelViewerDriver(tester, store);
        await d.mount();
        final tasks = d.h.model.tasks!;
        tasks.setScope(TaskScope.all);
        await d.settle();
        await d.select(ViewerRegion.tasks, 150);
        final id = tasks.selectedTaskId!;
        final snapshot = tasks.snapshotToken;
        store.reads.clear();
        store.detailRequests.clear();
        if (action == 'save') {
          await pressKey(tester, LogicalKeyboardKey.f4);
          await d.settle();
          d.h.model.editor.setField(EditorField.title, 'Committed title');
          await pressControl(tester, LogicalKeyboardKey.keyS);
        } else if (action == 'status') {
          await pressKey(tester, LogicalKeyboardKey.keyB);
        } else {
          await pressControl(tester, LogicalKeyboardKey.keyD);
        }
        await d.settle();
        expect(store.writer.requests, hasLength(1));
        expect(store.reads, hasLength(1));
        expect(store.detailRequests, isEmpty);
        final committed = store.records[tasks.projectId]![id]!;
        expect(d.h.model.detail!.detail!.version, committed.version);
        expect(d.h.model.editor.base!.version, committed.version);
        expect(tasks.itemAt(150)!.version, committed.version);
        expect(tasks.selectedTaskId, id);
        expect(tasks.selectedIndex, 150);
        expect(tasks.snapshotToken, isNot(snapshot));
        expect(d.h.model.editor.isEditing, isFalse);
        expect(d.h.model.editor.isDirty, isFalse);
        await d.close();
      },
    );
  }

  testWidgets(
    'old server reply uses the authoritative list and detail fallback',
    (tester) async {
      final store = ModelStore(count: 2);
      final d = ModelViewerDriver(tester, store);
      await d.mount();
      await d.select(ViewerRegion.tasks, 0);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await d.settle();
      d.h.model.editor.setField(EditorField.title, 'Old server');
      store.reads.clear();
      store.detailRequests.clear();
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      expect(store.writer.requests, hasLength(1));
      expect(store.reads, hasLength(1));
      expect(store.detailRequests, hasLength(1));
      expect(d.h.model.editor.base!.title, 'Old server');
      await d.close();
    },
  );

  testWidgets(
    'row-removing header save keeps saved detail with only a list read',
    (tester) async {
      final store = ModelStore(count: 2)..writer.includeTaskState = true;
      final d = ModelViewerDriver(tester, store);
      await d.mount();
      await d.select(ViewerRegion.tasks, 0);
      final tasks = d.h.model.tasks!, id = tasks.selectedTaskId!;
      await pressKey(tester, LogicalKeyboardKey.f4);
      await d.settle();
      d.h.model.editor.setField(EditorField.status, 'done');
      store.reads.clear();
      store.detailRequests.clear();
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      expect(store.reads, hasLength(1));
      expect(store.detailRequests, isEmpty);
      expect(tasks.selectedTaskId, id);
      expect(tasks.selection, isA<Retained<int>>());
      expect(tasks.retainedText, 'Saved task no longer matches these filters');
      expect(d.h.model.detail!.detail!.status, 'done');
      await d.close();
    },
  );
}
