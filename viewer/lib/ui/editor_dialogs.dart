/// The editor's modal guards: unsaved changes, Mark done with a draft, the
/// version conflict, reviewing against the current record and restoring a
/// recovery draft (viewer/design.md section 8, viewer/spec.md section 7).
///
/// Each dialog returns a plain decision; the details pane performs the store
/// work. Escape is always the safe Cancel/Close action and never Discard.
library;

import 'package:flutter/material.dart';

import '../controllers/editor_controller.dart';
import '../data/editor_models.dart';
import '../data/settings_store.dart';
import 'commands.dart';
import 'dialog_scope.dart';

/// The interactive half of the editor flow: the modal questions and the
/// spoken confirmations that need a live shell.
///
/// [ViewerWorkspaceModel] owns the editor state, but only a pane has the shell
/// API that can show a dialog or play a clip. The details pane implements this
/// so a leaving action that starts outside it - a task or project switch, a
/// settings change or a window close - can still ask before it drops a draft.
abstract class ViewerEditorHost {
  /// F4 for the selected task: enter edit mode, announce it and put the caret
  /// in Title. A no-op when no task is selected.
  Future<void> beginEdit();

  /// Save / Discard / Cancel for [reason]; false cancels the leaving action.
  ///
  /// A clean editor needs no question and answers true.
  Future<bool> confirmLeave(EditorLeaveReason reason);

  /// Save / Ctrl+S for the open draft, with its conflict and reconciliation
  /// dialogs. The result is the store's verdict; null means nothing was
  /// attempted, because no editor was open or a write was already running.
  Future<EditorSaveResult?> save();

  /// Ctrl+D for the selected task: the dirty-draft dialog first when the open
  /// editor has changes, then one version-checked update to `done`. Null when
  /// the task was already done, the user cancelled, or a write was running.
  Future<EditorSaveResult?> markDone();

  /// Runs the conflict workflow for [conflict] and follows its answer.
  Future<void> resolveConflict(EditorConflict conflict);

  /// Offers Restore draft / Discard for a draft found on disk (spec.md
  /// section 7, "Shared validation, updates and recovery").
  Future<void> offerDraftRestore(ViewerRecoveryDraft draft);

  /// Waits out a write in flight before the window closes. True when nothing
  /// was running any more.
  Future<bool> settleBeforeClose();
}

/// What a leaving action should do with the open draft.
enum EditorLeaveDecision { save, discard, cancel }

/// What Ctrl+D on a dirty editor should do.
enum MarkDoneDirtyDecision { saveAndMarkDone, discardAndMarkDone, cancel }

/// What the version-conflict dialog chose.
enum EditorConflictDecision { returnToEditor, reloadAndDiscard, review }

/// What a restart's restore prompt chose.
enum EditorRestoreDecision { restore, discard }

