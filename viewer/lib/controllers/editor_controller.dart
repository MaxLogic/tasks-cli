/// The one open task editor: draft text, validation, version-checked saves,
/// conflict reconciliation and recovery drafts (viewer/spec.md section 7,
/// viewer/design.md sections 7 and 8).
///
/// The store stays authoritative. This controller never invents a field value
/// the store would reject, never retries a mutation on its own, and never
/// throws a draft away because a write failed. It owns no [BuildContext]: the
/// details pane renders this state and owns the dialogs.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/editor_models.dart';
import '../data/editor_validation.dart';
import '../data/models.dart';
import '../data/settings_store.dart';

/// How long a changed draft may sit before it reaches the recovery index
/// (viewer/spec.md section 7: write after 500 ms idle).
const Duration editorDraftAutosaveDelay = Duration(milliseconds: 500);

/// How one save attempt ended.
enum EditorSaveOutcome {
  /// The store committed the update and created an event.
  saved,

  /// The store created no event because nothing actually changed.
  noop,

  /// Reconciliation found the intended values already stored: the write landed
  /// and only its acknowledgement was lost.
  reconciled,

  /// Reconciliation proved this write never applied. The draft is untouched
  /// and Save is a working Retry again.
  unsaved,

  /// Draft-side validation refused to send the request.
  invalid,

  /// The store rejected the version; the conflict workflow is open.
  conflict,

  /// A clean failure: nothing was written and [EditorSaveResult.message] says
  /// why. The draft is untouched.
  failed,
}

/// Why a leaving action is asking about the draft.
enum EditorLeaveReason {
  taskSwitch,
  projectSwitch,
  leaveEditMode,
  storeChange,
  windowClose,
}

/// One-line question each guard shows above Save / Discard / Cancel.
String editorLeaveQuestion(EditorLeaveReason reason) => switch (reason) {
  EditorLeaveReason.taskSwitch =>
    'Switch to another task and lose the changes to this one?',
  EditorLeaveReason.projectSwitch =>
    'Switch to another project and lose the changes to this task?',
  EditorLeaveReason.leaveEditMode => 'Leave the editor and lose your changes?',
  EditorLeaveReason.storeChange =>
    'Change the task store and lose the changes to this task?',
  EditorLeaveReason.windowClose =>
    'Close the viewer and lose the changes to this task?',
};

/// Per-field decision in the "Review against current" workflow.
enum EditorConflictChoice { mine, current }

/// One open version conflict: what the draft was based on, what the draft
/// holds, and what the store holds now.
final class EditorConflict {
  const EditorConflict({
    required this.baseVersion,
    required this.baseFields,
    required this.draftFields,
    required this.current,
    required this.changedFields,
    required this.conflictFields,
    this.choices = const <EditorField, EditorConflictChoice>{},
  });

  /// Version the draft was based on.
  final int baseVersion;

  /// Canonical field values at [baseVersion].
  final TaskEditFields baseFields;

  /// The user's draft.
  final TaskEditFields draftFields;

  /// The freshly read record, at its own version.
  final TaskDetail current;

  /// Fields that differ between base and draft, or base and current.
  final List<EditorField> changedFields;

  /// Fields the user changed *and* another writer changed: these need a Mine
  /// or Current choice before the draft can be rebased.
  final List<EditorField> conflictFields;

  /// Choices made so far in the review dialog.
  final Map<EditorField, EditorConflictChoice> choices;

  /// Current record as editor text.
  TaskEditFields get currentFields => TaskEditFields.fromDetail(current);

  int get currentVersion => current.version;

  bool get hasConflicts => conflictFields.isNotEmpty;

  bool get isResolved =>
      conflictFields.every((field) => choices.containsKey(field));

  EditorConflict withChoice(EditorField field, EditorConflictChoice choice) =>
      EditorConflict(
        baseVersion: baseVersion,
        baseFields: baseFields,
        draftFields: draftFields,
        current: current,
        changedFields: changedFields,
        conflictFields: conflictFields,
        choices: <EditorField, EditorConflictChoice>{...choices, field: choice},
      );

