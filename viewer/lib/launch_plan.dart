/// Launch outcome decisions that run before any window exists.
///
/// Contract: viewer/spec.md section 3.1. The Windows runner creates its native
/// window and then keeps its message loop alive, so a launch that must not
/// open a window has to end the process instead of returning from `main`.
library;

import 'data/settings_draft.dart';
import 'launch_args.dart';

/// What one launch does after the settings are known.
enum ViewerLaunchPlan {
  /// Claim the instance slot and show the viewer window.
  openWindow,

  /// A sign-in launch whose saved preference is off; exit without a window.
  exitWithoutWindow,
}

/// Decides whether a launch may open a window.
///
/// A `--startup` launch with the saved preference disabled is the only case
/// that must end the process before the window is shown: a stale registration
/// left behind by an older release must not open the viewer at sign-in.
ViewerLaunchPlan planViewerLaunch({
  required ViewerLaunchArgs args,
  required ViewerSettingsDraft settings,
}) => args.startup && !settings.startWithWindows
    ? ViewerLaunchPlan.exitWithoutWindow
    : ViewerLaunchPlan.openWindow;
