/// Versioned viewer settings and recovery drafts on disk.
///
/// Contract: viewer/spec.md section 5. Settings are private local preferences;
/// a corrupt file is preserved under a timestamped name and replaced by
/// defaults with a warning the shell can show. Writes go to a temporary file in
/// the same directory and are then renamed over the target so a crash cannot
/// leave a half-written settings file.
library;

import 'dart:convert';
import 'dart:io';

import '../controllers/announcement_controller.dart';
import 'models.dart';
import 'settings_draft.dart';

/// Joins a directory and a file name with the platform separator.
///
/// The viewer deliberately avoids a path package: every path it handles comes
/// from a launch argument or the settings file and is already absolute.
String joinViewerPath(String directory, String name) {
  if (directory.endsWith('\\') || directory.endsWith('/')) {
    return '$directory$name';
  }
  return '$directory${Platform.pathSeparator}$name';
}

/// Schema version of the settings document itself.
const int viewerSettingsSchemaVersion = 1;

/// File name of the settings document inside the settings root.
const String viewerSettingsFileName = 'viewer-settings.json';

/// File name of the recovery-draft index inside the settings root.
const String viewerRecoveryFileName = 'recovery-drafts.json';

/// One load attempt and everything the caller must be able to report.
final class SettingsLoadResult {
  const SettingsLoadResult({
    required this.draft,
    this.warning,
    this.preservedPath,
    this.loadedFromFile = false,
  });

  /// Effective preferences: the parsed file, or defaults after a problem.
  final ViewerSettingsDraft draft;

  /// Visible warning text, or null when the load was clean.
  final String? warning;

  /// Where a corrupt file was preserved, when that happened.
  final String? preservedPath;

  /// True when the draft came from the settings file rather than defaults.
  final bool loadedFromFile;

  bool get hasWarning => warning != null;
}

