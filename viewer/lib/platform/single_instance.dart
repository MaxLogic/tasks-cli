/// One normal viewer instance per Windows user and settings root.
///
/// Contract: viewer/spec.md section 3.1. The first launch owns an instance
/// lock under the resolved settings root and publishes a loopback activation
/// port; a second launch over the same settings root asks that window to come
/// forward and exits without creating another editor. Everything here is file
/// and socket based, so the exchange stays testable without a desktop session.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/settings_store.dart' show joinViewerPath;

/// Thrown when a launch cannot decide who owns the instance slot.
class ViewerInstanceUnavailable implements Exception {
  ViewerInstanceUnavailable(this.message);

  final String message;

  @override
  String toString() => 'ViewerInstanceUnavailable: $message';
}

/// What one launch learned about the instance slot.
class ViewerInstanceClaim {
  const ViewerInstanceClaim._({required this.isPrimary, this.instance});

  /// True when this process owns the slot and must run the viewer.
  final bool isPrimary;

  /// Primary-only handle; null for a secondary launch.
  final ViewerSingleInstance? instance;
}

/// The primary instance's activation channel and its owned registry files.
class ViewerSingleInstance {
  ViewerSingleInstance._({
    required ServerSocket server,
    required this.settingsRoot,
    required this.lockPath,
    required this.portPath,
    required Future<void> Function() onActivate,
  }) : _server = server, // ignore: prefer_initializing_formals
       _onActivate = onActivate; // ignore: prefer_initializing_formals

  /// Empty file whose exclusive creation marks the primary instance.
  static const String lockFileName = 'viewer-instance.lock';

  /// Activation-port document published for later launches.
  static const String portFileName = 'viewer-instance.json';

  /// Directory that owns both registry files.
  final String settingsRoot;

  /// Owned lock file; removed only by this instance.
  final String lockPath;

  /// Owned activation document; removed only by this instance.
  final String portPath;

  final ServerSocket _server;
  final Future<void> Function() _onActivate;
  bool _activationInFlight = false;
  bool _disposed = false;

  /// Loopback port later launches connect to.
  int get port => _server.port;

  /// Reads activation requests until [dispose].
  void listen() {
    _server.listen(
      _handleConnection,
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  /// Closes the channel and removes the files this instance created.
  ///
  /// Safe to call more than once; a repeated call does nothing.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await _server.close();
    } on Object catch (_) {
      // The channel is already unusable; the files are still removed below.
    }
    ViewerInstance._deleteQuietly(portPath);
    ViewerInstance._deleteQuietly(lockPath);
  }

  void _handleConnection(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim() == ViewerInstance.activateCommand) {
              unawaited(_activate());
            }
          },
          onError: (Object _) {},
          cancelOnError: true,
        );
  }

  /// Runs one activation at a time so a burst of launches cannot stack up.
  Future<void> _activate() async {
    if (_activationInFlight || _disposed) {
      return;
    }
    _activationInFlight = true;
    try {
      await _onActivate();
    } on Object catch (_) {
      // A failed activation never takes the running viewer down.
    } finally {
      _activationInFlight = false;
    }
  }
}

/// Claims the one viewer slot for a settings root.
class ViewerInstance {
  /// How long a second launch waits for the primary's activation port.
  static const Duration defaultConnectTimeout = Duration(milliseconds: 600);

  /// How long a lock file without a reachable window counts as live.
  static const Duration defaultStaleWait = Duration(seconds: 1);

  /// Pause between attempts while another launch is still starting up.
  static const Duration defaultRetryDelay = Duration(milliseconds: 100);

  /// Line a second launch sends to ask the existing window to come forward.
  static const String activateCommand = 'activate';

