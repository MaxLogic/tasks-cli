/// Shared doubles and fixtures for viewer widget tests.
///
/// Every launch uses an injected data root, CLI path and settings root, so no
/// test can reach the real task store or the real settings folder (spec 3).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/app_environment.dart';
import 'package:tasks_viewer/controllers/announcement_catalog.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/launch_args.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/prototype_workspace.dart';

/// One playback request recorded by [RecordingClipPlayer].
class RecordedClip {
  const RecordedClip(this.clipId, this.volume);

  final String clipId;
  final double volume;
}

/// Clip-player double: records requests and never touches audio.
class RecordingClipPlayer implements ClipPlayer {
  final List<RecordedClip> playbacks = <RecordedClip>[];
  int stopCount = 0;
  bool disposed = false;

  @override
  Future<void> play(AnnouncementClip clip, {required double volume}) async {
    playbacks.add(RecordedClip(clip.id, volume));
  }

  @override
  Future<void> stop() async => stopCount += 1;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Counters for shell actions whose only slice-1 effect is being called.
class ViewerActionLog {
  int refreshes = 0;
  int enrichments = 0;
  int markDone = 0;
  int edits = 0;
  int saves = 0;
}

/// Test environment with all three injected paths.
ViewerEnvironment viewerTestEnvironment({String suffix = 'default'}) {
  final dataRoot = 'C:\\viewer-test\\$suffix\\data';
  final settingsRoot = 'C:\\viewer-test\\$suffix\\settings';
  const tasksExe = r'C:\viewer-test\tasks.exe';
  return ViewerEnvironment(
    launchArgs: ViewerLaunchArgs(
      dataRoot: dataRoot,
      tasksExe: tasksExe,
      settingsRoot: settingsRoot,
      testMode: true,
    ),
    settingsRoot: settingsRoot,
    dataRoot: dataRoot,
    tasksExe: tasksExe,
  );
}

/// One mounted shell under test.
class ViewerHarness {
  ViewerHarness({
    required this.shell,
    required this.announcements,
    required this.clipPlayer,
    required this.log,
  });

  final ViewerShellState shell;
  final AnnouncementController announcements;
  final RecordingClipPlayer clipPlayer;
  final ViewerActionLog log;

  ViewerRegionHandles handles(ViewerRegion region) => shell.handlesFor(region);

  VirtualListController list(ViewerRegion region) =>
      shell.handlesFor(region).list;

  /// Debug label of the focused node, for focus-target assertions.
  String? get focusedDebugLabel =>
      FocusManager.instance.primaryFocus?.debugLabel;

  /// Last text committed to the status region.
  String get statusText => announcements.statusText;

  /// Text exposed through the single live announcement channel.
  String? get liveText => announcements.liveRegionText;
}

/// Pumps the mounted viewer shell with synthetic panes.
Future<ViewerHarness> pumpViewer(
  WidgetTester tester, {
  ViewerSettingsDraft settings = const ViewerSettingsDraft(),
  ViewerActionLog? log,
  Size surface = const Size(1600, 900),
  double platformTextScale = 1,
  AnnouncementCatalog? catalog,
  AnnouncementMode mode = AnnouncementMode.nvdaOnly,
}) async {
  final actions = log ?? ViewerActionLog();
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = platformTextScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final clipPlayer = RecordingClipPlayer();
  final announcements = AnnouncementController(
    clipPlayer: clipPlayer,
    catalog: catalog,
    mode: mode,
  );
  addTearDown(announcements.dispose);

  await tester.pumpWidget(
    MaterialApp(
      // A fresh key makes every call start a brand-new shell: two pumps in one
      // test must not inherit the previous shell's focus or revealed pane.
      key: UniqueKey(),
      home: ViewerShell(
        environment: viewerTestEnvironment(),
        announcements: announcements,
        initialSettings: settings,
        workspaceBuilder: buildPrototypeWorkspace,
        actions: ViewerShellActions(
          onRefresh: () => actions.refreshes += 1,
          onEnrichClipboard: () => actions.enrichments += 1,
          onMarkDone: () => actions.markDone += 1,
          onEditTask: () => actions.edits += 1,
          onSave: () => actions.saves += 1,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ViewerHarness(
    shell: tester.state<ViewerShellState>(find.byType(ViewerShell)),
    announcements: announcements,
    clipPlayer: clipPlayer,
    log: actions,
  );
}

/// Presses one key and settles the frame.
Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.pumpAndSettle();
}

/// Presses a key with Ctrl held, as a Windows user would.
Future<void> pressControl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.controlLeft,
    platform: 'windows',
  );
  await tester.pumpAndSettle();
}

/// Presses a key with Alt held, as a Windows access key.
Future<void> pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.altLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft, platform: 'windows');
  await tester.pumpAndSettle();
}

/// Presses a key with Shift held, as a Windows user would.
Future<void> pressShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.shiftLeft,
    platform: 'windows',
  );
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.shiftLeft,
    platform: 'windows',
  );
  await tester.pumpAndSettle();
}

/// Resizes the surface of the mounted viewer without restarting it.
Future<void> resizeViewer(WidgetTester tester, Size surface) async {
  tester.view.physicalSize = surface;
  await tester.pumpAndSettle();
}

/// Finds one text field by the label shown above it.
Finder textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labelled "$label"',
);
