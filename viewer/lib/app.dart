/// Application root: window theme, in-app text size and the viewer shell.
///
/// Contract: viewer/spec.md sections 3 and 9, viewer/design.md sections 2 and
/// 3. The prototype workspace is injected so the same root serves the real data
/// client in later slices and synthetic panes in slice 1.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_environment.dart';
import 'controllers/announcement_controller.dart';
import 'data/settings_draft.dart';
import 'data/models.dart';
import 'data/settings_store.dart';
import 'platform/viewer_startup.dart';
import 'platform/window_state.dart';
import 'ui/app_shell.dart';
import 'ui/prototype_workspace.dart';
import 'ui/real_workspace.dart';
import 'ui/workspace_model.dart';

/// Root widget of one viewer process.
class TasksViewerApp extends StatefulWidget {
  const TasksViewerApp({
    super.key,
    required this.environment,
    this.initialSettings = const ViewerSettingsDraft(),
    this.announcements,
    this.readers,
    this.readersFor,
    this.workspaceBuilder,
    this.drafts,
    this.closeGuard,
    this.startup,
    this.onSettingsPersist,
  });

  /// Resolved paths and modes for this launch.
  final ViewerEnvironment environment;

  /// Preferences in effect before Settings is opened.
  final ViewerSettingsDraft initialSettings;

  /// Injected announcement channel. Tests pass their own double; when null the
  /// root owns a silent controller, so spoken feedback comes from the live
  /// region until the packaged Bella player lands in slice 7.
  final AnnouncementController? announcements;

  /// Real data readers. Null keeps the slice-1 prototype panes, which never
  /// touch a task store.
  final ViewerDataReader? readers;

  /// Builds the reader bundle for one environment. Settings uses it when the
  /// data root changes, so cached rows and selection start over instead of
  /// describing another store.
  final ViewerDataReader Function(ViewerEnvironment environment)? readersFor;

  /// Overrides the three panes the shell arranges; by default the root picks
  /// the prototype panes, or the real workspace when [readers] is set.
  final WorkspaceBuilder? workspaceBuilder;

  /// Recovery-draft persistence for the editor. Null keeps drafts in memory,
  /// which is what every test and the prototype workspace use; `main.dart`
  /// passes the settings-root store.
  final RecoveryDraftSink? drafts;

  /// Platform close hook, wired by `main.dart` to the window listener.
  final ViewerCloseGuard? closeGuard;

  /// Startup-registration surface; null when this build must not touch the
  /// real Startup folder (debug, test and `--test-mode` launches).
  final ViewerStartupController? startup;

  /// Persists a saved draft; a failure is reported in the status region.
  final Future<void> Function(ViewerSettingsDraft draft)? onSettingsPersist;

  @override
  State<TasksViewerApp> createState() => _TasksViewerAppState();
}

class _TasksViewerAppState extends State<TasksViewerApp> {
  late final AnnouncementController _announcements =
      widget.announcements ??
      AnnouncementController(clipPlayer: SilentClipPlayer());
  late ViewerEnvironment _environment = widget.environment;
  late ViewerSettingsDraft _settings = widget.initialSettings;
  Future<void> _settingsWrite = Future<void>.value();
  late ViewerDataReader? _readers =
      widget.readers ?? widget.readersFor?.call(widget.environment);

