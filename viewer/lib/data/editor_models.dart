/// Editor-side DTOs for the six editable task fields (viewer/spec.md
/// sections 4.1 and 7).
///
/// The editor keeps the text the user typed and derives normalized values for
/// `viewer update`. Normalization mirrors `src/labels.rs` and the store's
/// dependency parsing so a draft that normalizes to the stored record is a
/// no-op rather than a spurious write.
library;

import 'models.dart';

/// The six editable fields, in the documented form order.
enum EditorField {
  title('title', 'Title'),
  status('status', 'Status'),
  priority('priority', 'Priority'),
  labels('labels', 'Labels'),
  deps('deps', 'Dependencies'),
  body('body', 'Body');

  const EditorField(this.wireName, this.label);

  /// Name of the field inside a `viewer update` `changes` object.
  final String wireName;

  /// User-facing label used by the form and by validation messages.
  final String label;
}

/// One editor draft: exactly the text the form shows.
///
/// Labels and dependencies stay as typed so the form can show the user's own
/// spelling; [EditorFieldChanges.between] and the validator derive the
/// normalized values from that text.
final class TaskEditFields {
  const TaskEditFields({
    required this.title,
    required this.body,
    required this.status,
    required this.priority,
    required this.labelsText,
    required this.depsText,
  });

  /// Canonical starting text for one stored record.
  factory TaskEditFields.fromDetail(TaskDetail detail) => TaskEditFields(
    title: detail.title,
    body: detail.body,
    status: detail.status,
    priority: detail.priority,
    labelsText: detail.labels.join(', '),
    depsText: detail.deps.map(viewerCanonicalTaskId).join(', '),
  );

  final String title;
  final String body;
  final String status;
  final String priority;

  /// Comma-separated labels as typed.
  final String labelsText;

  /// Comma-separated dependency IDs as typed.
  final String depsText;

  TaskEditFields copyWith({
    String? title,
    String? body,
    String? status,
    String? priority,
    String? labelsText,
    String? depsText,
  }) => TaskEditFields(
    title: title ?? this.title,
    body: body ?? this.body,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    labelsText: labelsText ?? this.labelsText,
    depsText: depsText ?? this.depsText,
  );

  /// Value for one field, for generic form plumbing.
  String textOf(EditorField field) => switch (field) {
    EditorField.title => title,
    EditorField.status => status,
    EditorField.priority => priority,
    EditorField.labels => labelsText,
    EditorField.deps => depsText,
    EditorField.body => body,
  };

  TaskEditFields withText(EditorField field, String value) => switch (field) {
    EditorField.title => copyWith(title: value),
    EditorField.status => copyWith(status: value),
    EditorField.priority => copyWith(priority: value),
    EditorField.labels => copyWith(labelsText: value),
    EditorField.deps => copyWith(depsText: value),
    EditorField.body => copyWith(body: value),
  };

