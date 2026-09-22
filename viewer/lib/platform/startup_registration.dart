/// Windows per-user startup registration for the portable viewer bundle.
///
/// Contract: viewer/spec.md section 3.1. One shortcut named
/// `MaxLogic Tasks Viewer.lnk` in the current user's Startup known folder
/// targets this executable with `--startup` plus the resolved data, settings
/// and CLI paths; arguments are stored as one shortcut property, never built
/// by shell composition. Registration is applied only by a packaged release
/// launch; debug, test and `--test-mode` launches never touch the real folder
/// because tests inject a temporary startup directory and a fake store.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../data/settings_store.dart' show joinViewerPath;

/// File name of the shortcut this application owns in the Startup folder.
const String viewerStartupShortcutFileName = 'MaxLogic Tasks Viewer.lnk';

/// Description written into the owned shortcut; also the ownership marker
/// used when adjudicating a shortcut whose target has moved.
const String viewerStartupShortcutDescription = 'MaxLogic Tasks Viewer';

/// What the Startup folder currently holds for this application.
enum StartupShortcutState {
  /// Owned shortcut present and pointing at this bundle with these arguments.
  registered,

  /// No file with the owned name exists.
  missing,

  /// An owned shortcut exists but is stale (moved bundle, changed paths).
  needsUpdate,

  /// A file with the owned name belongs to another program; never overwrite.
  foreign,

  /// The file exists but its link properties cannot be read.
  unreadable,

  /// The platform does not implement Windows shortcuts.
  unsupported,
}

/// Outcome of inspecting or updating the owned startup shortcut.
class StartupRegistrationReport {
  const StartupRegistrationReport({
    required this.state,
    required this.shortcutPath,
    this.windowsDisabled,
    this.failure,
  });

  final StartupShortcutState state;

  /// Absolute path of the owned shortcut file.
  final String shortcutPath;

  /// Effective Windows/Task Manager state from StartupApproved, when readable:
  /// true means Windows will not run the entry even though the file exists.
  final bool? windowsDisabled;

  /// Human-readable failure detail when an operation could not complete.
  final String? failure;

  bool get isRegistered => state == StartupShortcutState.registered;
  bool get hasFailure => failure != null;

  /// True when the user must act: a conflict, a policy block or a failure.
  bool get needsUserAction =>
      hasFailure ||
      state == StartupShortcutState.foreign ||
      state == StartupShortcutState.unreadable ||
      windowsDisabled == true;

  bool get isSupported => state != StartupShortcutState.unsupported;
}

/// Absolute identity of the bundle a startup shortcut must launch.
class ViewerStartupTarget {
  ViewerStartupTarget({
    required this.executablePath,
    required this.arguments,
    required this.workingDirectory,
  });

  /// Absolute path of the installed viewer executable.
  final String executablePath;

  /// Argument list, stored as one property with separate path values.
  final List<String> arguments;

  /// Working directory the shortcut starts in; the executable directory.
  final String workingDirectory;

  /// The single shortcut argument string for [arguments].
  String get argumentLine => formatWindowsArguments(arguments);

  /// Same bundle identity with a different argument list.
  ViewerStartupTarget withArguments(List<String> arguments) =>
      ViewerStartupTarget(
        executablePath: executablePath,
        arguments: arguments,
        workingDirectory: workingDirectory,
      );
}

/// Quotes one argument for a Windows command line.
///
/// The shortcut stores arguments as a single string property, so each value is
/// quoted and backslash-escaped with the documented CommandLineToArgv rules.
String quoteWindowsArgument(String argument) {
  if (argument.isEmpty) {
    return '""';
  }
  final needsQuotes = argument.codeUnits.any(
    (unit) => unit == 0x20 || unit == 0x09 || unit == 0x22,
  );
  if (!needsQuotes) {
    return argument;
  }
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final unit in argument.codeUnits) {
    if (unit == 0x5c) {
      backslashes += 1;
      continue;
    }
    if (unit == 0x22) {
      buffer.write('\\' * (backslashes * 2 + 1));
      buffer.writeCharCode(0x22);
      backslashes = 0;
      continue;
    }
    if (backslashes > 0) {
      buffer.write('\\' * backslashes);
      backslashes = 0;
    }
    buffer.writeCharCode(unit);
  }
  buffer.write('\\' * (backslashes * 2));
  buffer.write('"');
  return buffer.toString();
}

