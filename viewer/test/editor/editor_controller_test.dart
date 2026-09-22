/// Controller semantics for the one open task editor: identity mirroring,
/// draft state, validation, version-checked saves, conflict rebasing, lost
/// acknowledgements and Mark done (viewer/spec.md section 7, viewer/design.md
/// sections 7 and 8).
///
/// Every test drives [ViewerEditorController] through the writer, detail
/// reader and draft sink of the shared support file, so nothing here can reach
/// a real task store or the real settings folder.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/editor_validation.dart';
import 'package:tasks_viewer/data/models.dart';

import '../support/viewer_test_support.dart';

const String editorProjectId = '11111111-2222-3333-4444-555555555555';
const String editorDataRoot = r'C:\viewer-test\editor\data';
const String otherDataRoot = r'D:\viewer-test\other\data';
const int editorTaskId = 7;
const int editorBaseVersion = 3;
const int fixedClockMs = 1700000000000;

/// Short autosave delay; the shipped 500 ms default is pinned separately.
const Duration fastAutosave = Duration(milliseconds: 20);

/// One confirmed record for the editor fixtures.
TaskDetail editorDetail({
  int id = editorTaskId,
  String title = 'Review parser',
  String body = 'Base body\n',
  String status = 'todo',
  String priority = 'P2',
  int version = editorBaseVersion,
  List<String> labels = const <String>['needs-human', 'zeta'],
  List<int> deps = const <int>[2],
}) => testTaskDetail(
  id,
  title: title,
  body: body,
  status: status,
  priority: priority,
  version: version,
  labels: labels,
  deps: deps,
);

/// The record the store holds once another writer touched it: version 4 with
/// title, status, priority and labels changed.
TaskDetail conflictCurrent() => editorDetail(
  title: 'Store title',
  status: 'in-progress',
  priority: 'P1',
  labels: <String>['store'],
  version: editorBaseVersion + 1,
);

/// One controller with the three shared doubles already behind it.
class EditorHarness {
  EditorHarness({
    required this.writer,
    required this.reads,
    required this.drafts,
    Duration autosaveDelay = fastAutosave,
    DateTime Function()? clock,
  }) : controller = ViewerEditorController(
         writer: writer,
         detailReader: reads,
         drafts: drafts,
         dataRoot: editorDataRoot,
         autosaveDelay: autosaveDelay,
         clock: clock,
       ) {
    addTearDown(controller.dispose);
  }

  final FakeTaskWriter writer;
  final FakeWorkspaceReads reads;
  final MemoryDraftSink drafts;
  final ViewerEditorController controller;
}

/// Builds a harness and, when [detail] is given, mirrors it into the editor.
EditorHarness editorHarness({
  TaskDetail? detail,
  Duration autosaveDelay = fastAutosave,
  DateTime Function()? clock,
}) {
  final harness = EditorHarness(
    writer: FakeTaskWriter(),
    reads: fakeWorkspaceReads(),
    drafts: MemoryDraftSink(),
    autosaveDelay: autosaveDelay,
    clock: clock,
  );
  if (detail != null) {
    harness.reads.details[detail.id] = detail;
    harness.controller.observeDetail(detail, projectId: editorProjectId);
  }
  return harness;
}

/// Opens the editor on the base record, types the draft every conflict test
/// shares, and makes the writer answer with a version conflict while the store
/// already holds [conflictCurrent].
Future<EditorSaveResult> enterVersionConflict(EditorHarness harness) {
  final controller = harness.controller;
  controller.beginEdit();
  controller.setField(EditorField.title, 'Mine title');
  controller.setField(EditorField.priority, 'P0');
  controller.setField(EditorField.labels, 'mine');
  controller.setField(EditorField.deps, '4');
  controller.setField(EditorField.body, 'Mine body\n');
  harness.reads.details[editorTaskId] = conflictCurrent();
  harness.writer.failure = const ViewerCliErrorFailure(
    code: 'version_conflict',
    message: 'task 7 changed since version 3',
    exitCode: 4,
  );
  return controller.save();
}

/// Status text the controller must show for one clean failure.
String expectedCleanFailureMessage(ViewerFailure failure) =>
    failure is ViewerCancelledFailure
    ? 'The save was superseded by another read; nothing was sent.'
    : failure.message;

