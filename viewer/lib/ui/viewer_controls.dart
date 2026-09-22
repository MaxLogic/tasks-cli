/// Small controls shared by the three real panes.
///
/// Contract: viewer/design.md sections 4 to 7. A failed read always shows its
/// actionable message and a Retry button; it never renders an empty-list
/// message, and a stale refresh keeps the last confirmed rows visible.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import 'viewer_format.dart';

/// Vertical caps for the scrolling regions of one pane body.
///
/// A pane body is a column of a scrolling filter block, a status line, the
/// virtual row list and a scrolling footer. Every region except the list is
/// capped and scrolls its own content, so the column cannot overflow however
/// short the pane is or however large the text scale is (spec.md section 9:
/// no clipping and no lost operation at 800x600 logical pixels with 200%
/// in-app text size).
class ViewerPaneBudget {
  const ViewerPaneBudget({
    required this.header,
    required this.status,
    required this.footer,
  });

  /// Cap for the filter block.
  final double header;

  /// Cap for the pane's own status line.
  final double status;

  /// Cap for the footer block: go-to-row, dividers and the summary.
  final double footer;
}

/// Shares [height] between the regions of one pane body.
///
/// The list keeps two two-line rows plus, when it is tall enough for more,
/// every pixel the other regions do not use: the caps below are generous, so
/// a region that fits naturally is never cut. A pane too short for that
/// degrades to one row, then to the rows alone, instead of overflowing.
ViewerPaneBudget viewerPaneBudgetFor(BuildContext context, double height) {
  if (height <= 0) {
    return const ViewerPaneBudget(header: 0, status: 0, footer: 0);
  }
  final row = viewerRowExtent(context, textLines: 2);
  final available = height - row * 2;
  if (available <= 0) {
    return const ViewerPaneBudget(header: 0, status: 0, footer: 0);
  }
  final status = math.min(viewerStatusReserve(context), available * 0.25);
  final rest = available - status;
  return ViewerPaneBudget(
    header: rest * 0.6,
    status: status,
    footer: rest * 0.4,
  );
}

/// Reserve for the pane's own status line: two wrapped lines of small text
/// plus their padding. The cap only has to be generous, because the region
/// scrolls when the real line is taller than the reserve.
double viewerStatusReserve(BuildContext context) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final size = theme.textTheme.bodySmall?.fontSize ?? 12;
  return scaler.scale(size) * 2.8 + 8;
}

/// One capped pane region that scrolls its own content when the cap bites.
class ViewerPaneRegion extends StatelessWidget {
  const ViewerPaneRegion({
    super.key,
    required this.maxHeight,
    required this.child,
  });

  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight < 0 ? 0 : maxHeight),
      child: SingleChildScrollView(child: child),
    );
  }
}

/// One failed read: the full message, and Retry when the pane can repeat it.
class ViewerFailureView extends StatelessWidget {
  const ViewerFailureView({
    super.key,
    required this.failure,
    this.onRetry,
    this.heading = 'Could not load task data',
  });

  final ViewerFailure failure;
  final VoidCallback? onRetry;
  final String heading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(
                child: Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                heading,
                style: theme.textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                failure.message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: 12),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of secondary status text under a region's filter area.
class ViewerStatusLine extends StatelessWidget {
  const ViewerStatusLine({
    super.key,
    required this.text,
    this.detail,
    this.warning = false,
  });

  final String text;

  /// Optional second line, for a stale refresh or a non-fatal notice.
  final String? detail;

  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailText = detail;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(text, style: theme.textTheme.bodySmall),
          if (detailText != null)
            Text(
              detailText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: warning ? theme.colorScheme.error : null,
              ),
            ),
        ],
      ),
    );
  }
}
