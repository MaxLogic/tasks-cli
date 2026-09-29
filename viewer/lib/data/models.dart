/// Immutable viewer protocol DTOs and strict JSON response decoding.
///
/// Contract: viewer/spec.md sections 4.1 and 4.2. The CLI owns request
/// validation; this file owns the client side of the same boundary:
/// * the success envelope has schema_version 1;
/// * every viewer payload has protocol_version 1;
/// * required fields are present and type-checked;
/// * additive response fields are ignored;
/// * duplicate object keys are rejected at every object level.
library;

import 'dart:convert';

/// The only protocol version this client understands.
const int viewerProtocolVersion = 1;

/// Base class for user-presentable viewer failures.
sealed class ViewerFailure implements Exception {
  const ViewerFailure();

  /// A complete, actionable message suitable for the status region.
  String get message;

  @override
  String toString() => message;
}

/// No usable tasks executable was found in the documented search order.
final class ViewerExecutableNotFoundFailure extends ViewerFailure {
  const ViewerExecutableNotFoundFailure(this.attemptedPaths);

  final List<String> attemptedPaths;

  @override
  String get message {
    final tried = attemptedPaths.isEmpty
        ? 'no candidate path was available'
        : 'tried ${attemptedPaths.join(', ')}';
    return 'Tasks CLI not found; $tried. Set the CLI path in Settings or pass '
        '--tasks-exe. The viewer never searches PATH.';
  }
}

/// The CLI answered, but with a protocol version this viewer cannot use.
final class ViewerProtocolMismatchFailure extends ViewerFailure {
  const ViewerProtocolMismatchFailure(this.foundVersion);

  final int foundVersion;

  @override
  String get message =>
      'Tasks CLI protocol version $foundVersion is not supported; this viewer '
      'requires protocol version $viewerProtocolVersion. Update both files '
      'from the same release bundle.';
}

/// The CLI output was not the required protocol document.
final class ViewerMalformedResponseFailure extends ViewerFailure {
  const ViewerMalformedResponseFailure(this.detail);

  final String detail;

  @override
  String get message => 'The tasks CLI returned an invalid response: $detail';
}

/// The CLI exited with its normal JSON error envelope, or an unusable error
/// stream. [exitCode] is retained for diagnostics and retry decisions.
final class ViewerCliErrorFailure extends ViewerFailure {
  const ViewerCliErrorFailure({
    required this.code,
    required this.message,
    required this.exitCode,
    this.conflictExpected,
    this.conflictCurrent,
    this.openPrerequisites = const <ViewerOpenPrerequisite>[],
  });

  final String code;

  @override
  final String message;

  final int exitCode;
  final int? conflictExpected;
  final int? conflictCurrent;

  /// Prerequisites that made the store refuse `done`; empty otherwise.
  final List<ViewerOpenPrerequisite> openPrerequisites;

  bool get isStaleSnapshot => code == 'stale_snapshot';
  bool get isNoStore =>
      code == 'no_store' ||
      code == 'registry' ||
      code == 'invalid_path' ||
      code == 'not_found';
}

/// One prerequisite that is neither done nor cancelled, from the structured
/// `open_prerequisites` detail of the store's completion-guard refusal.
final class ViewerOpenPrerequisite {
  const ViewerOpenPrerequisite({
    required this.id,
    required this.status,
    this.displayId,
  });

  final int id;
  final String status;

  /// `KEY-009` from the CLI; older CLIs send only the number.
  final String? displayId;

  String get canonicalId => displayId ?? viewerCanonicalTaskId(id);
}

/// The CLI process did not finish within the client read timeout.
final class ViewerTimeoutFailure extends ViewerFailure {
  const ViewerTimeoutFailure(this.timeout);

  final Duration timeout;

  @override
  String get message =>
      'The tasks CLI did not answer within ${timeout.inSeconds} seconds. '
      'Retry the read.';
}

/// A generated request exceeded the protocol's 8 MiB limit before a process
/// was started.
final class ViewerRequestTooLargeFailure extends ViewerFailure {
  const ViewerRequestTooLargeFailure({
    required this.byteLength,
    required this.limitBytes,
  });

  final int byteLength;
  final int limitBytes;

  @override
  String get message =>
      'The viewer request is $byteLength bytes; the limit is $limitBytes bytes '
      '(8 MiB). Shorten the query text and retry.';
}

/// The process could not be started at all.
final class ViewerProcessStartFailure extends ViewerFailure {
  const ViewerProcessStartFailure(this.message);

  @override
  final String message;
}

/// A superseded read was deliberately cancelled. Callers normally swallow it.
final class ViewerCancelledFailure extends ViewerFailure {
  const ViewerCancelledFailure();

  @override
  String get message => 'The superseded viewer read was cancelled.';
}

/// A data action ran before the `viewer info` handshake passed.
final class ViewerProbeRequiredFailure extends ViewerFailure {
  const ViewerProbeRequiredFailure();

  @override
  String get message =>
      'The viewer has not confirmed the tasks CLI protocol version yet; '
      'connect to the CLI before loading projects.';
}

/// The platform clipboard refused to hand over its plain text. The message
/// never repeats the clipboard contents.
final class ViewerClipboardFailure extends ViewerFailure {
  const ViewerClipboardFailure(this.message);

  @override
  final String message;
}

/// A decoded success envelope with its command tag and payload object.
final class ViewerEnvelope {
  const ViewerEnvelope({
    required this.schemaVersion,
    required this.projectId,
    required this.command,
    required this.data,
  });

  final int schemaVersion;
  final String? projectId;
  final String command;
  final Map<String, Object?> data;

  /// Decode one CLI stdout document.
  factory ViewerEnvelope.decode(
    String source, {
    Set<String>? expectedCommands,
  }) {
    final Object? root;
    try {
      root = decodeStrictJson(source);
    } on FormatException catch (error) {
      throw ViewerMalformedResponseFailure(error.message);
    }
    final object = _requireObject(root, r'$');
    final schemaVersion = _requireInt(object, 'schema_version', r'$');
    if (schemaVersion != 1) {
      throw ViewerMalformedResponseFailure(
        'unsupported schema_version $schemaVersion; expected 1',
      );
    }
    final projectId = _requiredNullableString(object, 'project_id', r'$');
    final data = _requireObject(
      _requiredValue(object, 'data', r'$'),
      r'$.data',
    );
    final command = _requireString(data, 'command', r'$.data');
    if (expectedCommands != null && !expectedCommands.contains(command)) {
      throw ViewerMalformedResponseFailure(
        'expected command ${expectedCommands.join(' or ')}, found "$command"',
      );
    }
    return ViewerEnvelope(
      schemaVersion: schemaVersion,
      projectId: projectId,
      command: command,
      data: data,
    );
  }
}

