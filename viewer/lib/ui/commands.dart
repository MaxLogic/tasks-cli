/// The application command registry.
///
/// Every shortcut, scoped access key and Help entry comes from this list so the
/// Hotkey help dialog cannot drift from the controls that implement it
/// (viewer/design.md section 9).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../data/models.dart';

/// Where a binding is active. Only the focused scope resolves its access keys.
enum CommandScope {
  global,
  projects,
  tasks,
  details,
  editor,

  /// Commands shared by every modal dialog (Escape, F10).
  dialogs,
  settings,
  unsavedChanges,
  markDoneDirty,
  conflict,
  conflictReview,
  restoreDraft,
  enrichmentPreview,
  keyboardHelp,
  statusBar,
  slowSaveClose,
}

/// Whether [scope] belongs to a modal dialog.
bool isDialogScope(CommandScope scope) {
  switch (scope) {
    case CommandScope.settings:
    case CommandScope.unsavedChanges:
    case CommandScope.markDoneDirty:
    case CommandScope.conflict:
    case CommandScope.conflictReview:
    case CommandScope.restoreDraft:
    case CommandScope.enrichmentPreview:
    case CommandScope.keyboardHelp:
    case CommandScope.slowSaveClose:
      return true;
    case CommandScope.global:
    case CommandScope.projects:
    case CommandScope.tasks:
    case CommandScope.details:
    case CommandScope.editor:
    case CommandScope.dialogs:
    case CommandScope.statusBar:
      return false;
  }
}

/// Grouping used by the Hotkey help dialog.
enum HelpGroup { global, projects, tasks, details, editor, dialogs }

/// One application command.
class CommandSpec {
  const CommandSpec({
    required this.id,
    required this.scope,
    required this.group,
    required this.label,
    required this.description,
    this.activators = const <ShortcutActivator>[],
    this.shortcutText,
    this.alsoIn = const <HelpGroup>[],
  });

  /// Stable identifier used by [CommandIntent] and tests.
  final String id;

  /// Scope that owns and resolves the binding.
  final CommandScope scope;

  /// Primary Help group.
  final HelpGroup group;

  /// Additional Help groups that list the same binding.
  final List<HelpGroup> alsoIn;

  /// Control or action name.
  final String label;

  /// What the binding does, including its scope.
  final String description;

  final List<ShortcutActivator> activators;

  /// Explicit display text for help-only entries (traversal, arrows, Escape).
  final String? shortcutText;

  bool get isHelpOnly => activators.isEmpty;

  String get shortcutLabel {
    if (shortcutText != null) {
      return shortcutText!;
    }
    return activators.map(describeActivator).join(' or ');
  }

  /// True when Help must list this entry under [group].
  bool appearsIn(HelpGroup helpGroup) =>
      group == helpGroup || alsoIn.contains(helpGroup);
}

/// Intent raised by a registry binding.
class CommandIntent extends Intent {
  const CommandIntent(this.id);

  final String id;
}

/// Runs commands owned by one scope. Unknown ids are reported as ignored so the
/// enclosing scope (and finally the platform) still sees the key event.
class CommandAction extends Action<CommandIntent> {
  CommandAction({required this.onCommand});

  final KeyEventResult Function(String id) onCommand;

  @override
  Object? invoke(CommandIntent intent) => onCommand(intent.id);

  @override
  KeyEventResult toKeyEventResult(CommandIntent intent, Object? invokeResult) =>
      invokeResult is KeyEventResult ? invokeResult : KeyEventResult.handled;
}

/// Shortcut map for one scope, including the shared dialog bindings.
Map<ShortcutActivator, Intent> shortcutMapForScope(CommandScope scope) {
  final map = <ShortcutActivator, Intent>{};
  void addScope(CommandScope candidate) {
    for (final spec in commandRegistry) {
      if (spec.scope != candidate) {
        continue;
      }
      for (final activator in spec.activators) {
        map.putIfAbsent(activator, () => CommandIntent(spec.id));
      }
    }
  }

  if (isDialogScope(scope)) {
    addScope(CommandScope.dialogs);
  }
  addScope(scope);
  return Map<ShortcutActivator, Intent>.unmodifiable(map);
}

/// Actions map for one scope.
Map<Type, Action<Intent>> commandActionsForScope(
  CommandScope scope,
  KeyEventResult Function(String id) onCommand,
) {
  final action = CommandAction(onCommand: onCommand);
  return <Type, Action<Intent>>{CommandIntent: action};
}

