/// Routes fixed app feedback to a bundled Bella clip or to exactly one live
/// NVDA announcement channel (viewer/spec.md section 9.1).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'announcement_catalog.dart';

/// Announcement mode chosen in Settings.
enum AnnouncementMode { bella, nvdaOnly, off }

/// Playback surface for bundled announcement clips. Implementations are
/// injected so tests never touch real audio.
abstract class ClipPlayer {
  Future<void> play(AnnouncementClip clip, {required double volume});

  Future<void> stop();

  Future<void> dispose();
}

/// Player used until the packaged audio pipeline is wired (slice 7) and by
/// headless runs where no audio device may be touched.
class SilentClipPlayer implements ClipPlayer {
  @override
  Future<void> play(AnnouncementClip clip, {required double volume}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// One announcement controller for the whole application.
class AnnouncementController extends ChangeNotifier {
  AnnouncementController({
    required ClipPlayer clipPlayer,
    AnnouncementCatalog? catalog,
    AnnouncementMode mode = AnnouncementMode.bella,
    double volume = 0.7,
    Duration progressDelay = const Duration(milliseconds: 500),
  }) : _clipPlayer = clipPlayer, // ignore: prefer_initializing_formals
       // Private fields cannot be named parameters, so the lint cannot apply.
       _catalog = catalog, // ignore: prefer_initializing_formals
       _mode = mode, // ignore: prefer_initializing_formals
       _volume = volume, // ignore: prefer_initializing_formals
       _progressDelay = progressDelay; // ignore: prefer_initializing_formals

  final ClipPlayer _clipPlayer;
  final AnnouncementCatalog? _catalog;
  final Duration _progressDelay;

  AnnouncementMode _mode;
  double _volume;
  String _statusText = '';
  String? _liveRegionText;
  int _liveRegionRevision = 0;
  String? _progressText;
  Timer? _progressTimer;
  final List<String> _audioWarnings = <String>[];

  AnnouncementMode get mode => _mode;
  double get volume => _volume;

  /// Full, focusable status text. Always readable, never truncated and never
  /// spoken implicitly.
  String get statusText => _statusText;

  /// Text exposed through the single live announcement channel, or null when
  /// the current event must stay non-live (Bella clip played, or Off).
  String? get liveRegionText => _liveRegionText;

  /// Bumped whenever the live region content changes, including a repeat of the
  /// same text, so the platform live region fires exactly once per event.
  int get liveRegionRevision => _liveRegionRevision;

  /// Persistent audio problems the user must be able to read and act on.
  List<String> get audioWarnings => List.unmodifiable(_audioWarnings);

  bool get hasPendingProgress => _progressTimer != null;

  void setMode(AnnouncementMode mode) {
    if (_mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    if (clamped == _volume) {
      return;
    }
    _volume = clamped;
    notifyListeners();
  }

  /// Final outcome for an operation.
  ///
  /// [clipId] names a fixed catalog phrase: in Bella mode the clip is played and
  /// the status text stays non-live. Dynamic errors, validation details and
  /// NVDA-only mode use exactly one live announcement instead.
  void announceStatus(String text, {String? clipId, bool dynamic = false}) {
    _statusText = text;
    _cancelProgress();
    if (_mode == AnnouncementMode.off) {
      _liveRegionText = null;
      notifyListeners();
      return;
    }
    final clip = clipId == null ? null : _catalog?.clip(clipId);
    if (_mode == AnnouncementMode.bella && !dynamic && clip != null) {
      _liveRegionText = null;
      unawaited(_play(clip, fallbackText: text));
      notifyListeners();
      return;
    }
    _setLive(text);
    notifyListeners();
  }

  /// Coalesced progress feedback: only announced when the operation is still
  /// running after the configured delay.
  void announceProgress(String text, {String? clipId}) {
    _statusText = text;
    _progressText = text;
    _progressTimer?.cancel();
    _progressTimer = Timer(_progressDelay, () {
      _progressTimer = null;
      final pending = _progressText;
      if (pending == null) {
        return;
      }
      if (_mode == AnnouncementMode.off) {
        notifyListeners();
        return;
      }
      final clip = clipId == null ? null : _catalog?.clip(clipId);
      if (_mode == AnnouncementMode.bella && clip != null) {
        _liveRegionText = null;
        unawaited(_play(clip, fallbackText: pending));
      } else {
        _setLive(pending);
      }
      notifyListeners();
    });
  }

  /// Cancels pending progress feedback when the final result arrives first.
  void _cancelProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _progressText = null;
  }

  void _setLive(String text) {
    _liveRegionText = text;
    _liveRegionRevision++;
  }

  Future<void> _play(
    AnnouncementClip clip, {
    required String fallbackText,
  }) async {
    try {
      await _clipPlayer.play(clip, volume: _volume);
    } on Object catch (error) {
      _audioWarnings.add(
        'Could not play announcement "${clip.id}": $error. '
        'Spoken feedback fell back to the screen reader.',
      );
      _setLive(fallbackText);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _progressTimer = null;
    unawaited(_clipPlayer.dispose());
    super.dispose();
  }
}
