/// Task details region of the real workspace: header actions, the four
/// read-only view tabs, the body reader with Find in body, dependencies,
/// history snapshots and project rules.
///
/// Contract: viewer/spec.md section 6 with viewer/design.md section 7 (and the
/// Task details rows of section 9). Every read, debounce, late-answer guard and
/// dependency back stack belongs to [TaskDetailController]; the pane renders
/// that state and owns only the local focus and text controllers a rendering
/// layer needs.
library;

import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/detail_controller.dart';
import '../data/models.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'body_text.dart';
import 'commands.dart';
import 'viewer_controls.dart';
import 'viewer_format.dart';
import 'workspace_model.dart';

/// How long a read may run before the pane says it is still loading.
const Duration viewerSlowReadAfter = Duration(milliseconds: 500);

/// Honest feedback for the two header actions the editor slice still owns.
///
/// Slice 4 ships read views only, so the buttons and their shortcuts must say
/// what they did not do instead of failing silently.
const String viewerEditDeferredMessage =
    'The task editor is not part of this build yet. Nothing was changed.';
const String viewerMarkDoneDeferredMessage =
    'Mark done is not part of this build yet. Nothing was changed.';

/// Task details region bound to one workspace model.
class ViewerDetailsPane extends StatefulWidget {
  const ViewerDetailsPane({super.key, required this.api, required this.model});

  final ViewerShellApi api;
  final ViewerWorkspaceModel model;

  @override
  State<ViewerDetailsPane> createState() => _ViewerDetailsPaneState();
}

class _ViewerDetailsPaneState extends State<ViewerDetailsPane> {
  final TextEditingController _body = TextEditingController();
  /// The loaded body in stored and engine coordinates; [ViewerBodyText.parse].
  ViewerBodyText _bodyText = ViewerBodyText.parse('');
  final TextEditingController _find = TextEditingController();
  final TextEditingController _snapshot = TextEditingController();
  final TextEditingController _rules = TextEditingController();
  final Map<TaskDetailTab, FocusNode> _tabNodes = <TaskDetailTab, FocusNode>{
    for (final tab in TaskDetailTab.values)
      tab: FocusNode(debugLabel: 'details tab tab'),
  };
  final FocusNode _snapshotFocus = FocusNode(debugLabel: 'details snapshot');
  final FocusNode _rulesFocus = FocusNode(debugLabel: 'details rules');

  /// Controller instance the local text controls are currently bound to.
  TaskDetailController? _boundController;
  String? _announcedNotice;
  String? _slowReadKey;
  Timer? _slowReadTimer;

