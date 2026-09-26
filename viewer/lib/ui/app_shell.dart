/// The window shell: regions, focus targets and command dispatch.
///
/// Structure follows viewer/design.md section 9:
///  * the window scope holds the reserved global shortcuts;
///  * every region installs its own scope, so a scoped access key only resolves
///    while that region has focus;
///  * a modal lives in its own route below the window scope is unreachable and
///    installs `dialogs.*` itself, so it cannot forward F1/F2/F3, Ctrl+D or
///    Ctrl+E to the lists behind it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_environment.dart';
import '../controllers/announcement_controller.dart';
import '../data/settings_draft.dart';
import '../platform/viewer_startup.dart';
import 'accessible_virtual_list.dart';
import 'commands.dart';
import 'dialog_scope.dart';
import 'keyboard_help_dialog.dart';
import 'settings_dialog.dart';
import 'status_bar.dart';
import 'viewer_controls.dart';
import 'pane_splitter.dart';

/// Focusable regions cycled by F6.
enum ViewerRegion { projects, tasks, details, status }

/// Presentation facts about a region.
extension ViewerRegionInfo on ViewerRegion {
  String get label => switch (this) {
    ViewerRegion.projects => 'Projects',
    ViewerRegion.tasks => 'Tasks',
    ViewerRegion.details => 'Task details',
    ViewerRegion.status => 'Status',
  };

  CommandScope get commandScope => switch (this) {
    ViewerRegion.projects => CommandScope.projects,
    ViewerRegion.tasks => CommandScope.tasks,
    ViewerRegion.details => CommandScope.details,
    ViewerRegion.status => CommandScope.statusBar,
  };

  /// Regions that own a filterable collection.
  bool get isCollection =>
      this == ViewerRegion.projects || this == ViewerRegion.tasks;
}

/// Focus surfaces a region exposes to the window commands.
class ViewerRegionHandles {
  ViewerRegionHandles(this.region);

  final ViewerRegion region;

  /// Focused when the region itself is selected (F1/F2/F6, empty list).
  late final FocusNode regionFocus = FocusNode(
    debugLabel: '${region.name} region',
    skipTraversal: true,
    canRequestFocus: true,
  );

  /// The region's text filter; Ctrl+F targets it.
  late final FocusNode filterFocus = FocusNode(
    debugLabel: '${region.name} filter',
  );

  /// The region's collection controller.
  late final VirtualListController list = VirtualListController();

  /// The description/body control; F3 targets it.
  late final FocusNode bodyFocus = FocusNode(
    debugLabel: '${region.name} description',
  );

  /// Find in body; Ctrl+H targets it.
  late final FocusNode findFocus = FocusNode(
    debugLabel: '${region.name} find',
    skipTraversal: true,
  );

  void dispose() {
    regionFocus.dispose();
    filterFocus.dispose();
    list.dispose();
    bodyFocus.dispose();
    findFocus.dispose();
  }
}

/// Callbacks the shell runs when a global command needs real work.
///
/// A null callback means the operation does not exist yet in this build; the
/// shell then says so instead of pretending the command succeeded.
class ViewerShellActions {
  const ViewerShellActions({
    this.onRefresh,
    this.onEditTask,
    this.onMarkDone,
    this.onEnrichClipboard,
    this.onSave,
    this.onBack,
    this.onActivate,
    this.onRetry,
    this.onDetails,
    this.onFindInBody,
    this.onNextMatch,
    this.onPreviousMatch,
    this.onCopyReference,
    this.onShowDetailsTab,
    this.onBrowseCli,
    this.onTestConnection,
    this.onRegionChanged,
    this.onSettingsChanged,
    this.onStoreChangeRequested,
  });

  final VoidCallback? onRefresh;
  final VoidCallback? onEditTask;
  final VoidCallback? onMarkDone;
  final VoidCallback? onEnrichClipboard;
  final VoidCallback? onSave;
  final VoidCallback? onBack;
  final VoidCallback? onActivate;
  final VoidCallback? onRetry;
  final VoidCallback? onDetails;
  final VoidCallback? onFindInBody;
  final VoidCallback? onNextMatch;
  final VoidCallback? onPreviousMatch;
  final VoidCallback? onCopyReference;
  final ValueChanged<String>? onShowDetailsTab;
  final VoidCallback? onBrowseCli;
  final VoidCallback? onTestConnection;
  final ValueChanged<ViewerRegion>? onRegionChanged;

  /// Asked before the window accepts a settings draft that names a different
  /// task store. False means the change was refused (a dirty editor said
  /// Cancel), so the rest of the draft is refused with it. The reader swap
  /// itself happens in the settings slice; this only keeps the guard here.
  final Future<bool> Function(String? dataRoot)? onStoreChangeRequested;

