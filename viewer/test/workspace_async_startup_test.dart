import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import 'support/viewer_test_support.dart' as support;

void main() {
  testWidgets(
    'I/O startup cancellation lets a serialized refresh finish without pumping',
    (tester) async {
      final reads = _PendingStartupReads();
      addTearDown(reads.close);
      final announcements = AnnouncementController(
        clipPlayer: support.RecordingClipPlayer(),
      );
      addTearDown(announcements.dispose);
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await support.pumpIoWidget(
        tester,
        MaterialApp(
          home: ViewerWorkspaceHost(
            environment: support.viewerTestEnvironment(),
            readers: ViewerDataReader(
              projects: reads,
              tasks: reads,
              detail: reads,
              probe: reads.probe,
            ),
            announcements: announcements,
          ),
        ),
      );
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      expect(reads.started, isTrue);
      expect(model.projectList.isLoading, isTrue);
      final completed = await tester.runAsync(
        () => model.projectList
            .refresh()
            .then((_) => true)
            .timeout(const Duration(seconds: 2), onTimeout: () => false),
      );
      expect(
        completed,
        isTrue,
        reason: 'The cancelled startup read must release the lane in runAsync',
      );
      expect(reads.cancelled, isTrue);
      expect(reads.projectRequests, hasLength(1));
      expect(model.projectList.isLoading, isFalse);
      expect(
        model.projectList.itemAt(0)?.projectId,
        reads.projects.single.projectId,
      );
      expect(model.projectList.firstLoadError, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _PendingStartupReads extends support.FakeWorkspaceReads {
  _PendingStartupReads() : super(projects: [support.testProjectItem(1)]);

  Completer<void>? _first;
  Zone? _readZone;
  Timer? _exit;
  bool get started => _first != null;
  bool cancelled = false;

  @override
  Future<ProjectPage> fetchProjects(ProjectQuery query) async {
    if (_first == null) {
      final first = _first = Completer<void>();
      _readZone = Zone.current;
      await first.future;
      throw const ViewerCancelledFailure();
    }
    return super.fetchProjects(query);
  }

  @override
  void cancelScope(String scopeKey) {
    super.cancelScope(scopeKey);
    final first = _first;
    if (scopeKey == 'projects' && first != null && !first.isCompleted) {
      cancelled = true;
      // Like process-exit/stream cleanup, cancellation must finish in the
      // original read's event loop, independently of the caller awaiting it.
      _exit ??= _readZone!.createTimer(Duration.zero, first.complete);
    }
  }

  void close() {
    _exit?.cancel();
    if (_first case final first? when !first.isCompleted) first.complete();
  }
}
