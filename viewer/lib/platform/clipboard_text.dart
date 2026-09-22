/// The plain-text clipboard the viewer reads itself (viewer/spec.md section 8).
///
/// Only Preview enrichment uses this seam: it reads the clipboard once and the
/// CLI's `enrich --file -` transforms the copy. The direct action never comes
/// through here, because `enrich-clipboard` owns the read, the text-equality
/// check and the replacement in Rust.
library;

import 'package:flutter/services.dart';

import '../data/models.dart';

/// Read-only access to the clipboard's plain-text format.
///
/// Implementations are injected so a widget test never touches a real
/// clipboard and can prove the preview route does not write one.
abstract interface class ViewerClipboard {
  /// The clipboard's plain text, or null when it holds no text at all.
  Future<String?> readText();
}

/// The real clipboard, through the Flutter platform channel.
class SystemViewerClipboard implements ViewerClipboard {
  const SystemViewerClipboard();

  @override
  Future<String?> readText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } on PlatformException catch (error) {
      throw ViewerClipboardFailure(
        'The clipboard could not be read: '
        '${error.message ?? error.code}.',
      );
    } on MissingPluginException {
      throw const ViewerClipboardFailure(
        'This build has no clipboard access; preview is unavailable.',
      );
    }
  }
}
