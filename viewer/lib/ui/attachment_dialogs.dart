import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/attachment_controller.dart';
import '../controllers/editor_controller.dart';
import '../data/models.dart';
import '../data/editor_models.dart';
import 'editor_dialogs.dart';
import 'dialog_scope.dart';
import 'viewer_icons.dart';
import 'viewer_motion.dart';
import 'commands.dart';
import 'accessible_virtual_list.dart';
import 'app_shell.dart';
import 'attachment_preview_dialog.dart';
import 'viewer_format.dart';

class AttachmentConfirmationDialog extends StatelessWidget {
  const AttachmentConfirmationDialog({
    super.key,
    required this.title,
    required this.content,
    required this.accept,
    this.cancelDefault = false,
    this.acceptIcon = ViewerIcons.attach,
  });
  final String title, content, accept;
  final bool cancelDefault;
  final IconData acceptIcon;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.pop(context, false),
      const SingleActivator(LogicalKeyboardKey.keyC, alt: true): () =>
          Navigator.pop(context, false),
      SingleActivator(
        cancelDefault ? LogicalKeyboardKey.keyD : LogicalKeyboardKey.keyA,
        alt: true,
      ): () =>
          Navigator.pop(context, true),
    },
    child: AttachmentDialogFrame(
      title: title,
      content: SingleChildScrollView(child: SelectableText(content)),
      actions: [
        TextButton.icon(
          autofocus: !cancelDefault,
          onPressed: () => Navigator.pop(context, true),
          icon: Icon(acceptIcon),
          label: Text(accept),
        ),
        TextButton.icon(
          autofocus: cancelDefault,
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
  int? selected = 0;
  AttachmentController get c => widget.controller;
  AttachmentSummary? get item =>
      selected != null && selected! < c.task.attachments.length
      ? c.task.attachments[selected!]
      : null;
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
    (clip) => _confirm(
      AttachmentConfirmationDialog(
        title: 'Attach to ${c.task.canonicalId}?',
        accept: 'Attach (Alt+A)',
        content: [
          ...clip.items.map(
            (i) =>
                '${i['name']}, ${i['kind']}, ${attachmentSizeLabel(i['original_size']! as int)}',
          ),
          ...clip.skipped.map((i) => 'Skipped ${i['path']}: ${i['reason']}'),
        ].join('\n'),
      ),
      CommandScope.attachmentAttach,
    ),
  );
  Future<void> detach() async {
    final current = item;
    if (current == null) return;
    await c.detach(
      current,
      () => _confirm(
        AttachmentConfirmationDialog(
          title: 'Detach ${current.name} from ${c.task.canonicalId}?',
          content: "The file stays in the backlog's history.",
          accept: 'Detach (Alt+D)',
          acceptIcon: ViewerIcons.detach,
          cancelDefault: true,
        ),
        CommandScope.attachmentDetach,
      ),
    );
    if (!mounted) return;
    final count = c.task.attachments.length;
    selected = count == 0 ? null : (selected ?? 0).clamp(0, count - 1);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (selected != null) list.selectIndex(selected);
      list.focusRegion();
    });
  }

  Future<void> view() async {
    final current = item;
    if (current == null) return;
    final path = await c.materialize(current);
    if (path == null || !mounted) return;
    await _showModal<void>(
      AttachmentPreviewDialog(
        item: current,
        path: path,
        announce: c.announce,
        onSaveAs: () => c.saveAs(current),
      ),
      CommandScope.attachmentPreview,
    );
  }

  String rowLabel(BuildContext context, AttachmentSummary item) =>
      '${item.name}, ${item.kind}, ${item.mediaType}, ${item.sizeLabel}, added ${viewerTimestamp(context, item.addedMs)}';

  @override
  void dispose() {
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
          if (item != null) unawaited(c.saveAs(item!));
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
                onPressed: c.enabled ? c.addFiles : null,
                icon: const Icon(ViewerIcons.attach),
                label: const Text('Add files (Alt+F)'),
              ),
              TextButton.icon(
                onPressed: c.enabled ? paste : null,
                icon: const Icon(ViewerIcons.paste),
                label: const Text('Paste (Alt+U)'),
              ),
              TextButton.icon(
                onPressed: c.enabled && item != null ? view : null,
                icon: const Icon(ViewerIcons.view),
                label: const Text('View (Alt+W)'),
              ),
              TextButton.icon(
                onPressed: c.enabled && item != null
                    ? () => c.saveAs(item!)
                    : null,
                icon: const Icon(ViewerIcons.saveAs),
                label: const Text('Save as (Alt+S)'),
              ),
              TextButton.icon(
                onPressed: c.enabled && item != null ? detach : null,
                icon: const Icon(ViewerIcons.detach),
                label: const Text('Detach (Alt+X)'),
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
            child: AccessibleVirtualList(
              controller: list,
              itemCount: c.task.attachments.length,
              motionKey: ListMotionKey(
                scope: c.task.canonicalId,
                epoch: c.task.attachments,
              ),
              itemExtent: 64,
              listLabel: 'Attachments (Alt+A)',
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
              onSelectedIndexChanged: (i) => setState(() => selected = i),
              onActivate: (_) => unawaited(view()),
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
