/// Slice 1 prototype panes.
///
/// These panes exist to prove the accessibility foundation on the real Windows
/// build: a 10,000-row virtual list per collection, labelled text editing, an
/// enum selector, a modal with focus restoration and the persistent status
/// region. They are replaced by the real data client in later slices and never
/// touch a task store.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'commands.dart';
import 'viewer_format.dart';

/// Rows rendered in each synthetic collection.
const int prototypeRowCount = 10000;

const List<String> _statuses = <String>[
  'draft',
  'todo',
  'in-progress',
  'blocked',
  'done',
  'cancelled',
];

const List<String> _priorities = <String>['P0', 'P1', 'P2', 'P3'];

String _padded(int value, int width) => value.toString().padLeft(width, '0');

/// Row extent for a synthetic row of [textLines] stacked text lines.
///
/// viewer/design.md section 2: the extent follows the active text scale and
/// the row mode, so scaled text is never clipped. Normal density keeps its
/// 56-pixel minimum; taller text grows the row instead of truncating it.
double prototypeRowExtent(BuildContext context, {int textLines = 2}) =>
    viewerRowExtent(context, textLines: textLines);

/// Synthetic project row.
class PrototypeProject {
  const PrototypeProject({required this.name, required this.root});

  final String name;
  final String root;

  String get semanticsLabel => '$name. Root $root';
}

/// Synthetic task row.
class PrototypeTask {
  const PrototypeTask({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
  });

  final String id;
  final String title;
  final String status;
  final String priority;

  String get semanticsLabel =>
      '$id, ${priority.toUpperCase()}, $status, $title';
}

List<PrototypeProject> buildPrototypeProjects() =>
    List<PrototypeProject>.generate(prototypeRowCount, (index) {
      final number = index + 1;
      final padded = _padded(number, 5);
      return PrototypeProject(
        name: 'Project $padded',
        root: r'F:\projects\demo\project-' + padded,
      );
    }, growable: false);

List<PrototypeTask> buildPrototypeTasks() =>
    List<PrototypeTask>.generate(prototypeRowCount, (index) {
      final number = index + 1;
      final padded = _padded(number, 5);
      final title = number == prototypeRowCount
          ? 'Zażółć gęślą jaźń - Unicode row'
          : 'Task $padded';
      return PrototypeTask(
        id: 'T-$padded',
        title: title,
        status: _statuses[index % _statuses.length],
        priority: _priorities[index % _priorities.length],
      );
    }, growable: false);

List<int> _matchingIndexes(List<String> haystacks, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return List<int>.generate(
      haystacks.length,
      (index) => index,
      growable: false,
    );
  }
  final matches = <int>[];
  for (var index = 0; index < haystacks.length; index++) {
    if (haystacks[index].toLowerCase().contains(needle)) {
      matches.add(index);
    }
  }
  return matches;
}

/// The three prototype panes wired to the shell's region handles.
ViewerWorkspace buildPrototypeWorkspace(
  BuildContext context,
  ViewerShellApi api,
) {
  return ViewerWorkspace(
    projectsPane: PrototypeProjectsPane(api: api),
    tasksPane: PrototypeTasksPane(api: api),
    detailsPane: PrototypeDetailsPane(api: api),
  );
}

/// Projects region: filter, count, virtual list and selection summary.
class PrototypeProjectsPane extends StatefulWidget {
  const PrototypeProjectsPane({super.key, required this.api});

  final ViewerShellApi api;

  @override
  State<PrototypeProjectsPane> createState() => _PrototypeProjectsPaneState();
}

