/// Ctrl+V on a focused Projects or Tasks list pastes the clipboard text into
/// that list's search field, applies it at once and keeps the list focused.
///
/// Contract: viewer/design.md section 9 (scoped shortcuts; text-editing keys
/// stay with the focused text field).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/commands.dart';

import '../support/viewer_test_support.dart';

TextField _field(WidgetTester tester, String label) =>
    tester.widget<TextField>(textFieldWithLabel(label));

Future<RealViewerHarness> _pump(
  WidgetTester tester,
  FakeViewerClipboard clipboard,
) async {
  final harness = await pumpRealViewer(tester, clipboard: clipboard);
  harness.model.selectProjectIndex(0);
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('Ctrl+V on the Tasks list filters by the trimmed clipboard', (
    tester,
  ) async {
    final clipboard = FakeViewerClipboard(text: '  T-002\r\n');
    final harness = await _pump(tester, clipboard);
    await pressKey(tester, LogicalKeyboardKey.f2);
    expect(harness.list(ViewerRegion.tasks).hasListFocus, isTrue);

    await pressControl(tester, LogicalKeyboardKey.keyV);

    expect(clipboard.reads, 1);
    expect(_field(tester, 'Search tasks (Ctrl+F)').controller!.text, 'T-002');
    expect(harness.reads.lastTaskRequest.query, 'T-002');
    expect(harness.model.tasks!.totalCount, 1);
    expect(harness.list(ViewerRegion.tasks).hasListFocus, isTrue);
  });

  testWidgets('pasting replaces an earlier task search instead of appending', (
    tester,
  ) async {
    final clipboard = FakeViewerClipboard(text: 'Third');
    final harness = await _pump(tester, clipboard);
    await pressControl(tester, LogicalKeyboardKey.keyF);
    await pressKey(tester, LogicalKeyboardKey.f2);
    await tester.enterText(textFieldWithLabel('Search tasks (Ctrl+F)'), 'task');
    await tester.pumpAndSettle();
    await pressKey(tester, LogicalKeyboardKey.f2);

    await pressControl(tester, LogicalKeyboardKey.keyV);

    expect(_field(tester, 'Search tasks (Ctrl+F)').controller!.text, 'Third');
    expect(harness.reads.lastTaskRequest.query, 'Third');
    expect(harness.list(ViewerRegion.tasks).hasListFocus, isTrue);
  });

  testWidgets('Ctrl+V on the Projects list filters projects', (tester) async {
    final clipboard = FakeViewerClipboard(text: 'Project 2\n');
    final harness = await _pump(tester, clipboard);
    await pressKey(tester, LogicalKeyboardKey.f1);
    expect(harness.list(ViewerRegion.projects).hasListFocus, isTrue);

    await pressControl(tester, LogicalKeyboardKey.keyV);

    expect(
      _field(tester, 'Search projects (Ctrl+F)').controller!.text,
      'Project 2',
    );
    expect(harness.reads.lastProjectRequest.query, 'Project 2');
    expect(harness.model.projectList.totalCount, 1);
    expect(harness.list(ViewerRegion.projects).hasListFocus, isTrue);
  });

  for (final text in <String?>[null, '', ' \r\n\t ']) {
    testWidgets(
      'an empty or non-text clipboard (${text == null ? 'null' : '"${text.length}"'}) changes nothing',
      (tester) async {
        final clipboard = FakeViewerClipboard(text: text);
        final harness = await _pump(tester, clipboard);
        await pressKey(tester, LogicalKeyboardKey.f2);
        final requests = harness.reads.taskRequests.length;

        await pressControl(tester, LogicalKeyboardKey.keyV);

        expect(clipboard.reads, 1);
        expect(_field(tester, 'Search tasks (Ctrl+F)').controller!.text, '');
        expect(harness.reads.taskRequests.length, requests);
        expect(harness.list(ViewerRegion.tasks).hasListFocus, isTrue);
      },
    );
  }

  testWidgets('Ctrl+V inside a search field stays a normal text paste', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': 'Second'};
        }
        if (call.method == 'Clipboard.hasStrings') {
          return <String, Object?>{'value': true};
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
    final clipboard = FakeViewerClipboard(text: 'T-003');
    await _pump(tester, clipboard);
    await pressKey(tester, LogicalKeyboardKey.f2);
    await pressControl(tester, LogicalKeyboardKey.keyF);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tasks filter');

    await pressControl(tester, LogicalKeyboardKey.keyV);

    expect(clipboard.reads, 0);
    expect(_field(tester, 'Search tasks (Ctrl+F)').controller!.text, 'Second');
  });

  test('Help lists the paste shortcut for both lists', () {
    for (final id in <String>['projects.pasteFilter', 'tasks.pasteFilter']) {
      final spec = commandSpecById(id);
      expect(spec, isNotNull, reason: id);
      expect(spec!.shortcutLabel, 'Ctrl+V');
      expect(spec.description, contains('list'));
    }
  });
}
