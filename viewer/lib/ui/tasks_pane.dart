/// Tasks region of the real workspace: the combined query, its filters, the
/// virtual task list and the direct row jump.
///
/// Contract: viewer/spec.md sections 4.3, 5 and 6 with viewer/design.md
/// sections 5 and 6. Filters are delegated to the workspace model, whose task
/// controller owns the request parameters, the debounce and the paging.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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

class _ViewerTasksPaneState extends State<ViewerTasksPane> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _labels = TextEditingController();
  final TextEditingController _goToRow = TextEditingController();
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
  final FocusNode _goToRowFocus = FocusNode(debugLabel: 'tasks go to row');
  final FocusNode _activeFiltersFocus = FocusNode(
    debugLabel: 'tasks active filters',
  );
  final Map<String, FocusNode> _statusNodes = <String, FocusNode>{
    for (final status in viewerTaskStatuses)
      status: FocusNode(debugLabel: 'tasks status $status'),
  };
  final Map<String, FocusNode> _priorityNodes = <String, FocusNode>{
    for (final priority in viewerTaskPriorities)
      priority: FocusNode(debugLabel: 'tasks priority $priority'),
  };

  TaskController? _bound;
  bool _filtersVisible = true;
  String? _goToRowError;

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
    _goToRow.dispose();
    _scopeOpenFocus.dispose();
    _scopeAllFocus.dispose();
    _labelsFocus.dispose();
    _applyLabelsFocus.dispose();
    _needsHumanFocus.dispose();
    _readinessFocus.dispose();
    _sortFocus.dispose();
    _directionFocus.dispose();
    _goToRowFocus.dispose();
    _activeFiltersFocus.dispose();
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
        _scopeFocus(tasks.scope).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.statusChecklist':
        _firstStatusFocus(tasks).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.priorityChecklist':
        _firstPriorityFocus(tasks).requestFocus();
        return KeyEventResult.handled;
      case 'tasks.labelsField':
        _showFilters();
        _labelsFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.applyLabels':
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
        _sortFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.direction':
        _directionFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.clearFilters':
        _clearFilters();
        return KeyEventResult.handled;
      case 'tasks.goToRowField':
        _goToRowFocus.requestFocus();
        return KeyEventResult.handled;
      case 'tasks.goToRow':
        _goToSelectedRow();
        return KeyEventResult.handled;
      case 'tasks.removeActiveFilterGroup':
        _activeFiltersFocus.requestFocus();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  FocusNode _scopeFocus(TaskScope scope) =>
      scope == TaskScope.open ? _scopeOpenFocus : _scopeAllFocus;

  FocusNode _firstStatusFocus(TaskController tasks) {
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

  /// Validates the typed row number against the reported total; never clamps.
  void _goToSelectedRow() {
    final tasks = _tasks;
    if (tasks == null) {
      return;
    }
    final total = tasks.totalCount;
    final row = int.tryParse(_goToRow.text.trim());
    if (total == 0) {
      _reportGoToRow('There are no task rows to jump to.');
      return;
    }
    if (row == null || row < 1 || row > total) {
      _reportGoToRow('Enter a row number from 1 to $total. Nothing moved.');
      return;
    }
    setState(() => _goToRowError = null);
    _handles.list.goToIndex(row - 1);
    unawaited(_ensureRow(row - 1));
  }

  void _reportGoToRow(String message) {
    setState(() => _goToRowError = message);
    widget.api.announce(message, dynamic: true);
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
    widget.model.selectTaskIndex(index);
    unawaited(_ensureRow(index));
  }

  void _onRowActivated(int index) {
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
                ViewerPaneRegion(
                  maxHeight: budget.footer,
                  child: _buildGoToRow(context, tasks),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildHeading(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
    child: Text(
      'Tasks in ${widget.model.selectedProjectName}',
      style: Theme.of(context).textTheme.titleSmall,
    ),
  );

  // -------------------------------------------------------------- filters

  Widget _buildCollapsedFilters(BuildContext context, TaskController tasks) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: <Widget>[
          TextButton(
            onPressed: () => setState(() => _filtersVisible = true),
            child: Text(
              tasks.activeFilterCount == 0
                  ? 'Filters'
                  : 'Filters (${tasks.activeFilterCount} active)',
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Alt+F opens the filter controls',
            style: Theme.of(context).textTheme.bodySmall,
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
                Radio<TaskScope>(
                  value: TaskScope.open,
                  focusNode: _scopeOpenFocus,
                ),
                const Text('Open tasks'),
                const SizedBox(width: 12),
                Radio<TaskScope>(
                  value: TaskScope.all,
                  focusNode: _scopeAllFocus,
                ),
                const Text('All tasks'),
              ],
            ),
          ),
          _buildChecklist(
            context,
            title: 'Status (Alt+T)',
            values: viewerTaskStatuses,
            nodes: _statusNodes,
            labelOf: viewerStatusLabel,
            isSelected: tasks.statuses.contains,
            onToggle: _toggleStatus,
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
          _buildLabelsRow(context, tasks),
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
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
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<SortDirection>(
                  initialValue: tasks.direction,
                  focusNode: _directionFocus,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Direction (Alt+I)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<SortDirection>>[
                    for (final value in SortDirection.values)
                      DropdownMenuItem<SortDirection>(
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
                      tasks.setDirection(value);
                    }
                  },
                ),
              ),
              Tooltip(
                message: 'Alt+C',
                child: TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear filters'),
                ),
              ),
              Tooltip(
                message: 'Alt+F',
                child: TextButton(
                  onPressed: () => setState(() => _filtersVisible = false),
                  child: const Text('Hide filters'),
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
    final projectTotal = widget.model.selectedProject?.stats?.total;
    final sampled = tasks.sampledAtMs;
    final refreshFailure = tasks.refreshFailure;
    final line = ViewerStatusLine(
      text: <String>[
        if (tasks.isLoading && !tasks.hasConfirmedData)
          'Loading tasks'
        else if (tasks.totalCount == 0 && projectTotal == 0)
          'This project has no tasks'
        else if (tasks.totalCount == 0)
          'No tasks match these filters'
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
    if (tasks.totalCount != 0 || tasks.isLoading || projectTotal == 0) {
      return line;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        line,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: TextButton(
            onPressed: _clearFilters,
            child: const Text('Clear filters'),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- list

  Widget _buildList(BuildContext context, TaskController tasks) {
    final failure = tasks.firstLoadError;
    if (failure != null && !tasks.hasConfirmedData) {
      return ViewerFailureView(
        failure: failure,
        heading: 'Could not load tasks',
        onRetry: () => unawaited(widget.model.retryTasks()),
      );
    }
    final handles = _handles;
    final itemCount = tasks.totalCount;
    return AccessibleVirtualList(
      controller: handles.list,
      itemCount: itemCount,
      itemExtent: viewerRowExtent(context),
      listLabel: 'Tasks in ${widget.model.selectedProjectName}',
      emptyLabel: tasks.isLoading
          ? 'Loading tasks'
          : 'No tasks match these filters',
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
      rowBuilder: (context, index, selected) {
        final item = tasks.itemAt(index);
        if (item == null) {
          return const _TaskRowPlaceholder();
        }
        return _TaskRowTile(item: item, selected: selected);
      },
    );
  }

  // ------------------------------------------------------------- go to row

  Widget _buildGoToRow(BuildContext context, TaskController tasks) {
    final theme = Theme.of(context);
    final error = _goToRowError;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // A Wrap keeps the row count reachable in a narrow pane instead of
          // overflowing the row (design.md section 2, 800x600 minimum).
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _goToRow,
                  focusNode: _goToRowFocus,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _goToSelectedRow(),
                  decoration: const InputDecoration(
                    labelText: 'Go to row',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              TextButton(onPressed: _goToSelectedRow, child: const Text('Go')),
              Text(
                '1 to ${tasks.totalCount}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
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
class _TaskRowTile extends StatelessWidget {
  const _TaskRowTile({required this.item, required this.selected});

  final TaskItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = item.waitingDependencyCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: selected ? theme.colorScheme.primaryContainer : null,
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
          Row(
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
              if (waiting > 0) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  'Waiting on $waiting '
                  '${waiting == 1 ? 'dependency' : 'dependencies'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
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
