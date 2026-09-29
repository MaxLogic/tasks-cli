/// Row names, positions, extents and dates shared by the two collections and
/// the read views.
///
/// Contract: viewer/design.md sections 4, 5 and 7. Every string here is either
/// a tested accessible name or a locale-formatted timestamp; none of them is
/// built from task content that a screen reader could not also read in the
/// details pane.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';

/// Row extent for one row of [textLines] stacked text lines.
///
/// viewer/design.md section 2: the extent follows the active text scale, so
/// scaled text grows the row instead of being clipped. Normal density keeps
/// its 56-pixel minimum.
double viewerRowExtent(BuildContext context, {int textLines = 2}) {
  final scaler = MediaQuery.textScalerOf(context);
  final text = Theme.of(context).textTheme;
  double line(TextStyle? style, double fallbackSize, double fallbackHeight) {
    final size = scaler.scale(style?.fontSize ?? fallbackSize);
    return size * (style?.height ?? fallbackHeight);
  }

  final title = line(text.bodyMedium, 14, 1.43);
  final secondary = line(text.bodySmall, 12, 1.33);
  final lines = textLines <= 1 ? title : title + secondary * (textLines - 1);
  const verticalPadding = 12.0;
  return math.max(56, (lines + verticalPadding).ceilToDouble());
}

/// A percentage without a redundant trailing zero, for example `50` or `12.5`.
String viewerPercent(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// Accessible name of one project row (design.md section 4).
///
/// Counts never read as zeros for an unavailable project: the row says
/// `Unavailable` and carries the registry error instead.
String viewerProjectRowLabel(
  BuildContext context,
  ProjectItem item, {
  bool includeRoot = false,
}) {
  final buffer = StringBuffer(item.displayName);
  if (includeRoot && item.roots.isNotEmpty) {
    buffer
      ..write(', root ')
      ..write(viewerDisplayPath(item.roots.first));
  }
  final stats = item.stats;
  if (stats == null) {
    final error = item.error;
    buffer.write('. Unavailable');
    if (error != null) {
      buffer
        ..write('. ')
        ..write(error.message);
    }
    return buffer.toString();
  }
  buffer
    ..write('. ')
    ..write(stats.open)
    ..write(' open, ')
    ..write(stats.total)
    ..write(' total, ')
    ..write(stats.blocked)
    ..write(' blocked. ');
  final progress = stats.progressPercent;
  buffer.write(
    progress == null
        ? 'Progress not applicable'
        : 'Progress ${viewerPercent(progress)} percent',
  );
  buffer.write('. Started, first recorded task, ');
  buffer.write(
    stats.startedMs == null
        ? 'no recorded tasks'
        : viewerDate(context, stats.startedMs!),
  );
  buffer.write('. Last task write, ');
  buffer.write(
    stats.lastWriteMs == null
        ? 'no recorded tasks'
        : viewerTimestamp(context, stats.lastWriteMs!),
  );
  buffer.write('.');
  return buffer.toString();
}

/// Position label exposed next to a row name, for example `row 43 of 100000`.
String viewerRowPosition(int index, int total) => 'row ${index + 1} of $total';

/// Accessible name of one task row (design.md section 5).
String viewerTaskRowLabel(TaskItem item) {
  final buffer = StringBuffer()
    ..write(item.canonicalId)
    ..write(', ')
    ..write(item.priority)
    ..write(', ')
    ..write(viewerStatusLabel(item.status))
    ..write(', ')
    ..write(item.title);
  if (item.labels.isNotEmpty) {
    buffer
      ..write('. Labels ')
      ..write(item.labels.join(', '));
  }
  for (final part in viewerDependencyCountParts(item)) {
    buffer
      ..write('. ')
      ..write(part);
  }
  return buffer.toString();
}

/// Row wording for a task's unfinished prerequisites: the ones that keep it
/// from starting, then the `to-verify` ones that only block completion.
List<String> viewerDependencyCountParts(TaskItem item) {
  final blocking = item.blockingDependencyCount;
  final verifying = item.verifyingDependencyCount;
  return <String>[
    if (blocking > 0)
      'Waiting on $blocking ${blocking == 1 ? 'dependency' : 'dependencies'}',
    if (verifying > 0)
      '$verifying ${verifying == 1 ? 'dependency' : 'dependencies'} to verify',
  ];
}

/// Readiness wording of one dependency row (design.md section 7).
///
/// [dependentIsTerminal] is whether the task the row belongs to is itself
/// done or cancelled: a terminal task has nothing left pending, so no row
/// reads as waiting on it, whatever its prerequisites' statuses are (the CLI
/// reports zero waiting/verifying counts for it for the same reason).
String viewerDependencyReadinessText(
  DependencySummary dependency, {
  required bool dependentIsTerminal,
}) {
  if (dependentIsTerminal) {
    return 'Does not withhold readiness';
  }
  if (dependency.awaitsVerification) {
    return 'Awaiting verification; does not block starting';
  }
  if (dependency.status == 'cancelled') {
    return 'Cancelled; still withholds readiness';
  }
  return dependency.preventsReadiness
      ? 'Waiting for this dependency'
      : 'Does not withhold readiness';
}

/// Mark done hint from the loaded [dependencies], for example "Needs T-009
/// done first", or null when the done guard would accept the task.
///
/// Lists only what the guard counts (spec.md "CLI and output contract"):
/// draft, todo, in-progress, to-verify and blocked prerequisites. Done and
/// cancelled ones never block completion. The CLI stays the authority, so a
/// stale list is corrected by its refusal, not by disabling Mark done.
String? viewerMarkDoneHint(Iterable<DependencySummary> dependencies) {
  final open = <String>[
    for (final dependency in dependencies)
      if (!viewerStatusIsTerminal(dependency.status)) dependency.canonicalId,
  ];
  if (open.isEmpty) {
    return null;
  }
  final listed = open.length == 1
      ? open.single
      : '${open.sublist(0, open.length - 1).join(', ')} and ${open.last}';
  return 'Needs $listed done first';
}

/// Accessible name of one dependency row (design.md section 7).
String viewerDependencyRowLabel(
  DependencySummary dependency, {
  required bool dependentIsTerminal,
}) {
  final buffer = StringBuffer()
    ..write(dependency.canonicalId)
    ..write(', ')
    ..write(viewerStatusLabel(dependency.status))
    ..write(', ')
    ..write(dependency.title);
  buffer
    ..write('. ')
    ..write(
      viewerDependencyReadinessText(
        dependency,
        dependentIsTerminal: dependentIsTerminal,
      ),
    );
  return buffer.toString();
}

/// Accessible name of one history event row; [when] is its formatted time.
String viewerHistoryRowLabel(HistoryEvent event, String when) =>
    'Event ${event.eventId}, ${event.operation}, version '
    '${event.resultingVersion}, $when';

/// Local date and time of [epochMs], for example `21 September 2026, 10:30`.
String viewerTimestamp(BuildContext context, int epochMs) {
  final local = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  final localizations = MaterialLocalizations.of(context);
  final monthYear = localizations.formatMonthYear(local);
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: true,
  );
  return '${local.day} $monthYear, $time';
}

