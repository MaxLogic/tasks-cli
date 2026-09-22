/// Searchable Hotkey help (viewer/design.md section 9).
///
/// The list is generated from the same registry the shortcuts are installed
/// from, so a documented key cannot drift from the key that runs.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'accessible_virtual_list.dart';
import 'commands.dart';
import 'dialog_scope.dart';

/// Group order and titles shown by Help.
const List<(HelpGroup, String)> helpGroupTitles = <(HelpGroup, String)>[
  (HelpGroup.global, 'Global'),
  (HelpGroup.projects, 'Projects'),
  (HelpGroup.tasks, 'Tasks'),
  (HelpGroup.details, 'Task details'),
  (HelpGroup.editor, 'Editor'),
  (HelpGroup.dialogs, 'Dialogs and setup'),
];

String helpGroupTitle(HelpGroup group) =>
    helpGroupTitles.firstWhere((entry) => entry.$1 == group).$2;

/// One row of the generated help list.
class HelpEntry {
  const HelpEntry({
    required this.group,
    required this.spec,
    required this.activeHere,
  });

  final HelpGroup group;
  final CommandSpec spec;

  /// True when the binding belongs to the context that opened Help.
  final bool activeHere;

  String get semanticsLabel {
    final parts = <String>[
      '${spec.shortcutLabel}. ${spec.label}.',
      spec.description,
      if (activeHere) 'Active in this context.',
      helpGroupTitle(group),
    ];
    return parts.join(' ');
  }
}

/// Entries for one help context, in group then registry order.
List<HelpEntry> helpEntriesFor(CommandScope activeScope) {
  final entries = <HelpEntry>[];
  final helpActiveGroup = _helpGroupForScope(activeScope);
  for (final (group, _) in helpGroupTitles) {
    for (final spec in helpEntriesForGroup(group)) {
      entries.add(
        HelpEntry(
          group: group,
          spec: spec,
          activeHere:
              spec.scope == activeScope ||
              (helpActiveGroup != null &&
                  _helpGroupForScope(spec.scope) == helpActiveGroup),
        ),
      );
    }
  }
  return entries;
}

HelpGroup? _helpGroupForScope(CommandScope scope) {
  switch (scope) {
    case CommandScope.global:
      return HelpGroup.global;
    case CommandScope.projects:
      return HelpGroup.projects;
    case CommandScope.tasks:
      return HelpGroup.tasks;
    case CommandScope.details:
      return HelpGroup.details;
    case CommandScope.editor:
      return HelpGroup.editor;
    case CommandScope.settings:
    case CommandScope.unsavedChanges:
    case CommandScope.markDoneDirty:
    case CommandScope.conflict:
    case CommandScope.conflictReview:
    case CommandScope.restoreDraft:
    case CommandScope.enrichmentPreview:
    case CommandScope.keyboardHelp:
    case CommandScope.slowSaveClose:
    case CommandScope.dialogs:
    case CommandScope.statusBar:
      return HelpGroup.dialogs;
  }
}

/// Filters [entries] by a case-insensitive search over key, command and group.
List<HelpEntry> searchHelpEntries(List<HelpEntry> entries, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return entries;
  }
  return entries
      .where(
        (entry) =>
            entry.spec.shortcutLabel.toLowerCase().contains(needle) ||
            entry.spec.label.toLowerCase().contains(needle) ||
            entry.spec.description.toLowerCase().contains(needle) ||
            helpGroupTitle(entry.group).toLowerCase().contains(needle),
      )
      .toList(growable: false);
}

/// The modal keyboard help.
class KeyboardHelpDialog extends StatefulWidget {
  const KeyboardHelpDialog({super.key, required this.activeScope});

  /// Context that opened Help, used for the "active in this context" marker.
  final CommandScope activeScope;

  @override
  State<KeyboardHelpDialog> createState() => _KeyboardHelpDialogState();
}

class _KeyboardHelpDialogState extends State<KeyboardHelpDialog> {
  final FocusNode _searchNode = FocusNode(
    debugLabel: 'help search',
    skipTraversal: true,
  );
  final VirtualListController _list = VirtualListController();
  final TextEditingController _query = TextEditingController();
  late final List<HelpEntry> _all = helpEntriesFor(widget.activeScope);
  late List<HelpEntry> _visible = _all;
  FocusNode? _restoreFocus;

  @override
  void initState() {
    super.initState();
    _restoreFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchNode.canRequestFocus) {
        _searchNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _searchNode.dispose();
    _list.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _visible = searchHelpEntries(_all, value);
    });
  }

  void _close() {
    final restore = _restoreFocus;
    Navigator.of(context).maybePop();
    if (restore != null && restore.canRequestFocus) {
      restore.requestFocus();
    }
  }

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'keyboardHelp.search':
        _searchNode.requestFocus();
        return KeyEventResult.handled;
      case 'keyboardHelp.list':
        _list.focusRegion();
        return KeyEventResult.handled;
      case 'keyboardHelp.close':
      case 'dialogs.dismiss':
        _close();
        return KeyEventResult.handled;
      case 'dialogs.hotkeyHelp':
        return KeyEventResult.handled;
      default:
        return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final count = _visible.length;
    return DialogCommandHost(
      scope: CommandScope.keyboardHelp,
      onCommand: _onCommand,
      // The dialog surface itself: it supplies the Material ancestor the
      // search field needs and clamps the list to the current window.
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 480,
              maxWidth: math.min(960, size.width - 48),
              maxHeight: size.height - 96,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Keyboard help',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Reserved app shortcuts are handled before a focused text '
                    'field sees the key. Every other key stays with the field, '
                    'including Insert and Caps Lock combinations used by NVDA.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _query,
                    focusNode: _searchNode,
                    onChanged: _onQueryChanged,
                    decoration: const InputDecoration(
                      labelText: 'Search shortcuts (Alt+F)',
                      helperText:
                          'Matches key, command, description and group.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    count == 1 ? '1 shortcut' : '$count shortcuts',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: AccessibleVirtualList(
                      controller: _list,
                      itemCount: count,
                      itemExtent: 84,
                      listLabel: 'Keyboard shortcuts',
                      emptyLabel: 'No shortcuts match this search',
                      rowSemanticsBuilder: (index) => AccessibleRowSemantics(
                        label: _visible[index].semanticsLabel,
                      ),
                      itemKeyBuilder: (index) =>
                          ValueKey<String>(_visible[index].spec.id),
                      rowBuilder: (context, index, selected) =>
                          _HelpRow(entry: _visible[index], selected: selected),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _close,
                      child: const Text('Close (Alt+C)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpRow extends StatelessWidget {
  const _HelpRow({required this.entry, required this.selected});

  final HelpEntry entry;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emphasis = entry.activeHere
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Text(entry.spec.shortcutLabel, style: emphasis),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.activeHere
                      ? '${entry.spec.label} - active in this context'
                      : entry.spec.label,
                  style: emphasis,
                ),
                Text(
                  entry.spec.description,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
