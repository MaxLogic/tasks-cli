import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as real;
import 'real_cli_attachment_keyboard_test.dart' as keyboard;

void main() {
  test(
    'confirmation choices survive the settings wire format and reject wrong types',
    () {
      final decoded = decodeSettingsDocument(
        jsonEncode({
          'schema_version': 1,
          'confirmations': {
            'attachment_paste': false,
            'attachment_detach': false,
          },
        }),
      );
      expect(jsonDecode(encodeSettingsDocument(decoded))['confirmations'], {
        'attachment_paste': false,
        'attachment_detach': false,
      });
      expect(
        () => decodeSettingsDocument(
          jsonEncode({
            'schema_version': 1,
            'confirmations': {'attachment_paste': 'false'},
          }),
        ),
        throwsFormatException,
      );
      expect(
        jsonDecode(
          encodeSettingsDocument(
            decodeSettingsDocument('{"schema_version":1}'),
          ),
        )['confirmations'],
        {'attachment_paste': true, 'attachment_detach': true},
      );
    },
  );

  testWidgets(
    'confirmation checkbox persists skip across restart and Settings re-enables each choice',
    (tester) async {
      if (!real.available(real.clipboardCli)) return;
      final h = (await tester.runAsync(
        () => real.Harness.start(clipboard: true),
      ))!;
      final source = File('${h.root.path}/paste.log')
        ..writeAsStringSync('persisted confirmation fixture');
      File(
        '${h.clipboardFixture!.path}/files.json',
      ).writeAsStringSync(jsonEncode([source.path]));
      final store = SettingsStore(settingsRoot: h.environment.settingsRoot);
      ViewerSettingsDraft? savedDraft;
      var announcements = await keyboard.mount(
        tester,
        h,
        onSettingsChanged: (draft) {
          savedDraft = draft;
        },
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(
        tester,
        () => find.byType(AttachmentConfirmationDialog).evaluate().isNotEmpty,
      );
      final skip = find.widgetWithText(
        CheckboxListTile,
        "Don't show this again (Alt+G)",
      );
      expect(skip, findsOneWidget);
      await support.pressAlt(tester, LogicalKeyboardKey.keyG);
      expect(tester.widget<CheckboxListTile>(skip).value, isTrue);
      expect(
        Focus.of(
          tester.element(find.text("Don't show this again (Alt+G)")),
        ).hasFocus,
        isTrue,
      );
      await tester.tap(find.text('Cancel (Alt+C)'));
      await tester.pumpAndSettle();
      expect(
        savedDraft,
        isNull,
        reason: 'Cancel must not suppress a future confirmation',
      );
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(tester, () => skip.evaluate().isNotEmpty);
      await tester.tap(skip);
      await tester.tap(find.text('Attach (Alt+A)'));
      await tester.pumpAndSettle();
      await real.waitFor(
        tester,
        () =>
            announcements.liveRegionText ==
            'Attached 1 file to ATT-001. Re-enable this confirmation in Settings > Confirmations.',
      );
      await tester.runAsync(() => store.save(savedDraft!));
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      await support.pressAlt(tester, LogicalKeyboardKey.keyA);
      await tester.runAsync(
        () => support.pressKey(tester, LogicalKeyboardKey.delete),
      );
      await real.waitFor(tester, () => skip.evaluate().isNotEmpty);
      await tester.tap(skip);
      await tester.tap(find.text('Detach (Alt+D)'));
      await tester.pumpAndSettle();
      await real.waitFor(
        tester,
        () =>
            announcements.liveRegionText ==
            'Detached paste.log. Re-enable this confirmation in Settings > Confirmations.',
      );
      await tester.runAsync(() => store.save(savedDraft!));
      final loaded = (await tester.runAsync(store.load))!;
      await tester.pumpWidget(const SizedBox());
      announcements = await keyboard.mount(
        tester,
        h,
        initialSettings: loaded.draft,
        onSettingsChanged: (draft) {
          savedDraft = draft;
        },
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(
        tester,
        () => announcements.liveRegionText == 'Attached 1 file to ATT-001',
      );
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      await support.pressAlt(tester, LogicalKeyboardKey.keyA);
      await tester.runAsync(
        () => support.pressKey(tester, LogicalKeyboardKey.delete),
      );
      await real.waitFor(
        tester,
        () => announcements.liveRegionText == 'Detached paste.log',
      );
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      final shell = tester.state<ViewerShellState>(find.byType(ViewerShell));
      unawaited(shell.openSettings());
      await tester.pumpAndSettle();
      await support.pressAlt(tester, LogicalKeyboardKey.keyF);
      final pasteToggle = find.widgetWithText(
        CheckboxListTile,
        'Confirm clipboard attachment paste',
      );
      final detachToggle = find.widgetWithText(
        CheckboxListTile,
        'Confirm attachment detach',
      );
      expect(tester.widget<CheckboxListTile>(pasteToggle).value, isFalse);
      expect(tester.widget<CheckboxListTile>(detachToggle).value, isFalse);
      await support.pressKey(tester, LogicalKeyboardKey.space);
      await support.pressKey(tester, LogicalKeyboardKey.tab);
      await support.pressKey(tester, LogicalKeyboardKey.space);
      expect(tester.widget<CheckboxListTile>(pasteToggle).value, isTrue);
      expect(tester.widget<CheckboxListTile>(detachToggle).value, isTrue);
      await support.pressControl(tester, LogicalKeyboardKey.keyS);
      await tester.runAsync(() => store.save(savedDraft!));
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(tester, () => skip.evaluate().isNotEmpty);
      await tester.tap(find.text('Cancel (Alt+C)'));
      await tester.pumpAndSettle();
      final reloaded = (await tester.runAsync(store.load))!;
      expect(
        jsonDecode(encodeSettingsDocument(reloaded.draft))['confirmations'],
        {'attachment_paste': true, 'attachment_detach': true},
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
