/// The draft form that replaces the read-only Details panel while editing
/// (viewer/design.md section 7, viewer/spec.md section 7).
///
/// The form owns only rendering: text controllers, focus nodes and the six
/// controls. Every value, validation message, dirty flag and write belongs to
/// [ViewerEditorController]; the details pane owns the dialogs and the
/// Save/Mark done orchestration.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/editor_controller.dart';
import '../data/editor_models.dart';
import '../data/models.dart';
import 'commands.dart';
import 'dialog_scope.dart';
import 'viewer_controls.dart';

/// Fixed feedback text for a write that outlives the busy threshold.
const String viewerEditorSavingMessage = 'Saving';

/// The form controls that hold editable text and therefore a caret. Status and
/// Priority are dropdowns.
const List<EditorField> _editorTextFields = <EditorField>[
  EditorField.title,
  EditorField.labels,
  EditorField.deps,
  EditorField.body,
];

/// One [FocusNode] per editor control.
///
/// The details pane owns this set: F3 has to reach the draft Body without
/// leaving edit mode, and a refused Save has to focus the first invalid field
/// even though the field lives in this widget.
class ViewerEditorFocusSet {
  ViewerEditorFocusSet() {
    for (final field in EditorField.values) {
      _nodes[field] = FocusNode(debugLabel: 'editor ${field.wireName}');
    }
  }

  final Map<EditorField, FocusNode> _nodes = <EditorField, FocusNode>{};
  final FocusNode save = FocusNode(debugLabel: 'editor save');
  final FocusNode cancel = FocusNode(debugLabel: 'editor cancel');

  FocusNode forField(EditorField field) => _nodes[field]!;

  FocusNode get title => forField(EditorField.title);
  FocusNode get body => forField(EditorField.body);

  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    _nodes.clear();
    save.dispose();
    cancel.dispose();
  }
}

/// Editable form for the one open draft.
class ViewerEditorForm extends StatefulWidget {
  const ViewerEditorForm({
    super.key,
    required this.editor,
    required this.focus,
    required this.onSave,
    required this.onCancel,
    required this.onCopyDraft,
    required this.onRetryReconciliation,
    this.onCommand,
    this.statusValues = viewerTaskStatuses,
    this.priorityValues = viewerTaskPriorities,
  });

  final ViewerEditorController editor;
  final ViewerEditorFocusSet focus;

  /// Save/Ctrl+S: validates, then runs the one version-checked update.
  final Future<void> Function() onSave;

  /// Cancel/Alt+C: runs the dirty guard, then leaves edit mode.
  final Future<void> Function() onCancel;

  /// Copy draft: preserves the text when the local draft was not persisted.
  final Future<void> Function() onCopyDraft;

  /// Retry for a save whose acknowledgement was lost.
  final Future<void> Function() onRetryReconciliation;

  /// Receives the ids this form does not own, so a global shortcut keeps its
  /// documented meaning while a draft field has focus (design.md section 9).
  final CommandDispatch? onCommand;

  /// Selectable status and priority values, in display order.
  final List<String> statusValues;
  final List<String> priorityValues;

  @override
  State<ViewerEditorForm> createState() => _ViewerEditorFormState();
}

class _ViewerEditorFormState extends State<ViewerEditorForm> {
  final Map<EditorField, TextEditingController> _texts =
      <EditorField, TextEditingController>{
        for (final field in EditorField.values) field: TextEditingController(),
      };

  /// What one text field held when it last lost focus.
  ///
  /// A single-line field on Windows selects its whole value when it regains
  /// focus (`EditableText.selectAllOnFocus` defaults to true on desktop), which
  /// would lose the caret the guard interrupted. The design promises focus and
  /// caret back at the previous field after Cancel (design.md section 7), so
  /// the value is kept here and put back on the way in.
  final Map<EditorField, TextEditingValue> _caretMemory =
      <EditorField, TextEditingValue>{};

  final Map<EditorField, VoidCallback> _focusHandlers =
      <EditorField, VoidCallback>{};

  @override
  void initState() {
    super.initState();
    widget.editor.addListener(_syncFromDraft);
    for (final field in _editorTextFields) {
      void handler() => _handleFieldFocus(field);
      _focusHandlers[field] = handler;
      widget.focus.forField(field).addListener(handler);
    }
    _syncFromDraft();
  }

  @override
  void dispose() {
    for (final entry in _focusHandlers.entries) {
      widget.focus.forField(entry.key).removeListener(entry.value);
    }
    _focusHandlers.clear();
    widget.editor.removeListener(_syncFromDraft);
    for (final controller in _texts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Remembers the caret when a field loses focus and restores it once focus
  /// comes back to the same text, after the frame that ran Flutter's own
  /// select-all-on-focus.
  void _handleFieldFocus(EditorField field) {
    final node = widget.focus.forField(field);
    final controller = _texts[field]!;
    if (!node.hasFocus) {
      _caretMemory[field] = controller.value;
      return;
    }
    final remembered = _caretMemory[field];
    if (remembered == null || remembered.text != controller.text) {
      return;
    }
    // Flutter applies its own select-all-on-focus after this listener runs, so
    // the comparison has to wait for the frame that ran it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final live = widget.focus.forField(field);
      if (!live.hasFocus || controller.text != remembered.text) {
        return;
      }
      controller.selection = remembered.selection;
    });
  }

