/// Application root: window theme, in-app text size and the viewer shell.
///
/// Contract: viewer/spec.md sections 3 and 9, viewer/design.md sections 2 and
/// 3. The prototype workspace is injected so the same root serves the real data
/// client in later slices and synthetic panes in slice 1.
library;

import 'package:flutter/material.dart';

import 'app_environment.dart';
import 'controllers/announcement_controller.dart';
import 'data/settings_draft.dart';
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
    this.workspaceBuilder,
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

  /// Overrides the three panes the shell arranges; by default the root picks
  /// the prototype panes, or the real workspace when [readers] is set.
  final WorkspaceBuilder? workspaceBuilder;

  @override
  State<TasksViewerApp> createState() => _TasksViewerAppState();
}

class _TasksViewerAppState extends State<TasksViewerApp> {
  late final AnnouncementController _announcements =
      widget.announcements ??
      AnnouncementController(clipPlayer: SilentClipPlayer());
  late ViewerSettingsDraft _settings = widget.initialSettings;

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
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (_settings.themeMode) {
        ViewerThemeMode.system => ThemeMode.system,
        ViewerThemeMode.light => ThemeMode.light,
        ViewerThemeMode.dark => ThemeMode.dark,
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

  Widget _buildShell() {
    final readers = widget.readers;
    final builder =
        widget.workspaceBuilder ??
        (readers == null ? buildPrototypeWorkspace : buildViewerWorkspace);
    if (readers == null) {
      return ViewerShell(
        environment: widget.environment,
        announcements: _announcements,
        initialSettings: _settings,
        workspaceBuilder: builder,
        actions: ViewerShellActions(
          onSettingsChanged: (draft) => setState(() => _settings = draft),
        ),
      );
    }
    return ViewerWorkspaceHost(
      environment: widget.environment,
      readers: readers,
      announcements: _announcements,
      initialSettings: _settings,
      onSettingsChanged: (draft) => setState(() => _settings = draft),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    ),
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
