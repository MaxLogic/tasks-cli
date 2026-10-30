import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/project_controller.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';

import 'cli_client_test.dart' as base;

void main() {
  for (final projects in [true, false]) {
    for (final phase in ['launch', 'stdin', 'output']) {
      test(
        '${projects ? "Projects" : "Tasks"} $phase superseded read releases queued replacement',
        () async {
          final launcher = StallingLauncher();
          final client = base.buildClient(
            launcher: launcher,
            readTimeout: const Duration(milliseconds: 80),
          );
          launcher.replyWith(base.infoDocument());
          await client.probe();
          final dynamic list = projects
              ? ProjectController(reader: client)
              : TaskController(projectId: base.projectUuid, reader: client);
          addTearDown(() => list.dispose());
          launcher.replyWith(
            projects ? base.projectsDocument() : base.tasksDocument(),
          );
          launcher.phase = phase;
          try {
            final first = list.refresh() as Future<void>;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            launcher.phase = null;
            final replacement = list.refresh() as Future<void>;
            await Future.wait([
              first,
              replacement,
            ]).timeout(const Duration(seconds: 2));
            expect(list.isLoading, isFalse);
            expect(list.firstLoadError, isNull);
            expect(list.refreshFailure, isNull);
            expect(list.totalCount, greaterThan(0));
            expect(list.announcement, isNot(contains('failed')));
          } finally {
            if (!launcher.launchGate.isCompleted) {
              launcher.launchGate.complete();
            }
            if (!launcher.stdinGate.isCompleted) launcher.stdinGate.complete();
            launcher.stalled?.kill();
          }
        },
      );
      test(
        '${projects ? "Projects" : "Tasks"} $phase deadline releases lane and retry',
        () async {
          final launcher = StallingLauncher();
          final client = base.buildClient(
            launcher: launcher,
            readTimeout: const Duration(milliseconds: 80),
          );
          launcher.replyWith(base.infoDocument());
          await client.probe();
          final dynamic list = projects
              ? ProjectController(reader: client)
              : TaskController(projectId: base.projectUuid, reader: client);
          addTearDown(() => list.dispose());
          launcher.replyWith(
            projects ? base.projectsDocument() : base.tasksDocument(),
          );
          launcher.phase = phase;
          try {
            await (list.refresh() as Future<void>).timeout(
              const Duration(seconds: 2),
            );
            expect(list.isLoading, isFalse);
            expect(list.firstLoadError, isA<ViewerTimeoutFailure>());
            expect(list.announcementSerial, 1);
            expect(list.announcement, contains('failed'));
            launcher.phase = null;
            await (list.refresh() as Future<void>).timeout(
              const Duration(seconds: 2),
            );
            expect(list.firstLoadError, isNull);
            expect(list.totalCount, greaterThan(0));
            if (phase == 'launch') {
              launcher.launchGate.complete();
              await Future<void>.delayed(const Duration(milliseconds: 20));
              expect(launcher.stalled!.killCount, 1);
              expect(launcher.stalled!.stdinBytes, isEmpty);
            } else {
              expect(launcher.stalled!.killCount, 1);
            }
          } finally {
            if (!launcher.launchGate.isCompleted) {
              launcher.launchGate.complete();
            }
            if (!launcher.stdinGate.isCompleted) launcher.stdinGate.complete();
            launcher.stalled?.kill();
          }
        },
      );
    }
  }
}

class StallingLauncher extends base.ScriptedLauncher {
  String? phase;
  final launchGate = Completer<void>();
  final stdinGate = Completer<void>();
  base.FakeProcessHandle? stalled;

  @override
  Future<ViewerProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final stall = phase;
    if (stall == null) return super.start(executable, arguments);
    final handle = base.FakeProcessHandle(answer: false);
    stalled = handle;
    if (stall == 'launch') await launchGate.future;
    return stall == 'stdin' ? StalledStdin(handle, stdinGate.future) : handle;
  }
}

class StalledStdin implements ViewerProcessHandle {
  StalledStdin(this.inner, this.gate);
  final base.FakeProcessHandle inner;
  final Future<void> gate;
  @override
  void addStdin(List<int> bytes) => inner.addStdin(bytes);
  @override
  Future<void> closeStdin() => gate;
  @override
  Stream<List<int>> get stdout => inner.stdout;
  @override
  Stream<List<int>> get stderr => inner.stderr;
  @override
  Future<int> get exitCode => inner.exitCode;
  @override
  void kill() => inner.kill();
}
