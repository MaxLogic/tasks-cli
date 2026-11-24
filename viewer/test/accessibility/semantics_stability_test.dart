/// Regression tests for structural semantics stability on Windows.
///
/// Upstream Flutter issue #175041 / #195144 crashes `flutter_windows.dll` in
/// `AccessibilityBridge::CreateRemoveReparentedNodesUpdate` when semantics
/// nodes are reparented or churned during state updates and route dismissals.
/// These tests pin stable semantics node identity across StatusBar live-region
/// flips, conditional sibling changes in the Projects pane, and context-menu
/// dismissal into clipboard enrichment.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/status_bar.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import '../data/cli_client_test.dart' as transport;
import '../helpers/semantics_audit.dart';
import '../support/viewer_test_support.dart';

void main() {
  testWidgets('StatusBar keeps one semantics node across live flips', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
      mode: AnnouncementMode.off,
    );
    addTearDown(announcements.dispose);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(supportsAnnounce: false),
              child: StatusBar(controller: announcements),
            ),
          ),
        ),
      );

      announcements.announceStatus('Idle status');
      await tester.pump();
      final idleNode = tester.getSemantics(
        find.byKey(const ValueKey<String>('status-bar-text')),
      );
      final initialId = idleNode.id;
      expect(idleNode.label, 'Idle status');
      expect(idleNode.getSemanticsData().flagsCollection.isLiveRegion, isFalse);

      announcements.setMode(AnnouncementMode.nvdaOnly);
      announcements.announceStatus('Clipboard enriched.', dynamic: true);
      await tester.pump();
      final liveNode = tester.getSemantics(
        find.byKey(const ValueKey<String>('status-bar-text')),
      );
      expect(
        liveNode.id,
        initialId,
        reason: 'live-region toggle must update in place without reparenting',
      );
      expect(liveNode.label, 'Clipboard enriched.');
      expect(liveNode.getSemanticsData().flagsCollection.isLiveRegion, isTrue);

      announcements.setMode(AnnouncementMode.off);
      announcements.announceStatus('Back to quiet status');
      await tester.pump();
      final quietNode = tester.getSemantics(
        find.byKey(const ValueKey<String>('status-bar-text')),
      );
      expect(quietNode.id, initialId);
      expect(quietNode.label, 'Back to quiet status');
      expect(
        quietNode.getSemanticsData().flagsCollection.isLiveRegion,
        isFalse,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'Projects pane keeps clipboard button semantics identity across Retry and pending banner changes',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final projects = <ProjectItem>[testProjectItem(1, unavailable: true)];
        final reads = fakeWorkspaceReads(projects: projects);
        final enricher = FakeClipboardEnricher()
          ..answer = testClipboardEnrichment(replacements: 1);
        final harness = await pumpRealViewer(
          tester,
          reads: reads,
          enricher: enricher,
          settings: const ViewerSettingsDraft(
            projectState: ProjectStateFilter.all,
          ),
        );
        harness.model.selectProjectIndex(0);
        await tester.pumpAndSettle();

        final enrichFinder = find.widgetWithText(
          FilledButton,
          'Enrich clipboard (Alt+E)',
        );
        final previewFinder = find.widgetWithText(
          FilledButton,
          'Preview enrichment (Alt+P)',
        );
        final enrichIdBefore = tester.getSemantics(enrichFinder).id;
        final previewIdBefore = tester.getSemantics(previewFinder).id;
        final listElementBefore = tester.element(
          find.descendant(
            of: find.byType(ViewerProjectsPane),
            matching: find.byKey(const ValueKey<String>('projects-list')),
          ),
        );

        // Removing the conditional Retry button must not shift or recreate
        // the clipboard buttons' semantics nodes.
        projects[0] = testProjectItem(1);
        final retry = find.widgetWithText(FilledButton, 'Retry');
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(enrichFinder).id,
          enrichIdBefore,
          reason: 'removing Retry must keep Enrich button semantics identity',
        );
        expect(
          tester.getSemantics(previewFinder).id,
          previewIdBefore,
          reason: 'removing Retry must keep Preview button semantics identity',
        );
        expect(
          tester.element(
            find.descendant(
              of: find.byType(ViewerProjectsPane),
              matching: find.byKey(const ValueKey<String>('projects-list')),
            ),
          ),
          same(listElementBefore),
        );
        expectAccessibleSemantics(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'context-menu Enrich dismisses menu route immediately without lingering transition',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final enrichGate = Completer<void>();
        final enricher = FakeClipboardEnricher()
          ..answer = testClipboardEnrichment(replacements: 2);
        final reads = fakeWorkspaceReads();
        final harness = await pumpRealViewer(
          tester,
          reads: reads,
          enricher: _GatedClipboardEnricher(enricher, enrichGate),
        );
        await pressKey(tester, LogicalKeyboardKey.f1);
        await pressKey(tester, LogicalKeyboardKey.contextMenu);
        expect(find.text('Enrich clipboard (C)'), findsOneWidget);

        // Trigger Enrich from the context menu and pump only one frame: the
        // menu route must already be gone before enrichment updates run.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.pump();
        expect(
          find.text('Enrich clipboard (C)'),
          findsNothing,
          reason: 'menu must dismiss immediately with no lingering exit route',
        );
        expect(harness.model.clipboard.isRunning, isTrue);
        expectAccessibleSemantics(tester);

        enrichGate.complete();
        await tester.pumpAndSettle();
        expect(harness.model.clipboard.isRunning, isFalse);
        expect(harness.statusText, contains('Clipboard enriched'));
        expectAccessibleSemantics(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'pending remote change banner preserves Projects list and clipboard button elements',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final reads = fakeWorkspaceReads();
        final pendingClient = _MutablePendingClient();
        await tester.pumpWidget(
          TasksViewerApp(
            environment: viewerTestEnvironment(suffix: 'pending-stability'),
            readers: ViewerDataReader(
              projects: reads,
              tasks: reads,
              detail: reads,
              probe: reads.probe,
              update: pendingClient,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final listFinder = find.descendant(
          of: find.byType(ViewerProjectsPane),
          matching: find.byType(AccessibleVirtualList),
        );
        final enrichFinder = find.widgetWithText(
          FilledButton,
          'Enrich clipboard (Alt+E)',
        );
        final listElementBefore = tester.element(listFinder);
        final enrichIdBefore = tester.getSemantics(enrichFinder).id;

        pendingClient.pending = const <ViewerPendingReceipt>[
          ViewerPendingReceipt(
            '11111111-1111-4111-8111-111111111111',
            transport.projectUuid,
            'archive',
          ),
        ];
        // Trigger a rebuild through the workspace model's refresh path.
        await pressKey(tester, LogicalKeyboardKey.f5);
        expect(find.text('Check pending change'), findsOneWidget);
        expect(tester.element(listFinder), same(listElementBefore));
        expect(tester.getSemantics(enrichFinder).id, enrichIdBefore);

        pendingClient.pending = const <ViewerPendingReceipt>[];
        await pressKey(tester, LogicalKeyboardKey.f5);
        expect(find.text('Check pending change'), findsNothing);
        expect(tester.element(listFinder), same(listElementBefore));
        expect(tester.getSemantics(enrichFinder).id, enrichIdBefore);
        expectAccessibleSemantics(tester);
      } finally {
        semantics.dispose();
      }
    },
  );
}

class _MutablePendingClient extends ViewerCliClient {
  _MutablePendingClient()
    : super(environment: transport.viewerEnvironmentForTest());

  List<ViewerPendingReceipt> pending = const <ViewerPendingReceipt>[];

  @override
  List<ViewerPendingReceipt> get pendingReceipts => pending;
}

class _GatedClipboardEnricher implements ClipboardEnricher {
  _GatedClipboardEnricher(this.inner, this.gate);

  final FakeClipboardEnricher inner;
  final Completer<void> gate;

  @override
  Future<ClipboardEnrichment> enrichClipboard(String projectId) async {
    await gate.future;
    return inner.enrichClipboard(projectId);
  }

  @override
  Future<ClipboardEnrichment> enrichText(String projectId, String text) =>
      inner.enrichText(projectId, text);
}
