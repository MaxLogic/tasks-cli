/// Real three-pane workspace commands: the contextual filter chord, the
/// description target and the details tabs.
///
/// Contract: viewer/spec.md section 6 (V11) and viewer/design.md sections 6
/// and 9: Ctrl+F always reaches the remembered list filter, F3 always reaches
/// the description, and a details tab must never detach either target.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/viewer_test_support.dart';

void main() {
  group('real workspace focus commands', () {
    testWidgets('Ctrl+F from the Projects list focuses the projects filter', (
      WidgetTester tester,
    ) async {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f1);
      await pressControl(tester, LogicalKeyboardKey.keyF);

      expect(harness.focusedDebugLabel, 'projects filter');
    });

    testWidgets('Ctrl+F from the task body focuses the remembered filter', (
      WidgetTester tester,
    ) async {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.focusedDebugLabel, 'details description');

      await pressControl(tester, LogicalKeyboardKey.keyF);
      expect(harness.focusedDebugLabel, 'tasks filter');
    });

    testWidgets('F3 returns to the description after another details tab', (
      WidgetTester tester,
    ) async {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressKey(tester, LogicalKeyboardKey.f3);
      expect(harness.focusedDebugLabel, 'details description');

      await pressAlt(tester, LogicalKeyboardKey.digit2);
      await pressKey(tester, LogicalKeyboardKey.f3);

      expect(harness.focusedDebugLabel, 'details description');
    });

    testWidgets('Ctrl+F still works after visiting another details tab', (
      WidgetTester tester,
    ) async {
      final harness = await pumpRealViewer(tester);
      harness.model.selectProjectIndex(0);
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.f2);
      await pressKey(tester, LogicalKeyboardKey.f3);
      await pressAlt(tester, LogicalKeyboardKey.digit2);

      await pressKey(tester, LogicalKeyboardKey.f1);
      await pressControl(tester, LogicalKeyboardKey.keyF);

      expect(harness.focusedDebugLabel, 'projects filter');
    });
  });
}