  /// Reports saved preferences to the application root so the window theme and
  /// text scale follow Settings without a restart.
  final ValueChanged<ViewerSettingsDraft>? onSettingsChanged;
}

/// Services the workspace is allowed to use.
abstract class ViewerShellApi {
  ViewerEnvironment get environment;

  ViewerRegionHandles handlesFor(ViewerRegion region);

  /// Registers pane-owned command handling for one scope.
  ///
  /// A pane owns the controls of its own scope, so the window delegates
  /// `projects.*` / `tasks.*` / `details.*` / `editor.*` ids to the pane that is
  /// currently mounted. Pass null to unregister.
  void registerScopeCommands(CommandScope scope, CommandDispatch? handler);

  /// Runs one command id as if it had been bound in [scope]'s region.
  ///
  /// Flutter resolves a [CommandIntent] at the innermost [Actions] widget, so
  /// a nested scope — the editor form inside Task details — must hand over the
  /// ids it does not own. Returning ignored there would swallow Ctrl+S, Ctrl+D
  /// and F1..F6 instead of letting the region or the window answer them
  /// (design.md section 9, dispatch precedence).
  KeyEventResult dispatchFromScope(CommandScope scope, String id);

  /// True while the window is too narrow for three panes.
  bool get isReducedLayout;

  ViewerRegion get activeRegion;

  /// True while a dialog owns the window's keys (design.md section 9).
  bool get hasOpenModal;

  void announce(String text, {String? clipId, bool dynamic = false});

  void announceProgress(String text, {String? clipId});

  /// Opens the searchable keyboard help.
  Future<void> openHelp();

  /// Opens Settings.
  Future<void> openSettings();

  /// Runs [builder] as a modal that owns [scope] and restores focus on close.
  Future<T?> showModal<T>(
    CommandScope scope,
    WidgetBuilder builder, {
    CommandDispatch? onCommand,
  });

  /// Reveals a pane in the reduced layout.
  void revealRegion(ViewerRegion region);
}

/// Keeps the window's own keys reachable while a blocking failure view has
/// replaced one pane's list.
///
/// design.md section 2 starts the window in the Projects region: its selected
/// row, or the empty list container. A fatal read failure mounts neither, so
/// the control that held the focus is unmounted and the focus falls back to
/// the route scope. The shell's shortcuts sit *above* the focused node and
/// never see a key from there, which would make F1, F10 and Ctrl+, look dead in
/// the one state design.md section 2 requires the Hotkey help button to stay
/// visible in. The region node takes that focus instead.
///
/// The claim is made once per failure, and only when no real control holds the
/// focus and no dialog is open, so a user who reached another control or a
/// modal is never pulled away.
mixin FailureViewRegionFocus<T extends StatefulWidget> on State<T> {
  bool _claimed = false;

  /// Call from `build` while the pane shows its blocking failure view.
  void claimFailureViewRegionFocus(ViewerShellApi api, ViewerRegion region) {
    if (_claimed) {
      return;
    }
    _claimed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || api.hasOpenModal) {
        return;
      }
      final focused = FocusManager.instance.primaryFocus;
      if (focused != null && focused is! FocusScopeNode) {
        return;
      }
      final node = api.handlesFor(region).regionFocus;
      if (node.hasFocus) {
        return;
      }
      node.requestFocus();
    });
  }

  /// Call from `build` once the pane shows its list again.
  void releaseFailureViewRegionFocus() => _claimed = false;
}

/// How many panes the current window can show (design.md section 2).
enum ViewerLayoutMode { threePane, twoPane, singlePane }

/// Resolves the layout for one width and in-app text scale.
ViewerLayoutMode viewerLayoutModeFor(double width, double textScale) {
  final scale = textScale.clamp(1.0, 2.0);
  if (width >= 1280 * scale) {
    return ViewerLayoutMode.threePane;
  }
  if (width >= 1000 * scale) {
    return ViewerLayoutMode.twoPane;
  }
  return ViewerLayoutMode.singlePane;
}

/// Vertical caps for the shell's own regions: the top toolbar, the reduced
/// layout's pane navigation and the bottom status bar.
///
/// The panes keep at least [viewerShellPaneFloor] logical pixels, and each
/// capped region scrolls its own content, so a large in-app text size can
/// never squeeze the work area out of the window (spec.md section 9: no
/// clipping and no lost operation at 800x600 with 200% in-app text).
class ViewerShellBudget {
  const ViewerShellBudget({
    required this.toolbar,
    required this.navigation,
    required this.status,
  });

  final double toolbar;
  final double navigation;
  final double status;
}

