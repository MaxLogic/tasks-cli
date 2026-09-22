/// Startup failure and recovery (viewer/design.md walkthrough D4).
///
/// Contract: a missing CLI names the failure and the window keeps answering
/// its own keys. The Projects region holds the focus while the failure view
/// stands in for the list, so F10 and Ctrl+, still resolve; Settings opens on
/// its first field; Retry repeats the handshake and the first catalog read.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';

import '../support/viewer_test_support.dart';

/// The failure of a missing release binary, the way the client reports it.
const ViewerFailure missingCli = ViewerExecutableNotFoundFailure(<String>[
  r'C:\bundle\tasks.exe',
]);

void main() {
  group('startup recovery', () {
    testWidgets('the failure view keeps F10 and Ctrl+, reachable', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      reads.probeFailure = missingCli;
      final harness = await pumpRealViewer(tester, reads: reads);

      expect(find.text('Could not load task data'), findsOneWidget);
      expect(find.textContaining('never searches PATH'), findsOneWidget);
      expect(
        harness.focusedDebugLabel,
        'projects region',
        reason: 'no list is mounted, so the region holds the window keys',
      );

      // design.md section 2 keeps the Hotkey help button visible in the
      // connection-error state, so F10 has to reach the shell from here.
      await pressKey(tester, LogicalKeyboardKey.f10);
      await tester.pumpAndSettle();
      expect(harness.shell.modalDepth, 1);
      await pressKey(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(harness.shell.modalDepth, 0);

      await pressControl(tester, LogicalKeyboardKey.comma);
      await tester.pumpAndSettle();
      expect(harness.shell.modalDepth, 1);
      expect(harness.focusedDebugLabel, 'settings cli path');

      await pressKey(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(harness.shell.modalDepth, 0);
      expect(find.text('Could not load task data'), findsOneWidget);
    });

    testWidgets('Retry after the CLI returns reloads and refocuses', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads();
      reads.probeFailure = missingCli;
      final harness = await pumpRealViewer(tester, reads: reads);
      expect(find.text('Could not load task data'), findsOneWidget);

      reads.probeFailure = null;
      final retry = find.widgetWithText(FilledButton, 'Retry');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(harness.model.startupError, isNull);
      expect(harness.model.projectList.totalCount, 2);

      // The window is still keyboard-driven after recovery: F1 lands on the
      // selected Projects row (design.md section 9).
      await pressKey(tester, LogicalKeyboardKey.f1);
      expect(harness.focusedDebugLabel, 'list-row-0');
      expect(harness.list(ViewerRegion.projects).focusedRowIndex, 0);
      expect(harness.model.selectedProjectId, isNotNull);
    });
  });
}
