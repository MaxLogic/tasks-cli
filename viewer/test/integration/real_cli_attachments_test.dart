// Real local CLI boundary. Every process receives an isolated data root.
// Clipboard cases require a separate test-hooks binary and never use the desktop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/attachment_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/platform/file_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import '../support/viewer_test_support.dart' as support;

const cli = String.fromEnvironment('TASKS_VIEWER_TEST_CLI');
const clipboardCli = String.fromEnvironment('TASKS_VIEWER_TEST_CLIPBOARD_CLI');
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'real viewer info exposes the Attachments tab in the real shell',
    (tester) async {
      if (!available(cli)) return;
      final h = (await tester.runAsync(Harness.start))!;
      final info = (await tester.runAsync(h.client.probe))!;
      expect(info.supportsAttachments, isTrue);
      expect(info.isRemote, isFalse);
      expect(info.attachmentLimits['original_bytes'], 268435456);
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final announcements = AnnouncementController(
        clipPlayer: support.RecordingClipPlayer(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ViewerWorkspaceHost(
            environment: h.environment,
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
      );
      await waitFor(
        tester,
        () => find.byType(ViewerWorkspaceScope).evaluate().isNotEmpty,
      );
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      await tester.runAsync(model.projectList.refresh);
      expect(model.startupError, isNull);
      expect(model.projectList.firstLoadError, isNull);
      expect(model.projectList.isRowReady(0), isTrue);
      await tester.runAsync(() async {
        model.selectProjectIndex(0);
        await model.tasks!.refresh();
        expect(model.tasks!.isRowReady(0), isTrue);
        await model.openTaskIndex(0);
      });
      await waitFor(
        tester,
        () => find.text('Attachments (0)').evaluate().isNotEmpty,
      );
      await support.pressKey(tester, LogicalKeyboardKey.f3);
      await support.pressAlt(tester, LogicalKeyboardKey.digit5);
      expect(find.byType(AttachmentPanel), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      announcements.dispose();
    },
  );

  testWidgets('real file seam add row Save as SHA256 detach and history', (
    tester,
  ) async {
    if (!available(cli)) return;
    final h = (await tester.runAsync(Harness.start))!;
    final file = File('${h.root.path}/source.log')
      ..writeAsStringSync('Real bytes, unicode: \u03bb\n');
    h.dialogs.files = [file.path];
    await tester.runAsync(h.controller.addFiles);
    expect(h.detail.attachments, hasLength(1), reason: h.controller.notice);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: h.controller)),
      ),
    );
    expect(find.textContaining('source.log, text'), findsOneWidget);
    final item = h.detail.attachments.single;
    final output = File('${h.root.path}/saved.log')
      ..writeAsStringSync('overwrite this');
    h.dialogs.output = output.path;
    await tester.runAsync(() => h.controller.saveAs(item));
    final hashes = await tester.runAsync(
      () async => [await hash(file), await hash(output)],
    );
    expect(hashes![1], hashes[0]);
    expect(item.sha256, hashes[0]);
    expect(h.controller.notice, 'Saved source.log');
    await tester.runAsync(() => h.controller.detach(item, () async => true));
    await tester.pump();
    expect(h.detail.attachments, isEmpty);
    expect(find.textContaining('source.log, text'), findsNothing);
    final history = await tester.runAsync(
      () => h.command(['history', '${h.id}', '--limit', '100']),
    );
    final events = (history!['items'] as List).cast<Map<String, dynamic>>();
    expect(
      events.map((e) => e['operation']),
      containsAll(['attach', 'detach']),
    );
    final detached = await tester.runAsync(
      () => h.command(['attachment', 'list', '${h.id}', '--all']),
    );
    expect((detached!['items'] as List).single['detached_ms'], isA<int>());
  });

  testWidgets('real stored log Head Tail reads bounded windows in preview', (
    tester,
  ) async {
    if (!available(cli)) return;
    final h = (await tester.runAsync(Harness.start))!;
    const blockSize = 1024 * 1024;
    String block(String letter) =>
        ('$letter${'x' * 78}\n') * (blockSize ~/ 80) + 'z' * (blockSize % 80);
    final source = block('A') + block('B') + block('C');
    final file = File('${h.root.path}/large.log')..writeAsStringSync(source);
    h.dialogs.files = [file.path];
    await tester.runAsync(h.controller.addFiles);
    expect(h.detail.attachments, hasLength(1), reason: h.controller.notice);
    final item = h.detail.attachments.single;
    final path = await tester.runAsync(() => h.controller.materialize(item));
    expect(path, isNotNull);
    final windows = await tester.runAsync(
      () async => [
        await readAttachmentText(path!),
        await readAttachmentText(path, tail: true),
      ],
    );
    expect(windows!.map((v) => v.bytesRead), everyElement(blockSize));
    expect(windows[0].text, source.substring(0, blockSize));
    expect(windows[1].text, source.substring(2 * blockSize));
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: item,
          path: path!,
          announce: (_) {},
          onSaveAs: () async {},
        ),
      ),
    );
    await waitFor(tester, () => find.byType(TextField).evaluate().isNotEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      windows[0].text,
    );
    await support.pressAlt(tester, LogicalKeyboardKey.keyT);
    await waitFor(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          windows[1].text,
    );
    expect(find.textContaining('Showing last 1 MiB'), findsOneWidget);
  });

  testWidgets('real stored PNG renders dimensions and keyboard zoom', (
    tester,
  ) async {
    if (!available(cli)) return;
    final h = (await tester.runAsync(Harness.start))!;
    final file = File('${h.root.path}/pixel.png')
      ..writeAsBytesSync(base64Decode(png));
    h.dialogs.files = [file.path];
    await tester.runAsync(h.controller.addFiles);
    expect(h.detail.attachments, hasLength(1), reason: h.controller.notice);
    final item = h.detail.attachments.single;
    expect(item.kind, 'image');
    final path = await tester.runAsync(() => h.controller.materialize(item));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentPreviewDialog(
          item: item,
          path: path!,
          announce: (_) {},
          onSaveAs: () async {},
        ),
      ),
    );
    await waitFor(
      tester,
      () => find
          .bySemanticsLabel(RegExp('Image pixel.png, 1 by 1 pixels'))
          .evaluate()
          .isNotEmpty,
    );
    await support.pressControl(tester, LogicalKeyboardKey.digit1);
    expect(
      find.bySemanticsLabel('Image pixel.png, 1 by 1 pixels, zoom 100 percent'),
      findsOneWidget,
    );
    await support.pressControl(tester, LogicalKeyboardKey.equal);
    expect(
      find.bySemanticsLabel('Image pixel.png, 1 by 1 pixels, zoom 125 percent'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    semantics.dispose();
  });

  test(
    'real CLI destination_exists and original limit map typed errors without writes',
    () async {
      if (!available(cli)) return;
      final h = await Harness.start();
      final file = File('${h.root.path}/input.txt')
        ..writeAsStringSync('original');
      h.dialogs.files = [file.path];
      await h.controller.addFiles();
      final item = h.detail.attachments.single;
      final out = File('${h.root.path}/exists.txt')
        ..writeAsStringSync('keep me');
      await expectLater(
        h.client.attachmentCommand(h.project, [
          'get',
          '${h.id}',
          item.displayId,
          '--out',
          out.path,
        ]),
        throwsA(
          isA<ViewerCliErrorFailure>()
              .having((e) => e.code, 'code', 'destination_exists')
              .having((e) => e.exitCode, 'exit', 2)
              .having(
                (e) => attachmentFailureMessage(e),
                'display message',
                contains('exists'),
              ),
        ),
      );
      expect(out.readAsStringSync(), 'keep me');
      final large = File('${h.root.path}/too-large.bin');
      final handle = large.openSync(mode: FileMode.write);
      handle.truncateSync(268435457);
      handle.closeSync();
      final version = h.detail.version;
      await expectLater(
        h.client.attachmentCommand(h.project, [
          'add',
          '${h.id}',
          '--expect-version',
          '$version',
          '--file',
          large.path,
        ], mutation: true),
        throwsA(
          isA<ViewerCliErrorFailure>()
              .having((e) => e.code, 'code', 'attachment_original_too_large')
              .having((e) => e.exitCode, 'exit', 2)
              .having(
                (e) => e.message,
                'measured quantity',
                contains('268435457'),
              )
              .having((e) => e.message, 'limit', contains('268435456')),
        ),
      );
      h.dialogs.files = [large.path];
      await h.controller.addFiles();
      expect(h.controller.notice, contains('268435456'));
      await h.refresh();
      expect(h.detail.version, version);
      expect(h.detail.attachments.single.id, item.id);
    },
  );

  test(
    'real clipboard fixture inspect confirm token add empty and changed',
    () async {
      if (!available(clipboardCli)) return;
      final h = await Harness.start(clipboard: true);
      final fixture = h.clipboardFixture!;
      final file = File('${h.root.path}/pasted.txt')
        ..writeAsStringSync('paste fixture');
      final list = File('${fixture.path}/files.json')
        ..writeAsStringSync(jsonEncode([file.path]));
      var confirms = 0;
      await h.controller.paste((clip) async {
        confirms++;
        expect(clip.token, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(clip.items.single['name'], 'pasted.txt');
        return true;
      });
      expect(confirms, 1);
      expect(
        h.detail.attachments.single.name,
        'pasted.txt',
        reason: h.controller.notice,
      );
      final version = h.detail.version;
      await h.controller.paste((_) async {
        file.writeAsStringSync('changed after inspection');
        return true;
      });
      expect(h.controller.notice, 'The clipboard changed; paste again');
      list.deleteSync();
      await h.controller.paste((_) async => fail('empty must not confirm'));
      expect(h.controller.notice, 'The clipboard has no image or files');
      await h.refresh();
      expect(h.detail.version, version);
      expect(h.detail.attachments, hasLength(1));
    },
  );
}

