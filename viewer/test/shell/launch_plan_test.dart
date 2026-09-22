/// Launch planning for `--startup` (viewer/spec.md section 3.1).
///
/// A sign-in launch whose saved preference is off must not open a window, and
/// the Windows runner keeps its message loop alive after `main` returns, so
/// that launch ends the process instead. The packaged launch probe
/// (viewer/tool/package.ps1) holds the process-level proof; this test pins the
/// decision that selects the exit path.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/launch_plan.dart';

void main() {
  group('launch plan', () {
    test('a disabled sign-in launch exits without a window', () {
      expect(
        planViewerLaunch(
          args: const ViewerLaunchArgs(startup: true),
          settings: const ViewerSettingsDraft(startWithWindows: false),
        ),
        ViewerLaunchPlan.exitWithoutWindow,
      );
    });

    test('an enabled sign-in launch opens the window', () {
      expect(
        planViewerLaunch(
          args: const ViewerLaunchArgs(startup: true),
          settings: const ViewerSettingsDraft(startWithWindows: true),
        ),
        ViewerLaunchPlan.openWindow,
      );
    });

    test('a manual launch opens the window even when startup is disabled', () {
      expect(
        planViewerLaunch(
          args: const ViewerLaunchArgs(),
          settings: const ViewerSettingsDraft(startWithWindows: false),
        ),
        ViewerLaunchPlan.openWindow,
      );
    });
  });
}