/// One project-state filter value from viewer/spec.md section 4.2.
enum ProjectStateFilter {
  all('all', 'All projects'),
  hasOpen('has-open', 'With open tasks'),
  hasBlocked('has-blocked', 'With blocked tasks'),
  complete('complete', 'Complete'),
  empty('empty', 'Empty'),
  unavailable('unavailable', 'Database unavailable'),
  active('active', 'Active projects'),
  archived('archived', 'Archived projects');

  const ProjectStateFilter(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static ProjectStateFilter fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported project state "$value"');
  }
}

/// Project sort keys from viewer/spec.md section 4.2.
enum ProjectSort {
  name('name', 'Name'),
  open('open', 'Open tasks'),
  total('total', 'Total tasks'),
  blocked('blocked', 'Blocked tasks'),
  started('started', 'Started'),
  lastWrite('last-write', 'Last task write'),
  progress('progress', 'Progress');

  const ProjectSort(this.wireValue, this.label);

  final String wireValue;
  final String label;

  SortDirection get defaultDirection => this == ProjectSort.name
      ? SortDirection.ascending
      : SortDirection.descending;

  static ProjectSort fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported project sort "$value"');
  }
}

/// Sort direction shared by project and task queries.
enum SortDirection {
  ascending('asc', 'Ascending'),
  descending('desc', 'Descending');

  const SortDirection(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SortDirection fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported direction "$value"');
  }
}

/// Availability of one project's database.
enum ProjectAvailability {
  available('available'),
  missing('missing'),
  error('error');

  const ProjectAvailability(this.wireValue);

  final String wireValue;

  static ProjectAvailability fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure(
      'unsupported project availability "$value"',
    );
  }
}

/// One project request document.
final class ProjectQuery {
  const ProjectQuery({
    this.query = '',
    this.state = ProjectStateFilter.all,
    this.sort = ProjectSort.name,
    this.direction = SortDirection.ascending,
    this.offset = 0,
    this.limit = 100,
    this.snapshot,
  });

  final String query;
  final ProjectStateFilter state;
  final ProjectSort sort;
  final SortDirection direction;
  final int offset;
  final int limit;
  final String? snapshot;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'state': state.wireValue,
    'sort': sort.wireValue,
    'direction': direction.wireValue,
    'offset': offset,
    'limit': limit,
    'snapshot': snapshot,
  };

  ProjectQuery copyWith({
    String? query,
    ProjectStateFilter? state,
    ProjectSort? sort,
    SortDirection? direction,
    int? offset,
    int? limit,
    String? snapshot,
    bool clearSnapshot = false,
  }) {
    return ProjectQuery(
      query: query ?? this.query,
      state: state ?? this.state,
      sort: sort ?? this.sort,
      direction: direction ?? this.direction,
      offset: offset ?? this.offset,
      limit: limit ?? this.limit,
      snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
    );
  }
}

/// Error details attached to one unavailable project row.
final class ProjectErrorInfo {
  const ProjectErrorInfo({required this.code, required this.message});

  final String code;
  final String message;

  factory ProjectErrorInfo.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    return ProjectErrorInfo(
      code: _requireString(json, 'code', path),
      message: _requireString(json, 'message', path),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
  };
}

/// One project's aggregate statistics (viewer/spec.md section 4.2).
final class ProjectStats {
  const ProjectStats({
    required this.total,
    required this.open,
    required this.blocked,
    required this.done,
    required this.cancelled,
    required this.startedMs,
    required this.lastWriteMs,
    required this.progressPercent,
  });

  final int total;
  final int open;
  final int blocked;
  final int done;
  final int cancelled;

  /// MIN(created_ms), null for a project with no recorded tasks.
  final int? startedMs;

  /// MAX(updated_ms), null for a project with no recorded tasks.
  final int? lastWriteMs;

  /// Null when every stored task is cancelled: progress is not applicable.
  final double? progressPercent;

  bool get hasRecordedTasks => total > 0;

  bool get hasProgress => progressPercent != null;

  factory ProjectStats.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    return ProjectStats(
      total: _requireInt(json, 'total', path),
      open: _requireInt(json, 'open', path),
      blocked: _requireInt(json, 'blocked', path),
      done: _requireInt(json, 'done', path),
      cancelled: _requireInt(json, 'cancelled', path),
      startedMs: _requiredNullableInt(json, 'started_ms', path),
      lastWriteMs: _requiredNullableInt(json, 'last_write_ms', path),
      progressPercent: _requiredNullableDouble(json, 'progress_percent', path),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'total': total,
    'open': open,
    'blocked': blocked,
    'done': done,
    'cancelled': cancelled,
    'started_ms': startedMs,
    'last_write_ms': lastWriteMs,
    'progress_percent': progressPercent,
  };
}

/// One catalog row: a unique project UUID with every bound root.
final class ProjectItem {
  const ProjectItem({
    this.archivedAtMs,
    this.projectKey,
    required this.projectId,
    required this.name,
    required this.roots,
    required this.availability,
    required this.error,
    required this.sampledAtMs,
    required this.stats,
  });

  final String projectId;

  /// The project key (`DAK`), or null before one is assigned.
  final String? projectKey;
  final String name;
  final List<String> roots;
  final ProjectAvailability availability;
  final ProjectErrorInfo? error;
  final int sampledAtMs;

  /// Null whenever [availability] is not `available`; never zeros.
  final ProjectStats? stats;

  final int? archivedAtMs;

  bool get isAvailable => availability == ProjectAvailability.available;

  /// Name with the project key, for example `DelphiAiKit (DAK)`; the plain
  /// name when the project has no key.
  String get displayName => projectKey == null ? name : '$name ($projectKey)';

  /// Every bound root, or the label used when the registry has none.
  String get rootSummary => roots.isEmpty ? 'No bound root' : roots.join(', ');

