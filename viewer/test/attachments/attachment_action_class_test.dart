import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/attachment_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/platform/file_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import '../data/cli_client_test.dart' as transport;
import '../support/viewer_test_support.dart' as support;
import 'attachment_contract_test.dart' as att;

class GateLauncher extends transport.ScriptedLauncher {
  Completer<void>? gate;
  int starts = 0;
  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    starts++;
    await gate?.future;
    return super.start(executable, arguments);
  }
}

class Picker implements AttachmentFileDialogs {
  @override
  Future<List<String>> openFiles() async => [r'C:\synthetic\file.bin'];
  @override
  Future<String?> saveAs(String suggestedName) async =>
      r'C:\synthetic\saved.bin';
}

void main() {
  for (final action in ['View', 'Add files', 'Paste', 'Save as', 'Detach']) {
    testWidgets(
      'keyboard action $action retains button focus across busy and modal phases',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('action-focus-');
        addTearDown(() => root.deleteSync(recursive: true));
        final launcher = GateLauncher()..replyWith(jsonEncode(att.info()));
        final client = ViewerCliClient(
          environment: transport.viewerEnvironmentForTest(
            dataRoot: '${root.path}/store',
            settingsRoot: '${root.path}/settings',
          ),
          launcher: launcher,
          executableExists: (_) => true,
        );
        await client.probe();
        final metadata = {
          ...att.metadata,
          'kind': 'binary',
          'media_type': 'application/octet-stream',
          'original_size': 12,
        };
        final task = att.task();
        task.attachments[0] = AttachmentSummary.fromJson(metadata);
        final c = AttachmentController(
          client: client,
          projectId: transport.projectUuid,
          task: task,
          refresh: () async {},
          announce: (_) {},
          dialogs: Picker(),
        );
        addTearDown(c.dispose);
        if (action == 'View' || action == 'Save as') {
          launcher.replyWith(
            att.envelope('attachment_get', {
              'id': 42,
              'items': [
                {
                  'attachment': metadata,
                  'path': r'C:\synthetic\file.bin',
                  'reused': false,
                },
              ],
            }),
          );
        } else if (action == 'Paste') {
          launcher.replyWith(
            att.envelope('attachment_clipboard', {
              'items': [
                {'name': 'clip.log', 'kind': 'text', 'original_size': 12},
              ],
              'skipped': [],
              'token': 'b' * 64,
            }, project: false),
          );
        } else {
          launcher.replyWith(
            att.envelope(
              'attachment_${action == 'Detach' ? 'detach' : 'add'}',
              {
                'id': 42,
                'version': 8,
                'event_id': 9,
                'attachments': [metadata],
                'detached': [12],
              },
            ),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AttachmentPanel(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.widgetWithText(
          TextButton,
          '$action (${{'View': 'Alt+W', 'Add files': 'Alt+F', 'Paste': 'Alt+U', 'Save as': 'Alt+S', 'Detach': 'Alt+X'}[action]})',
        );
        final focus = Focus.of(
          tester.element(
            find.descendant(of: button, matching: find.byType(Text)).last,
          ),
        );
        focus.requestFocus();
        await tester.pump();
        launcher.gate = Completer<void>();
        final callsBefore = launcher.starts;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        if (action == 'Detach') {
          await tester.pumpAndSettle();
          await tester.tap(find.text('Detach (Alt+D)'));
          await tester.pumpAndSettle();
        }
        final heldFocus = focus.hasFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        final callsWhileBusy = launcher.starts;
        launcher.gate!.complete();
        await tester.pumpAndSettle();
        if (action == 'View' || action == 'Paste') {
          expect(
            find.byType(
              action == 'View'
                  ? AttachmentPreviewDialog
                  : AttachmentConfirmationDialog,
            ),
            findsOneWidget,
          );
          await support.pressKey(tester, LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        final returnedFocus = focus.hasFocus;
        final list = tester
            .state<AttachmentPanelState>(find.byType(AttachmentPanel))
            .list;
        final returnedToList = list.hasListFocus && list.focusedRowIndex == 0;
        await tester.pumpWidget(const SizedBox());
        expect(
          callsWhileBusy,
          callsBefore + 1,
          reason: '$action must ignore a second keypress while busy',
        );
        expect(
          heldFocus,
          isTrue,
          reason:
              '$action must not disable the focused button during its CLI work',
        );
        expect(
          action == 'Detach' ? returnedToList : returnedFocus,
          isTrue,
          reason: action == 'Detach'
              ? 'Successful detach returns to the nearest remaining row (TSK-060)'
              : '$action must return to the originating button',
        );
      },
    );
  }

  test('Save reports success once', () async {
    final root = Directory.systemTemp.createTempSync('single-save-notice-');
    addTearDown(() => root.deleteSync(recursive: true));
    final rig = att.Rig(root);
    addTearDown(rig.controller.dispose);
    await rig.probe();
    rig.launcher.replyWith(
      att.envelope('attachment_get', {
        'id': 42,
        'items': [
          {
            'attachment': att.metadata,
            'path': rig.dialogs.out,
            'reused': false,
          },
        ],
      }),
    );
    await rig.controller.saveAs(rig.controller.task.attachments.single);
    expect(rig.announcements.where((s) => s == 'Saved run.log').length, 1);
  });
  for (final cancel in [true, false]) {
    test(
      'skip reminder cannot leak after ${cancel ? 'cancelled' : 'invalidated'} confirmation',
      () async {
        final root = Directory.systemTemp.createTempSync('skip-reminder-');
        addTearDown(() => root.deleteSync(recursive: true));
        final rig = att.Rig(root);
        addTearDown(rig.controller.dispose);
        await rig.probe();
        var current = true;
        final c = AttachmentController(
          client: rig.client,
          projectId: transport.projectUuid,
          task: att.task(),
          refresh: () async {},
          announce: rig.announcements.add,
          dialogs: rig.dialogs,
          isCurrent: () => current,
        );
        addTearDown(c.dispose);
        rig.launcher.replyWith(
          att.envelope('attachment_clipboard', {
            'items': [
              {'name': 'clip.log', 'kind': 'text', 'original_size': 12},
            ],
            'skipped': [],
            'token': 'b' * 64,
          }, project: false),
        );
        await c.paste((_) async {
          c.confirmationWasSkipped();
          current = cancel;
          return !cancel;
        });
        current = true;
        rig.mutation('attachment_add');
        await c.addFiles();
        expect(rig.announcements.last, 'Attached 1 file to TSK-042');
      },
    );
  }
}