  /// Claims the slot under [settingsRoot], or activates the owner.
  ///
  /// Returns a claim whose [ViewerInstanceClaim.isPrimary] is false when an
  /// existing window accepted the activation request; the caller then exits
  /// without creating a second editor.
  static Future<ViewerInstanceClaim> claim({
    required String settingsRoot,
    required Future<void> Function() onActivate,
    Duration connectTimeout = defaultConnectTimeout,
    Duration staleWait = defaultStaleWait,
    Duration retryDelay = defaultRetryDelay,
  }) async {
    final lockPath = joinViewerPath(
      settingsRoot,
      ViewerSingleInstance.lockFileName,
    );
    final portPath = joinViewerPath(
      settingsRoot,
      ViewerSingleInstance.portFileName,
    );
    try {
      await Directory(settingsRoot).create(recursive: true);
    } on FileSystemException catch (error) {
      throw ViewerInstanceUnavailable(
        'The instance registry under $settingsRoot could not be created: '
        '${error.message}',
      );
    }

    final deadline = DateTime.now().add(staleWait);
    var clearedStaleLock = false;
    while (true) {
      if (await _requestActivation(portPath, connectTimeout)) {
        return const ViewerInstanceClaim._(isPrimary: false);
      }
      if (_createExclusive(lockPath)) {
        final instance = await _startPrimary(
          settingsRoot: settingsRoot,
          lockPath: lockPath,
          portPath: portPath,
          onActivate: onActivate,
        );
        return ViewerInstanceClaim._(isPrimary: true, instance: instance);
      }
      // The lock exists. Its owner may still be starting up, so it is only
      // treated as a leftover after [staleWait] and then cleared once.
      if (!clearedStaleLock && !DateTime.now().isBefore(deadline)) {
        clearedStaleLock = true;
        _deleteQuietly(lockPath);
        continue;
      }
      if (clearedStaleLock) {
        throw ViewerInstanceUnavailable(
          'Another viewer instance owns $lockPath but did not answer on its '
          'activation port.',
        );
      }
      await Future<void>.delayed(retryDelay);
    }
  }

  static Future<ViewerSingleInstance> _startPrimary({
    required String settingsRoot,
    required String lockPath,
    required String portPath,
    required Future<void> Function() onActivate,
  }) async {
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } on Object catch (error) {
      _deleteQuietly(lockPath);
      throw ViewerInstanceUnavailable(
        'The activation port could not be opened: $error',
      );
    }
    final instance = ViewerSingleInstance._(
      server: server,
      settingsRoot: settingsRoot,
      lockPath: lockPath,
      portPath: portPath,
      onActivate: onActivate,
    );
    try {
      await _writeRegistry(portPath, server.port);
    } on Object catch (error) {
      await instance.dispose();
      throw ViewerInstanceUnavailable(
        'The activation document $portPath could not be written: $error',
      );
    }
    instance.listen();
    return instance;
  }

  /// True when a running viewer accepted the activation request.
  static Future<bool> _requestActivation(
    String portPath,
    Duration connectTimeout,
  ) async {
    final int? port = await _readRegistryPort(portPath);
    if (port == null) {
      return false;
    }
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: connectTimeout,
      );
      socket.write('$activateCommand\n');
      await socket.flush();
      await socket.close();
      return true;
    } on Object catch (_) {
      // A refused or silent port means the document is stale.
      try {
        socket?.destroy();
      } on Object catch (_) {}
      return false;
    }
  }

  static Future<int?> _readRegistryPort(String portPath) async {
    final Object? decoded;
    try {
      final text = await File(portPath).readAsString();
      decoded = jsonDecode(text);
    } on Object catch (_) {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final port = decoded['port'];
    if (port is! int || port <= 0 || port > 65535) {
      return null;
    }
    return port;
  }

  static Future<void> _writeRegistry(String portPath, int port) async {
    final document = const JsonEncoder.withIndent(
      '  ',
    ).convert(<String, Object?>{'port': port, 'pid': pid});
    final tempPath = '$portPath.tmp-$pid';
    final temp = File(tempPath);
    await temp.writeAsString(document, flush: true);
    await temp.rename(portPath);
  }

  static bool _createExclusive(String lockPath) {
    try {
      File(lockPath).createSync(exclusive: true);
      return true;
    } on FileSystemException catch (_) {
      return false;
    }
  }

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (_) {
      // Leftovers are recovered by the next launch's stale-lock path.
    }
  }
}
