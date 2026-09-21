/// Monitor selection, window placement and the window title.
///
/// Contract: viewer/spec.md section 3.1, viewer/design.md section 2. The viewer
/// starts maximized over the whole work area of the last-used monitor when that
/// monitor is still connected, otherwise over the primary monitor's work area,
/// so the taskbar and the ordinary window controls stay usable.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// One connected monitor in logical pixels.
class ViewerDisplay {
  const ViewerDisplay({
    required this.id,
    required this.workArea,
    required this.scaleFactor,
  });

  /// Builds a monitor description from reported platform geometry.
  ///
  /// [workPosition] and [workSize] are the reported visible, taskbar-excluded
  /// values. A monitor that reports no work area falls back to its full
  /// [size] so the viewer can still place a window.
  factory ViewerDisplay.fromReportedGeometry({
    required String id,
    required Size size,
    Offset? workPosition,
    Size? workSize,
    num? scaleFactor,
  }) {
    final hasWorkArea = workPosition != null && workSize != null;
    return ViewerDisplay(
      id: id,
      workArea: hasWorkArea
          ? Rect.fromLTWH(
              workPosition.dx,
              workPosition.dy,
              workSize.width,
              workSize.height,
            )
          : Offset.zero & size,
      scaleFactor: (scaleFactor ?? 1).toDouble(),
    );
  }

  /// Platform identifier; stable while the monitor stays connected.
  final String id;

  /// Client area the viewer may cover, taskbar excluded, in logical pixels.
  final Rect workArea;

  /// Physical pixels per logical pixel on this monitor.
  final double scaleFactor;
}

/// Bounds used when the platform reports no monitor at all.
const Size viewerFallbackWindowSize = Size(1280, 800);

/// Where and how large the window is before it is maximized.
class ViewerWindowPlan {
  const ViewerWindowPlan({required this.displayId, required this.bounds});

  /// Selected monitor, or null when no monitor was reported.
  final String? displayId;

  /// Placement in logical pixels: the whole work area of [displayId].
  final Rect bounds;

  bool get hasKnownDisplay => displayId != null;
}

/// Picks the launch monitor: the last-used one when still connected, else the
/// primary monitor, else the first monitor the platform reported.
ViewerDisplay? selectViewerDisplay(
  List<ViewerDisplay> displays, {
  String? lastUsedDisplayId,
  String? primaryDisplayId,
}) {
  if (displays.isEmpty) {
    return null;
  }
  for (final display in displays) {
    if (display.id == lastUsedDisplayId) {
      return display;
    }
  }
  for (final display in displays) {
    if (display.id == primaryDisplayId) {
      return display;
    }
  }
  return displays.first;
}

/// Chooses the monitor and the maximized bounds for the next launch.
ViewerWindowPlan planViewerWindow({
  required List<ViewerDisplay> displays,
  String? lastUsedDisplayId,
  String? primaryDisplayId,
}) {
  final display = selectViewerDisplay(
    displays,
    lastUsedDisplayId: lastUsedDisplayId,
    primaryDisplayId: primaryDisplayId,
  );
  if (display == null) {
    return ViewerWindowPlan(
      displayId: null,
      bounds: Offset.zero & viewerFallbackWindowSize,
    );
  }
  return ViewerWindowPlan(displayId: display.id, bounds: display.workArea);
}

/// Moves previously restored bounds back onto a connected monitor.
///
/// Saved restored bounds can land outside every monitor after a resolution or
/// topology change (spec 3.1). The saved size is kept where it fits and the
/// window is moved into the work area of the monitor it overlaps most, or of
/// the primary monitor when it overlaps none.
Rect clampViewerBounds(
  Rect bounds, {
  required List<ViewerDisplay> displays,
  String? primaryDisplayId,
}) {
  final host =
      _bestOverlap(bounds, displays) ??
      selectViewerDisplay(displays, primaryDisplayId: primaryDisplayId);
  if (host == null) {
    return bounds;
  }
  final area = host.workArea;
  final width = bounds.width.clamp(1.0, math.max(1.0, area.width)).toDouble();
  final height = bounds.height
      .clamp(1.0, math.max(1.0, area.height))
      .toDouble();
  return Rect.fromLTWH(
    bounds.left.clamp(area.left, math.max(area.left, area.right - width)),
    bounds.top.clamp(area.top, math.max(area.top, area.bottom - height)),
    width,
    height,
  );
}

ViewerDisplay? _bestOverlap(Rect bounds, List<ViewerDisplay> displays) {
  ViewerDisplay? best;
  var bestArea = 0.0;
  for (final display in displays) {
    final overlap = bounds.intersect(display.workArea);
    if (overlap.isEmpty) {
      continue;
    }
    final area = overlap.width * overlap.height;
    if (area > bestArea) {
      bestArea = area;
      best = display;
    }
  }
  return best;
}

/// Window title (design.md section 2).
///
/// "Tasks Viewer"; the selected task's ID and project name are appended, and
/// unsaved editor changes are prefixed so an alt-tab list entry shows them.
String viewerWindowTitle({
  String? taskId,
  String? projectName,
  bool unsavedChanges = false,
}) {
  final parts = <String>[
    'Tasks Viewer',
    if (taskId != null && taskId.isNotEmpty) taskId,
    if (projectName != null && projectName.isNotEmpty) projectName,
  ];
  final title = parts.join(' - ');
  return unsavedChanges ? 'Unsaved changes - $title' : title;
}
