/// Offline playback of the bundled Bella announcement clips.
///
/// Contract: viewer/spec.md section 9.1. Runtime speech is local: the player
/// writes each bundled MP3 once per process into its own temporary directory
/// and drives the Win32 MCI device through `mciSendStringW`, so no network,
/// external player or API key is involved. Tests inject [MciBridge] and an
/// asset loader, so no test ever opens an audio device.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:win32/win32.dart';

import '../controllers/announcement_catalog.dart';
import '../controllers/announcement_controller.dart';

/// Raised when one clip cannot be played.
///
/// [AnnouncementController] catches it, keeps an audio warning and falls back
/// to the live announcement, so a broken clip never blocks an operation.
class AnnouncementPlaybackError implements Exception {
  AnnouncementPlaybackError(this.message);

  final String message;

  @override
  String toString() => 'AnnouncementPlaybackError: $message';
}

/// The narrow MCI surface the player uses; tests inject a recording double.
abstract interface class MciBridge {
  /// Sends one MCI command string and returns its result code (0 on success).
  int send(String command);

  /// Windows' text for a non-zero MCI result code.
  String errorText(int code);

  /// Text answer for a `status` command, or null when it cannot be read.
  String? query(String command);
}

/// [MciBridge] backed by `winmm`'s `mciSendStringW`.
class WinmmMciBridge implements MciBridge {
  WinmmMciBridge();

  static const int _statusChars = 128;
  static const int _errorChars = 512;

  @override
  int send(String command) =>
      using((arena) => mciSendString(arena.pcwstr(command), null, 0, null));

  @override
  String errorText(int code) {
    return using((arena) {
      final buffer = arena.pwstrBuffer(_errorChars);
      if (!mciGetErrorString(code, buffer, _errorChars)) {
        return 'MCI error $code';
      }
      return buffer.toDartString();
    });
  }

  @override
  String? query(String command) {
    return using((arena) {
      final buffer = arena.pwstrBuffer(_statusChars);
      final code = mciSendString(
        arena.pcwstr(command),
        buffer,
        _statusChars,
        null,
      );
      if (code != 0) {
        return null;
      }
      return buffer.toDartString();
    });
  }
}

/// Plays the bundled clips through one MCI alias.
///
/// Exactly one clip is open at a time: a new [play] stops and closes the
/// current clip first, which is what keeps two app clips from overlapping.
class WindowsBellaClipPlayer implements ClipPlayer {
  WindowsBellaClipPlayer({
    required Future<Uint8List> Function(String assetPath) loadAsset,
    required MciBridge bridge,
    required String tempRoot,
    Duration pollInterval = const Duration(milliseconds: 200),
    Duration maximumClipDuration = const Duration(seconds: 60),
  }) : _loadAsset = loadAsset, // ignore: prefer_initializing_formals
       _bridge = bridge, // ignore: prefer_initializing_formals
       _tempRoot = tempRoot, // ignore: prefer_initializing_formals
       _pollInterval = pollInterval, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _maximumClipDuration = maximumClipDuration;

  /// Player bound to the bundled assets and the real MCI device.
  factory WindowsBellaClipPlayer.withBundleAssets({
    MciBridge? bridge,
    String? tempRoot,
  }) => WindowsBellaClipPlayer(
    loadAsset: loadBundledClip,
    bridge: bridge ?? WinmmMciBridge(),
    tempRoot: tempRoot ?? defaultClipTempRoot,
  );

  /// MCI alias; never contains a space or a backslash.
  static const String alias = 'tasksviewerannounce';

  /// Asset directory the catalog's clip ids are resolved against.
  static const String assetDirectory = 'assets/announcements';

  /// Directory the decoded clip files are staged in for this process.
  static String get defaultClipTempRoot =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'MaxLogic-tasks-viewer';

  /// Asset path of one catalog clip.
  static String assetPathFor(String clipId) => '$assetDirectory/$clipId.mp3';

  /// Reads one bundled asset as bytes.
  static Future<Uint8List> loadBundledClip(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  final Future<Uint8List> Function(String assetPath) _loadAsset;
  final MciBridge _bridge;
  final String _tempRoot;
  final Duration _pollInterval;
  final Duration _maximumClipDuration;

  final Map<String, String> _files = <String, String>{};
  Timer? _poll;
  Timer? _cutoff;
  bool _open = false;
  bool _disposed = false;

  /// True while a clip is open on the MCI device.
  bool get isPlaying => _open;

  @override
  Future<void> play(AnnouncementClip clip, {required double volume}) async {
    if (_disposed) {
      throw AnnouncementPlaybackError(
        'The announcement player was already disposed.',
      );
    }
    final path = await _clipFile(clip);
    if (path.contains('"')) {
      throw AnnouncementPlaybackError(
        'The clip path "$path" cannot be quoted for MCI.',
      );
    }
    // Never overlap: the previous clip is stopped and closed first.
    await stop();
    _expect('open "$path" type mpegvideo alias $alias');
    _open = true;
    // Volume is best effort: an MCI device that cannot set it still plays the
    // clip, which matters more than the level of a status phrase.
    _bridge.send('setaudio $alias volume to ${_volumeLevel(volume)}');
    _expect('play $alias');
    _poll = Timer.periodic(_pollInterval, (_) => _pollFinished());
    _cutoff = Timer(_maximumClipDuration, () => unawaited(stop()));
  }

  @override
  Future<void> stop() async {
    _cancelTimers();
    if (!_open) {
      return;
    }
    _open = false;
    // A stop/close failure only means the device is already idle.
    _bridge.send('stop $alias');
    _bridge.send('close $alias');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await stop();
    _disposed = true;
    for (final path in _files.values) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on FileSystemException catch (_) {
        // Leftover clip files are harmless and never escape this directory.
      }
    }
    _files.clear();
  }

  /// MCI volume levels run 0..1000 for 0..100%.
  static int _volumeLevel(double volume) =>
      (volume.clamp(0.0, 1.0) * 1000).round();

  void _pollFinished() {
    final mode = _bridge.query('status $alias mode');
    if (mode == null) {
      return;
    }
    final normalized = mode.trim().toLowerCase();
    if (normalized == 'stopped' || normalized == 'not ready') {
      unawaited(stop());
    }
  }

  void _cancelTimers() {
    _poll?.cancel();
    _poll = null;
    _cutoff?.cancel();
    _cutoff = null;
  }

  void _expect(String command) {
    final code = _bridge.send(command);
    if (code != 0) {
      throw AnnouncementPlaybackError(
        '"$command" failed: ${_bridge.errorText(code)}',
      );
    }
  }

  /// Writes the clip once and reuses it for later plays of the same clip.
  Future<String> _clipFile(AnnouncementClip clip) async {
    final cached = _files[clip.id];
    if (cached != null) {
      return cached;
    }
    final Uint8List bytes;
    try {
      bytes = await _loadAsset(assetPathFor(clip.id));
    } on Object catch (error) {
      throw AnnouncementPlaybackError(
        'The bundled clip "${clip.id}" could not be read: $error',
      );
    }
    if (bytes.isEmpty) {
      throw AnnouncementPlaybackError(
        'The bundled clip "${clip.id}" is empty.',
      );
    }
    final directory = Directory(
      '$_tempRoot${Platform.pathSeparator}clips-$pid',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '${clip.id}.mp3',
    );
    try {
      await directory.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (error) {
      throw AnnouncementPlaybackError(
        'The clip "${clip.id}" could not be staged at ${file.path}: '
        '${error.message}',
      );
    }
    _files[clip.id] = file.path;
    return file.path;
  }
}