  factory ProjectItem.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    final errorValue = _requiredValue(json, 'error', path);
    final statsValue = _requiredValue(json, 'stats', path);
    return ProjectItem(
      archivedAtMs: json.containsKey('archived_at_ms')
          ? _requiredNullableInt(json, 'archived_at_ms', path)
          : null,
      projectId: _requireString(json, 'project_id', path),
      projectKey: _optionalString(json, 'project_key', path),
      name: _requireString(json, 'name', path),
      roots: _requireStringList(json, 'roots', path),
      availability: ProjectAvailability.fromWire(
        _requireString(json, 'availability', path),
      ),
      error: errorValue == null
          ? null
          : ProjectErrorInfo.fromJson(
              _requireObject(errorValue, '$path.error'),
              path: '$path.error',
            ),
      sampledAtMs: _requireInt(json, 'sampled_at_ms', path),
      stats: statsValue == null
          ? null
          : ProjectStats.fromJson(
              _requireObject(statsValue, '$path.stats'),
              path: '$path.stats',
            ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'project_id': projectId,
    'project_key': projectKey,
    'name': name,
    'roots': roots,
    'archived_at_ms': archivedAtMs,
    'availability': availability.wireValue,
    'error': error?.toJson(),
    'sampled_at_ms': sampledAtMs,
    'stats': stats?.toJson(),
  };
}

/// One page of the project catalog.
final class ProjectPage {
  const ProjectPage({
    required this.protocolVersion,
    required this.items,
    required this.totalCount,
    required this.offset,
    required this.limit,
    required this.hasMore,
    required this.nextOffset,
    required this.snapshot,
  });

  final int protocolVersion;
  final List<ProjectItem> items;
  final int totalCount;
  final int offset;
  final int limit;
  final bool hasMore;
  final int? nextOffset;
  final String? snapshot;

  factory ProjectPage.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    final rawItems = _requireList(
      _requiredValue(json, 'items', path),
      '$path.items',
    );
    return ProjectPage(
      protocolVersion: _requireProtocolVersion(json, path),
      items: List<ProjectItem>.unmodifiable(<ProjectItem>[
        for (var index = 0; index < rawItems.length; index++)
          ProjectItem.fromJson(
            _requireObject(rawItems[index], '$path.items[$index]'),
            path: '$path.items[$index]',
          ),
      ]),
      totalCount: _requireInt(json, 'total_count', path),
      offset: _requireInt(json, 'offset', path),
      limit: _requireInt(json, 'limit', path),
      hasMore: _requireBool(json, 'has_more', path),
      nextOffset: _requiredNullableInt(json, 'next_offset', path),
      snapshot: _requiredNullableString(json, 'snapshot', path),
    );
  }
}

/// The read surface a project pane needs.
///
/// [ViewerCliClient] implements it against the real CLI; controllers take this
/// interface so tests can drive them without a process.
abstract interface class ProjectReader {
  Future<ProjectPage> fetchProjects(ProjectQuery query);
}

/// A reader that can abandon the read in flight for one scope.
///
/// The controller cancels a superseded reload so the abandoned process is
/// killed instead of delivering a late answer.
abstract interface class CancellableProjectReader implements ProjectReader {
  void cancelScope(String scopeKey);
}

/// The six editable-field limits reported by `viewer info` (spec section 7).
final class ViewerEditableFieldLimits {
  const ViewerEditableFieldLimits({
    required this.titleMaxChars,
    required this.bodyMaxUtf8Bytes,
    required this.statusValues,
    required this.priorityValues,
    required this.labelsMaxCount,
    required this.labelsItemMaxChars,
    required this.labelsItemAllowed,
    required this.depsMaxCount,
  });

  final int titleMaxChars;
  final int bodyMaxUtf8Bytes;
  final List<String> statusValues;
  final List<String> priorityValues;
  final int labelsMaxCount;
  final int labelsItemMaxChars;
  final String labelsItemAllowed;
  final int depsMaxCount;

  factory ViewerEditableFieldLimits.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data.editable_field_limits',
  }) {
    Map<String, Object?> field(String name) =>
        _requireObject(_requiredValue(json, name, path), '$path.$name');
    final title = field('title');
    final body = field('body');
    final status = field('status');
    final priority = field('priority');
    final labels = field('labels');
    final deps = field('deps');
    return ViewerEditableFieldLimits(
      titleMaxChars: _requireInt(title, 'max_chars', '$path.title'),
      bodyMaxUtf8Bytes: _requireInt(body, 'max_utf8_bytes', '$path.body'),
      statusValues: _requireStringList(status, 'values', '$path.status'),
      priorityValues: _requireStringList(priority, 'values', '$path.priority'),
      labelsMaxCount: _requireInt(labels, 'max_count', '$path.labels'),
      labelsItemMaxChars: _requireInt(labels, 'item_max_chars', '$path.labels'),
      labelsItemAllowed: _requireString(labels, 'item_allowed', '$path.labels'),
      depsMaxCount: _requireInt(deps, 'max_count', '$path.deps'),
    );
  }
}

/// The `viewer info` payload: the handshake that must pass before any read.
final class ViewerInfo {
  const ViewerInfo({
    required this.protocolVersion,
    required this.operations,
    required this.statuses,
    required this.priorities,
    required this.editableFields,
    required this.editableFieldLimits,
  });

  final int protocolVersion;
  final List<String> operations;
  final List<String> statuses;
  final List<String> priorities;
  final List<String> editableFields;
  final ViewerEditableFieldLimits editableFieldLimits;

  factory ViewerInfo.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    return ViewerInfo(
      protocolVersion: _requireProtocolVersion(json, path),
      operations: _requireStringList(json, 'operations', path),
      statuses: _requireStringList(json, 'statuses', path),
      priorities: _requireStringList(json, 'priorities', path),
      editableFields: _requireStringList(json, 'editable_fields', path),
      editableFieldLimits: ViewerEditableFieldLimits.fromJson(
        _requireObject(
          _requiredValue(json, 'editable_field_limits', path),
          '$path.editable_field_limits',
        ),
        path: '$path.editable_field_limits',
      ),
    );
  }
}

/// The CLI's JSON error envelope, as written to stderr (spec section 4.1).
final class ViewerErrorEnvelope {
  const ViewerErrorEnvelope({
    required this.code,
    required this.message,
    this.conflictExpected,
    this.conflictCurrent,
    this.openPrerequisites = const <ViewerOpenPrerequisite>[],
  });

  final String code;
  final String message;
  final int? conflictExpected;
  final int? conflictCurrent;
  final List<ViewerOpenPrerequisite> openPrerequisites;

