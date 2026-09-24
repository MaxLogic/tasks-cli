import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/projects_pane.dart';

import '../support/viewer_test_support.dart';

void main() {
  testWidgets('project actions use left-hand keys on rows and in menus', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpRealViewer(tester);
    expect(
      find.descendant(
        of: find.byType(ViewerProjectsPane),
        matching: find.text('Go to row'),
      ),
      findsNothing,
    );
    await pressKey(tester, LogicalKeyboardKey.f1);
    await pressKey(tester, LogicalKeyboardKey.keyF);
    expect(copied, testProjectItem(1).roots.first);
    await pressKey(tester, LogicalKeyboardKey.keyD);
    expect(copied, testProjectItem(1).projectId);
    await pressKey(tester, LogicalKeyboardKey.contextMenu);
    for (final label in [
      'Open in Explorer (E)',
      'Open in Alacritty (R)',
      'Open in Terminal (T)',
      'Copy path (F)',
      'Archive (A)',
      'Copy project ID (D)',
      'Enrich clipboard (C)',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await pressKey(tester, LogicalKeyboardKey.keyF);
    expect(copied, testProjectItem(1).roots.first);
    expect(find.text('Copy path (F)'), findsNothing);
    await pressKey(tester, LogicalKeyboardKey.f1);
    await pressKey(tester, LogicalKeyboardKey.end);
    await pressKey(tester, LogicalKeyboardKey.keyD);
    expect(copied, testProjectItem(2).projectId);
    await pressKey(tester, LogicalKeyboardKey.contextMenu);
    copied = null;
    await pressKey(tester, LogicalKeyboardKey.keyD);
    expect(copied, testProjectItem(2).projectId);
    expect(find.text('Copy project ID (D)'), findsNothing);
  });
}