  /// Drops a choice for a field the user edited after the conflict was found.
  EditorConflict withDraft(TaskEditFields value) => EditorConflict(
    baseVersion: baseVersion,
    baseFields: baseFields,
    draftFields: value,
    current: current,
    changedFields: changedFields,
    conflictFields: conflictFields,
    choices: <EditorField, EditorConflictChoice>{
      for (final entry in choices.entries)
        if (value.textOf(entry.key) == draftFields.textOf(entry.key))
          entry.key: entry.value,
    },
  );
}

/// The outcome of one save, Mark done or reconciliation attempt.
final class EditorSaveResult {
  const EditorSaveResult(
    this.outcome, {
    this.message,
    this.version,
    this.eventId,
    this.conflict,
  });

  final EditorSaveOutcome outcome;

  /// Ready-to-show status text; never contains the task body.
  final String? message;

  /// Resulting store version when the store confirmed one.
  final int? version;

  /// History event the store created, if any.
  final int? eventId;

  /// Open conflict, for [EditorSaveOutcome.conflict].
  final EditorConflict? conflict;

  bool get isSuccess =>
      outcome == EditorSaveOutcome.saved ||
      outcome == EditorSaveOutcome.noop ||
      outcome == EditorSaveOutcome.reconciled;
}

/// Editor state for the one task the user is editing.
class ViewerEditorController extends ChangeNotifier {
  ViewerEditorController({
    TaskUpdateWriter? writer,
    TaskDetailReader? detailReader,
    RecoveryDraftSink? drafts,
    String? dataRoot,
    Duration autosaveDelay = editorDraftAutosaveDelay,
    DateTime Function()? clock,
  }) : // Private fields cannot be named parameters, so the lint cannot apply.
       // ignore: prefer_initializing_formals
       _writer = writer,
       // ignore: prefer_initializing_formals
       _detailReader = detailReader,
       // ignore: prefer_initializing_formals
       _drafts = drafts,
       // ignore: prefer_initializing_formals
       _dataRoot = dataRoot,
       // ignore: prefer_initializing_formals
       _autosaveDelay = autosaveDelay,
       _clock = clock ?? DateTime.now;

  final TaskUpdateWriter? _writer;
  final TaskDetailReader? _detailReader;
  final RecoveryDraftSink? _drafts;
  final Duration _autosaveDelay;
  final DateTime Function() _clock;

  String? _dataRoot;
  String? _projectId;
  int? _taskId;
  TaskDetail? _base;
  TaskEditFields? _baseFields;
  TaskEditFields? _draft;
  bool _editing = false;
  bool _saving = false;
  bool _awaitingReconciliation = false;
  EditorConflict? _conflict;
  Map<EditorField, String> _errors = const <EditorField, String>{};
  String? _persistenceWarning;
  Timer? _autosaveTimer;
  bool _disposed = false;

  TaskEditFields? _intendedFields;
  EditorFieldChanges? _intendedChanges;

  List<ViewerRecoveryDraft> _recoveryDrafts = const <ViewerRecoveryDraft>[];
  String? _recoveryWarning;

  // --------------------------------------------------------------- identity

  /// Project the editor is bound to, or null when nothing is selected.
  String? get projectId => _projectId;

  /// Selected task, or null.
  int? get taskId => _taskId;

  /// Canonical form of [taskId].
  String? get canonicalTaskId =>
      _taskId == null ? null : viewerCanonicalTaskId(_taskId!, _projectKey);

  /// Key of the project the confirmed record belongs to, if it has one.
  String? get projectKey => _base?.projectKey;

  String? get _projectKey => projectKey;

  /// Confirmed record the draft is based on.
  TaskDetail? get base => _base;

  /// Canonical text of the confirmed record.
  TaskEditFields? get baseFields => _baseFields;

  /// Current form text, or null while the editor is closed.
  TaskEditFields? get draft => _draft;

  bool get isEditing => _editing;

  bool get isDirty {
    final base = _baseFields;
    final draft = _draft;
    if (base == null || draft == null || !_editing) {
      return false;
    }
    return EditorFieldChanges.between(
      base,
      draft,
      projectKey: _projectKey,
    ).isNotEmpty;
  }

  /// Fields a save would send, normalized.
  EditorFieldChanges get changes {
    final base = _baseFields;
    final draft = _draft;
    if (base == null || draft == null) {
      return const EditorFieldChanges();
    }
    return EditorFieldChanges.between(base, draft, projectKey: _projectKey);
  }