/// Local date of [epochMs], for example `21 September 2026`.
String viewerDate(BuildContext context, int epochMs) {
  final local = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  return '${local.day} ${MaterialLocalizations.of(context).formatMonthYear(local)}';
}

/// `UTC+02:00` style offset label, so a summary states its timezone.
String viewerTimezoneLabel(DateTime local) {
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absolute = offset.abs();
  final hours = absolute.inHours.toString().padLeft(2, '0');
  final minutes = (absolute.inMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$minutes';
}

/// [path] as a person reads it: without the Win32 verbatim prefix.
///
/// The CLI reports canonical roots such as `\\?\F:\work`; the prefix is noise
/// on screen and in a copied path. Launchers keep the raw root.
String viewerDisplayPath(String path) {
  const unc = r'\\?\UNC\';
  const verbatim = r'\\?\';
  if (path.startsWith(unc)) {
    return '\\\\${path.substring(unc.length)}';
  }
  if (path.startsWith(verbatim)) {
    return path.substring(verbatim.length);
  }
  return path;
}

/// Clipboard text as a one-line search, or null when there is nothing to
/// search for: surrounding whitespace goes, and inner line breaks become one
/// space so a copied ticket line still reads as one query.
String? viewerClipboardSearchText(String? text) {
  if (text == null) {
    return null;
  }
  final line = text.trim().replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
  return line.isEmpty ? null : line;
}