/// Registry entries listed under one Help group, in registry order.
List<CommandSpec> helpEntriesForGroup(HelpGroup group) =>
    commandRegistry.where((spec) => spec.appearsIn(group)).toList();

/// Registry lookup by [CommandSpec.id].
///
/// Returns null for an unknown id so callers can report it as ignored instead
/// of running an unregistered command.
CommandSpec? commandSpecById(String id) {
  for (final spec in commandRegistry) {
    if (spec.id == id) {
      return spec;
    }
  }
  return null;
}

/// Human-readable label for a binding, for example `Ctrl+D` or `Alt+Left`.
String describeActivator(ShortcutActivator activator) {
  final triggers = activator.triggers;
  if (activator is CharacterActivator) {
    final parts = <String>[
      if (activator.control) 'Ctrl',
      if (activator.alt) 'Alt',
      if (activator.meta) 'Win',
      activator.character,
    ];
    return parts.join('+');
  }
  if (activator is SingleActivator) {
    final parts = <String>[
      if (activator.control) 'Ctrl',
      if (activator.alt) 'Alt',
      if (activator.shift) 'Shift',
      if (activator.meta) 'Win',
      _keyLabel(activator.trigger),
    ];
    return parts.join('+');
  }
  if (triggers != null && triggers.isNotEmpty) {
    return triggers.map(_keyLabel).join('+');
  }
  return activator.debugDescribeKeys();
}

final Map<LogicalKeyboardKey, String> _keyLabels = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.pageUp: 'Page Up',
  LogicalKeyboardKey.pageDown: 'Page Down',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.tab: 'Tab',
};

String _keyLabel(LogicalKeyboardKey key) => _keyLabels[key] ?? key.keyLabel;

/// Ctrl+V on a focused list; the pane handler ignores it anywhere else, so a
/// text field keeps its native paste.
const SingleActivator _pasteKey = SingleActivator(
  LogicalKeyboardKey.keyV,
  control: true,
  includeRepeats: false,
);

SingleActivator _alt(LogicalKeyboardKey key) =>
    SingleActivator(key, alt: true, includeRepeats: false);