class _PrototypeProjectsPaneState extends State<PrototypeProjectsPane> {
  late final List<PrototypeProject> _rows = buildPrototypeProjects();
  final TextEditingController _filter = TextEditingController();
  late final List<String> _haystacks = _rows
      .map((row) => '${row.name} ${row.root}')
      .toList(growable: false);
  late List<int> _visible = _matchingIndexes(_haystacks, '');
  int? _selected;

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.projects, _onScopeCommand);
  }

  KeyEventResult _onScopeCommand(String id) {
    switch (id) {
      case 'projects.clearSearch':
        _filter.clear();
        _onFilterChanged('');
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.projects, null);
    _filter.dispose();
    super.dispose();
  }

  void _onFilterChanged(String value) {
    setState(() {
      _visible = _matchingIndexes(_haystacks, value);
      if (_selected != null && _selected! >= _visible.length) {
        // The filter hid the selected row, so the summary must forget it
        // instead of reading a row the list no longer shows.
        _selected = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final handles = widget.api.handlesFor(ViewerRegion.projects);
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _filter,
            focusNode: handles.filterFocus,
            onChanged: _onFilterChanged,
            decoration: const InputDecoration(
              labelText: 'Search projects (Ctrl+F)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            _visible.length == 1 ? '1 project' : '${_visible.length} projects',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: AccessibleVirtualList(
            controller: handles.list,
            itemCount: _visible.length,
            itemExtent: prototypeRowExtent(context),
            listLabel: 'Projects',
            emptyLabel: 'No projects match these filters',
            itemKeyBuilder: (index) =>
                ValueKey<String>(_rows[_visible[index]].name),
            rowSemanticsBuilder: (index) => AccessibleRowSemantics(
              label: _rows[_visible[index]].semanticsLabel,
              value: 'row ${index + 1} of ${_visible.length}',
            ),
            onSelectedIndexChanged: (index) =>
                setState(() => _selected = index),
            onActivate: (index) => setState(() => _selected = index),
            rowBuilder: (context, index, isSelected) {
              final row = _rows[_visible[index]];
              return _PrototypeRowTile(
                title: row.name,
                subtitle: row.root,
                selected: isSelected,
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            selected == null
                ? 'Selected project: none'
                : 'Selected project: ${_rows[_visible[selected]].name}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Tasks region: filter, scope selector, count and virtual list.
class PrototypeTasksPane extends StatefulWidget {
  const PrototypeTasksPane({super.key, required this.api});

  final ViewerShellApi api;

  @override
  State<PrototypeTasksPane> createState() => _PrototypeTasksPaneState();
}

class _PrototypeTasksPaneState extends State<PrototypeTasksPane> {
  late final List<PrototypeTask> _rows = buildPrototypeTasks();
  late final List<String> _haystacks = _rows
      .map((row) => '${row.id} ${row.title}')
      .toList(growable: false);
  final TextEditingController _filter = TextEditingController();
  final FocusNode _scopeFocus = FocusNode(debugLabel: 'tasks scope');
  late List<int> _visible = _matchingIndexes(_haystacks, '');
  String _scope = 'open';
  int? _selected;

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.tasks, _onScopeCommand);
  }

  KeyEventResult _onScopeCommand(String id) {
    switch (id) {
      case 'tasks.clearSearch':
        _filter.clear();
        _onFilterChanged('');
        return KeyEventResult.handled;
      case 'tasks.scope':
        _scopeFocus.requestFocus();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.tasks, null);
    _filter.dispose();
    _scopeFocus.dispose();
    super.dispose();
  }

  void _onFilterChanged(String value) {
    setState(() {
      _visible = _matchingIndexes(_haystacks, value);
      if (_selected != null && _selected! >= _visible.length) {
        // Same stale-selection rule as the Projects pane: a row the filter
        // hides must not stay in the summary.
        _selected = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final handles = widget.api.handlesFor(ViewerRegion.tasks);
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _filter,
            focusNode: handles.filterFocus,
            onChanged: _onFilterChanged,
            decoration: const InputDecoration(
              labelText: 'Search tasks (Ctrl+F)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'open', label: Text('Open tasks')),
                ButtonSegment<String>(value: 'all', label: Text('All tasks')),
              ],
              selected: <String>{_scope},
              onSelectionChanged: (value) {
                if (value.isEmpty) {
                  return;
                }
                setState(() => _scope = value.first);
                widget.api.announce(
                  value.first == 'open'
                      ? 'Showing open tasks.'
                      : 'Showing all tasks, including done and cancelled.',
                  dynamic: true,
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            '${_visible.length} matching tasks in the synthetic fixture',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: AccessibleVirtualList(
            controller: handles.list,
            itemCount: _visible.length,
            itemExtent: prototypeRowExtent(context),
            listLabel: 'Tasks',
            emptyLabel: 'No tasks match these filters',
            itemKeyBuilder: (index) =>
                ValueKey<String>(_rows[_visible[index]].id),
            rowSemanticsBuilder: (index) => AccessibleRowSemantics(
              label: _rows[_visible[index]].semanticsLabel,
              value: 'row ${index + 1} of ${_visible.length}',
            ),
            onSelectedIndexChanged: (index) =>
                setState(() => _selected = index),
            onActivate: (index) => setState(() => _selected = index),
            rowBuilder: (context, index, isSelected) {
              final row = _rows[_visible[index]];
              return _PrototypeRowTile(
                title: '${row.id}  ${row.title}',
                subtitle: '${row.priority}  ${row.status}',
                selected: isSelected,
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            selected == null
                ? 'Selected task: none'
                : 'Selected task: ${_rows[_visible[selected]].id}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Task details region: enum selector, labelled editing, Find in body, modal.
class PrototypeDetailsPane extends StatefulWidget {
  const PrototypeDetailsPane({super.key, required this.api});

  final ViewerShellApi api;

  @override
  State<PrototypeDetailsPane> createState() => _PrototypeDetailsPaneState();
}

class _PrototypeDetailsPaneState extends State<PrototypeDetailsPane> {
  final TextEditingController _body = TextEditingController(
    text: 'Synthetic body text.\nSecond line for caret navigation.\n',
  );
  final TextEditingController _find = TextEditingController();
  final FocusNode _statusNode = FocusNode(debugLabel: 'details status');
  String _status = 'todo';

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.details, _onScopeCommand);
  }

  @override
  void dispose() {
    widget.api.registerScopeCommands(CommandScope.details, null);
    _body.dispose();
    _find.dispose();
    _statusNode.dispose();
    super.dispose();
  }

  /// The prototype answer to Ctrl+D: the real slice decides save/discard
  /// against the CLI, this one shows the same modal and speaks the outcome.
  KeyEventResult _onScopeCommand(String id) {
    if (id == 'global.markDone') {
      unawaited(_openMarkDoneDialog());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openMarkDoneDialog() async {
    BuildContext? dialogContext;
    final result = await widget.api.showModal<String>(
      CommandScope.markDoneDirty,
      (context) {
        dialogContext = context;
        return const _MarkDoneDirtyDialog();
      },
      onCommand: (id) {
        switch (id) {
          case 'markDone.saveAndMarkDone':
            Navigator.of(dialogContext!).pop('save');
          case 'markDone.discardAndMarkDone':
            Navigator.of(dialogContext!).pop('discard');
          case 'markDone.cancel':
            Navigator.of(dialogContext!).pop();
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() => _status = 'done');
    widget.api.announce(
      result == 'save'
          ? 'Prototype dialog: draft fields and status done would be saved in '
                'one version-checked update.'
          : 'Prototype dialog: only status done would be sent; the draft is '
                'kept until the outcome is confirmed.',
      dynamic: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final handles = widget.api.handlesFor(ViewerRegion.details);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'T-00010  P1  $_status',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Synthetic task for the accessibility foundation',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  focusNode: _statusNode,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final status in _statuses)
                      DropdownMenuItem<String>(
                        value: status,
                        child: Text(status),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _status = value ?? _status),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _body,
                  focusNode: handles.bodyFocus,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Description (F3)',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _find,
                  focusNode: handles.findFocus,
                  decoration: const InputDecoration(
                    labelText: 'Find in body (Ctrl+H)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _openMarkDoneDialog,
                    child: const Text('Mark done with unsaved changes...'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Prototype build: synthetic rows only. The CLI data client, the '
            'editor and real Bella clips arrive in the later slices.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// The "Mark task done with unsaved changes?" modal.
class _MarkDoneDirtyDialog extends StatelessWidget {
  const _MarkDoneDirtyDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mark task done with unsaved changes?'),
      content: const Text(
        'Save changes and mark done sends the draft and status done in one '
        'version-checked update. Discard changes and mark done keeps the draft '
        'until the outcome is confirmed.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          autofocus: true,
          child: const Text('Cancel (Alt+C)'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('discard'),
          child: const Text('Discard changes and mark done (Alt+D)'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop('save'),
          child: const Text('Save changes and mark done (Alt+S)'),
        ),
      ],
    );
  }
}

class _PrototypeRowTile extends StatelessWidget {
  const _PrototypeRowTile({
    required this.title,
    required this.subtitle,
    required this.selected,
  });

  final String title;
  final String subtitle;
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
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