  ViewerRegionHandles get _handles =>
      widget.api.handlesFor(ViewerRegion.details);

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.details, _onScopeCommand);
    widget.model.addListener(_syncExternalContent);
    _syncExternalContent();
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.details, null);
    widget.model.removeListener(_syncExternalContent);
    _slowReadTimer?.cancel();
    _body.dispose();
    _find.dispose();
    _snapshot.dispose();
    _rules.dispose();
    for (final node in _tabNodes.values) {
      node.dispose();
    }
    _snapshotFocus.dispose();
    _rulesFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- commands

  KeyEventResult _onScopeCommand(String id) {
    switch (id) {
      case 'details.tabDetails':
      case 'details.tabDependencies':
      case 'details.tabHistory':
      case 'details.tabRules':
        final tab = TaskDetailTab.fromCommandSuffix(
          id.substring('details.tab'.length),
        );
        if (tab == null) {
          return KeyEventResult.ignored;
        }
        _activateTab(tab);
        return KeyEventResult.handled;
      case 'details.copyReference':
        unawaited(_copyReference());
        return KeyEventResult.handled;
      case 'details.nextMatch':
        return _findStep(next: true);
      case 'details.previousMatch':
        return _findStep(next: false);
      case 'details.dependencyList':
        _revealInPanel(TaskDetailTab.dependencies, _handles.list.focusRegion);
        return KeyEventResult.handled;
      case 'details.openDependency':
        _openSelectedDependency();
        return KeyEventResult.handled;
      case 'details.historyList':
        _revealInPanel(TaskDetailTab.history, _handles.list.focusRegion);
        return KeyEventResult.handled;
      case 'details.eventSnapshot':
        final detail = widget.model.detail;
        if (detail == null || detail.openedEventId == null) {
          widget.api.announce(
            'Select a history event before reading its snapshot.',
            dynamic: true,
          );
          return KeyEventResult.handled;
        }
        _revealPanel(TaskDetailTab.history, _snapshotFocus);
        return KeyEventResult.handled;
      case 'details.rulesText':
        _revealPanel(TaskDetailTab.rules, _rulesFocus);
        return KeyEventResult.handled;
      // F3 and Ctrl+H reach the two controls the Description panel owns. The
      // window asks the pane first because a tab switch has to land before the
      // control exists; the window then focuses the node itself, which is also
      // the whole path for a workspace without a Details pane of its own.
      case 'global.focusDescription':
        _revealPanel(TaskDetailTab.details, _handles.bodyFocus);
        return KeyEventResult.handled;
      case 'global.findInBody':
        _revealPanel(TaskDetailTab.details, _handles.findFocus);
        return KeyEventResult.handled;
      case 'global.back':
        return _back() ? KeyEventResult.handled : KeyEventResult.ignored;
      case 'global.editTask':
        _deferEdit();
        return KeyEventResult.handled;
      case 'global.markDone':
        _deferMarkDone();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  // ------------------------------------------------------- external content

  /// Mirrors state the pane did not type: a new selection, the loaded body, a
  /// history snapshot, a wrap notice, and the slow-read announcement.
  void _syncExternalContent() {
    final state = widget.model.detail;
    if (!identical(state, _boundController)) {
      _boundController = state;
      _announcedNotice = null;
      _find.clear();
    }
    final loaded = state?.detail;
    final body = loaded?.body ?? '';
    final ViewerBodyText text = ViewerBodyText.parse(body);
    _bodyText = text;
    if (_body.text != text.display) {
      _body.text = text.display;
    }
    final findText = state?.findText ?? '';
    if (findText != _find.text && !_handles.findFocus.hasFocus) {
      _find.text = findText;
    }
    final snapshot = _snapshotText(state);
    if (_snapshot.text != snapshot) {
      _snapshot.text = snapshot;
    }
    final rules = loaded == null
        ? ''
        : loaded.rules.isEmpty
        ? 'This project has no rules.'
        : loaded.rules;
    if (_rules.text != rules) {
      _rules.text = rules;
    }
    final notice = state?.findNotice;
    if (notice == null) {
      _announcedNotice = null;
    } else if (notice != _announcedNotice) {
      _announcedNotice = notice;
      widget.api.announce(notice, dynamic: true);
    }
    _watchSlowRead(state);
  }

  /// Snapshot text for the History panel: the selected event, or the reason
  /// there is nothing to read yet.
  String _snapshotText(TaskDetailController? state) {
    if (state == null) {
      return '';
    }
    final eventId = state.openedEventId;
    if (eventId == null) {
      return 'Select a history event to read its full snapshot.';
    }
    final failure = state.eventError;
    if (failure != null) {
      return 'Could not load event $eventId: ${failure.message}';
    }
    final snapshot = state.eventSnapshot;
    if (snapshot == null) {
      return 'Loading event $eventId snapshot';
    }
    return snapshot.isEmpty
        ? 'Event $eventId has no stored snapshot.'
        : snapshot;
  }

  /// Speaks a read that is still running after [viewerSlowReadAfter].
  void _watchSlowRead(TaskDetailController? state) {
    String? key;
    String? message;
    if (state != null) {
      if (state.isLoading && !state.hasDetail) {
        key = 'detail/${state.projectId}/${state.taskId}';
        message = 'Loading task ${state.canonicalTaskId}';
      } else if (state.isEventLoading) {
        key = 'event/${state.projectId}/${state.openedEventId}';
        message = 'Loading event ${state.openedEventId} snapshot';
      }
    }
    if (key == _slowReadKey) {
      return;
    }
    _slowReadTimer?.cancel();
    _slowReadTimer = null;
    _slowReadKey = key;
    if (key == null || message == null) {
      return;
    }
    final announcement = message;
    _slowReadTimer = Timer(viewerSlowReadAfter, () {
      _slowReadTimer = null;
      if (!mounted || _slowReadKey != key) {
        return;
      }
      widget.api.announce(announcement, clipId: 'loading');
    });
  }

  // -------------------------------------------------------------- actions

  void _deferEdit() =>
      widget.api.announce(viewerEditDeferredMessage, dynamic: true);

  void _deferMarkDone() =>
      widget.api.announce(viewerMarkDoneDeferredMessage, dynamic: true);

  /// Dependency Back. False when there is nowhere to return to, so the key
  /// keeps whatever meaning the rest of the window has for it.
  bool _back() {
    if (!widget.model.canGoBack) {
      return false;
    }
    unawaited(widget.model.goBack());
    return true;
  }

  /// Activates one tab and leaves focus on its tab control.
  void _activateTab(TaskDetailTab tab) {
    widget.model.showTab(tab);
    final node = _tabNodes[tab];
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
    }
  }

  Future<void> _copyReference() async {
    final detail = widget.model.detail?.detail;
    if (detail == null) {
      widget.api.announce(
        'Select a task before copying its reference.',
        dynamic: true,
      );
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: '${detail.canonicalId}: ${detail.title}'),
    );
    widget.api.announce('Task reference copied', clipId: 'reference_copied');
  }

  /// Next/Previous match: selects it in the body and hands over the caret, so
  /// the screen reader reads the matched text next instead of the Find field.
  KeyEventResult _findStep({required bool next}) {
    final state = widget.model.detail;
    if (state == null || !state.hasDetail) {
      return KeyEventResult.ignored;
    }
    if (next) {
      state.findNext();
    } else {
      state.findPrevious();
    }
    final start = state.matchStart;
    final end = state.matchEnd;
    if (start != null && end != null) {
      // Find offsets belong to the stored body; the control holds its LF form.
      _body.selection = TextSelection(
        baseOffset: _bodyText.displayOffset(start),
        extentOffset: _bodyText.displayOffset(end),
      );
    }
    _revealPanel(TaskDetailTab.details, _handles.bodyFocus);
    if (state.findNotice == null) {
      widget.api.announce(
        state.matchCount == 0
            ? 'No matches'
            : 'Match ${state.matchIndex + 1} of ${state.matchCount}',
        dynamic: true,
      );
    }
    return KeyEventResult.handled;
  }

  /// Shows [tab] and focuses [focus]; a panel that is not on screen yet is
  /// focused on the next frame, once its control exists.
  void _revealPanel(TaskDetailTab tab, FocusNode focus) {
    _revealInPanel(tab, () {
      if (focus.context != null && focus.canRequestFocus) {
        focus.requestFocus();
      }
    });
  }

  /// Shows [tab] and hands focus to a control its panel owns.
  ///
  /// A panel that is not on screen yet owns no list or text control, so an
  /// access key that switches views has to wait for the frame that builds it
  /// (design.md section 9).
  void _revealInPanel(TaskDetailTab tab, VoidCallback focus) {
    final state = widget.model.detail;
    if (state == null) {
      return;
    }
    final switching = state.tab != tab;
    widget.model.showTab(tab);
    if (!switching) {
      focus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        focus();
      }
    });
  }

  /// Opens the selected dependency row in the same project.
  void _openSelectedDependency() {
    final state = widget.model.detail;
    if (state == null) {
      return;
    }
    if (state.dependencies.isEmpty) {
      widget.api.announce('This task has no dependencies.', dynamic: true);
      return;
    }
    if (state.tab != TaskDetailTab.dependencies) {
      _activateTab(TaskDetailTab.dependencies);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openDependencyAt(_handles.list.selectedIndex);
        }
      });
      return;
    }
    _openDependencyAt(_handles.list.selectedIndex);
  }

  void _openDependencyAt(int? index) {
    final state = widget.model.detail;
    if (state == null) {
      return;
    }
    final dependencies = state.dependencies;
    if (index == null || index < 0 || index >= dependencies.length) {
      widget.api.announce(
        'Select a dependency row before opening it.',
        dynamic: true,
      );
      return;
    }
    unawaited(state.openDependency(dependencies[index].id));
  }

  /// Enter/Space on one history event loads its complete snapshot.
  void _openEventAt(int index) {
    final state = widget.model.detail;
    if (state == null) {
      return;
    }
    final events = state.historyEvents;
    if (index < 0 || index >= events.length) {
      return;
    }
    unawaited(widget.model.selectHistoryEvent(events[index].eventId));
  }

  // ------------------------------------------------------------------ tabs

  KeyEventResult _onTabKey(TaskDetailTab tab, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveTabFocus(tab, -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveTabFocus(tab, 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      _activateTab(tab);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveTabFocus(TaskDetailTab from, int delta) {
    final values = TaskDetailTab.values;
    final target = values.indexOf(from) + delta;
    if (target < 0 || target >= values.length) {
      return;
    }
    final node = _tabNodes[values[target]];
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final state = widget.model.detail;
        if (state == null || state.taskId == null) {
          return _buildMessage('Select a task to read its details.');
        }
        final detail = state.detail;
        if (detail == null) {
          final failure = state.loadError;
          if (failure != null) {
            return ViewerFailureView(
              heading: 'Could not load task',
              failure: failure,
              onRetry: () => unawaited(widget.model.retryDetail()),
            );
          }
          return _buildMessage('Loading task ${state.canonicalTaskId}');
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final budget = viewerPaneBudgetFor(context, constraints.maxHeight);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ViewerPaneRegion(
                  maxHeight: budget.header,
                  child: _buildHeader(context, state, detail),
                ),
                if (state.detailIsStale)
                  ViewerPaneRegion(
                    maxHeight: budget.status,
                    child: ViewerStatusLine(
                      text:
                          'Showing the last confirmed read of '
                          '${detail.canonicalId}.',
                      detail: state.loadError?.message,
                      warning: true,
                    ),
                  )
                else if (state.isLoading)
                  ViewerPaneRegion(
                    maxHeight: budget.status,
                    child: const ViewerStatusLine(
                      text: 'Refreshing this task',
                      detail:
                          'The text below stays readable while the read runs.',
                    ),
                  ),
                ViewerPaneRegion(
                  maxHeight: budget.footer,
                  child: _buildTabBar(context, state),
                ),
                const Divider(height: 1),
                Expanded(child: _buildPanel(context, state, detail)),
              ],
            );
          },
        );
      },
    );
  }

  /// Placeholder for "nothing selected yet" and "the first read is running".
  Widget _buildMessage(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }

  // --------------------------------------------------------------- header

  Widget _buildHeader(
    BuildContext context,
    TaskDetailController state,
    TaskDetail detail,
  ) {
    final theme = Theme.of(context);
    final metadata = <String>[
      'ID ${detail.canonicalId}',
      'Priority ${detail.priority}',
      'Status ${viewerStatusLabel(detail.status)}',
      'Version ${detail.version}',
      detail.labels.isEmpty
          ? 'No labels'
          : 'Labels ${detail.labels.join(', ')}',
      'Created ${viewerTimestamp(context, detail.createdMs)}',
      'Updated ${viewerTimestamp(context, detail.updatedMs)}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(detail.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: <Widget>[
              for (final line in metadata)
                Text(line, style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Tooltip(
                message: 'F4',
                child: TextButton(
                  onPressed: _deferEdit,
                  child: const Text('Edit'),
                ),
              ),
              Tooltip(
                message: 'Ctrl+D',
                child: TextButton(
                  onPressed: _deferMarkDone,
                  child: const Text('Mark done'),
                ),
              ),
              Tooltip(
                message: 'Alt+C',
                child: TextButton(
                  onPressed: () => unawaited(_copyReference()),
                  child: const Text('Copy reference'),
                ),
              ),
              if (state.canGoBack)
                Tooltip(
                  message: 'Alt+Left',
                  child: TextButton(
                    onPressed: () => unawaited(widget.model.goBack()),
                    child: const Text('Back'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ tabs

  Widget _buildTabBar(BuildContext context, TaskDetailController state) {
    return Semantics(
      role: SemanticsRole.tabBar,
      container: true,
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        // The tab row is stretched so every tab is the same height; the
        // intrinsic pass keeps that working when the row scrolls inside the
        // pane's capped tab region.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final tab in TaskDetailTab.values)
                Expanded(child: _buildTab(context, state, tab)),
            ],
          ),
        ),
      ),
    );
  }

  /// One tab with standard tab semantics: Left/Right moves the focused tab,
  /// Enter/Space activates it, and only the active tab is a Tab stop, so Tab
  /// moves on into its panel (design.md section 7).
  Widget _buildTab(
    BuildContext context,
    TaskDetailController state,
    TaskDetailTab tab,
  ) {
    final theme = Theme.of(context);
    final selected = state.tab == tab;
    final shortcut = 'Alt+${TaskDetailTab.values.indexOf(tab) + 1}';
    final node = _tabNodes[tab];
    if (node != null) {
      node.skipTraversal = !selected;
    }
    return MergeSemantics(
      child: Semantics(
        role: SemanticsRole.tab,
        selected: selected,
        onTap: () => _activateTab(tab),
        child: Focus(
          focusNode: node,
          onKeyEvent: (_, event) => _onTabKey(tab, event),
          child: InkWell(
            onTap: () => _activateTab(tab),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: 3,
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    tab.label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  Text(shortcut, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- panels

  Widget _buildPanel(
    BuildContext context,
    TaskDetailController state,
    TaskDetail detail,
  ) {
    return Semantics(
      role: SemanticsRole.tabPanel,
      child: switch (state.tab) {
        TaskDetailTab.details => _buildDetailsPanel(context, state, detail),
        TaskDetailTab.dependencies => _buildDependenciesPanel(context, state),
        TaskDetailTab.history => _buildHistoryPanel(context, state),
        TaskDetailTab.rules => _buildRulesPanel(context, detail),
      },
    );
  }

  // --------------------------------------------------------------- details

  Widget _buildDetailsPanel(
    BuildContext context,
    TaskDetailController state,
    TaskDetail detail,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The find row scrolls instead of pushing the body out of the pane.
        final budget = viewerPaneBudgetFor(context, constraints.maxHeight);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ViewerPaneRegion(
              maxHeight: budget.header,
              child: _buildFindRow(context, state),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: _StoredBodyCopy(
                  body: _bodyText,
                  controller: _body,
                  child: _buildReadOnlyText(
                    key: const ValueKey<String>('details-body'),
                    controller: _body,
                    focusNode: _handles.bodyFocus,
                    label: 'Task body (F3)',
                    hint: detail.body.isEmpty
                        ? 'This task has no body text.'
                        : null,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFindRow(BuildContext context, TaskDetailController state) {
    final theme = Theme.of(context);
    final summary = state.findNotice ?? state.findSummary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onFindKey,
                  child: TextField(
                    controller: _find,
                    focusNode: _handles.findFocus,
                    onChanged: state.setFindText,
                    onSubmitted: (_) => _findStep(next: true),
                    decoration: const InputDecoration(
                      labelText: 'Find in body (Ctrl+H)',
                      helperText: 'Literal text, case-insensitive',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(summary, style: theme.textTheme.bodySmall),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              Tooltip(
                message: 'Alt+N',
                child: TextButton(
                  onPressed: () => _findStep(next: true),
                  child: const Text('Next match'),
                ),
              ),
              Tooltip(
                message: 'Alt+P',
                child: TextButton(
                  onPressed: () => _findStep(next: false),
                  child: const Text('Previous match'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Escape while Find has focus returns to the body selection; every other
  /// key keeps its normal text-field meaning (design.md section 7).
  KeyEventResult _onFindKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _revealPanel(TaskDetailTab.details, _handles.bodyFocus);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Read-only, labelled, selectable multiline text.
  ///
  /// A read-only [TextField] rather than [SelectableText]: the whole text stays
  /// reachable for screen-reader line, word and character navigation, ordinary
  /// Ctrl+A/C keeps working, and Find in body can put the selection on a match
  /// (spec.md section 6).
  Widget _buildReadOnlyText({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    String? hint,
    Key? key,
  }) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      readOnly: true,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  // ---------------------------------------------------------- dependencies

  Widget _buildDependenciesPanel(
    BuildContext context,
    TaskDetailController state,
  ) {
    final dependencies = state.dependencies;
    return AccessibleVirtualList(
      controller: _handles.list,
      itemCount: dependencies.length,
      itemExtent: viewerRowExtent(context),
      listLabel:
          'Dependencies of ${state.canonicalTaskId ?? 'the selected task'}',
      emptyLabel: 'No dependencies',
      itemKeyBuilder: (index) =>
          ValueKey<String>('dependency-${dependencies[index].id}'),
      rowSemanticsBuilder: (index) => AccessibleRowSemantics(
        label: viewerDependencyRowLabel(dependencies[index]),
        value: viewerRowPosition(index, dependencies.length),
      ),
      onActivate: _openDependencyAt,
      rowBuilder: (context, index, selected) => _DependencyRowTile(
        dependency: dependencies[index],
        selected: selected,
      ),
    );
  }

  // --------------------------------------------------------------- history

  Widget _buildHistoryPanel(BuildContext context, TaskDetailController state) {
    final events = state.historyEvents;
    final failure = state.historyError;
    if (failure != null && events.isEmpty) {
      return ViewerFailureView(
        heading: 'Could not load history',
        failure: failure,
        onRetry: _reloadHistory,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The panel owns its height, so the footer can be capped against it.
        final budget = viewerPaneBudgetFor(context, constraints.maxHeight);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: AccessibleVirtualList(
                controller: _handles.list,
                itemCount: events.length,
                itemExtent: viewerRowExtent(context),
                listLabel: 'History of ${state.canonicalTaskId ?? 'the task'}',
                emptyLabel: state.isHistoryLoading || !state.historyLoaded
                    ? 'Loading history'
                    : 'No history events',
                itemKeyBuilder: (index) =>
                    ValueKey<String>('history-event-${events[index].eventId}'),
                rowSemanticsBuilder: (index) => AccessibleRowSemantics(
                  label: viewerHistoryRowLabel(
                    events[index],
                    viewerTimestamp(context, events[index].createdMs),
                  ),
                  value: viewerRowPosition(index, events.length),
                ),
                onActivate: _openEventAt,
                rowBuilder: (context, index, selected) => _HistoryRowTile(
                  event: events[index],
                  when: viewerTimestamp(context, events[index].createdMs),
                  selected: selected,
                ),
              ),
            ),
            const Divider(height: 1),
            ViewerPaneRegion(
              maxHeight: budget.footer,
              child: _buildHistoryFooter(context, state),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: _buildReadOnlyText(
                  key: const ValueKey<String>('details-snapshot'),
                  controller: _snapshot,
                  focusNode: _snapshotFocus,
                  label: 'Event snapshot (Alt+E)',
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHistoryFooter(BuildContext context, TaskDetailController state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            state.isHistoryLoading
                ? 'Loading history'
                : '${state.historyEvents.length} events loaded',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton(
            onPressed: state.historyHasMore ? _loadMoreHistory : null,
            child: Text(
              state.historyHasMore ? 'Load more events' : 'No more events',
            ),
          ),
          Tooltip(
            message: 'Alt+E',
            child: TextButton(
              onPressed: _snapshotFocus.requestFocus,
              child: const Text('Snapshot text'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadMoreHistory() async {
    final detail = widget.model.detail;
    if (detail == null) {
      return;
    }
    await detail.loadMoreHistory();
  }

  void _reloadHistory() {
    final detail = widget.model.detail;
    if (detail != null) {
      unawaited(detail.reloadHistory());
    }
  }

  // ----------------------------------------------------------- project rules

  Widget _buildRulesPanel(BuildContext context, TaskDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Text(
            'Rules version ${detail.ruleVersion}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: _buildReadOnlyText(
              key: const ValueKey<String>('details-rules'),
              controller: _rules,
              focusNode: _rulesFocus,
              label: 'Project rules (Alt+R)',
            ),
          ),
        ),
      ],
    );
  }
}

/// One dependency row: the whole row is the activating control, so its
/// accessible name is reached through the shared row label.
class _DependencyRowTile extends StatelessWidget {
  const _DependencyRowTile({required this.dependency, required this.selected});

  final DependencySummary dependency;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(dependency.canonicalId, style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Text(
                viewerStatusLabel(dependency.status),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  dependency.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          Text(
            dependency.preventsReadiness
                ? 'Waiting for this dependency'
                : 'Does not withhold readiness',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// One history event row; the snapshot itself is read in the panel below.
class _HistoryRowTile extends StatelessWidget {
  const _HistoryRowTile({
    required this.event,
    required this.when,
    required this.selected,
  });

  final HistoryEvent event;
  final String when;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('Event ${event.eventId}', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  event.operation,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'version ${event.resultingVersion}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          Text(when, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Ctrl+C inside the body reader.
class _CopyStoredBodyIntent extends Intent {
  const _CopyStoredBodyIntent();
}

/// Copies the stored body text behind the body selection.
///
/// The reader lays out [ViewerBodyText.display], whose carriage returns are
/// gone; a copy must still hand over the store's own characters, CRLF included
/// (viewer/spec.md section 6 with the root spec's line-ending preservation).
/// Ctrl+C keeps its ordinary meaning -- copy the current selection -- and every
/// other text-editing key stays with the control.
class _StoredBodyCopy extends StatelessWidget {
  const _StoredBodyCopy({
    required this.body,
    required this.controller,
    required this.child,
  });

  final ViewerBodyText body;
  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _CopyStoredBodyIntent(),
      },
      // The wrapper only swaps Ctrl+C; it must not add a semantics node between
      // the body control and the tab panel that owns it.
      includeSemantics: false,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CopyStoredBodyIntent: CallbackAction<_CopyStoredBodyIntent>(
            onInvoke: (_) {
              _copySelection();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }

  void _copySelection() {
    final TextSelection selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return;
    }
    unawaited(
      Clipboard.setData(
        ClipboardData(text: body.storedRange(selection.start, selection.end)),
      ),
    );
  }
}
