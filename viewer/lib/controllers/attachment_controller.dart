import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/cli_client.dart';
import '../data/models.dart';
import '../platform/file_dialogs.dart';

String attachmentFailureMessage(ViewerFailure failure) => switch (failure) {
  ViewerCliErrorFailure(code: 'clipboard_empty') =>
    'The clipboard has no image or files',
  ViewerCliErrorFailure(code: 'clipboard_changed') =>
    'The clipboard changed; paste again',
  _ => failure.message,
};

class AttachmentController extends ChangeNotifier {
  AttachmentController({
    required this.client,
    required this.projectId,
    required this.task,
    required this.refresh,
    required this.announce,
    this.dialogs = const SystemAttachmentFileDialogs(),
    this.isCurrent,
  });
  final ViewerCliClient client;
  final String projectId;
  TaskDetail task;
  final Future<void> Function() refresh;
  final void Function(String) announce;
  final AttachmentFileDialogs dialogs;
  final bool Function()? isCurrent;
  bool get current => !_disposed && (isCurrent?.call() ?? true);
  String _busyMessage = 'Changing attachments...';
  bool busy = false, editing = false;
  bool _disposed = false;
  bool _dialogOpen = false;
  bool _confirmationSkipped = false;
  void confirmationWasSkipped() => _confirmationSkipped = true;
  String? notice;
  bool noticeAnnounced = false;
  bool clipboardRetryAvailable = false;
  String? get pendingRequestId => client.pendingReceipts
      .where(
        (r) =>
            r.projectId == projectId &&
            r.taskId == task.id &&
            r.operation.startsWith('attachment_'),
      )
      .firstOrNull
      ?.requestId;
  Future<void> recover() async {
    final id = pendingRequestId;
    if (!current || editing || id == null || busy) return;
    busy = true;
    _notify();
    try {
      await client.checkPendingChange(id);
      await refresh();
      _say('Attachment change confirmed');
    } on ViewerFailure catch (failure) {
      _say(attachmentFailureMessage(failure));
    } finally {
      busy = false;
      _notify();
    }
  }

  bool get enabled =>
      current && !_dialogOpen && !busy && !editing && pendingRequestId == null;
  String? get disabledReason => !current
      ? 'The selected task changed. Select the task again.'
      : editing
      ? 'Save or cancel your edits first'
      : busy
      ? _busyMessage
      : _dialogOpen
      ? 'Close the open attachment dialog first'
      : pendingRequestId != null
      ? 'Check the pending attachment change first'
      : null;
  bool _checkEnabled() {
    if (enabled) return true;
    _say(
      busy && !editing && current
          ? 'An attachment operation is in progress. $_busyMessage'
          : disabledReason ?? 'Attachments are unavailable',
    );
    return false;
  }

  void noSelection() => _say('Select an attachment first');
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _say(String value) {
    notice = value;
    noticeAnnounced = current;
    if (noticeAnnounced) announce(value);
    _notify();
  }

  void _outcome(String value) {
    final reminder = _confirmationSkipped
        ? '. Re-enable this confirmation in Settings > Confirmations.'
        : '';
    _confirmationSkipped = false;
    _say('$value$reminder');
  }

  Future<bool> _write(
    List<String> command,
    String success, {
    VoidCallback? onSuccess,
  }) async {
    if (!_checkEnabled()) {
      _confirmationSkipped = false;
      return false;
    }
    clipboardRetryAvailable = false;
    busy = true;
    _busyMessage = command.first == 'detach' ? 'Detaching...' : 'Attaching...';
    _notify();
    final slow = Timer(
      const Duration(milliseconds: 500),
      () => _say(command.first == 'detach' ? 'Detaching...' : 'Attaching...'),
    );
    try {
      await client.attachmentCommand(projectId, command, mutation: true);
      await refresh();
      onSuccess?.call();
      _outcome(success);
    } on ViewerPendingReceiptFailure catch (failure) {
      _outcome(
        'Attachment outcome pending. Check pending change ${failure.requestId}.',
      );
    } on ViewerTimeoutFailure {
      await _unknown();
    } on ViewerMalformedResponseFailure {
      await _unknown();
    } on ViewerFailure catch (failure) {
      if (failure is ViewerCliErrorFailure &&
          failure.code == 'unparsed_error') {
        await _unknown();
      } else {
        _outcome(attachmentFailureMessage(failure));
      }
    } finally {
      slow.cancel();
      busy = false;
      _confirmationSkipped = false;
      _notify();
    }
    return true;
  }

  Future<void> _unknown() async {
    if (client.usesRemoteReceipts) {
      _outcome(
        'Attachment outcome pending. Check pending change ${pendingRequestId ?? ''}.',
      );
      return;
    }
    try {
      await refresh();
    } on ViewerFailure catch (failure) {
      _outcome(
        'Attachment outcome unknown; check the list before retrying. ${failure.message}',
      );
      return;
    }
    _outcome('Attachment outcome unknown; check the list before retrying');
  }

  Future<T?> _choose<T>(Future<T> Function() action) async {
    _dialogOpen = true;
    _notify();
    try {
      return await action();
    } on Object catch (failure) {
      _say('Could not open attachment dialog: $failure');
      return null;
    } finally {
      _dialogOpen = false;
      _notify();
    }
  }

