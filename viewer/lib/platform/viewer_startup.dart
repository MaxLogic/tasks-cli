/// Desired versus effective Windows startup registration for one launch.
///
/// Contract: viewer/spec.md section 3.1. The saved `start_with_windows`
/// preference and the shortcut the shell actually holds are two independent
/// facts, so failure of one never hides the other: a registration problem is
/// reported with its own text and can be retried from Settings, while the
/// preference keeps the value the user chose.
library;

import 'package:flutter/foundation.dart';

import 'startup_registration.dart';

/// App-wide view of the one startup shortcut this application owns.
class ViewerStartupController extends ChangeNotifier {
  ViewerStartupController({required StartupRegistrar registrar})
    : _registrar = registrar, // ignore: prefer_initializing_formals
      _unavailableNote = null;

  /// Controller for a launch that must never touch the real Startup folder.
  ///
  /// Debug builds, test harnesses and `--test-mode` launches get this one, so
  /// Settings says the registration is unavailable instead of pretending a
  /// shortcut exists.
  ViewerStartupController.unavailable({String? note})
    : _registrar = null,
      _unavailableNote = note; // ignore: prefer_initializing_formals

  final StartupRegistrar? _registrar;
  final String? _unavailableNote;

  StartupRegistrationReport? _report;
  String? _failure;
  bool _busy = false;

  /// Last inspected or applied state, or null before the first attempt.
  StartupRegistrationReport? get report => _report;

  /// Wording for the last failure, independent of the desired preference.
  String? get failure => _failure ?? _report?.failure;

  /// False when this build may not change the real Startup folder.
  bool get supported => _registrar != null;

  /// True while an inspect or apply call is in flight.
  bool get busy => _busy;

  /// True when Windows/Task Manager holds a disabled entry for this app.
  bool get windowsDisabled => _report?.windowsDisabled ?? false;

  /// Effective state in one line, including what the user must do about it.
  String get summary {
    final note = _unavailableNote;
    if (!supported) {
      return note ??
          'Startup registration is applied by the packaged release. Debug and '
              'test launches never create or remove a shortcut.';
    }
    final report = _report;
    if (report == null) {
      return 'The startup shortcut has not been read yet.';
    }
    return switch (report.state) {
      StartupShortcutState.registered =>
        report.windowsDisabled == true
            ? 'Registered, but Windows currently disables this entry. Open Task '
                  'Manager, Startup apps, and enable "MaxLogic Tasks Viewer"; '
                  'the viewer never changes that setting itself.'
            : 'Registered: this user starts the viewer at sign-in from '
                  '${report.shortcutPath}.',
      StartupShortcutState.missing =>
        'No startup shortcut is registered for this user.',
      StartupShortcutState.needsUpdate =>
        'The registered shortcut is stale; saving Settings refreshes it for '
            'this copy of the viewer.',
      StartupShortcutState.foreign =>
        'A shortcut named "$viewerStartupShortcutFileName" belongs to another '
            'program. The viewer left it untouched.',
      StartupShortcutState.unreadable =>
        'The existing startup shortcut could not be read and was left '
            'untouched.',
      StartupShortcutState.unsupported =>
        'This platform has no Windows Startup folder.',
    };
  }

  /// Reads the current state; returns null when this build has no registrar.
  Future<StartupRegistrationReport?> refresh() async {
    final registrar = _registrar;
    if (registrar == null || _busy) {
      return null;
    }
    _busy = true;
    notifyListeners();
    try {
      final report = await registrar.inspect();
      _report = report;
      _failure = report.failure;
      return report;
    } on Object catch (error) {
      _failure = 'The startup shortcut could not be inspected: $error';
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Applies [desired] by creating/refreshing or removing the owned shortcut.
  ///
  /// A foreign or unreadable shortcut is reported, never overwritten. Returns
  /// null when this build has no registrar, when a call is already running or
  /// when the attempt threw.
  Future<StartupRegistrationReport?> applyDesired(bool desired) async {
    final registrar = _registrar;
    if (registrar == null || _busy) {
      return null;
    }
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final report = desired
          ? await registrar.ensureRegistered()
          : await registrar.removeOwned();
      _report = report;
      _failure = report.failure;
      return report;
    } on Object catch (error) {
      _failure = 'The startup shortcut could not be updated: $error';
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
