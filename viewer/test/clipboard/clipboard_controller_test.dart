/// Clipboard enrichment rules (viewer/spec.md section 8, walkthrough D).
///
/// Contract: the project scope is captured when an action starts, a second
/// invocation is ignored while one runs, the direct action never reads or
/// writes the clipboard in Dart, the whole clipboard is never reported, and
/// each outcome speaks exactly once.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/announcement_catalog.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/controllers/clipboard_controller.dart';
import 'package:tasks_viewer/data/models.dart';

import '../support/viewer_test_support.dart';

/// The bundled catalog, so this slice speaks only ids the release ships.
AnnouncementCatalog bundledCatalog() => AnnouncementCatalog.parse(
  File(AnnouncementCatalog.assetPath).readAsStringSync(),
);

/// One controller with its doubles, wired the way a window wires them.
class ClipboardHarness {
  ClipboardHarness({
    this.dataRoot = r'C:\viewer-test\clipboard\data',
    AnnouncementMode mode = AnnouncementMode.nvdaOnly,
  }) {
    announcements = AnnouncementController(
      clipPlayer: player,
      catalog: bundledCatalog(),
      mode: mode,
      progressDelay: const Duration(milliseconds: 20),
    );
    controller = ClipboardController(
      enricher: enricher,
      clipboard: clipboard,
      announcements: announcements,
      dataRoot: dataRoot,
    );
  }

  final String? dataRoot;
  final RecordingClipPlayer player = RecordingClipPlayer();
  final FakeClipboardEnricher enricher = FakeClipboardEnricher();
  final FakeViewerClipboard clipboard = FakeViewerClipboard();

  late final AnnouncementController announcements;
  late final ClipboardController controller;

  List<String> get playedClips => <String>[
    for (final clip in player.playbacks) clip.clipId,
  ];

  void dispose() {
    controller.dispose();
    announcements.dispose();
  }
}