  Future<void> addFiles() async {
    notice = null;
    if (!_checkEnabled()) return;
    final version = task.version;
    final files = await _choose(dialogs.openFiles);
    if (!_checkEnabled()) return;
    if (files == null || files.isEmpty) {
      if (notice == null) _say('Attachment add cancelled');
      return;
    }
    await _write(
      [
        'add',
        '${task.id}',
        '--expect-version',
        '$version',
        for (final file in files) ...['--file', file],
      ],
      'Attached ${files.length} ${files.length == 1 ? 'file' : 'files'} to ${task.canonicalId}',
    );
  }

  /// True only after a mutation starts. Every other result allows Tasks search
  /// paste to try its text clipboard seam; [notice] explains an unavailable attach.
  Future<bool> paste(
    Future<bool> Function(AttachmentClipboard) confirm, {
    bool ignoreEmpty = false,
  }) async {
    try {
      notice = null;
      noticeAnnounced = false;
      if (!_checkEnabled()) return false;
      final version = task.version;
      clipboardRetryAvailable = false;
      _busyMessage = 'Reading clipboard...';
      busy = true;
      _notify();
      AttachmentClipboard? clipboard;
      try {
        clipboard = AttachmentClipboard.fromJson(
          (await client.attachmentCommand(projectId, [
            'clipboard',
          ], clipboard: true)).data,
        );
      } on ViewerFailure catch (failure) {
        if (ignoreEmpty &&
            failure is ViewerCliErrorFailure &&
            failure.code == 'clipboard_empty') {
          notice = attachmentFailureMessage(failure);
          return false;
        }
        clipboardRetryAvailable =
            failure is ViewerTimeoutFailure ||
            (failure is ViewerCliErrorFailure && failure.code == 'interop');
        _say(attachmentFailureMessage(failure));
      } finally {
        busy = false;
        _notify();
      }
      if (clipboard == null || !_checkEnabled()) return false;
      final accepted = await _choose(() => confirm(clipboard!));
      if (accepted != true) {
        if (notice == null) _say('Attachment paste cancelled');
        return false;
      }
      if (!_checkEnabled()) return false;
      return await _write(
        [
          'add',
          '${task.id}',
          '--expect-version',
          '$version',
          '--clipboard',
          '--clipboard-token',
          clipboard.token,
        ],
        'Attached ${clipboard.items.length} ${clipboard.items.length == 1 ? 'file' : 'files'} to ${task.canonicalId}',
      );
    } finally {
      _confirmationSkipped = false;
    }
  }

  Future<void> detach(
    AttachmentSummary item,
    Future<bool> Function() confirm,
  ) async {
    await detachMany([item], confirm);
  }

  /// One optimistic version check, mutation and refresh for the selected set.
  /// False includes cancellation and unknown outcomes; selection is retained.
  Future<bool> detachMany(
    List<AttachmentSummary> items,
    Future<bool> Function() confirm,
  ) async {
    try {
      notice = null;
      if (!_checkEnabled()) return false;
      if (items.isEmpty) {
        noSelection();
        return false;
      }
      final version = task.version;
      final selected = List<AttachmentSummary>.of(items);
      if (await _choose(confirm) != true || !_checkEnabled()) return false;
      var succeeded = false;
      await _write(
        [
          'detach',
          '${task.id}',
          for (final item in selected) item.displayId,
          '--expect-version',
          '$version',
        ],
        selected.length == 1
            ? 'Detached ${selected.single.name}'
            : 'Detached ${selected.length} attachments',
        onSuccess: () => succeeded = true,
      );
      return succeeded;
    } finally {
      _confirmationSkipped = false;
    }
  }

  Future<String?> materialize(AttachmentSummary item, {String? out}) async {
    notice = null;
    if (!_checkEnabled()) return null;
    busy = true;
    _busyMessage = out == null
        ? 'Opening ${item.name}...'
        : 'Saving ${item.name}...';
    _say(_busyMessage);
    try {
      final result = await client.attachmentCommand(projectId, [
        'get',
        '${task.id}',
        item.displayId,
        if (out != null) ...['--out', out, '--overwrite'],
      ]);
      if (!current) {
        _say('The selected task changed. Select the task again.');
        return null;
      }
      final items = result.data['items'];
      if (result.data['id'] != task.id || items is! List || items.length != 1) {
        throw const ViewerMalformedResponseFailure(
          'attachment get returned a mismatched task or item count',
        );
      }
      final entry = items.single;
      if (entry is! Map<String, Object?> ||
          entry['path'] is! String ||
          entry['attachment'] is! Map<String, Object?> ||
          entry['reused'] is! bool) {
        throw const ViewerMalformedResponseFailure(
          'attachment get returned invalid metadata',
        );
      }
      final summary = AttachmentSummary.fromJson(
        entry['attachment']! as Map<String, Object?>,
      );
      if (summary.id != item.id) {
        throw const ViewerMalformedResponseFailure(
          'attachment get returned a mismatched item',
        );
      }
      _say(out == null ? 'Opened ${item.name}' : 'Saved ${item.name}');
      return entry['path']! as String;
    } on ViewerFailure catch (failure) {
      _say(attachmentFailureMessage(failure));
      return null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> saveAs(AttachmentSummary item) async {
    notice = null;
    if (!_checkEnabled()) return;
    final path = await _choose(() => dialogs.saveAs(item.name));
    if (!_checkEnabled()) return;
    if (path == null) {
      if (notice == null) _say('Save cancelled');
      return;
    }
    await materialize(item, out: path);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