/// The work area never shrinks below this height.
const double viewerShellPaneFloor = 150;

ViewerShellBudget viewerShellBudgetFor(double height) {
  if (height <= 0) {
    return const ViewerShellBudget(toolbar: 0, navigation: 0, status: 0);
  }
  final available = math.max(0.0, height - viewerShellPaneFloor);
  return ViewerShellBudget(
    toolbar: available * 0.30,
    navigation: available * 0.15,
    status: available * 0.12,
  );
}

/// The three panes the workspace contributes; the shell owns their layout.
class ViewerWorkspace {
  const ViewerWorkspace({
    required this.projectsPane,
    required this.tasksPane,
    required this.detailsPane,
  });

  final Widget projectsPane;
  final Widget tasksPane;
  final Widget detailsPane;
}

/// Builds the panes for the current shell.
typedef WorkspaceBuilder =
    ViewerWorkspace Function(BuildContext context, ViewerShellApi api);

/// The application window: toolbar, region scopes, panes and status region.
class ViewerShell extends StatefulWidget {
  const ViewerShell({
    super.key,
    required this.environment,
    required this.announcements,
    required this.workspaceBuilder,
    this.actions = const ViewerShellActions(),
    this.initialSettings,
    this.startup,
  });

  final ViewerEnvironment environment;
  final AnnouncementController announcements;
  final WorkspaceBuilder workspaceBuilder;
  final ViewerShellActions actions;

  /// Preferences resolved before the first frame; Settings edits merge into
  /// this value while the viewer runs.
  final ViewerSettingsDraft? initialSettings;

  /// Startup-registration surface Settings reads and retries; null when this
  /// build must not touch the real Startup folder.
  final ViewerStartupController? startup;

  @override
  State<ViewerShell> createState() => ViewerShellState();
}

class ViewerShellState extends State<ViewerShell> implements ViewerShellApi {
  static const List<ViewerRegion> _regionOrder = <ViewerRegion>[
    ViewerRegion.projects,
    ViewerRegion.tasks,
    ViewerRegion.details,
    ViewerRegion.status,
  ];

  late final ViewerRegionHandles _projects = ViewerRegionHandles(
    ViewerRegion.projects,
  );
  late final ViewerRegionHandles _tasks = ViewerRegionHandles(
    ViewerRegion.tasks,
  );
  late final ViewerRegionHandles _details = ViewerRegionHandles(
    ViewerRegion.details,
  );
  late final ViewerRegionHandles _status = ViewerRegionHandles(
    ViewerRegion.status,
  );

  ViewerRegion _activeRegion = ViewerRegion.projects;
  ViewerRegion _lastCollectionRegion = ViewerRegion.projects;
  ViewerRegion _revealedRegion = ViewerRegion.projects;
  int _modalDepth = 0;
  ViewerLayoutMode _layoutMode = ViewerLayoutMode.threePane;
  bool _detailsRequested = false;
  bool _initialSetupOpened = false;

  /// One key per pane, so a layout change *moves* a pane instead of rebuilding
  /// it and losing its selection, filters and scroll position (design.md
  /// section 2: preserve all state across layout changes).
  final Map<ViewerRegion, GlobalKey> _paneKeys = <ViewerRegion, GlobalKey>{
    for (final region in ViewerRegion.values) region: GlobalKey(),
  };
  late ViewerSettingsDraft _settings =
      widget.initialSettings ?? const ViewerSettingsDraft();
  final Map<CommandScope, CommandDispatch> _scopeCommandHandlers =
      <CommandScope, CommandDispatch>{};

  /// Preferences currently in effect; widget tests read this.
  ViewerSettingsDraft get settings => _settings;