void main() {
  group('direct enrichment', () {
    test('captures the project scope when the action starts', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      final first = testProjectItem(1);
      final second = testProjectItem(2);
      harness.enricher.latency = const Duration(milliseconds: 30);

      final running = harness.controller.enrichClipboard(first);
      // A later selection change cannot retarget the running action.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(harness.controller.blockedReason(second), isNull);
      await running;

      expect(harness.enricher.directProjectIds, <String>[first.projectId]);
      expect(harness.clipboard.reads, 0);
    });

    test('ignores a duplicate invocation while one is processing', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      final project = testProjectItem(1);
      harness.enricher.latency = const Duration(milliseconds: 40);

      final first = harness.controller.enrichClipboard(project);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(harness.controller.isRunning, isTrue);
      await harness.controller.enrichClipboard(project);
      await first;

      expect(harness.enricher.directProjectIds.length, 1);
      expect(harness.controller.isRunning, isFalse);
    });

    test('names the blocking reason for each disabled case', () async {
      final noClient = ClipboardHarness();
      addTearDown(noClient.dispose);
      final controller = ClipboardController(
        enricher: null,
        clipboard: noClient.clipboard,
        announcements: noClient.announcements,
        dataRoot: r'C:\viewer-test\data',
      );
      addTearDown(controller.dispose);
      expect(
        controller.blockedReason(testProjectItem(1)),
        contains('tasks CLI'),
      );

      final noRoot = ClipboardHarness(dataRoot: null);
      addTearDown(noRoot.dispose);
      expect(
        noRoot.controller.blockedReason(testProjectItem(1)),
        contains('data root'),
      );

      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      expect(
        harness.controller.blockedReason(null),
        contains('Select a project'),
      );
      expect(
        harness.controller.blockedReason(testProjectItem(1, unavailable: true)),
        contains('database is locked'),
      );
      expect(harness.controller.blockedReason(testProjectItem(1)), isNull);

      await harness.controller.enrichClipboard(
        testProjectItem(1, unavailable: true),
      );
      expect(harness.enricher.calls, 0);
      expect(harness.announcements.statusText, contains('unavailable'));
    });

    test('reports replacement and unknown counts, never the text', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      harness.enricher.answer = testClipboardEnrichment(
        text: 'T-1: secret clipboard contents',
        replacements: 3,
        clipboard: true,
      );

      await harness.controller.enrichClipboard(testProjectItem(4));

      expect(harness.announcements.statusText, contains('3 replacements'));
      expect(harness.announcements.statusText, contains('0 unknown IDs'));
      expect(harness.announcements.statusText, contains('Project 4'));
      expect(
        harness.announcements.statusText,
        isNot(contains('secret clipboard contents')),
      );
      expect(harness.playedClips, isEmpty);
    });

    test('plays the fixed clip for Bella and the counts for NVDA', () async {
      final bella = ClipboardHarness(mode: AnnouncementMode.bella);
      addTearDown(bella.dispose);
      bella.enricher.answer = testClipboardEnrichment(replacements: 2);
      await bella.controller.enrichClipboard(testProjectItem(1));
      expect(bella.playedClips, <String>['clipboard_enriched']);
      expect(bella.announcements.liveRegionText, isNull);

      final nvda = ClipboardHarness();
      addTearDown(nvda.dispose);
      nvda.enricher.answer = testClipboardEnrichment(replacements: 2);
      await nvda.controller.enrichClipboard(testProjectItem(1));
      expect(nvda.playedClips, isEmpty);
      expect(nvda.announcements.liveRegionText, contains('2 replacements'));
    });

    test('speaks unknown IDs once instead of the generic clip', () async {
      final harness = ClipboardHarness(mode: AnnouncementMode.bella);
      addTearDown(harness.dispose);
      harness.enricher.answer = testClipboardEnrichment(
        replacements: 1,
        unknownIds: const <int>[9, 12],
      );

      await harness.controller.enrichClipboard(testProjectItem(1));

      expect(harness.playedClips, isEmpty);
      final spoken = harness.announcements.liveRegionText;
      expect(spoken, contains('1 replacement,'));
      expect(spoken, contains('T-009, T-012'));
      expect(spoken, isNot(contains('Clipboard enriched')));
    });

    test(
      'names unknown references with keys as the CLI reported them',
      () async {
        final harness = ClipboardHarness(mode: AnnouncementMode.nvdaOnly);
        addTearDown(harness.dispose);
        harness.enricher.answer = testClipboardEnrichment(
          replacements: 1,
          unknownIds: const <int>[9],
          unknownRefs: const <String>['DAK-9', 'DS-4'],
        );

        await harness.controller.enrichClipboard(testProjectItem(1));

        final spoken = harness.announcements.liveRegionText;
        expect(spoken, contains('2 unknown IDs'));
        expect(
          spoken,
          contains('Unknown task IDs left unchanged: DAK-9, DS-4.'),
        );
      },
    );

    test('an older CLI without unknown_refs falls back to the keyed form', () {
      final result = testClipboardEnrichment(unknownIds: const <int>[9]);
      expect(result.unknownLabels('DAK'), <String>['DAK-009']);
      expect(result.unknownLabels(null), <String>['T-009']);
      final decoded = ClipboardEnrichment.fromJson(<String, Object?>{
        'text': 'x',
        'replacements': 0,
        'unknown_ids': <int>[9],
        'unknown_refs': <String>['DAK-9', 'DS-4'],
        'clipboard': false,
      });
      expect(decoded.unknownLabels('DAK'), <String>['DAK-9', 'DS-4']);
    });

    test('says Clipboard unchanged when nothing was replaced', () async {
      final harness = ClipboardHarness(mode: AnnouncementMode.bella);
      addTearDown(harness.dispose);
      harness.enricher.answer = testClipboardEnrichment();

      await harness.controller.enrichClipboard(testProjectItem(1));

      expect(harness.playedClips, <String>['clipboard_unchanged']);
      expect(harness.announcements.statusText, contains('0 replacements'));
    });

    test('surfaces a CLI failure with its own message', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      harness.enricher.failure = const ViewerCliErrorFailure(
        code: 'clipboard_changed',
        message:
            'The clipboard changed while the viewer worked; nothing was '
            'replaced. Copy the text again and retry.',
        exitCode: 1,
      );

      await harness.controller.enrichClipboard(testProjectItem(1));

      expect(harness.controller.failure, isA<ViewerCliErrorFailure>());
      expect(
        harness.announcements.statusText,
        contains('nothing was replaced'),
      );
      expect(harness.playedClips, isEmpty);
    });
  });

  group('preview', () {
    test('reads the clipboard once and sends exactly what it read', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      harness.clipboard.text = 'T-1 and T-404';
      harness.enricher.answer = testClipboardEnrichment(
        text: 'T-1: First task and T-404',
        replacements: 1,
        unknownIds: const <int>[404],
      );

      final preview = await harness.controller.previewEnrichment(
        testProjectItem(2),
      );

      expect(harness.clipboard.reads, 1);
      expect(harness.enricher.directProjectIds, isEmpty);
      expect(harness.enricher.textProjectIds, <String>[
        testProjectItem(2).projectId,
      ]);
      expect(harness.enricher.texts, <String>['T-1 and T-404']);
      expect(preview!.original, 'T-1 and T-404');
      expect(preview.enrichment.text, 'T-1: First task and T-404');
      expect(preview.projectName, 'Project 2');
      expect(preview.projectId, testProjectItem(2).projectId);
    });

    test('reports a non-text clipboard without calling the CLI', () async {
      final harness = ClipboardHarness(mode: AnnouncementMode.bella);
      addTearDown(harness.dispose);
      harness.clipboard.text = null;

      final preview = await harness.controller.previewEnrichment(
        testProjectItem(1),
      );

      expect(preview, isNull);
      expect(harness.enricher.calls, 0);
      expect(harness.playedClips, <String>['no_clipboard_text']);
      expect(harness.announcements.statusText, contains('no text'));
    });

    test(
      'reports a clipboard that cannot be read without a CLI call',
      () async {
        final harness = ClipboardHarness(mode: AnnouncementMode.bella);
        addTearDown(harness.dispose);
        harness.clipboard.failure = const ViewerClipboardFailure(
          'The clipboard could not be read: another program holds it.',
        );

        final preview = await harness.controller.previewEnrichment(
          testProjectItem(1),
        );

        expect(preview, isNull);
        expect(harness.clipboard.reads, 1);
        expect(harness.enricher.calls, 0);
        expect(harness.playedClips, isEmpty);
        expect(harness.controller.failure, isA<ViewerClipboardFailure>());
        expect(
          harness.announcements.statusText,
          contains('another program holds it'),
        );
      },
    );

    test('announces processing after the delay and the outcome once', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      harness.clipboard.text = 'T-1';
      harness.enricher.latency = const Duration(milliseconds: 80);
      harness.enricher.answer = testClipboardEnrichment(
        text: 'T-1: First task',
        replacements: 1,
      );

      final running = harness.controller.previewEnrichment(testProjectItem(1));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(harness.announcements.liveRegionText, contains('Reading'));
      final preview = await running;

      expect(preview, isNotNull);
      expect(harness.announcements.liveRegionText, contains('1 replacement,'));
      expect(harness.announcements.liveRegionText, isNot(contains('Reading')));
    });

    test('a fast preview never speaks the progress step', () async {
      final harness = ClipboardHarness();
      addTearDown(harness.dispose);
      harness.clipboard.text = 'nothing to enrich';

      await harness.controller.previewEnrichment(testProjectItem(1));

      expect(harness.announcements.hasPendingProgress, isFalse);
      expect(harness.announcements.liveRegionText, contains('0 replacements'));
    });
  });
}
