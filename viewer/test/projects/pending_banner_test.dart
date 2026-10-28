import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/cli_client.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import '../data/cli_client_test.dart' as transport;
import '../support/viewer_test_support.dart' as support;

class PendingClient extends ViewerCliClient {
  PendingClient() : super(environment: transport.viewerEnvironmentForTest());

  @override
  List<ViewerPendingReceipt> get pendingReceipts => const [
    ViewerPendingReceipt(
      '11111111-1111-4111-8111-111111111111',
      transport.projectUuid,
      'archive',
    ),
  ];
}

void main() {
  for (final theme in [
    ViewerThemeMode.light,
    ViewerThemeMode.highContrastLight,
  ]) {
    testWidgets('pending change banner fits minimum Projects width in $theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1641, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reads = support.fakeWorkspaceReads();
      await tester.pumpWidget(
        TasksViewerApp(
          environment: support.viewerTestEnvironment(),
          readers: ViewerDataReader(
            projects: reads,
            tasks: reads,
            detail: reads,
            probe: reads.probe,
            update: PendingClient(),
          ),
          initialSettings: ViewerSettingsDraft(
            themeMode: theme,
            projectsPanePercent: 16,
            tasksPanePercent: 34,
            detailsPanePercent: 50,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pane = find.byType(ViewerProjectsPane);
      expect(tester.getSize(pane).width, closeTo(260, 1));
      expect(find.text('Check pending change'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final button = tester.getRect(
        find.widgetWithText(TextButton, 'Check pending change'),
      );
      final paneRect = tester.getRect(pane);
      expect(button.left, greaterThanOrEqualTo(paneRect.left));
      expect(button.right, lessThanOrEqualTo(paneRect.right));
    });
  }
}
