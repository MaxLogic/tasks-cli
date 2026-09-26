/// Clipboard actions through the real workspace (viewer/spec.md section 8 and
/// viewer/design.md walkthrough D).
///
/// Both clipboard surfaces are injected and the CLI is a double, so these
/// tests can prove the scope Ctrl+E keeps, that the button and the shortcut
/// run one handler with one outcome, that a disabled toolbar exposes its
/// reason, and that the preview dialog reads once, writes nothing and gives
/// focus back when it closes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/app_shell.dart';

import '../support/viewer_test_support.dart';

/// Project UUID the default synthetic catalog uses for its first row.
const String firstProjectId = '00000000-0000-4000-8000-000000000001';

/// One launched viewer with the doubles its clipboard actions run against.
class ClipboardViewer {
  ClipboardViewer({
    required this.harness,
    required this.enricher,
    required this.clipboard,
  });

  final RealViewerHarness harness;
  final FakeClipboardEnricher enricher;
  final FakeViewerClipboard clipboard;
}

/// Launches the real workspace with the clipboard doubles in front of the CLI.
Future<ClipboardViewer> launchClipboardViewer(
  WidgetTester tester, {
  FakeWorkspaceReads? reads,
  bool withEnricher = true,
  bool selectProject = true,
  String? clipboardText,
  ViewerSettingsDraft settings = const ViewerSettingsDraft(),
}) async {
  final enricher = FakeClipboardEnricher();
  final clipboard = FakeViewerClipboard(text: clipboardText);
  final harness = await pumpRealViewer(
    tester,
    reads: reads,
    enricher: withEnricher ? enricher : null,
    clipboard: clipboard,
    settings: settings,
  );
  if (selectProject) {
    harness.model.selectProjectIndex(0);
    await tester.pumpAndSettle();
  }
  return ClipboardViewer(
    harness: harness,
    enricher: enricher,
    clipboard: clipboard,
  );
}

/// One toolbar button of the selected project summary.
Finder toolbarButton(String label) => find.widgetWithText(FilledButton, label);

/// Puts the keyboard in the Projects list, the one region Ctrl+E serves.
Future<void> focusProjectsList(
  WidgetTester tester,
  ClipboardViewer viewer,
) async {
  await pressKey(tester, LogicalKeyboardKey.f1);
  expect(
    viewer.harness.list(ViewerRegion.projects).hasListFocus,
    isTrue,
    reason: 'Ctrl+E is scoped to the Projects list',
  );
}

