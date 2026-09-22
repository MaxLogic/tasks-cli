/// The real three-pane workspace: project catalog, task browser and task
/// read views over one [ViewerWorkspaceModel].
///
/// Contract: viewer/spec.md sections 4.2, 4.3, 5 and 6. The shell asks for the
/// panes on every layout pass, so the model has to live above the shell: a
/// pane may not allocate a controller, start a read or lose its selection just
/// because the window was resized.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_environment.dart';
import '../controllers/announcement_controller.dart';
import '../data/settings_draft.dart';
import 'app_shell.dart';
import 'details_pane.dart';
import 'projects_pane.dart';
import 'tasks_pane.dart';
import 'workspace_model.dart';

/// Carries the one workspace model down to [buildViewerWorkspace].
///
/// A plain [InheritedWidget]: the model instance never changes for a window,
/// so reading it must not subscribe the layout to every list update.
class ViewerWorkspaceScope extends InheritedWidget {
  const ViewerWorkspaceScope({
    super.key,
    required this.model,
    required super.child,
  });

  final ViewerWorkspaceModel model;

  static ViewerWorkspaceModel of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ViewerWorkspaceScope>();
    assert(
      scope != null,
      'buildViewerWorkspace needs a ViewerWorkspaceScope above the shell.',
    );
    return scope!.model;
  }

  @override
  bool updateShouldNotify(ViewerWorkspaceScope oldWidget) =>
      !identical(model, oldWidget.model);
}

/// The three real panes bound to the model above them.
ViewerWorkspace buildViewerWorkspace(BuildContext context, ViewerShellApi api) {
  final model = ViewerWorkspaceScope.of(context);
  return ViewerWorkspace(
    projectsPane: ViewerProjectsPane(api: api, model: model),
    tasksPane: ViewerTasksPane(api: api, model: model),
    detailsPane: ViewerDetailsPane(api: api, model: model),
  );
}

/// Owns one [ViewerWorkspaceModel]: first read, then stale refresh on focus.
///
/// The model is created once here rather than by the builder, and it outlives
/// every layout pass of the shell below it.
class ViewerWorkspaceProvider extends StatefulWidget {
  const ViewerWorkspaceProvider({
    super.key,
    required this.environment,
    required this.readers,
    required this.child,
  });

  final ViewerEnvironment environment;
  final ViewerDataReader readers;

  /// Usually the shell.
  final Widget child;

  @override
  State<ViewerWorkspaceProvider> createState() =>
      _ViewerWorkspaceProviderState();
}

class _ViewerWorkspaceProviderState extends State<ViewerWorkspaceProvider>
    with WidgetsBindingObserver {
  late final ViewerWorkspaceModel _model = ViewerWorkspaceModel(
    environment: widget.environment,
    readers: widget.readers,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The handshake and the first catalog read start after the first frame, so
    // a failing CLI paints the shell and its status region first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_model.start());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model.dispose();
    super.dispose();
  }

  /// A regained window focus refreshes data that aged past the threshold
  /// (spec.md section 5). A window that was never used reads nothing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_model.refreshIfStale());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ViewerWorkspaceScope(model: _model, child: widget.child);
  }
}

/// The shell plus the real workspace and the actions the real data supports.
///
/// Slice 4 ships read views, so Edit and Mark done answer with what they did
/// not do instead of failing silently; the editor slice replaces them.
class ViewerWorkspaceHost extends StatelessWidget {
  const ViewerWorkspaceHost({
    super.key,
    required this.environment,
    required this.readers,
    required this.announcements,
    this.initialSettings,
    this.onSettingsChanged,
  });

  final ViewerEnvironment environment;
  final ViewerDataReader readers;
  final AnnouncementController announcements;
  final ViewerSettingsDraft? initialSettings;
  final ValueChanged<ViewerSettingsDraft>? onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    return ViewerWorkspaceProvider(
      environment: environment,
      readers: readers,
      child: Builder(
        builder: (context) {
          final model = ViewerWorkspaceScope.of(context);
          return ViewerShell(
            environment: environment,
            announcements: announcements,
            initialSettings: initialSettings,
            workspaceBuilder: buildViewerWorkspace,
            actions: ViewerShellActions(
              onRefresh: () => unawaited(model.refresh()),
              onBack: () {
                if (model.canGoBack) {
                  unawaited(model.goBack());
                }
              },
              onEditTask: () => announcements.announceStatus(
                viewerEditDeferredMessage,
                dynamic: true,
              ),
              onMarkDone: () => announcements.announceStatus(
                viewerMarkDoneDeferredMessage,
                dynamic: true,
              ),
              onSettingsChanged: onSettingsChanged,
            ),
          );
        },
      ),
    );
  }
}
