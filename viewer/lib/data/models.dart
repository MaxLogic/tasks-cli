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
  });

  final String code;

  @override
  final String message;

  final int exitCode;
  final int? conflictExpected;
  final int? conflictCurrent;

  bool get isStaleSnapshot => code == 'stale_snapshot';
  bool get isNoStore =>
      code == 'no_store' ||
      code == 'registry' ||
      code == 'invalid_path' ||
      code == 'not_found';
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
  unavailable('unavailable', 'Unavailable');

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
    required this.projectId,
    required this.name,
    required this.roots,
    required this.availability,
    required this.error,
    required this.sampledAtMs,
    required this.stats,
  });

  final String projectId;
  final String name;
  final List<String> roots;
  final ProjectAvailability availability;
  final ProjectErrorInfo? error;
  final int sampledAtMs;

  /// Null whenever [availability] is not `available`; never zeros.
  final ProjectStats? stats;

  bool get isAvailable => availability == ProjectAvailability.available;

  /// Every bound root, or the label used when the registry has none.
  String get rootSummary => roots.isEmpty ? 'No bound root' : roots.join(', ');

  factory ProjectItem.fromJson(
    Map<String, Object?> json, {
    required String path,
  }) {
    final errorValue = _requiredValue(json, 'error', path);
    final statsValue = _requiredValue(json, 'stats', path);
    return ProjectItem(
      projectId: _requireString(json, 'project_id', path),
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
    'name': name,
    'roots': roots,
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
  });

  final String code;
  final String message;
  final int? conflictExpected;
  final int? conflictCurrent;

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
    return ViewerErrorEnvelope(
      code: code,
      message: message,
      conflictExpected: expected,
      conflictCurrent: current,
    );
  }

  ViewerCliErrorFailure asFailure(int exitCode) => ViewerCliErrorFailure(
    code: code,
    message: message,
    exitCode: exitCode,
    conflictExpected: conflictExpected,
    conflictCurrent: conflictCurrent,
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
