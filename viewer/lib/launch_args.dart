/// Viewer launch arguments.
///
/// Contract: viewer/spec.md section 3. Path arguments override saved settings.
/// `--test-mode` is test-only: debug/test launches must never create or remove
/// real Windows startup registrations.
library;

/// Thrown when the command line cannot be interpreted.
class LaunchArgumentError implements Exception {
  LaunchArgumentError(this.message);

  final String message;

  @override
  String toString() => 'LaunchArgumentError: $message';
}

/// Parsed viewer launch arguments.
class ViewerLaunchArgs {
  const ViewerLaunchArgs({
    this.dataRoot,
    this.tasksExe,
    this.settingsRoot,
    this.startup = false,
    this.testMode = false,
  });

  static const String usage =
      'Usage: tasks_viewer [--data-root <absolute path>] '
      '[--tasks-exe <absolute path>] [--settings-root <absolute path>] '
      '[--startup] [--test-mode]';

  /// Absolute task store root used instead of the saved setting.
  final String? dataRoot;

  /// Absolute path to the matching `tasks.exe` used instead of the saved
  /// setting or the bundled executable.
  final String? tasksExe;

  /// Absolute settings root used instead of the default
  /// `%LOCALAPPDATA%\MaxLogic\tasks-viewer`.
  final String? settingsRoot;

  /// True when Windows sign-in started this process.
  final bool startup;

  /// True for automated test launches; injected roots are mandatory.
  final bool testMode;

  bool get hasAllInjectedRoots =>
      dataRoot != null && tasksExe != null && settingsRoot != null;

  /// Test launches must fail closed when any injected root is missing.
  void validate() {
    if (testMode && !hasAllInjectedRoots) {
      throw LaunchArgumentError(
        'Test mode requires --data-root, --tasks-exe and --settings-root. '
        '$usage',
      );
    }
  }

  static ViewerLaunchArgs parse(List<String> argv) {
    String? dataRoot;
    String? tasksExe;
    String? settingsRoot;
    var startup = false;
    var testMode = false;

    String requirePath(List<String> args, int index, String option) {
      if (index + 1 >= args.length) {
        throw LaunchArgumentError('Missing value for $option. $usage');
      }
      final value = args[index + 1];
      if (!_isAbsolutePath(value)) {
        throw LaunchArgumentError(
          '$option requires an absolute path, got "$value". $usage',
        );
      }
      return value;
    }

    for (var i = 0; i < argv.length; i++) {
      switch (argv[i]) {
        case '--data-root':
          dataRoot = requirePath(argv, i, '--data-root');
          i++;
        case '--tasks-exe':
          tasksExe = requirePath(argv, i, '--tasks-exe');
          i++;
        case '--settings-root':
          settingsRoot = requirePath(argv, i, '--settings-root');
          i++;
        case '--startup':
          startup = true;
        case '--test-mode':
          testMode = true;
        default:
          throw LaunchArgumentError('Unknown argument "${argv[i]}". $usage');
      }
    }

    final parsed = ViewerLaunchArgs(
      dataRoot: dataRoot,
      tasksExe: tasksExe,
      settingsRoot: settingsRoot,
      startup: startup,
      testMode: testMode,
    );
    parsed.validate();
    return parsed;
  }

  /// True for absolute Windows drive paths and UNC paths.
  static bool _isAbsolutePath(String value) {
    if (value.startsWith(r'\\')) {
      return value.length > 2;
    }
    if (value.length < 4) {
      return false;
    }
    final drive = value.codeUnitAt(0);
    final isLetter =
        (drive >= 0x41 && drive <= 0x5a) || (drive >= 0x61 && drive <= 0x7a);
    return isLetter && value[1] == ':' && (value[2] == r'\' || value[2] == '/');
  }
}
