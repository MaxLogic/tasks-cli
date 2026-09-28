/// Clipboard enrichment state and speech for one window (viewer/spec.md
/// section 8).
///
/// The controller owns the rules that are easy to get wrong at the call site:
/// the project scope is captured when an action starts, a second invocation is
/// ignored while one is processing, the direct action never reads or writes the
/// clipboard itself, and exactly one announcement describes each outcome.
library;

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../platform/clipboard_text.dart';
import 'announcement_controller.dart';

/// What the preview dialog renders: the captured scope, the text the viewer
/// read once, and the CLI's enrichment of that copy.
class ClipboardPreview {
  const ClipboardPreview({
    required this.projectId,
    required this.projectName,
    this.projectKey,
    required this.original,
    required this.enrichment,
  });

  final String projectId;
  final String projectName;

  /// The project's key, for showing unknown IDs from older CLIs.
  final String? projectKey;

  /// The clipboard text exactly as it was read; the dialog shows it unchanged.
  final String original;

  final ClipboardEnrichment enrichment;
}

/// Clipboard actions for one window.
class ClipboardController extends ChangeNotifier {
  ClipboardController({
    required this.enricher,
    required this.clipboard,
    required this.announcements,
    this.dataRoot,
  });

  /// The CLI's enrichment commands; null disables both actions.
  final ClipboardEnricher? enricher;

  /// The clipboard Preview enrichment reads. The direct action never uses it.
  final ViewerClipboard clipboard;

  /// The one announcement channel this window speaks through.
  final AnnouncementController announcements;

  /// The data root the window was launched with; null disables both actions.
  final String? dataRoot;

  bool _running = false;
  bool _disposed = false;
  ViewerFailure? _failure;

  /// True while one clipboard action owns the connection.
  bool get isRunning => _running;

  /// The failure of the last action, or null when it succeeded or nothing ran.
  ViewerFailure? get failure => _failure;

  /// Why the toolbar cannot act on [selected], or null when it can.
  ///
  /// The cases stay distinct so the tooltip and the announcement name the real
  /// blocker instead of a generic "disabled" (spec.md section 8).
  String? blockedReason(ProjectItem? selected) {
    if (enricher == null) {
      return 'The clipboard actions need the tasks CLI. Set its path in '
          'Settings and test the connection.';
    }
    final root = dataRoot;
    if (root == null || root.isEmpty) {
      return 'No task data root is configured. Choose one in Settings before '
          'enriching the clipboard.';
    }
    if (selected == null) {
      return 'Select a project to enable Enrich clipboard and Preview '
          'enrichment.';
    }
    if (!selected.isAvailable || selected.stats == null) {
      return 'The store of ${selected.name} is unavailable: '
          '${selected.error?.message ?? 'its database could not be read'}. '
          'Retry the project read before enriching the clipboard.';
    }
    return null;
  }

  /// Ctrl+E and the Enrich clipboard button share this handler.
  ///
  /// [selected] is the row selected when the action starts: the scope is
  /// captured here, so a later selection change cannot retarget a running
  /// action, and the whole clipboard is never reported.
  Future<void> enrichClipboard(ProjectItem? selected) async {
    final blocked = blockedReason(selected);
    if (blocked != null) {
      _failure = null;
      announcements.announceStatus(blocked, dynamic: true);
      return;
    }
    if (_running) {
      return;
    }
    _running = true;
    _failure = null;
    _notify();
    announcements.announceProgress('Enriching the clipboard...');
    final project = selected!;
    try {
      final result = await enricher!.enrichClipboard(project.projectId);
      _announceDirectOutcome(project, result);
    } on ViewerFailure catch (failure) {
      _failure = failure;
      announcements.announceStatus(failure.message, dynamic: true);
    } finally {
      _running = false;
      _notify();
    }
  }

