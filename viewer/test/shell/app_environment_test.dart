import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';

void main() {
  test('plain launch discovers the standard store and bundled CLI', () {
    final environment =
        ViewerEnvironment.fromLaunchArgs(const ViewerLaunchArgs())
            .withSavedSettings(const ViewerSettingsDraft())
            .withDiscoveredDefaults(
              standardDataRoot:
                  r'C:\Users\test\AppData\Local\MaxLogic\tasks-cli',
              bundledTasksExe: r'C:\bundle\tasks.exe',
              fileExists: (path) => <String>{
                r'C:\Users\test\AppData\Local\MaxLogic\tasks-cli\registry.json',
                r'C:\bundle\tasks.exe',
              }.contains(path),
            );

    expect(
      environment.dataRoot,
      r'C:\Users\test\AppData\Local\MaxLogic\tasks-cli',
    );
    expect(environment.tasksExe, r'C:\bundle\tasks.exe');
    expect(environment.needsSetup, isFalse);
  });

  test('arguments and saved settings win over discovered defaults', () {
    final environment =
        ViewerEnvironment.fromLaunchArgs(
              const ViewerLaunchArgs(dataRoot: r'C:\argument-store'),
            )
            .withSavedSettings(
              const ViewerSettingsDraft(cliPath: r'C:\saved\tasks.exe'),
            )
            .withDiscoveredDefaults(
              standardDataRoot: r'C:\standard-store',
              bundledTasksExe: r'C:\bundle\tasks.exe',
              fileExists: (_) => true,
            );

    expect(environment.dataRoot, r'C:\argument-store');
    expect(environment.tasksExe, r'C:\saved\tasks.exe');
  });

  test('discovery does not claim paths that are absent', () {
    final environment =
        ViewerEnvironment.fromLaunchArgs(
          const ViewerLaunchArgs(),
        ).withDiscoveredDefaults(
          standardDataRoot: r'C:\missing-store',
          bundledTasksExe: r'C:\missing\tasks.exe',
          fileExists: (_) => false,
        );

    expect(environment.dataRoot, isNull);
    expect(environment.tasksExe, isNull);
    expect(environment.needsSetup, isTrue);
  });
}