  bool get isSaving => _saving;

  /// True while a write may have landed without a usable answer.
  bool get isAwaitingReconciliation => _awaitingReconciliation;

  EditorConflict? get conflict => _conflict;

  /// Per-field validation messages currently shown in the form.
  Map<EditorField, String> get errors => _errors;

  bool get hasErrors => _errors.isNotEmpty;

  /// The first invalid field in form order, for focus recovery on Save.
  EditorField? get firstInvalidField {
    for (final field in EditorField.values) {
      if (_errors.containsKey(field)) {
        return field;
      }
    }
    return null;
  }

  /// Save is enabled only for a changed, valid-enough, idle, reconciled form.
  bool get saveEnabled =>
      _editing && isDirty && !_saving && !_awaitingReconciliation;

  /// Persistent warning about draft persistence, or null.
  String? get persistenceWarning => _persistenceWarning;

  /// Recovery drafts kept on disk for this store.
  List<ViewerRecoveryDraft> get recoveryDrafts =>
      List<ViewerRecoveryDraft>.unmodifiable(_recoveryDrafts);

  /// Warning raised while the recovery index was read.
  String? get recoveryWarning => _recoveryWarning;

  /// True when the editor can write at all in this build.
  bool get canWrite => _writer != null;

  // ---------------------------------------------------------------- binding

  /// Points the editor at one store identity; drops state from another store.
  void bindStore(String? dataRoot) {
    final previous = _dataRoot;
    _dataRoot = dataRoot;
    if (previous == dataRoot) {
      return;
    }
    _recoveryDrafts = const <ViewerRecoveryDraft>[];
    if (_editing) {
      // The leaving guard asked the user before the store changed, so a switch
      // that happens anyway must not carry a draft into another store.
      _closeEditor();
    }
    _notify();
  }

  /// Mirrors the confirmed record into [base] while the editor is closed.
  ///
  /// A refresh that lands while the user is editing never overwrites the
  /// draft: an intervening write has to become a conflict on Save instead.
  void observeDetail(TaskDetail? detail, {String? projectId}) {
    if (_editing) {
      return;
    }
    final nextProject = projectId ?? _projectId;
    if (detail == null) {
      if (_base == null && _projectId == nextProject) {
        return;
      }
      _projectId = nextProject;
      if (nextProject == null) {
        _taskId = null;
      }
      _base = null;
      _baseFields = null;
      _draft = null;
      _conflict = null;
      _errors = const <EditorField, String>{};
      _awaitingReconciliation = false;
      _notify();
      return;
    }
    _projectId = nextProject;
    _taskId = detail.id;
    _base = detail;
    _baseFields = TaskEditFields.fromDetail(detail);
    _draft = null;
    _conflict = null;
    _awaitingReconciliation = false;
    _notify();
  }

  /// Opens the editor on the confirmed record with no changes yet.
  void beginEdit() {
    final base = _base;
    final fields = _baseFields;
    if (base == null || fields == null) {
      return;
    }
    _editing = true;
    _draft = fields;
    _conflict = null;
    _errors = const <EditorField, String>{};
    _awaitingReconciliation = false;
    _notify();
  }

  /// Opens the editor with a recovered draft (viewer/spec.md section 7).
  ///
  /// [baseFields] is the base the draft was written against; [current] is the
  /// freshly read record. A version difference opens the conflict workflow
  /// instead of pretending the draft is still based on the current record.
  void restoreDraft({
    required String projectId,
    required TaskDetail current,
    required TaskEditFields baseFields,
    required int baseVersion,
    required TaskEditFields draftFields,
  }) {
    _projectId = projectId;
    _taskId = current.id;
    _editing = true;
    _errors = const <EditorField, String>{};
    _awaitingReconciliation = false;
    _base = current;
    if (current.version == baseVersion) {
      _baseFields = TaskEditFields.fromDetail(current);
      _draft = draftFields;
      _conflict = null;
    } else {
      _baseFields = baseFields;
      _draft = draftFields;
      // The conflict reports the version the draft was written against, not
      // the fresh one it is compared with (spec.md section 7).
      _conflict = _buildConflict(current, draftBaseVersion: baseVersion);
    }
    _notify();
  }

