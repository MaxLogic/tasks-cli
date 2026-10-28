import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/keyboard_help_dialog.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';
import '../data/cli_client_test.dart' as transport;
import '../support/viewer_test_support.dart' as support;
import 'attachment_contract_test.dart' as att;

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('attachment-modal-contract-');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 32) {
        rethrow;
      }
      // ignore: avoid_print
      print('DEFERRED_FIXTURE_CLEANUP ${root.path}');
    }
  });

  // Class-level contract: every attachment modal must preserve its route and
  // focus when nested Help opens, and isolate unrelated registered commands.
  for (final kind in [
    'attach',
    'paste',
    'detach',
    'text',
    'image',
    'binary',
    'conflict',
  ]) {
    testWidgets('attachment modal keyboard class contract: $kind', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final announcements = AnnouncementController(
        clipPlayer: support.RecordingClipPlayer(),
      );
      addTearDown(announcements.dispose);
      var backgroundActions = 0;
      var modalActions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerShell(
            environment: transport.viewerEnvironmentForTest(
              dataRoot: '${root.path}/data',
              settingsRoot: '${root.path}/settings',
            ),
            announcements: announcements,
            workspaceBuilder: buildPrototypeWorkspace,
            actions: ViewerShellActions(
              onRefresh: () => backgroundActions++,
              onEditTask: () => backgroundActions++,
              onSave: () => backgroundActions++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shell = tester.state<ViewerShellState>(find.byType(ViewerShell));
      final file = File('${root.path}/preview');
      if (kind == 'image') {
        file.writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
          ),
        );
      } else {
        file.writeAsStringSync('line one\nline two\n');
      }
      final preview = ['text', 'image', 'binary'].contains(kind);
      final Widget modal;
      final CommandScope scope;
      if (preview) {
        scope = CommandScope.attachmentPreview;
        modal = AttachmentPreviewDialog(
          item: AttachmentSummary.fromJson({
            ...att.metadata,
            'kind': kind,
            'media_type': kind == 'image' ? 'image/png' : 'text/plain',
            'original_size': file.lengthSync(),
          }),
          path: file.path,
          announce: announcements.announceStatus,
          onSaveAs: () async {
            modalActions++;
          },
        );
      } else if (kind == 'conflict') {
        scope = CommandScope.conflict;
        modal = AttachmentOnlyConflictDialog(
          conflict: EditorConflict(
            baseVersion: 7,
            baseFields: TaskEditFields.fromDetail(att.task()),
            draftFields: TaskEditFields.fromDetail(att.task()),
            current: att.task(),
            changedFields: const [],
            conflictFields: const [],
          ),
        );
      } else {
        final detach = kind == 'detach';
        scope = detach
            ? CommandScope.attachmentDetach
            : CommandScope.attachmentAttach;
        modal = AttachmentConfirmationDialog(
          title: '$kind confirmation',
          content: 'Synthetic files',
          accept: detach ? 'Detach (Alt+D)' : 'Attach (Alt+A)',
          cancelDefault: detach,
        );
      }
      var completed = false;
      final closing = shell.showModal<Object?>(scope, (_) => modal).then((_) {
        completed = true;
      });
      await tester.pumpAndSettle();
      if (preview) {
        await att.settleFileIo(tester);
      }
      final focus = FocusManager.instance.primaryFocus!;
      expect(
        focus.context!.findAncestorWidgetOfExactType<AttachmentDialogFrame>(),
        isNotNull,
      );
      await support.pressKey(tester, LogicalKeyboardKey.f10);
      expect(find.byType(KeyboardHelpDialog), findsOneWidget);
      expect(completed, isFalse, reason: '$kind must stay open under Help');
      expect(shell.hasOpenModal, isTrue);
      await support.pressKey(tester, LogicalKeyboardKey.escape);
      expect(find.byType(KeyboardHelpDialog), findsNothing);
      expect(completed, isFalse);
      expect(
        FocusManager.instance.primaryFocus,
        same(focus),
        reason: '$kind restores its focused control',
      );
      expect(
        focus.context!.findAncestorWidgetOfExactType<AttachmentDialogFrame>(),
        isNotNull,
      );
      await support.pressKey(tester, LogicalKeyboardKey.f5);
      await support.pressKey(tester, LogicalKeyboardKey.f4);
      await support.pressControl(tester, LogicalKeyboardKey.keyS);
      Actions.invoke(
        FocusManager.instance.primaryFocus!.context!,
        const CommandIntent('global.editTask'),
      );
      await tester.pumpAndSettle();
      expect(backgroundActions, 0);
      expect(modalActions, 0);
      expect(completed, isFalse, reason: '$kind ignores unrelated commands');
      expect(FocusManager.instance.primaryFocus, same(focus));
      await support.pressKey(tester, LogicalKeyboardKey.escape);
      await closing;
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  }

  testWidgets(
    'Head Tail loads start caret at zero and first Down reaches line two',
    (tester) async {
      const size = 3 * 1024 * 1024;
      const line = 'A short line for document reading.\n';
      final file = File('${root.path}/large.txt')
        ..writeAsStringSync(
          (line * (size ~/ line.length + 1)).substring(0, size),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentPreviewDialog(
            item: AttachmentSummary.fromJson({
              ...att.metadata,
              'original_size': size,
            }),
            path: file.path,
            announce: (_) {},
            onSaveAs: () async {},
          ),
        ),
      );
      for (final window in ['initial Head', 'Tail', 'Head']) {
        if (window != 'initial Head') {
          await support.pressAlt(
            tester,
            window == 'Tail'
                ? LogicalKeyboardKey.keyT
                : LogicalKeyboardKey.keyH,
          );
        }
        await att.settleFileIo(tester);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.focusNode!.hasFocus, isTrue);
        // Do not preset selection: this must prove the actual file-load behavior.
        expect(
          field.controller!.selection,
          const TextSelection.collapsed(offset: 0),
          reason: window,
        );
        await tester.sendKeyEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'windows',
        );
        await tester.pump();
        expect(
          field.controller!.selection.baseOffset,
          field.controller!.text.indexOf('\n') + 1,
          reason: window,
        );
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(TextField),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          scroll.position.pixels,
          lessThan(200),
          reason: '$window must not jump to the end',
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'preview notes form a semantic container separate from dialog title',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final file = File('${root.path}/split.txt')
        ..writeAsStringSync('x' * (3 * 1024 * 1024));
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentPreviewDialog(
            item: AttachmentSummary.fromJson(att.metadata),
            path: file.path,
            announce: (_) {},
            onSaveAs: () async {},
          ),
        ),
      );
      final notes = find.byKey(const ValueKey('attachment-preview-notes'));
      for (var i = 0; i < 30 && notes.evaluate().isEmpty; i++) {
        await att.settleFileIo(tester);
      }
      expect(tester.widget<Semantics>(notes).container, isTrue);
      final data = tester.getSemantics(notes).getSemanticsData();
      expect(data.label, contains('Showing first 1 MiB; preview truncated.'));
      expect(data.label, contains(attachmentLongLineNotice));
      expect(data.label, isNot(contains('run.log')));
      expect(data.flagsCollection.namesRoute, isFalse);
      semantics.dispose();
    },
  );
  test(
    'attachment Help rows describe behavior without duplicating shortcut text',
    () {
      for (final scope in [
        CommandScope.attachmentAttach,
        CommandScope.attachmentDetach,
        CommandScope.attachmentPreview,
      ]) {
        final spec = commandSpecById('${scope.name}.help')!;
        final entry = HelpEntry(
          group: spec.group,
          spec: spec,
          activeHere: true,
        );
        expect(spec.description, isNot(spec.shortcutLabel));
        expect(spec.shortcutLabel.allMatches(entry.semanticsLabel).length, 1);
      }
    },
  );
}