  /// Durable draft representation (private task content; never logged).
  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'body': body,
    'status': status,
    'priority': priority,
    'labels_text': labelsText,
    'deps_text': depsText,
  };

  /// Reads a draft written by [toJson]; throws [FormatException] on damage.
  factory TaskEditFields.fromJson(Map<String, Object?> json) {
    String text(String key) {
      final value = json[key];
      if (value is! String) {
        throw FormatException('draft field "$key" must be a string');
      }
      return value;
    }

    return TaskEditFields(
      title: text('title'),
      body: text('body'),
      status: text('status'),
      priority: text('priority'),
      labelsText: text('labels_text'),
      depsText: text('deps_text'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TaskEditFields &&
      other.title == title &&
      other.body == body &&
      other.status == status &&
      other.priority == priority &&
      other.labelsText == labelsText &&
      other.depsText == depsText;

  @override
  int get hashCode =>
      Object.hash(title, body, status, priority, labelsText, depsText);

  @override
  String toString() => 'TaskEditFields(${status.toLowerCase()})';
}

/// Normalizes a typed label list the way `src/labels.rs` does: split on
/// commas, trim, lowercase, drop empties, then sort and deduplicate.
List<String> normalizeEditorLabelsText(String text) {
  final normalized = <String>{};
  for (final part in text.split(',')) {
    final label = part.trim().toLowerCase();
    if (label.isNotEmpty) {
      normalized.add(label);
    }
  }
  final sorted = normalized.toList()..sort();
  return List<String>.unmodifiable(sorted);
}

/// One dependency entry that could not be parsed.
final class DependencyTokenError {
  const DependencyTokenError(this.token);

  /// The offending text exactly as typed.
  final String token;
}

/// Result of parsing the dependency text field.
final class DependencyTextParse {
  const DependencyTextParse({required this.ids, required this.errors});

  /// Distinct dependency IDs in first-seen order.
  final List<int> ids;

  /// Entries that are not `T-<digits>` or a bare integer, in typed order.
  final List<DependencyTokenError> errors;

  bool get isValid => errors.isEmpty;
}

/// Parses comma- or whitespace-separated `T-123` / `123` dependency entries.
DependencyTextParse parseEditorDependencyText(String text) {
  final ids = <int>[];
  final seen = <int>{};
  final errors = <DependencyTokenError>[];
  for (final raw in text.split(RegExp(r'[,\s]+'))) {
    final token = raw.trim();
    if (token.isEmpty) {
      continue;
    }
    final match = RegExp(r'^[Tt]-?0*(\d+)$').firstMatch(token);
    final int? id = match != null
        ? int.tryParse(match.group(1)!)
        : int.tryParse(token);
    if (id == null || id <= 0) {
      errors.add(DependencyTokenError(token));
      continue;
    }
    if (seen.add(id)) {
      ids.add(id);
    }
  }
  return DependencyTextParse(
    ids: List<int>.unmodifiable(ids),
    errors: List<DependencyTokenError>.unmodifiable(errors),
  );
}

_DependencyEquivalence _dependenciesEquivalent(String left, String right) {
  final a = parseEditorDependencyText(left);
  final b = parseEditorDependencyText(right);
  if (!a.isValid || !b.isValid) {
    return _DependencyEquivalence.incomparable;
  }
  final setA = a.ids.toSet();
  final setB = b.ids.toSet();
  return setA.length == setB.length && setA.containsAll(setB)
      ? _DependencyEquivalence.equal
      : _DependencyEquivalence.different;
}

enum _DependencyEquivalence { equal, different, incomparable }

/// The subset of the six fields a save would actually send.
///
/// Built by comparing a draft against its base record after normalization, so
/// reordering or recasing labels and respelling `T-2` as `2` never produces a
/// write.
final class EditorFieldChanges {
  const EditorFieldChanges({
    this.title,
    this.body,
    this.status,
    this.priority,
    this.labels,
    this.deps,
  });

  factory EditorFieldChanges.between(
    TaskEditFields base,
    TaskEditFields draft,
  ) {
    return EditorFieldChanges(
      title: draft.title == base.title ? null : draft.title,
      body: draft.body == base.body ? null : draft.body,
      status: draft.status == base.status ? null : draft.status,
      priority: draft.priority == base.priority ? null : draft.priority,
      labels: _sameLabels(base.labelsText, draft.labelsText)
          ? null
          : normalizeEditorLabelsText(draft.labelsText),
      deps:
          _dependenciesEquivalent(base.depsText, draft.depsText) ==
              _DependencyEquivalence.equal
          ? null
          : parseEditorDependencyText(draft.depsText).ids,
    );
  }

  static bool _sameLabels(String left, String right) {
    final a = normalizeEditorLabelsText(left);
    final b = normalizeEditorLabelsText(right);
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }

  final String? title;
  final String? body;
  final String? status;
  final String? priority;
  final List<String>? labels;
  final List<int>? deps;

  bool get isEmpty =>
      title == null &&
      body == null &&
      status == null &&
      priority == null &&
      labels == null &&
      deps == null;

  /// A copy with selected fields replaced; absent arguments keep this value.
  ///
  /// The Mark done paths use it to add `status: done` to whatever else the
  /// draft changes, so the store receives one request, not two.
  EditorFieldChanges copyWith({
    String? title,
    String? body,
    String? status,
    String? priority,
    List<String>? labels,
    List<int>? deps,
  }) => EditorFieldChanges(
    title: title ?? this.title,
    body: body ?? this.body,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    labels: labels ?? this.labels,
    deps: deps ?? this.deps,
  );

  bool get isNotEmpty => !isEmpty;

  /// Fields this change set touches, in form order.
  Set<EditorField> get fields => <EditorField>{
    if (title != null) EditorField.title,
    if (status != null) EditorField.status,
    if (priority != null) EditorField.priority,
    if (labels != null) EditorField.labels,
    if (deps != null) EditorField.deps,
    if (body != null) EditorField.body,
  };

  /// The `changes` object of a `viewer update` request.
  Map<String, Object?> toJson() => <String, Object?>{
    if (title != null) 'title': title,
    if (body != null) 'body': body,
    if (status != null) 'status': status,
    if (priority != null) 'priority': priority,
    if (labels != null) 'labels': labels,
    if (deps != null) 'deps': deps,
  };
}

/// One `viewer update` request body.
final class ViewerUpdateRequest {
  const ViewerUpdateRequest({
    required this.id,
    required this.expectVersion,
    required this.changes,
  });

  final int id;
  final int expectVersion;
  final EditorFieldChanges changes;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'expect_version': expectVersion,
    'changes': changes.toJson(),
  };
}

/// Applies one version-checked edit through the CLI (spec section 7).
///
/// The editor depends on this narrow surface instead of the whole client, so
/// tests can fault-inject conflicts, rejections and lost acknowledgements
/// without starting a process.
abstract interface class TaskUpdateWriter {
  Future<ViewerUpdateResult> updateTask(
    String projectId,
    ViewerUpdateRequest request,
  );
}

/// The confirmed result of one `viewer update`.
final class ViewerUpdateResult {
  const ViewerUpdateResult({
    required this.id,
    required this.status,
    required this.version,
    required this.eventId,
  });

  factory ViewerUpdateResult.fromJson(Map<String, Object?> json) {
    final command = json['command'];
    if (command != 'viewer_update') {
      throw ViewerMalformedResponseFailure(
        'expected a viewer_update payload, got "$command"',
      );
    }
    final protocol = json['protocol_version'];
    if (protocol != viewerProtocolVersion) {
      throw ViewerProtocolMismatchFailure(
        protocol is int ? protocol : viewerProtocolVersion + 1,
      );
    }
    final id = json['id'];
    final status = json['status'];
    final version = json['version'];
    if (id is! int || status is! String || version is! int) {
      throw const ViewerMalformedResponseFailure(
        'a viewer_update payload needs an integer id and version plus a '
        'status string',
      );
    }
    final eventId = json['event_id'];
    if (eventId is! int?) {
      throw const ViewerMalformedResponseFailure(
        'event_id must be an integer or null',
      );
    }
    return ViewerUpdateResult(
      id: id,
      status: status,
      version: version,
      eventId: eventId,
    );
  }

  final int id;

  /// Status after the update (normalized by the store).
  final String status;

  /// Resulting version; unchanged for a no-op.
  final int version;

  /// New history event, or null when the store created none (a no-op).
  final int? eventId;

  bool get isNoop => eventId == null;
}
