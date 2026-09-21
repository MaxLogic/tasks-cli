/// Monitor selection, placement and window-title tests (spec 3.1, design 2).
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/platform/window_state.dart';

/// Ultrawide primary monitor, taskbar along the bottom.
const Size ultrawideSize = Size(3440, 1440);
final Rect ultrawideWorkArea = const Rect.fromLTWH(0, 0, 3440, 1400);

void main() {
  final ultrawide = ViewerDisplay(
    id: 'ultrawide',
    workArea: ultrawideWorkArea,
    scaleFactor: 1,
  );
  final laptop = ViewerDisplay(
    id: 'laptop',
    workArea: const Rect.fromLTWH(3440, 0, 1920, 1040),
    scaleFactor: 1.5,
  );
  final displays = <ViewerDisplay>[ultrawide, laptop];

  group('ViewerDisplay.fromReportedGeometry', () {
    test('keeps the reported work area in logical pixels', () {
      final display = ViewerDisplay.fromReportedGeometry(
        id: 'ultrawide',
        size: ultrawideSize,
        workPosition: Offset.zero,
        workSize: const Size(3440, 1400),
        scaleFactor: 1,
      );
      expect(display.workArea, ultrawideWorkArea);
      expect(display.scaleFactor, 1);
    });

    test('falls back to the full monitor without a reported work area', () {
      final display = ViewerDisplay.fromReportedGeometry(
        id: 'ultrawide',
        size: ultrawideSize,
      );
      expect(display.workArea, Offset.zero & ultrawideSize);
      expect(display.scaleFactor, 1);
    });
  });

  group('planViewerWindow', () {
    test('prefers the last-used monitor while it is still connected', () {
      final plan = planViewerWindow(
        displays: displays,
        lastUsedDisplayId: 'laptop',
        primaryDisplayId: 'ultrawide',
      );
      expect(plan.displayId, 'laptop');
      expect(plan.bounds, laptop.workArea);
      expect(plan.hasKnownDisplay, isTrue);
    });

    test('uses the primary monitor when the last-used one is gone', () {
      final plan = planViewerWindow(
        displays: displays,
        lastUsedDisplayId: 'detached-monitor',
        primaryDisplayId: 'ultrawide',
      );
      expect(plan.displayId, 'ultrawide');
      expect(plan.bounds, ultrawideWorkArea);
    });

    test('uses the first reported monitor without a primary id', () {
      final plan = planViewerWindow(displays: displays);
      expect(plan.displayId, 'ultrawide');
    });

    test('keeps a usable window size when no monitor is reported', () {
      final plan = planViewerWindow(displays: const <ViewerDisplay>[]);
      expect(plan.displayId, isNull);
      expect(plan.bounds.size, viewerFallbackWindowSize);
      expect(plan.hasKnownDisplay, isFalse);
    });
  });

  group('clampViewerBounds', () {
    test('leaves restored bounds that already fit alone', () {
      const saved = Rect.fromLTWH(200, 120, 1200, 800);
      final clamped = clampViewerBounds(
        saved,
        displays: displays,
        primaryDisplayId: 'ultrawide',
      );
      expect(clamped, saved);
    });

    test('moves off-screen bounds onto the primary work area', () {
      const saved = Rect.fromLTWH(-500, 100, 800, 600);
      final clamped = clampViewerBounds(
        saved,
        displays: displays,
        primaryDisplayId: 'ultrawide',
      );
      expect(clamped, const Rect.fromLTWH(0, 100, 800, 600));
    });

    test('shrinks restored bounds that no longer fit', () {
      const saved = Rect.fromLTWH(0, 0, 5000, 3000);
      final clamped = clampViewerBounds(
        saved,
        displays: displays,
        primaryDisplayId: 'ultrawide',
      );
      expect(clamped, ultrawideWorkArea);
    });

    test('keeps the size on the monitor the window overlaps most', () {
      const saved = Rect.fromLTWH(3000, 0, 800, 600);
      final clamped = clampViewerBounds(
        saved,
        displays: displays,
        primaryDisplayId: 'laptop',
      );
      expect(clamped, const Rect.fromLTWH(2640, 0, 800, 600));
    });

    test('keeps bounds on a monitor placed left of the primary', () {
      final left = ViewerDisplay(
        id: 'left',
        workArea: const Rect.fromLTWH(-1920, 0, 1920, 1040),
        scaleFactor: 1,
      );
      const saved = Rect.fromLTWH(-1900, 50, 800, 600);
      final clamped = clampViewerBounds(
        saved,
        displays: <ViewerDisplay>[ultrawide, left],
        primaryDisplayId: 'ultrawide',
      );
      expect(clamped, saved);
    });

    test('returns saved bounds unchanged when nothing is connected', () {
      const saved = Rect.fromLTWH(-500, 100, 800, 600);
      expect(
        clampViewerBounds(
          saved,
          displays: const <ViewerDisplay>[],
          primaryDisplayId: 'ultrawide',
        ),
        saved,
      );
    });
  });

  group('viewerWindowTitle', () {
    test('names the window without a selection', () {
      expect(viewerWindowTitle(), 'Tasks Viewer');
    });

    test('appends the selected task id and project name', () {
      expect(
        viewerWindowTitle(taskId: 'T-042', projectName: 'PFM'),
        'Tasks Viewer - T-042 - PFM',
      );
    });

    test('prefixes unsaved editor changes', () {
      expect(
        viewerWindowTitle(
          taskId: 'T-042',
          projectName: 'PFM',
          unsavedChanges: true,
        ),
        'Unsaved changes - Tasks Viewer - T-042 - PFM',
      );
    });
  });
}
