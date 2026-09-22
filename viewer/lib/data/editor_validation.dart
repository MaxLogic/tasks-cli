/// Draft-side validation for the six editable task fields (viewer/spec.md
/// section 7).
///
/// The store stays authoritative. This validator reproduces the documented
/// limits and the per-field messages the form shows before a save is even
/// attempted, so an obviously invalid draft never reaches the CLI. Anything
/// that needs the dependency graph (unknown IDs, cycles) remains a store
/// rejection and is displayed unchanged.
library;

import 'dart:convert';

import 'editor_models.dart';
import 'models.dart';

/// Title limit in Unicode scalar values (spec section 7).
const int viewerTitleMaxScalars = 500;

/// Body limit in UTF-8 bytes (spec section 7).
const int viewerBodyMaxUtf8Bytes = 1048576;

/// Label limits (spec section 7).
const int viewerLabelsMaxCount = 32;
const int viewerLabelMaxChars = 64;

/// Pattern every normalized label must match (spec section 7).
final RegExp viewerLabelAllowedPattern = RegExp(r'^[a-z0-9\-_.:]+$');

/// Dependency limit (spec section 7).
const int viewerDepsMaxCount = 1000;

/// The outcome of validating one editor draft.
///
/// [normalizedLabels] and [normalizedDeps] are exactly the values a save would
/// send, so the controller can reuse them for the request and for the
/// lost-acknowledgement comparison.
final class EditorFieldValidation {
  const EditorFieldValidation({
    required this.errors,
    required this.normalizedLabels,
    required this.normalizedDeps,
  });

  /// One actionable message per invalid field, in form order.
  final Map<EditorField, String> errors;

  /// Labels as `viewer update` would send them.
  final List<String> normalizedLabels;

  /// Dependency IDs as `viewer update` would send them.
  final List<int> normalizedDeps;

  bool get isValid => errors.isEmpty;

  /// Single-line summary for the Save announcement, or null when valid.
  ///
  /// One `; `-separated segment per invalid field, so the status area and the
  /// screen reader hear each problem exactly once.
  String? get summary => errors.isEmpty ? null : errors.values.join('; ');

  /// The first invalid field in form order, for focus recovery on Save.
  EditorField? get firstInvalidField =>
      errors.isEmpty ? null : errors.keys.first;
}

/// Validates [fields] and derives the normalized values a save would send.
///
/// [taskId] enables the self-dependency check; the form always knows it.
/// [limits] lets the caller use the values `viewer info` reported instead of
/// the compiled-in defaults.
EditorFieldValidation validateEditorFields(
  TaskEditFields fields, {
  int? taskId,
  ViewerEditableFieldLimits? limits,
}) {
  final titleMax = limits?.titleMaxChars ?? viewerTitleMaxScalars;
  final bodyMaxBytes = limits?.bodyMaxUtf8Bytes ?? viewerBodyMaxUtf8Bytes;
  final statusValues = limits?.statusValues ?? viewerTaskStatuses;
  final priorityValues = limits?.priorityValues ?? viewerTaskPriorities;
  final labelsMaxCount = limits?.labelsMaxCount ?? viewerLabelsMaxCount;
  final labelMaxChars = limits?.labelsItemMaxChars ?? viewerLabelMaxChars;
  final depsMaxCount = limits?.depsMaxCount ?? viewerDepsMaxCount;

  final errors = <EditorField, String>{};

  final titleLength = fields.title.runes.length;
  if (titleLength == 0) {
    errors[EditorField.title] =
        'Title: the title is empty. Provide a non-empty title.';
  } else if (titleLength > titleMax) {
    errors[EditorField.title] =
        'Title: the title has $titleLength characters. The limit is $titleMax '
        'characters. Shorten the title.';
  }

  if (!statusValues.contains(fields.status)) {
    errors[EditorField.status] =
        'Status: "${fields.status}" is not one of ${statusValues.join(', ')}.';
  }

  if (!priorityValues.contains(fields.priority)) {
    errors[EditorField.priority] =
        'Priority: "${fields.priority}" is not one of '
        '${priorityValues.join(', ')}.';
  }

  final normalizedLabels = normalizeEditorLabelsText(fields.labelsText);
  final labelProblems = <String>[];
  if (normalizedLabels.length > labelsMaxCount) {
    labelProblems.add(
      'there are ${normalizedLabels.length} labels. The limit is '
      '$labelsMaxCount.',
    );
  }
  for (final raw in fields.labelsText.split(',')) {
    final typed = raw.trim();
    if (typed.isEmpty) {
      continue;
    }
    final label = typed.toLowerCase();
    if (label.length > labelMaxChars) {
      labelProblems.add(
        '"$typed" has ${label.length} characters. The limit is '
        '$labelMaxChars.',
      );
    } else if (!viewerLabelAllowedPattern.hasMatch(label)) {
      labelProblems.add(
        '"$typed" uses characters outside the allowed set: letters, digits, '
        '- _ . :',
      );
    }
  }
  if (labelProblems.isNotEmpty) {
    errors[EditorField.labels] = 'Labels: ${labelProblems.join(' ')}';
  }

  final deps = parseEditorDependencyText(fields.depsText);
  final depProblems = <String>[];
  for (final error in deps.errors) {
    depProblems.add('"${error.token}" is not a task ID like T-042.');
  }
  if (taskId != null && deps.ids.contains(taskId)) {
    depProblems.add(
      'the task cannot depend on itself (${viewerCanonicalTaskId(taskId)}).',
    );
  }
  if (deps.ids.length > depsMaxCount) {
    depProblems.add(
      'there are ${deps.ids.length} dependencies. The limit is $depsMaxCount.',
    );
  }
  if (depProblems.isNotEmpty) {
    errors[EditorField.deps] = 'Dependencies: ${depProblems.join(' ')}';
  }

  final bodyBytes = utf8.encode(fields.body).length;
  if (bodyBytes > bodyMaxBytes) {
    errors[EditorField.body] =
        'Body: the body has $bodyBytes bytes. The limit is $bodyMaxBytes '
        'bytes. Trim the body.';
  }

  return EditorFieldValidation(
    errors: Map<EditorField, String>.unmodifiable(errors),
    normalizedLabels: normalizedLabels,
    normalizedDeps: deps.ids,
  );
}
