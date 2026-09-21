/// Effective viewer configuration for one launch.
///
/// Path arguments override saved settings (viewer/spec.md section 3). Test
/// launches must supply every path explicitly and never touch the real task
/// store or the real settings root.
library;

import 'dart:io';

import 'launch_args.dart';

/// Resolved paths and modes for the running viewer process.
class ViewerEnvironment {
  const ViewerEnvironment({
    required this.launchArgs,
    required this.settingsRoot,
    required this.dataRoot,
    required this.tasksExe,
  });

  final ViewerLaunchArgs launchArgs;

  /// Directory for viewer settings and recovery drafts.
  final String settingsRoot;

  /// Task store root. Null until a settings file or launch argument provides
  /// one; the viewer never creates it.
  final String? dataRoot;

  /// Absolute path of the tasks executable, or null until resolved.
  final String? tasksExe;

  bool get testMode => launchArgs.testMode;
  bool get startupLaunch => launchArgs.startup;

  static const String defaultSettingsFolderName = 'MaxLogic/tasks-viewer';

  /// Default settings root for the current user, or a repository-independent
  /// fallback when no LOCALAPPDATA is available.
  static String defaultSettingsRoot() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      return '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'MaxLogic${Platform.pathSeparator}tasks-viewer';
    }
    return '$localAppData${Platform.pathSeparator}MaxLogic'
        '${Platform.pathSeparator}tasks-viewer';
  }

  factory ViewerEnvironment.fromLaunchArgs(ViewerLaunchArgs args) {
    return ViewerEnvironment(
      launchArgs: args,
      settingsRoot: args.settingsRoot ?? defaultSettingsRoot(),
      dataRoot: args.dataRoot,
      tasksExe: args.tasksExe,
    );
  }
}
