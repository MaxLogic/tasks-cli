/// Tasks region of the real workspace: the combined query, its filters, the
/// virtual task list and its filters.
///
/// Contract: viewer/spec.md sections 4.3, 5 and 6 with viewer/design.md
/// sections 5 and 6. Filters are delegated to the workspace model, whose task
/// controller owns the request parameters, the debounce and the paging.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/task_controller.dart';
import '../data/models.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'commands.dart';
import 'viewer_controls.dart';
import 'viewer_format.dart';
import 'workspace_model.dart';

/// Tasks region bound to one workspace model.
class ViewerTasksPane extends StatefulWidget {
  const ViewerTasksPane({super.key, required this.api, required this.model});

  final ViewerShellApi api;
  final ViewerWorkspaceModel model;

  @override
  State<ViewerTasksPane> createState() => _ViewerTasksPaneState();
}

class _ViewerTasksPaneState extends State<ViewerTasksPane>
    with FailureViewRegionFocus<ViewerTasksPane> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _labels = TextEditingController();
  final FocusNode _scopeOpenFocus = FocusNode(debugLabel: 'tasks scope open');
  final FocusNode _scopeAllFocus = FocusNode(debugLabel: 'tasks scope all');
  final FocusNode _labelsFocus = FocusNode(debugLabel: 'tasks labels');
  final FocusNode _applyLabelsFocus = FocusNode(
    debugLabel: 'tasks apply labels',
  );
  final FocusNode _needsHumanFocus = FocusNode(debugLabel: 'tasks needs human');
  final FocusNode _readinessFocus = FocusNode(debugLabel: 'tasks readiness');
  final FocusNode _sortFocus = FocusNode(debugLabel: 'tasks sort');
  final FocusNode _directionFocus = FocusNode(debugLabel: 'tasks direction');
  final FocusNode _activeFiltersFocus = FocusNode(
    debugLabel: 'tasks active filters',
  );
  final FocusNode _filtersToggleFocus = FocusNode(
    debugLabel: 'tasks filters toggle',
  );
  final Map<String, FocusNode> _statusNodes = <String, FocusNode>{
    'all': FocusNode(debugLabel: 'tasks status all'),
    for (final status in viewerTaskStatuses)
      status: FocusNode(debugLabel: 'tasks status $status'),
  };
  final Map<String, FocusNode> _priorityNodes = <String, FocusNode>{
    for (final priority in viewerTaskPriorities)
      priority: FocusNode(debugLabel: 'tasks priority $priority'),
  };

  TaskController? _bound;
  bool _filtersVisible = false;

  TaskController? get _tasks => widget.model.tasks;

  ViewerRegionHandles get _handles => widget.api.handlesFor(ViewerRegion.tasks);

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.tasks, _onScopeCommand);
    widget.model.addListener(_syncExternalControls);
    _syncExternalControls();
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.tasks, null);
    widget.model.removeListener(_syncExternalControls);
    _search.dispose();
    _labels.dispose();
    _scopeOpenFocus.dispose();
    _scopeAllFocus.dispose();
    _labelsFocus.dispose();
    _applyLabelsFocus.dispose();
    _needsHumanFocus.dispose();
    _readinessFocus.dispose();
    _sortFocus.dispose();
    _directionFocus.dispose();
    _activeFiltersFocus.dispose();
    _filtersToggleFocus.dispose();
    for (final node in _statusNodes.values) {
      node.dispose();
    }
    for (final node in _priorityNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Mirrors state the pane did not type: a project switch, Clear filters or a
  /// restored per-project preference.
  void _syncExternalControls() {
    final tasks = _tasks;
    if (!identical(tasks, _bound)) {
      _bound = tasks;
      if (tasks == null) {
        _search.clear();
        _labels.clear();
      } else {
        _search.text = tasks.query;
        _labels.text = tasks.labels.join(', ');
      }
      return;
    }
    if (tasks == null) {
      return;
    }
    final query = tasks.query;
    if (query != _search.text && !_handles.filterFocus.hasFocus) {
      _search.text = query;
    }
    final labelText = tasks.labels.join(', ');
    if (labelText != _labels.text && !_labelsFocus.hasFocus) {
      _labels.text = labelText;
    }
  }

  // ------------------------------------------------------------- commands

  KeyEventResult _onScopeCommand(String id) {
    final tasks = _tasks;
    if (tasks == null) {
      return KeyEventResult.ignored;
    }
    switch (id) {
      case 'tasks.clearSearch':
        _search.clear();
        tasks.setQuery('');
        unawaited(tasks.submitQuery());
        return KeyEventResult.handled;
      case 'tasks.filtersPopup':
        _showFilters();
        _scopeFocus(tasks.scope).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.scope':
        _showFilters();
        _scopeFocus(tasks.scope).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.statusChecklist':
        _showFilters();
        _firstStatusFocus(tasks).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.priorityChecklist':
        _showFilters();
        _firstPriorityFocus(tasks).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.labelsField':
        _showFilters();
        _labelsFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.applyLabels':
        _showFilters();
        _applyLabels();
        _applyLabelsFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.needsHuman':
        _showFilters();
        _needsHumanFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.readiness':
        _showFilters();
        _readinessFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.sort':
        _showFilters();
        _sortFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.direction':
        _tasks?.setDirection(
          _tasks?.direction == SortDirection.ascending
              ? SortDirection.descending
              : SortDirection.ascending,
        );
        return KeyEventResult.handled;
      case 'tasks.clearFilters':
        _clearFilters();
        return KeyEventResult.handled;
      case 'tasks.removeActiveFilterGroup':
        _activeFiltersFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.pasteFilter':
        if (!_handles.list.hasListFocus) {
          // A text field in this region keeps its native paste.
          return KeyEventResult.ignored;
        }
        unawaited(_pasteIntoSearch(tasks));
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Ctrl+V on the list: the clipboard text (a copied task ID, say) replaces
  /// the search and applies at once, and the keyboard stays in the list.
  Future<void> _pasteIntoSearch(TaskController tasks) async {
    final text = await readClipboardSearchText(widget.api, widget.model);
    if (text == null || !mounted || !identical(tasks, _tasks)) {
      return;
    }
    _search.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    tasks.setQuery(text);
    await tasks.submitQuery();
    if (!mounted || !identical(tasks, _tasks)) {
      return;
    }
    keepListFocus(_handles);
    final count = tasks.totalCount;
    widget.api.announce(
      '${count == 1 ? '1 matching task' : '$count matching tasks'} for $text',
      dynamic: true,
    );
  }

  FocusNode _scopeFocus(TaskScope scope) =>
      scope == TaskScope.open ? _scopeOpenFocus : _scopeAllFocus;

  FocusNode _firstStatusFocus(TaskController tasks) {
    if (tasks.statuses.isEmpty ||
        tasks.statuses.length == viewerTaskStatuses.length) {
      return _statusNodes['all']!;
    }
    for (final status in viewerTaskStatuses) {
      if (tasks.statuses.contains(status)) {
        return _statusNodes[status]!;
      }
    }
    return _statusNodes[viewerTaskStatuses.first]!;
  }

  FocusNode _firstPriorityFocus(TaskController tasks) {
    for (final priority in viewerTaskPriorities) {
      if (tasks.priorities.contains(priority)) {
        return _priorityNodes[priority]!;
      }
    }
    return _priorityNodes[viewerTaskPriorities.first]!;
  }

  void _showFilters() {
    if (!_filtersVisible) {
      setState(() => _filtersVisible = true);
    }
  }

  void _toggleFilters(bool visible) {
    _filtersToggleFocus.requestFocus();
    setState(() => _filtersVisible = visible);
  }

  void _applyLabels() {
    _tasks?.setLabels(_labels.text.split(','));
  }

  void _clearFilters() {
    _search.clear();
    _labels.clear();
    _tasks?.clearFilters();
  }

  void _toggleStatus(String status) {
    final tasks = _tasks;
    if (tasks == null) {
      return;
    }
    final movedToAll = tasks.toggleStatus(status);
    if (movedToAll) {
      widget.api.announce(
        'All tasks selected as well, so Done and Cancelled tasks can be '
        'shown.',
        dynamic: true,
      );
    }
  }

  /// Fetches the page that owns [index] and settles the pending row focus.
  Future<void> _ensureRow(int index) async {
    await widget.model.ensureTaskRow(index);
    if (!mounted) {
      return;
    }
    _handles.list.retryPending();
  }

  void _onRowSelected(int index) {
    unawaited(_selectRow(index));
  }

  /// Arrow navigation runs the dirty-draft guard first; a refusal puts the
  /// highlight back on the task the open editor still edits (spec.md 7).
  Future<void> _selectRow(int index) async {
    final moved = await widget.model.selectTaskRow(index);
    if (!mounted) {
      return;
    }
    if (!moved) {
      _restoreRowSelection(index);
      return;
    }
    await _ensureRow(index);
  }

  /// Puts the list highlight back where the model still is after a refusal.
  void _restoreRowSelection(int refusedIndex) {
    final current = widget.model.tasks?.selectedIndex;
    if (current != null) {
      _handles.list.refuseMove(refusedIndex, current);
    }
  }

  void _onRowActivated(int index) {
    unawaited(_activateRow(index));
  }

  Future<void> _activateRow(int index) async {
    if (!await widget.model.selectTaskRow(index)) {
      if (mounted) {
        _restoreRowSelection(index);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    await _ensureRow(index);
    if (!mounted) {
      return;
    }
    unawaited(widget.model.openTaskIndex(index));
    if (widget.api.isReducedLayout) {
      widget.api.revealRegion(ViewerRegion.details);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final tasks = _tasks;
        if (tasks == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Select a project to browse its tasks.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final budget = viewerPaneBudgetFor(context, constraints.maxHeight);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ViewerPaneRegion(
                  maxHeight: budget.header,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildHeading(context),
                      if (_filtersVisible)
                        _buildFilters(context, tasks)
                      else
                        _buildCollapsedFilters(context, tasks),
                    ],
                  ),
                ),
                ViewerPaneRegion(
                  maxHeight: budget.status,
                  child: _buildStatusLine(context, tasks),
                ),
                Expanded(child: _buildList(context, tasks)),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildHeading(BuildContext context) => Padding(
    // The same inset as the shell's Projects and Task details headings, so
    // the three pane titles share one baseline.
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Semantics(
      header: true,
      child: Text(
        'Tasks in ${widget.model.selectedProjectName}',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
  );

  // -------------------------------------------------------------- filters

  Widget _buildCollapsedFilters(BuildContext context, TaskController tasks) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _handles.filterFocus,
              onChanged: tasks.setQuery,
              onSubmitted: (_) => unawaited(tasks.submitQuery()),
              decoration: const InputDecoration(
                labelText: 'Search tasks (Ctrl+F)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Show filters (Alt+F)',
            child: TextButton.icon(
              focusNode: _filtersToggleFocus,
              onPressed: () => _toggleFilters(true),
              icon: const Icon(Icons.tune),
              label: _FiltersButtonLabel(tasks: tasks),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context, TaskController tasks) {
    final theme = Theme.of(context);
    final handles = _handles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message: 'Alt+F',
              child: TextButton.icon(
                focusNode: _filtersToggleFocus,
                onPressed: () => _toggleFilters(false),
                icon: const Icon(Icons.expand_less),
                label: const Text('Hide filters'),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: handles.filterFocus,
                  onChanged: tasks.setQuery,
                  onSubmitted: (_) => unawaited(tasks.submitQuery()),
                  decoration: const InputDecoration(
                    labelText: 'Search tasks (Ctrl+F)',
                    helperText: 'Search task ID, title or body',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  _search.clear();
                  tasks.setQuery('');
                  unawaited(tasks.submitQuery());
                },
                child: const Text('Clear search'),
              ),
            ],
          ),
          // Room for the helper line before the next label.
          const SizedBox(height: 12),
          Text('Scope (Alt+S)', style: theme.textTheme.bodySmall),
          RadioGroup<TaskScope>(
            groupValue: tasks.scope,
            onChanged: (value) {
              if (value != null) {
                tasks.setScope(value);
              }
            },
            child: Row(
              children: <Widget>[
                MergeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Radio<TaskScope>(
                        value: TaskScope.open,
                        focusNode: _scopeOpenFocus,
                      ),
                      const Text('Open tasks'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                MergeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Radio<TaskScope>(
                        value: TaskScope.all,
                        focusNode: _scopeAllFocus,
                      ),
                      const Text('All tasks'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _buildChecklist(
            context,
            title: 'Status (Alt+T)',
            values: const <String>['all', ...viewerTaskStatuses],
            nodes: _statusNodes,
            labelOf: (value) =>
                value == 'all' ? 'All' : viewerStatusLabel(value),
            isSelected: (value) => value == 'all'
                ? tasks.statuses.length == viewerTaskStatuses.length
                : tasks.statuses.contains(value),
            onToggle: (value) => value == 'all'
                ? tasks.setAllStatuses(
                    tasks.statuses.length != viewerTaskStatuses.length,
                  )
                : _toggleStatus(value),
          ),
          _buildChecklist(
            context,
            title: 'Priority (Alt+P)',
            values: viewerTaskPriorities,
            nodes: _priorityNodes,
            labelOf: (value) => value,
            isSelected: tasks.priorities.contains,
            onToggle: tasks.togglePriority,
          ),
          const SizedBox(height: 8),
          _buildLabelsRow(context, tasks),
          const SizedBox(height: 12),
          MergeSemantics(
            child: Row(
              children: <Widget>[
                Checkbox(
                  focusNode: _needsHumanFocus,
                  value: tasks.needsHuman,
                  onChanged: (value) => tasks.setNeedsHuman(value ?? false),
                ),
                const Text('Needs human'),
              ],
            ),
          ),
          SizedBox(
            width: 340,
            child: DropdownButtonFormField<TaskReadiness>(
              initialValue: tasks.readiness,
              focusNode: _readinessFocus,
              isDense: true,
              // The pane can be narrow and the text scale can be 200%; the
              // value shortens instead of overflowing the fixed box.
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Readiness (Alt+R)',
                helperText:
                    'Blocked status and waiting for dependencies are '
                    'different filters',
                helperMaxLines: 2,
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<TaskReadiness>>[
                for (final value in TaskReadiness.values)
                  DropdownMenuItem<TaskReadiness>(
                    value: value,
                    child: Text(
                      value.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  tasks.setReadiness(value);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<TaskSort>(
                  initialValue: tasks.sort,
                  focusNode: _sortFocus,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Sort (Alt+O)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<TaskSort>>[
                    for (final value in TaskSort.values)
                      DropdownMenuItem<TaskSort>(
                        value: value,
                        child: Text(
                          value.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      tasks.setSort(value);
                    }
                  },
                ),
              ),
              Tooltip(
                message: '${tasks.direction.label}; reverse sort (Alt+I)',
                excludeFromSemantics: true,
                child: IconButton(
                  focusNode: _directionFocus,
                  icon: Icon(
                    tasks.direction == SortDirection.ascending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    semanticLabel:
                        '${tasks.direction.label}; reverse sort (Alt+I)',
                  ),
                  onPressed: () => tasks.setDirection(
                    tasks.direction == SortDirection.ascending
                        ? SortDirection.descending
                        : SortDirection.ascending,
                  ),
                ),
              ),
              Tooltip(
                message: 'Alt+C',
                child: TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear filters'),
                ),
              ),
            ],
          ),
          _buildActiveFilters(context, tasks),
        ],
      ),
    );
  }

  Widget _buildChecklist(
    BuildContext context, {
    required String title,
    required List<String> values,
    required Map<String, FocusNode> nodes,
    required String Function(String value) labelOf,
    required bool Function(String value) isSelected,
    required ValueChanged<String> onToggle,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.bodySmall),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: <Widget>[
              for (final value in values)
                MergeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Checkbox(
                        focusNode: nodes[value],
                        value: isSelected(value),
                        onChanged: (_) => onToggle(value),
                      ),
                      Text(labelOf(value)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLabelsRow(BuildContext context, TaskController tasks) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _labels,
            focusNode: _labelsFocus,
            onSubmitted: (_) => _applyLabels(),
            decoration: const InputDecoration(
              labelText: 'Labels (Alt+L)',
              helperText: 'Tasks must have all these labels',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          focusNode: _applyLabelsFocus,
          onPressed: _applyLabels,
          child: const Text('Apply labels'),
        ),
      ],
    );
  }

  /// The active filter groups with one labelled Remove button each.
  Widget _buildActiveFilters(BuildContext context, TaskController tasks) {
    final chips = <Widget>[];
    final query = tasks.query.trim();
    if (query.isNotEmpty) {
      chips.add(
        _ActiveFilterChip(
          label: 'Search: $query',
          onRemove: () {
            _search.clear();
            tasks.setQuery('');
            unawaited(tasks.submitQuery());
          },
        ),
      );
    }
    if (tasks.scope != TaskScope.open) {
      chips.add(
        _ActiveFilterChip(
          label: 'Scope: ${tasks.scope.label}',
          onRemove: () => tasks.setScope(TaskScope.open),
        ),
      );
    }
    for (final status in tasks.statuses.toList()..sort()) {
      chips.add(
        _ActiveFilterChip(
          label: 'Status: ${viewerStatusLabel(status)}',
          onRemove: () => tasks.toggleStatus(status),
        ),
      );
    }
    for (final priority in tasks.priorities.toList()..sort()) {
      chips.add(
        _ActiveFilterChip(
          label: 'Priority: $priority',
          onRemove: () => tasks.togglePriority(priority),
        ),
      );
    }
    for (final label in tasks.labels) {
      chips.add(
        _ActiveFilterChip(
          label: 'Label: $label',
          onRemove: () =>
              tasks.setLabels(tasks.labels.where((value) => value != label)),
        ),
      );
    }
    if (tasks.readiness != TaskReadiness.any) {
      chips.add(
        _ActiveFilterChip(
          label: 'Readiness: ${tasks.readiness.label}',
          onRemove: () => tasks.setReadiness(TaskReadiness.any),
        ),
      );
    }
    if (chips.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Focus(
        focusNode: _activeFiltersFocus,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Active filters',
          child: Wrap(spacing: 8, runSpacing: 4, children: chips),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- status

  Widget _buildStatusLine(BuildContext context, TaskController tasks) {
    final failure = tasks.firstLoadError;
    if (failure != null && !tasks.hasConfirmedData) {
      // The failure view below carries the actionable message on its own.
      return const SizedBox.shrink();
    }
    final sampled = tasks.sampledAtMs;
    final refreshFailure = tasks.refreshFailure;
    // An empty result is explained once, by the list's own empty state,
    // which also carries Clear filters.
    return ViewerStatusLine(
      text: <String>[
        if (tasks.isLoading && !tasks.hasConfirmedData)
          'Loading tasks'
        else if (tasks.totalCount == 1)
          '1 matching task'
        else
          '${tasks.totalCount} matching tasks',
        if (tasks.isLoading && tasks.hasConfirmedData) 'Refreshing',
        if (sampled != null) 'sampled ${viewerTimestamp(context, sampled)}',
      ].join('  |  '),
      detail: refreshFailure != null
          ? 'Refresh failed: ${refreshFailure.message} The rows above are the '
                'last confirmed data.'
          : tasks.notice,
      warning: refreshFailure != null,
    );
  }

  // ---------------------------------------------------------------- list

  Widget _buildList(BuildContext context, TaskController tasks) {
    final failure = tasks.firstLoadError;
    if (failure != null && !tasks.hasConfirmedData) {
      claimFailureViewRegionFocus(widget.api, ViewerRegion.tasks);
      return ViewerFailureView(
        failure: failure,
        heading: 'Could not load tasks',
        onRetry: () => unawaited(widget.model.retryTasks()),
      );
    }
    releaseFailureViewRegionFocus();
    final handles = _handles;
    final itemCount = tasks.totalCount;
    final projectTotal = widget.model.selectedProject?.stats?.total;
    final projectEmpty = projectTotal == 0;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent || !handles.list.hasListFocus) {
          return KeyEventResult.ignored;
        }
        final index = handles.list.focusedRowIndex;
        final item = index == null ? null : tasks.itemAt(index);
        if (item == null) return KeyEventResult.ignored;
        final keyboard = HardwareKeyboard.instance;
        if (event.logicalKey == LogicalKeyboardKey.keyC &&
            keyboard.isControlPressed &&
            !keyboard.isAltPressed &&
            !keyboard.isShiftPressed) {
          unawaited(_runTaskAction(item, index!, _TaskMenuAction.copySummary));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
            (event.logicalKey == LogicalKeyboardKey.f10 &&
                keyboard.isShiftPressed)) {
          unawaited(_showTaskMenu(item, index!));
          return KeyEventResult.handled;
        }
        final action = _taskActionForKey(event);
        if (action != null &&
            _taskActionEnabled(
              action,
              item,
              widget.model.editor.canWrite && !widget.model.editor.isSaving,
            )) {
          unawaited(_runTaskAction(item, index!, action));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AccessibleVirtualList(
        controller: handles.list,
        itemCount: itemCount,
        itemExtent: viewerRowExtent(context),
        listLabel: 'Tasks in ${widget.model.selectedProjectName}',
        emptyLabel: tasks.isLoading
            ? 'Loading tasks'
            : projectEmpty
            ? 'This project has no tasks'
            : 'No tasks match these filters',
        emptyAction: tasks.isLoading || projectEmpty
            ? null
            : Tooltip(
                message: 'Alt+C',
                child: TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear filters'),
                ),
              ),
        itemKeyBuilder: (index) => ValueKey<String>(
          tasks.itemAt(index)?.canonicalId ?? 'tasks-row-$index',
        ),
        rowSemanticsBuilder: (index) {
          final item = tasks.itemAt(index);
          if (item == null) {
            return AccessibleRowSemantics(
              label: 'Task row ${index + 1} is not loaded yet',
              value: viewerRowPosition(index, itemCount),
            );
          }
          return AccessibleRowSemantics(
            label: viewerTaskRowLabel(item),
            value: viewerRowPosition(index, itemCount),
          );
        },
        isRowReady: tasks.isRowReady,
        onPendingRowSlow: (index) => widget.api.announceProgress(
          'Loading row ${index + 1}',
          clipId: 'loading',
        ),
        onSelectedIndexChanged: _onRowSelected,
        onActivate: _onRowActivated,
        excludeRowChildSemantics: false,
        rowBuilder: (context, index, selected) {
          final item = tasks.itemAt(index);
          if (item == null) {
            return const _TaskRowPlaceholder();
          }
          return GestureDetector(
            excludeFromSemantics: true,
            onSecondaryTapDown: (event) =>
                unawaited(_showTaskMenu(item, index, event.globalPosition)),
            child: Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(child: _TaskRowTile(item: item)),
                ),
                Tooltip(
                  message: 'Actions for ${item.canonicalId}',
                  excludeFromSemantics: true,
                  child: IconButton(
                    icon: Icon(
                      Icons.more_horiz,
                      semanticLabel: 'Actions for ${item.canonicalId}',
                    ),
                    onPressed: () => unawaited(_showTaskMenu(item, index)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showTaskMenu(
    TaskItem item,
    int index, [
    Offset? position,
  ]) async {
    final openedTasks = _tasks;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final origin =
        position ??
        (context.findRenderObject()! as RenderBox).localToGlobal(
          const Offset(24, 100),
        );
    final canWrite =
        widget.model.editor.canWrite && !widget.model.editor.isSaving;
    // Only the open task's dependencies are loaded; another row gets no hint
    // rather than an extra CLI call.
    final loaded = widget.model.detail?.detail;
    final doneHint =
        loaded != null && loaded.id == item.id && loaded.status != 'done'
        ? viewerMarkDoneHint(loaded.dependencySummaries)
        : null;
    final action = await showMenu<_TaskMenuAction>(
      context: context,
      requestFocus: true,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final action in _TaskMenuAction.values)
          _TaskActionMenuItem(
            action: action,
            item: item,
            canWrite: canWrite,
            hint: action == _TaskMenuAction.done ? doneHint : null,
          ),
      ],
    );
    if (!mounted) return;
    _handles.list.focusRegion();
    if (action != null && identical(openedTasks, _tasks)) {
      await _runTaskAction(item, index, action);
    }
  }

  Future<void> _runTaskAction(
    TaskItem item,
    int index,
    _TaskMenuAction action,
  ) async {
    try {
      if (action == _TaskMenuAction.copySummary) {
        await Clipboard.setData(
          ClipboardData(text: '${item.canonicalId} ${item.title}'),
        );
        widget.api.announce('Task ID and name copied', dynamic: true);
        return;
      }
      final model = widget.model;
      final tasks = model.tasks;
      if (tasks?.itemAt(index)?.id != item.id ||
          !await model.selectTaskRow(index)) {
        return;
      }
      await model.openTaskIndex(index);
      if (!mounted ||
          !identical(tasks, model.tasks) ||
          model.detail?.detail?.id != item.id) {
        return;
      }
      switch (action) {
        case _TaskMenuAction.copySummary:
          break;
        case _TaskMenuAction.copyContent:
          final detail = model.detail!.detail!;
          await Clipboard.setData(
            ClipboardData(
              text: '${detail.canonicalId} ${detail.title}\n\n${detail.body}',
            ),
          );
          widget.api.announce('Task content copied', dynamic: true);
        case _TaskMenuAction.edit:
          await model.beginEditTask();
        case _TaskMenuAction.done:
          await model.markDoneTask();
        case _TaskMenuAction.block:
          await model.changeTaskStatus('blocked');
        case _TaskMenuAction.cancel:
          await model.changeTaskStatus('cancelled');
      }
    } on Object catch (error) {
      widget.api.announce('Task action failed: $error', dynamic: true);
    }
  }
}

/// "Filters", the active-filter count as a badge and the scope as a chip.
///
/// The screen reader hears the complete sentence, for example
/// "Filters (Open tasks, 1 active)", instead of the pieces.
class _FiltersButtonLabel extends StatelessWidget {
  const _FiltersButtonLabel({required this.tasks});

  final TaskController tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = tasks.activeFilterCount;
    final scope = tasks.scope.label;
    return Semantics(
      label: 'Filters ($scope${count == 0 ? '' : ', $count active'})',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Filters'),
          if (count > 0) ...<Widget>[
            const SizedBox(width: ViewerSpace.xs),
            Badge.count(
              count: count,
              backgroundColor: colors.primary,
              textColor: colors.onPrimary,
            ),
          ],
          const SizedBox(width: ViewerSpace.s),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: ViewerSpace.s,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outline),
              borderRadius: BorderRadius.circular(ViewerSpace.s),
            ),
            child: Text(
              scope,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// One active filter group: its plain-text description plus a button that is
/// named after what it removes, so a screen reader never hears "Remove" alone.
class _ActiveFilterChip extends StatelessWidget {
  const _ActiveFilterChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(width: 4),
        Semantics(
          container: true,
          button: true,
          label: 'Remove $label',
          onTap: onRemove,
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: onRemove,
              style: TextButton.styleFrom(
                minimumSize: const Size(1, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Remove'),
            ),
          ),
        ),
      ],
    );
  }
}

/// One task row: ID, priority, status and title, then labels and the
/// dependency-waiting indicator. The order matches the accessible row name.
enum _TaskMenuAction { copySummary, copyContent, edit, done, block, cancel }

class _TaskRowTile extends StatelessWidget {
  const _TaskRowTile({required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dependencyParts = viewerDependencyCountParts(item);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(item.canonicalId, style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Text(item.priority, style: theme.textTheme.bodySmall),
              const SizedBox(width: 8),
              Text(
                viewerStatusLabel(item.status),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    item.labels.isEmpty
                        ? 'No labels'
                        : 'Labels ${item.labels.join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (dependencyParts.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  // Natural width when it fits; a narrow pane shortens only
                  // the visible copy, and the row's accessible name keeps the
                  // full wording.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.6,
                    ),
                    child: Text(
                      dependencyParts.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row the viewer has not fetched yet; it never invents task content.
class _TaskRowPlaceholder extends StatelessWidget {
  const _TaskRowPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      alignment: Alignment.centerLeft,
      child: Text(
        'Loading row',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
      ),
    );
  }
}

bool _taskActionEnabled(_TaskMenuAction action, TaskItem item, bool canWrite) =>
    switch (action) {
      _TaskMenuAction.copySummary || _TaskMenuAction.copyContent => true,
      _TaskMenuAction.edit => canWrite,
      _TaskMenuAction.done => canWrite && item.status != 'done',
      _TaskMenuAction.block => canWrite && item.status != 'blocked',
      _TaskMenuAction.cancel => canWrite && item.status != 'cancelled',
    };

_TaskMenuAction? _taskActionForKey(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (event is! KeyDownEvent ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isShiftPressed ||
      keyboard.isMetaPressed) {
    return null;
  }
  return switch (event.logicalKey) {
    LogicalKeyboardKey.keyC => _TaskMenuAction.copySummary,
    LogicalKeyboardKey.keyV => _TaskMenuAction.copyContent,
    LogicalKeyboardKey.keyE => _TaskMenuAction.edit,
    LogicalKeyboardKey.keyD => _TaskMenuAction.done,
    LogicalKeyboardKey.keyB => _TaskMenuAction.block,
    LogicalKeyboardKey.keyX => _TaskMenuAction.cancel,
    _ => null,
  };
}

class _TaskActionMenuItem extends PopupMenuItem<_TaskMenuAction> {
  _TaskActionMenuItem({
    required this.action,
    required this.item,
    required this.canWrite,
    String? hint,
  }) : super(
         value: action,
         enabled: _taskActionEnabled(action, item, canWrite),
         child: _TaskActionLabel(
           label: switch (action) {
             _TaskMenuAction.copySummary => 'Copy ID and name (C)',
             _TaskMenuAction.copyContent => 'Copy content (V)',
             _TaskMenuAction.edit => 'Edit task (E)',
             _TaskMenuAction.done => 'Mark done (D)',
             _TaskMenuAction.block => 'Block task (B)',
             _TaskMenuAction.cancel => 'Cancel task (X)',
           },
           hint: hint,
         ),
       );
  final _TaskMenuAction action;
  final TaskItem item;
  final bool canWrite;
  @override
  PopupMenuItemState<_TaskMenuAction, _TaskActionMenuItem> createState() =>
      _TaskActionMenuItemState();
}

class _TaskActionMenuItemState
    extends PopupMenuItemState<_TaskMenuAction, _TaskActionMenuItem> {
  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.action == _TaskMenuAction.copySummary,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      final keys = HardwareKeyboard.instance;
      if (event is! KeyDownEvent ||
          keys.isControlPressed ||
          keys.isAltPressed ||
          keys.isShiftPressed ||
          keys.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      if (node.hasPrimaryFocus &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space)) {
        if (widget.enabled) Navigator.of(context).pop(widget.action);
        return KeyEventResult.handled;
      }
      final action = _taskActionForKey(event);
      if (action == null) return KeyEventResult.ignored;
      if (_taskActionEnabled(action, widget.item, widget.canWrite)) {
        Navigator.of(context).pop(action);
      }
      return KeyEventResult.handled;
    },
    child: super.build(context),
  );
}

/// A menu item's text, with an optional [hint] shown under it and spoken as
/// part of its accessible name (the Mark done prerequisites hint).
class _TaskActionLabel extends StatelessWidget {
  const _TaskActionLabel({required this.label, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final hint = this.hint;
    if (hint == null) {
      return Text(label);
    }
    return Semantics(
      // Flutter's Windows bridge transfers labels, but omits semantics hints.
      label: '$label. $hint',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label),
          ExcludeSemantics(
            child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
