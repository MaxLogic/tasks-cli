import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/attachment_controller.dart';
import '../controllers/editor_controller.dart';
import '../data/models.dart';
import '../data/editor_models.dart';
import '../data/settings_draft.dart';
import 'editor_dialogs.dart';
import 'dialog_scope.dart';
import 'viewer_icons.dart';
import 'viewer_motion.dart';
import 'commands.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'attachment_preview_dialog.dart';
import 'viewer_format.dart';

String attachmentClipboardDescription(AttachmentClipboard clip) => [
  ...clip.items.map(
    (i) =>
        '${i['name']}, ${i['kind']}, ${attachmentSizeLabel(i['original_size']! as int)}',
  ),
  ...clip.skipped.map((i) => 'Skipped ${i['path']}: ${i['reason']}'),
].join('\n');

Future<bool> confirmAttachmentPaste(
  ViewerShellApi api,
  TaskDetail task,
  AttachmentClipboard clip, {
  VoidCallback? onSkip,
}) async {
  if (!api.settings.confirmationEnabled(ViewerConfirmation.attachmentPaste)) {
    return true;
  }
  return await api.showModal<bool>(
        CommandScope.attachmentAttach,
        (_) => AttachmentConfirmationDialog(
          title: 'Attach to ${task.canonicalId}?',
          accept: 'Attach (Alt+A)',
          content: attachmentClipboardDescription(clip),
          onSkip: () {
            api.setConfirmationEnabled(
              ViewerConfirmation.attachmentPaste,
              false,
            );
            onSkip?.call();
          },
        ),
      ) ??
      false;
}

class AttachmentConfirmationDialog extends StatefulWidget {
  const AttachmentConfirmationDialog({
    super.key,
    required this.title,
    required this.content,
    required this.accept,
    this.cancelDefault = false,
    this.acceptIcon = ViewerIcons.attach,
    this.onSkip,
  });
  final String title, content, accept;
  final bool cancelDefault;
  final IconData acceptIcon;
  final VoidCallback? onSkip;
  @override
  State<AttachmentConfirmationDialog> createState() =>
      _AttachmentConfirmationDialogState();
}

class _AttachmentConfirmationDialogState
    extends State<AttachmentConfirmationDialog> {
  bool _skip = false;
  final _skipFocus = FocusNode(debugLabel: 'Skip attachment confirmation');
  @override
  void dispose() {
    _skipFocus.dispose();
    super.dispose();
  }

  void _accept() {
    if (_skip) widget.onSkip?.call();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.pop(context, false),
      const SingleActivator(LogicalKeyboardKey.keyC, alt: true): () =>
          Navigator.pop(context, false),
      SingleActivator(
        widget.cancelDefault
            ? LogicalKeyboardKey.keyD
            : LogicalKeyboardKey.keyA,
        alt: true,
      ): () =>
          _accept(),
      if (widget.onSkip != null)
        const SingleActivator(LogicalKeyboardKey.keyG, alt: true): () {
          setState(() => _skip = !_skip);
          _skipFocus.requestFocus();
        },
    },
    child: AttachmentDialogFrame(
      title: widget.title,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(widget.content),
            if (widget.onSkip != null)
              CheckboxListTile(
                focusNode: _skipFocus,
                title: const Text("Don't show this again (Alt+G)"),
                subtitle: const Text(
                  'Re-enable this confirmation in Settings > Confirmations.',
                ),
                value: _skip,
                onChanged: (value) => setState(() => _skip = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          autofocus: !widget.cancelDefault,
          onPressed: _accept,
          icon: Icon(widget.acceptIcon),
          label: Text(widget.accept),
        ),
        TextButton.icon(
          autofocus: widget.cancelDefault,
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(ViewerIcons.close),
          label: const Text('Cancel (Alt+C)'),
        ),
      ],
    ),
  );
}

class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({super.key, required this.controller, this.api});
  final AttachmentController controller;
  final ViewerShellApi? api;
  @override
  State<AttachmentPanel> createState() => AttachmentPanelState();
}