  /// Decodes an error document, or null when [source] is not one.
  static ViewerErrorEnvelope? tryDecode(String source) {
    final Object? root;
    try {
      root = decodeStrictJson(source);
    } on FormatException {
      return null;
    }
    if (root is! Map<String, Object?> || root['schema_version'] != 1) {
      return null;
    }
    final error = root['error'];
    if (error is! Map<String, Object?>) {
      return null;
    }
    final code = error['code'];
    final message = error['message'];
    if (code is! String || message is! String) {
      return null;
    }
    int? expected;
    int? current;
    final conflict = error['conflict'];
    if (conflict is Map<String, Object?>) {
      final expectedValue = conflict['expected'];
      final currentValue = conflict['current'];
      if (expectedValue is int) {
        expected = expectedValue;
      }
      if (currentValue is int) {
        current = currentValue;
      }
    }
    final open = <ViewerOpenPrerequisite>[];
    final guard = error['open_prerequisites'];
    if (guard is Map<String, Object?>) {
      final items = guard['prerequisites'];
      if (items is List<Object?>) {
        for (final item in items) {
          if (item is Map<String, Object?>) {
            final id = item['id'];
            final status = item['status'];
            final displayId = item['display_id'];
            if (id is int && status is String) {
              open.add(
                ViewerOpenPrerequisite(
                  id: id,
                  status: status,
                  displayId: displayId is String ? displayId : null,
                ),
              );
            }
          }
        }
      }
    }
    return ViewerErrorEnvelope(
      code: code,
      message: message,
      conflictExpected: expected,
      conflictCurrent: current,
      openPrerequisites: open,
    );
  }

  ViewerCliErrorFailure asFailure(int exitCode) => ViewerCliErrorFailure(
    code: code,
    message: message,
    exitCode: exitCode,
    conflictExpected: conflictExpected,
    conflictCurrent: conflictCurrent,
    openPrerequisites: openPrerequisites,
  );
}

/// Decodes one JSON document, rejecting duplicate object keys everywhere.
///
/// `dart:convert` keeps the last duplicate key, which would silently accept a
/// request or response that the protocol must reject, so the viewer parses its
/// own documents.
Object? decodeStrictJson(String source) => _StrictJsonParser(source).parse();

class _StrictJsonParser {
  _StrictJsonParser(this._source);

  /// Guards against a hostile document exhausting the stack.
  static const int _maxDepth = 100;

  final String _source;
  int _offset = 0;

  Object? parse() {
    _skipWhitespace();
    final value = _parseValue(0);
    _skipWhitespace();
    if (_offset != _source.length) {
      throw FormatException('unexpected trailing content at offset $_offset');
    }
    return value;
  }

  Object? _parseValue(int depth) {
    if (depth > _maxDepth) {
      throw const FormatException('the JSON document is nested too deeply');
    }
    final code = _peek();
    if (code == null) {
      throw FormatException('unexpected end of JSON at offset $_offset');
    }
    switch (code) {
      case 0x7B:
        return _parseObject(depth);
      case 0x5B:
        return _parseList(depth);
      case 0x22:
        return _parseString();
      case 0x74:
        _expectLiteral('true');
        return true;
      case 0x66:
        _expectLiteral('false');
        return false;
      case 0x6E:
        _expectLiteral('null');
        return null;
      default:
        return _parseNumber();
    }
  }

  Map<String, Object?> _parseObject(int depth) {
    _expect(0x7B);
    final result = <String, Object?>{};
    _skipWhitespace();
    if (_peek() == 0x7D) {
      _offset++;
      return result;
    }
    while (true) {
      _skipWhitespace();
      if (_peek() != 0x22) {
        throw FormatException('expected an object key at offset $_offset');
      }
      final keyOffset = _offset;
      final key = _parseString();
      if (result.containsKey(key)) {
        throw FormatException('duplicate JSON key "$key" at offset $keyOffset');
      }
      _skipWhitespace();
      _expect(0x3A);
      _skipWhitespace();
      result[key] = _parseValue(depth + 1);
      _skipWhitespace();
      final next = _peek();
      if (next == 0x2C) {
        _offset++;
        continue;
      }
      if (next == 0x7D) {
        _offset++;
        return result;
      }
      throw FormatException('expected "," or "}" at offset $_offset');
    }
  }

  List<Object?> _parseList(int depth) {
    _expect(0x5B);
    final result = <Object?>[];
    _skipWhitespace();
    if (_peek() == 0x5D) {
      _offset++;
      return result;
    }
    while (true) {
      _skipWhitespace();
      result.add(_parseValue(depth + 1));
      _skipWhitespace();
      final next = _peek();
      if (next == 0x2C) {
        _offset++;
        continue;
      }
      if (next == 0x5D) {
        _offset++;
        return result;
      }
      throw FormatException('expected "," or "]" at offset $_offset');
    }
  }

  String _parseString() {
    _expect(0x22);
    final buffer = StringBuffer();
    while (true) {
      final code = _peek();
      if (code == null) {
        throw FormatException('unterminated string at offset $_offset');
      }
      if (code == 0x22) {
        _offset++;
        return buffer.toString();
      }
      if (code == 0x5C) {
        _offset++;
        _parseEscape(buffer);
        continue;
      }
      if (code < 0x20) {
        throw FormatException(
          'unescaped control character 0x${code.toRadixString(16)} at offset '
          '$_offset',
        );
      }
      buffer.writeCharCode(code);
      _offset++;
    }
  }

  void _parseEscape(StringBuffer buffer) {
    final code = _peek();
    if (code == null) {
      throw FormatException('unterminated escape at offset $_offset');
    }
    _offset++;
    switch (code) {
      case 0x22:
        buffer.writeCharCode(0x22);
      case 0x5C:
        buffer.writeCharCode(0x5C);
      case 0x2F:
        buffer.writeCharCode(0x2F);
      case 0x62:
        buffer.writeCharCode(0x08);
      case 0x66:
        buffer.writeCharCode(0x0C);
      case 0x6E:
        buffer.writeCharCode(0x0A);
      case 0x72:
        buffer.writeCharCode(0x0D);
      case 0x74:
        buffer.writeCharCode(0x09);
      case 0x75:
        final first = _parseHexQuad();
        if (first >= 0xD800 && first <= 0xDBFF) {
          if (_peek() != 0x5C) {
            throw FormatException(
              'unpaired UTF-16 surrogate at offset $_offset',
            );
          }
          _offset++;
          if (_peek() != 0x75) {
            throw FormatException(
              'unpaired UTF-16 surrogate at offset $_offset',
            );
          }
          _offset++;
          final second = _parseHexQuad();
          if (second < 0xDC00 || second > 0xDFFF) {
            throw FormatException(
              'invalid UTF-16 surrogate pair at offset $_offset',
            );
          }
          buffer.writeCharCode(first);
          buffer.writeCharCode(second);
          return;
        }
        if (first >= 0xDC00 && first <= 0xDFFF) {
          throw FormatException('unpaired UTF-16 surrogate at offset $_offset');
        }
        buffer.writeCharCode(first);
      default:
        throw FormatException(
          'invalid escape "\\${String.fromCharCode(code)}" at offset '
          '${_offset - 1}',
        );
    }
  }

