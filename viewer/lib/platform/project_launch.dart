import 'dart:io';

/// Starts a desktop application without putting a project path through a shell.
typedef ProjectProcessStart =
    Future<void> Function(String executable, List<String> arguments);

enum ProjectLaunchTarget { explorer, alacritty, terminal }

class ProjectLauncher {
  const ProjectLauncher({this.start = _startDetached});

  final ProjectProcessStart start;

  Future<void> open(ProjectLaunchTarget target, String root) async {
    if (root.isEmpty) {
      throw const FileSystemException('This project has no bound path.');
    }
    final (executable, arguments) = switch (target) {
      ProjectLaunchTarget.explorer => ('explorer.exe', <String>[root]),
      ProjectLaunchTarget.alacritty => (
        'alacritty.exe',
        <String>['--working-directory', root],
      ),
      ProjectLaunchTarget.terminal => ('wt.exe', <String>['-d', root]),
    };
    await start(executable, arguments);
  }

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }
}