/// Shared frame: named dialog, contained traversal, one safe default action.
class _EditorDialogFrame extends StatelessWidget {
  const _EditorDialogFrame({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: size.width < 340 ? size.width - 32 : 320,
          maxWidth: 620,
          maxHeight: size.height - 48,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Save / Discard / Cancel for a leaving action with a dirty draft.
class ViewerUnsavedChangesDialog extends StatelessWidget {
  const ViewerUnsavedChangesDialog({
    super.key,
    required this.identity,
    required this.title,
    required this.question,
  });

  /// Task identity, for example `T-042`.
  final String identity;

  /// Full task title.
  final String title;

  /// The reason-specific question, from [editorLeaveQuestion].
  final String question;

  void _close(BuildContext context, EditorLeaveDecision decision) =>
      Navigator.of(context).pop(decision);

  @override
  Widget build(BuildContext context) {
    return DialogCommandHost(
      scope: CommandScope.unsavedChanges,
      onCommand: (id) {
        switch (id) {
          case 'unsaved.save':
            _close(context, EditorLeaveDecision.save);
          case 'unsaved.discard':
            _close(context, EditorLeaveDecision.discard);
          case 'unsaved.cancel':
          case 'dialogs.dismiss':
            _close(context, EditorLeaveDecision.cancel);
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: _EditorDialogFrame(
        title: 'Unsaved changes',
        children: <Widget>[
          Text('$identity  $title'),
          const SizedBox(height: 8),
          Text(question),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              FilledButton(
                onPressed: () => _close(context, EditorLeaveDecision.save),
                child: const Text('Save (Alt+S)'),
              ),
              OutlinedButton(
                onPressed: () => _close(context, EditorLeaveDecision.discard),
                child: const Text('Discard (Alt+D)'),
              ),
              TextButton(
                autofocus: true,
                onPressed: () => _close(context, EditorLeaveDecision.cancel),
                child: const Text('Cancel (Alt+C)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Save changes and mark done / Discard changes and mark done / Cancel.
class ViewerMarkDoneDirtyDialog extends StatelessWidget {
  const ViewerMarkDoneDirtyDialog({
    super.key,
    required this.identity,
    required this.title,
  });

  final String identity;
  final String title;

  void _close(BuildContext context, MarkDoneDirtyDecision decision) =>
      Navigator.of(context).pop(decision);

  @override
  Widget build(BuildContext context) {
    return DialogCommandHost(
      scope: CommandScope.markDoneDirty,
      onCommand: (id) {
        switch (id) {
          case 'markDone.saveAndMarkDone':
            _close(context, MarkDoneDirtyDecision.saveAndMarkDone);
          case 'markDone.discardAndMarkDone':
            _close(context, MarkDoneDirtyDecision.discardAndMarkDone);
          case 'markDone.cancel':
          case 'dialogs.dismiss':
            _close(context, MarkDoneDirtyDecision.cancel);
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: _EditorDialogFrame(
        title: 'Mark task done with unsaved changes?',
        children: <Widget>[
          Text('$identity  $title'),
          const SizedBox(height: 8),
          const Text(
            'Saving changes and marking done sends one version-checked '
            'update. Discarding changes sends only the done status and keeps '
            'the draft until the store confirms.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              FilledButton(
                onPressed: () =>
                    _close(context, MarkDoneDirtyDecision.saveAndMarkDone),
                child: const Text('Save changes and mark done (Alt+S)'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _close(context, MarkDoneDirtyDecision.discardAndMarkDone),
                child: const Text('Discard changes and mark done (Alt+D)'),
              ),
              TextButton(
                autofocus: true,
                onPressed: () => _close(context, MarkDoneDirtyDecision.cancel),
                child: const Text('Cancel (Alt+C)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One Base / Mine / Current block for a field, all values selectable.
class _ConflictFieldBlock extends StatelessWidget {
  const _ConflictFieldBlock({
    required this.field,
    required this.base,
    required this.mine,
    required this.current,
    this.baseFocus,
    this.mineFocus,
    this.currentFocus,
  });

  final EditorField field;
  final String base;
  final String mine;
  final String current;
  final FocusNode? baseFocus;
  final FocusNode? mineFocus;
  final FocusNode? currentFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(field.label, style: theme.textTheme.labelLarge),
          _conflictValue(context, 'Base', base, baseFocus),
          _conflictValue(context, 'Mine', mine, mineFocus),
          _conflictValue(context, 'Current', current, currentFocus),
        ],
      ),
    );
  }

  Widget _conflictValue(
    BuildContext context,
    String label,
    String value,
    FocusNode? node,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: MergeSemantics(
        child: Focus(
          focusNode: node,
          child: SelectableText(
            '$label: ${value.isEmpty ? '(empty)' : value}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// Base/current versions, the changed fields and the three documented actions.
class ViewerConflictDialog extends StatelessWidget {
  const ViewerConflictDialog({super.key, required this.conflict});

  final EditorConflict conflict;

  void _close(BuildContext context, EditorConflictDecision decision) =>
      Navigator.of(context).pop(decision);

  @override
  Widget build(BuildContext context) {
    return DialogCommandHost(
      scope: CommandScope.conflict,
      onCommand: (id) {
        switch (id) {
          case 'conflict.returnToEditor':
            _close(context, EditorConflictDecision.returnToEditor);
          case 'conflict.reloadAndDiscard':
            _close(context, EditorConflictDecision.reloadAndDiscard);
          case 'conflict.review':
            _close(context, EditorConflictDecision.review);
          case 'dialogs.dismiss':
            _close(context, EditorConflictDecision.returnToEditor);
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: _EditorDialogFrame(
        title: 'Version conflict',
        children: <Widget>[
          Text(
            '${conflict.current.canonicalId} was based on version '
            '${conflict.baseVersion} and is now at version '
            '${conflict.currentVersion}.',
          ),
          const SizedBox(height: 4),
          Text(
            conflict.changedFields.isEmpty
                ? 'No field differs from the base record.'
                : 'Changed fields: '
                      '${conflict.changedFields.map((field) => field.label).join(', ')}.',
          ),
          const Divider(height: 20),
          for (final field in conflict.changedFields)
            _ConflictFieldBlock(
              field: field,
              base: conflict.baseFields.textOf(field),
              mine: conflict.draftFields.textOf(field),
              current: conflict.currentFields.textOf(field),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _close(context, EditorConflictDecision.review),
                child: const Text('Review against current (Alt+V)'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _close(context, EditorConflictDecision.reloadAndDiscard),
                child: const Text('Reload current and discard draft (Alt+R)'),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () =>
                    _close(context, EditorConflictDecision.returnToEditor),
                child: const Text('Return to editor (Alt+E)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Per-field Mine or Current choices before saving again.
class ViewerConflictReviewDialog extends StatefulWidget {
  const ViewerConflictReviewDialog({super.key, required this.conflict});

  final EditorConflict conflict;

  @override
  State<ViewerConflictReviewDialog> createState() =>
      _ViewerConflictReviewDialogState();
}

class _ViewerConflictReviewDialogState
    extends State<ViewerConflictReviewDialog> {
  late final Map<EditorField, EditorConflictChoice> _choices =
      <EditorField, EditorConflictChoice>{...widget.conflict.choices};
  late EditorField _selected = _firstUnresolved();

  final FocusNode _selector = FocusNode(debugLabel: 'conflict review field');
  final FocusNode _base = FocusNode(debugLabel: 'conflict review base');
  final FocusNode _mine = FocusNode(debugLabel: 'conflict review mine');
  final FocusNode _current = FocusNode(debugLabel: 'conflict review current');

  @override
  void dispose() {
    _selector.dispose();
    _base.dispose();
    _mine.dispose();
    _current.dispose();
    super.dispose();
  }

  List<EditorField> get _fields => widget.conflict.conflictFields;

  EditorField _firstUnresolved() {
    for (final field in _fields) {
      if (!_choices.containsKey(field)) {
        return field;
      }
    }
    return _fields.isEmpty ? EditorField.title : _fields.first;
  }

  bool get _isResolved => _fields.every((field) => _choices.containsKey(field));

  void _choose(EditorField field, EditorConflictChoice choice) {
    setState(() {
      _choices[field] = choice;
      _selected = field;
    });
  }

  void _advance() {
    for (final field in _fields) {
      if (!_choices.containsKey(field)) {
        setState(() => _selected = field);
        return;
      }
    }
  }

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'conflictReview.fieldSelector':
        _selector.requestFocus();
      case 'conflictReview.baseValue':
        _base.requestFocus();
      case 'conflictReview.mineValue':
        _mine.requestFocus();
      case 'conflictReview.currentValue':
        _current.requestFocus();
      case 'conflictReview.chooseMine':
        _choose(_selected, EditorConflictChoice.mine);
        _advance();
      case 'conflictReview.chooseCurrent':
        _choose(_selected, EditorConflictChoice.current);
        _advance();
      case 'conflictReview.apply':
        if (_isResolved) {
          Navigator.of(context).pop(_choices);
        }
      case 'conflictReview.cancel':
      case 'dialogs.dismiss':
        Navigator.of(context).pop(null);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    return DialogCommandHost(
      scope: CommandScope.conflictReview,
      onCommand: _onCommand,
      child: _EditorDialogFrame(
        title: 'Review against current',
        children: <Widget>[
          const Text(
            'Choose Mine or Current for every conflicting field. Applying '
            'only rebases the form; saving is a separate step.',
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<EditorField>(
            key: ValueKey<EditorField>(_selected),
            initialValue: _selected,
            focusNode: _selector,
            isExpanded: true,
            onChanged: (field) {
              if (field != null) {
                setState(() => _selected = field);
              }
            },
            decoration: const InputDecoration(
              labelText: 'Conflicting field (Alt+F)',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<EditorField>>[
              for (final field in _fields)
                DropdownMenuItem<EditorField>(
                  value: field,
                  child: Text(
                    _choices.containsKey(field)
                        ? '${field.label} - '
                              '${_choices[field] == EditorConflictChoice.mine ? 'Mine' : 'Current'}'
                        : '${field.label} - undecided',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _ConflictFieldBlock(
            field: _selected,
            base: conflict.baseFields.textOf(_selected),
            mine: conflict.draftFields.textOf(_selected),
            current: conflict.currentFields.textOf(_selected),
            baseFocus: _base,
            mineFocus: _mine,
            currentFocus: _current,
          ),
          const SizedBox(height: 8),
          for (final field in _fields) _buildChooser(field),
          const SizedBox(height: 8),
          Text(
            _isResolved
                ? 'Every conflicting field has a choice.'
                : 'Choose Mine or Current for every conflicting field.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              FilledButton(
                onPressed: _isResolved
                    ? () => Navigator.of(context).pop(_choices)
                    : null,
                child: const Text('Apply choices (Alt+A)'),
              ),
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel (Alt+C)'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChooser(EditorField field) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MergeSemantics(
        child: SegmentedButton<EditorConflictChoice>(
          segments: const <ButtonSegment<EditorConflictChoice>>[
            ButtonSegment<EditorConflictChoice>(
              value: EditorConflictChoice.mine,
              label: Text('Mine'),
            ),
            ButtonSegment<EditorConflictChoice>(
              value: EditorConflictChoice.current,
              label: Text('Current'),
            ),
          ],
          selected: <EditorConflictChoice>{
            if (_choices[field] != null) _choices[field]!,
          },
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          onSelectionChanged: (values) {
            if (values.isEmpty) {
              setState(() => _choices.remove(field));
              return;
            }
            _choose(field, values.first);
          },
        ),
      ),
    );
  }
}

/// Restore draft / Discard for one recovery draft found at startup.
class ViewerRestoreDraftDialog extends StatelessWidget {
  const ViewerRestoreDraftDialog({
    super.key,
    required this.identity,
    required this.title,
    required this.baseVersion,
    required this.currentVersion,
  });

  final String identity;
  final String title;
  final int baseVersion;
  final int currentVersion;

  @override
  Widget build(BuildContext context) {
    void close(EditorRestoreDecision decision) =>
        Navigator.of(context).pop(decision);

    return DialogCommandHost(
      scope: CommandScope.restoreDraft,
      onCommand: (id) {
        switch (id) {
          case 'restoreDraft.restore':
            close(EditorRestoreDecision.restore);
          case 'restoreDraft.discard':
            close(EditorRestoreDecision.discard);
          case 'dialogs.dismiss':
            close(EditorRestoreDecision.restore);
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: _EditorDialogFrame(
        title: 'Restore draft',
        children: <Widget>[
          Text('$identity  $title'),
          const SizedBox(height: 8),
          Text(
            'The draft was written against version $baseVersion; the store is '
            'now at version $currentVersion. Restoring compares the current '
            'record before anything can be saved.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              FilledButton(
                autofocus: true,
                onPressed: () => close(EditorRestoreDecision.restore),
                child: const Text('Restore draft (Alt+R)'),
              ),
              TextButton(
                onPressed: () => close(EditorRestoreDecision.discard),
                child: const Text('Discard (Alt+D)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Close request while a save is in flight: keep waiting, never claim to
/// cancel an atomic store write.
class ViewerSlowSaveCloseDialog extends StatelessWidget {
  const ViewerSlowSaveCloseDialog({super.key, required this.identity});

  final String identity;

  @override
  Widget build(BuildContext context) {
    return DialogCommandHost(
      scope: CommandScope.slowSaveClose,
      onCommand: (id) {
        switch (id) {
          case 'slowSaveClose.keepWaiting':
          case 'dialogs.dismiss':
            Navigator.of(context).pop();
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: _EditorDialogFrame(
        title: 'Save still running',
        children: <Widget>[
          Text(
            '$identity is still being written. The viewer keeps waiting so a '
            'committed write is never reported as cancelled.',
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep waiting (Alt+W)'),
            ),
          ),
        ],
      ),
    );
  }
}