  int _parseHexQuad() {
    var value = 0;
    for (var index = 0; index < 4; index++) {
      final code = _peek();
      if (code == null) {
        throw FormatException('truncated \\u escape at offset $_offset');
      }
      final digit = _hexDigit(code);
      if (digit < 0) {
        throw FormatException('invalid \\u escape at offset $_offset');
      }
      value = (value << 4) | digit;
      _offset++;
    }
    return value;
  }

  static int _hexDigit(int code) {
    if (code >= 0x30 && code <= 0x39) {
      return code - 0x30;
    }
    if (code >= 0x41 && code <= 0x46) {
      return code - 0x41 + 10;
    }
    if (code >= 0x61 && code <= 0x66) {
      return code - 0x61 + 10;
    }
    return -1;
  }

  num _parseNumber() {
    final start = _offset;
    if (_peek() == 0x2D) {
      _offset++;
    }
    final first = _peek();
    if (first == null) {
      throw FormatException('unexpected end of JSON at offset $_offset');
    }
    if (first == 0x30) {
      _offset++;
    } else if (first >= 0x31 && first <= 0x39) {
      while (_isDigit(_peek())) {
        _offset++;
      }
    } else {
      throw FormatException('unexpected character at offset $_offset');
    }
    var isDouble = false;
    if (_peek() == 0x2E) {
      isDouble = true;
      _offset++;
      if (!_isDigit(_peek())) {
        throw FormatException('expected a fraction digit at offset $_offset');
      }
      while (_isDigit(_peek())) {
        _offset++;
      }
    }
    final exponent = _peek();
    if (exponent == 0x65 || exponent == 0x45) {
      isDouble = true;
      _offset++;
      final sign = _peek();
      if (sign == 0x2B || sign == 0x2D) {
        _offset++;
      }
      if (!_isDigit(_peek())) {
        throw FormatException('expected an exponent digit at offset $_offset');
      }
      while (_isDigit(_peek())) {
        _offset++;
      }
    }
    final text = _source.substring(start, _offset);
    final value = isDouble ? double.tryParse(text) : int.tryParse(text);
    if (value == null || (value is double && !value.isFinite)) {
      throw FormatException('invalid JSON number "$text" at offset $start');
    }
    return value;
  }

  void _expectLiteral(String literal) {
    if (!_source.startsWith(literal, _offset)) {
      throw FormatException('invalid literal at offset $_offset');
    }
    _offset += literal.length;
  }

  void _expect(int code) {
    if (_peek() != code) {
      throw FormatException(
        'expected "${String.fromCharCode(code)}" at offset $_offset',
      );
    }
    _offset++;
  }

  int? _peek() => _offset < _source.length ? _source.codeUnitAt(_offset) : null;

  static bool _isDigit(int? code) =>
      code != null && code >= 0x30 && code <= 0x39;

  void _skipWhitespace() {
    while (_offset < _source.length) {
      final code = _source.codeUnitAt(_offset);
      if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D) {
        _offset++;
        continue;
      }
      return;
    }
  }
}

// --------------------------------------------------------------------- tasks

/// Task scope values from viewer/spec.md section 4.3.
enum TaskScope {
  open('open', 'Open tasks'),
  all('all', 'All tasks');

  const TaskScope(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static TaskScope fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported task scope "$value"');
  }
}

/// Readiness filter values from viewer/spec.md section 4.3.
enum TaskReadiness {
  any('any', 'Any'),
  runnable('runnable', 'Runnable'),
  waiting('waiting', 'Waiting for dependencies');

  const TaskReadiness(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static TaskReadiness fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported readiness "$value"');
  }
}

/// Task sort keys from viewer/spec.md section 4.3.
enum TaskSort {
  priority('priority', 'Priority'),
  id('id', 'Task ID'),
  status('status', 'Status'),
  title('title', 'Title'),
  created('created', 'Created'),
  updated('updated', 'Last updated');

  const TaskSort(this.wireValue, this.label);

  final String wireValue;
  final String label;

  SortDirection get defaultDirection =>
      this == TaskSort.created || this == TaskSort.updated
      ? SortDirection.descending
      : SortDirection.ascending;

  static TaskSort fromWire(String value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) {
        return candidate;
      }
    }
    throw ViewerMalformedResponseFailure('unsupported task sort "$value"');
  }
}

/// Canonical status values in display order (viewer/spec.md section 4.3).
const List<String> viewerTaskStatuses = <String>[
  'draft',
  'todo',
  'in-progress',
  'to-verify',
  'blocked',
  'done',
  'cancelled',
];

/// Canonical priority values in display order.
const List<String> viewerTaskPriorities = <String>['P0', 'P1', 'P2', 'P3'];

/// Label that the "Needs human" checkbox synchronizes with.
const String needsHumanLabel = 'needs-human';

/// Human label for one canonical status value.
String viewerStatusLabel(String wireValue) => switch (wireValue) {
  'draft' => 'Draft',
  'todo' => 'Todo',
  'in-progress' => 'In progress',
  'to-verify' => 'To verify',
  'blocked' => 'Blocked',
  'done' => 'Done',
  'cancelled' => 'Cancelled',
  _ => wireValue,
};

/// True for statuses that end the task without further work.
bool viewerStatusIsTerminal(String wireValue) =>
    wireValue == 'done' || wireValue == 'cancelled';

/// Viewer wording for the store refusing `done` because of [open]
/// prerequisites, for example "T-012 was not marked done. Finish or cancel
/// T-009 (To verify) first."
String viewerOpenPrerequisitesMessage(
  String canonicalTaskId,
  List<ViewerOpenPrerequisite> open,
) {
  final names = <String>[
    for (final item in open)
      '${item.canonicalId} (${viewerStatusLabel(item.status)})',
  ];
  final listed = names.length <= 1
      ? names.join()
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '$canonicalTaskId was not marked done. Finish or cancel $listed '
      'first.';
}

