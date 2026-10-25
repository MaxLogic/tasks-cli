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
  String? notice;
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
  String? get disabledReason => editing
      ? 'Save or cancel your edits first'
      : busy
      ? _busyMessage
      : null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _say(String value) {
    notice = value;
    if (current) announce(value);
    _notify();
  }

  Future<void> _write(List<String> command, String success) async {
    if (!enabled) return;
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
      _say(success);
    } on ViewerPendingReceiptFailure catch (failure) {
      _say(
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
        _say(attachmentFailureMessage(failure));
      }
    } finally {
      slow.cancel();
      busy = false;
      _notify();
    }
  }

  Future<void> _unknown() async {
    if (client.usesRemoteReceipts) {
      _say(
        'Attachment outcome pending. Check pending change ${pendingRequestId ?? ''}.',
      );
      return;
    }
    try {
      await refresh();
    } on ViewerFailure catch (failure) {
      _say(
        'Attachment outcome unknown; check the list before retrying. ${failure.message}',
      );
      return;
    }
    _say('Attachment outcome unknown; check the list before retrying');
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
    if (!enabled) return;
    final version = task.version;
    final files = await _choose(dialogs.openFiles);
    if (!enabled || files == null || files.isEmpty) return;
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

  Future<void> paste(Future<bool> Function(AttachmentClipboard) confirm) async {
    if (!enabled) return;
    final version = task.version;
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
      _say(attachmentFailureMessage(failure));
    } finally {
      busy = false;
      _notify();
    }
    if (clipboard == null ||
        !enabled ||
        await _choose(() => confirm(clipboard!)) != true ||
        !enabled) {
      return;
    }
    await _write(
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
  }

  Future<void> detach(
    AttachmentSummary item,
    Future<bool> Function() confirm,
  ) async {
    if (!enabled) return;
    final version = task.version;
    if (await _choose(confirm) != true || !enabled) return;
    await _write([
      'detach',
      '${task.id}',
      item.displayId,
      '--expect-version',
      '$version',
    ], 'Detached ${item.name}');
  }

  Future<String?> materialize(AttachmentSummary item, {String? out}) async {
    if (!enabled) return null;
    try {
      final result = await client.attachmentCommand(projectId, [
        'get',
        '${task.id}',
        item.displayId,
        if (out != null) ...['--out', out, '--overwrite'],
      ]);
      if (!current) return null;
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
      return entry['path']! as String;
    } on ViewerFailure catch (failure) {
      _say(attachmentFailureMessage(failure));
      return null;
    }
  }

  Future<void> saveAs(AttachmentSummary item) async {
    if (!enabled) return;
    final path = await _choose(() => dialogs.saveAs(item.name));
    if (path == null || !enabled) return;
    if (await materialize(item, out: path) != null) _say('Saved ${item.name}');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