  /// One changed field from the form.
  void setField(EditorField field, String value) {
    final draft = _draft;
    if (!_editing || draft == null) {
      return;
    }
    _draft = draft.withText(field, value);
    _errors = <EditorField, String>{
      for (final entry in _errors.entries)
        if (entry.key != field) entry.key: entry.value,
    };
    _conflict = _conflict?.withDraft(_draft!);
    _notify();
    _scheduleAutosave();
  }

  /// Validates one field: blur feedback and the first-invalid focus on Save.
  void validateField(EditorField field) {
    final fields = _draft;
    if (fields == null) {
      return;
    }
    final message = validateEditorFields(
      fields,
      taskId: _taskId,
      projectKey: _projectKey,
    ).errors[field];
    final next = Map<EditorField, String>.of(_errors);
    if (message == null) {
      next.remove(field);
    } else {
      next[field] = message;
    }
    if (mapEquals(next, _errors)) {
      return;
    }
    _errors = next;
    _notify();
  }

  /// Closes the editor. The caller owns the guard; this only drops the draft.
  void exitEdit() {
    if (!_editing) {
      return;
    }
    _closeEditor();
    _notify();
  }

  /// Drops the draft without touching the store: the leaving guard's Discard.
  ///
  /// The caller has already asked the user, so the persisted copy goes too;
  /// a failed delete leaves [persistenceWarning] behind instead of pretending
  /// the draft is gone.
  Future<void> discardDraft() async {
    if (!_editing) {
      return;
    }
    await _deleteDraft();
    _closeEditor();
    _notify();
  }

  void _closeEditor() {
    _editing = false;
    _draft = null;
    _conflict = null;
    _errors = const <EditorField, String>{};
    _awaitingReconciliation = false;
    _intendedFields = null;
    _intendedChanges = null;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
  }

  // -------------------------------------------------------- recovery drafts

  /// Reads the recovery index for this store.
  ///
  /// A damaged entry is skipped by the store; only an unreadable index raises
  /// [recoveryWarning], and a failure never blocks the editor.
  Future<void> loadRecoveryDrafts() async {
    final sink = _drafts;
    if (sink == null) {
      return;
    }
    try {
      _recoveryDrafts = await sink.loadAll();
      _recoveryWarning = null;
    } on Object catch (error) {
      _recoveryDrafts = const <ViewerRecoveryDraft>[];
      _recoveryWarning = 'Recovery drafts could not be read: $error';
    }
    _notify();
  }

  /// Drafts that belong to the store this window reads.
  List<ViewerRecoveryDraft> get pendingDrafts {
    final root = _dataRoot;
    if (root == null) {
      return const <ViewerRecoveryDraft>[];
    }
    final slug = recoveryDraftSlug(root);
    return <ViewerRecoveryDraft>[
      for (final draft in _recoveryDrafts)
        if (recoveryDraftSlug(draft.dataRoot) == slug) draft,
    ];
  }

  /// Identity of the draft the open editor owns, or null without one.
  String? get currentDraftId {
    final root = _dataRoot;
    final project = _projectId;
    final task = _taskId;
    if (root == null || project == null || task == null) {
      return null;
    }
    return viewerRecoveryDraftId(
      dataRoot: root,
      projectId: project,
      taskId: viewerCanonicalTaskId(task),
    );
  }

  /// Forgets one recovered draft once the user chose Restore or Discard.
  void settleRecoveryDraft(ViewerRecoveryDraft draft) {
    final next = <ViewerRecoveryDraft>[
      for (final existing in _recoveryDrafts)
        if (existing.draftId != draft.draftId) existing,
    ];
    if (next.length == _recoveryDrafts.length) {
      return;
    }
    _recoveryDrafts = next;
    _notify();
  }

  /// Deletes one recovered draft from disk without opening it.
  Future<void> discardRecoveryDraft(ViewerRecoveryDraft draft) async {
    settleRecoveryDraft(draft);
    final sink = _drafts;
    if (sink == null) {
      return;
    }
    try {
      await sink.delete(draft.draftId);
    } on Object catch (error) {
      _persistenceWarning = 'The recovery draft was not removed: $error';
      _notify();
    }
  }