class AttachmentPanelState extends State<AttachmentPanel> {
  final list = VirtualListController();
  AttachmentController get c => widget.controller;
  // selectedIndex is the retained focus/activation row in multi-select mode,
  // even when Ctrl+click deselected it. View, double-click and Save as use it.
  AttachmentSummary? get item {
    final selected = list.selectedIndex;
    return selected != null &&
            selected >= 0 &&
            selected < c.task.attachments.length
        ? c.task.attachments[selected]
        : null;
  }

  bool _selectionRebuildPending = false;
  // The list clamps its own selection during child layout. Re-read it after
  // controller/parent updates so action enabled states use that same index.
  void _afterListUpdate() {
    if (_selectionRebuildPending) return;
    _selectionRebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionRebuildPending = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    c.addListener(_afterListUpdate);
    _afterListUpdate();
  }

  @override
  void didUpdateWidget(covariant AttachmentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_afterListUpdate);
      c.addListener(_afterListUpdate);
    }
    _afterListUpdate();
  }

  void focusList() => list.focusRegion();
  Future<T?> _showModal<T>(Widget dialog, CommandScope scope) async {
    ModalRoute<T>? route;
    Widget buildDialog(BuildContext dialogContext) {
      route = ModalRoute.of<T>(dialogContext);
      return dialog;
    }

    final api = widget.api;
    final T? result;
    if (api != null) {
      result = await api.showModal<T>(scope, buildDialog);
    } else {
      result = await showDialog<T>(
        context: context,
        barrierDismissible: false,
        animationStyle: viewerDialogAnimationStyle(context),
        builder: (dialogContext) => DialogCommandHost(
          scope: scope,
          onCommand: (id) {
            if (id == 'dialogs.dismiss') Navigator.pop(dialogContext);
            return KeyEventResult.handled;
          },
          child: buildDialog(dialogContext),
        ),
      );
    }
    // Route teardown restores the old button focus. Restore list focus afterwards.
    await route?.completed;
    return result;
  }

  Future<bool> _confirm(Widget dialog, CommandScope scope) async =>
      await _showModal<bool>(dialog, scope) ?? false;
  Future<void> paste() => c.paste(
    (clip) => widget.api != null
        ? confirmAttachmentPaste(
            widget.api!,
            c.task,
            clip,
            onSkip: c.confirmationWasSkipped,
          )
        : _confirm(
            AttachmentConfirmationDialog(
              title: 'Attach to ${c.task.canonicalId}?',
              accept: 'Attach (Alt+A)',
              content: attachmentClipboardDescription(clip),
            ),
            CommandScope.attachmentAttach,
          ),
  );
  Future<void> detach() async {
    final returnToList = list.hasListFocus;
    final previousFocus = FocusManager.instance.primaryFocus;
    final before = List<AttachmentSummary>.of(c.task.attachments);
    final indices = list.selectedIndices.toList()..sort();
    final selected = [for (final i in indices) before[i]];
    final focused = list.selectedIndex ?? 0;
    if (selected.isEmpty) {
      c.noSelection();
      return;
    }
    final succeeded = await c.detachMany(
      selected,
      () =>
          widget.api?.settings.confirmationEnabled(
                ViewerConfirmation.attachmentDetach,
              ) ==
              false
          ? Future.value(true)
          : _confirm(
              AttachmentConfirmationDialog(
                title: selected.length == 1
                    ? 'Detach ${selected.single.name} from ${c.task.canonicalId}?'
                    : 'Detach ${selected.length} attachments?',
                content: selected.length == 1
                    ? "The file stays in the backlog's history."
                    : '${selected.map((item) => item.name).join('\n')}\n\nThe files stay in the backlog\'s history.',
                accept: 'Detach (Alt+D)',
                acceptIcon: ViewerIcons.detach,
                cancelDefault: true,
                onSkip: widget.api == null
                    ? null
                    : () {
                        widget.api!.setConfirmationEnabled(
                          ViewerConfirmation.attachmentDetach,
                          false,
                        );
                        c.confirmationWasSkipped();
                      },
              ),
              CommandScope.attachmentDetach,
            ),
    );
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (succeeded) {
        // Compare original positions so removing rows before the focused row
        // does not turn an adjacent survivor into an unrelated index jump.
        final remaining = c.task.attachments;
        int? nearest;
        var distance = before.length + 1;
        for (var i = 0; i < remaining.length; i++) {
          final old = before.indexWhere((item) => item.id == remaining[i].id);
          final gap = old < 0 ? before.length : (old - focused).abs();
          if (gap < distance || (gap == distance && old >= focused)) {
            distance = gap;
            nearest = i;
          }
        }
        list.selectIndex(nearest);
        if (nearest != null) list.goToIndex(nearest);
        list.focusRegion();
      } else if (returnToList) {
        list.focusRegion();
      } else if (previousFocus?.canRequestFocus == true) {
        previousFocus!.requestFocus();
      }
    });
  }

  Future<void> view() async {
    final current = item;
    if (current == null) {
      c.noSelection();
      return;
    }
    final path = await c.materialize(current);
    if (path == null || !mounted) return;
    await _showModal<void>(
      AttachmentPreviewDialog(
        item: current,
        path: path,
        announce: c.announce,
        onSaveAs: () => c.saveAs(current),
        saveNotice: () => c.notice,
      ),
      CommandScope.attachmentPreview,
    );
  }

  String rowLabel(BuildContext context, AttachmentSummary item) =>
      '${item.name}, ${item.kind}, ${item.mediaType}, ${item.sizeLabel}, added ${viewerTimestamp(context, item.addedMs)}';

  @override
  void dispose() {
    c.removeListener(_afterListUpdate);
    list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            unawaited(paste()),
        const SingleActivator(LogicalKeyboardKey.keyA, alt: true): focusList,
        const SingleActivator(LogicalKeyboardKey.keyF, alt: true): () =>
            unawaited(c.addFiles()),
        const SingleActivator(LogicalKeyboardKey.keyU, alt: true): () =>
            unawaited(paste()),
        const SingleActivator(LogicalKeyboardKey.keyW, alt: true): () =>
            unawaited(view()),
        const SingleActivator(LogicalKeyboardKey.keyS, alt: true): () {
          if (item case final current?) {
            unawaited(c.saveAs(current));
          } else {
            c.noSelection();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyX, alt: true): () =>
            unawaited(detach()),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: c.addFiles,
                icon: const Icon(ViewerIcons.attach),
                label: const Text('Add files (Alt+F)'),
              ),
              TextButton.icon(
                onPressed: paste,
                icon: const Icon(ViewerIcons.paste),
                label: const Text('Paste (Alt+U)'),
              ),
              TextButton.icon(
                onPressed: view,
                icon: const Icon(ViewerIcons.view),
                label: const Text('View (Alt+W)'),
              ),
              TextButton.icon(
                onPressed: () {
                  if (item case final current?) {
                    unawaited(c.saveAs(current));
                  } else {
                    c.noSelection();
                  }
                },
                icon: const Icon(ViewerIcons.saveAs),
                label: const Text('Save as (Alt+S)'),
              ),
              Tooltip(
                message:
                    'Detach selected attachments (Delete on the attachment list)',
                child: Semantics(
                  hint:
                      'Delete also detaches the selected attachments from the list',
                  child: TextButton.icon(
                    onPressed: detach,
                    icon: const Icon(ViewerIcons.detach),
                    label: const Text('Detach (Alt+X)'),
                  ),
                ),
              ),
            ],
          ),
          if (c.disabledReason != null) Text(c.disabledReason!),
          if (c.notice != null) Text(c.notice!),
          if (c.clipboardRetryAvailable)
            TextButton(
              onPressed: c.enabled ? paste : null,
              child: const Text('Retry clipboard'),
            ),
          if (c.pendingRequestId != null)
            TextButton.icon(
              onPressed: c.busy ? null : c.recover,
              icon: const Icon(ViewerIcons.sync),
              label: const Text('Check pending change'),
            ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.delete,
                  includeRepeats: false,
                ): () =>
                    unawaited(detach()),
              },
              child: AccessibleVirtualList(
                controller: list,
                multiSelect: true,
                onSelectionChanged: (selected) => c.announce(
                  '${selected.length} ${selected.length == 1 ? 'attachment' : 'attachments'} selected',
                ),
                itemCount: c.task.attachments.length,
                motionKey: ListMotionKey(
                  scope: c.task.canonicalId,
                  epoch: c.task.attachments,
                ),
                itemExtent: 64,
                listLabel:
                    'Attachments (Alt+A). Delete detaches the selected attachments',
                emptyLabel:
                    'No attachments. Add files (Alt+F) or paste an image or files (Ctrl+V).',
                itemKeyBuilder: (i) => ValueKey(c.task.attachments[i].id),
                rowSemanticsBuilder: (i) => AccessibleRowSemantics(
                  label: rowLabel(context, c.task.attachments[i]),
                ),
                rowBuilder: (context, i, selected) => Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(rowLabel(context, c.task.attachments[i])),
                ),
                onSelectedIndexChanged: (_) => setState(() {}),
                activateOnDoubleTap: true,
                onActivate: (_) => unawaited(view()),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class AttachmentOnlyConflictDialog extends StatelessWidget {
  const AttachmentOnlyConflictDialog({super.key, required this.conflict});
  final EditorConflict conflict;
  KeyEventResult _onCommand(BuildContext context, String id) {
    final result = switch (id) {
      'conflict.reloadAndDiscard' => EditorConflictDecision.reloadAndDiscard,
      'conflict.review' => EditorConflictDecision.review,
      'conflict.returnToEditor' ||
      'dialogs.dismiss' => EditorConflictDecision.returnToEditor,
      _ => null,
    };
    if (result == null) {
      return KeyEventResult.ignored;
    }
    Navigator.pop(context, result);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    // Bind only choices owned here. A nested CommandAction would shadow the
    // shell's Help action even when this handler returned ignored.
    bindings: {
      for (final spec in commandRegistry.where(
        (spec) => const {
          'conflict.returnToEditor',
          'conflict.reloadAndDiscard',
          'conflict.review',
          'dialogs.dismiss',
        }.contains(spec.id),
      ))
        for (final activator in spec.activators)
          activator: () => _onCommand(context, spec.id),
    },
    child: AttachmentDialogFrame(
      title: 'Version conflict',
      content: const Text('Only attachments changed since you started editing'),
      actions: [
        TextButton.icon(
          autofocus: true,
          onPressed: () =>
              Navigator.pop(context, EditorConflictDecision.returnToEditor),
          icon: const Icon(ViewerIcons.returnToEditor),
          label: const Text('Return to editor (Alt+E)'),
        ),
        TextButton.icon(
          onPressed: () =>
              Navigator.pop(context, EditorConflictDecision.reloadAndDiscard),
          icon: const Icon(ViewerIcons.reload),
          label: const Text('Reload current and discard draft (Alt+R)'),
        ),
        TextButton.icon(
          onPressed: () =>
              Navigator.pop(context, EditorConflictDecision.review),
          icon: const Icon(ViewerIcons.review),
          label: const Text('Review against current (Alt+V)'),
        ),
      ],
    ),
  );
}

bool attachmentsOnlyConflict(EditorConflict conflict) =>
    EditorField.values.every(
      (field) =>
          conflict.baseFields.textOf(field) ==
          conflict.currentFields.textOf(field),
    );

class AttachmentDialogFrame extends StatelessWidget {
  const AttachmentDialogFrame({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });
  final String title;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 768,
        maxHeight: MediaQuery.sizeOf(context).height - 48,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              namesRoute: true,
              header: true,
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            const SizedBox(height: 8),
            Flexible(child: content),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: actions,
            ),
          ],
        ),
      ),
    ),
  );
}
