import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';

import '../support/viewer_test_support.dart';

void main() {
  testWidgets('missing required paths open the first setup dialog', (
    WidgetTester tester,
  ) async {
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
      mode: AnnouncementMode.nvdaOnly,
    );
    addTearDown(announcements.dispose);
    const environment = ViewerEnvironment(
      launchArgs: ViewerLaunchArgs(),
      settingsRoot: r'C:\viewer-test\settings',
      dataRoot: null,
      tasksExe: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ViewerShell(
          environment: environment,
          announcements: announcements,
          workspaceBuilder: buildPrototypeWorkspace,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Set up Tasks Viewer'), findsOneWidget);
    expect(
      find.textContaining('The data root contains the project registry'),
      findsOneWidget,
    );
    expect(find.text('Save and continue (Ctrl+S)'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings cli path');
  });
}