  /// Mirrors the draft into the text controllers without typing over a field
  /// the user is still editing (a restore or a conflict review is the only
  /// writer that changes the draft behind the form's back).
  void _syncFromDraft() {
    final draft = widget.editor.draft;
    if (draft == null) {
      return;
    }
    for (final entry in _texts.entries) {
      final value = draft.textOf(entry.key);
      final controller = entry.value;
      if (controller.text != value) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    }
  }

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'editor.title':
        widget.focus.title.requestFocus();
        return KeyEventResult.handled;
      case 'editor.status':
        widget.focus.forField(EditorField.status).requestFocus();
        return KeyEventResult.handled;
      case 'editor.priority':
        widget.focus.forField(EditorField.priority).requestFocus();
        return KeyEventResult.handled;
      case 'editor.labels':
        widget.focus.forField(EditorField.labels).requestFocus();
        return KeyEventResult.handled;
      case 'editor.dependencies':
        widget.focus.forField(EditorField.deps).requestFocus();
        return KeyEventResult.handled;
      case 'editor.body':
        widget.focus.body.requestFocus();
        return KeyEventResult.handled;
      case 'editor.cancel':
        unawaited(widget.onCancel());
        return KeyEventResult.handled;
      default:
        return widget.onCommand?.call(id) ?? KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final theme = Theme.of(context);
    final draft = editor.draft;
    if (draft == null) {
      return const SizedBox.shrink();
    }
    final reconciliation = editor.isAwaitingReconciliation;
    return Shortcuts(
      shortcuts: shortcutMapForScope(CommandScope.editor),
      child: Actions(
        actions: commandActionsForScope(CommandScope.editor, _onCommand),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: Semantics(
                header: true,
                child: Text(
                  'Editing ${editor.canonicalTaskId ?? 'task'}  '
                  '(base version ${editor.base?.version ?? 0})',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            if (reconciliation)
              _buildReconciliation(editor)
            else if (editor.persistenceWarning != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        editor.persistenceWarning!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => unawaited(widget.onCopyDraft()),
                      child: const Text('Copy draft'),
                    ),
                  ],
                ),
              ),
            const ViewerRule(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildTextField(
                      field: EditorField.title,
                      label: 'Title (Alt+T)',
                      helper: 'Cannot be empty. At most 500 characters.',
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    _buildEnumField(
                      field: EditorField.status,
                      label: 'Status (Alt+S)',
                      values: widget.statusValues,
                      value: draft.status,
                    ),
                    const SizedBox(height: 12),
                    _buildEnumField(
                      field: EditorField.priority,
                      label: 'Priority (Alt+P)',
                      values: widget.priorityValues,
                      value: draft.priority,
                    ),
                    const SizedBox(height: 12),
                    _buildTextField(
                      field: EditorField.labels,
                      label: 'Labels (Alt+L)',
                      helper:
                          'Comma-separated, at most 32; each up to 64 of '
                          'a-z 0-9 -_.: Empty clears every label.',
                    ),
                    const SizedBox(height: 12),
                    _buildTextField(
                      field: EditorField.deps,
                      label: 'Dependencies (Alt+D)',
                      helper:
                          'Comma-separated T-IDs in this project, at most '
                          '1000. Empty clears every dependency.',
                    ),
                    const SizedBox(height: 12),
                    _buildTextField(
                      field: EditorField.body,
                      label: 'Body (F3 or Alt+B)',
                      helper:
                          'Markdown text. At most 1,048,576 UTF-8 bytes; '
                          'Enter adds a newline.',
                      minLines: 6,
                      maxLines: 12,
                    ),
                  ],
                ),
              ),
            ),
            const ViewerRule(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: Row(
                children: <Widget>[
                  Tooltip(
                    message: 'Ctrl+S',
                    child: FilledButton(
                      focusNode: widget.focus.save,
                      onPressed: editor.saveEnabled
                          ? () => unawaited(widget.onSave())
                          : null,
                      child: Text(editor.isSaving ? 'Saving' : 'Save (Ctrl+S)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Alt+C',
                    child: TextButton(
                      focusNode: widget.focus.cancel,
                      onPressed: () => unawaited(widget.onCancel()),
                      child: const Text('Cancel (Alt+C)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      editor.isSaving
                          ? 'Saving the task.'
                          : editor.isDirty
                          ? 'Unsaved changes.'
                          : 'No changes yet.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReconciliation(ViewerEditorController editor) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'The last save outcome is unknown until the task is read again. '
              'Save stays disabled.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => unawaited(widget.onRetryReconciliation()),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required EditorField field,
    required String label,
    required String helper,
    bool autofocus = false,
    int minLines = 1,
    int maxLines = 1,
  }) {
    return TextField(
      controller: _texts[field],
      focusNode: widget.focus.forField(field),
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: (value) => widget.editor.setField(field, value),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        errorText: widget.editor.errors[field],
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildEnumField({
    required EditorField field,
    required String label,
    required List<String> values,
    required String value,
  }) {
    final options = <String>{...values, if (values.isNotEmpty) value};
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('${field.wireName}-$value'),
      initialValue: value,
      focusNode: widget.focus.forField(field),
      isExpanded: true,
      onChanged: (next) {
        if (next != null) {
          widget.editor.setField(field, next);
        }
      },
      decoration: InputDecoration(
        labelText: label,
        errorText: widget.editor.errors[field],
        border: const OutlineInputBorder(),
      ),
      items: <DropdownMenuItem<String>>[
        for (final option in options)
          DropdownMenuItem<String>(
            value: option,
            child: Text(viewerStatusLabel(option)),
          ),
      ],
    );
  }
}