bool available(String executable) {
  if (executable.isEmpty) {
    markTestSkipped(
      'Pass explicit TASKS_VIEWER_TEST_CLI and TASKS_VIEWER_TEST_CLIPBOARD_CLI (test-hooks).',
    );
    return false;
  }
  expect(
    File(executable).existsSync(),
    isTrue,
    reason: 'Explicit test binary must exist: $executable',
  );
  return true;
}

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Real CLI/viewer did not reach expected state');
}

Future<String> hash(File file) async {
  final result = await Process.run(
    'pwsh',
    [
      '-NoProfile',
      '-Command',
      r'(Get-FileHash -LiteralPath $env:TASKS_HASH_INPUT -Algorithm SHA256).Hash.ToLowerInvariant()',
    ],
    environment: {'TASKS_HASH_INPUT': file.path},
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (result.stdout as String).trim();
}

class Dialogs implements AttachmentFileDialogs {
  List<String> files = [];
  String? output;
  @override
  Future<List<String>> openFiles() async => files;
  @override
  Future<String?> saveAs(String suggestedName) async => output;
}

class Harness {
  Harness(
    this.root,
    this.executable,
    this.project,
    this.id,
    this.environment,
    this.client,
    this.clipboardFixture,
  );
  final Directory root;
  final String executable, project;
  final int id;
  final ViewerEnvironment environment;
  final ViewerCliClient client;
  final Directory? clipboardFixture;
  final dialogs = Dialogs();
  late TaskDetail detail;
  late AttachmentController controller;

  static Future<Harness> start({bool clipboard = false}) async {
    final root = Directory.systemTemp.createTempSync(
      'viewer-real-attachments-',
    );
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode != 32) rethrow;
        // Image mappings are released when the test process exits. The caller
        // removes its explicit TEMP root after collecting that exit.
        // ignore: avoid_print
        print('DEFERRED_FIXTURE_CLEANUP ${root.path}');
      }
    });
    final executable = clipboard ? clipboardCli : cli;
    final fixture = clipboard
        ? (Directory('${root.path}/clipboard')..createSync())
        : null;
    final store = '${root.path}/store';
    final projectRoot = Directory('${root.path}/project')..createSync();
    final init = await run(executable, [
      '--data-root',
      store,
      '--format',
      'json',
      'init',
      '--root',
      projectRoot.path,
      '--key',
      'ATT',
    ]);
    final project = init['project_id'] as String;
    final body = File('${root.path}/body.md')
      ..writeAsStringSync('Synthetic attachment integration.');
    final created = await run(executable, [
      '--data-root',
      store,
      '--project',
      project,
      '--format',
      'json',
      'create',
      '--title',
      'Real attachment integration',
      '--body-file',
      body.path,
      '--status',
      'todo',
    ]);
    final settings = '${root.path}/settings';
    final env = ViewerEnvironment(
      launchArgs: ViewerLaunchArgs(
        dataRoot: store,
        settingsRoot: settings,
        tasksExe: executable,
        testMode: true,
      ),
      settingsRoot: settings,
      dataRoot: store,
      tasksExe: executable,
    );
    final client = ViewerCliClient(
      environment: env,
      launcher: fixture == null
          ? const SystemProcessLauncher()
          : FixtureLauncher(fixture.path),
    );
    await client.probe();
    final h = Harness(
      root,
      executable,
      project,
      created['id'] as int,
      env,
      client,
      fixture,
    );
    await h.refresh();
    h.controller = AttachmentController(
      client: client,
      projectId: project,
      task: h.detail,
      refresh: h.refresh,
      announce: (_) {},
      dialogs: h.dialogs,
    );
    addTearDown(h.controller.dispose);
    return h;
  }

  Future<void> refresh() async {
    detail = await client.fetchTaskDetail(project, id);
    // Initial read occurs before the controller is allocated.
    if (_initialized) controller.task = detail;
    _initialized = true;
  }

  bool _initialized = false;

  Future<Map<String, dynamic>> command(List<String> args) => run(executable, [
    '--data-root',
    environment.dataRoot!,
    '--project',
    project,
    '--format',
    'json',
    ...args,
  ]);
}

Future<Map<String, dynamic>> run(String exe, List<String> args) async {
  final result = await Process.run(exe, args, runInShell: false);
  expect(result.exitCode, 0, reason: '$args\n${result.stderr}');
  return (jsonDecode(result.stdout as String) as Map<String, dynamic>)['data']
      as Map<String, dynamic>;
}

class FixtureLauncher implements ProcessLauncher {
  FixtureLauncher(this.fixture);
  final String fixture;
  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async => Handle(
    await Process.start(
      executable,
      arguments,
      runInShell: false,
      environment: {'TASKS_TEST_CLIPBOARD_FIXTURE': fixture},
    ),
  );
}

class Handle implements ViewerProcessHandle {
  Handle(this.process);
  final Process process;
  @override
  void addStdin(List<int> bytes) => process.stdin.add(bytes);
  @override
  Future<void> closeStdin() => process.stdin.close();
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void kill() => process.kill();
}
