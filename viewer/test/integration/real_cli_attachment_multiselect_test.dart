import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';

import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachment_keyboard_test.dart' as keyboard;
import 'real_cli_attachments_test.dart' as real;

void main() {
  testWidgets(
    'real batch detach uses one write and refresh and retains the skip preference',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.start))!;
      h.dialogs.files = [
        for (var i = 0; i < 4; i++)
          (File(
            '${h.root.path}/file-$i.log',
          )..writeAsStringSync('File $i')).path,
      ];
      await tester.runAsync(h.controller.addFiles);
      ViewerSettingsDraft? saved;
      await keyboard.mount(
        tester,
        h,
        onSettingsChanged: (value) => saved = value,
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      final panel = tester.state<AttachmentPanelState>(
        find.byType(AttachmentPanel),
      );
      panel.list.goToIndex(1);
      panel.focusList();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(panel.list.selectedIndices, {1, 2, 3});
      final ids = panel.c.task.attachments
          .skip(1)
          .map((item) => item.displayId)
          .toList();
      // Real subprocess futures must start outside the widget fake-async zone,
      // just like the other real-CLI keyboard tests.
      await tester.runAsync(
        () => tester.sendKeyEvent(LogicalKeyboardKey.delete),
      );
      await tester.pumpAndSettle();
      expect(find.text('Detach 3 attachments?'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(CheckboxListTile, "Don't show this again (Alt+G)"),
      );
      final before = h.launcher.calls.length;
      await tester.runAsync(() => tester.tap(find.text('Detach (Alt+D)')));
      await tester.pumpAndSettle();
      await real.waitFor(
        tester,
        () => !panel.c.busy && panel.c.task.attachments.length == 1,
      );
      final calls = h.launcher.calls.skip(before).toList();
      final writes = calls.where((args) => args.contains('detach')).toList();
      expect(writes, hasLength(1));
      final args = writes.single;
      expect(args.sublist(args.indexOf('attachment')), [
        'attachment',
        'detach',
        '${h.id}',
        ...ids,
        '--expect-version',
        '2',
      ]);
      expect(calls.where((args) => args.contains('show')), hasLength(1));
      expect(panel.list.focusedRowIndex, 0);
      expect(
        saved!.confirmationEnabled(ViewerConfirmation.attachmentDetach),
        isFalse,
      );
      await tester.runAsync(
        () => tester.sendKeyEvent(LogicalKeyboardKey.delete),
      );
      await real.waitFor(
        tester,
        () => !panel.c.busy && panel.c.task.attachments.isEmpty,
      );
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      final detail = (await tester.runAsync(
        () => h.client.fetchTaskDetail(h.project, h.id),
      ))!;
      expect(
        detail.version,
        4,
        reason:
            'One version increment per batch, then the skipped-confirmation detach',
      );
      expect(detail.attachments, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
    skip: real.cli.isEmpty,
  );
}
