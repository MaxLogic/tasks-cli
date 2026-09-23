/// Effective viewer configuration for one launch.
///
/// Path arguments override saved settings (viewer/spec.md section 3). Test
/// launches must supply every path explicitly and never touch the real task
/// store or the real settings root.
library;

import 'dart:io';

import 'data/settings_draft.dart';
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
  bool get needsSetup => dataRoot == null || tasksExe == null;

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

  /// Standard task store created by the CLI migration.
  static String defaultDataRoot() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      return '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'MaxLogic${Platform.pathSeparator}tasks-cli';
    }
    return '$localAppData${Platform.pathSeparator}MaxLogic'
        '${Platform.pathSeparator}tasks-cli';
  }

  /// Matching CLI packaged beside the running viewer executable.
  static String bundledTasksExecutable() =>
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}${Platform.isWindows ? 'tasks.exe' : 'tasks'}';

  factory ViewerEnvironment.fromLaunchArgs(ViewerLaunchArgs args) {
    return ViewerEnvironment(
      launchArgs: args,
      settingsRoot: args.settingsRoot ?? defaultSettingsRoot(),
      dataRoot: args.dataRoot,
      tasksExe: args.tasksExe,
    );
  }

  /// Same launch with saved settings filling paths no argument named.
  ///
  /// Launch arguments win over saved settings (spec.md section 3), so the
  /// saved values are only a fallback for a plain double-clicked launch.
  ViewerEnvironment withSavedSettings(ViewerSettingsDraft draft) =>
      ViewerEnvironment(
        launchArgs: launchArgs,
        settingsRoot: settingsRoot,
        dataRoot: dataRoot ?? draft.dataRoot,
        tasksExe: tasksExe ?? draft.cliPath,
      );

  /// Fills a plain launch from safe, read-only conventional locations.
  ///
  /// Discovery never creates a store. The standard data root is accepted only
  /// when its registry exists, and the bundled CLI only when the file exists.
  /// Arguments and saved settings have already won before this method runs.
  ViewerEnvironment withDiscoveredDefaults({
    String? standardDataRoot,
    String? bundledTasksExe,
    bool Function(String path)? fileExists,
  }) {
    if (testMode) {
      return this;
    }
    final exists = fileExists ?? (path) => File(path).existsSync();
    final candidateRoot = standardDataRoot ?? defaultDataRoot();
    final candidateCli = bundledTasksExe ?? bundledTasksExecutable();
    final separator =
        candidateRoot.endsWith(r'\') || candidateRoot.endsWith('/')
        ? ''
        : candidateRoot.contains(r'\')
        ? r'\'
        : Platform.pathSeparator;
    final registryPath = '$candidateRoot${separator}registry.json';
    return ViewerEnvironment(
      launchArgs: launchArgs,
      settingsRoot: settingsRoot,
      dataRoot: dataRoot ?? (exists(registryPath) ? candidateRoot : null),
      tasksExe: tasksExe ?? (exists(candidateCli) ? candidateCli : null),
    );
  }

  /// Same launch pointed at the paths saved from Settings.
  ViewerEnvironment withPaths({String? dataRoot, String? tasksExe}) =>
      ViewerEnvironment(
        launchArgs: launchArgs,
        settingsRoot: settingsRoot,
        dataRoot: dataRoot,
        tasksExe: tasksExe,
      );
}
