// Loopback equivalent of tests/support/{remote_fixture,https}.rs: a real
// tasks-server behind a private TLS proxy, with isolated signing credentials.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/attachment_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as local;

const server = String.fromEnvironment('TASKS_VIEWER_TEST_SERVER');
const hookServer = String.fromEnvironment('TASKS_VIEWER_TEST_HOOK_SERVER');

void main() {
  for (final capable in [true, false]) {
    testWidgets(
      'real remote server capability=$capable controls the attachment tab',
      (tester) async {
        if (!local.available(local.cli) ||
            !local.available(capable ? server : hookServer)) {
          return;
        }
        final fixture = (await tester.runAsync(
          () => RemoteFixture.start(capable: capable),
        ))!;
        addTearDown(fixture.close);
        final info = (await tester.runAsync(fixture.client.probe))!;
        expect(info.isRemote, isTrue);
        expect(fixture.capabilities.contains('attachments-v1'), capable);
        expect(
          info.supportsAttachments,
          capable,
          reason:
              'viewer info operations must agree with the actual server capability',
        );
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final announcements = AnnouncementController(
          clipPlayer: support.RecordingClipPlayer(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ViewerWorkspaceHost(
              environment: fixture.environment,
              readers: ViewerDataReader(
                projects: fixture.client,
                tasks: fixture.client,
                detail: fixture.client,
                update: fixture.client,
                probe: fixture.client.probe,
              ),
              announcements: announcements,
            ),
          ),
        );
        final model = tester
            .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
            .model;
        await tester.runAsync(() async {
          await model.projectList.refresh();
          model.selectProjectIndex(0);
          await model.tasks!.refresh();
          await model.openTaskIndex(0);
        });
        await tester.pumpAndSettle();
        expect(
          find.text('Attachments (0)'),
          capable ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        announcements.dispose();
      },
    );
  }
  testWidgets(
    'real remote add row Save as preserves bytes and detach removes row',
    (tester) async {
      if (!local.available(local.cli) || !local.available(server)) return;
      final fixture = (await tester.runAsync(
        () => RemoteFixture.start(capable: true),
      ))!;
      addTearDown(fixture.close);
      final h = (await tester.runAsync(() => fixture.harness()))!;
      addTearDown(h.controller.dispose);
      final source = File('${fixture.root.path}/remote.log')
        ..writeAsStringSync('Signed remote attachment \u03bb\n' * 1024);
      h.dialogs.files = [source.path];
      await tester.runAsync(h.controller.addFiles);
      expect(h.detail.attachments, hasLength(1), reason: h.controller.notice);
      expect(h.client.pendingReceipts, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentPanel(controller: h.controller)),
        ),
      );
      expect(find.textContaining('remote.log, text'), findsOneWidget);
      final output = File('${fixture.root.path}/saved.log')
        ..writeAsStringSync('replace this');
      h.dialogs.output = output.path;
      await tester.runAsync(
        () => h.controller.saveAs(h.detail.attachments.single),
      );
      expect(
        h.controller.notice,
        'Saved remote.log',
        reason: 'Save must report success before comparing bytes',
      );
      final hashes = (await tester.runAsync(
        () async => [await local.hash(source), await local.hash(output)],
      ))!;
      expect(hashes[1], hashes[0]);
      expect(hashes[0], h.detail.attachments.single.sha256);
      expect(output.readAsBytesSync(), source.readAsBytesSync());
      await tester.runAsync(
        () =>
            h.controller.detach(h.detail.attachments.single, () async => true),
      );
      await tester.pump();
      expect(h.detail.attachments, isEmpty, reason: h.controller.notice);
      expect(find.textContaining('remote.log, text'), findsNothing);
      expect(h.client.pendingReceipts, isEmpty);
      final history = (await tester.runAsync(
        () => h.command(['history', '${h.id}', '--limit', '100']),
      ))!;
      expect(
        (history['items'] as List).map((e) => e['operation']),
        containsAll(['attach', 'detach']),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'real remote lost response recovers exact request through attachment UI',
    (tester) async {
      if (!local.available(local.cli) || !local.available(server)) return;
      final fixture = (await tester.runAsync(
        () => RemoteFixture.start(capable: true),
      ))!;
      addTearDown(fixture.close);
      final h = (await tester.runAsync(fixture.harness))!;
      addTearDown(h.controller.dispose);
      final source = File('${fixture.root.path}/recover.txt')
        ..writeAsStringSync('Only one remote attachment');
      h.dialogs.files = [source.path];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentPanel(controller: h.controller)),
        ),
      );
      fixture.dropNextAttachment = true;
      await tester.runAsync(h.controller.addFiles);
      await tester.pump();
      expect(h.controller.notice, contains('Attachment outcome pending'));
      expect(h.client.pendingReceipts, hasLength(1));
      final receipt = h.client.pendingReceipts.single;
      expect(receipt.operation, 'attachment_add');
      final recovery = (await tester.runAsync(
        () => exec(local.cli, [
          '--data-root',
          h.environment.dataRoot!,
          '--format',
          'json',
          'viewer',
          'recovery',
        ]),
      ))!;
      final retained = (recovery['data']['items'] as List).single;
      expect(
        retained['task_id'],
        h.id,
        reason: 'Actual real CLI recovery JSON: ${jsonEncode(retained)}',
      );

      expect(
        receipt.taskId,
        h.id,
        reason:
            'Retained receipt must identify the task for the attachment recovery button',
      );
      expect(h.controller.pendingRequestId, receipt.requestId);
      expect(h.controller.enabled, isFalse);
      expect(find.text('Check pending change'), findsOneWidget);
      final pending = await tester.runAsync(
        () => exec(local.cli, [
          '--data-root',
          h.environment.dataRoot!,
          '--format',
          'json',
          'viewer',
          'recovery',
        ]),
      );
      expect(
        (pending!['data']['items'] as List).single['request_id'],
        receipt.requestId,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Check pending change'));
        for (var i = 0; h.controller.busy && i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      expect(h.controller.notice, 'Attachment change confirmed');
      expect(h.client.pendingReceipts, isEmpty);
      expect(h.controller.enabled, isTrue);
      expect(h.detail.attachments.single.name, 'recover.txt');
      expect(find.text('Check pending change'), findsNothing);
      final history = (await tester.runAsync(
        () => h.command(['history', '${h.id}', '--limit', '100']),
      ))!;
      expect(
        (history['items'] as List).where((e) => e['operation'] == 'attach'),
        hasLength(1),
      );
      expect(fixture.attachmentRequests, hasLength(2));
      expect(
        fixture.attachmentRequests.toSet(),
        hasLength(1),
        reason: 'Reconcile must replay the exact original request ID',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class RemoteFixture {
  RemoteFixture(
    this.root,
    this.process,
    this.proxy,
    this.environment,
    this.client,
    this.project,
    this.id,
    this.capabilities,
    this.launcher,
  );
  final Directory root;
  final Process process;
  final HttpServer proxy;
  final ViewerEnvironment environment;
  final ViewerCliClient client;
  final String project;
  final int id;
  final List<dynamic> capabilities;
  final local.TrackingLauncher launcher;
  bool dropNextAttachment = false;
  final attachmentRequests = <String>[];

  static Future<RemoteFixture> start({required bool capable}) async {
    final root = Directory.systemTemp.createTempSync(
      'viewer-remote-attachments-',
    );
    Process? process;
    HttpServer? proxy;
    try {
      final executable = capable ? server : hookServer;
      final serverRoot = '${root.path}/server';
      final clientRoot = '${root.path}/client';
      Directory(clientRoot).createSync();
      final initialized = await exec(executable, [
        '--data-root',
        serverRoot,
        'admin',
        'init',
      ]);
      final registration = await exec(local.cli, [
        '--data-root',
        clientRoot,
        'remote',
        'keygen',
        '--directory',
        '$clientRoot/client',
      ]);
      final registrationFile = File('${root.path}/registration.json')
        ..writeAsStringSync(jsonEncode(registration));
      final enrolled = await exec(executable, [
        '--data-root',
        serverRoot,
        'admin',
        'register',
        '--registration-file',
        registrationFile.path,
      ]);
      final cert = '${root.path}/ca.pem';
      final key = '${root.path}/tls-key.pem';
      final config = File('${root.path}/openssl.cnf')
        ..writeAsStringSync(
          '[req]\ndistinguished_name=dn\n[dn]\nCN=localhost\n',
        );
      final openssl = await Process.run('openssl', [
        'req',
        '-config',
        config.path,
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-keyout',
        '${root.path}/ca-key.pem',
        '-out',
        cert,
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=DNS:localhost',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      expect(openssl.exitCode, 0, reason: '${openssl.stderr}');
      final csr = '${root.path}/server.csr';
      final leaf = '${root.path}/server.pem';
      final extensions = File('${root.path}/extensions.cnf')
        ..writeAsStringSync(
          'subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n',
        );
      final request = await Process.run('openssl', [
        'req',
        '-config',
        config.path,
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        csr,
        '-subj',
        '/CN=localhost',
      ]);
      expect(request.exitCode, 0, reason: '${request.stderr}');
      final signed = await Process.run('openssl', [
        'x509',
        '-req',
        '-in',
        csr,
        '-CA',
        cert,
        '-CAkey',
        '${root.path}/ca-key.pem',
        '-CAcreateserial',
        '-out',
        leaf,
        '-days',
        '1',
        '-extfile',
        extensions.path,
      ]);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
      final context = SecurityContext()
        ..useCertificateChain(leaf)
        ..usePrivateKey(key);
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      process = await Process.start(
        executable,
        ['--data-root', serverRoot, 'serve', '--listen', '127.0.0.1:$port'],
        runInShell: false,
        environment: capable
            ? {}
            : {'TASKS_TEST_NO_ATTACHMENTS_CAPABILITY': '1'},
      );
      process.stdout.drain<void>();
      process.stderr
          .transform(utf8.decoder)
          .listen(
            (s) => File(
              '${root.path}/server.log',
            ).writeAsStringSync(s, mode: FileMode.append),
          );
      for (var attempt = 0; ; attempt++) {
        try {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(milliseconds: 100),
          );
          socket.destroy();
          break;
        } on SocketException {
          if (attempt == 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      proxy = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      List<dynamic> advertised = [];
      RemoteFixture? fixture;
      proxy.listen((request) async {
        try {
          if (fixture != null &&
              request.method == 'POST' &&
              request.uri.path.endsWith('/attachments')) {
            fixture.attachmentRequests.add(
              request.headers.value('idempotency-key') ?? 'missing-request-id',
            );
          }
          final bytes = await request.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          // Match the Rust TLS fixture: preserve signed headers, including an
          // explicit Content-Length: 0, and relay the raw response unchanged.
          final backend = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
          );
          backend.write(
            '${request.method} ${request.uri} HTTP/1.1\r\nConnection: close\r\n',
          );
          request.headers.forEach((name, values) {
            if (name != 'connection') {
              for (final value in values) {
                backend.write('$name: $value\r\n');
              }
            }
          });
          backend.write('\r\n');
          backend.add(bytes);
          await backend.flush();
          final wire = await backend
              .fold<List<int>>([], (a, b) => a..addAll(b))
              .timeout(const Duration(seconds: 20));
          backend.destroy();
          if (request.uri.path == '/v1/info') {
            final response = utf8.decode(wire);
            final start = response.indexOf('\r\n\r\n') + 4;
            advertised =
                (jsonDecode(response.substring(start))
                        as Map<String, dynamic>)['capabilities']
                    as List<dynamic>;
          }
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          if (fixture?.dropNextAttachment == true &&
              request.method == 'POST' &&
              request.uri.path.endsWith('/attachments')) {
            fixture!.dropNextAttachment = false;
          } else {
            socket.add(wire);
            await socket.flush();
          }
          await socket.close();
        } on Object catch (error) {
          File(
            '${root.path}/proxy.log',
          ).writeAsStringSync('$error\n', mode: FileMode.append);
          request.response.statusCode = 502;
          await request.response.close();
        }
      });
      await exec(local.cli, [
        '--data-root',
        clientRoot,
        'remote',
        'configure',
        '--server-url',
        'https://localhost:${proxy.port}',
        '--server-id',
        '${initialized['server_id']}',
        '--credential-id',
        '${enrolled['credential_id']}',
        '--credential-file',
        '$clientRoot/client/signing-key.pem',
        '--private-ca',
        cert,
      ]);
      final projectRoot = Directory('${root.path}/workspace')..createSync();
      final project = await exec(local.cli, [
        '--data-root',
        clientRoot,
        '--format',
        'json',
        'init',
        '--root',
        projectRoot.path,
        '--key',
        'RAT',
      ]);
      final projectId = project['data']['project_id'] as String;
      final body = File('${root.path}/body.txt')
        ..writeAsStringSync('Remote synthetic task');
      final task = await exec(local.cli, [
        '--data-root',
        clientRoot,
        '--project',
        projectId,
        '--format',
        'json',
        'create',
        '--title',
        'Remote attachment integration',
        '--body-file',
        body.path,
        '--status',
        'todo',
      ]);
      final env = ViewerEnvironment(
        launchArgs: ViewerLaunchArgs(
          dataRoot: clientRoot,
          settingsRoot: '${root.path}/settings',
          tasksExe: local.cli,
          testMode: true,
        ),
        settingsRoot: '${root.path}/settings',
        dataRoot: clientRoot,
        tasksExe: local.cli,
      );
      final launcher = local.TrackingLauncher(const SystemProcessLauncher());
      final client = ViewerCliClient(environment: env, launcher: launcher);
      fixture = RemoteFixture(
        root,
        process,
        proxy,
        env,
        client,
        projectId,
        task['data']['id'] as int,
        advertised,
        launcher,
      );
      return fixture;
    } on Object {
      await proxy?.close(force: true);
      if (process != null) {
        process.kill();
        await process.exitCode;
      }
      if (root.existsSync()) root.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    await proxy.close(force: true);
    process.kill();
    await process.exitCode;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  Future<local.Harness> harness() async {
    await client.probe();
    final h = local.Harness(
      root,
      local.cli,
      project,
      id,
      environment,
      client,
      null,
      launcher,
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
    return h;
  }
}

Future<Map<String, dynamic>> exec(String executable, List<String> args) async {
  final result = await Process.run(executable, args, runInShell: false);
  expect(result.exitCode, 0, reason: '$args\n${result.stderr}');
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}