/// Canonical display form of a task ID: `DAK-007` for a project with a key,
/// otherwise T-007, T-12000.
String viewerCanonicalTaskId(int id, [String? projectKey]) =>
    '${projectKey ?? 'T'}-${id.toString().padLeft(3, '0')}';

/// Throws unless [value] is one of the canonical statuses.
String _requireStatus(Object? value, String path) {
  final text = _requireStringValue(value, path);
  if (viewerTaskStatuses.contains(text)) {
    return text;
  }
  throw ViewerMalformedResponseFailure(
    'unsupported task status "$text" at $path',
  );
}

/// Throws unless [value] is one of the canonical priorities.
String _requirePriority(Object? value, String path) {
  final text = _requireStringValue(value, path);
  if (viewerTaskPriorities.contains(text)) {
    return text;
  }
  throw ViewerMalformedResponseFailure(
    'unsupported task priority "$text" at $path',
  );
}

/// One combined task request document (viewer/spec.md section 4.3).
///
/// The project UUID is not part of the document: every call passes it as an
/// explicit `--project` argument, so a page can never be routed by the
/// viewer's working directory.
final class TaskQuery {
  const TaskQuery({
    this.query = '',
    this.scope = TaskScope.open,
    this.statuses = const <String>[],
    this.priorities = const <String>[],
    this.labels = const <String>[],
    this.readiness = TaskReadiness.any,
    this.sort = TaskSort.priority,
    this.direction = SortDirection.ascending,
    this.offset = 0,
    this.limit = 100,
    this.snapshot,
  });

  final String query;
  final TaskScope scope;
  final List<String> statuses;
  final List<String> priorities;
  final List<String> labels;
  final TaskReadiness readiness;
  final TaskSort sort;
  final SortDirection direction;
  final int offset;
  final int limit;
  final String? snapshot;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'scope': scope.wireValue,
    'statuses': statuses,
    'priorities': priorities,
    'labels': labels,
    'readiness': readiness.wireValue,
    'sort': sort.wireValue,
    'direction': direction.wireValue,
    'offset': offset,
    'limit': limit,
    'snapshot': snapshot,
  };
}

/// One task row from `viewer tasks`; bodies never appear here.
final class TaskItem {
  const TaskItem({
    required this.id,
    this.displayId,
    required this.title,
    required this.status,
    required this.priority,
    required this.version,
    required this.labels,
    required this.dependencyCount,
    required this.waitingDependencyCount,
    this.verifyingDependencyCount = 0,
    required this.createdMs,
    required this.updatedMs,
  });

  final int id;

  /// `KEY-007` from the CLI; older CLIs send only the number.
  final String? displayId;
  final String title;
  final String status;
  final String priority;
  final int version;
  final List<String> labels;
  final int dependencyCount;

  /// Prerequisites that are not done, including cancelled ones.
  final int waitingDependencyCount;

  /// Prerequisites in `to-verify`. They are part of [waitingDependencyCount]
  /// because they still block completion, but they do not block starting.
  final int verifyingDependencyCount;

  /// Waiting prerequisites that also keep the task from starting, cancelled
  /// ones included.
  int get blockingDependencyCount =>
      waitingDependencyCount - verifyingDependencyCount;
  final int createdMs;
  final int updatedMs;

  String get canonicalId => displayId ?? viewerCanonicalTaskId(id);

  factory TaskItem.fromJson(Map<String, Object?> json, {required String path}) {
    return TaskItem(
      id: _requireInt(json, 'id', path),
      displayId: _optionalString(json, 'display_id', path),
      title: _requireString(json, 'title', path),
      status: _requireStatus(
        _requiredValue(json, 'status', path),
        '$path.status',
      ),
      priority: _requirePriority(
        _requiredValue(json, 'priority', path),
        '$path.priority',
      ),
      version: _requireInt(json, 'version', path),
      labels: _requireStringList(json, 'labels', path),
      dependencyCount: _requireInt(json, 'dependency_count', path),
      waitingDependencyCount: _requireInt(
        json,
        'waiting_dependency_count',
        path,
      ),
      verifyingDependencyCount: _requireInt(
        json,
        'verifying_dependency_count',
        path,
      ),
      createdMs: _requireInt(json, 'created_ms', path),
      updatedMs: _requireInt(json, 'updated_ms', path),
    );
  }
}

/// One page of the combined task query.
final class TaskPage {
  const TaskPage({
    required this.protocolVersion,
    this.projectKey,
    required this.items,
    required this.totalCount,
    required this.offset,
    required this.limit,
    required this.hasMore,
    required this.nextOffset,
    required this.snapshot,
  });

  final int protocolVersion;

  /// The project's key, or null when it has none (IDs then read T-N).
  final String? projectKey;
  final List<TaskItem> items;
  final int totalCount;
  final int offset;
  final int limit;
  final bool hasMore;
  final int? nextOffset;
  final String? snapshot;

  factory TaskPage.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    final rawItems = _requireList(
      _requiredValue(json, 'items', path),
      '$path.items',
    );
    return TaskPage(
      protocolVersion: _requireProtocolVersion(json, path),
      projectKey: _optionalString(json, 'project_key', path),
      items: List<TaskItem>.unmodifiable(<TaskItem>[
        for (var index = 0; index < rawItems.length; index++)
          TaskItem.fromJson(
            _requireObject(rawItems[index], '$path.items[$index]'),
            path: '$path.items[$index]',
          ),
      ]),
      totalCount: _requireInt(json, 'total_count', path),
      offset: _requireInt(json, 'offset', path),
      limit: _requireInt(json, 'limit', path),
      hasMore: _requireBool(json, 'has_more', path),
      nextOffset: _requiredNullableInt(json, 'next_offset', path),
      snapshot: _requiredNullableString(json, 'snapshot', path),
    );
  }
}

/// One dependency row inside a task detail.
final class DependencySummary {
  const DependencySummary({
    required this.id,
    this.displayId,
    required this.title,
    required this.status,
    required this.version,
  });

  final int id;

  /// `KEY-007` from the CLI; older CLIs send only the number.
  final String? displayId;
  final String title;
  final String status;
  final int version;

  String get canonicalId => displayId ?? viewerCanonicalTaskId(id);

  /// True while this dependency still withholds readiness from the task.
  ///
  /// Dependency waiting is separate from an explicit blocked status. Only a
  /// done dependency stops preventing readiness: a cancelled one remains
  /// unsatisfied (spec.md "CLI and output contract"), although it no longer
  /// blocks completion.
  bool get preventsReadiness => status != 'done';

