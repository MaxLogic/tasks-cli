/// Stored and display coordinates for the task body reader.
///
/// Contract: viewer/spec.md section 6 (preserve all whitespace and content,
/// keep the full 1 MiB body reachable) with the root spec's line-ending
/// preservation. The reader lays the body out without carriage returns because
/// the Windows paragraph engine degenerates on U+000D; every offset the user
/// can reach -- Find in body and a copied selection -- must still belong to the
/// stored text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/body_text.dart';

void main() {
  test('a body without carriage returns is its own display text', () {
    const String stored = 'first line\nsecond line\n';
    final ViewerBodyText body = ViewerBodyText.parse(stored);

    expect(body.display, stored);
    expect(body.normalized, isFalse);
    for (int offset = 0; offset <= stored.length; offset++) {
      expect(body.displayOffset(offset), offset);
      expect(body.storedOffset(offset), offset);
    }
    expect(body.storedRange(6, 10), 'line');
  });

  test('CRLF and bare CR both become the single line break they draw', () {
    final ViewerBodyText body = ViewerBodyText.parse('one\r\ntwo\rthree\n');

    expect(body.display, 'one\ntwo\nthree\n');
    expect(body.normalized, isTrue);
    // The stored offsets of both breaks map onto their display line breaks.
    expect(body.displayOffset(3), 3);
    expect(body.displayOffset(4), 3);
    expect(body.displayOffset(5), 4);
    expect(body.displayOffset(9), 7);
    expect(body.displayOffset(10), 8);
    expect(body.storedOffset(3), 3);
    expect(body.storedOffset(4), 5);
    expect(body.storedOffset(8), 10);
  });

  test('a copied display range hands back the stored characters', () {
    const String stored = 'alpha\r\nMARKER-42\r\nomega\r\n';
    final ViewerBodyText body = ViewerBodyText.parse(stored);

    expect(body.display, 'alpha\nMARKER-42\nomega\n');
    expect(body.storedRange(0, body.display.length), stored);
    expect(body.storedRange(6, 15), 'MARKER-42');
    // A range that spans the line break keeps the stored CRLF.
    expect(body.storedRange(5, 9), '\r\nMAR');
    // Out-of-range and reversed ranges stay inside the stored text.
    expect(body.storedRange(-5, 5), 'alpha');
    expect(body.storedRange(15, 6), 'MARKER-42');
    expect(body.storedRange(0, 5000), stored);
  });

  test('a one-mebibyte CRLF body maps every line boundary', () {
    const String line = 'The report body repeats a synthetic paragraph.\r\n';
    final String stored = List<String>.filled(
      1048576 ~/ line.length,
      line,
    ).join();
    final ViewerBodyText body = ViewerBodyText.parse(stored);

    expect(stored.length, greaterThan(1000000));
    expect(
      body.display.length,
      stored.length - stored.split('\r\n').length + 1,
    );
    expect(body.display.contains('\r'), isFalse);
    // Every line start in the stored text maps onto its display line start.
    int storedOffset = 0;
    int displayOffset = 0;
    while (storedOffset < stored.length) {
      expect(body.displayOffset(storedOffset), displayOffset);
      expect(body.storedOffset(displayOffset), storedOffset);
      storedOffset += line.length;
      displayOffset += line.length - 1;
    }
    expect(body.storedRange(0, body.display.length), stored);
  });
}
