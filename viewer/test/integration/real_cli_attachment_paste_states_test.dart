import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as real;
import 'real_cli_attachment_keyboard_test.dart' as keyboard;

class StateClient extends ViewerCliClient {
  StateClient(ViewerEnvironment environment, ProcessLauncher launcher)
    : super(environment: environment, launcher: launcher);
  List<ViewerPendingReceipt> syntheticPending = [];
  bool attachmentsUnavailable = false;
  bool clipboardReadFails = false;
  @override
  ViewerInfo? get attachmentInfo =>
      attachmentsUnavailable ? null : super.attachmentInfo;
  @override
  Future<ViewerEnvelope> attachmentCommand(
    String projectId,
    List<String> command, {
    bool mutation = false,
    bool clipboard = false,
  }) {
    if (clipboard && clipboardReadFails) {
      throw const ViewerCliErrorFailure(
        code: 'interop',
        message: 'Clipboard fixture read failed',
        exitCode: 5,
      );
    }
    return super.attachmentCommand(
      projectId,
      command,
      mutation: mutation,
      clipboard: clipboard,
    );
  }

  @override
  List<ViewerPendingReceipt> get pendingReceipts => [
    ...super.pendingReceipts,
    ...syntheticPending,
  ];
}

void main() {
  for (final state in [
    'empty',
    'no selected task',
    'attachments unavailable',
  ]) {
    testWidgets('Tasks paste $state reports no search text once', (
      tester,
    ) async {
      if (!real.available(real.clipboardCli)) return;
      final h = (await tester.runAsync(
        () =>
            real.Harness.start(clipboard: true, clientFactory: StateClient.new),
      ))!;
      (h.client as StateClient).attachmentsUnavailable =
          state == 'attachments unavailable';
      final announcements = await keyboard.mount(tester, h);
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      if (state == 'no selected task') {
        await tester.runAsync(() async {
          model.tasks!.setQuery('No matching task fixture');
          await model.tasks!.submitQuery();
        });
        await real.waitFor(tester, () => model.tasks!.totalCount == 0);
        expect(model.detail!.detail, isNull);
      }
      await support.pressKey(tester, LogicalKeyboardKey.f2);
      final before = announcements.liveRegionRevision;
      final queryBefore = model.tasks!.query;
      final clipboard =
          model.clipboard.clipboard as support.FakeViewerClipboard;
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(tester, () => clipboard.reads == 1);
      expect(announcements.liveRegionRevision, before + 1);
      expect(
        announcements.liveRegionText,
        'The clipboard has no text to search for.',
      );
      expect(model.tasks!.query, queryBefore);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final failure in [false, true]) {
    testWidgets(
      'Tasks attachment ${failure ? 'read failure' : 'cancel'} fallback announces once',
      (tester) async {
        if (!real.available(real.clipboardCli)) return;
        final h = (await tester.runAsync(
          () => real.Harness.start(
            clipboard: true,
            clientFactory: StateClient.new,
          ),
        ))!;
        final source = File('${h.root.path}/paste.log')
          ..writeAsStringSync('fixture');
        File(
          '${h.clipboardFixture!.path}/files.json',
        ).writeAsStringSync(jsonEncode([source.path]));
        final announcements = await keyboard.mount(tester, h);
        final model = tester
            .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
            .model;
        final clipboard =
            model.clipboard.clipboard as support.FakeViewerClipboard;
        (h.client as StateClient).clipboardReadFails = failure;
        if (failure) {
          clipboard.failure = const ViewerCliErrorFailure(
            code: 'interop',
            message: 'Clipboard fixture read failed',
            exitCode: 5,
          );
        }
        await support.pressKey(tester, LogicalKeyboardKey.f2);
        var before = announcements.liveRegionRevision;
        await tester.runAsync(
          () => support.pressControl(tester, LogicalKeyboardKey.keyV),
        );
        if (!failure) {
          await real.waitFor(
            tester,
            () =>
                find.byType(AttachmentConfirmationDialog).evaluate().isNotEmpty,
          );
          before = announcements.liveRegionRevision;
          await support.pressKey(tester, LogicalKeyboardKey.escape);
        }
        await real.waitFor(tester, () => clipboard.reads == 1);
        expect(announcements.liveRegionRevision, before + 1);
        expect(
          announcements.liveRegionText,
          failure
              ? 'Clipboard fixture read failed'
              : 'Attachment paste cancelled',
        );
        expect(model.tasks!.query, isEmpty);
        expect(find.byType(AttachmentConfirmationDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final state in ['editing', 'busy', 'dialog', 'pending', 'stale']) {
    for (final text in [true, false]) {
      testWidgets(
        'Tasks paste $state with ${text ? 'text' : 'attachment'} never disappears',
        (tester) async {
          if (!real.available(real.clipboardCli)) return;
          final h = (await tester.runAsync(
            () => real.Harness.start(
              clipboard: true,
              clientFactory: StateClient.new,
            ),
          ))!;
          final source = File('${h.root.path}/paste.log')
            ..writeAsStringSync('fixture');
          File(
            '${h.clipboardFixture!.path}/files.json',
          ).writeAsStringSync(jsonEncode(text ? [] : [source.path]));
          h.dialogs.files = [source.path];
          await tester.runAsync(h.controller.addFiles);
          final announcements = await keyboard.mount(
            tester,
            h,
            clipboardText: text ? 'Real attachment' : null,
          );
          // Leave room for the existing Projects pending-recovery banner.
          tester.view.physicalSize = const Size(1920, 1080);
          await tester.pumpAndSettle();
          final model = tester
              .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
              .model;
          await support.pressKey(tester, LogicalKeyboardKey.f3);
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);
          final c = tester
              .widget<AttachmentPanel>(find.byType(AttachmentPanel))
              .controller;
          Future<void>? picker;
          if (state == 'editing') {
            await support.pressKey(tester, LogicalKeyboardKey.f4);
          } else if (state == 'busy') {
            c.busy = true;
          } else if (state == 'dialog') {
            h.dialogs.saveGate = Completer<String?>();
            picker = c.saveAs(c.task.attachments.single);
          } else if (state == 'pending') {
            (h.client as StateClient).syntheticPending = [
              ViewerPendingReceipt(
                'synthetic',
                h.project,
                'attachment_add',
                taskId: h.id,
              ),
            ];
          } else {
            await tester.runAsync(() => model.detail!.openTask(999));
            await tester.pumpAndSettle();
          }
          await support.pressKey(tester, LogicalKeyboardKey.f2);
          final before = announcements.liveRegionRevision;
          await tester.runAsync(
            () => support.pressControl(tester, LogicalKeyboardKey.keyV),
          );
          await tester.pumpAndSettle();
          if (text) {
            await real.waitFor(
              tester,
              () =>
                  model.tasks!.query == 'Real attachment' &&
                  !model.tasks!.isLoading,
            );
            await tester.runAsync(() => h.launcher.idle);
            expect(
              model.tasks!.query,
              'Real attachment',
              reason: '$state must fall through to search',
            );
          } else {
            expect(announcements.liveRegionRevision, greaterThan(before));
            expect(
              announcements.liveRegionText,
              contains(
                {
                  'editing': 'Save or cancel',
                  'busy': 'Changing attachments',
                  'dialog': 'dialog',
                  'pending': 'pending attachment',
                  'stale': 'selected task',
                }[state]!,
              ),
            );
          }
          expect(find.byType(AttachmentConfirmationDialog), findsNothing);
          if (picker != null) {
            h.dialogs.saveGate!.complete(null);
            await picker;
          }
          c.busy = false;
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