  /// The Preview enrichment button and Alt+P.
  ///
  /// Returns what the dialog renders, or null when nothing can be shown. The
  /// clipboard is read once and never written: replacing it stays the direct
  /// action's job, with the CLI's own comparison in front.
  Future<ClipboardPreview?> previewEnrichment(ProjectItem? selected) async {
    final blocked = blockedReason(selected);
    if (blocked != null) {
      _failure = null;
      announcements.announceStatus(blocked, dynamic: true);
      return null;
    }
    if (_running) {
      return null;
    }
    _running = true;
    _failure = null;
    _notify();
    announcements.announceProgress('Reading the clipboard for preview...');
    final project = selected!;
    try {
      final text = await clipboard.readText();
      if (text == null || text.isEmpty) {
        announcements.announceStatus(
          'Clipboard contains no text. Nothing was changed.',
          clipId: 'no_clipboard_text',
        );
        return null;
      }
      final result = await enricher!.enrichText(project.projectId, text);
      _announcePreviewOutcome(project, result);
      return ClipboardPreview(
        projectId: project.projectId,
        projectName: project.name,
        projectKey: project.projectKey,
        original: text,
        enrichment: result,
      );
    } on ViewerFailure catch (failure) {
      _failure = failure;
      announcements.announceStatus(failure.message, dynamic: true);
      return null;
    } finally {
      _running = false;
      _notify();
    }
  }

  /// One announcement for a direct success.
  ///
  /// Unknown IDs need attention, so they get that single dynamic sentence
  /// instead of the generic clip; Bella mode plays the fixed phrase for the
  /// other two outcomes while NVDA-only mode reads the counts.
  void _announceDirectOutcome(ProjectItem project, ClipboardEnrichment result) {
    final counts = clipboardCountsText(result);
    final unknown = result.unknownLabels(project.projectKey);
    if (unknown.isNotEmpty) {
      announcements.announceStatus(
        clipboardAttentionText(project.name, counts, unknown),
        dynamic: true,
      );
      return;
    }
    if (result.replacements == 0) {
      announcements.announceStatus(
        'Clipboard unchanged. ${project.name}: $counts.',
        clipId: 'clipboard_unchanged',
      );
      return;
    }
    announcements.announceStatus(
      'Clipboard enriched. ${project.name}: $counts.',
      clipId: 'clipboard_enriched',
    );
  }

  /// The preview outcome, announced once, never per ID.
  void _announcePreviewOutcome(
    ProjectItem project,
    ClipboardEnrichment result,
  ) {
    final counts = clipboardCountsText(result);
    final unknown = result.unknownLabels(project.projectKey);
    if (unknown.isNotEmpty) {
      announcements.announceStatus(
        clipboardAttentionText(project.name, counts, unknown),
        dynamic: true,
      );
      return;
    }
    announcements.announceStatus(
      'Preview ready. ${project.name}: $counts.',
      clipId: 'preview_ready',
    );
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// "3 replacements, 0 unknown IDs": counts only, never clipboard content.
String clipboardCountsText(ClipboardEnrichment result) =>
    '${clipboardPlural(result.replacements, 'replacement')}, '
    '${clipboardPlural(result.unknownLabels(null).length, 'unknown ID')}';

/// The one sentence an outcome that needs attention is spoken through.
///
/// It never repeats the generic clip's wording, so the event is heard once and
/// names the IDs that stayed unchanged (spec.md section 8).
String clipboardAttentionText(
  String projectName,
  String counts,
  List<String> unknown,
) => '$projectName: $counts. ${clipboardUnknownIdsText(unknown)}';

/// The unknown-ID line, shared by the dialog and the spoken sentence.
///
/// [unknown] comes from [ClipboardEnrichment.unknownLabels], so keyed
/// references read as the CLI reported them (`DAK-9`, `DS-4`).
String clipboardUnknownIdsText(List<String> unknown) =>
    'Unknown task IDs left unchanged: ${unknown.join(', ')}.';

/// "1 replacement" vs "2 replacements".
String clipboardPlural(int count, String noun) =>
    count == 1 ? '1 $noun' : '$count ${noun}s';
