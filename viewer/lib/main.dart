/// Tasks Viewer entry point.
///
/// Contract: viewer/spec.md sections 3 and 3.1. One launch resolves the
/// effective paths, decides whether a `--startup` launch may open a window,
/// places the window over the selected monitor's work area and then hands over
/// to the application root. Windows startup registration, single-instance
/// activation, the settings store and Bella playback arrive in later slices.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_environment.dart';
import 'launch_args.dart';
import 'platform/window_state.dart';

Future<void> main(List<String> arguments) async {
  final ViewerLaunchArgs launchArgs;
  try {
    launchArgs = ViewerLaunchArgs.parse(arguments);
  } on LaunchArgumentError catch (error) {
    // There is no window yet, so the command line is the only place to report
    // a bad launch. A non-zero code keeps scripting failures visible.
    stderr.writeln(error.message);
    exitCode = 2;
    return;
  }

  final environment = ViewerEnvironment.fromLaunchArgs(launchArgs);

  if (launchArgs.startup && !await startupPreferenceAllowsWindow(environment)) {
    // A stale registration must exit before any window appears (spec 3.1).
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  await _showViewerWindow();
  runApp(TasksViewerApp(environment: environment));
}

/// Whether a `--startup` launch should open a window at all.
///
/// The versioned settings store arrives with the data-client slice; until then
/// the documented default (`start_with_windows` true) applies, so a launch at
/// sign-in shows the window and a saved false preference is honoured as soon as
/// it can be read.
Future<bool> startupPreferenceAllowsWindow(
  ViewerEnvironment environment,
) async {
  assert(environment.startupLaunch, 'only meaningful for --startup launches');
  return true;
}

/// Places the window on its monitor before the first frame is requested.
Future<void> _showViewerWindow() async {
  try {
    await windowManager.ensureInitialized();
    final plan = await resolveWindowPlan();
    final options = WindowOptions(
      size: plan.bounds.size,
      center: false,
      minimumSize: const Size(640, 480),
      title: viewerWindowTitle(),
      titleBarStyle: TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      // Order matters: the window is hidden until now, so placing it first
      // makes Maximize use the selected monitor's work area.
      await windowManager.setBounds(plan.bounds);
      await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    });
  } on Object catch (error) {
    // A window-management failure must not stop the viewer: the shell still
    // runs and reports problems through its status region.
    stderr.writeln('Could not prepare the viewer window: $error');
  }
}

/// Resolves the launch monitor from the connected displays.
///
/// The last-used monitor from saved settings is preferred once the settings
/// store exists; until then the primary monitor wins (spec 3.1).
Future<ViewerWindowPlan> resolveWindowPlan({String? lastUsedDisplayId}) async {
  var displays = const <ViewerDisplay>[];
  String? primaryDisplayId;
  try {
    final reported = await screenRetriever.getAllDisplays();
    primaryDisplayId = (await screenRetriever.getPrimaryDisplay()).id;
    displays = reported
        .map(
          (display) => ViewerDisplay.fromReportedGeometry(
            id: display.id,
            size: display.size,
            workPosition: display.visiblePosition,
            workSize: display.visibleSize,
            scaleFactor: display.scaleFactor,
          ),
        )
        .toList(growable: false);
  } on Object catch (error) {
    stderr.writeln('Could not read monitor geometry: $error');
  }
  return planViewerWindow(
    displays: displays,
    lastUsedDisplayId: lastUsedDisplayId,
    primaryDisplayId: primaryDisplayId,
  );
}
