/// Editor flows through the real workspace: Save, Ctrl+D, conflicts, lost
/// acknowledgements, recovery drafts and the leaving guards.
///
/// Contract: viewer/spec.md section 7 with viewer/design.md sections 7 and 9.
/// Every launch injects the synthetic readers, a scripted writer and an
/// in-memory draft sink, so no test can reach a real task store.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';

import '../support/viewer_test_support.dart';

/// Project UUID the default synthetic catalog uses.
const String firstProjectId = '00000000-0000-4000-8000-000000000001';

/// Data root [viewerTestEnvironment] injects; a recovery draft only belongs to
/// the window that reads that exact store.
const String testDataRoot = r'C:\viewer-test\default\data';

/// Opens the first task of the first project on the synthetic catalog.
Future<RealViewerHarness> openFirstTask(
  WidgetTester tester, {
  FakeWorkspaceReads? reads,
  FakeTaskWriter? update,
  MemoryDraftSink? drafts,
  AnnouncementMode mode = AnnouncementMode.nvdaOnly,
  bool open = true,
}) async {
  final harness = await pumpRealViewer(
    tester,
    reads: reads,
    update: update,
    drafts: drafts,
    mode: mode,
  );
  harness.model.selectProjectIndex(0);
  await tester.pumpAndSettle();
  if (open) {
    await harness.model.openTaskIndex(0);
    await tester.pumpAndSettle();
  }
  return harness;
}

/// One labelled control of the open editor form.
Finder editorField(String label) => textFieldWithLabel(label);

/// One recovery draft for T-001 of the default synthetic catalog.
///
/// The identity uses the injected test data root, so the draft belongs to the
/// store this window reads and to no other.
ViewerRecoveryDraft savedDraftForFirstTask({
  int baseVersion = 1,
  Map<String, Object?>? baseFields,
  Map<String, Object?>? draftFields,
}) => ViewerRecoveryDraft(
  dataRoot: testDataRoot,
  projectId: firstProjectId,
  taskId: 'T-001',
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
  updatedMs: 1700000000000,
);

/// One in-memory recovery index that already holds [draft].
MemoryDraftSink sinkHoldingDraft(ViewerRecoveryDraft draft) =>
    MemoryDraftSink()..drafts[draft.draftId] = draft;

/// A draft sink whose writes wait for [gate].
///
/// Holding the write back lets the list settle the focus move before the
/// guard's question appears, which is the ordering a real draft file on disk
/// produces on Windows.
class GatedDraftSink extends MemoryDraftSink {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> save(ViewerRecoveryDraft draft) async {
    if (!gate.isCompleted) {
      await gate.future;
    }
    await super.save(draft);
  }
}

