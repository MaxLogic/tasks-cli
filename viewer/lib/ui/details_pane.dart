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
import '../controllers/editor_controller.dart';
import '../data/editor_models.dart';
import '../data/models.dart';
import '../data/settings_store.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'body_text.dart';
import 'commands.dart';
import 'editor_dialogs.dart';
import 'editor_form.dart';
import 'viewer_controls.dart';
import 'viewer_format.dart';
import 'workspace_model.dart';

/// How long a read may run before the pane says it is still loading.
const Duration viewerSlowReadAfter = Duration(milliseconds: 500);

/// Task details region bound to one workspace model.
class ViewerDetailsPane extends StatefulWidget {
  const ViewerDetailsPane({super.key, required this.api, required this.model});

  final ViewerShellApi api;
  final ViewerWorkspaceModel model;

  @override
  State<ViewerDetailsPane> createState() => _ViewerDetailsPaneState();
}

class _ViewerDetailsPaneState extends State<ViewerDetailsPane>
    implements ViewerEditorHost {
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

  /// Focus targets the editor adds: one per field plus the header actions the
  /// leaving guards return to.
  final ViewerEditorFocusSet _editorFocus = ViewerEditorFocusSet();
  final FocusNode _editActionFocus = FocusNode(debugLabel: 'details edit');
  final FocusNode _markDoneActionFocus = FocusNode(
    debugLabel: 'details mark done',
  );

  /// Controller instance the local text controls are currently bound to.
  TaskDetailController? _boundController;
  String? _announcedNotice;
  String? _slowReadKey;
  Timer? _slowReadTimer;

  ViewerEditorController get _editor => widget.model.editor;

  ViewerRegionHandles get _handles =>
      widget.api.handlesFor(ViewerRegion.details);

  @override
  void initState() {
    super.initState();
    widget.api.registerScopeCommands(CommandScope.details, _onScopeCommand);
    widget.api.registerScopeCommands(CommandScope.statusBar, _onStatusCommand);
    widget.model.addListener(_syncExternalContent);
    widget.model.editorHost = this;
    _syncExternalContent();
  }

  @override
  void dispose() {
    if (identical(widget.model.editorHost, this)) {
      widget.model.editorHost = null;
    }
    widget.api.registerScopeCommands(CommandScope.details, null);
    widget.api.registerScopeCommands(CommandScope.statusBar, null);
    widget.model.removeListener(_syncExternalContent);
    _slowReadTimer?.cancel();
    _editorFocus.dispose();
    _editActionFocus.dispose();
    _markDoneActionFocus.dispose();
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

  /// The status region asks first for the one command its own scope cannot
  /// answer: Copy draft (design.md section 9, Status/error/setup).
  KeyEventResult _onStatusCommand(String id) {
    if (id != 'status.copyDraft') {
      return KeyEventResult.ignored;
    }
    final editor = _editor;
    if (!editor.isEditing || editor.draft == null) {
      return KeyEventResult.ignored;
    }
    unawaited(_copyDraft());
    return KeyEventResult.handled;
  }

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
        // In edit mode F3 reaches the draft Body without leaving the editor
        // (design.md section 7, "Task details and editor").
        if (_editor.isEditing) {
          widget.api.revealRegion(ViewerRegion.details);
          _focusEditorField(EditorField.body);
          return KeyEventResult.handled;
        }
        _revealPanel(TaskDetailTab.details, _handles.bodyFocus);
        return KeyEventResult.handled;
      case 'global.findInBody':
        _revealPanel(TaskDetailTab.details, _handles.findFocus);
        return KeyEventResult.handled;
      case 'global.back':
        return _back() ? KeyEventResult.handled : KeyEventResult.ignored;
      case 'global.editTask':
        unawaited(beginEdit());
        return KeyEventResult.handled;
      case 'global.markDone':
        unawaited(_markDone());
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
    final attribution = state.historyEvents
        .where((event) => event.eventId == eventId)
        .firstOrNull
        ?.attribution;
    final context = attribution == null || attribution.detailText.isEmpty
        ? ''
        : '${attribution.detailText}\n\n';
    return snapshot.isEmpty
        ? 'Event $eventId has no stored snapshot.'
        : '$context$snapshot';
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

  // ---------------------------------------------------------------- editor

  /// F4, the Edit button and the shell's fallback action.
  @override
  Future<void> beginEdit() async {
    final editor = _editor;
    if (editor.isEditing) {
      widget.api.revealRegion(ViewerRegion.details);
      _focusEditorField(EditorField.title);
      return;
    }
    final base = editor.base;
    if (base == null) {
      widget.api.announce('Select a task before editing.', dynamic: true);
      return;
    }
    widget.api.revealRegion(ViewerRegion.details);
    editor.beginEdit();
    widget.api.announce(
      'Editing ${editor.canonicalTaskId ?? base.canonicalId}, base version ${base.version}.',
      dynamic: true,
    );
    _focusEditorField(EditorField.title);
  }

  /// Ctrl+D, the Mark done button and the shell's fallback action.
  ///
  /// A clean selected task needs no confirmation; a dirty editor asks first and
  /// keeps the draft until the store confirms (spec.md section 7).
  Future<EditorSaveResult?> _markDone({bool fromHeader = false}) async {
    final editor = _editor;
    final base = editor.base;
    if (base == null) {
      widget.api.announce(
        'Select a task before marking it done.',
        dynamic: true,
      );
      return null;
    }
    if (base.status == 'done') {
      widget.api.announce(
        '${base.canonicalId} is already done.',
        dynamic: true,
      );
      return null;
    }
    if (editor.isSaving) {
      return null;
    }
    if (editor.isEditing && editor.isDirty) {
      final decision = await widget.api.showModal<MarkDoneDirtyDecision>(
        CommandScope.markDoneDirty,
        (context) => ViewerMarkDoneDirtyDialog(
          identity: base.canonicalId,
          title: base.title,
        ),
      );
      switch (decision) {
        case MarkDoneDirtyDecision.saveAndMarkDone:
          return _runWrite(
            () => editor.markDone(includeDraft: true),
            clipId: 'task_done',
          );
        case MarkDoneDirtyDecision.discardAndMarkDone:
          // Discard sends only the status: the draft survives a failure or a
          // conflict and is cleared once the store confirms.
          return _runWrite(() => editor.markDone(), clipId: 'task_done');
        case MarkDoneDirtyDecision.cancel:
        case null:
          return null;
      }
    }
    final restoreHeaderFocus = fromHeader || _markDoneActionFocus.hasFocus;
    final projectId = widget.model.selectedProjectId;
    final result = await _runWrite(
      () => editor.markDone(),
      clipId: 'task_done',
    );
    if (restoreHeaderFocus && result.outcome == EditorSaveOutcome.failed) {
      // The in-flight disabled button loses focus before the CLI answers.
      // Restore its initiator once the enabled button has been rebuilt.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.model.selectedProjectId == projectId &&
            _editor.base?.id == base.id &&
            !_editor.isEditing &&
            _markDoneEnabled &&
            _markDoneActionFocus.canRequestFocus) {
          _markDoneActionFocus.requestFocus();
        }
      });
    }
    return result;
  }

  /// Save / Ctrl+S from the form and the shell's fallback action.
  @override
  Future<EditorSaveResult?> save() async {
    final editor = _editor;
    if (!editor.isEditing || editor.isSaving) {
      return null;
    }
    return _runWrite(() => editor.save(), clipId: 'task_saved');
  }

  @override
  Future<EditorSaveResult?> markDone() => _markDone();

  /// The reconciliation Retry under the form's unknown-outcome banner.
  Future<void> _retryReconciliation() async {
    final editor = _editor;
    if (editor.isSaving) {
      return;
    }
    await _runWrite(() => editor.retryReconciliation(), clipId: 'task_saved');
  }

  /// Cancel/Alt+C in the form: the dirty guard, then out of edit mode.
  Future<void> _cancelEdit() async {
    if (await confirmLeave(EditorLeaveReason.leaveEditMode)) {
      _editor.exitEdit();
    }
  }

  // ----------------------------------------------------------- editor host

  @override
  Future<bool> confirmLeave(EditorLeaveReason reason) async {
    final editor = _editor;
    if (!editor.isEditing) {
      return true;
    }
    // Persist before the question: a crash inside the dialog must not lose the
    // keystrokes the status line already promised to keep.
    await editor.flushDraft();
    if (!editor.isDirty) {
      return true;
    }
    final base = editor.base;
    final identity = base?.canonicalId ?? 'This task';
    final decision = await widget.api.showModal<EditorLeaveDecision>(
      CommandScope.unsavedChanges,
      (context) => ViewerUnsavedChangesDialog(
        identity: identity,
        title: base?.title ?? '',
        question: editorLeaveQuestion(reason),
      ),
    );
    switch (decision) {
      case EditorLeaveDecision.save:
        final result = await _runWrite(
          () => editor.save(),
          clipId: 'task_saved',
          refocusEdit: false,
        );
        // Navigation continues only after a confirmed save or reconciliation.
        return result.isSuccess;
      case EditorLeaveDecision.discard:
        await editor.discardDraft();
        widget.api.announce(
          'Discarded the draft of $identity.',
          clipId: 'draft_discarded',
        );
        return true;
      case EditorLeaveDecision.cancel:
      case null:
        return false;
    }
  }

  @override
  Future<void> resolveConflict(EditorConflict conflict) async {
    final editor = _editor;
    final canonical = conflict.current.canonicalId;
    final decision = await widget.api.showModal<EditorConflictDecision>(
      CommandScope.conflict,
      (context) => ViewerConflictDialog(conflict: conflict),
    );
    switch (decision) {
      case EditorConflictDecision.reloadAndDiscard:
        await editor.reloadCurrentAndDiscardDraft();
        widget.api.announce(
          'Reloaded $canonical at version ${conflict.current.version}. '
          'Your draft was discarded.',
          dynamic: true,
        );
        await widget.model.noteConfirmedRead();
      case EditorConflictDecision.review:
        final choices = await widget.api
            .showModal<Map<EditorField, EditorConflictChoice>>(
              CommandScope.conflictReview,
              (context) => ViewerConflictReviewDialog(conflict: conflict),
            );
        if (choices == null) {
          widget.api.announce(
            'No choices applied. $canonical still conflicts with your draft.',
            dynamic: true,
          );
          return;
        }
        editor.applyConflictReview(choices);
        widget.api.announce(
          'Rebased your draft on version ${conflict.current.version} of '
          '$canonical. Save again to write it.',
          dynamic: true,
        );
        final fields = conflict.conflictFields;
        if (fields.isNotEmpty) {
          _focusEditorField(fields.first);
        }
      case EditorConflictDecision.returnToEditor:
      case null:
        widget.api.announce(
          '$canonical changed in the store. Resolve the conflict before '
          'saving; your draft is kept.',
          dynamic: true,
        );
    }
  }

  @override
  Future<void> offerDraftRestore(ViewerRecoveryDraft draft) async {
    final editor = _editor;
    final current = widget.model.detail?.detail;
    if (current == null || viewerCanonicalTaskId(current.id) != draft.taskId) {
      return;
    }
    // Drafts keep the T-N identity; people see the keyed display form.
    final shown = current.canonicalId;
    final TaskEditFields baseFields;
    final TaskEditFields draftFields;
    try {
      baseFields = TaskEditFields.fromJson(draft.baseFields);
      draftFields = TaskEditFields.fromJson(draft.draftFields);
    } on FormatException catch (error) {
      await editor.discardRecoveryDraft(draft);
      widget.api.announce(
        'The saved draft for $shown could not be read and was '
        'removed: ${error.message}.',
        dynamic: true,
      );
      return;
    }
    final decision = await widget.api.showModal<EditorRestoreDecision>(
      CommandScope.restoreDraft,
      (context) => ViewerRestoreDraftDialog(
        identity: shown,
        title: current.title,
        baseVersion: draft.baseVersion,
        currentVersion: current.version,
      ),
    );
    if (decision != EditorRestoreDecision.restore) {
      await editor.discardRecoveryDraft(draft);
      widget.api.announce(
        'Discarded the saved draft for $shown.',
        clipId: 'draft_discarded',
      );
      return;
    }
    widget.api.revealRegion(ViewerRegion.details);
    editor.restoreDraft(
      projectId: draft.projectId,
      current: current,
      baseFields: baseFields,
      baseVersion: draft.baseVersion,
      draftFields: draftFields,
      draftProjectKeys: draft.projectKeys,
    );
    // The draft stays on disk until the restored form is saved or discarded.
    editor.settleRecoveryDraft(draft);
    widget.api.announce(
      'Restored the saved draft for $shown. Check the fields, then '
      'save.',
      clipId: 'draft_restored',
    );
    _focusEditorField(EditorField.title);
  }

  @override
  Future<bool> settleBeforeClose() async {
    final editor = _editor;
    if (!editor.isSaving) {
      return true;
    }
    // "Keep waiting" is the only action: an atomic store write cannot be
    // cancelled, and the window must not pretend otherwise.
    await widget.api.showModal<void>(
      CommandScope.slowSaveClose,
      (context) => ViewerSlowSaveCloseDialog(
        identity: editor.canonicalTaskId ?? 'this task',
      ),
    );
    return !editor.isSaving;
  }

  // ------------------------------------------------------------ write paths

  /// One write with the busy feedback, the outcome rules and the data refresh.
  Future<EditorSaveResult> _runWrite(
    Future<EditorSaveResult> Function() write, {
    required String clipId,
    bool refocusEdit = true,
  }) async {
    _startBusyWatch();
    final result = await write();
    await _afterWrite(result, clipId: clipId, refocusEdit: refocusEdit);
    return result;
  }

  /// Speaks the outcome the way design.md section 7 asks, then refreshes.
  Future<void> _afterWrite(
    EditorSaveResult result, {
    required String clipId,
    bool refocusEdit = true,
  }) async {
    final editor = _editor;
    switch (result.outcome) {
      case EditorSaveOutcome.saved:
      case EditorSaveOutcome.reconciled:
        widget.api.announce(result.message ?? 'Saved.', clipId: clipId);
        await widget.model.noteConfirmedRead();
        if (refocusEdit) {
          _returnToEditAction();
        }
      case EditorSaveOutcome.noop:
        widget.api.announce(
          result.message ?? 'No changes needed',
          clipId: 'no_changes',
        );
        if (refocusEdit) {
          _returnToEditAction();
        }
      case EditorSaveOutcome.unsaved:
      case EditorSaveOutcome.failed:
        widget.api.announce(
          result.message ?? 'The write did not complete.',
          dynamic: true,
        );
      case EditorSaveOutcome.invalid:
        final field = editor.firstInvalidField;
        if (field != null) {
          _focusEditorField(field);
        }
        widget.api.announce(
          result.message ?? 'Some fields need attention.',
          dynamic: true,
        );
      case EditorSaveOutcome.conflict:
        final conflict = result.conflict;
        if (conflict != null) {
          await resolveConflict(conflict);
        }
    }
  }

  /// The busy rule: one coalesced "Saving" status, with Bella's static clip
  /// only once the write outlives the announcement controller's 500 ms
  /// progress delay (design.md section 7). The outcome announcement that
  /// follows every write clears the pending progress.
  void _startBusyWatch() {
    widget.api.announceProgress(viewerEditorSavingMessage, clipId: 'saving');
  }

  /// Focuses one field of the open form once the frame that owns it exists.
  void _focusEditorField(EditorField field) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final node = _editorFocus.forField(field);
      if (node.context != null && node.canRequestFocus) {
        node.requestFocus();
      }
    });
  }

  /// Returns focus to Edit after a save returns to read mode.
  void _returnToEditAction() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _editActionFocus.context != null &&
          _editActionFocus.canRequestFocus) {
        _editActionFocus.requestFocus();
      }
    });
  }

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
          return _buildNoSelection(context);
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
        // The editor replaces Details and the tab strip, so a half-written
        // task can never sit next to a read view that claims it is stored.
        if (_editor.isEditing) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final budget = viewerPaneBudgetFor(
                context,
                constraints.maxHeight,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ViewerPaneRegion(
                    maxHeight: budget.header,
                    child: _buildHeader(context, state, detail),
                  ),
                  Expanded(child: _buildEditor(context)),
                ],
              );
            },
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
                const ViewerRule(),
                Expanded(child: _buildPanel(context, state, detail)),
              ],
            );
          },
        );
      },
    );
  }

  /// Nothing selected yet: a top-aligned hint that says how to get a task
  /// here, instead of one sentence floating in a blank pane.
  Widget _buildNoSelection(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          ViewerSpace.m,
          ViewerSpace.s,
          ViewerSpace.m,
          ViewerSpace.m,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Select a task to read its details.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: ViewerSpace.s),
            Text(
              'F2 moves to the task list. Up and Down show a task here; '
              'Enter opens it at once. F3 reads the description and F4 '
              'edits the task.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Placeholder for "the first read is running".
  Widget _buildMessage(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }

  /// The draft form, bound to this pane's dialogs and the model's refresh.
  Widget _buildEditor(BuildContext context) {
    return ViewerEditorForm(
      editor: _editor,
      focus: _editorFocus,
      onSave: () async {
        await save();
      },
      onCancel: _cancelEdit,
      onCopyDraft: _copyDraft,
      onRetryReconciliation: _retryReconciliation,
      onCommand: (id) => widget.api.dispatchFromScope(CommandScope.details, id),
    );
  }

  /// Last resort for a draft that could not be persisted locally: hand the
  /// user the exact text they would lose (spec.md section 7).
  Future<void> _copyDraft() async {
    final editor = _editor;
    final base = editor.base;
    final draft = editor.draft;
    if (!editor.isEditing || draft == null) {
      widget.api.announce('Open a draft before copying it.', dynamic: true);
      return;
    }
    final lines = <String>[
      '${base?.canonicalId ?? 'Task'} (base version ${base?.version ?? 0})',
      for (final field in EditorField.values)
        '${field.wireName}: ${draft.textOf(field)}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    widget.api.announce('Draft copied to the clipboard.', dynamic: true);
  }

  /// Mark done needs a selected task that is not done and no write in flight
  /// (spec.md section 7, "Mark done").
  bool get _markDoneEnabled {
    final editor = _editor;
    final base = editor.base;
    return base != null && base.status != 'done' && !editor.isSaving;
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
    final markDoneHint = detail.status == 'done'
        ? null
        : viewerMarkDoneHint(detail.dependencySummaries);
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
          // The form owns Save and Cancel, so the read-mode actions go away
          // while it is open instead of offering a second way to write.
          if (!_editor.isEditing)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Tooltip(
                  message: 'F4',
                  child: TextButton(
                    focusNode: _editActionFocus,
                    onPressed: () => unawaited(beginEdit()),
                    child: const Text('Edit'),
                  ),
                ),
                Tooltip(
                  message: 'Ctrl+D',
                  // One Wrap child: the button and its hint stay together, so
                  // wrapping never separates the hint from Mark done or
                  // attaches it to a neighboring button instead.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      TextButton(
                        focusNode: _markDoneActionFocus,
                        onPressed: _markDoneEnabled
                            ? () => unawaited(_markDone(fromHeader: true))
                            : null,
                        // The button stays enabled: the CLI is the authority
                        // and explains a refusal if the loaded list is stale.
                        // Windows' bridge omits Semantics.hint, so put the
                        // prerequisite text in the native accessible name.
                        child: Semantics(
                          label: markDoneHint == null
                              ? 'Mark done'
                              : 'Mark done. $markDoneHint',
                          excludeSemantics: true,
                          child: const Text('Mark done'),
                        ),
                      ),
                      // Visible twin of the button's description; excluded so
                      // a screen reader does not hear it twice.
                      if (markDoneHint != null)
                        ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12, bottom: 4),
                            child: Text(
                              markDoneHint,
                              key: const ValueKey<String>(
                                'details-mark-done-hint',
                              ),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ),
                    ],
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
      container: true,
      explicitChildNodes: true,
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
            const ViewerRule(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: _StoredBodyCopy(
                  body: _bodyText,
                  controller: _body,
                  child: _buildReadOnlyText(
                    key: const ValueKey<String>('details-body'),
                    controller: _body,
                    focusNode: _handles.bodyFocus,
                    label: 'Task body (F3)',
                    expands: true,
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
    bool expands = false,
    String? hint,
    Key? key,
  }) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      readOnly: true,
      maxLines: null,
      expands: expands,
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

  /// True while the open task itself is done or cancelled: no dependency
  /// row of it reads as waiting, whatever its prerequisites' statuses are.
  bool _dependentIsTerminal(TaskDetailController state) =>
      viewerStatusIsTerminal(state.detail?.status ?? '');

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
        label: viewerDependencyRowLabel(
          dependencies[index],
          dependentIsTerminal: _dependentIsTerminal(state),
        ),
        value: viewerRowPosition(index, dependencies.length),
      ),
      onActivate: _openDependencyAt,
      rowBuilder: (context, index, selected) => _DependencyRowTile(
        dependency: dependencies[index],
        selected: selected,
        dependentIsTerminal: _dependentIsTerminal(state),
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
            const ViewerRule(),
            ViewerPaneRegion(
              maxHeight: budget.footer,
              child: _buildHistoryFooter(context, state),
            ),
            const ViewerRule(),
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
        const ViewerRule(),
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
  const _DependencyRowTile({
    required this.dependency,
    required this.selected,
    required this.dependentIsTerminal,
  });

  final DependencySummary dependency;
  final bool selected;
  final bool dependentIsTerminal;

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
            viewerDependencyReadinessText(
              dependency,
              dependentIsTerminal: dependentIsTerminal,
            ),
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
          Text(
            event.attribution?.summary.isNotEmpty == true
                ? '$when. ${event.attribution!.summary}'
                : when,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Ctrl+C inside the body reader.
class _CopyStoredBodyIntent extends Intent {
  const _CopyStoredBodyIntent();
}

/// Copies the selected stored body text, or the whole body without a selection.
///
/// The reader lays out [ViewerBodyText.display], whose carriage returns are
/// gone; a copy must still hand over the store's own characters, CRLF included
/// (viewer/spec.md section 6 with the root spec's line-ending preservation).
/// With a selection Ctrl+C copies that range; with only a caret it copies the
/// whole body. Every other text-editing key stays with the control.
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
    final text = !selection.isValid || selection.isCollapsed
        ? body.stored
        : body.storedRange(selection.start, selection.end);
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }
}
