/// Confirmation dialog for pending crash reports in "Ask before sending" mode.
///
/// Mirrors the viewer's accessible modal conventions: named route, contained
/// focus traversal, scoped Alt access keys, read-only selectable details, and
/// Escape mapped to the safe non-sending action (Don't send).
library;

import 'package:flutter/material.dart';

import '../platform/crash_reporting.dart';
import 'commands.dart';
import 'dialog_scope.dart';
import 'viewer_icons.dart';

/// User choice returned by [ViewerCrashReportDialog].
enum CrashReportDecision { send, alwaysSend, discard }

/// Reviews one scrubbed crash report before anything is sent to Sentry.
class ViewerCrashReportDialog extends StatefulWidget {
  const ViewerCrashReportDialog({super.key, required this.report});

  final PendingCrashReport report;

  @override
  State<ViewerCrashReportDialog> createState() =>
      _ViewerCrashReportDialogState();
}

class _ViewerCrashReportDialogState extends State<ViewerCrashReportDialog> {
  late final TextEditingController _details = TextEditingController(
    text: widget.report.details,
  );
  final FocusNode _detailsFocus = FocusNode(debugLabel: 'crash report details');
  final FocusNode _sendFocus = FocusNode(debugLabel: 'crash report send');

  @override
  void dispose() {
    _details.dispose();
    _detailsFocus.dispose();
    _sendFocus.dispose();
    super.dispose();
  }

  void _close(CrashReportDecision decision) =>
      Navigator.of(context).pop(decision);

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'crashReport.details':
        _detailsFocus.requestFocus();
      case 'crashReport.send':
        _close(CrashReportDecision.send);
      case 'crashReport.alwaysSend':
        _close(CrashReportDecision.alwaysSend);
      case 'crashReport.discard':
      case 'dialogs.dismiss':
        _close(CrashReportDecision.discard);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final report = widget.report;
    final title = report.kind == PendingCrashKind.nativeMinidump
        ? 'Tasks Viewer closed unexpectedly'
        : 'Tasks Viewer encountered an error';

    return DialogCommandHost(
      scope: CommandScope.crashReport,
      onCommand: _onCommand,
      child: Semantics(
        label: title,
        namesRoute: true,
        scopesRoute: true,
        explicitChildNodes: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: size.width < 360 ? size.width - 32 : 360,
              maxWidth: 680,
              maxHeight: size.height - 48,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(ViewerIcons.bugReport),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(title, style: theme.textTheme.titleLarge),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(report.summary),
                  const SizedBox(height: 6),
                  Text(
                    'Nothing is sent unless you choose Send report or Always '
                    'send. Clipboard contents and task text are excluded from '
                    'text crash reports.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: TextField(
                        key: const ValueKey<String>('crash-report-details'),
                        controller: _details,
                        focusNode: _detailsFocus,
                        readOnly: true,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          labelText: 'Scrubbed crash details (Alt+I)',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton.icon(
                        onPressed: () => _close(CrashReportDecision.discard),
                        icon: const Icon(ViewerIcons.close),
                        label: const Text("Don't send (Alt+D)"),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _close(CrashReportDecision.alwaysSend),
                        icon: const Icon(ViewerIcons.check),
                        label: const Text('Always send (Alt+A)'),
                      ),
                      FilledButton.icon(
                        focusNode: _sendFocus,
                        autofocus: true,
                        onPressed: () => _close(CrashReportDecision.send),
                        icon: const Icon(ViewerIcons.send),
                        label: const Text('Send report (Alt+S)'),
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
