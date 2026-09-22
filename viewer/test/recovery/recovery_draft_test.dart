/// Recovery drafts on disk and their editor integration (viewer/spec.md
/// section 7 draft/recovery rules and V05).
///
/// Nothing here can reach the real settings root or a real task store: the
/// file-backed store gets a fresh temporary directory, and the editor gets an
/// in-memory sink, a short idle delay and a fixed clock.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/settings_store.dart';

import '../support/viewer_test_support.dart';

const String recoveryTestDataRoot = r'C:\Store\Data';
const String recoveryTestOtherRoot = r'D:\Other\Data';
const String recoveryTestProjectId = '00000000-0000-4000-8000-000000000001';
const int recoveryTestNowMs = 1700000000123;

/// A fresh temporary settings root, removed after the test.
Directory newRecoveryRoot() {
  final directory = Directory.systemTemp.createTempSync('viewer-recovery-');
  addTearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });
  return directory;
}

String recoveryIndexPath(Directory root) =>
    joinViewerPath(root.path, viewerRecoveryFileName);

RecoveryDraftStore newRecoveryStore(Directory root) => RecoveryDraftStore(
  indexFilePath: recoveryIndexPath(root),
  clock: () => DateTime.fromMillisecondsSinceEpoch(recoveryTestNowMs),
);

Future<void> writeRecoveryIndex(Directory root, String contents) async {
  await File(recoveryIndexPath(root)).writeAsString(contents);
}

/// One draft whose default fields mirror `testTaskDetail(7)`.
ViewerRecoveryDraft recoveryDraft({
  String dataRoot = recoveryTestDataRoot,
  String projectId = recoveryTestProjectId,
  String taskId = 'T-007',
  int baseVersion = 3,
  Map<String, Object?>? baseFields,
  Map<String, Object?>? draftFields,
  int updatedMs = recoveryTestNowMs,
}) => ViewerRecoveryDraft(
  dataRoot: dataRoot,
  projectId: projectId,
  taskId: taskId,
  baseVersion: baseVersion,
  baseFields:
      baseFields ??
      const <String, Object?>{
        'title': 'First task',
        'body': 'body text',
        'status': 'todo',
        'priority': 'P2',
        'labels_text': '',
        'deps_text': '',
      },
  draftFields:
      draftFields ??
      const <String, Object?>{
        'title': 'Typed title',
        'body': 'body text',
        'status': 'todo',
        'priority': 'P2',
        'labels_text': '',
        'deps_text': '',
      },
  updatedMs: updatedMs,
);

ViewerEditorController newEditor({
  required MemoryDraftSink sink,
  TaskUpdateWriter? writer,
  String? dataRoot = recoveryTestDataRoot,
  Duration autosaveDelay = const Duration(milliseconds: 20),
}) {
  final controller = ViewerEditorController(
    writer: writer ?? FakeTaskWriter(),
    drafts: sink,
    dataRoot: dataRoot,
    autosaveDelay: autosaveDelay,
    clock: () => DateTime.fromMillisecondsSinceEpoch(recoveryTestNowMs),
  );
  addTearDown(controller.dispose);
  return controller;
}

