/// Tasks Viewer entry point.
///
/// Contract: viewer/spec.md sections 3 and 3.1. One launch loads the saved
/// settings, decides whether a `--startup` launch may open a window, claims the
/// one instance slot for this settings root, registers the packaged release in
/// the Windows Startup folder when the build may, places the window over the
/// selected monitor's work area and then hands over to the application root.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'app_environment.dart';
import 'controllers/announcement_catalog.dart';
import 'controllers/announcement_controller.dart';
import 'data/cli_client.dart';
import 'data/settings_draft.dart';
import 'data/settings_store.dart';
import 'launch_args.dart';
import 'launch_plan.dart';
import 'platform/announcement_player.dart';
import 'platform/single_instance.dart';
import 'platform/startup_registration.dart';
import 'platform/window_state.dart';
import 'platform/viewer_startup.dart';
import 'ui/real_workspace.dart';
import 'ui/workspace_model.dart';

Future<void> main(List<String> arguments) async {
  final ViewerLaunchArgs launchArgs;
  try {
    launchArgs = ViewerLaunchArgs.parse(arguments);
  } on LaunchArgumentError catch (error) {
    // There is no window yet, so the command line is the only place to report
    // a bad launch. A non-zero code keeps scripting failures visible.
    stderr.writeln(error.message);
    exit(2);
  }

  final settingsStore = SettingsStore(
    settingsRoot:
        launchArgs.settingsRoot ?? ViewerEnvironment.defaultSettingsRoot(),
  );
  final loaded = await settingsStore.load();
  final warning = loaded.warning;
  if (warning != null) {
    stderr.writeln(warning);
  }
  var currentSettings = loaded.draft;

  if (planViewerLaunch(args: launchArgs, settings: currentSettings) ==
      ViewerLaunchPlan.exitWithoutWindow) {
    // A stale registration must exit before any window appears (spec 3.1).
    // Returning from `main` is not enough: the Windows runner owns a message
    // loop that keeps the process alive until it is told to quit.
    exit(0);
  }

  final environment = ViewerEnvironment.fromLaunchArgs(
    launchArgs,
  ).withSavedSettings(currentSettings).withDiscoveredDefaults();

  // One normal instance per Windows user and settings root. A second launch
  // asks the running window to come forward instead of opening an editor.
  final ViewerInstanceClaim claim;
  try {
    claim = await ViewerInstance.claim(
      settingsRoot: environment.settingsRoot,
      onActivate: activateRunningViewer,
    );
  } on ViewerInstanceUnavailable catch (error) {
    stderr.writeln(error.message);
    exit(3);
  }
  if (!claim.isPrimary) {
    // The running instance already received the activation request; this
    // process only has to go away.
    exit(0);
  }
  final instance = claim.instance;
  if (instance == null) {
    stderr.writeln('The instance registry returned no activation channel.');
    exit(3);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // Keep the Windows accessibility tree available even when the screen reader
  // attaches after the viewer has already started.
  SemanticsBinding.instance.ensureSemantics();
  final startup = await _prepareStartupRegistration(
    launchArgs: launchArgs,
    environment: environment,
    settings: currentSettings,
  );
  final announcements = await _buildAnnouncements(
    launchArgs: launchArgs,
    settings: currentSettings,
  );
  await _showViewerWindow();
  final closeGuard = ViewerCloseGuard();
  _installCloseGuard(closeGuard, instance);
  // Recovery drafts are private task content, so they live under the settings
  // root the launch resolved and never under the store itself.
  final drafts = settingsStore.recoveryDrafts;
  runApp(
    TasksViewerApp(
      environment: environment,
      initialSettings: currentSettings,
      announcements: announcements,
      readersFor: (next) => buildViewerReaders(
        next,
        settings: () => currentSettings,
        drafts: drafts,
      ),
      drafts: drafts,
      closeGuard: closeGuard,
      startup: startup,
      onSettingsPersist: (draft) async {
        await settingsStore.save(draft);
        currentSettings = draft;
      },
    ),
  );
}

/// Makes the window ask the workspace before it closes (spec.md section 7).
///
/// A close with a dirty draft prompts Save / Discard / Cancel, and a write in
/// flight offers "Keep waiting" instead of pretending to cancel it.
void _installCloseGuard(ViewerCloseGuard guard, ViewerSingleInstance instance) {
  final listener = _ViewerCloseListener(guard, instance);
  try {
    windowManager.addListener(listener);
    unawaited(windowManager.setPreventClose(true));
  } on Object catch (error) {
    stderr.writeln('Could not install the window close guard: $error');
  }
}

/// Platform close request, routed to the live workspace model.
class _ViewerCloseListener extends WindowListener {
  _ViewerCloseListener(this.guard, this.instance);

  final ViewerCloseGuard guard;
  final ViewerSingleInstance instance;

  @override
  Future<void> onWindowClose() async {
    if (await guard()) {
      // The instance lock and the activation port die with this window.
      await instance.dispose();
      await windowManager.destroy();
    }
  }
}

/// True only for a launch that may change the real Windows Startup folder.
///
/// A debug build, a `--test-mode` launch and any process started by a test
/// harness are excluded, so tests can never create a real shortcut.
bool isPackagedReleaseLaunch(ViewerLaunchArgs launchArgs) =>
    kReleaseMode && !launchArgs.testMode && !runningUnderTestHarness();

/// True when a Flutter test harness started this process.
bool runningUnderTestHarness() =>
    (Platform.environment['FLUTTER_TEST'] ?? '').toLowerCase() == 'true';

/// Brings the already running window forward; never called in a test process.
Future<void> activateRunningViewer() async {
  try {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  } on Object catch (error) {
    stderr.writeln('Could not activate the running viewer window: $error');
  }
}

/// Reader bundle for one environment; a store change builds a new one.
ViewerDataReader buildViewerReaders(
  ViewerEnvironment environment, {
  required ViewerSettingsDraftSource settings,
  required RecoveryDraftSink drafts,
}) {
  // One client serves all three read scopes; the probe runs once before the
  // first data read, so a version mismatch is reported instead of parsed.
  final client = ViewerCliClient(
    environment: environment,
    savedSettings: settings,
  );
  return ViewerDataReader(
    projects: client,
    tasks: client,
    detail: client,
    update: client,
    clipboard: client,
    projectArchive: client,
    drafts: drafts,
    probe: client.probe,
  );
}

/// Applies the saved startup preference for a packaged release launch.
///
/// Returns null when this build must not touch the real Startup folder, which
/// is also what every test and every `--test-mode` launch gets.
Future<ViewerStartupController?> _prepareStartupRegistration({
  required ViewerLaunchArgs launchArgs,
  required ViewerEnvironment environment,
  required ViewerSettingsDraft settings,
}) async {
  if (!isPackagedReleaseLaunch(launchArgs)) {
    return null;
  }
  final ViewerStartupController controller;
  try {
    controller = ViewerStartupController(
      registrar: StartupRegistrar(
        startupDirectory: windowsStartupDirectory(),
        target: viewerStartupTargetFor(
          executablePath: Platform.resolvedExecutable,
          settingsRoot: environment.settingsRoot,
          dataRoot: environment.dataRoot,
          tasksExe: environment.tasksExe,
        ),
      ),
    );
  } on Object catch (error) {
    stderr.writeln('Could not prepare startup registration: $error');
    return null;
  }
  await controller.applyDesired(settings.startWithWindows);
  return controller;
}

/// The one announcement controller for this process.
Future<AnnouncementController> _buildAnnouncements({
  required ViewerLaunchArgs launchArgs,
  required ViewerSettingsDraft settings,
}) async {
  // Headless and test launches must never touch an audio device.
  final ClipPlayer player = launchArgs.testMode || runningUnderTestHarness()
      ? SilentClipPlayer()
      : WindowsBellaClipPlayer.withBundleAssets();
  AnnouncementCatalog? catalog;
  try {
    catalog = await AnnouncementCatalog.load(rootBundle);
  } on Object catch (error) {
    stderr.writeln('Could not load the announcement catalog: $error');
  }
  return AnnouncementController(
    clipPlayer: player,
    catalog: catalog,
    mode: settings.announcementMode,
    volume: settings.bellaVolumePercent / 100,
  );
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
