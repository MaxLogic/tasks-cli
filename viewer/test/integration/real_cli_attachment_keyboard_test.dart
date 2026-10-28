import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/settings_dialog.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as real;

void main() {
  for (final location in [
    'tasks',
    'body',
    'dependencies',
    'history',
    'rules',
    'attachments',
  ]) {
    testWidgets('real clipboard Ctrl+V from $location and Delete detaches', (
      tester,
    ) async {
      if (!real.available(real.clipboardCli)) return;
      final h = (await tester.runAsync(
        () => real.Harness.start(clipboard: true),
      ))!;
      final source = File('${h.root.path}/paste.png')
        ..writeAsBytesSync(base64Decode(real.png));
      File(
        '${h.clipboardFixture!.path}/files.json',
      ).writeAsStringSync(jsonEncode([source.path]));
      final announcements = await mount(tester, h);
      if (location == 'tasks') {
        await support.pressKey(tester, LogicalKeyboardKey.f2);
      } else {
        await support.pressKey(tester, LogicalKeyboardKey.f3);
        if (location != 'body') {
          await support.pressAlt(
            tester,
            {
              'dependencies': LogicalKeyboardKey.digit2,
              'history': LogicalKeyboardKey.digit3,
              'rules': LogicalKeyboardKey.digit4,
              'attachments': LogicalKeyboardKey.digit5,
            }[location]!,
          );
        }
      }
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(
        tester,
        () => find.byType(AttachmentConfirmationDialog).evaluate().isNotEmpty,
      );
      expect(find.text('Attach to ATT-001?'), findsOneWidget);
      await tester.tap(find.text('Attach (Alt+A)'));
      await tester.pumpAndSettle();
      await real.waitFor(
        tester,
        () => announcements.liveRegionText == 'Attached 1 file to ATT-001',
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      await support.pressAlt(tester, LogicalKeyboardKey.keyA);
      await tester.runAsync(
        () => support.pressKey(tester, LogicalKeyboardKey.delete),
      );
      await real.waitFor(
        tester,
        () => find.byType(AttachmentConfirmationDialog).evaluate().isNotEmpty,
      );
      expect(find.text('Detach paste.png from ATT-001?'), findsOneWidget);
      await tester.tap(find.text('Detach (Alt+D)'));
      await tester.pumpAndSettle();
      await real.waitFor(
        tester,
        () => announcements.liveRegionText == 'Detached paste.png',
      );
      final detail = await tester.runAsync(
        () => h.client.fetchTaskDetail(h.project, h.id),
      );
      expect(detail!.attachments, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'image paste never escapes an editor text field or an open dialog',
    (tester) async {
      if (!real.available(real.clipboardCli)) return;
      final h = (await tester.runAsync(
        () => real.Harness.start(clipboard: true),
      ))!;
      final source = File('${h.root.path}/paste.log')
        ..writeAsStringSync('clipboard fixture');
      File(
        '${h.clipboardFixture!.path}/files.json',
      ).writeAsStringSync(jsonEncode([source.path]));
      h.dialogs.files = [source.path];
      await tester.runAsync(h.controller.addFiles);
      await mount(tester, h);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'Pasted text'};
          }
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressControl(tester, LogicalKeyboardKey.keyH);
      await support.pressControl(tester, LogicalKeyboardKey.keyV);
      expect(
        tester
            .widget<TextField>(
              support.textFieldWithLabel('Find in body (Ctrl+H)'),
            )
            .controller!
            .text,
        'Pasted text',
      );
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      await support.pressKey(tester, LogicalKeyboardKey.f4);
      final title = support.textFieldWithLabel('Title (Alt+T)');
      await tester.tap(title);
      await support.pressControl(tester, LogicalKeyboardKey.keyV);
      expect(
        tester.widget<TextField>(title).controller!.text,
        contains('Pasted text'),
      );
      await tester.enterText(title, 'Delete this');
      tester.widget<TextField>(title).controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 7);
      await support.pressKey(tester, LogicalKeyboardKey.delete);
      expect(tester.widget<TextField>(title).controller!.text, 'this');
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      await tester.runAsync(model.editor.discardDraft);
      await tester.pumpAndSettle();
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      await support.pressAlt(tester, LogicalKeyboardKey.keyA);
      final panel = tester.state<AttachmentPanelState>(
        find.byType(AttachmentPanel),
      );
      expect(panel.item?.name, 'paste.log');
      final shell = tester.state<ViewerShellState>(find.byType(ViewerShell));
      unawaited(shell.openSettings());
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      await tester.runAsync(() => h.launcher.idle);
      final callsBefore = h.launcher.calls.length;
      await tester.runAsync(() async {
        await support.pressControl(tester, LogicalKeyboardKey.keyV);
        await support.pressKey(tester, LogicalKeyboardKey.delete);
        await h.launcher.idle;
      });
      await tester.pumpAndSettle();
      expect(
        h.launcher.calls.length,
        callsBefore,
        reason: 'Modal keys must not start any background attachment CLI call',
      );
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      final detail = await tester.runAsync(
        () => h.client.fetchTaskDetail(h.project, h.id),
      );
      expect(detail!.attachments.single.name, 'paste.log');
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('keyboard help describes paste from all task tabs and Delete', () {
    expect(commandSpecById('attachment.help')!.description, contains('Delete'));
    expect(
      commandSpecById('attachment.help')!.description,
      contains('task list'),
    );
  });
}

Future<AnnouncementController> mount(
  WidgetTester tester,
  real.Harness h, {
  ViewerSettingsDraft? initialSettings,
  ValueChanged<ViewerSettingsDraft>? onSettingsChanged,
  String? clipboardText,
}) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final announcements = AnnouncementController(
    clipPlayer: support.RecordingClipPlayer(),
  );
  addTearDown(announcements.dispose);
  await tester.runAsync(
    () => tester.pumpWidget(
      MaterialApp(
        home: ViewerWorkspaceHost(
          environment: h.environment,
          initialSettings: initialSettings,
          onSettingsChanged: onSettingsChanged,
          viewerClipboard: support.FakeViewerClipboard(text: clipboardText),
          attachmentDialogs: h.dialogs,
          readers: ViewerDataReader(
            projects: h.client,
            tasks: h.client,
            detail: h.client,
            update: h.client,
            probe: h.client.probe,
          ),
          announcements: announcements,
        ),
      ),
    ),
  );
  await real.waitFor(
    tester,
    () => find.byType(ViewerWorkspaceScope).evaluate().isNotEmpty,
  );
  final model = tester
      .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
      .model;
  await real.waitFor(
    tester,
    () => model.projectList.totalCount > 0 && !model.projectList.isLoading,
  );
  await tester.runAsync(() async {
    model.selectProjectIndex(0);
    await model.tasks!.refresh();
    await model.openTaskIndex(0);
  });
  await tester.pumpAndSettle();
  return announcements;
}