void main() {
  group('save', () {
    testWidgets('Save sends one update with the changed fields', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      expect(harness.model.editor.isDirty, isTrue);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(1));
      final ViewerUpdateRequest request = writer.lastRequest;
      expect(request.id, 1);
      expect(request.expectVersion, 1);
      expect(request.changes.title, 'Renamed task');
      expect(request.changes.body, isNull);
      expect(request.changes.status, isNull);
      expect(request.changes.labels, isNull);
      expect(writer.projectIds.single, firstProjectId);

      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'Saved T-001, version 2');
      expect(harness.focusedDebugLabel, 'details edit');
    });

    testWidgets('a store no-op reports no changes and closes the form', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()..nextEventId = null;
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Body (F3 or Alt+B)'), 'changed body');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(1));
      expect(harness.statusText, 'No changes needed');
      expect(harness.model.editor.isEditing, isFalse);
    });

    testWidgets('a clean form disables Save and sends nothing', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter();
      await openFirstTask(tester, update: writer);
      await pressKey(tester, LogicalKeyboardKey.f4);

      final FilledButton save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save (Ctrl+S)'),
      );
      expect(save.onPressed, isNull);

      await pressControl(tester, LogicalKeyboardKey.keyS);
      expect(writer.requests, isEmpty);
    });

    testWidgets('an invalid field is focused and never written', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), '');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, isEmpty);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.focusedDebugLabel, 'editor title');
      expect(harness.liveText, contains('title'));
    });
  });

  group('markDone', () {
    testWidgets('Ctrl+D marks a clean task done with one update', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      final writer = FakeTaskWriter()..nextStatus = 'done';
      final harness = await openFirstTask(tester, reads: reads, update: writer);

      // The commit lands in the store, so the read that follows the write
      // already reports the done record.
      reads.details[1] = testTaskDetail(
        1,
        title: 'First task',
        status: 'done',
        version: 2,
      );
      await pressControl(tester, LogicalKeyboardKey.keyD);

      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.expectVersion, 1);
      expect(writer.lastRequest.changes.status, 'done');
      expect(writer.lastRequest.changes.title, isNull);
      expect(harness.statusText, 'T-001 is done, version 2');

      await pressControl(tester, LogicalKeyboardKey.keyD);

      expect(writer.requests, hasLength(1));
      expect(harness.statusText, 'T-001 is already done.');
    });

    testWidgets('Ctrl+D on a dirty draft marks done only after the dialog', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()..nextStatus = 'done';
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyD);

      expect(find.text('Mark task done with unsaved changes?'), findsOneWidget);
      expect(writer.requests, isEmpty);
      expect(harness.statusText, 'Editing T-001, base version 1.');

      await pressAlt(tester, LogicalKeyboardKey.keyS);

      expect(find.text('Mark task done with unsaved changes?'), findsNothing);
      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.changes.title, 'Renamed task');
      expect(writer.lastRequest.changes.status, 'done');
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'T-001 is done, version 2');
    });

    testWidgets('Discard changes and mark done sends the status alone', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()..nextStatus = 'done';
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyD);
      await pressAlt(tester, LogicalKeyboardKey.keyD);

      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.changes.status, 'done');
      expect(writer.lastRequest.changes.title, isNull);
      expect(harness.statusText, 'T-001 is done, version 2');
      expect(harness.model.editor.isEditing, isFalse);
    });

    testWidgets('Cancel keeps the draft and writes nothing', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyD);
      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(find.text('Mark task done with unsaved changes?'), findsNothing);
      expect(writer.requests, isEmpty);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
    });

    testWidgets('a cancelled task can still be marked done', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{1: testTaskDetail(1, status: 'cancelled')},
      );
      final writer = FakeTaskWriter()..nextStatus = 'done';
      final harness = await openFirstTask(tester, reads: reads, update: writer);

      await pressControl(tester, LogicalKeyboardKey.keyD);

      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.changes.status, 'done');
      expect(harness.statusText, 'T-001 is done, version 2');
    });

    group('refused by the completion guard', () {
      const refusal = ViewerCliErrorFailure(
        code: 'validation',
        message:
            'validation: update T-001: cannot mark done while prerequisites '
            'are not done or cancelled: T-009 (to-verify); complete or cancel '
            'them first, in dependency order (project '
            '00000000-0000-4000-8000-000000000001)',
        exitCode: 2,
        openPrerequisites: <ViewerOpenPrerequisite>[
          ViewerOpenPrerequisite(id: 9, status: 'to-verify'),
        ],
      );
      const expected =
          'T-001 was not marked done. Finish or cancel T-009 (To verify) '
          'first.';

      /// Focuses the header's Mark done button and activates it by keyboard.
      Future<void> activateMarkDone(WidgetTester tester) async {
        final button = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text('Mark done'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        button.focusNode!.requestFocus();
        await tester.pumpAndSettle();
        await pressKey(tester, LogicalKeyboardKey.enter);
      }

      testWidgets('Mark done speaks viewer text and keeps focus', (
        WidgetTester tester,
      ) async {
        final reads = fakeWorkspaceReads();
        final writer = FakeTaskWriter()..failure = refusal;
        final harness = await openFirstTask(
          tester,
          reads: reads,
          update: writer,
        );

        await activateMarkDone(tester);

        expect(writer.requests, hasLength(1));
        expect(writer.lastRequest.changes.status, 'done');
        expect(harness.statusText, expected);
        expect(harness.statusText, isNot(contains('project')));
        expect(harness.statusText, isNot(contains('to-verify')));
        expect(harness.model.detail!.detail!.version, 1);
        expect(harness.model.detail!.detail!.status, 'todo');
        expect(harness.focusedDebugLabel, 'details mark done');
      });

      testWidgets(
        'Save and mark done keeps the draft, editor and field focus',
        (WidgetTester tester) async {
          final writer = FakeTaskWriter()..failure = refusal;
          final harness = await openFirstTask(tester, update: writer);

          await pressKey(tester, LogicalKeyboardKey.f4);
          await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
          await tester.pumpAndSettle();
          // The edit form replaces the header buttons, so Ctrl+D is the path.
          expect(harness.focusedDebugLabel, 'editor title');
          await pressControl(tester, LogicalKeyboardKey.keyD);
          expect(
            find.text('Mark task done with unsaved changes?'),
            findsOneWidget,
          );
          await pressAlt(tester, LogicalKeyboardKey.keyS);

          expect(writer.requests, hasLength(1));
          expect(writer.lastRequest.changes.title, 'Renamed task');
          expect(writer.lastRequest.changes.status, 'done');
          expect(harness.statusText, expected);
          expect(harness.model.editor.isEditing, isTrue);
          expect(harness.model.editor.isDirty, isTrue);
          expect(harness.model.editor.draft?.title, 'Renamed task');
          expect(harness.model.editor.base?.version, 1);
          expect(harness.focusedDebugLabel, 'editor title');
        },
      );
    });

    testWidgets('a failed mark done keeps the draft and the editor', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()
        ..persistentFailure = const ViewerCliErrorFailure(
          code: 'io_error',
          message: 'the task store is locked',
          exitCode: 3,
        );
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      await pressControl(tester, LogicalKeyboardKey.keyD);
      await pressAlt(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(1));
      expect(harness.statusText, 'the task store is locked');
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
    });
  });

  group('conflict', () {
    /// Opens the editor with one changed Title and makes the writer answer the
    /// save with a version conflict, while the store record moves to version 2
    /// with a different title.
    Future<(RealViewerHarness, FakeTaskWriter)> openConflictingDraft(
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      final writer = FakeTaskWriter()
        ..failure = const ViewerCliErrorFailure(
          code: 'version_conflict',
          message: 'expected version 1 but the task is at version 2',
          exitCode: 4,
        );
      final harness = await openFirstTask(tester, reads: reads, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      // Another writer committed version 2 while this draft was open.
      reads.details[1] = testTaskDetail(1, title: 'Store title', version: 2);
      return (harness, writer);
    }

    testWidgets('a version conflict shows the base, mine and current values', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openConflictingDraft(tester);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(find.text('Version conflict'), findsOneWidget);
      expect(
        find.text('T-001 was based on version 1 and is now at version 2.'),
        findsOneWidget,
      );
      expect(find.text('Changed fields: Title.'), findsOneWidget);
      expect(find.text('Base: First task'), findsOneWidget);
      expect(find.text('Mine: Renamed task'), findsOneWidget);
      expect(find.text('Current: Store title'), findsOneWidget);
      expect(find.text('Review against current (Alt+V)'), findsOneWidget);
      expect(
        find.text('Reload current and discard draft (Alt+R)'),
        findsOneWidget,
      );
      expect(find.text('Return to editor (Alt+E)'), findsOneWidget);
      expect(writer.requests, hasLength(1));
      expect(harness.model.editor.conflict, isNotNull);

      await pressAlt(tester, LogicalKeyboardKey.keyE);
    });

    testWidgets('Return to editor keeps the draft and blocks the next save', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openConflictingDraft(tester);
      await pressControl(tester, LogicalKeyboardKey.keyS);

      await pressAlt(tester, LogicalKeyboardKey.keyE);

      expect(find.text('Version conflict'), findsNothing);
      expect(
        harness.statusText,
        'T-001 changed in the store. Resolve the conflict before saving; '
        'your draft is kept.',
      );
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      expect(harness.model.editor.conflict, isNotNull);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(
        writer.requests,
        hasLength(1),
        reason: 'an unresolved conflict must not resend the update',
      );
      expect(find.text('Version conflict'), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyE);
    });

    testWidgets('Reload current and discard draft adopts the store record', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openConflictingDraft(tester);
      await pressControl(tester, LogicalKeyboardKey.keyS);

      await pressAlt(tester, LogicalKeyboardKey.keyR);

      expect(
        harness.statusText,
        'Reloaded T-001 at version 2. Your draft was discarded.',
      );
      final editor = harness.model.editor;
      expect(editor.conflict, isNull);
      expect(editor.isEditing, isTrue);
      expect(editor.isDirty, isFalse);
      expect(editor.draft?.title, 'Store title');
      expect(writer.requests, hasLength(1));
    });

    testWidgets('Review against current rebases the draft and saves again', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openConflictingDraft(tester);
      await pressControl(tester, LogicalKeyboardKey.keyS);

      await pressAlt(tester, LogicalKeyboardKey.keyV);

      expect(find.text('Review against current'), findsOneWidget);
      expect(find.text('Conflicting field (Alt+F)'), findsOneWidget);
      expect(find.text('Title - undecided'), findsOneWidget);
      final FilledButton apply = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Apply choices (Alt+A)'),
      );
      expect(
        apply.onPressed,
        isNull,
        reason: 'Apply waits for every conflicting field',
      );

      await pressAlt(tester, LogicalKeyboardKey.keyI);

      expect(
        find.text('Every conflicting field has a choice.'),
        findsOneWidget,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyA);

      expect(
        harness.statusText,
        'Rebased your draft on version 2 of T-001. Save again to write it.',
      );
      final editor = harness.model.editor;
      expect(editor.conflict, isNull);
      expect(editor.isEditing, isTrue);
      expect(editor.draft?.title, 'Renamed task');
      expect(editor.base?.version, 2);
      expect(harness.focusedDebugLabel, 'editor title');

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(2));
      expect(writer.lastRequest.expectVersion, 2);
      expect(writer.lastRequest.changes.title, 'Renamed task');
      expect(harness.statusText, 'Saved T-001, version 2');
    });

    testWidgets('Cancel in the review keeps every value as it was', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openConflictingDraft(tester);
      await pressControl(tester, LogicalKeyboardKey.keyS);

      await pressAlt(tester, LogicalKeyboardKey.keyV);
      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(
        harness.statusText,
        'No choices applied. T-001 still conflicts with your draft.',
      );
      expect(harness.model.editor.conflict, isNotNull);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      expect(writer.requests, hasLength(1));
    });
  });

  group('lostAcknowledgement', () {
    /// A write whose answer never arrived, as a Windows firewall or a killed
    /// relay would leave it.
    const ViewerTimeoutFailure timeout = ViewerTimeoutFailure(
      Duration(seconds: 5),
    );

    testWidgets('a write that landed reconciles instead of resending', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      final writer = FakeTaskWriter()..failure = timeout;
      final harness = await openFirstTask(tester, reads: reads, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      // The update committed; only its acknowledgement was lost, so the fresh
      // read already holds the intended title at version 2.
      reads.details[1] = testTaskDetail(1, title: 'Renamed task', version: 2);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(
        writer.requests,
        hasLength(1),
        reason: 'reconciliation never resends the update',
      );
      expect(
        harness.statusText,
        'Current task matches your changes; the save acknowledgement was '
        'lost. T-001 is at version 2.',
      );
      expect(harness.model.editor.isAwaitingReconciliation, isFalse);
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.model.editor.base?.version, 2);
    });

    testWidgets('a write that never landed keeps the draft and retries', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()..failure = timeout;
      final harness = await openFirstTask(tester, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(
        harness.statusText,
        'The save did not reach the store. The draft is unchanged; Retry '
        'sends it again.',
      );
      final editor = harness.model.editor;
      expect(editor.isAwaitingReconciliation, isFalse);
      expect(editor.isEditing, isTrue);
      expect(editor.draft?.title, 'Renamed task');
      expect(editor.saveEnabled, isTrue);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(2));
      expect(writer.lastRequest.expectVersion, 1);
      expect(writer.lastRequest.changes.title, 'Renamed task');
      expect(harness.statusText, 'Saved T-001, version 2');
    });

    testWidgets('an unreadable task keeps Save disabled until Retry reads it', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      final writer = FakeTaskWriter()..persistentFailure = timeout;
      final harness = await openFirstTask(tester, reads: reads, update: writer);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      reads.detailFailure = const ViewerCliErrorFailure(
        code: 'io_error',
        message: 'the task store is locked',
        exitCode: 3,
      );

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(
        find.text(
          'The last save outcome is unknown until the task is read again. '
          'Save stays disabled.',
        ),
        findsOneWidget,
      );
      final FilledButton save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save (Ctrl+S)'),
      );
      expect(save.onPressed, isNull);
      expect(harness.model.editor.isAwaitingReconciliation, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      expect(harness.statusText, contains('The save outcome is unknown'));

      // The store answers again and the lost write turns out to have landed.
      reads.detailFailure = null;
      reads.details[1] = testTaskDetail(1, title: 'Renamed task', version: 2);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(
        harness.statusText,
        'Current task matches your changes; the save acknowledgement was '
        'lost. T-001 is at version 2.',
      );
      expect(harness.model.editor.isAwaitingReconciliation, isFalse);
      expect(harness.model.editor.isEditing, isFalse);
      expect(writer.requests, hasLength(1));
    });
  });

  group('draftRestore', () {
    testWidgets('a saved draft asks Restore or Discard with Restore first', (
      WidgetTester tester,
    ) async {
      final drafts = sinkHoldingDraft(savedDraftForFirstTask());
      final harness = await openFirstTask(tester, drafts: drafts);

      expect(
        viewerTestEnvironment().dataRoot,
        testDataRoot,
        reason: 'the draft identity must match the store this window reads',
      );

      expect(find.text('Restore draft'), findsOneWidget);
      expect(find.text('T-001  First task'), findsOneWidget);
      expect(find.text('Restore draft (Alt+R)'), findsOneWidget);
      expect(find.text('Discard (Alt+D)'), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyD);

      expect(find.text('Restore draft'), findsNothing);
      expect(harness.statusText, 'Discarded the saved draft for T-001.');
      expect(harness.model.editor.isEditing, isFalse);
      expect(drafts.deletes, 1);
      expect(drafts.drafts, isEmpty);
    });

    testWidgets('a keyed task still offers its T-N recovery draft', (
      WidgetTester tester,
    ) async {
      final drafts = sinkHoldingDraft(savedDraftForFirstTask());
      final catalog = <ProjectItem>[testProjectItem(1)];
      final reads = fakeWorkspaceReads(
        projects: catalog,
        tasks: <String, List<TaskItem>>{
          catalog.single.projectId: <TaskItem>[
            testTaskItem(1, title: 'First task', displayId: 'DAK-001'),
          ],
        },
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'First task', projectKey: 'DAK'),
        },
      );
      final harness = await openFirstTask(tester, reads: reads, drafts: drafts);

      expect(find.text('Restore draft'), findsOneWidget);
      expect(find.text('DAK-001  First task'), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyD);

      expect(harness.statusText, 'Discarded the saved draft for DAK-001.');
      expect(drafts.drafts, isEmpty);
    });

    testWidgets('a draft that cannot be read is removed with the reason', (
      WidgetTester tester,
    ) async {
      final drafts = sinkHoldingDraft(
        savedDraftForFirstTask(
          draftFields: const <String, Object?>{'title': 'Typed title'},
        ),
      );
      final harness = await openFirstTask(tester, drafts: drafts);

      expect(find.text('Restore draft'), findsNothing);
      expect(
        harness.statusText,
        startsWith(
          'The saved draft for T-001 could not be read and was removed: ',
        ),
      );
      expect(harness.statusText, contains('draft field "body"'));
      expect(drafts.deletes, 1);
      expect(drafts.drafts, isEmpty);
      expect(harness.model.editor.isEditing, isFalse);
    });

    testWidgets('Restore loads the typed draft and keeps it until the save', (
      WidgetTester tester,
    ) async {
      final drafts = sinkHoldingDraft(savedDraftForFirstTask());
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(
        tester,
        drafts: drafts,
        update: writer,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyR);

      expect(
        harness.statusText,
        'Restored the saved draft for T-001. Check the fields, then save.',
      );
      final editor = harness.model.editor;
      expect(editor.isEditing, isTrue);
      expect(editor.draft?.title, 'Typed title');
      expect(editor.isDirty, isTrue);
      expect(editor.conflict, isNull);
      expect(harness.focusedDebugLabel, 'editor title');
      expect(
        drafts.drafts,
        hasLength(1),
        reason: 'the disk draft survives a restore that was not saved',
      );

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.expectVersion, 1);
      expect(writer.lastRequest.changes.title, 'Typed title');
      expect(harness.statusText, 'Saved T-001, version 2');
      expect(drafts.drafts, isEmpty);
    });

    testWidgets('a restored draft against a newer record opens the conflict', (
      WidgetTester tester,
    ) async {
      final drafts = sinkHoldingDraft(savedDraftForFirstTask());
      final reads = fakeWorkspaceReads(
        details: <int, TaskDetail>{
          1: testTaskDetail(1, title: 'Store title', version: 2),
        },
      );
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(
        tester,
        reads: reads,
        drafts: drafts,
        update: writer,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyR);

      final editor = harness.model.editor;
      expect(editor.isEditing, isTrue);
      expect(editor.draft?.title, 'Typed title');
      expect(editor.conflict, isNotNull);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(find.text('Version conflict'), findsOneWidget);
      expect(find.text('Base: First task'), findsOneWidget);
      expect(find.text('Mine: Typed title'), findsOneWidget);
      expect(find.text('Current: Store title'), findsOneWidget);
      expect(
        writer.requests,
        isEmpty,
        reason: 'a restored conflict refuses to write until it is resolved',
      );
      expect(editor.draft?.title, 'Typed title');

      await pressAlt(tester, LogicalKeyboardKey.keyE);
    });
  });

  group('diskWriteFailure', () {
    testWidgets('a draft that cannot be persisted warns and offers a copy', (
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

      final drafts = MemoryDraftSink()
        ..saveFailure = const FileSystemException('disk full');
      final harness = await openFirstTask(tester, drafts: drafts);

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(drafts.saves, greaterThan(0));
      expect(
        harness.model.editor.persistenceWarning,
        'Your draft could not be saved for recovery: '
        "FileSystemException: disk full, path = ''. "
        'Copy it before closing the viewer.',
      );
      expect(
        find.textContaining('Copy it before closing the viewer.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Copy draft'));
      await tester.pumpAndSettle();

      expect(harness.statusText, 'Draft copied to the clipboard.');
      final MethodCall copy = platformCalls.firstWhere(
        (MethodCall call) => call.method == 'Clipboard.setData',
      );
      expect(
        (copy.arguments as Map<Object?, Object?>)['text'],
        <String>[
          'T-001 (base version 1)',
          'title: Renamed task',
          'status: todo',
          'priority: P2',
          'labels: ',
          'deps: ',
          'body: body text',
        ].join('\n'),
      );

      // A working disk clears the warning on the next autosave.
      drafts.saveFailure = null;
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed twice');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(harness.model.editor.persistenceWarning, isNull);
      expect(find.text('Copy draft'), findsNothing);
    });
  });

  group('leavingGuards', () {
    /// Opens the editor on T-001 and types one changed title.
    Future<(RealViewerHarness, FakeTaskWriter)> openDirtyEditor(
      WidgetTester tester, {
      FakeTaskWriter? writer,
    }) async {
      final target = writer ?? FakeTaskWriter();
      final harness = await openFirstTask(tester, update: target);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();
      return (harness, target);
    }

    testWidgets('a task switch asks first and Cancel keeps the open task', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openDirtyEditor(tester);

      final Future<bool> navigation = harness.model.selectTaskRow(1);
      await tester.pumpAndSettle();

      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.text('T-001  First task'), findsOneWidget);
      expect(
        find.text('Switch to another task and lose the changes to this one?'),
        findsOneWidget,
      );
      // The editor form's own Cancel sits behind the modal, so the dialog's
      // three answers are scoped to the dialog itself.
      final Finder dialog = find.byType(ViewerUnsavedChangesDialog);
      expect(dialog, findsOneWidget);
      for (final String label in <String>[
        'Save (Alt+S)',
        'Discard (Alt+D)',
        'Cancel (Alt+C)',
      ]) {
        expect(
          find.descendant(of: dialog, matching: find.text(label)),
          findsOneWidget,
          reason: '$label belongs to the guard dialog',
        );
      }
      expect(writer.requests, isEmpty);

      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(await navigation, isFalse);
      expect(harness.model.tasks?.selectedTaskId, 1);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      expect(harness.focusedDebugLabel, 'editor title');
    });

    testWidgets('Discard in the task guard drops the draft and moves on', (
      WidgetTester tester,
    ) async {
      final (harness, _) = await openDirtyEditor(tester);

      final Future<bool> navigation = harness.model.selectTaskRow(1);
      await tester.pumpAndSettle();
      await pressAlt(tester, LogicalKeyboardKey.keyD);

      expect(await navigation, isTrue);
      expect(harness.model.tasks?.selectedTaskId, 2);
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'Discarded the draft of T-001.');
    });

    testWidgets('Save in the task guard writes before it navigates', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openDirtyEditor(tester);

      final Future<bool> navigation = harness.model.selectTaskRow(1);
      await tester.pumpAndSettle();
      await pressAlt(tester, LogicalKeyboardKey.keyS);

      expect(await navigation, isTrue);
      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.expectVersion, 1);
      expect(writer.lastRequest.changes.title, 'Renamed task');
      expect(harness.model.tasks?.selectedTaskId, 2);
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'Saved T-001, version 2');
    });

    testWidgets('a save that fails cancels the leaving action', (
      WidgetTester tester,
    ) async {
      final writer = FakeTaskWriter()
        ..persistentFailure = const ViewerCliErrorFailure(
          code: 'io_error',
          message: 'the task store is locked',
          exitCode: 3,
        );
      final (harness, _) = await openDirtyEditor(tester, writer: writer);

      final Future<bool> navigation = harness.model.selectTaskRow(1);
      await tester.pumpAndSettle();
      await pressAlt(tester, LogicalKeyboardKey.keyS);

      expect(await navigation, isFalse);
      expect(harness.model.tasks?.selectedTaskId, 1);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      expect(harness.statusText, 'the task store is locked');
    });

    testWidgets('a project switch asks with its own question', (
      WidgetTester tester,
    ) async {
      final (harness, _) = await openDirtyEditor(tester);

      final Future<bool> navigation = harness.model.selectProjectRow(1);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Switch to another project and lose the changes to this task?',
        ),
        findsOneWidget,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(await navigation, isFalse);
      expect(harness.model.selectedProjectId, firstProjectId);
      expect(harness.model.editor.isEditing, isTrue);
    });

    testWidgets('a refused project move survives the modal returning focus', (
      WidgetTester tester,
    ) async {
      final sink = GatedDraftSink();
      final harness = await openFirstTask(tester, drafts: sink);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      // The list settles its focus move while the draft write is still in
      // flight, exactly as the live app does with a real draft file.
      await tester.pump(const Duration(milliseconds: 100));
      sink.gate.complete();
      await tester.pumpAndSettle();
      final question =
          'Switch to another project and lose the changes to this task?';
      expect(find.text(question), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();

      expect(
        find.text(question),
        findsNothing,
        reason: 'the dismissed guard must not reopen',
      );
      expect(harness.model.selectedProjectId, firstProjectId);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      final projects = harness.list(ViewerRegion.projects);
      expect(projects.selectedIndex, 0);
      expect(projects.focusedRowIndex, 0);
    });

    testWidgets('a refused task move survives the modal returning focus', (
      WidgetTester tester,
    ) async {
      final sink = GatedDraftSink();
      final harness = await openFirstTask(tester, drafts: sink);
      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      await tester.enterText(editorField('Title (Alt+T)'), 'Renamed task');
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));
      sink.gate.complete();
      await tester.pumpAndSettle();
      final question =
          'Switch to another task and lose the changes to this one?';
      expect(find.text(question), findsOneWidget);

      await pressAlt(tester, LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();

      expect(
        find.text(question),
        findsNothing,
        reason: 'the dismissed guard must not reopen',
      );
      expect(harness.model.tasks!.selectedTaskId, 1);
      expect(harness.model.editor.isEditing, isTrue);
      expect(harness.model.editor.draft?.title, 'Renamed task');
      final tasks = harness.list(ViewerRegion.tasks);
      expect(tasks.selectedIndex, 0);
      expect(tasks.focusedRowIndex, 0);
    });

    testWidgets('a window close asks before it drops the draft', (
      WidgetTester tester,
    ) async {
      final (harness, _) = await openDirtyEditor(tester);

      final Future<bool> closes = harness.model.closeWindow();
      await tester.pumpAndSettle();

      expect(
        find.text('Close the viewer and lose the changes to this task?'),
        findsOneWidget,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(await closes, isFalse);
      expect(harness.model.editor.isEditing, isTrue);

      final Future<bool> again = harness.model.closeWindow();
      await tester.pumpAndSettle();
      await pressAlt(tester, LogicalKeyboardKey.keyD);

      expect(await again, isTrue);
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'Discarded the draft of T-001.');
    });

    // The live defect only exists on a desktop target: EditableText selects the
    // whole value when a single-line field regains focus (selectAllOnFocus
    // defaults to true on Windows), and the test binding reports Android
    // unless the target is pinned.
    testWidgets(
      'Cancel of the close guard restores the caret it interrupted',
      variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows}),
      (WidgetTester tester) async {
        final (harness, _) = await openDirtyEditor(tester);
        final TextEditingController controller = tester
            .widget<TextField>(editorField('Title (Alt+T)'))
            .controller!;
        controller.selection = const TextSelection.collapsed(offset: 6);
        await tester.pump();

        final Future<bool> closes = harness.model.closeWindow();
        await tester.pumpAndSettle();
        expect(
          find.text('Close the viewer and lose the changes to this task?'),
          findsOneWidget,
        );

        await pressAlt(tester, LogicalKeyboardKey.keyC);

        expect(await closes, isFalse);
        expect(harness.focusedDebugLabel, 'editor title');
        expect(controller.text, 'Renamed task');
        expect(
          controller.selection,
          const TextSelection.collapsed(offset: 6),
          reason: 'Cancel must restore the caret the guard interrupted',
        );
      },
    );

    testWidgets(
      'Cancel of the form guard keeps the caret it interrupted',
      variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows}),
      (WidgetTester tester) async {
        final (harness, writer) = await openDirtyEditor(tester);
        final TextEditingController controller = tester
            .widget<TextField>(editorField('Title (Alt+T)'))
            .controller!;
        controller.selection = const TextSelection.collapsed(offset: 4);
        await tester.pump();

        await pressAlt(tester, LogicalKeyboardKey.keyC);
        await tester.pumpAndSettle();
        expect(
          find.text('Leave the editor and lose your changes?'),
          findsOneWidget,
        );

        await pressAlt(tester, LogicalKeyboardKey.keyC);
        await tester.pumpAndSettle();

        expect(harness.model.editor.isEditing, isTrue);
        expect(harness.focusedDebugLabel, 'editor title');
        expect(controller.selection, const TextSelection.collapsed(offset: 4));
        expect(writer.requests, isEmpty);
      },
    );

    testWidgets('a store change asks, and Save lets the change continue', (
      WidgetTester tester,
    ) async {
      final (harness, writer) = await openDirtyEditor(tester);

      final Future<bool> change = harness.model.requestStoreChange(
        r'C:\other\data',
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Change the task store and lose the changes to this task?'),
        findsOneWidget,
      );

      await pressAlt(tester, LogicalKeyboardKey.keyS);

      expect(await change, isTrue);
      expect(writer.requests, hasLength(1));
      expect(harness.model.editor.isEditing, isFalse);
      expect(harness.statusText, 'Saved T-001, version 2');
    });
  });

  group('projectKey', () {
    /// T-001 depending on T-002 in a project whose key is [key].
    void keyedCatalog(FakeWorkspaceReads reads, String key) {
      reads
        ..projectKey = key
        ..tasks[reads.projects.single.projectId] = <TaskItem>[
          testTaskItem(1, title: 'First task', displayId: '$key-001'),
          testTaskItem(2, title: 'Second task', displayId: '$key-002'),
        ]
        ..details[1] = testTaskDetail(
          1,
          title: 'First task',
          projectKey: key,
          deps: const <int>[2],
          dependencySummaries: <DependencySummary>[
            DependencySummary(
              id: 2,
              displayId: '$key-002',
              title: 'Second task',
              status: 'todo',
              version: 1,
            ),
          ],
        );
    }

    testWidgets('project key change refreshes the editor', (
      WidgetTester tester,
    ) async {
      final catalog = <ProjectItem>[testProjectItem(1)];
      final reads = fakeWorkspaceReads(projects: catalog);
      keyedCatalog(reads, 'OLD');
      final writer = FakeTaskWriter();
      final harness = await openFirstTask(tester, reads: reads, update: writer);
      final editor = harness.model.editor;

      await pressKey(tester, LogicalKeyboardKey.f4);
      await tester.enterText(editorField('Title (Alt+T)'), 'Typed title');
      await tester.pumpAndSettle();
      final draft = editor.draft;
      expect(draft?.depsText, 'OLD-002');
      expect(find.textContaining('Editing OLD-001  '), findsWidgets);

      // `tasks project-key --set NEW` from a terminal, then F5.
      keyedCatalog(reads, 'NEW');
      await harness.model.refresh();
      await tester.pumpAndSettle();

      expect(editor.isEditing, isTrue);
      expect(editor.canonicalTaskId, 'NEW-001');
      expect(editor.projectKey, 'NEW');
      expect(find.textContaining('Editing NEW-001  '), findsWidgets);
      expect(find.textContaining('Editing OLD-001  '), findsNothing);
      expect(
        find.textContaining('NEW-7, T-7 or 7'),
        findsWidgets,
        reason: 'the dependency field names the accepted forms in the new key',
      );
      expect(harness.model.detail!.canonicalTaskId, 'NEW-001');
      expect(
        harness.model.detail!.dependencies.single.canonicalId,
        'NEW-002',
        reason: 'the details pane shows dependency IDs in the new key',
      );

      // The dirty draft is kept exactly as typed, and its old-key entry still
      // names this project: no validation error and no dependency change.
      expect(editor.draft, draft);
      expect(editor.isDirty, isTrue);
      editor.validateField(EditorField.deps);
      expect(editor.errors, isEmpty);
      expect(editor.changes.deps, isNull);

      await pressControl(tester, LogicalKeyboardKey.keyS);

      expect(writer.requests, hasLength(1));
      expect(writer.lastRequest.changes.title, 'Typed title');
      expect(writer.lastRequest.changes.deps, isNull);
      expect(harness.statusText, 'Saved NEW-001, version 2');

      // The next draft starts from text in the new key.
      await pressKey(tester, LogicalKeyboardKey.f4);
      expect(editor.draft?.depsText, 'NEW-002');
    });
  });
}
