import 'package:file_selector/file_selector.dart' as selector;

/// Native dialogs belong to the viewer. Tests inject paths without opening UI.
abstract interface class AttachmentFileDialogs {
  Future<List<String>> openFiles();
  Future<String?> saveAs(String suggestedName);
}

class SystemAttachmentFileDialogs implements AttachmentFileDialogs {
  const SystemAttachmentFileDialogs();
  @override
  Future<List<String>> openFiles() async =>
      (await selector.openFiles()).map((f) => f.path).toList();
  @override
  Future<String?> saveAs(String suggestedName) async =>
      (await selector.getSaveLocation(suggestedName: suggestedName))?.path;
}