void main() {
  group('observeDetail', () {
    test('mirrors the confirmed record and keeps the editor closed', () {
      final harness = editorHarness();
      final detail = editorDetail();

      harness.controller.observeDetail(detail, projectId: editorProjectId);

      expect(harness.controller.projectId, editorProjectId);
      expect(harness.controller.taskId, editorTaskId);
      expect(harness.controller.canonicalTaskId, 'T-007');
      expect(harness.controller.base, same(detail));
      expect(harness.controller.baseFields, TaskEditFields.fromDetail(detail));
      expect(harness.controller.draft, isNull);
      expect(harness.controller.isEditing, isFalse);
      expect(harness.controller.isDirty, isFalse);
      expect(harness.controller.saveEnabled, isFalse);
    });

    test('clears the confirmed record when no detail is available', () async {
      final harness = editorHarness(detail: editorDetail());

      harness.controller.observeDetail(null);

      expect(harness.controller.base, isNull);
      expect(harness.controller.baseFields, isNull);
      expect(harness.controller.draft, isNull);
      expect(harness.controller.conflict, isNull);
      expect(harness.controller.isEditing, isFalse);
      expect(harness.controller.isDirty, isFalse);
      expect(harness.controller.saveEnabled, isFalse);

      // Without a record there is nothing to save or mark done.
      expect(
        (await harness.controller.save()).outcome,
        EditorSaveOutcome.failed,
      );
      expect(
        (await harness.controller.markDone()).outcome,
        EditorSaveOutcome.failed,
      );
      expect(harness.writer.requests, isEmpty);
    });

    test('a refresh while editing never overwrites the draft', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'My unsaved title');

      controller.observeDetail(
        editorDetail(title: 'Someone else wrote this', version: 4),
        projectId: editorProjectId,
      );
      controller.observeDetail(null);

      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'My unsaved title');
      expect(controller.base?.version, editorBaseVersion);
      expect(controller.baseFields, TaskEditFields.fromDetail(editorDetail()));
      expect(controller.isDirty, isTrue);
    });

    test(
      'keeps the bound project and the last task id once the record goes',
      () {
        // Characterises the current code: with a project already bound,
        // observeDetail(null) drops the record while taskId/canonicalTaskId keep
        // naming the vanished task. The hand-off report calls this out.
        final harness = editorHarness(detail: editorDetail());

        harness.controller.observeDetail(null);

        expect(harness.controller.projectId, editorProjectId);
        expect(harness.controller.taskId, editorTaskId);
        expect(harness.controller.canonicalTaskId, 'T-007');
        expect(harness.controller.base, isNull);

        // Nothing can reopen the editor without a record.
        harness.controller.beginEdit();
        expect(harness.controller.isEditing, isFalse);
        expect(harness.controller.draft, isNull);
      },
    );
  });

  group('beginEdit', () {
    test('opens a clean editor on the confirmed record', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;

      controller.beginEdit();

      expect(controller.isEditing, isTrue);
      expect(controller.draft, TaskEditFields.fromDetail(editorDetail()));
      expect(controller.draft?.labelsText, 'needs-human, zeta');
      expect(controller.draft?.depsText, 'T-002');
      expect(controller.isDirty, isFalse);
      expect(controller.saveEnabled, isFalse);
      expect(controller.errors, isEmpty);
    });

    test('does nothing without a confirmed record', () {
      final harness = editorHarness();

      harness.controller.beginEdit();

      expect(harness.controller.isEditing, isFalse);
      expect(harness.controller.draft, isNull);
    });
  });

  group('setField and autosave', () {
    test('marks the form dirty and clears only that field error', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();

      controller.setField(EditorField.title, '');
      controller.validateField(EditorField.title);
      expect(controller.errors[EditorField.title], isNotNull);

      controller.setField(EditorField.labels, 'Bad Label');
      controller.validateField(EditorField.labels);
      expect(controller.errors[EditorField.labels], isNotNull);

      controller.setField(EditorField.title, 'Review parser v2');

      expect(controller.errors.containsKey(EditorField.title), isFalse);
      expect(controller.errors[EditorField.labels], isNotNull);
      expect(controller.isDirty, isTrue);
      expect(controller.saveEnabled, isTrue);
      expect(harness.writer.requests, isEmpty);
    });

    test('writes the recovery draft only after the idle delay', () async {
      expect(editorDraftAutosaveDelay, const Duration(milliseconds: 500));
      final harness = editorHarness(
        detail: editorDetail(),
        autosaveDelay: const Duration(milliseconds: 120),
        clock: () => DateTime.fromMillisecondsSinceEpoch(fixedClockMs),
      );
      final controller = harness.controller;
      controller.beginEdit();

      controller.setField(EditorField.title, 'Review parser v2');

      expect(harness.drafts.saves, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(harness.drafts.saves, 0);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(harness.drafts.saves, 1);
      final draft = harness.drafts.drafts.values.single;
      expect(draft.dataRoot, editorDataRoot);
      expect(draft.projectId, editorProjectId);
      expect(draft.taskId, 'T-007');
      expect(draft.baseVersion, editorBaseVersion);
      expect(draft.updatedMs, fixedClockMs);
      expect(draft.baseFields['title'], 'Review parser');
      expect(draft.draftFields['title'], 'Review parser v2');
      expect(draft.draftFields['deps_text'], 'T-002');
    });
  });

  group('validateField', () {
    test('sets exactly the validated field message', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, '');

      controller.validateField(EditorField.title);

      final expected = validateEditorFields(
        TaskEditFields.fromDetail(editorDetail()).copyWith(title: ''),
        taskId: editorTaskId,
      ).errors[EditorField.title];
      expect(expected, isNotNull);
      expect(controller.errors.length, 1);
      expect(controller.errors[EditorField.title], expected);
      expect(controller.firstInvalidField, EditorField.title);
    });

    test('counts title characters in Unicode scalar values', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();

      controller.setField(EditorField.title, 'x' * 501);
      controller.validateField(EditorField.title);
      expect(controller.errors[EditorField.title], contains('501'));

      controller.setField(EditorField.title, 'y' * 500);
      controller.validateField(EditorField.title);
      expect(controller.errors.containsKey(EditorField.title), isFalse);
    });

    test('checks label length and label count', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();

      controller.setField(EditorField.labels, 'a' * 65);
      controller.validateField(EditorField.labels);
      expect(controller.errors[EditorField.labels], contains('65'));

      controller.setField(
        EditorField.labels,
        List<String>.generate(33, (int index) => 'l$index').join(', '),
      );
      controller.validateField(EditorField.labels);
      expect(controller.errors[EditorField.labels], contains('33'));
      expect(controller.errors[EditorField.labels], contains('32'));
    });

    test('rejects a self dependency and leaves unknown IDs to the store', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();

      controller.setField(EditorField.deps, 'T-007, T-002');
      controller.validateField(EditorField.deps);
      expect(controller.errors[EditorField.deps], contains('T-007'));

      // T-999 cannot be judged locally. Spec section 7 keeps unknown-ID
      // rejection in the store, whose message is displayed unchanged.
      controller.setField(EditorField.deps, 'T-999');
      controller.validateField(EditorField.deps);
      expect(controller.errors.containsKey(EditorField.deps), isFalse);
    });

    test('does nothing while the editor is closed', () {
      final harness = editorHarness(detail: editorDetail());

      harness.controller.validateField(EditorField.title);

      expect(harness.controller.errors, isEmpty);
    });
  });

  group('save', () {
    test('a clean form reports a no-op and sends no request', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.noop);
      expect(result.message, 'No changes needed');
      expect(result.version, editorBaseVersion);
      expect(result.eventId, isNull);
      expect(harness.writer.requests, isEmpty);
      // The clean-form return leaves the editor open; the store no-op answer
      // is the path that closes it.
      expect(controller.isEditing, isTrue);
    });

    test(
      'a changed form sends one request and closes on confirmation',
      () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        controller.beginEdit();
        controller.setField(EditorField.title, 'Review parser v2');
        controller.setField(
          EditorField.labels,
          '  ZETA , Needs-Human ,zeta, ALPHA ',
        );
        controller.setField(EditorField.deps, 'T-2, 4');
        controller.setField(EditorField.body, 'Base body plus one more line\n');
        expect(controller.isDirty, isTrue);
        await controller.flushDraft();
        expect(harness.drafts.drafts, isNotEmpty);
        final deletes = harness.drafts.deletes;
        harness.writer
          ..nextVersion = 4
          ..nextEventId = 42
          ..nextStatus = 'todo';

        final result = await controller.save();

        expect(harness.writer.projectIds, <String>[editorProjectId]);
        expect(harness.writer.requests, hasLength(1));
        expect(harness.writer.lastRequest.toJson(), <String, Object?>{
          'id': editorTaskId,
          'expect_version': editorBaseVersion,
          'changes': <String, Object?>{
            'title': 'Review parser v2',
            'body': 'Base body plus one more line\n',
            'labels': <String>['alpha', 'needs-human', 'zeta'],
            'deps': <int>[2, 4],
          },
        });
        expect(result.outcome, EditorSaveOutcome.saved);
        expect(result.message, 'Saved T-007, version 4');
        expect(result.version, 4);
        expect(result.eventId, 42);
        expect(controller.isEditing, isFalse);
        expect(controller.draft, isNull);
        expect(harness.drafts.deletes, greaterThan(deletes));
        expect(harness.drafts.drafts, isEmpty);
      },
    );

    test('a draft that normalizes to the store values is a no-op', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.labels, '  ZETA , needs-human ');
      controller.setField(EditorField.deps, '2');

      expect(controller.isDirty, isFalse);
      expect(controller.saveEnabled, isFalse);

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.noop);
      expect(result.message, 'No changes needed');
      expect(harness.writer.requests, isEmpty);
      expect(controller.isEditing, isTrue);
    });

    test('an invalid draft never reaches the writer', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, '');
      controller.setField(EditorField.labels, 'Bad Label');

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.invalid);
      expect(result.message, isNotNull);
      expect(result.message, contains('Title:'));
      expect(controller.firstInvalidField, EditorField.title);
      expect(
        controller.errors.keys,
        containsAll(<EditorField>[EditorField.title, EditorField.labels]),
      );
      expect(harness.writer.requests, isEmpty);
      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, '');
      expect(controller.isDirty, isTrue);
      expect(controller.isSaving, isFalse);
    });

    test('a store no-op closes the editor and clears the draft', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      await controller.flushDraft();
      final deletes = harness.drafts.deletes;
      harness.writer
        ..nextEventId = null
        ..nextVersion = 99;

      final result = await controller.save();

      expect(harness.writer.requests, hasLength(1));
      expect(result.outcome, EditorSaveOutcome.noop);
      expect(result.message, 'No changes needed');
      expect(result.eventId, isNull);
      // The double answers the expected version when the store creates no
      // event, exactly like a real no-op.
      expect(result.version, editorBaseVersion);
      expect(controller.isEditing, isFalse);
      expect(harness.drafts.deletes, greaterThan(deletes));
      expect(harness.drafts.drafts, isEmpty);
    });

    test('isSaving covers exactly the in-flight write', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      harness.writer.latency = const Duration(milliseconds: 40);

      final pending = controller.save();
      await pumpEventQueue();

      expect(controller.isSaving, isTrue);
      expect(controller.saveEnabled, isFalse);

      final result = await pending;

      expect(result.outcome, EditorSaveOutcome.saved);
      expect(controller.isSaving, isFalse);
      expect(harness.writer.requests, hasLength(1));
    });
  });

  group('version conflicts', () {
    test('a conflict keeps the draft and exposes the current record', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;

      final result = await enterVersionConflict(harness);

      expect(result.outcome, EditorSaveOutcome.conflict);
      expect(harness.writer.requests, hasLength(1)); // the rejected attempt
      expect(harness.reads.detailRequests, <int>[editorTaskId]);
      final conflict = controller.conflict;
      if (conflict == null) {
        fail('a version conflict must open the review state');
      }
      expect(conflict.baseVersion, editorBaseVersion);
      expect(conflict.current.version, editorBaseVersion + 1);
      expect(conflict.current.title, 'Store title');
      expect(conflict.current.canonicalId, 'T-007');
      expect(conflict.currentFields.labelsText, 'store');
      expect(conflict.changedFields, <EditorField>[
        EditorField.title,
        EditorField.status,
        EditorField.priority,
        EditorField.labels,
        EditorField.deps,
        EditorField.body,
      ]);
      expect(conflict.conflictFields, <EditorField>[
        EditorField.title,
        EditorField.priority,
        EditorField.labels,
      ]);
      expect(conflict.hasConflicts, isTrue);
      expect(conflict.isResolved, isFalse);
      // The draft, its base and the editor survive the rejection.
      expect(controller.isEditing, isTrue);
      expect(controller.base?.version, editorBaseVersion);
      expect(controller.baseFields, TaskEditFields.fromDetail(editorDetail()));
      expect(controller.draft?.title, 'Mine title');
      expect(controller.draft?.body, 'Mine body\n');
      // Choices are per conflicting field.
      final titleChosen = conflict.withChoice(
        EditorField.title,
        EditorConflictChoice.mine,
      );
      expect(titleChosen.isResolved, isFalse);
      expect(
        titleChosen
            .withChoice(EditorField.priority, EditorConflictChoice.current)
            .withChoice(EditorField.labels, EditorConflictChoice.current)
            .isResolved,
        isTrue,
      );
    });

    test('applyConflictReview rebases the form without writing', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      await enterVersionConflict(harness);
      final attempts = harness.writer.requests.length;

      controller.applyConflictReview(<EditorField, EditorConflictChoice>{
        EditorField.title: EditorConflictChoice.mine,
        EditorField.priority: EditorConflictChoice.current,
        EditorField.labels: EditorConflictChoice.current,
      });

      expect(controller.conflict, isNull);
      expect(controller.isEditing, isTrue);
      // A field the user did not touch adopts current, a mine choice keeps the
      // user text, a current choice adopts the stored text, and body, labels
      // and dependencies stay whole fields with no automatic merge.
      expect(controller.draft?.title, 'Mine title');
      expect(controller.draft?.status, 'in-progress');
      expect(controller.draft?.priority, 'P1');
      expect(controller.draft?.labelsText, 'store');
      expect(controller.draft?.depsText, '4');
      expect(controller.draft?.body, 'Mine body\n');
      // The base becomes the current record at its own version.
      expect(controller.base?.version, editorBaseVersion + 1);
      expect(
        controller.baseFields,
        TaskEditFields.fromDetail(conflictCurrent()),
      );
      // The review itself writes nothing.
      expect(harness.writer.requests, hasLength(attempts));
    });

    test('the save after a review uses the freshly read version', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      await enterVersionConflict(harness);
      controller.applyConflictReview(<EditorField, EditorConflictChoice>{
        EditorField.title: EditorConflictChoice.mine,
        EditorField.priority: EditorConflictChoice.current,
        EditorField.labels: EditorConflictChoice.current,
      });
      harness.writer
        ..nextVersion = 5
        ..nextEventId = 60
        ..nextStatus = 'in-progress';

      final result = await controller.save();

      expect(harness.writer.requests, hasLength(2));
      expect(harness.writer.lastRequest.toJson(), <String, Object?>{
        'id': editorTaskId,
        'expect_version': editorBaseVersion + 1,
        'changes': <String, Object?>{
          'title': 'Mine title',
          'body': 'Mine body\n',
          'deps': <int>[4],
        },
      });
      expect(result.outcome, EditorSaveOutcome.saved);
      expect(result.message, 'Saved T-007, version 5');
    });

    test(
      'reloadCurrentAndDiscardDraft adopts the store and clears the draft',
      () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        await enterVersionConflict(harness);
        await controller.flushDraft();
        expect(harness.drafts.drafts, isNotEmpty);
        final deletes = harness.drafts.deletes;
        final attempts = harness.writer.requests.length;

        await controller.reloadCurrentAndDiscardDraft();

        expect(controller.conflict, isNull);
        expect(controller.isEditing, isTrue);
        expect(controller.base?.version, editorBaseVersion + 1);
        expect(controller.draft, TaskEditFields.fromDetail(conflictCurrent()));
        expect(controller.isDirty, isFalse);
        expect(controller.saveEnabled, isFalse);
        expect(controller.errors, isEmpty);
        expect(harness.drafts.deletes, greaterThan(deletes));
        expect(harness.drafts.drafts, isEmpty);
        expect(harness.writer.requests, hasLength(attempts));
      },
    );
  });

  group('unknown save outcomes', () {
    final Map<String, ViewerFailure> unknownFailures = <String, ViewerFailure>{
      'a timeout': const ViewerTimeoutFailure(Duration(seconds: 30)),
      'a malformed response': const ViewerMalformedResponseFailure(
        'truncated payload',
      ),
      'an unparsed error': const ViewerCliErrorFailure(
        code: 'unparsed_error',
        message: 'the CLI exited without a usable answer',
        exitCode: 1,
      ),
    };

    for (final entry in unknownFailures.entries) {
      test('${entry.key} reconciles through one show read', () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        controller.beginEdit();
        controller.setField(EditorField.title, 'Review parser v2');
        await controller.flushDraft();
        final deletes = harness.drafts.deletes;
        harness.reads
          ..latency = const Duration(milliseconds: 40)
          ..details[editorTaskId] = editorDetail(
            title: 'Review parser v2',
            version: editorBaseVersion + 1,
          );
        harness.writer.failure = entry.value;

        final pending = controller.save();
        await pumpEventQueue();

        // While the lost write is being checked, Save is disabled.
        expect(controller.isAwaitingReconciliation, isTrue);
        expect(controller.saveEnabled, isFalse);
        expect(controller.isSaving, isFalse);

        final result = await pending;

        expect(harness.writer.requests, hasLength(1));
        expect(harness.reads.detailRequests, <int>[editorTaskId]);
        expect(result.outcome, EditorSaveOutcome.reconciled);
        expect(result.message, contains('acknowledgement was lost'));
        expect(result.version, editorBaseVersion + 1);
        expect(controller.isAwaitingReconciliation, isFalse);
        expect(controller.isEditing, isFalse);
        expect(harness.drafts.deletes, greaterThan(deletes));
        expect(harness.drafts.drafts, isEmpty);
      });
    }

    test('a record still at the base version returns to unsaved', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      harness.writer.failure = const ViewerTimeoutFailure(
        Duration(seconds: 30),
      );
      // The store never saw the write: the record is still at version 3.
      harness.reads.details[editorTaskId] = editorDetail();

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.unsaved);
      expect(result.message, contains('Retry'));
      expect(result.version, editorBaseVersion);
      expect(harness.reads.detailRequests, <int>[editorTaskId]);
      expect(harness.writer.requests, hasLength(1));
      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'Review parser v2');
      expect(controller.isAwaitingReconciliation, isFalse);
      expect(controller.saveEnabled, isTrue);

      // The unsaved answer ends the reconciliation window: the Retry the
      // status text promises is Save, and it must not resend anything here.
      final retry = await controller.retryReconciliation();
      expect(retry.outcome, EditorSaveOutcome.failed);
      expect(retry.message, 'There is no unresolved save to reconcile.');
      expect(harness.writer.requests, hasLength(1));
      expect(harness.reads.detailRequests, <int>[editorTaskId]);

      harness.writer
        ..nextVersion = 4
        ..nextEventId = 70;
      final second = await controller.save();

      expect(harness.writer.requests, hasLength(2));
      expect(harness.writer.lastRequest.toJson(), <String, Object?>{
        'id': editorTaskId,
        'expect_version': editorBaseVersion,
        'changes': <String, Object?>{'title': 'Review parser v2'},
      });
      expect(second.outcome, EditorSaveOutcome.saved);
    });

    test('a record at another version opens the conflict instead', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      harness.writer.failure = const ViewerMalformedResponseFailure(
        'truncated payload',
      );
      harness.reads.details[editorTaskId] = editorDetail(
        title: 'Store title',
        version: editorBaseVersion + 1,
      );

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.conflict);
      final conflict = result.conflict;
      if (conflict == null) {
        fail('a newer record must open the conflict workflow');
      }
      expect(conflict.current.version, editorBaseVersion + 1);
      expect(conflict.current.title, 'Store title');
      expect(conflict.conflictFields, <EditorField>[EditorField.title]);
      expect(controller.conflict, isNotNull);
      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'Review parser v2');
      expect(controller.isAwaitingReconciliation, isFalse);
      expect(harness.writer.requests, hasLength(1));
    });

    test('a failed reconciliation read keeps the outcome unknown', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      await controller.flushDraft();
      final deletes = harness.drafts.deletes;
      harness.writer.failure = const ViewerTimeoutFailure(
        Duration(seconds: 30),
      );
      harness.reads.detailFailure = const ViewerTimeoutFailure(
        Duration(seconds: 30),
      );

      final result = await controller.save();

      expect(result.outcome, EditorSaveOutcome.failed);
      expect(result.message, contains('Save stays disabled'));
      expect(controller.isAwaitingReconciliation, isTrue);
      expect(controller.saveEnabled, isFalse);
      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'Review parser v2');
      expect(harness.drafts.drafts, isNotEmpty);
      expect(harness.drafts.deletes, deletes);
      expect(harness.writer.requests, hasLength(1));
      expect(harness.reads.detailRequests, <int>[editorTaskId]);

      // A second save is refused while the outcome is unknown.
      final refused = await controller.save();
      expect(refused.outcome, EditorSaveOutcome.failed);
      expect(refused.message, contains('still unknown'));
      expect(harness.writer.requests, hasLength(1));

      // Retrying only re-reads the record; the mutation is never resent.
      harness.reads.detailFailure = null;
      harness.reads.details[editorTaskId] = editorDetail(
        title: 'Review parser v2',
        version: editorBaseVersion + 1,
      );
      final retried = await controller.retryReconciliation();

      expect(retried.outcome, EditorSaveOutcome.reconciled);
      expect(harness.writer.requests, hasLength(1));
      expect(harness.reads.detailRequests, <int>[editorTaskId, editorTaskId]);
      expect(controller.isAwaitingReconciliation, isFalse);
      expect(harness.drafts.deletes, greaterThan(deletes));
      expect(harness.drafts.drafts, isEmpty);
    });

    test(
      'retryReconciliation without a pending outcome reports failed',
      () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        controller.beginEdit();
        controller.setField(EditorField.title, 'Review parser v2');

        final result = await controller.retryReconciliation();

        expect(result.outcome, EditorSaveOutcome.failed);
        expect(result.message, 'There is no unresolved save to reconcile.');
        expect(harness.writer.requests, isEmpty);
        expect(harness.reads.detailRequests, isEmpty);
      },
    );
  });

  group('clean failures', () {
    final Map<String, ViewerFailure> cleanFailures = <String, ViewerFailure>{
      'a request over the protocol limit': const ViewerRequestTooLargeFailure(
        byteLength: 9000000,
        limitBytes: 8388608,
      ),
      'a process that cannot start': const ViewerProcessStartFailure(
        'the tasks CLI could not be started',
      ),
      'a missing handshake': const ViewerProbeRequiredFailure(),
      'a protocol mismatch': const ViewerProtocolMismatchFailure(2),
      'a cancelled write': const ViewerCancelledFailure(),
      'a store rejection': const ViewerCliErrorFailure(
        code: 'unknown_dependency',
        message: 'dependency T-999 does not exist',
        exitCode: 3,
      ),
    };

    for (final entry in cleanFailures.entries) {
      test('${entry.key} keeps the draft and leaves Save usable', () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        controller.beginEdit();
        controller.setField(EditorField.title, 'Review parser v2');
        harness.writer.failure = entry.value;

        final result = await controller.save();

        expect(result.outcome, EditorSaveOutcome.failed);
        expect(result.message, expectedCleanFailureMessage(entry.value));
        expect(harness.writer.requests, hasLength(1));
        expect(controller.isSaving, isFalse);
        expect(controller.isAwaitingReconciliation, isFalse);
        expect(controller.isEditing, isTrue);
        expect(controller.draft?.title, 'Review parser v2');
        expect(controller.saveEnabled, isTrue);
        // Clean failures never trigger a reconciliation read.
        expect(harness.reads.detailRequests, isEmpty);
      });
    }
  });

  group('markDone', () {
    test('an already-done task is a no-op with no request', () async {
      final harness = editorHarness(detail: editorDetail(status: 'done'));

      final result = await harness.controller.markDone();

      expect(result.outcome, EditorSaveOutcome.noop);
      expect(result.message, 'T-007 is already done.');
      expect(result.version, editorBaseVersion);
      expect(harness.writer.requests, isEmpty);
    });

    test('a normal task is marked done with one status-only request', () async {
      final harness = editorHarness(detail: editorDetail());
      harness.writer
        ..nextVersion = 4
        ..nextEventId = 51
        ..nextStatus = 'done';

      final result = await harness.controller.markDone();

      expect(harness.writer.requests, hasLength(1));
      expect(harness.writer.projectIds, <String>[editorProjectId]);
      expect(harness.writer.lastRequest.toJson(), <String, Object?>{
        'id': editorTaskId,
        'expect_version': editorBaseVersion,
        'changes': <String, Object?>{'status': 'done'},
      });
      expect(result.outcome, EditorSaveOutcome.saved);
      expect(result.message, 'T-007 is done, version 4');
      expect(result.version, 4);
      expect(result.eventId, 51);
    });

    test('a dirty draft joins the done status in one request', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      controller.setField(EditorField.labels, 'alpha');
      harness.writer
        ..nextVersion = 4
        ..nextEventId = 52
        ..nextStatus = 'done';

      final result = await controller.markDone(includeDraft: true);

      expect(harness.writer.requests, hasLength(1));
      expect(harness.writer.lastRequest.toJson(), <String, Object?>{
        'id': editorTaskId,
        'expect_version': editorBaseVersion,
        'changes': <String, Object?>{
          'title': 'Review parser v2',
          'labels': <String>['alpha'],
          'status': 'done',
        },
      });
      expect(result.outcome, EditorSaveOutcome.saved);
      expect(result.message, 'T-007 is done, version 4');
      expect(controller.isEditing, isFalse);
    });

    test('without includeDraft only the status travels', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      await controller.flushDraft();
      harness.writer
        ..nextVersion = 4
        ..nextEventId = 53
        ..nextStatus = 'done';

      final result = await controller.markDone();

      expect(harness.writer.lastRequest.toJson(), <String, Object?>{
        'id': editorTaskId,
        'expect_version': editorBaseVersion,
        'changes': <String, Object?>{'status': 'done'},
      });
      expect(result.outcome, EditorSaveOutcome.saved);
      // A confirmed mark-done clears the draft the discarded changes lived in.
      expect(controller.isEditing, isFalse);
      expect(harness.drafts.drafts, isEmpty);
    });

    test('a failed mark-done keeps the draft and Save usable', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');
      harness.writer.failure = const ViewerCliErrorFailure(
        code: 'invalid_transition',
        message: 'task 7 cannot move from blocked to done',
        exitCode: 3,
      );

      final result = await controller.markDone(includeDraft: true);

      expect(result.outcome, EditorSaveOutcome.failed);
      expect(result.message, 'task 7 cannot move from blocked to done');
      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'Review parser v2');
      expect(controller.isSaving, isFalse);
      expect(controller.saveEnabled, isTrue);
      expect(harness.writer.requests, hasLength(1));
    });
  });

  group('leaving the editor', () {
    test('exitEdit closes without a write or a recovery draft', () async {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');

      controller.exitEdit();

      expect(controller.isEditing, isFalse);
      expect(controller.draft, isNull);
      expect(controller.isDirty, isFalse);
      expect(controller.saveEnabled, isFalse);
      expect(controller.errors, isEmpty);

      // The idle autosave was cancelled together with the draft.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(harness.writer.requests, isEmpty);
      expect(harness.drafts.saves, 0);
      expect(harness.drafts.drafts, isEmpty);
    });

    test('bindStore with the same root keeps the open draft', () {
      final harness = editorHarness(detail: editorDetail());
      final controller = harness.controller;
      controller.beginEdit();
      controller.setField(EditorField.title, 'Review parser v2');

      controller.bindStore(editorDataRoot);

      expect(controller.isEditing, isTrue);
      expect(controller.draft?.title, 'Review parser v2');
    });

    test(
      'bindStore with another root closes without crossing stores',
      () async {
        final harness = editorHarness(detail: editorDetail());
        final controller = harness.controller;
        controller.beginEdit();
        controller.setField(EditorField.title, 'Review parser v2');

        controller.bindStore(otherDataRoot);

        expect(controller.isEditing, isFalse);
        expect(controller.draft, isNull);
        expect(controller.isDirty, isFalse);
        expect(controller.conflict, isNull);

        // No keystroke from the old store reaches the new store's index.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(harness.drafts.saves, 0);
        expect(harness.drafts.drafts, isEmpty);
      },
    );
  });
}