/// Waits past the injected 20 ms idle delay and the write its timer starts.
Future<void> settleAutosave() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  group('RecoveryDraftStore file behaviour', () {
    test('a missing index file reads as no drafts', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);

      expect(await store.loadAll(), isEmpty);
      expect(root.listSync(), isEmpty);
    });

    test('save then loadAll round-trips every field', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      final draft = recoveryDraft(
        baseVersion: 7,
        updatedMs: 1700000000999,
        baseFields: const <String, Object?>{
          'title': 'From the store',
          'status': 'todo',
        },
        draftFields: const <String, Object?>{
          'title': 'Typed by the user',
          'status': 'in-progress',
        },
      );

      await store.save(draft);
      final loaded = (await store.loadAll()).single;

      expect(loaded.dataRoot, recoveryTestDataRoot);
      expect(loaded.projectId, recoveryTestProjectId);
      expect(loaded.taskId, 'T-007');
      expect(loaded.baseVersion, 7);
      expect(loaded.baseFields, <String, Object?>{
        'title': 'From the store',
        'status': 'todo',
      });
      expect(loaded.draftFields, <String, Object?>{
        'title': 'Typed by the user',
        'status': 'in-progress',
      });
      expect(loaded.updatedMs, 1700000000999);
      expect(loaded.draftId, draft.draftId);
    });

    test('a second save replaces one draft and leaves the others', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      final second = recoveryDraft(
        taskId: 'T-002',
        baseVersion: 8,
        updatedMs: 1700000000888,
      );
      await store.save(recoveryDraft(taskId: 'T-001'));
      await store.save(second);
      await store.save(
        recoveryDraft(
          taskId: 'T-001',
          baseVersion: 9,
          draftFields: const <String, Object?>{'title': 'Replaced'},
        ),
      );

      final all = await store.loadAll();
      expect(all, hasLength(2));
      final replaced = all.singleWhere((entry) => entry.taskId == 'T-001');
      expect(replaced.baseVersion, 9);
      expect(replaced.draftFields['title'], 'Replaced');
      final untouched = all.singleWhere((entry) => entry.taskId == 'T-002');
      expect(untouched.baseVersion, 8);
      expect(untouched.updatedMs, 1700000000888);
    });

    test('delete removes only the named draft', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      final first = recoveryDraft(taskId: 'T-001');
      final second = recoveryDraft(taskId: 'T-002');
      await store.save(first);
      await store.save(second);

      await store.delete(first.draftId);

      expect((await store.loadAll()).single.draftId, second.draftId);
      await store.delete('missing|project|T-404');
      expect((await store.loadAll()).single.draftId, second.draftId);
    });

    test('the index is valid JSON with no temporary file behind', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      await store.save(recoveryDraft(taskId: 'T-001'));
      await store.save(recoveryDraft(taskId: 'T-002'));

      final text = await File(recoveryIndexPath(root)).readAsString();
      final document = jsonDecode(text) as Map<String, Object?>;
      expect(document['drafts'], isA<List<Object?>>());
      expect(document['drafts']! as List<Object?>, hasLength(2));

      final names = root
          .listSync()
          .map((entity) => entity.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names, <String>[viewerRecoveryFileName]);
      expect(names.where((name) => name.contains('.tmp-')), isEmpty);
    });
  });

  group('corrupt index tolerance', () {
    test('a completely malformed file yields no drafts', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      await writeRecoveryIndex(root, '{"drafts": [');

      expect(await store.loadAll(), isEmpty);
    });

    test('a JSON array instead of an object yields no drafts', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      await writeRecoveryIndex(
        root,
        jsonEncode(<Object?>[recoveryDraft().toJson()]),
      );

      expect(await store.loadAll(), isEmpty);
    });

    test('an entry that is not an object is skipped', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      final healthy = recoveryDraft(taskId: 'T-001');
      await writeRecoveryIndex(
        root,
        '{"schema_version":1,"drafts":['
        '${jsonEncode(healthy.toJson())},"not-a-draft"]}',
      );

      final loaded = await store.loadAll();
      expect(loaded.single.draftId, healthy.draftId);
    });

    test('an entry missing identity keys is skipped', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      final healthy = recoveryDraft(taskId: 'T-001');
      await writeRecoveryIndex(
        root,
        '{"schema_version":1,"drafts":['
        '{"data_root":"C:\\\\Store\\\\Data","project_id":"p1"}]}',
      );
      expect(await store.loadAll(), isEmpty);

      await writeRecoveryIndex(
        root,
        '{"schema_version":1,"drafts":['
        '${jsonEncode(healthy.toJson())},'
        '{"data_root":"C:\\\\Store\\\\Data","project_id":"p1"}]}',
      );
      expect((await store.loadAll()).single.draftId, healthy.draftId);
    });

    test('delete on a corrupt index does not throw', () async {
      final root = newRecoveryRoot();
      final store = newRecoveryStore(root);
      await writeRecoveryIndex(root, 'this is not JSON at all');

      await store.delete(recoveryDraft().draftId);

      expect(await store.loadAll(), isEmpty);
    });
  });

  group('draft identity', () {
    test('one store spelled two ways has one identity', () {
      expect(
        recoveryDraftSlug(r'C:\Store\Data'),
        recoveryDraftSlug('c:/store/data'),
      );
      expect(
        viewerRecoveryDraftId(
          dataRoot: r'C:\Store\Data',
          projectId: 'p1',
          taskId: 'T-007',
        ),
        viewerRecoveryDraftId(
          dataRoot: 'c:/store/data',
          projectId: 'p1',
          taskId: 'T-007',
        ),
      );
      expect(
        recoveryDraft(dataRoot: 'c:/store/data').draftId,
        recoveryDraft(dataRoot: r'C:\Store\Data').draftId,
      );
    });

    test('project and task both change the identity', () {
      const root = recoveryTestDataRoot;
      final base = viewerRecoveryDraftId(
        dataRoot: root,
        projectId: 'p1',
        taskId: 'T-007',
      );
      expect(
        viewerRecoveryDraftId(dataRoot: root, projectId: 'p2', taskId: 'T-007'),
        isNot(base),
      );
      expect(
        viewerRecoveryDraftId(dataRoot: root, projectId: 'p1', taskId: 'T-008'),
        isNot(base),
      );
    });

    test('two data roots never share an identity', () {
      expect(
        viewerRecoveryDraftId(
          dataRoot: recoveryTestDataRoot,
          projectId: 'p1',
          taskId: 'T-007',
        ),
        isNot(
          viewerRecoveryDraftId(
            dataRoot: recoveryTestOtherRoot,
            projectId: 'p1',
            taskId: 'T-007',
          ),
        ),
      );
      expect(
        viewerRecoveryDraftId(
          dataRoot: r'C:\Store\Data',
          projectId: 'p1',
          taskId: 'T-007',
        ),
        isNot(
          viewerRecoveryDraftId(
            dataRoot: r'C:\Store\Data2',
            projectId: 'p1',
            taskId: 'T-007',
          ),
        ),
      );
    });
  });

  group('editor autosave and flush', () {
    test('a dirty draft reaches the sink after the idle delay', () async {
      final sink = MemoryDraftSink();
      final controller = newEditor(sink: sink);
      controller.observeDetail(
        testTaskDetail(7, title: 'First task', version: 3),
        projectId: recoveryTestProjectId,
      );
      controller.beginEdit();

      controller.setField(EditorField.title, 'Typed title');
      controller.setField(EditorField.labels, '  ZETA , needs-human ');

      expect(sink.saves, 0, reason: 'nothing is written before the delay');

      await settleAutosave();

      final written = sink.drafts.values.single;
      expect(
        written.draftId,
        viewerRecoveryDraftId(
          dataRoot: recoveryTestDataRoot,
          projectId: recoveryTestProjectId,
          taskId: 'T-007',
        ),
      );
      expect(written.baseVersion, 3);
      expect(written.baseFields['title'], 'First task');
      expect(written.draftFields['title'], 'Typed title');
      expect(
        written.draftFields['labels_text'],
        '  ZETA , needs-human ',
        reason: 'the draft keeps what the user typed, not the normalized form',
      );
      expect(written.updatedMs, recoveryTestNowMs);
    });

    test('flushDraft writes without waiting for the idle delay', () async {
      final sink = MemoryDraftSink();
      final controller = newEditor(
        sink: sink,
        autosaveDelay: const Duration(seconds: 5),
      );
      controller.observeDetail(
        testTaskDetail(7, title: 'First task', version: 3),
        projectId: recoveryTestProjectId,
      );
      controller.beginEdit();
      controller.setField(EditorField.body, 'Body typed once');

      await controller.flushDraft();

      final written = sink.drafts.values.single;
      expect(written.draftFields['body'], 'Body typed once');
      expect(written.baseVersion, 3);
      expect(sink.saves, 1);
    });

    test('a form that matches the store deletes instead of saving', () async {
      final sink = MemoryDraftSink();
      final detail = testTaskDetail(7, title: 'First task', version: 3);
      final fields = TaskEditFields.fromDetail(detail);
      final stale = recoveryDraft(
        baseVersion: 3,
        baseFields: fields.toJson(),
        draftFields: fields.copyWith(title: 'Old typing').toJson(),
      );
      sink.drafts[stale.draftId] = stale;
      final controller = newEditor(sink: sink);
      controller.observeDetail(detail, projectId: recoveryTestProjectId);
      controller.beginEdit();

      expect(controller.isDirty, isFalse);
      await controller.flushDraft();

      expect(sink.drafts, isEmpty);
      expect(sink.saves, 0, reason: 'a clean form is not worth recovering');
      expect(sink.deletes, 1);
    });
  });

  group('recovery list, warnings and removal', () {
    test('loadRecoveryDrafts offers only the bound store', () async {
      final sink = MemoryDraftSink();
      for (final draft in <ViewerRecoveryDraft>[
        recoveryDraft(taskId: 'T-007'),
        recoveryDraft(taskId: 'T-008'),
        recoveryDraft(dataRoot: recoveryTestOtherRoot, taskId: 'T-009'),
      ]) {
        sink.drafts[draft.draftId] = draft;
      }
      final controller = newEditor(sink: sink);

      await controller.loadRecoveryDrafts();

      expect(controller.recoveryDrafts, hasLength(3));
      expect(controller.recoveryWarning, isNull);
      expect(
        controller.pendingDrafts.map((draft) => draft.taskId).toSet(),
        <String>{'T-007', 'T-008'},
      );
    });

    test('a failing load raises a warning instead of throwing', () async {
      final sink = MemoryDraftSink()
        ..loadFailure = const FileSystemException('the index is unreadable');
      final controller = newEditor(sink: sink);

      await controller.loadRecoveryDrafts();

      expect(controller.recoveryDrafts, isEmpty);
      expect(controller.recoveryWarning, isNotNull);
      expect(
        controller.recoveryWarning,
        contains('Recovery drafts could not be read'),
      );

      sink.loadFailure = null;
      await controller.loadRecoveryDrafts();
      expect(controller.recoveryWarning, isNull);
    });

    test(
      'a failing save keeps a persistent warning that asks for a copy',
      () async {
        final sink = MemoryDraftSink()
          ..saveFailure = const FileSystemException('the disk is full');
        final controller = newEditor(sink: sink);
        controller.observeDetail(
          testTaskDetail(7, title: 'First task', version: 3),
          projectId: recoveryTestProjectId,
        );
        controller.beginEdit();
        controller.setField(EditorField.title, 'Typed title');

        await controller.flushDraft();

        expect(controller.isDirty, isTrue, reason: 'the draft stays open');
        final warning = controller.persistenceWarning;
        expect(warning, isNotNull);
        expect(warning, contains('Copy it'));

        controller.setField(EditorField.title, 'Typed title again');
        expect(
          controller.persistenceWarning,
          warning,
          reason: 'the warning is persistent, not a transient status',
        );
      },
    );

    test('a later successful write clears the warning', () async {
      final sink = MemoryDraftSink()
        ..saveFailure = const FileSystemException('the disk is full');
      final controller = newEditor(sink: sink);
      controller.observeDetail(
        testTaskDetail(7, title: 'First task', version: 3),
        projectId: recoveryTestProjectId,
      );
      controller.beginEdit();
      controller.setField(EditorField.title, 'Typed title');
      await controller.flushDraft();
      expect(controller.persistenceWarning, isNotNull);

      sink.saveFailure = null;
      await controller.flushDraft();

      expect(controller.persistenceWarning, isNull);
      expect(sink.drafts.values.single.draftFields['title'], 'Typed title');
    });

    test('discard and settle stop offering the draft', () async {
      final sink = MemoryDraftSink();
      final first = recoveryDraft(taskId: 'T-007');
      final second = recoveryDraft(taskId: 'T-008');
      sink.drafts[first.draftId] = first;
      sink.drafts[second.draftId] = second;
      final controller = newEditor(sink: sink);
      await controller.loadRecoveryDrafts();

      await controller.discardRecoveryDraft(first);

      expect(controller.pendingDrafts.map((draft) => draft.draftId), <String>[
        second.draftId,
      ]);
      expect(sink.drafts.keys, <String>[second.draftId]);

      controller.settleRecoveryDraft(second);

      expect(controller.recoveryDrafts, isEmpty);
      expect(controller.pendingDrafts, isEmpty);
      expect(
        sink.drafts.keys,
        <String>[second.draftId],
        reason: 'Restore keeps the disk copy until a confirmed save deletes it',
      );
      expect(sink.deletes, 1);
    });
  });

  group('bindStore', () {
    test('a different root drops drafts and never re-homes them', () async {
      final sink = MemoryDraftSink();
      final controller = newEditor(sink: sink);
      controller.observeDetail(
        testTaskDetail(7, title: 'First task', version: 3),
        projectId: recoveryTestProjectId,
      );
      controller.beginEdit();
      controller.setField(EditorField.title, 'Typed on A');
      await controller.flushDraft();
      await controller.loadRecoveryDrafts();
      final firstId = viewerRecoveryDraftId(
        dataRoot: recoveryTestDataRoot,
        projectId: recoveryTestProjectId,
        taskId: 'T-007',
      );
      expect(sink.drafts.keys, <String>[firstId]);
      expect(controller.pendingDrafts, hasLength(1));

      // A change that has not reached disk yet, then a store switch anyway.
      controller.setField(EditorField.title, 'Typed on A again');
      controller.bindStore(recoveryTestOtherRoot);
      await controller.flushDraft();
      await settleAutosave();

      expect(controller.isEditing, isFalse);
      expect(controller.recoveryDrafts, isEmpty);
      expect(sink.saves, 1);
      expect(sink.drafts.keys, <String>[firstId]);
      expect(sink.drafts[firstId]!.dataRoot, recoveryTestDataRoot);
      expect(sink.drafts[firstId]!.draftFields['title'], 'Typed on A');

      // The other store's draft is on disk but is not offered here.
      await controller.loadRecoveryDrafts();
      expect(controller.recoveryDrafts, hasLength(1));
      expect(controller.pendingDrafts, isEmpty);

      controller.observeDetail(
        testTaskDetail(8, title: 'Second task', version: 1),
        projectId: recoveryTestProjectId,
      );
      controller.beginEdit();
      controller.setField(EditorField.title, 'Typed on B');
      await controller.flushDraft();

      final secondId = viewerRecoveryDraftId(
        dataRoot: recoveryTestOtherRoot,
        projectId: recoveryTestProjectId,
        taskId: 'T-008',
      );
      expect(sink.drafts[secondId]!.dataRoot, recoveryTestOtherRoot);
      expect(
        sink.drafts[firstId]!.draftFields['title'],
        'Typed on A',
        reason: 'the other store kept its own draft untouched',
      );
    });
  });

  group('restore path', () {
    test('a draft at the current version opens a clean editor', () async {
      final sink = MemoryDraftSink();
      final controller = newEditor(sink: sink);
      final current = testTaskDetail(7, title: 'First task', version: 3);
      final baseFields = TaskEditFields.fromDetail(current);
      final draftFields = baseFields.copyWith(
        title: 'Typed title',
        body: 'Typed body',
      );

      controller.restoreDraft(
        projectId: recoveryTestProjectId,
        current: current,
        baseFields: baseFields,
        baseVersion: 3,
        draftFields: draftFields,
      );

      expect(controller.isEditing, isTrue);
      expect(controller.projectId, recoveryTestProjectId);
      expect(controller.taskId, 7);
      expect(controller.conflict, isNull);
      expect(controller.draft, draftFields);
      expect(controller.baseFields, baseFields);
      expect(controller.base, same(current));
      expect(controller.isDirty, isTrue);
    });

    test('a newer record opens the conflict with the fresh record', () async {
      final sink = MemoryDraftSink();
      final controller = newEditor(sink: sink);
      final baseFields = TaskEditFields.fromDetail(
        testTaskDetail(7, title: 'First task', version: 3),
      );
      final draftFields = baseFields.copyWith(title: 'Typed title');
      final current = testTaskDetail(7, title: 'Changed elsewhere', version: 9);

      controller.restoreDraft(
        projectId: recoveryTestProjectId,
        current: current,
        baseFields: baseFields,
        baseVersion: 3,
        draftFields: draftFields,
      );

      final conflict = controller.conflict;
      expect(conflict, isNotNull);
      expect(conflict!.current, same(current));
      expect(conflict.current.version, 9);
      expect(
        conflict.baseVersion,
        3,
        reason: 'the question names the version the draft was written against',
      );
      expect(conflict.currentVersion, 9);
      expect(conflict.baseFields, baseFields);
      expect(conflict.draftFields, draftFields);
      expect(
        controller.draft,
        draftFields,
        reason: 'the typed draft survives the conflict',
      );
      expect(controller.isDirty, isTrue);
    });

    test(
      'a confirmed save after a restore deletes exactly that draft',
      () async {
        final sink = MemoryDraftSink();
        final recovered = recoveryDraft(taskId: 'T-007');
        final untouched = recoveryDraft(taskId: 'T-008');
        sink.drafts[recovered.draftId] = recovered;
        sink.drafts[untouched.draftId] = untouched;
        final writer = FakeTaskWriter()..nextVersion = 4;
        final controller = newEditor(sink: sink, writer: writer);
        final current = testTaskDetail(7, title: 'First task', version: 3);
        final baseFields = TaskEditFields.fromDetail(current);
        final draftFields = baseFields.copyWith(title: 'Typed title');

        controller.restoreDraft(
          projectId: recoveryTestProjectId,
          current: current,
          baseFields: baseFields,
          baseVersion: recovered.baseVersion,
          draftFields: draftFields,
        );

        final result = await controller.save();

        expect(result.outcome, EditorSaveOutcome.saved);
        expect(writer.lastRequest.expectVersion, 3);
        expect(writer.lastRequest.changes.title, 'Typed title');
        expect(controller.isEditing, isFalse);
        expect(sink.drafts.keys, <String>[untouched.draftId]);
        expect(sink.deletes, 1);
      },
    );
  });
}