/// Joins arguments into the shortcut's single argument string.
String formatWindowsArguments(List<String> arguments) =>
    arguments.map(quoteWindowsArgument).join(' ');

/// Parses a Windows argument string back into separate values.
///
/// Only used to compare an existing app-owned shortcut with this bundle; a
/// string that cannot be parsed returns null and never counts as a match.
List<String>? parseWindowsArguments(String line) {
  final arguments = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var backslashes = 0;
  var started = false;
  for (final unit in line.codeUnits) {
    if (unit == 0x5c) {
      backslashes += 1;
      started = true;
      continue;
    }
    if (unit == 0x22) {
      current.write('\\' * (backslashes ~/ 2));
      if (backslashes.isOdd) {
        current.writeCharCode(0x22);
      } else {
        inQuotes = !inQuotes;
      }
      backslashes = 0;
      started = true;
      continue;
    }
    if (backslashes > 0) {
      current.write('\\' * backslashes);
      backslashes = 0;
    }
    if (!inQuotes && (unit == 0x20 || unit == 0x09)) {
      if (started) {
        arguments.add(current.toString());
        current.clear();
        started = false;
      }
      continue;
    }
    current.writeCharCode(unit);
    started = true;
  }
  if (inQuotes) {
    return null;
  }
  current.write('\\' * backslashes);
  if (started) {
    arguments.add(current.toString());
  }
  return arguments;
}

/// One shortcut file's stored properties.
class StartupShortcutRecord {
  const StartupShortcutRecord({
    this.target,
    this.arguments,
    this.workingDirectory,
    this.description,
  });

  final String? target;
  final String? arguments;
  final String? workingDirectory;
  final String? description;
}

/// Reads, writes and deletes shortcut files.
abstract interface class StartupShortcutStore {
  Future<StartupShortcutRecord?> read(String shortcutPath);

  Future<void> write(String shortcutPath, StartupShortcutRecord record);

  Future<void> delete(String shortcutPath);
}

/// Shortcut store backed by the Windows shell link COM API.
///
/// IShellLink writes the target, the argument string and the working directory
/// as separate properties; paths are never passed through a command shell.
class ShellStartupShortcutStore implements StartupShortcutStore {
  const ShellStartupShortcutStore();

  /// CLSID_ShellLink `{00021401-0000-0000-C000-000000000046}`.
  static final GUID _clsidShellLink = GUID.fromComponents(
    0x21401,
    0x0,
    0x0,
    .fromList(const [0xc0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x46]),
  );

  /// Maximum characters the shell link API returns for a path.
  static const int _pathChars = 4096;

  /// Maximum characters for the argument string.
  static const int _argumentChars = 32768;

  /// Maximum characters for the shortcut description.
  static const int _descriptionChars = 1024;

  @override
  Future<StartupShortcutRecord?> read(String shortcutPath) async {
    if (!await File(shortcutPath).exists()) {
      return null;
    }
    return _withCom((arena) {
      final link = arena.com<IShellLink>(_clsidShellLink);
      final persist = arena.adopt(link.queryInterface<IPersistFile>());
      persist.load(arena.pcwstr(shortcutPath), STGM_READ);
      final target = arena.pwstrBuffer(_pathChars);
      link.getPath(target, _pathChars, nullptr, 0);
      final arguments = arena.pwstrBuffer(_argumentChars);
      link.getArguments(arguments, _argumentChars);
      final workingDirectory = arena.pwstrBuffer(_pathChars);
      link.getWorkingDirectory(workingDirectory, _pathChars);
      final description = arena.pwstrBuffer(_descriptionChars);
      link.getDescription(description, _descriptionChars);
      return StartupShortcutRecord(
        target: target.toDartString(),
        arguments: arguments.toDartString(),
        workingDirectory: workingDirectory.toDartString(),
        description: description.toDartString(),
      );
    });
  }

