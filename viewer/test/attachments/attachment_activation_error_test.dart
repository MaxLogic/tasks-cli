import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';

import 'attachment_contract_test.dart' as att;
import '../integration/real_cli_attachments_test.dart' as real;
import '../integration/real_cli_attachment_keyboard_test.dart' as keyboard;
import '../support/viewer_test_support.dart' as support;

void main() {
  for (final activation in ['double-click', 'Enter']) {
    testWidgets('$activation opens the attachment selected by the row', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync(
        'attachment-activation-',
      );
      addTearDown(() => removeFixture(root));
      final rig = att.Rig(root);
      addTearDown(rig.controller.dispose);
      await rig.probe();
      final file = File('${root.path}/preview.log')
        ..writeAsStringSync('Preview');
      rig.launcher.replyWith(
        att.envelope('attachment_get', {
          'id': 42,
          'items': [
            {'attachment': att.metadata, 'path': file.path, 'reused': false},
          ],
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<AttachmentPanelState>(
        find.byType(AttachmentPanel),
      );
      state.list.selectIndex(null);
      await tester.pump();
      final row = find.textContaining('run.log, text');
      final pointer = await tester.startGesture(
        tester.getCenter(row),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(state.list.selectedIndex, 0);
      expect(state.list.focusedRowIndex, 0);
      expect(state.list.hasListFocus, isTrue);
      await pointer.up();
      if (activation == 'double-click') {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(row, kind: PointerDeviceKind.mouse);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
      expect(state.item?.displayId, 'A12');
      expect(rig.announcements.last, 'Opened run.log');
      expect(
        rig.launcher.launches.where((call) => call.arguments.contains('get')),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  group(
    'immediate attachment selection with real CLI',
    () {
      testWidgets(
        'quick click on row B then Delete detaches B with confirmation disabled',
        (tester) async {
          final h = (await tester.runAsync(real.Harness.start))!;
          h.dialogs.files = [
            for (final name in ['first.log', 'second.log'])
              (File('${h.root.path}/$name')..writeAsStringSync(name)).path,
          ];
          await tester.runAsync(h.controller.addFiles);
          expect(h.detail.attachments, hasLength(2));
          await keyboard.mount(
            tester,
            h,
            initialSettings: const ViewerSettingsDraft(
              skippedConfirmations: {ViewerConfirmation.attachmentDetach},
            ),
          );
          await support.pressKey(tester, LogicalKeyboardKey.f3);
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);
          final state = tester.state<AttachmentPanelState>(
            find.byType(AttachmentPanel),
          );
          final first = h.detail.attachments.first.name;
          final second = h.detail.attachments.last.name;
          state.list.selectIndex(0);
          state.list.focusRegion();
          await tester.pumpAndSettle();
          await tester.tap(
            find.textContaining('$second, text'),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          // No double-tap timeout elapses before this destructive key.
          await tester.runAsync(() async {
            await tester.sendKeyEvent(LogicalKeyboardKey.delete);
            await h.launcher.idle;
          });
          await real.waitFor(tester, () => !state.c.busy);
          final detail = (await tester.runAsync(
            () => h.client.fetchTaskDetail(h.project, h.id),
          ))!;
          expect(detail.attachments.map((item) => item.name), [first]);
          expect(find.byType(AttachmentConfirmationDialog), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    },
    skip: real.cli.isEmpty
        ? 'Requires TASKS_VIEWER_TEST_CLI for real detach proof.'
        : false,
  );

  testWidgets('attachment CLI authentication error is readable and announced', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('attachment-error-');
    addTearDown(() => removeFixture(root));
    final rig = att.Rig(root);
    addTearDown(rig.controller.dispose);
    await rig.probe();
    rig.launcher.exit = 5;
    rig.launcher.stderrBytes = [
      utf8.encode(
        '{"error":{"code":"authentication","message":"Remote authentication failed."}}',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('View (Alt+W)'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Remote authentication failed.'),
      findsOneWidget,
    );
    expect(
      rig.controller.notice,
      'Remote authentication failed. Error code: authentication.',
    );
    expect(rig.controller.notice, isNot(contains('{')));
    expect(rig.announcements.last, rig.controller.notice);
    expect(rig.controller.busy, isFalse);
    expect(find.byType(AttachmentPreviewDialog), findsNothing);
  });
}

void removeFixture(Directory root) {
  try {
    root.deleteSync(recursive: true);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode != 32) rethrow;
    // The worker removes its explicit TEMP root after the test process exits.
    // ignore: avoid_print
    print('DEFERRED_FIXTURE_CLEANUP ${root.path}');
  }
}
