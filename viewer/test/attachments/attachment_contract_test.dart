import 'dart:async';
import 'dart:convert';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/keyboard_help_dialog.dart';
import 'package:tasks_viewer/ui/viewer_format.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import '../support/viewer_test_support.dart' as support;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/controllers/attachment_controller.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart'
    show taskDetailDebounce;
import 'package:tasks_viewer/platform/file_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import '../data/cli_client_test.dart' as transport;

final metadata = <String, Object?>{
  'id': 12,
  'display_id': 'A12',
  'name': 'run.log',
  'kind': 'text',
  'media_type': 'text/plain; charset=utf-8',
  'original_size': 3145728,
  'stored_size': 123,
  'sha256': 'a' * 64,
  'added_ms': 1700000000000,
};
TaskDetail task() => TaskDetail(
  id: 42,
  displayId: 'TSK-042',
  title: 'Synthetic',
  body: '',
  status: 'todo',
  priority: 'P2',
  version: 7,
  labels: const [],
  deps: const [],
  dependencySummaries: const [],
  ruleVersion: 1,
  rules: '',
  createdMs: 0,
  updatedMs: 0,
  attachments: [AttachmentSummary.fromJson(metadata)],
);
Map<String, Object?> info({bool remote = false, bool attachments = true}) {
  final doc = jsonDecode(transport.infoDocument()) as Map<String, dynamic>;
  final data = doc['data'] as Map<String, dynamic>;
  data['operations'] = [
    'projects',
    'tasks',
    'show',
    'update',
    if (attachments) ...[
      'attachment-add',
      'attachment-get',
      'attachment-detach',
      'attachment-clipboard',
    ],
  ];
  data['backend'] = remote ? 'remote' : 'local';
  data['receipt_recovery'] = remote;
  return doc;
}

String envelope(
  String command,
  Map<String, Object?> data, {
  bool project = true,
}) => jsonEncode({
  'schema_version': 1,
  'project_id': project ? transport.projectUuid : null,
  'data': {'command': command, ...data},
});

class Dialogs implements AttachmentFileDialogs {
  List<String> files = [r'C:\synthetic\run.log'];
  String? out = r'C:\synthetic\saved.log';
  @override
  Future<List<String>> openFiles() async => files;
  @override
  Future<String?> saveAs(String suggestedName) async {
    expect(suggestedName, 'run.log');
    return out;
  }
}

class Rig {
  Rig(this.root) {
    client = ViewerCliClient(
      environment: transport.viewerEnvironmentForTest(
        dataRoot: '${root.path}/data',
        settingsRoot: '${root.path}/settings',
      ),
      launcher: launcher,
      executableExists: (_) => true,
    );
    controller = AttachmentController(
      client: client,
      projectId: transport.projectUuid,
      task: task(),
      dialogs: dialogs,
      refresh: () async {
        refreshes++;
      },
      announce: announcements.add,
    );
  }
  final Directory root;
  final launcher = transport.ScriptedLauncher();
  final dialogs = Dialogs();
  final announcements = <String>[];
  late ViewerCliClient client;
  late AttachmentController controller;
  int refreshes = 0;
  Future<void> probe() async {
    launcher.replyWith(jsonEncode(info()));
    await client.probe();
  }

  void mutation(String command) => launcher.replyWith(
    envelope(command, {
      'id': 42,
      'display_id': 'TSK-042',
      'version': 8,
      'event_id': 9,
      'status': 'todo',
      'attachments': [metadata],
      'detached': [12],
    }),
  );
  List<String> get args => launcher.launches.last.arguments;
}