/// Reads and writes the versioned settings document.
class SettingsStore {
  SettingsStore({required this.settingsRoot, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Directory that owns the settings file and the recovery-draft index.
  final String settingsRoot;

  final DateTime Function() _clock;
  int _tempCounter = 0;

  String get settingsFilePath =>
      joinViewerPath(settingsRoot, viewerSettingsFileName);

  String get recoveryFilePath =>
      joinViewerPath(settingsRoot, viewerRecoveryFileName);

  /// The recovery-draft surface slice 5 fills in with editor semantics.
  late final RecoveryDraftStore recoveryDrafts = RecoveryDraftStore(
    indexFilePath: recoveryFilePath,
    clock: _clock,
  );

  /// Loads the effective settings, never throwing on a bad file.
  Future<SettingsLoadResult> load() async {
    final file = File(settingsFilePath);
    if (!await file.exists()) {
      return const SettingsLoadResult(draft: ViewerSettingsDraft());
    }
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (error) {
      return SettingsLoadResult(
        draft: const ViewerSettingsDraft(),
        warning:
            'Could not read $settingsFilePath (${error.message}). Defaults '
            'are in effect.',
      );
    }
    final ViewerSettingsDraft draft;
    try {
      draft = decodeSettingsDocument(text);
    } on FormatException catch (error) {
      final preserved = await _preserveCorruptFile(file);
      return SettingsLoadResult(
        draft: const ViewerSettingsDraft(),
        preservedPath: preserved,
        warning:
            'The settings file was unreadable (${error.message}). It was kept '
            'as $preserved and defaults are in effect.',
      );
    }
    return SettingsLoadResult(draft: draft, loadedFromFile: true);
  }

  /// Saves [draft] by writing a temporary file and renaming it into place.
  Future<void> save(ViewerSettingsDraft draft) async {
    await _writeAtomically(settingsFilePath, encodeSettingsDocument(draft));
  }

  /// Writes [contents] next to [path] and renames it over the target.
  Future<void> _writeAtomically(String path, String contents) async {
    final directory = Directory(settingsRoot);
    await directory.create(recursive: true);
    final tempPath = joinViewerPath(
      settingsRoot,
      '${_basename(path)}.tmp-${_clock().microsecondsSinceEpoch}-'
      '${_tempCounter++}',
    );
    final temp = File(tempPath);
    try {
      await temp.writeAsString(contents, flush: true);
      try {
        await temp.rename(path);
      } on FileSystemException {
        // A target that Windows refuses to replace in place (for example one
        // with a read-only attribute) is removed first. This path is not
        // atomic; it is only reached when the rename above already failed.
        final target = File(path);
        if (await target.exists()) {
          await target.delete();
        }
        await temp.rename(path);
      }
    } on Object {
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  /// Renames a corrupt file out of the way without destroying its contents.
  Future<String> _preserveCorruptFile(File file) async {
    final stamp = _fileTimestamp(_clock());
    var candidate = joinViewerPath(
      settingsRoot,
      'viewer-settings.corrupt-$stamp.json',
    );
    var attempt = 1;
    while (await File(candidate).exists()) {
      attempt++;
      candidate = joinViewerPath(
        settingsRoot,
        'viewer-settings.corrupt-$stamp-$attempt.json',
      );
    }
    try {
      await file.rename(candidate);
    } on FileSystemException {
      // A rename can fail while another process holds the file; copying keeps
      // the evidence even then.
      await file.copy(candidate);
    }
    return candidate;
  }

  static String _basename(String path) {
    final separator = path.lastIndexOf('\\') > path.lastIndexOf('/')
        ? '\\'
        : '/';
    final index = path.lastIndexOf(separator);
    return index < 0 ? path : path.substring(index + 1);
  }

  static String _fileTimestamp(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}T'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${three(now.millisecond)}';
  }
}

/// Serializes one settings document.
String encodeSettingsDocument(ViewerSettingsDraft draft) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(<String, Object?>{
    'schema_version': viewerSettingsSchemaVersion,
    'cli_path': draft.cliPath,
    'data_root': draft.dataRoot,
    'theme_mode': draft.themeMode.name,
    'text_scale_percent': draft.textScalePercent,
    'projects_pane_percent': draft.projectsPanePercent,
    'tasks_pane_percent': draft.tasksPanePercent,
    'details_pane_percent': draft.detailsPanePercent,
    'start_with_windows': draft.startWithWindows,
    'announcement_mode': draft.announcementMode.name,
    'bella_volume_percent': draft.bellaVolumePercent,
    'project_state': draft.projectState.wireValue,
    'project_sort': draft.projectSort.wireValue,
    'project_direction': draft.projectDirection.wireValue,
  });
}

/// Parses one settings document, throwing [FormatException] when it cannot be
/// trusted. Unknown additive fields are ignored; a wrong type for a known field
/// counts as corruption rather than silently changing a preference.
ViewerSettingsDraft decodeSettingsDocument(String source) {
  final Object? root;
  try {
    root = decodeStrictJson(source);
  } on FormatException catch (error) {
    throw FormatException(error.message);
  }
  final Map<String, Object?> document;
  if (root is Map<String, Object?>) {
    document = root;
  } else {
    throw const FormatException('the settings document is not an object');
  }
  final version = document['schema_version'];
  if (version is! int) {
    throw const FormatException('missing integer schema_version');
  }
  if (version != viewerSettingsSchemaVersion) {
    throw FormatException('unsupported settings schema_version $version');
  }
  String? optionalPath(String key) {
    final value = document[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value.isEmpty ? null : value;
    }
    throw FormatException('field "$key" must be a string or null');
  }

  int percent(String key, int fallback) {
    final value = document[key];
    if (value == null) {
      return fallback;
    }
    if (value is int) {
      return value;
    }
    throw FormatException('field "$key" must be an integer');
  }

  bool flag(String key, bool fallback) {
    final value = document[key];
    if (value == null) {
      return fallback;
    }
    if (value is bool) {
      return value;
    }
    throw FormatException('field "$key" must be a boolean');
  }

  T named<T extends Enum>(String key, List<T> values, T fallback) {
    final value = document[key];
    if (value == null) {
      return fallback;
    }
    if (value is String) {
      for (final candidate in values) {
        if (candidate.name == value) {
          return candidate;
        }
      }
      throw FormatException('field "$key" has unsupported value "$value"');
    }
    throw FormatException('field "$key" must be a string');
  }

  T wired<T>(String key, List<T> values, T fallback, String Function(T) wire) {
    final value = document[key];
    if (value == null) return fallback;
    if (value is String) {
      for (final candidate in values) {
        if (wire(candidate) == value) return candidate;
      }
      throw FormatException('field "$key" has unsupported value "$value"');
    }
    throw FormatException('field "$key" must be a string');
  }

  const defaults = ViewerSettingsDraft();
  return ViewerSettingsDraft(
    cliPath: optionalPath('cli_path'),
    dataRoot: optionalPath('data_root'),
    themeMode: named('theme_mode', ViewerThemeMode.values, defaults.themeMode),
    textScalePercent: percent('text_scale_percent', defaults.textScalePercent),
    projectsPanePercent: percent(
      'projects_pane_percent',
      defaults.projectsPanePercent,
    ),
    tasksPanePercent: percent('tasks_pane_percent', defaults.tasksPanePercent),
    detailsPanePercent: percent(
      'details_pane_percent',
      defaults.detailsPanePercent,
    ),
    startWithWindows: flag('start_with_windows', defaults.startWithWindows),
    announcementMode: named(
      'announcement_mode',
      AnnouncementMode.values,
      defaults.announcementMode,
    ),
    bellaVolumePercent: percent(
      'bella_volume_percent',
      defaults.bellaVolumePercent,
    ),
    projectState: wired(
      'project_state',
      ProjectStateFilter.values,
      defaults.projectState,
      (value) => value.wireValue,
    ),
    projectSort: wired(
      'project_sort',
      ProjectSort.values,
      defaults.projectSort,
      (value) => value.wireValue,
    ),
    projectDirection: wired(
      'project_direction',
      SortDirection.values,
      defaults.projectDirection,
      (value) => value.wireValue,
    ),
  );
}

/// Normalizes a store path for draft identity comparison.
///
/// Windows stores are compared case-insensitively with forward slashes, so the
/// same store reached through two spellings keeps one draft.
String recoveryDraftSlug(String path) =>
    path.replaceAll('\\', '/').toLowerCase();

/// Stable identity of the recovery draft for one store, project and task.
String viewerRecoveryDraftId({
  required String dataRoot,
  required String projectId,
  required String taskId,
}) => '${recoveryDraftSlug(dataRoot)}|$projectId|$taskId';

/// One unsaved editor draft, keyed by store, project and task identity.
///
/// Slice 5 owns when drafts are written and deleted; this type and
/// [RecoveryDraftStore] keep the on-disk surface stable for it.
final class ViewerRecoveryDraft {
  const ViewerRecoveryDraft({
    required this.dataRoot,
    required this.projectId,
    required this.taskId,
    required this.baseVersion,
    required this.baseFields,
    required this.draftFields,
    required this.updatedMs,
  });

  final String dataRoot;
  final String projectId;
  final String taskId;
  final int baseVersion;
  final Map<String, Object?> baseFields;
  final Map<String, Object?> draftFields;
  final int updatedMs;

  /// Stable identity of one editor draft.
  String get draftId => viewerRecoveryDraftId(
    dataRoot: dataRoot,
    projectId: projectId,
    taskId: taskId,
  );

  factory ViewerRecoveryDraft.fromJson(Map<String, Object?> json) {
    Map<String, Object?> fields(String key) {
      final value = json[key];
      if (value is Map<String, Object?>) {
        return Map<String, Object?>.unmodifiable(value);
      }
      throw FormatException('recovery draft field "$key" must be an object');
    }

    final dataRoot = json['data_root'];
    final projectId = json['project_id'];
    final taskId = json['task_id'];
    final baseVersion = json['base_version'];
    final updatedMs = json['updated_ms'];
    if (dataRoot is! String ||
        projectId is! String ||
        taskId is! String ||
        baseVersion is! int ||
        updatedMs is! int) {
      throw const FormatException('recovery draft identity is incomplete');
    }
    return ViewerRecoveryDraft(
      dataRoot: dataRoot,
      projectId: projectId,
      taskId: taskId,
      baseVersion: baseVersion,
      baseFields: fields('base_fields'),
      draftFields: fields('draft_fields'),
      updatedMs: updatedMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'data_root': dataRoot,
    'project_id': projectId,
    'task_id': taskId,
    'base_version': baseVersion,
    'base_fields': baseFields,
    'draft_fields': draftFields,
    'updated_ms': updatedMs,
  };
}

/// The persistence surface the editor needs for recovery drafts.
///
/// The editor depends on this interface rather than the file-backed store, so
/// tests can inject keep-in-memory drafts, a damaged index or a failing disk
/// without touching the file system.
abstract interface class RecoveryDraftSink {
  Future<List<ViewerRecoveryDraft>> loadAll();

  Future<void> save(ViewerRecoveryDraft draft);

  Future<void> delete(String draftId);
}

/// Persists recovery drafts as one atomically replaced index file.
class RecoveryDraftStore implements RecoveryDraftSink {
  RecoveryDraftStore({required this.indexFilePath, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final String indexFilePath;
  final DateTime Function() _clock;

  @override
  Future<List<ViewerRecoveryDraft>> loadAll() async {
    final file = File(indexFilePath);
    if (!await file.exists()) {
      return const <ViewerRecoveryDraft>[];
    }
    final Object? root;
    try {
      root = decodeStrictJson(await file.readAsString());
    } on FormatException {
      return const <ViewerRecoveryDraft>[];
    }
    if (root is! Map<String, Object?> || root['drafts'] is! List<Object?>) {
      return const <ViewerRecoveryDraft>[];
    }
    final drafts = <ViewerRecoveryDraft>[];
    for (final entry in root['drafts']! as List<Object?>) {
      if (entry is! Map<String, Object?>) {
        continue;
      }
      try {
        drafts.add(ViewerRecoveryDraft.fromJson(entry));
      } on FormatException {
        continue;
      }
    }
    return List<ViewerRecoveryDraft>.unmodifiable(drafts);
  }

  /// Inserts or replaces one draft, keeping the rest.
  @override
  Future<void> save(ViewerRecoveryDraft draft) async {
    final drafts = <String, ViewerRecoveryDraft>{
      for (final existing in await loadAll()) existing.draftId: existing,
    };
    drafts[draft.draftId] = draft;
    await _write(drafts.values.toList(growable: false));
  }

  @override
  Future<void> delete(String draftId) async {
    final drafts = <String, ViewerRecoveryDraft>{
      for (final existing in await loadAll()) existing.draftId: existing,
    };
    if (drafts.remove(draftId) == null) {
      return;
    }
    await _write(drafts.values.toList(growable: false));
  }

  Future<void> _write(List<ViewerRecoveryDraft> drafts) async {
    final directory = Directory(File(indexFilePath).parent.path);
    await directory.create(recursive: true);
    final tempPath = '$indexFilePath.tmp-${_clock().microsecondsSinceEpoch}';
    final temp = File(tempPath);
    const encoder = JsonEncoder.withIndent('  ');
    try {
      await temp.writeAsString(
        encoder.convert(<String, Object?>{
          'schema_version': viewerSettingsSchemaVersion,
          'drafts': <Object?>[for (final draft in drafts) draft.toJson()],
        }),
        flush: true,
      );
      await temp.rename(indexFilePath);
    } on Object {
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }
}