  /// True for a `to-verify` dependency: it still waits for its batch gate, so
  /// it blocks completion, but it does not block starting the task.
  bool get awaitsVerification => status == 'to-verify';

  factory DependencySummary.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    return DependencySummary(
      id: _requireInt(json, 'id', path),
      displayId: _optionalString(json, 'display_id', path),
      title: _requireString(json, 'title', path),
      status: _requireStatus(
        _requiredValue(json, 'status', path),
        '$path.status',
      ),
      version: _requireInt(json, 'version', path),
    );
  }
}

/// The complete `viewer show` payload: every editable and read-only field.
final class TaskDetail {
  const TaskDetail({
    required this.id,
    this.projectKey,
    this.displayId,
    required this.title,
    required this.body,
    required this.status,
    required this.priority,
    required this.version,
    required this.labels,
    required this.deps,
    required this.dependencySummaries,
    required this.ruleVersion,
    required this.rules,
    required this.createdMs,
    required this.updatedMs,
  });

  final int id;
  final String title;
  final String body;
  final String status;
  final String priority;
  final int version;
  final List<String> labels;
  final List<int> deps;
  final List<DependencySummary> dependencySummaries;
  final int ruleVersion;
  final String rules;
  final int createdMs;
  final int updatedMs;

  /// The project's key, or null when it has none; the editor uses it to show
  /// and parse `KEY-N` dependency IDs.
  final String? projectKey;

  /// `KEY-007` from the CLI; older CLIs send only the number.
  final String? displayId;

  String get canonicalId => displayId ?? viewerCanonicalTaskId(id, projectKey);

  factory TaskDetail.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    final rawDeps = _requireList(
      _requiredValue(json, 'deps', path),
      '$path.deps',
    );
    final rawSummaries = _requireList(
      _requiredValue(json, 'dependency_summaries', path),
      '$path.dependency_summaries',
    );
    return TaskDetail(
      id: _requireInt(json, 'id', path),
      projectKey: _optionalString(json, 'project_key', path),
      displayId: _optionalString(json, 'display_id', path),
      title: _requireString(json, 'title', path),
      body: _requireString(json, 'body', path),
      status: _requireStatus(
        _requiredValue(json, 'status', path),
        '$path.status',
      ),
      priority: _requirePriority(
        _requiredValue(json, 'priority', path),
        '$path.priority',
      ),
      version: _requireInt(json, 'version', path),
      labels: _requireStringList(json, 'labels', path),
      deps: List<int>.unmodifiable(<int>[
        for (var index = 0; index < rawDeps.length; index++)
          _requireIntValue(rawDeps[index], '$path.deps[$index]'),
      ]),
      dependencySummaries:
          List<DependencySummary>.unmodifiable(<DependencySummary>[
            for (var index = 0; index < rawSummaries.length; index++)
              DependencySummary.fromJson(
                _requireObject(
                  rawSummaries[index],
                  '$path.dependency_summaries[$index]',
                ),
                path: '$path.dependency_summaries[$index]',
              ),
          ]),
      ruleVersion: _requireInt(json, 'rule_version', path),
      rules: _requireString(json, 'rules', path),
      createdMs: _requireInt(json, 'created_ms', path),
      updatedMs: _requireInt(json, 'updated_ms', path),
    );
  }
}

/// One append-only history event from the existing `history` command.
///
/// The CLI omits `task_id` and `entity_type` (the page names the task) and
/// sends the selected event's snapshot as a nested `snapshot` value; older
/// CLIs sent `task_id`, `entity_type` and a `snapshot_json` string, which are
/// still accepted.
final class HistoryEvent {
  const HistoryEvent({
    required this.eventId,
    required this.taskId,
    required this.entityType,
    required this.operation,
    required this.resultingVersion,
    required this.createdMs,
    required this.snapshotJson,
    this.changedFields,
  });

  final int eventId;
  final int? taskId;
  final String entityType;
  final String operation;
  final int resultingVersion;
  final int createdMs;

  /// Complete stored snapshot text, or null for events without one.
  final String? snapshotJson;

  /// Snapshot fields changed since the previous event, when the CLI reports
  /// them; null for a create or an event without a comparable predecessor.
  final List<String>? changedFields;

  factory HistoryEvent.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    return HistoryEvent(
      eventId: _requireInt(json, 'event_id', path),
      taskId: json.containsKey('task_id')
          ? _requiredNullableInt(json, 'task_id', path)
          : null,
      entityType: json.containsKey('entity_type')
          ? _requireString(json, 'entity_type', path)
          : 'task',
      operation: _requireString(json, 'operation', path),
      resultingVersion: _requireInt(json, 'resulting_version', path),
      createdMs: _requireInt(json, 'created_ms', path),
      snapshotJson: _historySnapshot(json, path),
      changedFields: json['changed_fields'] == null
          ? null
          : _requireStringList(json, 'changed_fields', path),
    );
  }
}

/// Snapshot text from a nested `snapshot` value (a JSON object, or a string
/// for legacy non-JSON snapshots) or the older `snapshot_json` string.
String? _historySnapshot(Map<String, Object?> json, String path) {
  if (json.containsKey('snapshot')) {
    final value = json['snapshot'];
    if (value == null || value is String) {
      return value as String?;
    }
    if (value is Map || value is List) {
      return jsonEncode(value);
    }
    throw ViewerMalformedResponseFailure(
      'field "$path.snapshot" must be an object, a string or null',
    );
  }
  if (json.containsKey('snapshot_json')) {
    return _requiredNullableString(json, 'snapshot_json', path);
  }
  return null;
}

/// One page of history events for a task, 100 per read.
final class TaskHistoryPage {
  const TaskHistoryPage({
    required this.items,
    required this.hasMore,
    required this.nextAfter,
  });

  final List<HistoryEvent> items;
  final bool hasMore;
  final int? nextAfter;

  factory TaskHistoryPage.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    final rawItems = _requireList(
      _requiredValue(json, 'items', path),
      '$path.items',
    );
    return TaskHistoryPage(
      items: List<HistoryEvent>.unmodifiable(<HistoryEvent>[
        for (var index = 0; index < rawItems.length; index++)
          HistoryEvent.fromJson(
            _requireObject(rawItems[index], '$path.items[$index]'),
            path: '$path.items[$index]',
          ),
      ]),
      hasMore: _requireBool(json, 'has_more', path),
      nextAfter: _requiredNullableInt(json, 'next_after', path),
    );
  }
}

