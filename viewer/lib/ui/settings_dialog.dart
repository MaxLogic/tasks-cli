/// Settings (design.md section 9, spec.md section 3).
///
/// Every control carries its scoped Alt access key in its own label, and the
/// dialog returns a [ViewerSettingsDraft] only when Save succeeds. Startup
/// registration itself is a packaged-release concern; this dialog records the
/// desired state and says so instead of pretending a shortcut exists.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_environment.dart';
import '../controllers/announcement_controller.dart';
import '../data/cli_client.dart';
import '../data/models.dart';
import '../data/settings_draft.dart';
import '../platform/viewer_startup.dart';
import 'commands.dart';
import 'dialog_scope.dart';

typedef SettingsConnectionTester = Future<ViewerInfo> Function(String cliPath);

/// Settings and first-run setup form.
///
/// It pops with the edited draft on Save and null on Cancel. Every visible
/// field is reachable by Tab and has a semantic label; the dialog also names
/// its route so a screen reader announces the modal context when it opens.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.environment,
    required this.announcements,
    required this.initial,
    this.startup,
    this.firstSetup = false,
    this.connectionTester,
  });

  final ViewerEnvironment environment;
  final AnnouncementController announcements;
  final ViewerSettingsDraft initial;
  final bool firstSetup;
  final SettingsConnectionTester? connectionTester;

  /// Startup registration surface; null when this build must not touch the
  /// real Startup folder.
  final ViewerStartupController? startup;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _cliPath = TextEditingController(
    text: widget.initial.cliPath ?? widget.environment.tasksExe ?? '',
  );
  late final TextEditingController _dataRoot = TextEditingController(
    text: widget.initial.dataRoot ?? widget.environment.dataRoot ?? '',
  );
  late final TextEditingController _projectsWidth = TextEditingController(
    text: '${widget.initial.projectsPanePercent}',
  );
  late final TextEditingController _tasksWidth = TextEditingController(
    text: '${widget.initial.tasksPanePercent}',
  );
  late final TextEditingController _detailsWidth = TextEditingController(
    text: '${widget.initial.detailsPanePercent}',
  );

  final FocusNode _cliNode = FocusNode(debugLabel: 'settings cli path');
  final FocusNode _dataRootNode = FocusNode(debugLabel: 'settings data root');
  final FocusNode _themeNode = FocusNode(debugLabel: 'settings theme');
  final FocusNode _textSizeNode = FocusNode(debugLabel: 'settings text size');
  final FocusNode _projectsWidthNode = FocusNode(
    debugLabel: 'settings projects width',
  );
  final FocusNode _tasksWidthNode = FocusNode(
    debugLabel: 'settings tasks width',
  );
  final FocusNode _detailsWidthNode = FocusNode(
    debugLabel: 'settings details width',
  );
  final FocusNode _startupNode = FocusNode(debugLabel: 'settings startup');
  final FocusNode _modeNode = FocusNode(debugLabel: 'settings announcements');
  final FocusNode _volumeNode = FocusNode(debugLabel: 'settings volume');

  late ViewerThemeMode _theme = widget.initial.themeMode;
  late int _textScale = widget.initial.textScalePercent;
  late bool _startWithWindows = widget.initial.startWithWindows;
  late AnnouncementMode _mode = widget.initial.announcementMode;
  late int _volume = widget.initial.bellaVolumePercent;
  String? _error;
  String? _connectionStatus;
  bool _testingConnection = false;

  @override
  void dispose() {
    _cliPath.dispose();
    _dataRoot.dispose();
    _projectsWidth.dispose();
    _tasksWidth.dispose();
    _detailsWidth.dispose();
    _cliNode.dispose();
    _dataRootNode.dispose();
    _themeNode.dispose();
    _textSizeNode.dispose();
    _projectsWidthNode.dispose();
    _tasksWidthNode.dispose();
    _detailsWidthNode.dispose();
    _startupNode.dispose();
    _modeNode.dispose();
    _volumeNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final startup = widget.startup;
    if (startup != null) {
      unawaited(startup.refresh());
    }
  }

  void _close(ViewerSettingsDraft? result) => Navigator.of(context).pop(result);

  void _fail(String message, FocusNode field) {
    setState(() => _error = message);
    widget.announcements.announceStatus(message, dynamic: true);
    field.requestFocus();
  }

  void _save() {
    final cliPath = _cliPath.text.trim();
    final dataRoot = _dataRoot.text.trim();
    if (widget.firstSetup && cliPath.isEmpty) {
      _fail('Choose the packaged tasks.exe or enter its full path.', _cliNode);
      return;
    }
    if (widget.firstSetup && dataRoot.isEmpty) {
      _fail(
        'Choose the standard task store or enter its full path.',
        _dataRootNode,
      );
      return;
    }
    if (cliPath.isNotEmpty && !_looksAbsolute(cliPath)) {
      _fail('The CLI path must be an absolute Windows path.', _cliNode);
      return;
    }
    if (dataRoot.isNotEmpty && !_looksAbsolute(dataRoot)) {
      _fail('The data root must be an absolute Windows path.', _dataRootNode);
      return;
    }
    final projects = int.tryParse(_projectsWidth.text.trim());
    final tasks = int.tryParse(_tasksWidth.text.trim());
    final details = int.tryParse(_detailsWidth.text.trim());
    if (projects == null || tasks == null || details == null) {
      _fail('Pane widths must be whole percentages.', _projectsWidthNode);
      return;
    }
    for (final width in <int>[projects, tasks, details]) {
      if (width < 10 || width > 60) {
        _fail(
          'Each pane width must be between 10 and 60 percent.',
          _projectsWidthNode,
        );
        return;
      }
    }
    if (projects + tasks + details > 100) {
      _fail(
        'Pane widths must add up to 100 percent or less.',
        _detailsWidthNode,
      );
      return;
    }
    final draft = ViewerSettingsDraft(
      cliPath: cliPath.isEmpty ? null : cliPath,
      dataRoot: dataRoot.isEmpty ? null : dataRoot,
      themeMode: _theme,
      textScalePercent: _textScale,
      projectsPanePercent: projects,
      tasksPanePercent: tasks,
      detailsPanePercent: details,
      startWithWindows: _startWithWindows,
      announcementMode: _mode,
      bellaVolumePercent: _volume,
    );
    widget.announcements.setMode(_mode);
    widget.announcements.setVolume(draft.bellaVolume);
    _close(draft);
  }

  void _testVoice() {
    widget.announcements.announceStatus(
      'This is Bella. Spoken announcements are enabled.',
      clipId: 'voice_test',
    );
  }

  void _useBundledCli() {
    final path = widget.environment.tasksExe;
    if (path == null) {
      _fail(
        'No packaged tasks.exe was found beside the viewer. Enter its full path.',
        _cliNode,
      );
      return;
    }
    setState(() {
      _cliPath.text = path;
      _error = null;
    });
    _cliNode.requestFocus();
  }

  void _useStandardDataRoot() {
    setState(() {
      _dataRoot.text = ViewerEnvironment.defaultDataRoot();
      _error = null;
    });
    _dataRootNode.requestFocus();
  }

  Future<ViewerInfo> _probe(String cliPath) {
    final environment = widget.environment.withPaths(
      dataRoot: _dataRoot.text.trim().isEmpty ? null : _dataRoot.text.trim(),
      tasksExe: cliPath,
    );
    return ViewerCliClient(environment: environment).probe(force: true);
  }

  Future<void> _testConnection() async {
    if (_testingConnection) {
      return;
    }
    final cliPath = _cliPath.text.trim();
    if (cliPath.isEmpty) {
      _fail('Enter the full path to tasks.exe before testing.', _cliNode);
      return;
    }
    if (!_looksAbsolute(cliPath)) {
      _fail('The CLI path must be an absolute Windows path.', _cliNode);
      return;
    }
    setState(() {
      _testingConnection = true;
      _error = null;
      _connectionStatus = 'Testing the Tasks CLI connection.';
    });
    try {
      final info = await (widget.connectionTester ?? _probe)(cliPath);
      if (!mounted) {
        return;
      }
      final message =
          'Connection succeeded. Protocol version ${info.protocolVersion}.';
      setState(() => _connectionStatus = message);
      widget.announcements.announceStatus(message, dynamic: true);
    } on ViewerFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _fail('Connection failed: ${failure.message}', _cliNode);
      setState(() => _connectionStatus = null);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _fail('Connection failed: $error', _cliNode);
      setState(() => _connectionStatus = null);
    } finally {
      if (mounted) {
        setState(() => _testingConnection = false);
      }
    }
  }

  /// Reports the effective registration separately from the preference.
  ///
  /// A conflict, a policy-disabled entry or a failed write keeps the Retry
  /// action visible until the state is repaired (spec.md section 3.1).
  Widget _buildStartupStatus(BuildContext context) {
    final startup = widget.startup;
    final small = Theme.of(context).textTheme.bodySmall;
    if (startup == null) {
      return Text(
        'Startup registration is applied by the packaged release. Debug and '
        'test launches never create or remove a shortcut.',
        style: small,
      );
    }
    return ListenableBuilder(
      listenable: startup,
      builder: (context, _) {
        final failure = startup.failure;
        final needsAction =
            failure != null || startup.report?.needsUserAction == true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(startup.summary, style: small),
            if (failure != null) ...<Widget>[
              const SizedBox(height: 4),
              Semantics(
                liveRegion: true,
                child: Text(
                  failure,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            if (needsAction)
              TextButton(
                onPressed: startup.busy
                    ? null
                    : () => unawaited(startup.applyDesired(_startWithWindows)),
                child: const Text('Retry registration (Alt+G)'),
              ),
          ],
        );
      },
    );
  }

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'settings.cliPath':
        _cliNode.requestFocus();
      case 'settings.dataRoot':
        _dataRootNode.requestFocus();
      case 'settings.browseCli':
        _useBundledCli();
      case 'settings.browseRoot':
        _useStandardDataRoot();
      case 'settings.testConnection':
        unawaited(_testConnection());
      case 'settings.theme':
        _themeNode.requestFocus();
      case 'settings.textSize':
        _textSizeNode.requestFocus();
      case 'settings.projectsWidth':
        _projectsWidthNode.requestFocus();
      case 'settings.tasksWidth':
        _tasksWidthNode.requestFocus();
      case 'settings.detailsWidth':
        _detailsWidthNode.requestFocus();
      case 'settings.startWithWindows':
        _startupNode.requestFocus();
      case 'settings.announcementMode':
        _modeNode.requestFocus();
      case 'settings.bellaVolume':
        _volumeNode.requestFocus();
      case 'settings.save':
        _save();
      case 'settings.cancel':
      case 'dialogs.dismiss':
        _close(null);
      case 'settings.testVoice':
        _testVoice();
      case 'settings.retryStartup':
        unawaited(widget.startup?.applyDesired(_startWithWindows));
      case 'settings.resetLayout':
        setState(() {
          _projectsWidth.text = '22';
          _tasksWidth.text = '33';
          _detailsWidth.text = '45';
        });
      default:
        break;
    }
    return KeyEventResult.handled;
  }

  static bool _looksAbsolute(String value) {
    if (value.startsWith(r'\\')) {
      return value.length > 2;
    }
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final title = widget.firstSetup ? 'Set up Tasks Viewer' : 'Settings';
    return DialogCommandHost(
      scope: CommandScope.settings,
      onCommand: _onCommand,
      // The dialog surface itself: it supplies the Material ancestor the text
      // fields need and clips the scroll view to the current window.
      child: Semantics(
        label: title,
        namesRoute: true,
        scopesRoute: true,
        explicitChildNodes: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.min(420, math.max(280, size.width - 48)),
              maxWidth: math.max(280, math.min(760, size.width - 48)),
              maxHeight: math.max(240, math.min(720, size.height - 96)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (widget.firstSetup) ...<Widget>[
                            const Text(
                              'The data root contains the project registry and '
                              'project databases. It is not one project folder. '
                              'The Tasks CLI path points to the matching '
                              'tasks.exe. The viewer reads an existing store and '
                              'never creates or migrates one.',
                            ),
                            const SizedBox(height: 16),
                          ],
                          Semantics(
                            header: true,
                            child: Text(
                              'Task data connection',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _cliPath,
                            focusNode: _cliNode,
                            // design.md section 8: Settings opens on its first
                            // setting, which also keeps the dialog's Alt access
                            // keys reachable before the first Tab.
                            autofocus:
                                !widget.firstSetup || _cliPath.text.isEmpty,
                            decoration: const InputDecoration(
                              labelText: 'Tasks CLI path (Alt+E)',
                              helperText:
                                  'Full path to the tasks.exe from the same '
                                  'release as this viewer.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _useBundledCli,
                              child: const Text('Use packaged CLI (Alt+B)'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _dataRoot,
                            focusNode: _dataRootNode,
                            autofocus:
                                widget.firstSetup &&
                                _cliPath.text.isNotEmpty &&
                                _dataRoot.text.isEmpty,
                            decoration: const InputDecoration(
                              labelText: 'Data root (Alt+D)',
                              helperText:
                                  'Folder containing registry.json and the '
                                  'project database files.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _useStandardDataRoot,
                              child: const Text(
                                'Use standard task store (Alt+O)',
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _testingConnection
                                  ? null
                                  : () => unawaited(_testConnection()),
                              child: Text(
                                _testingConnection
                                    ? 'Testing connection'
                                    : 'Test connection (Alt+T)',
                              ),
                            ),
                          ),
                          if (_connectionStatus != null)
                            Semantics(
                              liveRegion: true,
                              child: Text(_connectionStatus!),
                            ),
                          const Divider(height: 24),
                          Semantics(
                            header: true,
                            child: Text(
                              'Appearance and layout',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<ViewerThemeMode>(
                            initialValue: _theme,
                            focusNode: _themeNode,
                            decoration: const InputDecoration(
                              labelText: 'Theme (Alt+H)',
                              border: OutlineInputBorder(),
                            ),
                            items: const <DropdownMenuItem<ViewerThemeMode>>[
                              DropdownMenuItem<ViewerThemeMode>(
                                value: ViewerThemeMode.system,
                                child: Text('Follow Windows'),
                              ),
                              DropdownMenuItem<ViewerThemeMode>(
                                value: ViewerThemeMode.light,
                                child: Text('Light'),
                              ),
                              DropdownMenuItem<ViewerThemeMode>(
                                value: ViewerThemeMode.dark,
                                child: Text('Dark'),
                              ),
                              DropdownMenuItem<ViewerThemeMode>(
                                value: ViewerThemeMode.highContrastLight,
                                child: Text('High contrast light'),
                              ),
                              DropdownMenuItem<ViewerThemeMode>(
                                value: ViewerThemeMode.highContrastDark,
                                child: Text('High contrast dark'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _theme = value ?? _theme),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<int>(
                            initialValue: _textScale,
                            focusNode: _textSizeNode,
                            decoration: const InputDecoration(
                              labelText: 'Text size (Alt+Z)',
                              border: OutlineInputBorder(),
                            ),
                            items: <DropdownMenuItem<int>>[
                              for (final percent
                                  in viewerTextScalePercentChoices)
                                DropdownMenuItem<int>(
                                  value: percent,
                                  child: Text('$percent%'),
                                ),
                            ],
                            onChanged: (value) => setState(
                              () => _textScale = value ?? _textScale,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Pane widths',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: <Widget>[
                              SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _projectsWidth,
                                  focusNode: _projectsWidthNode,
                                  decoration: const InputDecoration(
                                    labelText: 'Projects % (Alt+P)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _tasksWidth,
                                  focusNode: _tasksWidthNode,
                                  decoration: const InputDecoration(
                                    labelText: 'Tasks % (Alt+K)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _detailsWidth,
                                  focusNode: _detailsWidthNode,
                                  decoration: const InputDecoration(
                                    labelText: 'Details % (Alt+I)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () =>
                                  _onCommand('settings.resetLayout'),
                              child: const Text('Reset layout (Alt+R)'),
                            ),
                          ),
                          const Divider(height: 24),
                          Semantics(
                            header: true,
                            child: Text(
                              'Windows startup',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          SwitchListTile(
                            value: _startWithWindows,
                            focusNode: _startupNode,
                            onChanged: (value) =>
                                setState(() => _startWithWindows = value),
                            title: const Text('Start with Windows (Alt+W)'),
                            subtitle: const Text(
                              'Applied when Settings is saved. The viewer owns '
                              'one shortcut and never overwrites another '
                              'program.',
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 16, top: 4),
                            child: _buildStartupStatus(context),
                          ),
                          const SizedBox(height: 8),
                          Semantics(
                            header: true,
                            child: Text(
                              'Announcements',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<AnnouncementMode>(
                            initialValue: _mode,
                            focusNode: _modeNode,
                            decoration: const InputDecoration(
                              labelText: 'Announcements (Alt+A)',
                              border: OutlineInputBorder(),
                            ),
                            items: const <DropdownMenuItem<AnnouncementMode>>[
                              DropdownMenuItem<AnnouncementMode>(
                                value: AnnouncementMode.bella,
                                child: Text('Bella clips'),
                              ),
                              DropdownMenuItem<AnnouncementMode>(
                                value: AnnouncementMode.nvdaOnly,
                                child: Text('Screen reader only'),
                              ),
                              DropdownMenuItem<AnnouncementMode>(
                                value: AnnouncementMode.off,
                                child: Text('Off'),
                              ),
                            ],
                            onChanged: (value) {
                              setState(() => _mode = value ?? _mode);
                              if (value != null) {
                                widget.announcements.setMode(value);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          Text('Bella volume (Alt+V): $_volume%'),
                          Slider(
                            focusNode: _volumeNode,
                            value: _volume.toDouble(),
                            min: 0,
                            max: 100,
                            divisions: 10,
                            label: '$_volume%',
                            onChanged: (value) {
                              final stepped = (value / 10).round() * 10;
                              setState(() => _volume = stepped);
                              widget.announcements.setVolume(stepped / 100);
                            },
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _testVoice,
                              child: const Text('Test voice (Alt+Y)'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Settings are stored under '
                            '${widget.environment.settingsRoot} and are applied '
                            'when you save them.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_error != null) ...<Widget>[
                            const SizedBox(height: 12),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => _close(null),
                        child: const Text('Cancel (Alt+C)'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _save,
                        child: Text(
                          widget.firstSetup
                              ? 'Save and continue (Ctrl+S)'
                              : 'Save (Ctrl+S)',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