  /// Writes the draft now: before a navigation, a guard and a close.
  ///
  /// Keystrokes typed after this call are the only ones a crash can lose, which
  /// is what the status text promises.
  Future<void> flushDraft() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    return _persistDraft();
  }

  void _scheduleAutosave() {
    if (_drafts == null) {
      return;
    }
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDelay, () {
      _autosaveTimer = null;
      unawaited(_persistDraft());
    });
  }

  Future<void> _persistDraft() async {
    final sink = _drafts;
    if (sink == null || !_editing) {
      return;
    }
    final base = _baseFields;
    final record = _base;
    final draft = _draft;
    final id = currentDraftId;
    if (base == null || record == null || draft == null || id == null) {
      return;
    }
    try {
      if (!isDirty) {
        // An editor that matches the store has nothing to recover, so a
        // restart must not offer this task a draft.
        await sink.delete(id);
      } else {
        await sink.save(
          ViewerRecoveryDraft(
            dataRoot: _dataRoot!,
            projectId: _projectId!,
            taskId: viewerCanonicalTaskId(_taskId!),
            baseVersion: record.version,
            baseFields: base.toJson(),
            draftFields: draft.toJson(),
            updatedMs: _clock().millisecondsSinceEpoch,
          ),
        );
      }
      if (_persistenceWarning != null) {
        _persistenceWarning = null;
        _notify();
      }
    } on Object catch (error) {
      final warning =
          'Your draft could not be saved for recovery: $error. '
          'Copy it before closing the viewer.';
      if (_persistenceWarning != warning) {
        _persistenceWarning = warning;
        _notify();
      }
    }
  }

  Future<void> _deleteDraft() async {
    final sink = _drafts;
    final id = currentDraftId;
    if (sink == null || id == null) {
      return;
    }
    try {
      await sink.delete(id);
    } on Object catch (error) {
      _persistenceWarning = 'The recovery draft was not removed: $error';
      _notify();
    }
  }

  // ----------------------------------------------------------------- saves

  /// Save/Ctrl+S: one version-checked update for every changed field.
  Future<EditorSaveResult> save() async {
    final base = _base;
    final baseFields = _baseFields;
    final draft = _draft;
    if (!_editing || base == null || baseFields == null || draft == null) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message: 'Open a task editor before saving.',
      );
    }
    final conflict = _conflict;
    if (conflict != null) {
      return EditorSaveResult(
        EditorSaveOutcome.conflict,
        message:
            '${conflict.current.canonicalId} changed in the store. Resolve the '
            'conflict before saving.',
        conflict: conflict,
      );
    }
    if (_awaitingReconciliation) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message:
            'The previous save outcome is still unknown. Reconcile it before '
            'saving again.',
      );
    }
    final validation = _validateAll();
    if (!validation.isValid) {
      return EditorSaveResult(
        EditorSaveOutcome.invalid,
        message: validation.summary,
      );
    }
    final changes = EditorFieldChanges.between(
      baseFields,
      draft,
      projectKey: _projectKey,
    );
    if (changes.isEmpty) {
      return EditorSaveResult(
        EditorSaveOutcome.noop,
        message: 'No changes needed',
        version: base.version,
      );
    }
    return _write(
      changes: changes,
      intended: _applyChanges(baseFields, changes),
      statusText: (result) =>
          'Saved ${base.canonicalId}, version ${result.version}',
    );
  }

  /// Ctrl+D (viewer/spec.md section 7, "Mark done").
  ///
  /// [includeDraft] sends the draft's other changed fields together with
  /// `status: done` in one update; without it only `status: done` travels and
  /// the draft survives until the store confirms.
  Future<EditorSaveResult> markDone({bool includeDraft = false}) async {
    final base = _base;
    final baseFields = _baseFields;
    if (base == null || baseFields == null) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message: 'Select a task before marking it done.',
      );
    }
    if (base.status == 'done') {
      return EditorSaveResult(
        EditorSaveOutcome.noop,
        message: '${base.canonicalId} is already done.',
        version: base.version,
      );
    }
    final conflict = _conflict;
    if (conflict != null) {
      return EditorSaveResult(
        EditorSaveOutcome.conflict,
        message:
            '${conflict.current.canonicalId} changed in the store. Resolve the '
            'conflict before marking it done.',
        conflict: conflict,
      );
    }
    if (_awaitingReconciliation) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message:
            'The previous save outcome is still unknown. Reconcile it before '
            'writing again.',
      );
    }
    EditorFieldChanges changes = const EditorFieldChanges(status: 'done');
    if (includeDraft && _editing && _draft != null) {
      final validation = _validateAll();
      if (!validation.isValid) {
        return EditorSaveResult(
          EditorSaveOutcome.invalid,
          message: validation.summary,
        );
      }
      changes = EditorFieldChanges.between(
        baseFields,
        _draft!,
        projectKey: _projectKey,
      ).copyWith(status: 'done');
    }
    return _write(
      changes: changes,
      intended: _applyChanges(baseFields, changes),
      statusText: (result) =>
          '${base.canonicalId} is done, version ${result.version}',
    );
  }

  /// Adopts the store's values and drops the draft: the conflict dialog's
  /// "Reload current and discard draft".
  Future<void> reloadCurrentAndDiscardDraft() async {
    final conflict = _conflict;
    if (conflict == null) {
      return;
    }
    final currentFields = conflict.currentFields;
    _base = conflict.current;
    _baseFields = currentFields;
    _draft = currentFields;
    _conflict = null;
    _errors = const <EditorField, String>{};
    _awaitingReconciliation = false;
    _notify();
    await _deleteDraft();
  }

  /// Applies per-field Mine/Current choices and rebases the draft.
  ///
  /// Fields the user did not touch always adopt the current value, and nothing
  /// is saved here: the next Save uses the freshly read version.
  void applyConflictReview(Map<EditorField, EditorConflictChoice> choices) {
    final conflict = _conflict;
    final draft = _draft;
    if (conflict == null || draft == null) {
      return;
    }
    final currentFields = conflict.currentFields;
    var next = draft;
    for (final field in EditorField.values) {
      final userChanged = _differs(
        conflict.baseFields,
        draft,
        field,
        _projectKey,
      );
      final currentChanged = _differs(
        conflict.baseFields,
        currentFields,
        field,
        _projectKey,
      );
      final choice = choices[field] ?? conflict.choices[field];
      if (!userChanged) {
        next = next.withText(field, currentFields.textOf(field));
      } else if (currentChanged && choice != EditorConflictChoice.mine) {
        next = next.withText(field, currentFields.textOf(field));
      }
    }
    _base = conflict.current;
    _baseFields = currentFields;
    _draft = next;
    _conflict = null;
    _notify();
  }

  /// Retries the `show` reconciliation after an unknown save outcome.
  Future<EditorSaveResult> retryReconciliation() async {
    final intended = _intendedFields;
    final changes = _intendedChanges;
    if (!_awaitingReconciliation || intended == null || changes == null) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message: 'There is no unresolved save to reconcile.',
      );
    }
    return _reconcile(intended, changes);
  }

  /// The single write path: one request, then the documented outcome rules.
  Future<EditorSaveResult> _write({
    required EditorFieldChanges changes,
    required TaskEditFields intended,
    required String Function(ViewerUpdateResult result) statusText,
  }) async {
    final writer = _writer;
    final base = _base;
    final projectId = _projectId;
    final taskId = _taskId;
    if (writer == null || base == null || projectId == null || taskId == null) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message:
            'No tasks CLI is available, so nothing was written. Choose the '
            'executable in Settings.',
      );
    }
    _saving = true;
    _notify();
    try {
      final result = await writer.updateTask(
        projectId,
        ViewerUpdateRequest(
          id: taskId,
          expectVersion: base.version,
          changes: changes,
        ),
      );
      _saving = false;
      if (result.isNoop) {
        // The store created no event, so there is nothing left to save.
        _closeEditor();
        await _deleteDraft();
        _notify();
        return EditorSaveResult(
          EditorSaveOutcome.noop,
          message: 'No changes needed',
          version: result.version,
        );
      }
      _closeEditor();
      await _deleteDraft();
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.saved,
        message: statusText(result),
        version: result.version,
        eventId: result.eventId,
      );
    } on ViewerCancelledFailure {
      _saving = false;
      _notify();
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message: 'The save was superseded by another read; nothing was sent.',
      );
    } on ViewerCliErrorFailure catch (failure) {
      _saving = false;
      if (failure.code == 'version_conflict') {
        return _enterConflict(failure.message);
      }
      if (failure.openPrerequisites.isNotEmpty) {
        // The completion guard refused `done` before writing anything, so the
        // draft and the editor stay exactly as they were.
        _notify();
        return EditorSaveResult(
          EditorSaveOutcome.failed,
          message: viewerOpenPrerequisitesMessage(
            base.canonicalId,
            failure.openPrerequisites,
          ),
        );
      }
      if (failure.code == 'unparsed_error') {
        // The process ran and exited without a usable answer: the write may or
        // may not have committed, so this is an unknown outcome, not a failure.
        return _outcomeUnknown(
          "The tasks CLI exited without a usable answer: ${failure.message}",
          intended,
          changes,
        );
      }
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.failed,
        message: failure.message,
      );
    } on ViewerTimeoutFailure catch (failure) {
      _saving = false;
      return _outcomeUnknown(failure.message, intended, changes);
    } on ViewerMalformedResponseFailure catch (failure) {
      _saving = false;
      return _outcomeUnknown(failure.message, intended, changes);
    } on ViewerFailure catch (failure) {
      // Resolution, probe and size failures happen before any write, so they
      // are clean failures that leave the draft untouched.
      _saving = false;
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.failed,
        message: failure.message,
      );
    }
  }

  /// A write whose answer never arrived: hold the draft and reconcile.
  Future<EditorSaveResult> _outcomeUnknown(
    String message,
    TaskEditFields intended,
    EditorFieldChanges changes,
  ) async {
    _awaitingReconciliation = true;
    _intendedFields = intended;
    _intendedChanges = changes;
    _notify();
    final reconciled = await _reconcile(intended, changes);
    if (reconciled.outcome == EditorSaveOutcome.reconciled ||
        reconciled.outcome == EditorSaveOutcome.conflict ||
        reconciled.outcome == EditorSaveOutcome.unsaved) {
      return reconciled;
    }
    return EditorSaveResult(
      EditorSaveOutcome.failed,
      message:
          'The save outcome is unknown: $message. The draft is preserved and '
          'Save stays disabled until the task can be read again.',
    );
  }

  /// Reads the task again and decides what the lost write actually did.
  ///
  /// Reconciliation never mutates the store and never resends the update.
  Future<EditorSaveResult> _reconcile(
    TaskEditFields intended,
    EditorFieldChanges changes,
  ) async {
    final reader = _detailReader;
    final projectId = _projectId;
    final taskId = _taskId;
    if (reader == null || projectId == null || taskId == null) {
      return const EditorSaveResult(
        EditorSaveOutcome.failed,
        message:
            'The save outcome could not be checked: no reader is available.',
      );
    }
    final TaskDetail fresh;
    try {
      fresh = await reader.fetchTaskDetail(projectId, taskId);
    } on ViewerFailure catch (failure) {
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.failed,
        message: 'Could not read the task back: ${failure.message}',
      );
    }
    _awaitingReconciliation = false;
    _intendedFields = null;
    _intendedChanges = null;
    if (_matchesIntended(fresh, intended, changes)) {
      _base = fresh;
      _baseFields = TaskEditFields.fromDetail(fresh);
      _closeEditor();
      await _deleteDraft();
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.reconciled,
        message:
            'Current task matches your changes; the save acknowledgement was '
            'lost. ${fresh.canonicalId} is at version ${fresh.version}.',
        version: fresh.version,
      );
    }
    final baseVersion = _base?.version;
    if (baseVersion != null && fresh.version == baseVersion) {
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.unsaved,
        message:
            'The save did not reach the store. The draft is unchanged; Retry '
            'sends it again.',
        version: fresh.version,
      );
    }
    final conflict = _buildConflict(fresh);
    _conflict = conflict;
    _notify();
    return EditorSaveResult(
      EditorSaveOutcome.conflict,
      message: '${fresh.canonicalId} changed in the store since you opened it.',
      conflict: conflict,
    );
  }

  /// Reads the current record after a version conflict and opens the dialog
  /// state. The draft and the base values stay exactly as they were.
  Future<EditorSaveResult> _enterConflict(String message) async {
    final reader = _detailReader;
    final projectId = _projectId;
    final taskId = _taskId;
    if (reader == null || projectId == null || taskId == null) {
      _notify();
      return EditorSaveResult(EditorSaveOutcome.failed, message: message);
    }
    try {
      final fresh = await reader.fetchTaskDetail(projectId, taskId);
      final conflict = _buildConflict(fresh);
      _conflict = conflict;
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.conflict,
        message:
            '${fresh.canonicalId} is already at version ${fresh.version}. '
            'Your draft is kept.',
        conflict: conflict,
      );
    } on ViewerFailure catch (failure) {
      _notify();
      return EditorSaveResult(
        EditorSaveOutcome.failed,
        message:
            '${message.trim()} The current record could not be read: '
            '${failure.message}',
      );
    }
  }

  EditorConflict _buildConflict(TaskDetail current, {int? draftBaseVersion}) {
    final base = _baseFields!;
    final draft = _draft ?? base;
    final currentFields = TaskEditFields.fromDetail(current);
    final changed = <EditorField>[];
    final conflicting = <EditorField>[];
    for (final field in EditorField.values) {
      final userChanged = _differs(base, draft, field, _projectKey);
      final currentChanged = _differs(base, currentFields, field, _projectKey);
      if (userChanged || currentChanged) {
        changed.add(field);
      }
      if (userChanged && currentChanged) {
        conflicting.add(field);
      }
    }
    return EditorConflict(
      baseVersion: draftBaseVersion ?? _base?.version ?? current.version,
      baseFields: base,
      draftFields: draft,
      current: current,
      changedFields: List<EditorField>.unmodifiable(changed),
      conflictFields: List<EditorField>.unmodifiable(conflicting),
    );
  }

  EditorFieldValidation _validateAll() {
    final draft = _draft;
    if (draft == null) {
      return const EditorFieldValidation(
        errors: <EditorField, String>{},
        normalizedLabels: <String>[],
        normalizedDeps: <int>[],
      );
    }
    final result = validateEditorFields(
      draft,
      taskId: _taskId,
      projectKey: _projectKey,
    );
    _errors = result.errors;
    _notify();
    return result;
  }

  /// Applies [changes] to [fields] exactly the way the request would.
  TaskEditFields _applyChanges(
    TaskEditFields fields,
    EditorFieldChanges changes,
  ) {
    var next = fields;
    if (changes.title != null) {
      next = next.copyWith(title: changes.title);
    }
    if (changes.body != null) {
      next = next.copyWith(body: changes.body);
    }
    if (changes.status != null) {
      next = next.copyWith(status: changes.status);
    }
    if (changes.priority != null) {
      next = next.copyWith(priority: changes.priority);
    }
    if (changes.labels != null) {
      next = next.copyWith(labelsText: changes.labels!.join(', '));
    }
    if (changes.deps != null) {
      next = next.copyWith(
        depsText: changes.deps!
            .map((id) => viewerCanonicalTaskId(id, _projectKey))
            .join(', '),
      );
    }
    return next;
  }

  /// True when [fresh] already holds every value the lost write intended.
  bool _matchesIntended(
    TaskDetail fresh,
    TaskEditFields intended,
    EditorFieldChanges changes,
  ) {
    if (changes.title != null && fresh.title != intended.title) {
      return false;
    }
    if (changes.body != null && fresh.body != intended.body) {
      return false;
    }
    if (changes.status != null && fresh.status != intended.status) {
      return false;
    }
    if (changes.priority != null && fresh.priority != intended.priority) {
      return false;
    }
    if (changes.labels != null) {
      final stored = <String>[...fresh.labels]..sort();
      final wanted = <String>[...normalizeEditorLabelsText(intended.labelsText)]
        ..sort();
      if (!listEquals(stored, wanted)) {
        return false;
      }
    }
    if (changes.deps != null) {
      final stored = fresh.deps.toSet();
      final wanted = parseEditorDependencyText(intended.depsText).ids.toSet();
      if (stored.length != wanted.length || !stored.containsAll(wanted)) {
        return false;
      }
    }
    return true;
  }

  static bool _differs(
    TaskEditFields base,
    TaskEditFields other,
    EditorField field,
    String? projectKey,
  ) => EditorFieldChanges.between(
    base,
    other,
    projectKey: projectKey,
  ).fields.contains(field);

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    super.dispose();
  }
}