int _requireIntValue(Object? value, String path) {
  if (value is int) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path" must be an integer');
}

/// The read surface a task list needs.
abstract interface class TaskReader {
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query);
}

/// A task reader whose in-flight read for one scope can be abandoned.
abstract interface class CancellableTaskReader implements TaskReader {
  void cancelScope(String scopeKey);
}

/// The read surface the details pane needs: full detail and paged history.
abstract interface class TaskDetailReader {
  Future<TaskDetail> fetchTaskDetail(String projectId, int taskId);

  Future<TaskHistoryPage> fetchTaskHistory(
    String projectId,
    int taskId, {
    int? after,
    int limit,
    int? event,
  });
}

/// A detail reader whose in-flight read for one scope can be abandoned.
abstract interface class CancellableTaskDetailReader
    implements TaskDetailReader {
  void cancelScope(String scopeKey);
}

/// The clipboard enrichment surface of one project scope (spec.md section 8).
///
/// Both operations reuse the legacy commands: [enrichClipboard] runs
/// `enrich-clipboard`, so the CLI owns the clipboard read, the text-equality
/// check and the replacement; [enrichText] runs `enrich --file -` with text the
/// caller already read and never touches the clipboard.
abstract interface class ClipboardEnricher {
  Future<ClipboardEnrichment> enrichClipboard(String projectId);

  Future<ClipboardEnrichment> enrichText(String projectId, String text);
}

/// One `enrich` payload: the transformed text and what changed.
///
/// `unknown_ids` are numeric task IDs that exist in the text but not in the
/// project; they stay unchanged and are reported so the UI can name them.
final class ClipboardEnrichment {
  const ClipboardEnrichment({
    required this.text,
    required this.replacements,
    required this.unknownIds,
    this.unknownRefs = const <String>[],
    required this.clipboard,
  });

  /// Enriched text. Never shown for the direct action, which must not expose
  /// the whole clipboard.
  final String text;

  /// How many references received a title annotation.
  final int replacements;

  /// Numeric IDs of this project that were left unchanged.
  final List<int> unknownIds;

  /// Every unknown reference as the CLI names it (`DAK-9`, `T-4`), including
  /// another project's; older CLIs omit it.
  final List<String> unknownRefs;

  /// Unknown references to show: [unknownRefs], or [unknownIds] in the
  /// project's display form when an older CLI sent only numbers.
  List<String> unknownLabels(String? projectKey) => unknownRefs.isNotEmpty
      ? unknownRefs
      : <String>[
          for (final id in unknownIds) viewerCanonicalTaskId(id, projectKey),
        ];

  /// True when the CLI read and replaced the clipboard itself.
  final bool clipboard;

  factory ClipboardEnrichment.fromJson(
    Map<String, Object?> json, {
    String path = r'$.data',
  }) {
    final rawUnknown = _requireList(
      _requiredValue(json, 'unknown_ids', path),
      '$path.unknown_ids',
    );
    return ClipboardEnrichment(
      text: _requireString(json, 'text', path),
      replacements: _requireInt(json, 'replacements', path),
      unknownIds: List<int>.unmodifiable(<int>[
        for (var index = 0; index < rawUnknown.length; index++)
          _requireIntValue(rawUnknown[index], '$path.unknown_ids[$index]'),
      ]),
      unknownRefs: json.containsKey('unknown_refs')
          ? _requireStringList(json, 'unknown_refs', path)
          : const <String>[],
      clipboard: _requireBool(json, 'clipboard', path),
    );
  }
}

// --------------------------------------------------------------- readers

Object? _requiredValue(Map<String, Object?> json, String key, String path) {
  if (!json.containsKey(key)) {
    throw ViewerMalformedResponseFailure('missing required field "$path.$key"');
  }
  return json[key];
}

Map<String, Object?> _requireObject(Object? value, String path) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path" must be a JSON object');
}

List<Object?> _requireList(Object? value, String path) {
  if (value is List<Object?>) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path" must be a JSON array');
}

String _requireString(Map<String, Object?> json, String key, String path) {
  final value = _requiredValue(json, key, path);
  if (value is String) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path.$key" must be a string');
}

/// A string field newer CLIs send and older ones omit; absent or null is null.
String? _optionalString(Map<String, Object?> json, String key, String path) {
  if (!json.containsKey(key)) {
    return null;
  }
  return _requiredNullableString(json, key, path);
}

String? _requiredNullableString(
  Map<String, Object?> json,
  String key,
  String path,
) {
  final value = _requiredValue(json, key, path);
  if (value == null || value is String) {
    return value as String?;
  }
  throw ViewerMalformedResponseFailure(
    'field "$path.$key" must be a string or null',
  );
}

int _requireInt(Map<String, Object?> json, String key, String path) {
  final value = _requiredValue(json, key, path);
  if (value is int) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path.$key" must be an integer');
}

int? _requiredNullableInt(Map<String, Object?> json, String key, String path) {
  final value = _requiredValue(json, key, path);
  if (value == null || value is int) {
    return value as int?;
  }
  throw ViewerMalformedResponseFailure(
    'field "$path.$key" must be an integer or null',
  );
}

double? _requiredNullableDouble(
  Map<String, Object?> json,
  String key,
  String path,
) {
  final value = _requiredValue(json, key, path);
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  throw ViewerMalformedResponseFailure(
    'field "$path.$key" must be a number or null',
  );
}

bool _requireBool(Map<String, Object?> json, String key, String path) {
  final value = _requiredValue(json, key, path);
  if (value is bool) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path.$key" must be a boolean');
}

List<String> _requireStringList(
  Map<String, Object?> json,
  String key,
  String path,
) {
  final values = _requireList(_requiredValue(json, key, path), '$path.$key');
  return List<String>.unmodifiable(<String>[
    for (var index = 0; index < values.length; index++)
      _requireStringValue(values[index], '$path.$key[$index]'),
  ]);
}

String _requireStringValue(Object? value, String path) {
  if (value is String) {
    return value;
  }
  throw ViewerMalformedResponseFailure('field "$path" must be a string');
}

int _requireProtocolVersion(Map<String, Object?> json, String path) {
  final version = _requireInt(json, 'protocol_version', path);
  if (version != viewerProtocolVersion) {
    throw ViewerProtocolMismatchFailure(version);
  }
  return version;
}