void main() {
  late Directory root;
  late Rig rig;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('viewer-attachments-test-');
    rig = Rig(root);
  });
  tearDown(() async {
    rig.controller.dispose();
    try {
      await root.delete(recursive: true);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 32) rethrow;
      // Flutter may keep an image mapping until this test process exits.
      // The worker cleans its explicit TEMP root after collecting the exit.
      // ignore: avoid_print
      print('DEFERRED_FIXTURE_CLEANUP ${root.path}');
    }
  });
  for (final malformed in [false, true]) {
    test(
      'unusable attachment state falls back to refresh malformed=$malformed',
      () async {
        await rig.probe();
        rig.launcher.replyWith(
          envelope('attachment_add', {
            'id': 42,
            'status': 'todo',
            'version': 8,
            'attachment_state': {
              'items': [metadata],
              'has_more': !malformed,
              'next_after': 'A12',
              'attachment_count': 101,
              'updated_ms': 1234,
            },
          }),
        );
        await rig.controller.addFiles();
        expect(rig.refreshes, 1);
        expect(rig.controller.task.version, 7);
      },
    );
  }
  test('complete attachment write replies update without refresh', () async {
    await rig.probe();
    for (final detach in [false, true]) {
      final items = detach ? <Map<String, Object?>>[] : [metadata];
      rig.launcher.replyWith(
        envelope(detach ? 'attachment_detach' : 'attachment_add', {
          'id': 42,
          'display_id': 'TSK-042',
          'status': 'todo',
          'version': detach ? 9 : 8,
          'event_id': 10,
          'attachment_state': {
            'items': items,
            'has_more': false,
            'next_after': null,
            'attachment_count': items.length,
            'updated_ms': 1234,
          },
        }),
      );
      final before = rig.launcher.launches.length;
      if (detach) {
        expect(
          await rig.controller.detachMany(
            rig.controller.task.attachments,
            () async => true,
          ),
          isTrue,
        );
      } else {
        await rig.controller.addFiles();
      }
      expect(rig.refreshes, 0);
      expect(rig.launcher.launches.length - before, 1);
      expect(rig.controller.task.version, detach ? 9 : 8);
      expect(rig.controller.task.updatedMs, 1234);
      expect(rig.controller.task.attachments.length, items.length);
    }
  });

  testWidgets(
    'short preview owns focus arrows save and preserves caret on rebuild',
    (tester) async {
      final file = File('${root.path}/short.txt')
        ..writeAsStringSync('first line\nsecond line');
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentPreviewDialog(
            item: AttachmentSummary.fromJson({
              ...metadata,
              'original_size': 22,
            }),
            path: file.path,
            announce: (_) {},
            onSaveAs: () async {
              saves++;
            },
          ),
        ),
      );
      await settleFileIo(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(find.text('Head (Alt+H)'), findsNothing);
      field.controller!.selection = const TextSelection.collapsed(offset: 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(field.controller!.selection.baseOffset, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(field.controller!.selection.baseOffset, greaterThan(1));
      final selection = field.controller!.selection;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AttachmentPreviewDialog(
            item: AttachmentSummary.fromJson({
              ...metadata,
              'original_size': 22,
            }),
            path: file.path,
            announce: (_) {},
            onSaveAs: () async {
              saves++;
            },
          ),
        ),
      );
      await tester.pump();
      expect(field.controller!.selection, selection);
      await support.pressAlt(tester, LogicalKeyboardKey.keyS);
      expect(saves, 1);
      expect(find.text('Save as (Alt+S)'), findsOneWidget);
    },
  );
  testWidgets(
    'long lines split once for display while retaining one selectable document',
    (tester) async {
      final file = File('${root.path}/long.txt')..writeAsStringSync('x' * 8192);
      final spoken = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentPreviewDialog(
            item: AttachmentSummary.fromJson({
              ...metadata,
              'original_size': 8192,
            }),
            path: file.path,
            announce: spoken.add,
            onSaveAs: () async {},
          ),
        ),
      );
      await settleFileIo(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text.split('\n').every((line) => line.length <= 4096),
        isTrue,
      );
      expect(field.controller!.text.replaceAll('\n', ''), 'x' * 8192);
      expect(
        find.text(
          'Long lines were split for preview; Save as keeps the original file.',
        ),
        findsOneWidget,
      );
      expect(spoken.where((s) => s.contains('Long lines')).length, 1);
      expect(file.readAsStringSync(), 'x' * 8192);
    },
  );
  testWidgets(
    'one MiB single line opens like line broken text and caret survives',
    (tester) async {
      final timings = <int>[];
      for (final single in [false, true]) {
        final source = single
            ? 'x' * attachmentTextPreviewLimit
            : ('x' * 2047 + '\n') * 512;
        final file = File('${root.path}/perf-$single.txt')
          ..writeAsStringSync(source);
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: AttachmentPreviewDialog(
              key: ValueKey(single),
              item: AttachmentSummary.fromJson({
                ...metadata,
                'original_size': source.length,
              }),
              path: file.path,
              announce: (_) {},
              onSaveAs: () async {},
            ),
          ),
        );
        await settleFileIo(tester);
        watch.stop();
        timings.add(watch.elapsedMilliseconds);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(find.byType(TextField), findsOneWidget);
        expect(
          field.controller!.text
              .split('\n')
              .every((line) => line.length <= 4096),
          isTrue,
        );
        field.controller!.selection = const TextSelection.collapsed(offset: 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(field.controller!.selection.baseOffset, 1);
        await tester.pumpWidget(const SizedBox());
      }
      // ignore: avoid_print
      print('PREVIEW_1MIB_MS broken=${timings[0]} single=${timings[1]}');
      expect(timings[1], lessThan(3500));
      expect(timings[1], lessThan(timings[0] * 2 + 500));
    },
  );
  testWidgets(
    'detach returns focus to same or previous selected row and initial actions enabled',
    (tester) async {
      await rig.probe();
      rig.controller.task.attachments.add(
        AttachmentSummary.fromJson({
          ...metadata,
          'id': 13,
          'name': 'second.log',
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
        ),
      );
      final panel = tester.state<AttachmentPanelState>(
        find.byType(AttachmentPanel),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'View (Alt+W)',
        'Save as (Alt+S)',
        'Detach (Alt+X)',
      ]) {
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, label))
              .onPressed,
          isNotNull,
        );
      }
      panel.list.goToIndex(1);
      panel.focusList();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      rig.mutation('attachment_detach');
      rig.controller.task.attachments.removeLast();
      await tester.tap(find.text('Detach (Alt+D)'));
      await tester.pumpAndSettle();
      expect(panel.list.hasFocus, isTrue);
      expect(panel.list.focusedRowIndex, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel (Alt+C)'));
      await tester.pumpAndSettle();
      expect(panel.list.hasFocus, isTrue);
      expect(panel.list.focusedRowIndex, 0);
    },
  );
  testWidgets('attachment titles name routes without Alert semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: AttachmentConfirmationDialog(
          title: 'Detach run.log?',
          content: 'History retained',
          accept: 'Detach',
          cancelDefault: true,
        ),
      ),
    );
    final title = tester
        .getSemantics(find.text('Detach run.log?'))
        .getSemanticsData();
    expect(title.flagsCollection.namesRoute, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    semantics.dispose();
  });
  test(
    'context invalidated during file dialog cannot dispatch any attachment operation',
    () async {
      await rig.probe();
      var current = true;
      final dialogs = DeferredDialogs();
      final c = AttachmentController(
        client: rig.client,
        projectId: transport.projectUuid,
        task: task(),
        dialogs: dialogs,
        refresh: () async {},
        announce: (_) {},
        isCurrent: () => current,
      );
      final opening = c.addFiles();
      await Future<void>.delayed(Duration.zero);
      current = false;
      dialogs.files.complete(['C:/fixture.log']);
      await opening;
      await c.paste((_) async => true);
      await c.detach(c.task.attachments.first, () async => true);
      await c.materialize(c.task.attachments.first);
      await c.saveAs(c.task.attachments.first);
      await c.recover();
      expect(rig.launcher.launches.length, 1);
      c.dispose();
    },
  );
  test('clipboard inspection reports reading rather than saving', () async {
    await rig.probe();
    rig.launcher.answer = false;
    final pasting = rig.controller.paste((_) async => false);
    await Future<void>.delayed(Duration.zero);
    expect(rig.controller.disabledReason, 'Reading clipboard...');
    rig.launcher.launches.last.handle.finishWithoutResponse();
    await pasting;
  });
  test(
    'display splitting prefers nearby spaces commas and preserves Unicode',
    () {
      for (final separator in [' ', ',']) {
        final source = '${'x' * 2000}$separator${'y' * 3000}';
        final display = splitAttachmentPreviewLines(source);
        expect(display.split('\n').first, '${'x' * 2000}$separator');
        expect(display.replaceAll('\n', ''), source);
      }
      final unicode = '${'x' * 2047}\u{1F600}${'y' * 2000}';
      final display = splitAttachmentPreviewLines(unicode);
      expect(display.replaceAll('\n', ''), unicode);
      expect(display.split('\n').first.length, 2047);
    },
  );
  testWidgets('invalid PNG falls back without reusing the image focus node', (
    tester,
  ) async {
    final file = File('${root.path}/bad.png')..writeAsStringSync('invalid');
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: AttachmentSummary.fromJson({
            ...metadata,
            'kind': 'image',
            'media_type': 'image/png',
            'original_size': 7,
          }),
          path: file.path,
          announce: (_) {},
          onSaveAs: () async {},
        ),
      ),
    );
    await settleFileIo(tester);
    expect(find.textContaining('Preview unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('clipboard errors have actionable attachment messages', () {
    expect(
      attachmentFailureMessage(
        const ViewerCliErrorFailure(
          code: 'clipboard_empty',
          message: 'empty',
          exitCode: 2,
        ),
      ),
      'The clipboard has no image or files',
    );
    expect(
      attachmentFailureMessage(
        const ViewerCliErrorFailure(
          code: 'clipboard_changed',
          message: 'changed',
          exitCode: 4,
        ),
      ),
      'The clipboard changed; paste again',
    );
  });
  test('attachment operations gate requires all four operations', () {
    final data = info()['data'] as Map<String, dynamic>;
    expect(ViewerInfo.fromJson(data).supportsAttachments, isTrue);
    for (final operation in [
      'attachment-add',
      'attachment-get',
      'attachment-detach',
      'attachment-clipboard',
    ]) {
      final changed = Map<String, Object?>.from(data);
      changed['operations'] = (data['operations'] as List<String>)
          .where((v) => v != operation)
          .toList();
      expect(ViewerInfo.fromJson(changed).supportsAttachments, isFalse);
    }
    expect(
      ViewerInfo.fromJson(
        info(attachments: false)['data'] as Map<String, dynamic>,
      ).supportsAttachments,
      isFalse,
    );
  });
  test('metadata rows expose name kind media size and date', () {
    final row = task().attachments.single;
    expect(
      row.rowLabel,
      contains('run.log, text, text/plain; charset=utf-8, 3.0 MB, added'),
    );
    expect(row.displayId, 'A12');
  });
  test(
    'fake open-files dialog sends repeated file args with displayed version',
    () async {
      await rig.probe();
      rig.dialogs.files = [r'C:\a.txt', r'C:\b.txt'];
      rig.mutation('attachment_add');
      await rig.controller.addFiles();
      expect(rig.args.sublist(rig.args.indexOf('attachment')), [
        'attachment',
        'add',
        '42',
        '--expect-version',
        '7',
        '--file',
        r'C:\a.txt',
        '--file',
        r'C:\b.txt',
      ]);
      expect(rig.refreshes, 1);
      expect(rig.announcements.last, 'Attached 2 files to TSK-042');
      expect(
        rig.args,
        containsAll([
          '--data-root',
          '${root.path}/data',
          '--project',
          transport.projectUuid,
        ]),
      );
    },
  );
  test('paste inspects then confirms then adds exact token', () async {
    await rig.probe();
    rig.launcher.replyWith(
      envelope('attachment_clipboard', {
        'items': [
          {
            'source': 'file',
            'name': 'run.log',
            'kind': 'text',
            'original_size': 12,
            'media_type': 'text/plain',
            'path': r'C:\a.log',
          },
        ],
        'skipped': [
          {'path': 'folder', 'reason': 'not regular'},
        ],
        'token': 'f' * 64,
      }, project: false),
    );
    await rig.controller.paste((clip) async {
      expect(clip.skipped.single['reason'], 'not regular');
      expect(rig.args.last, 'clipboard');
      rig.mutation('attachment_add');
      return true;
    });
    expect(rig.args.sublist(rig.args.indexOf('attachment')), [
      'attachment',
      'add',
      '42',
      '--expect-version',
      '7',
      '--clipboard',
      '--clipboard-token',
      'f' * 64,
    ]);
  });
  test('paste cancel never adds', () async {
    await rig.probe();
    rig.launcher.replyWith(
      envelope('attachment_clipboard', {
        'items': [],
        'skipped': [],
        'token': 'a' * 64,
      }, project: false),
    );
    await rig.controller.paste((_) async => false);
    expect(rig.args.last, 'clipboard');
    expect(rig.refreshes, 0);
  });
  testWidgets('clipboard phase error offers an explicit retry of inspection', (
    tester,
  ) async {
    await rig.probe();
    const message =
        'Clipboard did not respond while reading the image. Try again in a moment. (phase: reading_image)';
    rig.launcher.exit = 6;
    rig.launcher.stderrBytes = [
      utf8.encode(
        jsonEncode({
          'schema_version': 1,
          'error': {'code': 'interop', 'message': message},
        }),
      ),
    ];
    await rig.controller.paste(
      (_) async => fail('must not confirm failed inspect'),
    );
    rig.controller.editing = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    expect(find.text('$message. Error code: interop.'), findsOneWidget);
    final retry = find.widgetWithText(TextButton, 'Retry clipboard');
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    await rig.controller.paste(
      (_) async => fail('must not inspect while editing'),
    );
    expect(rig.launcher.launches.length, 2); // No automatic retries.
    rig.controller.editing = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    rig.launcher.exit = 0;
    rig.launcher.stderrBytes = [];
    rig.launcher.replyWith(
      envelope('attachment_clipboard', {
        'items': [],
        'skipped': [],
        'token': 'a' * 64,
      }, project: false),
    );
    Focus.of(tester.element(find.text('Retry clipboard'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(rig.args.last, 'clipboard');
    expect(rig.launcher.launches.length, 3);
    expect(find.text('Attach to TSK-042?'), findsOneWidget);
    expect(find.text('Retry clipboard'), findsNothing);
    await tester.tap(find.text('Cancel (Alt+C)'));
    await tester.pumpAndSettle();
    expect(rig.refreshes, 0);
    expect(rig.launcher.launches.length, 3);
  });
  for (final code in ['clipboard_empty', 'clipboard_changed']) {
    test('CLI $code is surfaced without resending', () async {
      await rig.probe();
      rig.launcher.exit = code == 'clipboard_empty' ? 2 : 4;
      rig.launcher.stderrBytes = [
        utf8.encode(
          jsonEncode({
            'schema_version': 1,
            'error': {'code': code, 'message': 'fixture'},
          }),
        ),
      ];
      await rig.controller.paste(
        (_) async => fail('must not confirm failed inspection'),
      );
      expect(
        rig.controller.notice,
        code == 'clipboard_empty'
            ? 'The clipboard has no image or files'
            : 'The clipboard changed; paste again',
      );
      expect(rig.launcher.launches.length, 2);
      expect(rig.controller.clipboardRetryAvailable, isFalse);
    });
  }
  test(
    'detach confirmation cancels and explicit detach uses version',
    () async {
      await rig.probe();
      await rig.controller.detach(task().attachments.single, () async => false);
      expect(rig.launcher.launches.length, 1);
      rig.mutation('attachment_detach');
      await rig.controller.detach(task().attachments.single, () async => true);
      expect(rig.args.sublist(rig.args.indexOf('attachment')), [
        'attachment',
        'detach',
        '42',
        'A12',
        '--expect-version',
        '7',
      ]);
      expect(rig.announcements.last, 'Detached run.log');
    },
  );
  testWidgets('detach default focus is Cancel and Enter cancels', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<bool>(
                context: context,
                builder: (_) => const AttachmentConfirmationDialog(
                  title: 'Detach run.log?',
                  content: 'History retained',
                  accept: 'Detach',
                  cancelDefault: true,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Detach run.log?'), findsNothing);
    expect(result, isFalse);
  });
  test('Save as uses explicit out and overwrite', () async {
    await rig.probe();
    rig.launcher.replyWith(
      envelope('attachment_get', {
        'id': 42,
        'display_id': 'TSK-042',
        'items': [
          {'attachment': metadata, 'path': rig.dialogs.out, 'reused': false},
        ],
      }),
    );
    await rig.controller.saveAs(task().attachments.single);
    expect(rig.args.sublist(rig.args.indexOf('attachment')), [
      'attachment',
      'get',
      '42',
      'A12',
      '--out',
      rig.dialogs.out!,
      '--overwrite',
    ]);
    expect(rig.announcements.last, 'Saved run.log');
  });
  test('editing disables dialog clipboard detach preview and save', () async {
    await rig.probe();
    rig.controller.editing = true;
    await rig.controller.addFiles();
    await rig.controller.paste((_) async => fail('editing'));
    await rig.controller.detach(
      task().attachments.single,
      () async => fail('editing'),
    );
    await rig.controller.saveAs(task().attachments.single);
    expect(await rig.controller.materialize(task().attachments.single), isNull);
    expect(rig.launcher.launches.length, 1);
    expect(rig.controller.disabledReason, 'Save or cancel your edits first');
  });
  test(
    'local unknown outcome refreshes and never resends malformed write',
    () async {
      await rig.probe();
      rig.launcher.replyWith('{');
      await rig.controller.addFiles();
      expect(rig.refreshes, 1);
      expect(
        rig.controller.notice,
        'Attachment outcome unknown; check the list before retrying',
      );
      expect(rig.launcher.launches.length, 2);
    },
  );
  test('Head and Tail read only 1 MiB of a 3 MiB file', () async {
    final file = File('${root.path}/large.log');
    await file.writeAsBytes([
      ...List.filled(1024 * 1024, 65),
      ...List.filled(1024 * 1024, 66),
      ...List.filled(1024 * 1024, 67),
    ]);
    final head = await readAttachmentText(file.path);
    final tail = await readAttachmentText(file.path, tail: true);
    expect(head.bytesRead, 1048576);
    expect(tail.bytesRead, 1048576);
    expect(head.text, 'A' * 1048576);
    expect(tail.text, 'C' * 1048576);
    expect(head.truncated, isTrue);
    await file.writeAsBytes([255, 65]);
    expect((await readAttachmentText(file.path)).invalid, isTrue);
  });
  testWidgets('binary fallback retains Save as', (tester) async {
    final binary = AttachmentSummary.fromJson({
      ...metadata,
      'kind': 'binary',
      'media_type': 'application/octet-stream',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: binary,
          path: 'unused',
          announce: (_) {},
          onSaveAs: () async {},
        ),
      ),
    );
    expect(find.textContaining('Preview unavailable'), findsOneWidget);
    expect(find.text('Save as (Alt+S)'), findsOneWidget);
  });
  testWidgets('PNG preview exposes dimensions zoom keys pan and fit', (
    tester,
  ) async {
    final file = File('${root.path}/tiny.png');
    await tester.runAsync(
      () => file.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
        ),
      ),
    );
    final image = AttachmentSummary.fromJson({
      ...metadata,
      'name': 'tiny.png',
      'kind': 'image',
      'media_type': 'image/png',
      'original_size': file.lengthSync(),
    });
    final announcements = <String>[];
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: image,
          path: file.path,
          announce: announcements.add,
          onSaveAs: () async {},
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp('Image tiny.png, 1 by 1 pixels, zoom')),
      findsOneWidget,
    );
    await support.pressControl(tester, LogicalKeyboardKey.digit1);
    expect(
      find.bySemanticsLabel('Image tiny.png, 1 by 1 pixels, zoom 100 percent'),
      findsOneWidget,
    );
    await support.pressControl(tester, LogicalKeyboardKey.equal);
    expect(announcements.last, 'Zoom 125 percent');
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final before = viewer.transformationController!.value.storage[12];
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      viewer.transformationController!.value.storage[12],
      lessThan(before),
    );
    await support.pressControl(tester, LogicalKeyboardKey.minus);
    expect(announcements.last, 'Zoom 100 percent');
    await support.pressControl(tester, LogicalKeyboardKey.digit0);
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 16);
    expect(announcements.last, 'Zoom 1600 percent');
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    semantics.dispose();
  });
  testWidgets('unsupported image falls back without decoding file', (
    tester,
  ) async {
    final image = AttachmentSummary.fromJson({
      ...metadata,
      'kind': 'image',
      'media_type': 'image/tiff',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: image,
          path: 'does-not-exist',
          announce: (_) {},
          onSaveAs: () async {},
        ),
      ),
    );
    expect(find.textContaining('Preview unavailable'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
  });
  testWidgets('text preview Head Tail controls and note are accessible', (
    tester,
  ) async {
    final file = File('${root.path}/text.log');
    await tester.runAsync(
      () => file.writeAsBytes([
        ...List.generate(1024 * 1024, (i) => i % 80 == 79 ? 10 : 65),
        ...List.generate(1024 * 1024, (i) => i % 80 == 79 ? 10 : 66),
        ...List.generate(1024 * 1024, (i) => i % 80 == 79 ? 10 : 67),
      ]),
    );
    final notices = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: task().attachments.single,
          path: file.path,
          announce: notices.add,
          onSaveAs: () async {},
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await settleFileIo(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      String.fromCharCodes(
        List.generate(1048576, (i) => i % 80 == 79 ? 10 : 65),
      ),
    );
    await tester.tap(find.text('Tail (Alt+T)'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await settleFileIo(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      String.fromCharCodes(
        List.generate(1048576, (i) => i % 80 == 79 ? 10 : 67),
      ),
    );
    expect(notices.last, contains('last 1 MiB; preview truncated'));
  });
  testWidgets('attachment panel rows and edit-mode action guard', (
    tester,
  ) async {
    await rig.probe();
    final semantics = tester.ensureSemantics();
    rig.controller.editing = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    expect(
      find.bySemanticsLabel(
        'run.log, text, text/plain; charset=utf-8, 3.0 MB, added ${viewerTimestamp(tester.element(find.byType(AttachmentPanel)), metadata['added_ms']! as int)}',
      ),
      findsOneWidget,
    );
    expect(find.text('Save or cancel your edits first'), findsOneWidget);
    final add = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Add files (Alt+F)'),
    );
    expect(add.onPressed, isNotNull);
    final calls = rig.launcher.launches.length;
    await tester.tap(find.text('Add files (Alt+F)'));
    await tester.pumpAndSettle();
    expect(rig.launcher.launches.length, calls);
    expect(rig.announcements.last, 'Save or cancel your edits first');
    semantics.dispose();
  });
  testWidgets('attachments-only conflict explains and offers explicit review', (
    tester,
  ) async {
    final conflict = EditorConflict(
      baseVersion: 7,
      current: task(),
      baseFields: TaskEditFields.fromDetail(task()),
      draftFields: TaskEditFields.fromDetail(task()),
      changedFields: const [],
      conflictFields: const [],
    );
    await tester.pumpWidget(
      MaterialApp(home: AttachmentOnlyConflictDialog(conflict: conflict)),
    );
    expect(
      find.text('Only attachments changed since you started editing'),
      findsOneWidget,
    );
    expect(find.text('Review against current (Alt+V)'), findsOneWidget);
  });
  test(
    'attachment keyboard entries are discoverable from shared help registry',
    () {
      expect(commandSpecById('details.tabAttachments')!.shortcutLabel, 'Alt+5');
      expect(commandSpecById('details.attachmentAdd')!.shortcutLabel, 'Alt+F');
      for (final scope in [
        CommandScope.attachmentAttach,
        CommandScope.attachmentDetach,
        CommandScope.attachmentPreview,
      ]) {
        expect(isDialogScope(scope), isTrue);
        expect(
          helpEntriesFor(scope).where((entry) => entry.spec.scope == scope),
          isNotEmpty,
        );
      }
      expect(
        commandSpecById('attachmentPreview.help')!.shortcutLabel,
        contains('Alt+S: Save as'),
      );
      expect(
        commandSpecById('attachment.help')!.shortcutLabel,
        contains('Ctrl+V'),
      );
    },
  );
  test(
    'remote add request-id survives malformed result and reconciles once',
    () async {
      final launcher = RemoteLauncher();
      final client = ViewerCliClient(
        environment: transport.viewerEnvironmentForTest(
          dataRoot: '${root.path}/data',
          settingsRoot: '${root.path}/settings',
        ),
        launcher: launcher,
        executableExists: (_) => true,
      );
      await client.probe();
      final notices = <String>[];
      final c = AttachmentController(
        client: client,
        projectId: transport.projectUuid,
        task: task(),
        dialogs: Dialogs(),
        refresh: () async {},
        announce: notices.add,
      );
      await c.addFiles();
      expect(c.pendingRequestId, isNotNull);
      expect(c.enabled, isFalse);
      expect(notices.last, contains('Check pending change'));
      final id = c.pendingRequestId;
      await c.recover();
      expect(client.pendingReceipts, isEmpty);
      expect(launcher.calls.where((a) => a.contains('add')).length, 1);
      expect(
        launcher.calls.where((a) => a.contains('reconcile')).single.last,
        id,
      );
      expect(
        launcher.calls.where((a) => a.contains('acknowledge')).single.last,
        id,
      );
      expect(notices.last, 'Attachment change confirmed');
      c.dispose();
    },
  );
  test(
    'changed clipboard at token-checked add preserves list and asks to paste again',
    () async {
      await rig.probe();
      rig.launcher.replyWith(
        envelope('attachment_clipboard', {
          'items': [],
          'skipped': [],
          'token': 'a' * 64,
        }, project: false),
      );
      await rig.controller.paste((_) async {
        rig.launcher.exit = 4;
        rig.launcher.stderrBytes = [
          utf8.encode(
            jsonEncode({
              'schema_version': 1,
              'error': {'code': 'clipboard_changed', 'message': 'changed'},
            }),
          ),
        ];
        return true;
      });
      expect(rig.controller.notice, 'The clipboard changed; paste again');
      expect(rig.refreshes, 0);
      expect(rig.launcher.launches.length, 3);
    },
  );
  for (final remote in [false, true]) {
    testWidgets(
      'attachment success patches the real pane and task row without reads remote=$remote',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final launcher = DetailLauncher(true, remote: remote);
        final client = ViewerCliClient(
          environment: rig.client.environment,
          launcher: launcher,
          executableExists: (_) => true,
        );
        final backend = support.fakeWorkspaceReads(
          tasks: {
            '00000000-0000-4000-8000-000000000001': [
              support.testTaskItem(42).withAttachmentWrite(task(), 1),
            ],
          },
        );
        final announcements = AnnouncementController(
          clipPlayer: support.RecordingClipPlayer(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ViewerWorkspaceHost(
              environment: rig.client.environment,
              readers: ViewerDataReader(
                projects: backend,
                tasks: backend,
                detail: client,
                update: client,
                probe: client.probe,
              ),
              announcements: announcements,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final model = tester
            .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
            .model;
        model.selectProjectIndex(0);
        await tester.pumpAndSettle();
        await model.openTaskIndex(0);
        await tester.pumpAndSettle();
        await support.pressKey(tester, LogicalKeyboardKey.f3);
        await support.pressAlt(tester, LogicalKeyboardKey.digit3);
        await support.pressAlt(tester, LogicalKeyboardKey.digit5);
        final controller = tester
            .widget<AttachmentPanel>(find.byType(AttachmentPanel))
            .controller;
        final reads = backend.taskRequests.length;
        var calls = launcher.calls.length;
        expect(
          await controller.detachMany(
            controller.task.attachments,
            () async => true,
          ),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(launcher.calls.length, calls + (remote ? 2 : 1));
        expect(backend.taskRequests.length, reads);
        expect(find.text('Attachments (0)'), findsOneWidget);
        expect(model.detail!.detail!.attachments, isEmpty);
        expect(model.tasks!.itemAt(0)!.attachmentCount, 0);
        expect(model.tasks!.itemAt(0)!.version, 8);
        expect(model.tasks!.itemAt(0)!.updatedMs, 1234);
        expect(model.editor.base!.version, 8);
        calls = launcher.calls.length;
        await controller.paste((_) async => true);
        await tester.pumpAndSettle();
        // Clipboard inspect is local; the write itself is the only server request.
        expect(launcher.calls.length, calls + (remote ? 3 : 2));
        expect(launcher.calls[calls].last, 'clipboard');
        expect(backend.taskRequests.length, reads);
        expect(find.text('Attachments (1)'), findsOneWidget);
        expect(find.textContaining('run.log, text'), findsOneWidget);
        expect(model.detail!.detail!.version, 9);
        expect(model.tasks!.itemAt(0)!.attachmentCount, 1);
        expect(model.tasks!.itemAt(0)!.version, 9);
        expect(model.tasks!.selectedTaskId, 42);
        calls = launcher.calls.length;
        await support.pressAlt(tester, LogicalKeyboardKey.digit3);
        expect(launcher.calls.length, calls + 1);
        expect(launcher.calls.last, contains('history'));
        await tester.pumpWidget(const SizedBox());
        announcements.dispose();
      },
    );
  }
  for (final navigation in ['history', 'task', 'project']) {
    testWidgets('paste reply updates after navigation=$navigation', (
      tester,
    ) async {
      final switchTask = navigation == 'task';
      final switchProject = navigation == 'project';
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final launcher = DetailLauncher(true)
        ..mutationStarted = Completer<void>()
        ..releaseMutation = Completer<void>();
      final client = ViewerCliClient(
        environment: rig.client.environment,
        launcher: launcher,
        executableExists: (_) => true,
      );
      final backend = GatedWorkspaceReads(
        tasks: {
          '00000000-0000-4000-8000-000000000001': [
            support.testTaskItem(42).withAttachmentWrite(task(), 1),
            support.testTaskItem(43),
          ],
        },
      );
      final announcements = AnnouncementController(
        clipPlayer: support.RecordingClipPlayer(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerWorkspaceHost(
            environment: rig.client.environment,
            readers: ViewerDataReader(
              projects: backend,
              tasks: backend,
              detail: client,
              update: client,
              probe: client.probe,
            ),
            announcements: announcements,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      model.selectProjectIndex(0);
      await tester.pumpAndSettle();
      expect(model.detail, isNotNull, reason: 'project selected');
      await model.openTaskIndex(0);
      await tester.pumpAndSettle();
      expect(model.detail!.detail, isNotNull);
      if (navigation == 'history') {
        await support.pressKey(tester, LogicalKeyboardKey.f3);
        await support.pressAlt(tester, LogicalKeyboardKey.digit3);
        expect(model.detail!.historyLoaded, isTrue);
      }
      await support.pressKey(tester, LogicalKeyboardKey.f2);
      await support.pressControl(tester, LogicalKeyboardKey.keyV);
      expect(find.textContaining('Attach to '), findsOneWidget);
      await support.pressAlt(tester, LogicalKeyboardKey.keyA);
      expect(launcher.mutationStarted!.isCompleted, isTrue);
      if (switchProject) {
        await support.pressKey(tester, LogicalKeyboardKey.f1);
        await support.pressKey(tester, LogicalKeyboardKey.arrowDown);
        expect(model.selectedProjectId, '00000000-0000-4000-8000-000000000002');
        backend.taskReadStarted = Completer<void>();
        backend.releaseTaskRead = Completer<void>();
        await support.pressKey(tester, LogicalKeyboardKey.arrowUp);
        await tester.pump(taskDetailDebounce);
        expect(model.selectedProjectId, '00000000-0000-4000-8000-000000000001');
        expect(backend.taskReadStarted!.isCompleted, isTrue);
        expect(model.tasks!.isLoading, isTrue);
      }
      final reads = backend.taskRequests.length;
      if (switchTask) {
        model.selectTaskIndex(1);
        await tester.pump(taskDetailDebounce);
        await tester.pumpAndSettle();
        expect(model.detail!.taskId, 43);
      }
      final shows = launcher.calls
          .where((args) => args.contains('show'))
          .length;
      final histories = launcher.calls
          .where((args) => args.contains('history'))
          .length;
      launcher.releaseMutation!.complete();
      await tester.pumpAndSettle();
      if (switchProject) {
        // The held page captured v7 before commit. Only the follow-up read can
        // observe the real v8 row, including all non-attachment fields.
        backend.tasks[model.selectedProjectId!] = [
          support
              .testTaskItem(42)
              .withAttachmentWrite(
                task().withAttachmentWrite(
                  version: 8,
                  updatedMs: 1234,
                  attachments: [AttachmentSummary.fromJson(metadata)],
                ),
                1,
              ),
        ];
        backend.releaseTaskRead!.complete();
        await tester.pumpAndSettle();
      }
      expect(backend.taskRequests.length, reads + (switchProject ? 1 : 0));
      // Local detail reads wait for the writer, including the selected task's
      // legitimate navigation read. The attachment reply must add no reload.
      expect(
        launcher.calls.where((args) => args.contains('show')).length,
        shows + (switchTask || switchProject ? 1 : 0),
      );
      expect(model.tasks!.itemAt(0)!.attachmentCount, 1);
      expect(model.tasks!.itemAt(0)!.version, 8);
      expect(model.tasks!.itemAt(0)!.updatedMs, 1234);
      if (switchTask) {
        expect(model.detail!.taskId, 43);
        expect(model.detail!.detail!.id, 43);
        expect(model.detail!.detail!.version, 7);
        expect(model.tasks!.selectedTaskId, 43);
      } else if (switchProject) {
        expect(model.detail!.detail!.id, 42);
        expect(model.detail!.detail!.version, 8);
        expect(model.tasks!.selectedTaskId, 42);
      } else {
        expect(
          launcher.calls.where((args) => args.contains('history')).length,
          histories + 1,
        );
        expect(model.detail!.historyLoaded, isTrue);
        expect(model.detail!.isHistoryLoading, isFalse);
        expect(model.detail!.historyEvents.single.resultingVersion, 8);
        expect(find.text('Loading history'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      announcements.dispose();
    });
  }
  for (final capable in [false, true]) {
    testWidgets(
      'real Details pane gates attachment tab capable=$capable and Alt+5 opens rows',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final launcher = DetailLauncher(capable);
        final client = ViewerCliClient(
          environment: rig.client.environment,
          launcher: launcher,
          executableExists: (_) => true,
        );
        final backend = support.fakeWorkspaceReads(
          tasks: {
            '00000000-0000-4000-8000-000000000001': [
              const TaskItem(
                id: 42,
                title: 'Task 42',
                status: 'todo',
                priority: 'P2',
                version: 1,
                labels: [],
                dependencyCount: 0,
                waitingDependencyCount: 0,
                attachmentCount: 1,
                createdMs: 0,
                updatedMs: 0,
              ),
              support.testTaskItem(43),
            ],
          },
        );
        final announcements = AnnouncementController(
          clipPlayer: support.RecordingClipPlayer(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ViewerWorkspaceHost(
              environment: rig.client.environment,
              readers: ViewerDataReader(
                projects: backend,
                tasks: backend,
                detail: client,
                update: client,
                probe: client.probe,
              ),
              announcements: announcements,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final model = tester
            .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
            .model;
        model.selectProjectIndex(0);
        await tester.pumpAndSettle();
        await model.openTaskIndex(0);
        await tester.pumpAndSettle();
        expect(
          find.text('Attachments (1)'),
          capable ? findsOneWidget : findsNothing,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'Task 42.*1 attachment(?!s)')),
          findsOneWidget,
        );
        if (capable) {
          final attachmentStyle = tester
              .widget<Text>(find.text('Attachments (1)'))
              .style;
          final detailsStyle = tester.widget<Text>(find.text('Details')).style;
          expect(attachmentStyle?.fontSize, detailsStyle?.fontSize);
          expect(attachmentStyle?.fontWeight, detailsStyle?.fontWeight);
          await support.pressKey(tester, LogicalKeyboardKey.f3);
          for (final tab in [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
          ]) {
            await support.pressAlt(tester, tab);
            for (final action in [
              LogicalKeyboardKey.keyF,
              LogicalKeyboardKey.keyU,
              LogicalKeyboardKey.keyW,
              LogicalKeyboardKey.keyS,
              LogicalKeyboardKey.keyX,
            ]) {
              final revision = announcements.liveRegionRevision;
              final calls = launcher.calls.length;
              await support.pressAlt(tester, action);
              expect(
                announcements.liveRegionText,
                'Open the Attachments tab first (Alt+5)',
              );
              expect(announcements.liveRegionRevision, revision + 1);
              expect(launcher.calls.length, calls);
              expect(find.byType(AttachmentPanel), findsNothing);
            }
          }
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);
          expect(find.byType(AttachmentPanel), findsOneWidget);
          expect(find.textContaining('run.log, text'), findsOneWidget);
          final old = tester
              .widget<AttachmentPanel>(find.byType(AttachmentPanel))
              .controller;
          launcher.failDetails = true;
          await model.openTaskIndex(1);
          await tester.pumpAndSettle();
          final retry = find.widgetWithText(FilledButton, 'Retry');
          expect(retry, findsOneWidget);
          Focus.of(tester.element(find.text('Retry'))).requestFocus();
          await tester.pump();
          final callsBefore = launcher.calls.length;
          expect(old.enabled, isFalse);
          await support.pressAlt(tester, LogicalKeyboardKey.keyF);
          expect(launcher.calls.length, callsBefore);
          expect(find.byType(AttachmentPanel), findsNothing);
          // Even activation from a failed detail must not carry across selections.
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);
          launcher.failDetails = false;
          await model.openTaskIndex(0);
          await tester.pumpAndSettle();
          expect(find.byType(AttachmentPanel), findsNothing);
          await support.pressKey(tester, LogicalKeyboardKey.f3);
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);

          await support.pressAlt(tester, LogicalKeyboardKey.keyA);
          await support.pressControl(tester, LogicalKeyboardKey.keyV);
          expect(find.textContaining('Attach to '), findsOneWidget);
          expect(
            tester
                .state<ViewerShellState>(find.byType(ViewerShell))
                .hasOpenModal,
            isTrue,
          );
          await support.pressKey(tester, LogicalKeyboardKey.f10);
          expect(find.byType(KeyboardHelpDialog), findsOneWidget);
          await support.pressKey(tester, LogicalKeyboardKey.escape);
          await support.pressKey(tester, LogicalKeyboardKey.escape);
          expect(
            tester
                .state<ViewerShellState>(find.byType(ViewerShell))
                .hasOpenModal,
            isFalse,
          );
          await support.pressAlt(tester, LogicalKeyboardKey.digit1);
          expect(find.byType(AttachmentPanel), findsNothing);
          await support.pressKey(tester, LogicalKeyboardKey.f4);
          await support.pressAlt(tester, LogicalKeyboardKey.digit5);
          expect(
            announcements.liveRegionText,
            'Save or cancel your edits first',
          );
          await support.pressAlt(tester, LogicalKeyboardKey.keyF);
          expect(
            announcements.liveRegionText,
            'Save or cancel your edits first',
          );
          for (final key in [
            LogicalKeyboardKey.digit5,
            LogicalKeyboardKey.keyA,
            LogicalKeyboardKey.keyF,
            LogicalKeyboardKey.keyU,
            LogicalKeyboardKey.keyW,
            LogicalKeyboardKey.keyX,
          ]) {
            final beforeRevision = announcements.liveRegionRevision;
            await support.pressAlt(tester, key);
            expect(announcements.liveRegionRevision, beforeRevision + 1);
            expect(
              announcements.liveRegionText,
              'Save or cancel your edits first',
            );
          }
          model.editor.setField(EditorField.title, 'My preserved title');
          launcher.rejectUpdate = true;
          final saved = await model.editor.save();
          expect(saved.outcome, EditorSaveOutcome.conflict);
          expect(attachmentsOnlyConflict(saved.conflict!), isTrue);
          final resolution = model.editorHost!.resolveConflict(saved.conflict!);
          await tester.pumpAndSettle();
          expect(find.text('Return to editor (Alt+E)'), findsOneWidget);
          expect(
            find.text('Reload current and discard draft (Alt+R)'),
            findsOneWidget,
          );
          await support.pressAlt(tester, LogicalKeyboardKey.keyV);
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsNothing);
          await resolution;
          expect(model.editor.conflict, isNull);
          expect(model.editor.base!.version, 8);
          expect(model.editor.draft!.title, 'My preserved title');
          expect(
            launcher.calls.where((args) => args.contains('update')).length,
            1,
          );
        }
        await tester.pumpWidget(const SizedBox());
        announcements.dispose();
        semantics.dispose();
      },
    );
  }
  testWidgets('Ctrl+V in panel inspects confirms then attaches with token', (
    tester,
  ) async {
    await rig.probe();
    rig.launcher.replyWith(
      envelope('attachment_clipboard', {
        'items': [
          {'name': 'clip.png', 'kind': 'image', 'original_size': 834512},
        ],
        'skipped': [
          {'path': 'folder', 'reason': 'directory'},
        ],
        'token': 'b' * 64,
      }, project: false),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    tester
        .state<AttachmentPanelState>(find.byType(AttachmentPanel))
        .focusList();
    await tester.pumpAndSettle();
    await support.pressAlt(tester, LogicalKeyboardKey.keyA);
    await support.pressControl(tester, LogicalKeyboardKey.keyV);
    expect(find.text('Attach to TSK-042?'), findsOneWidget);
    expect(find.textContaining('815.0 KB'), findsOneWidget);
    expect(find.textContaining('Skipped folder: directory'), findsOneWidget);
    expect(rig.args.last, 'clipboard');
    rig.mutation('attachment_add');
    await tester.tap(find.text('Attach (Alt+A)'));
    await tester.pumpAndSettle();
    expect(
      rig.args,
      containsAllInOrder(['--clipboard', '--clipboard-token', 'b' * 64]),
    );
    expect(rig.announcements.last, 'Attached 1 file to TSK-042');
  });
  test(
    'local timeout does not kill or resend the writer and re-reads outcome',
    () async {
      final launcher = transport.ScriptedLauncher()
        ..replyWith(jsonEncode(info()));
      final client = ViewerCliClient(
        environment: rig.client.environment,
        launcher: launcher,
        executableExists: (_) => true,
        readTimeout: const Duration(milliseconds: 10),
      );
      await client.probe();
      launcher.answer = false;
      final notices = <String>[];
      var reads = 0;
      final c = AttachmentController(
        client: client,
        projectId: transport.projectUuid,
        task: task(),
        dialogs: Dialogs(),
        refresh: () async {
          reads++;
        },
        announce: notices.add,
      );
      await c.addFiles();
      expect(launcher.launches.length, 2);
      expect(launcher.launches.last.handle.killCount, 0);
      expect(reads, 1);
      expect(
        notices.last,
        'Attachment outcome unknown; check the list before retrying',
      );
      launcher.launches.last.handle.finishWithoutResponse();
      c.dispose();
    },
  );
}

class RemoteLauncher implements ProcessLauncher {
  final calls = <List<String>>[];
  String? id;
  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> args,
  ) async {
    calls.add(args);
    String answer;
    if (args.contains('info')) {
      answer = jsonEncode(info(remote: true));
    } else if (args.contains('recovery')) {
      answer = envelope('viewer_recovery', {'items': []}, project: false);
    } else if (args.contains('add')) {
      id = args[args.indexOf('--request-id') + 1];
      answer = '{';
    } else if (args.contains('reconcile')) {
      answer = envelope('attachment_add', {
        'id': 42,
        'display_id': 'TSK-042',
        'version': 8,
        'status': 'todo',
        'event_id': 10,
        'attachments': [metadata],
      });
    } else if (args.contains('acknowledge')) {
      answer = envelope('viewer_acknowledge', {
        'request_id': id,
        'acknowledged': true,
      }, project: false);
    } else {
      throw StateError('Unexpected args $args');
    }
    return transport.FakeProcessHandle(stdoutBytes: [utf8.encode(answer)]);
  }
}

Future<void> settleFileIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

class GatedWorkspaceReads extends support.FakeWorkspaceReads {
  GatedWorkspaceReads({required super.tasks})
    : super(projects: [support.testProjectItem(1), support.testProjectItem(2)]);

  Completer<void>? taskReadStarted;
  Completer<void>? releaseTaskRead;

  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) async {
    final gate = releaseTaskRead;
    final page = await super.fetchTasks(projectId, query);
    if (gate != null) {
      if (!taskReadStarted!.isCompleted) taskReadStarted!.complete();
      await gate.future;
    }
    return page;
  }
}

class DetailLauncher implements ProcessLauncher {
  DetailLauncher(this.capable, {this.remote = false});
  final bool remote;
  bool failDetails = false;
  bool rejectUpdate = false;
  int version = 7;
  Completer<void>? mutationStarted;
  Completer<void>? releaseMutation;
  List<Map<String, Object?>> attachments = [metadata];
  final calls = <List<String>>[];
  final bool capable;
  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> args,
  ) async {
    calls.add(args);
    if (rejectUpdate && args.contains('update')) {
      version = 8;
      return transport.FakeProcessHandle(
        exit: 4,
        stderrBytes: [
          utf8.encode(
            '{"schema_version":1,"error":{"code":"version_conflict","message":"expected 7 found 8","conflict":{"expected":7,"current":8}}}',
          ),
        ],
      );
    }
    if (failDetails && args.contains('show')) {
      return transport.FakeProcessHandle(stdoutBytes: [utf8.encode('{')]);
    }
    String response;
    if (args.contains('info')) {
      response = jsonEncode(info(attachments: capable, remote: remote));
    } else if (args.contains('recovery')) {
      response = envelope('viewer_recovery', {'items': []}, project: false);
    } else if (args.contains('acknowledge')) {
      response = envelope('viewer_acknowledge', {
        'request_id': args.last,
        'acknowledged': true,
      }, project: false);
    } else if (args.contains('attachment') &&
        (args.contains('detach') || args.contains('add'))) {
      mutationStarted?.complete();
      await releaseMutation?.future;
      final detach = args.contains('detach');
      version++;
      attachments = detach ? [] : [metadata];
      response = envelope(detach ? 'attachment_detach' : 'attachment_add', {
        'id': 42,
        'display_id': 'TSK-042',
        'status': 'todo',
        'version': version,
        'event_id': 10,
        'attachment_state': {
          'items': attachments,
          'has_more': false,
          'next_after': null,
          'attachment_count': attachments.length,
          'updated_ms': 1234,
        },
      });
    } else if (args.contains('show')) {
      final doc =
          jsonDecode(
                transport.showDocument(
                  projectId: args[args.indexOf('--project') + 1],
                ),
              )
              as Map<String, dynamic>;
      final id = int.parse(args[args.indexOf('show') + 1].split('-').last);
      (doc['data'] as Map<String, dynamic>)['version'] = id == 42 ? version : 7;
      (doc['data'] as Map<String, dynamic>)['id'] = id;
      (doc['data'] as Map<String, dynamic>)['attachments'] = attachments;
      response = jsonEncode(doc);
    } else if (args.contains('history')) {
      response = transport.historyDocument(
        projectId: args[args.indexOf('--project') + 1],
        items: [
          {
            'event_id': 11,
            'task_id': 42,
            'entity_type': 'task',
            'operation': 'update',
            'resulting_version': version,
            'created_ms': 1700000001000,
            'snapshot_json': '{"version":$version}',
          },
        ],
      );
    } else if (args.contains('clipboard')) {
      response = envelope('attachment_clipboard', {
        'items': [
          {'name': 'run.log', 'kind': 'text', 'original_size': 5},
        ],
        'skipped': [],
        'token': 'c' * 64,
      }, project: false);
    } else {
      throw StateError('Unexpected details args $args');
    }
    if (args.contains('--project')) {
      response = response.replaceAll(
        transport.projectUuid,
        args[args.indexOf('--project') + 1],
      );
    }
    return transport.FakeProcessHandle(stdoutBytes: [utf8.encode(response)]);
  }
}

class DeferredDialogs implements AttachmentFileDialogs {
  final files = Completer<List<String>>();
  @override
  Future<List<String>> openFiles() => files.future;
  @override
  Future<String?> saveAs(String suggestedName) async => null;
}