/// Every application command.
final List<CommandSpec> commandRegistry = List<CommandSpec>.unmodifiable(
  <CommandSpec>[
    // ---------------------------------------------------------------- global
    CommandSpec(
      id: 'global.nextRegion',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Next region',
      description:
          'Move focus to the next region: Projects, Tasks, Task details, '
          'Status. Reveals the pane in a reduced layout.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f6, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[
        HelpGroup.projects,
        HelpGroup.tasks,
        HelpGroup.details,
      ],
    ),
    CommandSpec(
      id: 'global.previousRegion',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Previous region',
      description: 'Move focus to the previous region, in reverse order.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.f6,
          shift: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[
        HelpGroup.projects,
        HelpGroup.tasks,
        HelpGroup.details,
      ],
    ),
    CommandSpec(
      id: 'global.focusProjects',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Focus Projects',
      description:
          'Select the Projects region and focus its selected list row. An '
          'empty list focuses the list container. F1 is not Help.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f1, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.projects],
    ),
    CommandSpec(
      id: 'global.focusTasks',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Focus Tasks',
      description:
          'Select the Tasks region and focus its selected list row. An empty '
          'list focuses the list container. F2 is not Edit.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f2, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.tasks],
    ),
    CommandSpec(
      id: 'global.focusDescription',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Focus description',
      description:
          'Reveal Task details and focus the description/body control '
          'directly, including the draft body while editing. F3 never stops '
          'at a heading or a tab. In the read-only body, Ctrl+C copies selected '
          'text, or the full body when nothing is selected.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f3, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.details, HelpGroup.editor],
    ),
    CommandSpec(
      id: 'global.focusFilter',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Focus text filter',
      description:
          'Focus the text filter of the focused Projects or Tasks region. '
          'Outside both regions it uses the last focused list, default '
          'Projects.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[
        HelpGroup.projects,
        HelpGroup.tasks,
        HelpGroup.details,
        HelpGroup.editor,
      ],
    ),
    CommandSpec(
      id: 'global.findInBody',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Find in body',
      description: 'Focus Find in body in Task details.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyH,
          control: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.details],
    ),
    CommandSpec(
      id: 'global.refresh',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Refresh',
      description: 'Refresh the workspace, preserving draft and focus.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f5, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[
        HelpGroup.projects,
        HelpGroup.tasks,
        HelpGroup.details,
      ],
    ),
    CommandSpec(
      id: 'global.editTask',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Edit task',
      description:
          'Enter edit mode for the selected task when Tasks or Task details '
          'has focus.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f4, includeRepeats: false),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.details],
    ),
    CommandSpec(
      id: 'global.markDone',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Mark done',
      description:
          'Mark the selected task done with one version-checked update. With a '
          'dirty editor the Save/Discard dialog opens first.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.details],
    ),
    CommandSpec(
      id: 'global.enrichClipboard',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Enrich clipboard',
      description:
          'Invoke Enrich clipboard only when the Projects list itself has '
          'focus. The selected project UUID is captured when the action '
          'starts.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.projects],
    ),
    CommandSpec(
      id: 'global.save',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Save',
      description: 'Save the active editor; otherwise no action.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.editor],
    ),
    CommandSpec(
      id: 'global.settings',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Open Settings',
      description: 'Open the Settings dialog.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.comma,
          control: true,
          includeRepeats: false,
        ),
      ],
    ),
    CommandSpec(
      id: 'global.back',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Back',
      description:
          'Go back from a dependency detail or a reduced-layout child pane. '
          'Text-caret commands are never intercepted.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          alt: true,
          includeRepeats: false,
        ),
      ],
      alsoIn: const <HelpGroup>[HelpGroup.details],
    ),
    CommandSpec(
      id: 'global.hotkeyHelp',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Hotkey help',
      description:
          'Open the searchable keyboard help. Available in every layout and '
          'from another modal.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f10, includeRepeats: false),
      ],
    ),
    CommandSpec(
      id: 'global.nextControl',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Next control',
      description:
          'Move to the next control. A collection is a single traversal stop, '
          'so Tab never visits thousands of rows.',
      shortcutText: 'Tab',
    ),
    CommandSpec(
      id: 'global.previousControl',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Previous control',
      description: 'Move to the previous control.',
      shortcutText: 'Shift+Tab',
    ),
    CommandSpec(
      id: 'global.collectionNavigation',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Collection navigation',
      description:
          'Move within the focused collection only: one row, one viewport, '
          'first or last filtered row. Selection stays in place at a '
          'boundary.',
      shortcutText: 'Up, Down, Page Up, Page Down, Home, End',
      alsoIn: const <HelpGroup>[
        HelpGroup.projects,
        HelpGroup.tasks,
        HelpGroup.details,
      ],
    ),
    CommandSpec(
      id: 'global.activate',
      scope: CommandScope.global,
      group: HelpGroup.global,
      label: 'Activate',
      description:
          'Open the selected row or activate the focused control. Enter adds a '
          'newline in a multiline field; Space types a space in a text field.',
      shortcutText: 'Enter, Space',
    ),
    // -------------------------------------------------------------- projects
    for (final state in ProjectStateFilter.values)
      CommandSpec(
        id: 'projects.state.${state.wireValue}',
        scope: CommandScope.projects,
        group: HelpGroup.projects,
        label: state.label,
        description: state == ProjectStateFilter.unavailable
            ? 'Show projects whose task database is missing or cannot be read.'
            : 'Show ${state.label.toLowerCase()}.',
        activators: <ShortcutActivator>[
          _alt(
            <LogicalKeyboardKey>[
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
              LogicalKeyboardKey.digit5,
              LogicalKeyboardKey.digit6,
              LogicalKeyboardKey.digit7,
              LogicalKeyboardKey.digit8,
              LogicalKeyboardKey.digit9,
            ][state.index],
          ),
        ],
      ),

    CommandSpec(
      id: 'projects.clearSearch',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Clear search',
      description: 'Clear the Projects search field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyX)],
    ),
    CommandSpec(
      id: 'projects.stateFilter',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'State filter',
      description: 'Focus the project state filter.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyS)],
    ),
    CommandSpec(
      id: 'projects.sort',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Sort',
      description: 'Focus the project sort selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyO)],
    ),
    CommandSpec(
      id: 'projects.direction',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Direction',
      description: 'Reverse the sort direction.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyI)],
    ),
    CommandSpec(
      id: 'projects.clearFilters',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Clear filters',
      description:
          'Reset the project query and state filter, keeping the chosen sort.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    CommandSpec(
      id: 'projects.copyProjectId',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Copy project ID',
      description: 'Copy the selected project UUID to the clipboard.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyY)],
    ),
    CommandSpec(
      id: 'projects.enrichClipboard',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Enrich clipboard',
      description:
          'Enrich the clipboard in the selected project and write the result '
          'back.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyE)],
    ),
    CommandSpec(
      id: 'projects.previewEnrichment',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Preview enrichment',
      description:
          'Preview clipboard enrichment in the selected project without '
          'writing the clipboard.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyP)],
    ),
    CommandSpec(
      id: 'projects.summary',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Selected project summary',
      description:
          'Focus the selected project summary, including every bound root.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyU)],
    ),
    CommandSpec(
      id: 'projects.pasteFilter',
      scope: CommandScope.projects,
      group: HelpGroup.projects,
      label: 'Paste into search',
      description:
          'While the Projects list itself has focus, replace the Projects '
          'search with the clipboard text (trimmed) and apply it; focus stays '
          'in the list. In a text field Ctrl+V pastes as usual.',
      activators: <ShortcutActivator>[_pasteKey],
    ),
    // ----------------------------------------------------------------- tasks
    CommandSpec(
      id: 'tasks.pasteFilter',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Paste into search',
      description:
          'While the Tasks list itself has focus, replace the Tasks search '
          'with the clipboard text (trimmed), for example a copied task ID, '
          'and apply it; focus stays in the list. In a text field Ctrl+V '
          'pastes as usual.',
      activators: <ShortcutActivator>[_pasteKey],
    ),
    CommandSpec(
      id: 'tasks.clearSearch',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Clear search',
      description: 'Clear the Tasks search field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyX)],
    ),
    CommandSpec(
      id: 'tasks.filtersPopup',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Task filters',
      description: 'Expand the task filter controls.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyF)],
    ),
    CommandSpec(
      id: 'tasks.scope',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Scope',
      description: 'Focus the Open tasks / All tasks scope control.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyS)],
    ),
    CommandSpec(
      id: 'tasks.statusChecklist',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Status checklist',
      description:
          'Focus the status checklist. Down selects a status, Space toggles '
          'it. Selecting Done or Cancelled also selects All tasks.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyT)],
    ),
    CommandSpec(
      id: 'tasks.priorityChecklist',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Priority checklist',
      description:
          'Focus the priority checklist. Down selects a priority, Space '
          'toggles it.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyP)],
    ),
    CommandSpec(
      id: 'tasks.labelsField',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Labels field',
      description:
          'Focus the comma-separated label filter. Every listed label must be '
          'present.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyL)],
    ),
    CommandSpec(
      id: 'tasks.applyLabels',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Apply labels',
      description: 'Apply the typed label filter.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyA)],
    ),
    CommandSpec(
      id: 'tasks.needsHuman',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Needs human',
      description: 'Toggle the needs-human label filter.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyH)],
    ),
    CommandSpec(
      id: 'tasks.readiness',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Readiness',
      description:
          'Focus the readiness filter: Any, Runnable or Waiting for '
          'dependencies. Blocked status and waiting for dependencies are '
          'different filters.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'tasks.sort',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Sort',
      description: 'Focus the task sort selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyO)],
    ),
    CommandSpec(
      id: 'tasks.direction',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Direction',
      description: 'Reverse the sort direction.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyI)],
    ),
    CommandSpec(
      id: 'tasks.clearFilters',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Clear filters',
      description:
          'Return to Open scope with no statuses, priorities, labels or '
          'readiness filter and an empty query, keeping the chosen sort.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    CommandSpec(
      id: 'tasks.removeActiveFilterGroup',
      scope: CommandScope.tasks,
      group: HelpGroup.tasks,
      label: 'Remove active filter',
      description:
          'Focus the active filters. Arrows choose a filter and Enter or '
          'Delete removes it.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyM)],
    ),
    // --------------------------------------------------------------- details
    CommandSpec(
      id: 'details.tabDetails',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Details tab',
      description: 'Show the Details tab.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.digit1)],
    ),
    CommandSpec(
      id: 'details.tabDependencies',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Dependencies tab',
      description: 'Show the Dependencies tab.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.digit2)],
    ),
    CommandSpec(
      id: 'details.tabHistory',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'History tab',
      description: 'Show the History tab.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.digit3)],
    ),
    CommandSpec(
      id: 'details.tabRules',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Project rules tab',
      description: 'Show the Project rules tab.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.digit4)],
    ),
    CommandSpec(
      id: 'details.copyReference',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Copy reference',
      description:
          'Copy the task ID and full title as plain text, for example '
          '"DAK-042: Full title". Existing clipboard text is never enriched '
          'implicitly.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    CommandSpec(
      id: 'details.nextMatch',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Next match',
      description: 'Select the next Find in body match.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyN)],
    ),
    CommandSpec(
      id: 'details.previousMatch',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Previous match',
      description: 'Select the previous Find in body match.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyP)],
    ),
    CommandSpec(
      id: 'details.dependencyList',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Dependencies list',
      description: 'Focus the dependency list.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyL)],
    ),
    CommandSpec(
      id: 'details.openDependency',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Open dependency',
      description: 'Open the selected dependency in the same project.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyO)],
    ),
    CommandSpec(
      id: 'details.historyList',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'History list',
      description: 'Focus the history event list.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyV)],
    ),
    CommandSpec(
      id: 'details.eventSnapshot',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Event snapshot',
      description: 'Focus the selected history event snapshot text.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyE)],
    ),
    CommandSpec(
      id: 'details.rulesText',
      scope: CommandScope.details,
      group: HelpGroup.details,
      label: 'Rules text',
      description: 'Focus the read-only project rules text.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    // ---------------------------------------------------------------- editor
    CommandSpec(
      id: 'editor.title',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Title',
      description: 'Focus the task title field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyT)],
    ),
    CommandSpec(
      id: 'editor.status',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Status',
      description: 'Focus the status selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyS)],
    ),
    CommandSpec(
      id: 'editor.priority',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Priority',
      description: 'Focus the priority selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyP)],
    ),
    CommandSpec(
      id: 'editor.labels',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Labels',
      description: 'Focus the labels field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyL)],
    ),
    CommandSpec(
      id: 'editor.dependencies',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Dependencies',
      description: 'Focus the dependencies field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),
    CommandSpec(
      id: 'editor.body',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Body',
      description: 'Focus the draft body without leaving edit mode.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyB)],
    ),
    CommandSpec(
      id: 'editor.cancel',
      scope: CommandScope.editor,
      group: HelpGroup.editor,
      label: 'Cancel',
      description: 'Leave edit mode through the unsaved-changes guard.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    // --------------------------------------------------- shared modal bindings
    CommandSpec(
      id: 'dialogs.dismiss',
      scope: CommandScope.dialogs,
      group: HelpGroup.dialogs,
      label: 'Close dialog',
      description:
          'Close the active dialog through its safe Cancel/Close action. '
          'Escape never discards changes.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false),
      ],
    ),
    CommandSpec(
      id: 'dialogs.hotkeyHelp',
      scope: CommandScope.dialogs,
      group: HelpGroup.dialogs,
      label: 'Hotkey help',
      description:
          'Open keyboard help without activating the background window; '
          'closing it returns focus to the dialog.',
      activators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.f10, includeRepeats: false),
      ],
    ),

    // -------------------------------------------------------------- settings
    CommandSpec(
      id: 'settings.cliPath',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'CLI path',
      description: 'Focus the tasks executable path field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyE)],
    ),
    CommandSpec(
      id: 'settings.browseCli',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Use packaged CLI',
      description:
          'Fill the CLI path with the tasks executable beside the viewer.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyB)],
    ),
    CommandSpec(
      id: 'settings.dataRoot',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Data root',
      description: 'Focus the task store root field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),
    CommandSpec(
      id: 'settings.browseRoot',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Use standard task store',
      description: 'Fill the data root with the standard local task store.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyO)],
    ),
    CommandSpec(
      id: 'settings.testConnection',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Test connection',
      description: 'Run the CLI protocol probe.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyT)],
    ),
    CommandSpec(
      id: 'settings.theme',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Theme',
      description: 'Focus the theme selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyH)],
    ),
    CommandSpec(
      id: 'settings.textSize',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Text size',
      description: 'Focus the in-app text size selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyZ)],
    ),
    CommandSpec(
      id: 'settings.projectsWidth',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Projects width',
      description: 'Focus the Projects pane width field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyP)],
    ),
    CommandSpec(
      id: 'settings.tasksWidth',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Tasks width',
      description: 'Focus the Tasks pane width field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyK)],
    ),
    CommandSpec(
      id: 'settings.detailsWidth',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Details width',
      description: 'Focus the Task details pane width field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyI)],
    ),
    CommandSpec(
      id: 'settings.resetLayout',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Reset layout',
      description: 'Restore the default pane proportions.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'settings.startWithWindows',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Start with Windows',
      description:
          'Toggle the application-owned Startup shortcut. Applies when '
          'Settings is saved.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyW)],
    ),
    CommandSpec(
      id: 'settings.announcementMode',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Announcement mode',
      description: 'Focus the announcement mode selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyA)],
    ),
    CommandSpec(
      id: 'settings.bellaVolume',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Bella volume',
      description: 'Focus the Bella volume slider.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyV)],
    ),
    CommandSpec(
      id: 'settings.testVoice',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Test voice',
      description: 'Play the fixed Bella preview phrase.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyY)],
    ),
    CommandSpec(
      id: 'settings.retryStartup',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Retry startup registration',
      description:
          'Retry creating or removing the application-owned Startup shortcut.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyG)],
    ),
    CommandSpec(
      id: 'settings.save',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Save settings',
      description: 'Apply and store the settings.',
      activators: const <ShortcutActivator>[
        SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          includeRepeats: false,
        ),
      ],
    ),
    CommandSpec(
      id: 'settings.cancel',
      scope: CommandScope.settings,
      group: HelpGroup.dialogs,
      label: 'Cancel',
      description: 'Close Settings without applying changes.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    // ----------------------------------------------------- unsaved changes
    CommandSpec(
      id: 'unsaved.save',
      scope: CommandScope.unsavedChanges,
      group: HelpGroup.dialogs,
      label: 'Save',
      description: 'Save the draft, then continue the leaving action.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyS)],
    ),
    CommandSpec(
      id: 'unsaved.discard',
      scope: CommandScope.unsavedChanges,
      group: HelpGroup.dialogs,
      label: 'Discard',
      description: 'Discard the draft and continue the leaving action.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),
    CommandSpec(
      id: 'unsaved.cancel',
      scope: CommandScope.unsavedChanges,
      group: HelpGroup.dialogs,
      label: 'Cancel',
      description: 'Return to the editor and keep the draft.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),

    // ------------------------------------------------ mark done with draft
    CommandSpec(
      id: 'markDone.saveAndMarkDone',
      scope: CommandScope.markDoneDirty,
      group: HelpGroup.dialogs,
      label: 'Save changes and mark done',
      description:
          'Save the draft fields together with status done in one '
          'version-checked update.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyS)],
    ),
    CommandSpec(
      id: 'markDone.discardAndMarkDone',
      scope: CommandScope.markDoneDirty,
      group: HelpGroup.dialogs,
      label: 'Discard changes and mark done',
      description:
          'Send only status done and keep the draft until completion is '
          'confirmed.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),
    CommandSpec(
      id: 'markDone.cancel',
      scope: CommandScope.markDoneDirty,
      group: HelpGroup.dialogs,
      label: 'Cancel',
      description: 'Return to the editor without changing the task.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),

    // ------------------------------------------------------------- conflict
    CommandSpec(
      id: 'conflict.returnToEditor',
      scope: CommandScope.conflict,
      group: HelpGroup.dialogs,
      label: 'Return to editor',
      description: 'Keep the draft and go back to the editor.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyE)],
    ),
    CommandSpec(
      id: 'conflict.reloadAndDiscard',
      scope: CommandScope.conflict,
      group: HelpGroup.dialogs,
      label: 'Reload current and discard draft',
      description: 'Load the current record and discard the local draft.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'conflict.review',
      scope: CommandScope.conflict,
      group: HelpGroup.dialogs,
      label: 'Review against current',
      description:
          'Choose Mine or Current for each conflicting field before saving '
          'again.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyV)],
    ),

    // ------------------------------------------------------ conflict review
    CommandSpec(
      id: 'conflictReview.fieldSelector',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Field selector',
      description: 'Focus the conflicting field selector.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyF)],
    ),
    CommandSpec(
      id: 'conflictReview.baseValue',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Base value',
      description: 'Focus the base value of the selected field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyB)],
    ),
    CommandSpec(
      id: 'conflictReview.mineValue',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Mine value',
      description: 'Focus your draft value of the selected field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyM)],
    ),
    CommandSpec(
      id: 'conflictReview.currentValue',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Current value',
      description: 'Focus the current stored value of the selected field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyU)],
    ),
    CommandSpec(
      id: 'conflictReview.chooseMine',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Choose Mine',
      description: 'Use your value for the selected conflicting field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyI)],
    ),
    CommandSpec(
      id: 'conflictReview.chooseCurrent',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Choose Current',
      description: 'Use the stored value for the selected conflicting field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'conflictReview.apply',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Apply choices',
      description:
          'Return to the editor with the chosen values. Applying does not '
          'save.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyA)],
    ),
    CommandSpec(
      id: 'conflictReview.cancel',
      scope: CommandScope.conflictReview,
      group: HelpGroup.dialogs,
      label: 'Cancel',
      description: 'Close the review without changing the draft.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),
    // --------------------------------------------------------- restore draft
    CommandSpec(
      id: 'restoreDraft.restore',
      scope: CommandScope.restoreDraft,
      group: HelpGroup.dialogs,
      label: 'Restore draft',
      description:
          'Load the recovery draft and compare the current version before '
          'saving.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'restoreDraft.discard',
      scope: CommandScope.restoreDraft,
      group: HelpGroup.dialogs,
      label: 'Discard',
      description: 'Delete the recovery draft.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),

    // --------------------------------------------------- enrichment preview
    CommandSpec(
      id: 'enrichmentPreview.original',
      scope: CommandScope.enrichmentPreview,
      group: HelpGroup.dialogs,
      label: 'Original text',
      description: 'Focus the original clipboard text.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyO)],
    ),
    CommandSpec(
      id: 'enrichmentPreview.result',
      scope: CommandScope.enrichmentPreview,
      group: HelpGroup.dialogs,
      label: 'Result text',
      description: 'Focus the enriched preview text.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'enrichmentPreview.close',
      scope: CommandScope.enrichmentPreview,
      group: HelpGroup.dialogs,
      label: 'Close',
      description: 'Close the preview. The clipboard is not written.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),

    // --------------------------------------------------------- keyboard help
    CommandSpec(
      id: 'keyboardHelp.search',
      scope: CommandScope.keyboardHelp,
      group: HelpGroup.dialogs,
      label: 'Search',
      description: 'Focus the help search field.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyF)],
    ),
    CommandSpec(
      id: 'keyboardHelp.list',
      scope: CommandScope.keyboardHelp,
      group: HelpGroup.dialogs,
      label: 'Shortcut list',
      description: 'Focus the shortcut list.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyL)],
    ),
    CommandSpec(
      id: 'keyboardHelp.close',
      scope: CommandScope.keyboardHelp,
      group: HelpGroup.dialogs,
      label: 'Close',
      description: 'Close help and restore the initiating control.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),

    // ---------------------------------------------------------------- status
    CommandSpec(
      id: 'status.details',
      scope: CommandScope.statusBar,
      group: HelpGroup.dialogs,
      label: 'Details',
      description: 'Focus the error details.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyD)],
    ),
    CommandSpec(
      id: 'status.retry',
      scope: CommandScope.statusBar,
      group: HelpGroup.dialogs,
      label: 'Retry',
      description: 'Retry the failed operation.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyR)],
    ),
    CommandSpec(
      id: 'status.browseCli',
      scope: CommandScope.statusBar,
      group: HelpGroup.dialogs,
      label: 'Browse CLI',
      description: 'Browse for a compatible tasks executable.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyB)],
    ),
    CommandSpec(
      id: 'status.testConnection',
      scope: CommandScope.statusBar,
      group: HelpGroup.dialogs,
      label: 'Test connection',
      description: 'Run the CLI protocol probe again.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyT)],
    ),
    CommandSpec(
      id: 'status.copyDraft',
      scope: CommandScope.statusBar,
      group: HelpGroup.dialogs,
      label: 'Copy draft',
      description: 'Copy the draft when local draft persistence failed.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyC)],
    ),

    // -------------------------------------------------- slow save close
    CommandSpec(
      id: 'slowSaveClose.keepWaiting',
      scope: CommandScope.slowSaveClose,
      group: HelpGroup.dialogs,
      label: 'Keep waiting',
      description:
          'Keep waiting for the running save. Closing never cancels an atomic '
          'store write.',
      activators: <ShortcutActivator>[_alt(LogicalKeyboardKey.keyW)],
    ),
  ],
);
