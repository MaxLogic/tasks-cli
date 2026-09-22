/// One task body in the two coordinate systems the read views need: the text
/// exactly as the store returned it, and the text the Windows paragraph engine
/// actually lays out.
///
/// Contract: viewer/spec.md section 6 (preserve all whitespace and content, the
/// full 1 MiB body reachable by line, word and character, Find in body) and the
/// root spec's rule that line endings survive a round trip.
///
/// The native paragraph layout degenerates on U+000D. Measured with the slice-4
/// fixture body (1 046 247 characters, 24 870 CRLF pairs) in a profile build of
/// this app, one layout pass costs about 278 s, while the same text with LF
/// endings costs 0.32 s; one repeated 128-character line costs 448 ms with CRLF
/// against 18 ms with LF, and non-ASCII, markdown and a 1 981-character
/// unbreakable line are all irrelevant to the cost. A carriage return draws
/// nothing, so the reader lays out [display] and keeps [stored] as the source of
/// truth for offsets and for anything that leaves the app. See
/// viewer/target/evidence/viewer/2026-09-22-slice4-nvda/drive/paragraph-probe.log.
library;

/// A task body whose carriage returns are kept out of the engine.
class ViewerBodyText {
  ViewerBodyText._(this.stored, this.display, this._removed);

  /// Splits [stored] into the stored form and the LF form the engine lays out.
  factory ViewerBodyText.parse(String stored) {
    if (!stored.contains('\r')) {
      return ViewerBodyText._(stored, stored, const <int>[]);
    }
    final StringBuffer out = StringBuffer();
    final List<int> removed = <int>[];
    for (int index = 0; index < stored.length; index++) {
      if (stored.codeUnitAt(index) != 0x0D) {
        out.writeCharCode(stored.codeUnitAt(index));
        continue;
      }
      removed.add(index);
      // CRLF keeps its LF; a bare CR becomes the line break the engine takes.
      if (index + 1 >= stored.length || stored.codeUnitAt(index + 1) != 0x0A) {
        out.writeCharCode(0x0A);
      }
    }
    return ViewerBodyText._(stored, out.toString(), removed);
  }

  /// The body exactly as `viewer show` returned it.
  final String stored;

  /// The text handed to the paragraph engine: every U+000D is gone, every line
  /// still ends the way it did in [stored].
  final String display;

  /// Code-unit indexes of the removed carriage returns, ascending.
  final List<int> _removed;

  /// Whether [display] differs from [stored], that is whether the body used CR.
  bool get normalized => _removed.isNotEmpty;

  /// The offset in [display] for an offset in [stored].
  ///
  /// Used by Find in body, whose match offsets belong to the stored text.
  int displayOffset(int storedOffset) =>
      storedOffset - _removedBefore(storedOffset);

  /// The offset in [stored] for an offset in [display].
  int storedOffset(int displayOffset) {
    // The n-th removed carriage return holds display index `removed[n] - n`.
    int low = 0;
    int high = _removed.length;
    while (low < high) {
      final int middle = (low + high) >> 1;
      if (_removed[middle] - middle < displayOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return displayOffset + low;
  }

  /// The exact stored text behind a display range, so a copy of a selection
  /// hands over the body's own characters, CRLF included.
  String storedRange(int start, int end) {
    final int from = storedOffset(_inside(start));
    final int to = storedOffset(_inside(end));
    return stored.substring(from < to ? from : to, from < to ? to : from);
  }

  int _inside(int offset) =>
      offset < 0 ? 0 : (offset > display.length ? display.length : offset);

  int _removedBefore(int storedOffset) {
    int low = 0;
    int high = _removed.length;
    while (low < high) {
      final int middle = (low + high) >> 1;
      if (_removed[middle] < storedOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}