  @override
  void initState() {
    super.initState();
    _status.regionFocus.addListener(_onStatusFocusChanged);
    // design.md section 2: a launch starts in the Projects region, on its
    // selected row, or on the empty list container when it has no rows. Without
    // this the first Tab would be the only way into the window and F1..F3 would
    // look dead to a screen-reader user.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (widget.environment.needsSetup && !_initialSetupOpened) {
        _initialSetupOpened = true;
        unawaited(_openSettings(firstSetup: true));
      } else {
        _focusRegion(ViewerRegion.projects);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ViewerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.initialSettings, oldWidget.initialSettings) &&
        widget.initialSettings != null) {
      _settings = widget.initialSettings!;
    }
  }

  void _onStatusFocusChanged() {
    if (_status.regionFocus.hasFocus) {
      _onRegionFocusChange(ViewerRegion.status, true);
    }
  }

  @override
  ViewerEnvironment get environment => widget.environment;

  @override
  ViewerRegion get activeRegion => _activeRegion;

  @override
  bool get isReducedLayout => _layoutMode != ViewerLayoutMode.threePane;

  /// Layout actually used by the current frame; read by widget tests.
  ViewerLayoutMode get layoutMode => _layoutMode;

  /// Number of open modals; a background command is blocked while positive.
  int get modalDepth => _modalDepth;

  @override
  bool get hasOpenModal => _modalDepth > 0;

  @override
  ViewerRegionHandles handlesFor(ViewerRegion region) => switch (region) {
    ViewerRegion.projects => _projects,
    ViewerRegion.tasks => _tasks,
    ViewerRegion.details => _details,
    ViewerRegion.status => _status,
  };

  @override
  void dispose() {
    _status.regionFocus.removeListener(_onStatusFocusChanged);
    _scopeCommandHandlers.clear();
    _projects.dispose();
    _tasks.dispose();
    _details.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  void announce(String text, {String? clipId, bool dynamic = false}) {
    widget.announcements.announceStatus(text, clipId: clipId, dynamic: dynamic);
  }

  @override
  void announceProgress(String text, {String? clipId}) {
    widget.announcements.announceProgress(text, clipId: clipId);
  }

  @override
  void registerScopeCommands(CommandScope scope, CommandDispatch? handler) {
    if (handler == null) {
      _scopeCommandHandlers.remove(scope);
      return;
    }
    _scopeCommandHandlers[scope] = handler;
  }

  // ------------------------------------------------------------- focus moves

  void _onRegionFocusChange(ViewerRegion region, bool hasFocus) {
    if (!hasFocus) {
      return;
    }
    if (region.isCollection) {
      _lastCollectionRegion = region;
    }
    if (_activeRegion == region) {
      return;
    }
    _activeRegion = region;
    if (region != ViewerRegion.status) {
      _revealedRegion = region;
    }
    widget.actions.onRegionChanged?.call(region);
    _rebuildAfterFocusChange();
  }

  void _rebuildAfterFocusChange() {
    if (!mounted) {
      return;
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
  }

  @override
  void revealRegion(ViewerRegion region) {
    if (region == ViewerRegion.status) {
      // Status has no pane of its own; it stays visible under the panes, so
      // moving to it must not replace the pane the user was reading.
      return;
    }
    if (_revealedRegion == region) {
      return;
    }
    _revealedRegion = region;
    if (mounted) {
      setState(() {});
    }
  }

  /// Moves focus into a collection, waiting for the pane to mount.
  ///
  /// In a reduced layout the destination pane is built only after the reveal,
  /// so the list has no attached state yet. The retry lands the focus on the
  /// row as soon as it exists, and does nothing when something inside the
  /// region already took the focus or a modal opened in the meantime.
  void _focusCollection(ViewerRegion region) {
    final handles = handlesFor(region);
    handles.list.focusRegion();
    if (handles.list.hasListFocus) {
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _modalDepth > 0) {
        return;
      }
      if (handles.regionFocus.hasFocus) {
        return;
      }
      handles.list.focusRegion();
    });
  }

  /// Marks Task details as the pane the reduced layouts must show.
  void _requestDetails() {
    final changed = !_detailsRequested;
    _detailsRequested = true;
    if (_layoutMode != ViewerLayoutMode.threePane) {
      // Task details replaces the Tasks pane instead of opening beside it.
      revealRegion(ViewerRegion.details);
    }
    if (changed) {
      _rebuildAfterFocusChange();
    }
  }

  /// Regions the current layout actually shows.
  ///
  /// Hidden panes stay mounted so their selection, filter text and scroll
  /// position survive a resize (design.md section 2), but they must leave the
  /// focus and accessibility trees.
  Set<ViewerRegion> get _visibleRegions => switch (_layoutMode) {
    ViewerLayoutMode.threePane => const <ViewerRegion>{
      ViewerRegion.projects,
      ViewerRegion.tasks,
      ViewerRegion.details,
    },
    ViewerLayoutMode.twoPane => <ViewerRegion>{
      ViewerRegion.projects,
      if (_detailsRequested) ViewerRegion.details else ViewerRegion.tasks,
    },
    ViewerLayoutMode.singlePane => <ViewerRegion>{_revealedRegion},
  };

  /// Keeps [child] mounted without letting a hidden pane take focus or speech.
  Widget _slotted(ViewerRegion region, Widget child) => Visibility(
    visible: _visibleRegions.contains(region),
    maintainState: true,
    child: child,
  );

  /// Hands focus to the revealed pane when a layout change hides the one that
  /// owned it, so no resize drops the user on the window root.
  void _scheduleFocusRepair() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _modalDepth > 0) {
        return;
      }
      if (_visibleRegions.contains(_activeRegion)) {
        return;
      }
      _focusRegion(_revealedRegion);
    });
  }

  void _requestFocusAfterReveal(ViewerRegion region, FocusNode node) {
    revealRegion(region);
    // A pane that the current layout hides is excluded from focus until the
    // reveal rebuilds the tree, so only a node that can take focus now is
    // focused now; the rest wait one frame.
    if (node.context != null && node.canRequestFocus) {
      node.requestFocus();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) {
        node.requestFocus();
      }
    });
  }

  void _focusRegion(ViewerRegion region) {
    final handles = handlesFor(region);
    switch (region) {
      case ViewerRegion.projects:
      case ViewerRegion.tasks:
        final detailsRequested = _detailsRequested;
        _detailsRequested = false;
        revealRegion(region);
        if (detailsRequested && _layoutMode != ViewerLayoutMode.threePane) {
          _rebuildAfterFocusChange();
        }
        _focusCollection(region);
      case ViewerRegion.details:
        _focusDescription();
      case ViewerRegion.status:
        _requestFocusAfterReveal(ViewerRegion.status, handles.regionFocus);
    }
  }

  /// Reveals Task details and focuses the description/body control.
  ///
  /// The Details pane owns which of its four panels is on screen, and the body
  /// control only exists while the Description panel is showing, so the pane
  /// gets the command before the region tries to focus the node. Reaching the
  /// description must not stop at another tab (viewer/design.md section 9).
  void _focusDescription() {
    _requestDetails();
    _scopeCommandHandlers[CommandScope.details]?.call(
      'global.focusDescription',
    );
    _requestFocusAfterReveal(ViewerRegion.details, _details.bodyFocus);
  }

  /// Reveals Task details and focuses Find in body.
  ///
  /// Same panel hand-off as [_focusDescription]: the Find control lives on the
  /// Description panel.
  void _focusFindInBody() {
    _requestDetails();
    _scopeCommandHandlers[CommandScope.details]?.call('global.findInBody');
    _requestFocusAfterReveal(ViewerRegion.details, _details.findFocus);
  }

  void _cycleRegion(int delta) {
    final current = _regionOrder.indexOf(_activeRegion);
    final next = (current + delta) % _regionOrder.length;
    _focusRegion(_regionOrder[next < 0 ? next + _regionOrder.length : next]);
  }

  // --------------------------------------------------------------- dispatch

  /// Runs one command id reached from [scope].
  ///
  /// The scope that installed the binding checks ownership first; a global
  /// command is run here for whichever region had focus, which is how F1..F10
  /// stay available everywhere without duplicating bindings.
  @override
  KeyEventResult dispatchFromScope(CommandScope scope, String id) {
    final spec = commandSpecById(id);
    if (spec == null) {
      return KeyEventResult.ignored;
    }
    if (_modalDepth > 0 && !isDialogScope(spec.scope)) {
      // Modal isolation: the background never acts while a dialog is open.
      return KeyEventResult.handled;
    }
    if (spec.scope != scope &&
        spec.scope != CommandScope.global &&
        spec.scope != CommandScope.dialogs) {
      return KeyEventResult.ignored;
    }
    final paneHandler = _scopeCommandHandlers[scope];
    if (paneHandler != null) {
      final result = paneHandler(id);
      if (result != KeyEventResult.ignored) {
        return result;
      }
    }
    return _runCommand(id) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _runCommand(String id) {
    switch (id) {
      case 'global.focusProjects':
        _focusRegion(ViewerRegion.projects);
        return true;
      case 'global.focusTasks':
        _focusRegion(ViewerRegion.tasks);
        return true;
      case 'global.focusDescription':
        _focusRegion(ViewerRegion.details);
        return true;
      case 'global.nextRegion':
        _cycleRegion(1);
        return true;
      case 'global.previousRegion':
        _cycleRegion(-1);
        return true;
      case 'global.focusFilter':
        _focusFilter();
        return true;
      case 'global.findInBody':
        _focusFindInBody();
        return true;
      case 'global.refresh':
        _refresh();
        return true;
      case 'global.editTask':
        _requestDetails();
        widget.actions.onEditTask?.call();
        return true;
      case 'global.markDone':
        widget.actions.onMarkDone?.call();
        return true;
      case 'global.enrichClipboard':
        return _enrichFromProjectsList();
      case 'global.save':
        widget.actions.onSave?.call();
        return true;
      case 'global.back':
        widget.actions.onBack?.call();
        return true;
      case 'global.activate':
        widget.actions.onActivate?.call();
        return true;
      case 'global.settings':
        unawaited(openSettings());
        return true;
      case 'global.hotkeyHelp':
      case 'dialogs.hotkeyHelp':
        unawaited(openHelp());
        return true;
      case 'dialogs.dismiss':
        return _dismissTopModal();
      case 'status.retry':
        widget.actions.onRetry?.call();
        return true;
      case 'status.details':
        widget.actions.onDetails?.call();
        return true;
      case 'status.browseCli':
        widget.actions.onBrowseCli?.call();
        return true;
      case 'status.testConnection':
        widget.actions.onTestConnection?.call();
        return true;
      case 'details.copyReference':
        widget.actions.onCopyReference?.call();
        return true;
      case 'details.nextMatch':
        widget.actions.onNextMatch?.call();
        return true;
      case 'details.previousMatch':
        widget.actions.onPreviousMatch?.call();
        return true;
      case 'details.openDependency':
        widget.actions.onActivate?.call();
        return true;
      case 'projects.pasteFilter':
      case 'tasks.pasteFilter':
        // The pane takes Ctrl+V only while its list has focus; everywhere
        // else the key keeps the focused text field's native paste.
        return false;
      default:
        break;
    }
    if (id.startsWith('details.tab')) {
      widget.actions.onShowDetailsTab?.call(id.substring('details.tab'.length));
      return true;
    }
    if (id.startsWith('editor.')) {
      widget.actions.onEditTask?.call();
      return true;
    }
    // A bound but not yet implemented app command is consumed so it cannot
    // reach a native default; help-only entries stay unbound.
    final spec = commandSpecById(id);
    return spec != null && !spec.isHelpOnly;
  }

  void _focusFilter() {
    final target = _activeRegion.isCollection
        ? _activeRegion
        : _lastCollectionRegion;
    final node = handlesFor(target).filterFocus;
    revealRegion(target);
    _requestFocusAfterReveal(target, node);
  }

  bool _enrichFromProjectsList() {
    if (!_projects.list.hasListFocus) {
      // Outside the Projects list the key keeps the focused control's own
      // behaviour instead of being swallowed.
      return false;
    }
    final callback = widget.actions.onEnrichClipboard;
    if (callback == null) {
      return true;
    }
    callback();
    return true;
  }

  void _refresh() {
    final callback = widget.actions.onRefresh;
    if (callback != null) {
      callback();
      return;
    }
    announce(
      'Refreshed. This prototype shows synthetic rows; no task store is '
      'connected yet.',
      clipId: 'refreshed',
    );
  }

  bool _dismissTopModal() {
    if (_modalDepth == 0) {
      return false;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.canPop()) {
      return false;
    }
    navigator.maybePop();
    return true;
  }

  // ------------------------------------------------------------------ modals

  @override
  Future<void> openHelp() async {
    // Help opened from another modal is stacked above it; the dialog restores
    // the focus it captured when it opened, and the modal below keeps its
    // state. Background commands stay unreachable because the window scope is
    // not an ancestor of either route.
    final scope = _activeRegion.commandScope;
    await showModal<void>(
      CommandScope.keyboardHelp,
      (context) => KeyboardHelpDialog(activeScope: scope),
    );
  }

  @override
  Future<void> openSettings() => _openSettings(firstSetup: false);

  Future<void> _openSettings({required bool firstSetup}) async {
    final draft = await showModal<ViewerSettingsDraft>(
      CommandScope.settings,
      (context) => SettingsDialog(
        environment: widget.environment,
        announcements: widget.announcements,
        startup: widget.startup,
        initial: _settings,
        firstSetup: firstSetup,
      ),
    );
    if (draft == null) {
      return;
    }
    if (draft.dataRoot != _settings.dataRoot) {
      final guard = widget.actions.onStoreChangeRequested;
      if (guard != null) {
        final allowed = await guard(draft.dataRoot);
        if (!mounted) {
          return;
        }
        if (!allowed) {
          announce(
            'Store change cancelled. Settings were not saved.',
            dynamic: true,
          );
          return;
        }
      }
    }
    setState(() {
      _settings = draft;
    });
    widget.announcements.setMode(draft.announcementMode);
    widget.announcements.setVolume(draft.bellaVolume);
    widget.actions.onSettingsChanged?.call(draft);
    announce('Settings saved.', clipId: 'settings_saved');
  }

  @override
  Future<T?> showModal<T>(
    CommandScope scope,
    WidgetBuilder builder, {
    CommandDispatch? onCommand,
  }) async {
    assert(isDialogScope(scope), 'showModal needs a dialog scope.');
    final previousFocus = FocusManager.instance.primaryFocus;
    _modalDepth++;
    try {
      return await showDialog<T>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => DialogCommandHost(
          scope: scope,
          onHotkeyHelp: openHelp,
          onCommand: (id) {
            final delegated = onCommand?.call(id);
            if (delegated != null && delegated != KeyEventResult.ignored) {
              return delegated;
            }
            return _defaultDialogCommand(id, dialogContext);
          },
          child: builder(dialogContext),
        ),
      );
    } finally {
      _modalDepth--;
      if (previousFocus != null && previousFocus.canRequestFocus) {
        previousFocus.requestFocus();
      }
    }
  }

  /// Safe default behaviour shared by every dialog.
  KeyEventResult _defaultDialogCommand(String id, BuildContext dialogContext) {
    switch (id) {
      case 'dialogs.dismiss':
        Navigator.of(dialogContext).maybePop();
      case 'dialogs.hotkeyHelp':
        unawaited(openHelp());
    }
    // A dialog never forwards a command to the window behind it.
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------------- build

  String get _environmentSummary {
    final missing = <String>[
      if (widget.environment.dataRoot == null) 'task data root',
      if (widget.environment.tasksExe == null) 'Tasks CLI',
    ];
    final status = missing.isEmpty
        ? ''
        : 'Setup required: ${missing.join(' and ')}';
    return widget.environment.testMode
        ? (status.isEmpty ? 'test mode' : 'test mode  |  $status')
        : status;
  }

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Shortcuts(
      shortcuts: shortcutMapForScope(CommandScope.global),
      child: Actions(
        actions: commandActionsForScope(
          CommandScope.global,
          (id) => dispatchFromScope(CommandScope.global, id),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final mode = viewerLayoutModeFor(constraints.maxWidth, textScale);
            if (mode != _layoutMode) {
              _layoutMode = mode;
              _scheduleFocusRepair();
            }
            final workspace = widget.workspaceBuilder(context, this);
            return Semantics(
              label: 'Tasks Viewer',
              namesRoute: true,
              child: Scaffold(
                body: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, body) {
                      final budget = viewerShellBudgetFor(body.maxHeight);
                      return Column(
                        children: <Widget>[
                          ViewerPaneRegion(
                            maxHeight: budget.toolbar,
                            child: _buildToolbar(context),
                          ),
                          const ViewerRule(),
                          Expanded(child: _buildPanes(workspace, mode, budget)),
                          const ViewerRule(),
                          ViewerPaneRegion(
                            maxHeight: budget.status,
                            child: _buildStatusRegion(),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  'Tasks Viewer',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_environmentSummary.isNotEmpty)
                  Text(
                    _environmentSummary,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Tooltip(
            message: 'Refresh (F5)',
            excludeFromSemantics: true,
            child: IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, semanticLabel: 'Refresh (F5)'),
            ),
          ),
          Tooltip(
            message: 'Settings (Ctrl+,)',
            excludeFromSemantics: true,
            child: IconButton(
              onPressed: () => unawaited(openSettings()),
              icon: const Icon(
                Icons.settings_outlined,
                semanticLabel: 'Settings (Ctrl+,)',
              ),
            ),
          ),
          Tooltip(
            message: 'Hotkey help (F10)',
            excludeFromSemantics: true,
            child: IconButton(
              onPressed: () => unawaited(openHelp()),
              icon: const Icon(
                Icons.help_outline,
                semanticLabel: 'Hotkey help (F10)',
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _resizePanes(int boundary, double delta, double width) {
    final weights = [
      _settings.projectsPanePercent,
      _settings.tasksPanePercent,
      _settings.detailsPanePercent,
    ];
    final total = weights.reduce((a, b) => a + b);
    final shift = (delta / width * total).round();
    final minimum = (260 / width * total).ceil();
    final right = boundary + 1;
    final lower = math.min(0, minimum - weights[boundary]);
    final upper = math.max(0, weights[right] - minimum);
    final allowed = shift.clamp(lower, upper);
    if (allowed != 0) {
      setState(
        () => _settings = _settings.copyWith(
          projectsPanePercent: weights[0] + (boundary == 0 ? allowed : 0),
          tasksPanePercent: weights[1] + (boundary == 0 ? -allowed : allowed),
          detailsPanePercent: weights[2] - (boundary == 1 ? allowed : 0),
        ),
      );
    }
  }

  Widget _buildPanes(
    ViewerWorkspace workspace,
    ViewerLayoutMode mode,
    ViewerShellBudget budget,
  ) {
    final projects = _regionPane(ViewerRegion.projects, workspace.projectsPane);
    final tasks = _regionPane(ViewerRegion.tasks, workspace.tasksPane);
    final details = _regionPane(ViewerRegion.details, workspace.detailsPane);
    switch (mode) {
      case ViewerLayoutMode.threePane:
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - 16;
            return Row(
              children: [
                Expanded(flex: _settings.projectsPanePercent, child: projects),
                PaneSplitter(
                  label: 'Resize Projects and Tasks',
                  onResize: (delta) => _resizePanes(0, delta, width),
                  onResizeEnd: () =>
                      widget.actions.onSettingsChanged?.call(_settings),
                ),
                Expanded(flex: _settings.tasksPanePercent, child: tasks),
                PaneSplitter(
                  label: 'Resize Tasks and Task details',
                  onResize: (delta) => _resizePanes(1, delta, width),
                  onResizeEnd: () =>
                      widget.actions.onSettingsChanged?.call(_settings),
                ),
                Expanded(flex: _settings.detailsPanePercent, child: details),
              ],
            );
          },
        );
      case ViewerLayoutMode.twoPane:
        return LayoutBuilder(
          builder: (context, constraints) => Row(
            children: <Widget>[
              Expanded(flex: _settings.projectsPanePercent, child: projects),
              PaneSplitter(
                label: 'Resize Projects and Tasks',
                onResize: (delta) {
                  final total =
                      _settings.projectsPanePercent +
                      _settings.tasksPanePercent +
                      _settings.detailsPanePercent;
                  final minimum = (260 / (constraints.maxWidth - 8) * total)
                      .ceil();
                  final next =
                      (_settings.projectsPanePercent +
                              delta / (constraints.maxWidth - 8) * total)
                          .round()
                          .clamp(minimum, total - minimum);
                  final remaining = total - next;
                  final task =
                      (remaining *
                              _settings.tasksPanePercent /
                              (_settings.tasksPanePercent +
                                  _settings.detailsPanePercent))
                          .round();
                  setState(
                    () => _settings = _settings.copyWith(
                      projectsPanePercent: next,
                      tasksPanePercent: task,
                      detailsPanePercent: remaining - task,
                    ),
                  );
                },
                onResizeEnd: () =>
                    widget.actions.onSettingsChanged?.call(_settings),
              ),
              Expanded(
                flex: _settings.tasksPanePercent + _settings.detailsPanePercent,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _slotted(ViewerRegion.tasks, tasks),
                    _slotted(ViewerRegion.details, details),
                  ],
                ),
              ),
            ],
          ),
        );
      case ViewerLayoutMode.singlePane:
        return Column(
          children: <Widget>[
            ViewerPaneRegion(
              maxHeight: budget.navigation,
              child: _buildRegionNavigation(context),
            ),
            const ViewerRule(),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _slotted(ViewerRegion.projects, projects),
                  _slotted(ViewerRegion.tasks, tasks),
                  _slotted(ViewerRegion.details, details),
                ],
              ),
            ),
          ],
        );
    }
  }

  Widget _buildRegionNavigation(BuildContext context) {
    final selection = <ViewerRegion>{
      if (_revealedRegion != ViewerRegion.status) _revealedRegion,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<ViewerRegion>(
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          segments: const <ButtonSegment<ViewerRegion>>[
            ButtonSegment<ViewerRegion>(
              value: ViewerRegion.projects,
              label: Text('Projects'),
            ),
            ButtonSegment<ViewerRegion>(
              value: ViewerRegion.tasks,
              label: Text('Tasks'),
            ),
            ButtonSegment<ViewerRegion>(
              value: ViewerRegion.details,
              label: Text('Task details'),
            ),
          ],
          selected: selection,
          onSelectionChanged: (value) {
            if (value.isEmpty) {
              return;
            }
            final region = value.first;
            if (region == ViewerRegion.details) {
              _detailsRequested = true;
            }
            _focusRegion(region);
          },
        ),
      ),
    );
  }

  Widget _regionPane(ViewerRegion region, Widget child) {
    final handles = handlesFor(region);
    return Focus(
      key: _paneKeys[region],
      focusNode: handles.regionFocus,
      includeSemantics: false,
      onFocusChange: (hasFocus) => _onRegionFocusChange(region, hasFocus),
      child: Shortcuts(
        shortcuts: shortcutMapForScope(region.commandScope),
        child: Actions(
          actions: commandActionsForScope(
            region.commandScope,
            (id) => dispatchFromScope(region.commandScope, id),
          ),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (region != ViewerRegion.tasks)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Semantics(
                      header: true,
                      child: Text(
                        region.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusRegion() {
    return Shortcuts(
      shortcuts: shortcutMapForScope(CommandScope.statusBar),
      child: Actions(
        actions: commandActionsForScope(
          CommandScope.statusBar,
          (id) => dispatchFromScope(CommandScope.statusBar, id),
        ),
        child: StatusBar(
          controller: widget.announcements,
          focusNode: _status.regionFocus,
          onRetry: widget.actions.onRetry,
          onDetails: widget.actions.onDetails,
        ),
      ),
    );
  }
}