  @override
  Future<void> write(String shortcutPath, StartupShortcutRecord record) async {
    final directory = File(shortcutPath).parent;
    await directory.create(recursive: true);
    _withCom((arena) {
      final link = arena.com<IShellLink>(_clsidShellLink);
      link.setPath(arena.pcwstr(record.target ?? ''));
      link.setArguments(arena.pcwstr(record.arguments ?? ''));
      link.setWorkingDirectory(arena.pcwstr(record.workingDirectory ?? ''));
      link.setDescription(arena.pcwstr(record.description ?? ''));
      final persist = arena.adopt(link.queryInterface<IPersistFile>());
      persist.save(arena.pcwstr(shortcutPath), true);
      return true;
    });
  }

  @override
  Future<void> delete(String shortcutPath) async {
    final file = File(shortcutPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// Runs one COM operation inside a fresh arena after initializing COM.
T _withCom<T>(T Function(Arena arena) body) {
  _ensureComInitialized();
  return using(body);
}

/// COM is initialized once per isolate and never uninitialized.
///
/// The engine may already own the apartment on this thread; a failed
/// CoInitializeEx leaves COM usable and the real failure surfaces from the
/// operation itself, so no HRESULT is handled here.
bool _comInitialized = false;

void _ensureComInitialized() {
  if (_comInitialized) {
    return;
  }
  _comInitialized = true;
  try {
    CoInitializeEx(COINIT_APARTMENTTHREADED);
  } on Object catch (_) {
    // Ignored: any real COM failure is reported by the operation's HRESULT.
  }
}

/// Normalizes a Windows path for identity comparison.
String normalizeViewerPath(String path) {
  var normalized = path.trim().replaceAll('/', '\\');
  while (normalized.length > 3 && normalized.endsWith('\\')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

/// True when two Windows paths name the same location.
bool viewerPathsEqual(String left, String right) =>
    normalizeViewerPath(left) == normalizeViewerPath(right);

/// File name portion of a Windows path.
String viewerPathFileName(String path) {
  final normalized = path.replaceAll('/', '\\');
  final index = normalized.lastIndexOf('\\');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

/// Read-only view of the effective Windows startup state.
abstract interface class StartupPolicyProbe {
  /// True when Windows or Task Manager disabled [shortcutFileName], false when
  /// it is explicitly enabled, null when the state is unreadable.
  Future<bool?> shortcutDisabledByWindows(String shortcutFileName);
}

/// Reads the per-entry StartupApproved flag without ever writing it.
///
/// The encoding is documented by behavior, not by Microsoft: the first byte of
/// the binary value is 0x02/0x03 for a disabled entry and 0x06 for an enabled
/// one. Anything else, a missing value or an unreadable key reports null and
/// the viewer then says the effective state is unknown instead of guessing.
class WindowsStartupPolicyProbe implements StartupPolicyProbe {
  const WindowsStartupPolicyProbe();

  /// Where Windows records per-entry startup enablement.
  static const String startupApprovedSubKey =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer'
      r'\StartupApproved\StartupFolder';

  @override
  Future<bool?> shortcutDisabledByWindows(String shortcutFileName) async {
    try {
      return using((arena) {
        final type = arena<Uint32>();
        final size = arena<Uint32>();
        final data = arena<Uint8>(32);
        size.value = 32;
        final result = RegGetValue(
          HKEY_CURRENT_USER,
          startupApprovedSubKey.toPcwstr(allocator: arena),
          shortcutFileName.toPcwstr(allocator: arena),
          RRF_RT_REG_BINARY,
          type,
          data.cast<Void>(),
          size,
        );
        if (result != 0 || size.value == 0) {
          return null;
        }
        final flag = data[0];
        if (flag == 0x02 || flag == 0x03) {
          return true;
        }
        if (flag == 0x06) {
          return false;
        }
        return null;
      });
    } on Object catch (_) {
      // An unreadable policy value is reported as unknown, never as enabled.
      return null;
    }
  }
}

/// Inspects and updates the one startup shortcut this application owns.
class StartupRegistrar {
  StartupRegistrar({
    required this.startupDirectory,
    required this.target,
    StartupShortcutStore store = const ShellStartupShortcutStore(),
    StartupPolicyProbe policy = const WindowsStartupPolicyProbe(),
    this.shortcutName = viewerStartupShortcutFileName,
  }) : // Private fields cannot be named parameters, so the lint cannot apply.
       // ignore: prefer_initializing_formals
       _store = store,
       // ignore: prefer_initializing_formals
       _policy = policy;

  /// Absolute Startup known folder; tests inject a temporary directory.
  final String startupDirectory;

  /// Bundle the shortcut must launch.
  final ViewerStartupTarget target;

  /// Owned shortcut file name.
  final String shortcutName;

  final StartupShortcutStore _store;
  final StartupPolicyProbe _policy;

  /// Absolute path of the owned shortcut file.
  String get shortcutPath => joinViewerPath(startupDirectory, shortcutName);

  /// Current truth for the shortcut file and its effective Windows state.
  Future<StartupRegistrationReport> inspect() async {
    if (!Platform.isWindows) {
      return StartupRegistrationReport(
        state: StartupShortcutState.unsupported,
        shortcutPath: shortcutPath,
      );
    }
    final StartupShortcutRecord? record;
    try {
      record = await _store.read(shortcutPath);
    } on Object catch (error) {
      return _report(
        StartupShortcutState.unreadable,
        failure:
            'The startup shortcut at $shortcutPath could not be read: '
            '$error',
      );
    }
    return _report(_classify(record));
  }

  /// Creates or refreshes the owned shortcut.
  ///
  /// A foreign or unreadable file is reported, never overwritten.
  Future<StartupRegistrationReport> ensureRegistered() async {
    final current = await inspect();
    switch (current.state) {
      case StartupShortcutState.registered:
      case StartupShortcutState.unsupported:
        return current;
      case StartupShortcutState.foreign:
        return _report(
          current.state,
          failure:
              'A startup shortcut named "$shortcutName" already belongs '
              'to another program. It was left untouched; remove or rename it '
              'to let the viewer register its own entry.',
        );
      case StartupShortcutState.unreadable:
        return _report(
          current.state,
          failure:
              current.failure ??
              'The existing startup shortcut cannot be read and was left '
                  'untouched.',
        );
      case StartupShortcutState.missing:
      case StartupShortcutState.needsUpdate:
        try {
          await _store.write(shortcutPath, _ownedRecord());
        } on Object catch (error) {
          return _report(
            current.state,
            failure:
                'The startup shortcut could not be written to '
                '$shortcutPath: $error',
          );
        }
        final verified = await inspect();
        if (verified.isRegistered) {
          return verified;
        }
        return _report(
          verified.state,
          failure:
              verified.failure ??
              'The startup shortcut at $shortcutPath did not read back as this '
                  'bundle.',
        );
    }
  }

  /// Removes the owned shortcut; a foreign file is never deleted.
  Future<StartupRegistrationReport> removeOwned() async {
    final current = await inspect();
    switch (current.state) {
      case StartupShortcutState.missing:
      case StartupShortcutState.unsupported:
        return current;
      case StartupShortcutState.foreign:
        return _report(
          current.state,
          failure:
              'A startup shortcut named "$shortcutName" belongs to '
              'another program. It was left untouched.',
        );
      case StartupShortcutState.registered:
      case StartupShortcutState.needsUpdate:
      case StartupShortcutState.unreadable:
        try {
          await _store.delete(shortcutPath);
        } on Object catch (error) {
          return _report(
            current.state,
            failure:
                'The startup shortcut at $shortcutPath could not be '
                'removed: $error',
          );
        }
        final after = await inspect();
        if (after.state == StartupShortcutState.missing) {
          return after;
        }
        return _report(
          after.state,
          failure:
              after.failure ??
              'The startup shortcut at $shortcutPath is still present.',
        );
    }
  }

  /// Shortcut properties this application owns for [target].
  StartupShortcutRecord _ownedRecord() => StartupShortcutRecord(
    target: target.executablePath,
    arguments: target.argumentLine,
    workingDirectory: target.workingDirectory,
    description: viewerStartupShortcutDescription,
  );

  /// Decides what an existing file means for this bundle.
  StartupShortcutState _classify(StartupShortcutRecord? record) {
    if (record == null) {
      return StartupShortcutState.missing;
    }
    final targetPath = record.target;
    if (targetPath == null || targetPath.isEmpty) {
      return StartupShortcutState.unreadable;
    }
    final sameTarget = viewerPathsEqual(targetPath, target.executablePath);
    if (sameTarget) {
      return _argumentsMatch(record.arguments, target.arguments)
          ? StartupShortcutState.registered
          : StartupShortcutState.needsUpdate;
    }
    final sameFileName = viewerPathsEqual(
      viewerPathFileName(targetPath),
      viewerPathFileName(target.executablePath),
    );
    if (!sameFileName) {
      return StartupShortcutState.foreign;
    }
    final ownedDescription =
        (record.description ?? '').trim() == viewerStartupShortcutDescription;
    final startupArguments =
        parseWindowsArguments(record.arguments ?? '')?.contains('--startup') ??
        false;
    if (ownedDescription || startupArguments) {
      return StartupShortcutState.needsUpdate;
    }
    return StartupShortcutState.foreign;
  }

  bool _argumentsMatch(String? stored, List<String> expected) {
    if (stored == null) {
      return false;
    }
    final parsed = parseWindowsArguments(stored);
    if (parsed == null || parsed.length != expected.length) {
      return false;
    }
    for (var index = 0; index < parsed.length; index++) {
      if (parsed[index] != expected[index]) {
        return false;
      }
    }
    return true;
  }

  Future<StartupRegistrationReport> _report(
    StartupShortcutState state, {
    String? failure,
  }) async {
    bool? windowsDisabled;
    if (state != StartupShortcutState.missing &&
        state != StartupShortcutState.unsupported) {
      windowsDisabled = await _policy.shortcutDisabledByWindows(shortcutName);
    }
    return StartupRegistrationReport(
      state: state,
      shortcutPath: shortcutPath,
      windowsDisabled: windowsDisabled,
      failure: failure,
    );
  }
}

/// Builds the startup target for one installed bundle.
///
/// The saved data root and CLI path are included when known; the CLI falls
/// back to the bundled `tasks.exe` beside the viewer when it is not.
ViewerStartupTarget viewerStartupTargetFor({
  required String executablePath,
  required String settingsRoot,
  String? dataRoot,
  String? tasksExe,
}) {
  final directory = File(executablePath).parent.path;
  final arguments = <String>[
    '--startup',
    '--settings-root',
    settingsRoot,
    if (dataRoot != null && dataRoot.isNotEmpty) ...<String>[
      '--data-root',
      dataRoot,
    ],
    if (tasksExe != null && tasksExe.isNotEmpty) ...<String>[
      '--tasks-exe',
      tasksExe,
    ],
  ];
  return ViewerStartupTarget(
    executablePath: executablePath,
    arguments: arguments,
    workingDirectory: directory,
  );
}

/// Absolute path of the current user's Startup known folder.
///
/// `SHGetKnownFolderPath` hands back shell-owned memory, so the string is
/// copied before `CoTaskMemFree` releases it; callers never see shell memory.
/// Only Windows implements the folder, and only a packaged release may use it.
String windowsStartupDirectory() {
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Windows startup registration is only available on Windows.',
    );
  }
  _ensureComInitialized();
  return using((arena) {
    final path = SHGetKnownFolderPath(
      FOLDERID_Startup.toNative(allocator: arena),
      KF_FLAG_DEFAULT,
      null,
    );
    try {
      return path.toDartString();
    } finally {
      CoTaskMemFree(path);
    }
  });
}
