/// Projects region of the real workspace: query controls, the virtual catalog
/// and the selected-project summary.
///
/// Contract: viewer/spec.md sections 4.2 and 5 with viewer/design.md sections
/// 4 and 6. The pane renders [ViewerWorkspaceModel] and owns only the local
/// control state a rendering layer needs (focus nodes and the Go to row text).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/project_controller.dart';
import '../data/models.dart';
import '../platform/project_launch.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'commands.dart';
import 'enrichment_preview_dialog.dart';
import 'viewer_controls.dart';
import 'viewer_format.dart';
import 'workspace_model.dart';

/// Projects region bound to one workspace model.
class ViewerProjectsPane extends StatefulWidget {
  const ViewerProjectsPane({super.key, required this.api, required this.model});

  final ViewerShellApi api;
  final ViewerWorkspaceModel model;

  @override
  State<ViewerProjectsPane> createState() => _ViewerProjectsPaneState();
}

class _ViewerProjectsPaneState extends State<ViewerProjectsPane>
    with FailureViewRegionFocus<ViewerProjectsPane> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _goToRow = TextEditingController();
  final FocusNode _stateFocus = FocusNode(debugLabel: 'projects state filter');
  final FocusNode _sortFocus = FocusNode(debugLabel: 'projects sort');
  final FocusNode _directionFocus = FocusNode(debugLabel: 'projects direction');
  final FocusNode _goToRowFocus = FocusNode(debugLabel: 'projects go to row');
  final FocusNode _summaryFocus = FocusNode(debugLabel: 'projects summary');
  final FocusNode _previewFocus = FocusNode(
    debugLabel: 'projects preview enrichment',
  );
  bool _compactRows = false;
  final ProjectLauncher _projectLauncher = const ProjectLauncher();
  String? _goToRowError;

  ProjectController get _projects => widget.model.projectList;

  ViewerRegionHandles get _handles =>
      widget.api.handlesFor(ViewerRegion.projects);

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.projects, _onScopeCommand);
    _projects.addListener(_syncExternalQuery);
    _search.text = _projects.query;
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.projects, null);
    _projects.removeListener(_syncExternalQuery);
    _search.dispose();
    _goToRow.dispose();
    _stateFocus.dispose();
    _sortFocus.dispose();
    _directionFocus.dispose();
    _goToRowFocus.dispose();
    _summaryFocus.dispose();
    _previewFocus.dispose();
    super.dispose();
  }

  /// Mirrors a query the pane did not type, for example a restored preference.
  void _syncExternalQuery() {
    final query = _projects.query;
    if (query != _search.text && !_handles.filterFocus.hasFocus) {
      _search.text = query;
    }
  }

  // ------------------------------------------------------------- commands

  KeyEventResult _onScopeCommand(String id) {
    if (id.startsWith('projects.state.')) {
      _projects.setState(
        ProjectStateFilter.fromWire(id.substring('projects.state.'.length)),
      );
      return KeyEventResult.handled;
    }
    switch (id) {
      case 'projects.clearSearch':
        _clearSearch();
        return KeyEventResult.handled;
      case 'projects.stateFilter':
        _stateFocus.requestFocus();
        return KeyEventResult.handled;
      case 'projects.sort':
        _sortFocus.requestFocus();
        return KeyEventResult.handled;
      case 'projects.direction':
        _projects.setDirection(
          _projects.direction == SortDirection.ascending
              ? SortDirection.descending
              : SortDirection.ascending,
        );
        return KeyEventResult.handled;
      case 'projects.clearFilters':
        _clearFilters();
        return KeyEventResult.handled;
      case 'projects.goToRowField':
        _goToRowFocus.requestFocus();
        return KeyEventResult.handled;
      case 'projects.goToRow':
        _goToSelectedRow();
        return KeyEventResult.handled;
      case 'projects.summary':
        _summaryFocus.requestFocus();
        return KeyEventResult.handled;
      case 'projects.copyProjectId':
        unawaited(_copyProjectId());
        return KeyEventResult.handled;
      case 'projects.enrichClipboard':
        unawaited(_enrichClipboard());
        return KeyEventResult.handled;
      case 'projects.previewEnrichment':
        unawaited(_previewEnrichment());
        return KeyEventResult.handled;
      case 'projects.rowDensity':
        _toggleRowDensity();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _clearSearch() {
    _search.clear();
    _projects.setQuery('');
    unawaited(_projects.submitQuery());
  }

  void _clearFilters() {
    _search.clear();
    _projects.clearFilters();
  }

  void _toggleRowDensity() {
    setState(() => _compactRows = !_compactRows);
    widget.api.announce(
      _compactRows
          ? 'Compact project rows. Dates stay in the row names and the '
                'selected summary.'
          : 'Expanded project rows with started and last-write dates.',
      dynamic: true,
    );
  }

  /// Validates the typed row number against the reported total; never clamps.
  void _goToSelectedRow() {
    final total = _projects.totalCount;
    final typed = _goToRow.text.trim();
    final row = int.tryParse(typed);
    if (total == 0) {
      _reportGoToRow('There are no project rows to jump to.');
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
    await widget.model.ensureProjectRow(index);
    if (!mounted) {
      return;
    }
    _handles.list.retryPending();
  }

  Future<void> _copyProjectId() async {
    final id = _projects.selectedProjectId;
    if (id == null) {
      widget.api.announce(
        'Select a project before copying its ID.',
        dynamic: true,
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: id));
    widget.api.announce('Project ID copied', clipId: 'project_id_copied');
  }

  /// The same handler Ctrl+E reaches: button and shortcut never diverge.
  Future<void> _enrichClipboard() => widget.model.enrichClipboard();

  /// Preview reads the clipboard and shows both texts; it never writes one.
  Future<void> _previewEnrichment() async {
    final preview = await widget.model.previewEnrichment();
    if (preview == null || !mounted) {
      return;
    }
    await widget.api.showModal<void>(
      CommandScope.enrichmentPreview,
      (context) => ViewerEnrichmentPreviewDialog(preview: preview),
    );
    if (mounted) {
      // Close returns to the control that started the preview.
      _previewFocus.requestFocus();
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final projects = _projects;
        return LayoutBuilder(
          builder: (context, constraints) {
            final budget = viewerPaneBudgetFor(context, constraints.maxHeight);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ViewerPaneRegion(
                  maxHeight: budget.header,
                  child: _buildFilters(context, projects),
                ),
                ViewerPaneRegion(
                  maxHeight: budget.status,
                  child: _buildStatusLine(context, projects),
                ),
                Expanded(child: _buildList(context, projects)),
                ViewerPaneRegion(
                  maxHeight: budget.footer,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (projects.totalCount > 0) ...<Widget>[
                        _buildGoToRow(context, projects),
                        const Divider(height: 1),
                      ],
                      _buildSummary(context, projects),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------- filters

  Widget _buildFilters(BuildContext context, ProjectController projects) {
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
                  onChanged: projects.setQuery,
                  onSubmitted: (_) => unawaited(projects.submitQuery()),
                  decoration: const InputDecoration(
                    labelText: 'Search projects (Ctrl+F)',
                    helperText: 'Search name, path or project ID',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _clearSearch,
                child: const Text('Clear search'),
              ),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<ProjectStateFilter>(
                  initialValue: projects.stateFilter,
                  focusNode: _stateFocus,
                  isDense: true,
                  // The pane can be narrow and the text scale can be 200%;
                  // the value shortens instead of overflowing the fixed box.
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'State filter (Alt+S)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<ProjectStateFilter>>[
                    for (final value in ProjectStateFilter.values)
                      DropdownMenuItem<ProjectStateFilter>(
                        value: value,
                        child: Text(
                          "${value.label} (Alt+${value.index + 1})",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      projects.setState(value);
                    }
                  },
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<ProjectSort>(
                  initialValue: projects.sort,
                  focusNode: _sortFocus,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Sort (Alt+O)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<ProjectSort>>[
                    for (final value in ProjectSort.values)
                      DropdownMenuItem<ProjectSort>(
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
                      projects.setSort(value);
                    }
                  },
                ),
              ),
              IconButton(
                focusNode: _directionFocus,
                tooltip: '${projects.direction.label}; reverse sort (Alt+I)',
                icon: Icon(
                  projects.direction == SortDirection.ascending
                      ? Icons.arrow_upward
                      : Icons.arrow_downward,
                ),
                onPressed: () => projects.setDirection(
                  projects.direction == SortDirection.ascending
                      ? SortDirection.descending
                      : SortDirection.ascending,
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
                message: 'Alt+W',
                child: TextButton(
                  onPressed: _toggleRowDensity,
                  child: Text(_compactRows ? 'Expanded rows' : 'Compact rows'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- status

  Widget _buildStatusLine(BuildContext context, ProjectController projects) {
    final blocking = widget.model.startupError ?? projects.firstLoadError;
    if (blocking != null && !projects.hasConfirmedData) {
      // The failure view below carries the actionable message on its own.
      return const SizedBox.shrink();
    }
    final segments = <String>[
      if (projects.isLoading && !projects.hasConfirmedData)
        'Loading projects'
      else if (projects.totalCount == 0)
        'No projects match these filters'
      else if (projects.totalCount == 1)
        '1 matching project'
      else
        '${projects.totalCount} matching projects',
      if (projects.isLoading && projects.hasConfirmedData) 'Refreshing',
    ];
    final sampled = projects.sampledAtMs;
    if (sampled != null) {
      segments.add('sampled ${viewerTimestamp(context, sampled)}');
    }
    final failure = projects.refreshFailure;
    return ViewerStatusLine(
      text: segments.join('  |  '),
      detail: failure != null
          ? 'Refresh failed: ${failure.message} The rows above are the last '
                'confirmed data.'
          : projects.notice,
      warning: failure != null,
    );
  }

  // ---------------------------------------------------------------- list

  Widget _buildList(BuildContext context, ProjectController projects) {
    final blocking = widget.model.startupError ?? projects.firstLoadError;
    if (blocking != null && !projects.hasConfirmedData) {
      claimFailureViewRegionFocus(widget.api, ViewerRegion.projects);
      return ViewerFailureView(
        failure: blocking,
        onRetry: () => unawaited(widget.model.retryStartup()),
      );
    }
    releaseFailureViewRegionFocus();
    final handles = _handles;
    final itemCount = projects.totalCount;
    final duplicates = _duplicateProjectNames(projects);
    return AccessibleVirtualList(
      controller: handles.list,
      itemCount: itemCount,
      itemExtent: viewerRowExtent(context, textLines: _compactRows ? 2 : 3),
      listLabel: 'Projects',
      emptyLabel: projects.isLoading
          ? 'Loading projects'
          : 'No projects match these filters',
      itemKeyBuilder: (index) => ValueKey<String>(
        projects.itemAt(index)?.projectId ?? 'projects-row-$index',
      ),
      rowSemanticsBuilder: (index) {
        final item = projects.itemAt(index);
        if (item == null) {
          return AccessibleRowSemantics(
            label: 'Project row ${index + 1} is not loaded yet',
            value: viewerRowPosition(index, itemCount),
          );
        }
        return AccessibleRowSemantics(
          label: viewerProjectRowLabel(
            context,
            item,
            includeRoot: duplicates.contains(item.name),
          ),
          value: viewerRowPosition(index, itemCount),
        );
      },
      isRowReady: projects.isRowReady,
      onPendingRowSlow: (index) => widget.api.announceProgress(
        'Loading row ${index + 1}',
        clipId: 'loading',
      ),
      onSelectedIndexChanged: _onRowSelected,
      onActivate: _onRowActivated,
      excludeRowChildSemantics: false,
      rowBuilder: (context, index, selected) {
        final item = projects.itemAt(index);
        if (item == null) {
          return const _ProjectRowPlaceholder();
        }
        return _ProjectRowTile(
          item: item,
          compact: _compactRows,
          onAction: (action) =>
              unawaited(_runProjectAction(item, index, action)),
          canArchive: widget.model.canArchiveProjects,
        );
      },
    );
  }

  Future<void> _runProjectAction(
    ProjectItem item,
    int index,
    _ProjectMenuAction action,
  ) async {
    final root = item.roots.isEmpty ? null : item.roots.first;
    try {
      switch (action) {
        case _ProjectMenuAction.explorer:
        case _ProjectMenuAction.alacritty:
        case _ProjectMenuAction.terminal:
          if (root == null) return;
          await _projectLauncher.open(switch (action) {
            _ProjectMenuAction.explorer => ProjectLaunchTarget.explorer,
            _ProjectMenuAction.alacritty => ProjectLaunchTarget.alacritty,
            _ => ProjectLaunchTarget.terminal,
          }, root);
          return;
        case _ProjectMenuAction.copyPath:
          if (root == null) return;
          await Clipboard.setData(ClipboardData(text: root));
          widget.api.announce('Project path copied', dynamic: true);
          return;
        case _ProjectMenuAction.archive:
          await widget.model.setProjectArchived(
            item,
            archived: item.archivedAtMs == null,
          );
          widget.api.announce(
            item.archivedAtMs == null
                ? '${item.name} archived'
                : '${item.name} unarchived',
            dynamic: true,
          );
          return;
        case _ProjectMenuAction.copyId:
          await Clipboard.setData(ClipboardData(text: item.projectId));
          widget.api.announce('Project ID copied', dynamic: true);
          return;
        case _ProjectMenuAction.enrich:
          if (await widget.model.selectProjectRow(index)) {
            await widget.model.enrichClipboard();
          }
          return;
      }
    } on Object catch (error) {
      widget.api.announce('Project action failed: $error', dynamic: true);
    }
  }

  void _onRowSelected(int index) {
    unawaited(_selectRow(index));
  }

  /// Arrow navigation runs the dirty-draft guard first; a refusal puts the
  /// highlight back on the project the open editor still edits (spec.md 7).
  Future<void> _selectRow(int index) async {
    final moved = await widget.model.selectProjectRow(index);
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
    final current = widget.model.projectList.selectedIndex;
    if (current != null) {
      _handles.list.refuseMove(refusedIndex, current);
    }
  }

  void _onRowActivated(int index) {
    unawaited(_activateRow(index));
  }

  Future<void> _activateRow(int index) async {
    if (!await widget.model.selectProjectRow(index)) {
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
    if (widget.api.isReducedLayout) {
      // In a reduced layout the Tasks pane replaces this one, so opening a
      // project has to reveal it. The full layout keeps the focus here.
      widget.api.revealRegion(ViewerRegion.tasks);
    }
  }

  /// Names that appear more than once among the rows the viewer has loaded.
  ///
  /// Those rows carry their distinguishing root inside the accessible name;
  /// unique names stay short because the summary always shows every root.
  Set<String> _duplicateProjectNames(ProjectController projects) {
    final counts = <String, int>{};
    for (var index = 0; index < projects.totalCount; index++) {
      final item = projects.itemAt(index);
      if (item == null) {
        continue;
      }
      counts[item.name] = (counts[item.name] ?? 0) + 1;
    }
    return <String>{
      for (final entry in counts.entries)
        if (entry.value > 1) entry.key,
    };
  }

  // ------------------------------------------------------------- go to row

  Widget _buildGoToRow(BuildContext context, ProjectController projects) {
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
                '1 to ${projects.totalCount}',
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

  // -------------------------------------------------------------- summary

  Widget _buildSummary(BuildContext context, ProjectController projects) {
    final theme = Theme.of(context);
    final item = projects.selectedItem;
    final stats = item?.stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Focus(
        focusNode: _summaryFocus,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Selected project',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (item == null)
                Text(
                  'No project is selected. Choose a row to see its '
                  'statistics and bound roots.',
                  style: theme.textTheme.bodySmall,
                )
              else ...<Widget>[
                Text(item.name, style: theme.textTheme.bodyMedium),
                _summaryLine(
                  context,
                  stats == null
                      ? 'Unavailable: '
                            '${item.error?.message ?? 'the project database '
                                    'could not be read'}'
                      : '${stats.open} open / ${stats.total} total / '
                            '${stats.blocked} blocked',
                ),
                _summaryLine(
                  context,
                  stats == null || stats.progressPercent == null
                      ? 'Not applicable'
                      : 'Progress ${viewerPercent(stats.progressPercent!)} '
                            'percent',
                ),
                _summaryLine(
                  context,
                  'Started (first task): ${_summaryDate(context, stats?.startedMs)}',
                ),
                _summaryLine(
                  context,
                  'Last task write: ${_summaryTimestamp(context, stats?.lastWriteMs)}',
                ),
                _summaryLine(
                  context,
                  'Sample time: ${viewerTimestamp(context, item.sampledAtMs)}',
                ),
                _summaryLine(context, 'UUID: ${item.projectId}'),
                if (item.roots.isEmpty)
                  _summaryLine(context, 'Root: no bound root')
                else
                  for (final root in item.roots)
                    _summaryLine(context, 'Root: $root'),
              ],
              const SizedBox(height: 8),
              _buildClipboardActions(context, projects, item),
            ],
          ),
        ),
      ),
    );
  }

  /// The selected project's toolbar.
  ///
  /// Both clipboard buttons stay in place when they cannot act, so the reason
  /// is readable instead of hidden in a missing control (spec.md section 8).
  Widget _buildClipboardActions(
    BuildContext context,
    ProjectController projects,
    ProjectItem? item,
  ) {
    final reason = widget.model.clipboardBlockedReason;
    final busy = widget.model.clipboard.isRunning;
    final canEnrich = reason == null && !busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              reason,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            FilledButton(
              onPressed: item == null
                  ? null
                  : () => unawaited(_copyProjectId()),
              child: const Text('Copy project ID (Alt+Y)'),
            ),
            if (item != null && item.stats == null)
              OutlinedButton(
                onPressed: () => unawaited(projects.retry()),
                child: const Text('Retry'),
              ),
            Tooltip(
              message:
                  reason ??
                  'Enrich the clipboard in ${item?.name ?? 'the selected '
                          'project'} and write the result back (Alt+E).',
              child: TextButton(
                onPressed: canEnrich
                    ? () => unawaited(_enrichClipboard())
                    : null,
                child: const Text('Enrich clipboard'),
              ),
            ),
            Tooltip(
              message:
                  reason ??
                  'Preview enrichment without writing the clipboard (Alt+P).',
              child: Focus(
                focusNode: _previewFocus,
                child: TextButton(
                  onPressed: canEnrich
                      ? () => unawaited(_previewEnrichment())
                      : null,
                  child: const Text('Preview enrichment'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryLine(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  String _summaryDate(BuildContext context, int? epochMs) =>
      epochMs == null ? 'No recorded tasks' : viewerDate(context, epochMs);

  String _summaryTimestamp(BuildContext context, int? epochMs) =>
      epochMs == null ? 'No recorded tasks' : viewerTimestamp(context, epochMs);
}

/// One project row: name with progress, counts with the primary root, and (in
/// the expanded density) both dates.
enum _ProjectMenuAction {
  explorer,
  alacritty,
  terminal,
  copyPath,
  archive,
  copyId,
  enrich,
}

class _ProjectRowTile extends StatelessWidget {
  const _ProjectRowTile({
    required this.item,
    required this.compact,
    required this.onAction,
    required this.canArchive,
  });

  final ProjectItem item;
  final bool compact;
  final ValueChanged<_ProjectMenuAction> onAction;
  final bool canArchive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = item.stats;
    final progress = stats?.progressPercent;
    final progressText = stats == null
        ? 'Unavailable'
        : progress == null
        ? 'Not applicable'
        : '${viewerPercent(progress)}% complete';
    final counts = stats == null
        ? (item.error?.message ?? 'Statistics unavailable')
        : '${stats.open} open / ${stats.total} total / ${stats.blocked} blocked';
    final root = item.roots.isEmpty ? 'No bound root' : item.roots.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Text(progressText, style: theme.textTheme.bodySmall),
              ),
              SizedBox(
                width: 24,
                height: 20,
                child: PopupMenuButton<_ProjectMenuAction>(
                  tooltip: 'Actions for ${item.name}',
                  padding: EdgeInsets.zero,
                  onSelected: onAction,
                  itemBuilder: (context) =>
                      <PopupMenuEntry<_ProjectMenuAction>>[
                        _menuItem(
                          _ProjectMenuAction.explorer,
                          'Open in Explorer',
                          item.roots.isNotEmpty,
                        ),
                        _menuItem(
                          _ProjectMenuAction.alacritty,
                          'Open in Alacritty',
                          item.roots.isNotEmpty,
                        ),
                        _menuItem(
                          _ProjectMenuAction.terminal,
                          'Open in Terminal',
                          item.roots.isNotEmpty,
                        ),
                        _menuItem(
                          _ProjectMenuAction.copyPath,
                          'Copy path',
                          item.roots.isNotEmpty,
                        ),
                        _menuItem(
                          _ProjectMenuAction.archive,
                          item.archivedAtMs == null ? 'Archive' : 'Unarchive',
                          canArchive,
                        ),
                        _menuItem(
                          _ProjectMenuAction.copyId,
                          'Copy project ID',
                          true,
                        ),
                        _menuItem(
                          _ProjectMenuAction.enrich,
                          'Enrich clipboard',
                          item.isAvailable,
                        ),
                      ],
                  child: Semantics(
                    button: true,
                    label: 'Actions for ${item.name}',
                    child: const Icon(Icons.menu, size: 18),
                  ),
                ),
              ),
            ],
          ),
          ExcludeSemantics(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    counts,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    root,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          if (!compact)
            ExcludeSemantics(
              child: Text(
                'Started (first task): '
                '${stats?.startedMs == null ? 'No recorded tasks' : viewerDate(context, stats!.startedMs!)}'
                '   Last task write: '
                '${stats?.lastWriteMs == null ? 'No recorded tasks' : viewerTimestamp(context, stats!.lastWriteMs!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  PopupMenuItem<_ProjectMenuAction> _menuItem(
    _ProjectMenuAction action,
    String label,
    bool enabled,
  ) => PopupMenuItem<_ProjectMenuAction>(
    value: action,
    enabled: enabled,
    height: 36,
    child: Text(label),
  );
}

/// A row the viewer has not fetched yet; it never invents project identity.
class _ProjectRowPlaceholder extends StatelessWidget {
  const _ProjectRowPlaceholder();

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
