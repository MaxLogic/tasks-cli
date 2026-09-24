/// The Enrichment preview dialog (viewer/design.md sections 8 and 9).
///
/// Preview reads the clipboard once and shows both texts; it never writes. The
/// dialog has one action, Close, because replacing the clipboard is the
/// deliberate route through the Enrich clipboard command and its CLI-side
/// text-equality check.
library;

import 'package:flutter/material.dart';

import '../controllers/clipboard_controller.dart';
import 'commands.dart';
import 'dialog_scope.dart';

/// Captured scope, both texts and the counts, with Close as the only action.
class ViewerEnrichmentPreviewDialog extends StatefulWidget {
  const ViewerEnrichmentPreviewDialog({super.key, required this.preview});

  final ClipboardPreview preview;

  @override
  State<ViewerEnrichmentPreviewDialog> createState() =>
      _ViewerEnrichmentPreviewDialogState();
}

class _ViewerEnrichmentPreviewDialogState
    extends State<ViewerEnrichmentPreviewDialog> {
  late final TextEditingController _original = TextEditingController(
    text: widget.preview.original,
  );
  late final TextEditingController _result = TextEditingController(
    text: widget.preview.enrichment.text,
  );

  final FocusNode _heading = FocusNode(debugLabel: 'enrichment preview');
  final FocusNode _originalFocus = FocusNode(
    debugLabel: 'enrichment preview original',
  );
  final FocusNode _resultFocus = FocusNode(
    debugLabel: 'enrichment preview result',
  );

  @override
  void dispose() {
    _original.dispose();
    _result.dispose();
    _heading.dispose();
    _originalFocus.dispose();
    _resultFocus.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  KeyEventResult _onCommand(String id) {
    switch (id) {
      case 'enrichmentPreview.original':
        _originalFocus.requestFocus();
      case 'enrichmentPreview.result':
        _resultFocus.requestFocus();
      case 'enrichmentPreview.close':
      case 'dialogs.dismiss':
        _close();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final unknown = preview.enrichment.unknownIds;
    return DialogCommandHost(
      scope: CommandScope.enrichmentPreview,
      onCommand: _onCommand,
      child: Semantics(
        label: 'Enrichment preview',
        namesRoute: true,
        scopesRoute: true,
        explicitChildNodes: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: size.width < 360 ? size.width - 32 : 360,
              maxWidth: 720,
              maxHeight: size.height - 48,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Focus(
                    focusNode: _heading,
                    autofocus: true,
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Enrichment preview',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Project: ${preview.projectName} (${preview.projectId})',
                  ),
                  Text(
                    'Replacements: ${preview.enrichment.replacements}. '
                    'Unknown IDs: ${unknown.length}.',
                  ),
                  if (unknown.isNotEmpty)
                    Text(
                      clipboardUnknownIdsText(unknown),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _buildText(
                            key: const ValueKey<String>(
                              'enrichment-preview-original',
                            ),
                            controller: _original,
                            focusNode: _originalFocus,
                            label: 'Original clipboard text (Alt+O)',
                          ),
                          const SizedBox(height: 8),
                          _buildText(
                            key: const ValueKey<String>(
                              'enrichment-preview-result',
                            ),
                            controller: _result,
                            focusNode: _resultFocus,
                            label: 'Enriched text (Alt+R)',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Preview only. The clipboard keeps its current contents; '
                    'Enrich clipboard is the action that replaces it.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _close,
                      child: const Text('Close (Alt+C)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Read-only, labelled, selectable multiline text, as the details pane uses
  /// for a whole task body: line, word and character navigation stay reachable.
  Widget _buildText({
    required Key key,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
  }) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      readOnly: true,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