  @override
  void dispose() {
    if (widget.announcements == null) {
      _announcements.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: viewerWindowTitle(),
      debugShowCheckedModeBanner: false,
      theme: _theme(
        Brightness.light,
        highContrast: _settings.themeMode == ViewerThemeMode.highContrastLight,
      ),
      darkTheme: _theme(
        Brightness.dark,
        highContrast: _settings.themeMode == ViewerThemeMode.highContrastDark,
      ),
      highContrastTheme: _theme(Brightness.light, highContrast: true),
      highContrastDarkTheme: _theme(Brightness.dark, highContrast: true),
      themeMode: switch (_settings.themeMode) {
        ViewerThemeMode.system => ThemeMode.system,
        ViewerThemeMode.light ||
        ViewerThemeMode.highContrastLight => ThemeMode.light,
        ViewerThemeMode.dark ||
        ViewerThemeMode.highContrastDark => ThemeMode.dark,
      },
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: viewerTextScaler(
              MediaQuery.textScalerOf(context),
              _settings.textScalePercent,
            ),
          ),
          child: _buildShell(),
        ),
      ),
    );
  }

  /// Applies one saved draft: live preferences, a store change, then disk.
  void _applySettings(ViewerSettingsDraft draft) {
    final connectionChanged =
        draft.dataRoot != _environment.dataRoot ||
        draft.cliPath != _environment.tasksExe;
    setState(() {
      _settings = draft;
      if (connectionChanged) {
        // Every cached row and successful protocol probe belongs to the
        // previous CLI/store pair.
        _environment = _environment.withPaths(
          dataRoot: draft.dataRoot,
          tasksExe: draft.cliPath,
        );
        final build = widget.readersFor;
        if (build != null) {
          _readers = build(_environment);
        }
      }
    });
    unawaited(_persistSettings(draft));
    unawaited(_applyStartupPreference(draft));
  }

  void _applyProjectPreferences(
    ProjectStateFilter state,
    ProjectSort sort,
    SortDirection direction,
  ) {
    final draft = _settings.copyWith(
      projectState: state,
      projectSort: sort,
      projectDirection: direction,
    );
    setState(() => _settings = draft);
    unawaited(_persistSettings(draft));
  }

  Future<void> _persistSettings(ViewerSettingsDraft draft) async {
    final persist = widget.onSettingsPersist;
    if (persist == null) {
      return;
    }
    final write = _settingsWrite.then((_) => persist(draft));
    _settingsWrite = write.then<void>((_) {}, onError: (Object _) {});
    try {
      await write;
    } on Object catch (error) {
      _announcements.announceStatus(
        'Settings could not be saved: $error. They stay in effect for this '
        'session only.',
        dynamic: true,
      );
    }
  }

  /// Startup registration is applied only when Settings is saved (spec 3.1).
  Future<void> _applyStartupPreference(ViewerSettingsDraft draft) async {
    final startup = widget.startup;
    if (startup == null) {
      return;
    }
    await startup.applyDesired(draft.startWithWindows);
  }

  Widget _buildShell() {
    final readers = _readers;
    final builder =
        widget.workspaceBuilder ??
        (readers == null ? buildPrototypeWorkspace : buildViewerWorkspace);
    if (readers == null) {
      return ViewerShell(
        environment: _environment,
        announcements: _announcements,
        initialSettings: _settings,
        workspaceBuilder: builder,
        startup: widget.startup,
        actions: ViewerShellActions(onSettingsChanged: _applySettings),
      );
    }
    return ViewerWorkspaceHost(
      // A new CLI/store pair rebuilds the workspace, so selection, protocol
      // state and cached rows never describe the previous connection.
      key: ValueKey<(String?, String?)>((
        _environment.dataRoot,
        _environment.tasksExe,
      )),
      environment: _environment,
      readers: readers,
      announcements: _announcements,
      initialSettings: _settings,
      onSettingsChanged: _applySettings,
      onProjectPreferencesChanged: _applyProjectPreferences,
      startup: widget.startup,
      drafts: widget.drafts,
      closeGuard: widget.closeGuard,
    );
  }

  ThemeData _theme(Brightness brightness, {bool highContrast = false}) =>
      ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: brightness,
          contrastLevel: highContrast ? 1 : 0,
        ),
        dividerTheme: DividerThemeData(thickness: highContrast ? 2 : 1),
      );
}

/// Applies the in-app text-size choice on top of the platform text scale.
///
/// The shell resolves its pane breakpoints from the same value, so a larger
/// text size moves the layout to fewer panes instead of clipping content
/// (design.md sections 2 and 3).
TextScaler viewerTextScaler(TextScaler platform, int textScalePercent) {
  final factor = textScalePercent.clamp(50, 400) / 100;
  return TextScaler.linear(platform.scale(1) * factor);
}