void main() {
  group('the Ctrl+E scope', () {
    testWidgets('Ctrl+E enriches the selected project from the list', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester);
      viewer.enricher.answer = testClipboardEnrichment(replacements: 2);
      await focusProjectsList(tester, viewer);

      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.directProjectIds, <String>[firstProjectId]);
      expect(viewer.enricher.textProjectIds, isEmpty);
      expect(
        viewer.clipboard.reads,
        0,
        reason: 'the direct action reads the clipboard inside the CLI',
      );
      expect(viewer.harness.statusText, contains('Clipboard enriched'));
      expect(viewer.harness.statusText, contains('2 replacements'));
      expect(viewer.harness.statusText, contains('Project 1'));
    });

    testWidgets('the button and Ctrl+E run one handler with one outcome', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester);
      viewer.enricher.answer = testClipboardEnrichment(replacements: 1);
      await focusProjectsList(tester, viewer);

      final button = toolbarButton('Enrich clipboard (Alt+E)');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      final String byButton = viewer.harness.statusText;

      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.directProjectIds, <String>[
        firstProjectId,
        firstProjectId,
      ]);
      expect(viewer.harness.statusText, byButton);
    });

    testWidgets('Alt+E inside the pane runs the same action', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester);
      viewer.enricher.answer = testClipboardEnrichment(replacements: 1);
      await focusProjectsList(tester, viewer);

      await pressAlt(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.directProjectIds, <String>[firstProjectId]);
      expect(viewer.harness.statusText, contains('Clipboard enriched'));
    });

    testWidgets('Ctrl+E outside the Projects list leaves the control alone', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester);
      await focusProjectsList(tester, viewer);

      await pressKey(tester, LogicalKeyboardKey.f2);
      expect(viewer.harness.list(ViewerRegion.tasks).hasListFocus, isTrue);
      await pressControl(tester, LogicalKeyboardKey.keyE);

      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressKey(tester, LogicalKeyboardKey.f4);
      expect(viewer.harness.model.editor.isEditing, isTrue);
      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.calls, 0);
      expect(viewer.clipboard.reads, 0);
      expect(viewer.harness.model.editor.isEditing, isTrue);
    });
  });

  group('disabled controls', () {
    testWidgets('without the CLI both buttons stay and name the reason', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester, withEnricher: false);

      expect(find.textContaining('need the tasks CLI'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(toolbarButton('Enrich clipboard (Alt+E)')).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(toolbarButton('Preview enrichment (Alt+P)'))
            .onPressed,
        isNull,
      );

      await focusProjectsList(tester, viewer);
      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.calls, 0);
      expect(viewer.harness.statusText, contains('need the tasks CLI'));
    });

    testWidgets('an unavailable store names its own blocker', (
      WidgetTester tester,
    ) async {
      final reads = fakeWorkspaceReads(
        projects: <ProjectItem>[testProjectItem(1, unavailable: true)],
      );
      final viewer = await launchClipboardViewer(
        tester,
        reads: reads,
        settings: const ViewerSettingsDraft(projectState: ProjectStateFilter.all),
      );
      await focusProjectsList(tester, viewer);

      expect(
        find.textContaining('Retry the project read before enriching'),
        findsOneWidget,
      );

      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.calls, 0);
      expect(viewer.harness.statusText, contains('unavailable'));
      expect(viewer.harness.statusText, contains('database is locked'));
    });

    testWidgets('the project Retry re-enables the clipboard actions', (
      WidgetTester tester,
    ) async {
      final projects = <ProjectItem>[testProjectItem(1, unavailable: true)];
      final reads = fakeWorkspaceReads(projects: projects);
      final viewer = await launchClipboardViewer(
        tester,
        reads: reads,
        settings: const ViewerSettingsDraft(projectState: ProjectStateFilter.all),
      );
      await focusProjectsList(tester, viewer);

      expect(
        tester.widget<FilledButton>(toolbarButton('Enrich clipboard (Alt+E)')).onPressed,
        isNull,
      );
      await pressControl(tester, LogicalKeyboardKey.keyE);
      expect(viewer.enricher.calls, 0);
      expect(viewer.harness.statusText, contains('database is locked'));

      // The store comes back; the row's own Retry re-reads it.
      projects[0] = testProjectItem(1);
      final retry = find.widgetWithText(FilledButton, 'Retry');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(toolbarButton('Enrich clipboard (Alt+E)')).onPressed,
        isNotNull,
      );

      viewer.enricher.answer = testClipboardEnrichment(replacements: 2);
      await focusProjectsList(tester, viewer);
      await pressControl(tester, LogicalKeyboardKey.keyE);

      expect(viewer.enricher.directProjectIds, <String>[firstProjectId]);
      expect(viewer.harness.statusText, contains('Clipboard enriched'));
    });

    testWidgets('without a selection the toolbar asks for one', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester, selectProject: false);
      viewer.harness.model.selectProjectIndex(null);
      await tester.pumpAndSettle();

      expect(find.textContaining('Select a project'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Copy project ID (Alt+Y)'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(toolbarButton('Enrich clipboard (Alt+E)')).onPressed,
        isNull,
      );
    });
  });

  group('preview', () {
    testWidgets('preview shows both texts, writes nothing and returns focus', (
      WidgetTester tester,
    ) async {
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final viewer = await launchClipboardViewer(
        tester,
        clipboardText: 'T-1 and T-404 and T-1 again',
      );
      viewer.enricher.answer = testClipboardEnrichment(
        text: 'T-1: First task and T-404 and T-1 again',
        replacements: 2,
        unknownIds: const <int>[404],
      );
      await focusProjectsList(tester, viewer);

      await pressAlt(tester, LogicalKeyboardKey.keyP);

      expect(find.text('Enrichment preview'), findsOneWidget);
      expect(viewer.harness.focusedDebugLabel, 'enrichment preview');
      final TextField original = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('enrichment-preview-original')),
      );
      final TextField result = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('enrichment-preview-result')),
      );
      expect(original.readOnly, isTrue);
      expect(result.readOnly, isTrue);
      expect(original.controller!.text, 'T-1 and T-404 and T-1 again');
      expect(
        result.controller!.text,
        'T-1: First task and T-404 and T-1 again',
      );
      expect(find.textContaining('Replacements: 2'), findsOneWidget);
      expect(find.textContaining('Unknown IDs: 1'), findsOneWidget);
      expect(
        find.text('Unknown task IDs left unchanged: T-404.'),
        findsOneWidget,
      );
      expect(viewer.clipboard.reads, 1);
      expect(viewer.enricher.textProjectIds, <String>[firstProjectId]);
      expect(viewer.enricher.directProjectIds, isEmpty);
      expect(
        platformCalls.where(
          (MethodCall call) => call.method == 'Clipboard.setData',
        ),
        isEmpty,
        reason: 'Preview shows the enrichment; the direct action writes it',
      );

      await pressAlt(tester, LogicalKeyboardKey.keyC);

      expect(find.text('Enrichment preview'), findsNothing);
      expect(viewer.harness.focusedDebugLabel, 'projects preview enrichment');
      expect(
        viewer.clipboard.reads,
        1,
        reason: 'closing the dialog neither reads nor writes the clipboard',
      );
      expect(viewer.enricher.calls, 1);
    });

    testWidgets('a non-text clipboard opens no dialog and says so', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester, clipboardText: null);
      await focusProjectsList(tester, viewer);

      await pressAlt(tester, LogicalKeyboardKey.keyP);

      expect(find.text('Enrichment preview'), findsNothing);
      expect(viewer.harness.statusText, contains('Clipboard contains no text'));
      expect(viewer.clipboard.reads, 1);
      expect(viewer.enricher.calls, 0);
    });

    testWidgets('a clipboard that cannot be read opens nothing and says so', (
      WidgetTester tester,
    ) async {
      final viewer = await launchClipboardViewer(tester, clipboardText: 'T-1');
      viewer.clipboard.failure = const ViewerClipboardFailure(
        'The clipboard could not be read: another program holds it.',
      );
      await focusProjectsList(tester, viewer);

      await pressAlt(tester, LogicalKeyboardKey.keyP);

      expect(find.text('Enrichment preview'), findsNothing);
      expect(viewer.clipboard.reads, 1);
      expect(viewer.enricher.calls, 0);
      expect(viewer.harness.statusText, contains('another program holds it'));
    });
  });
}
