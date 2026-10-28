import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';

import 'attachment_contract_test.dart' as att;

Future<void> modified(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  Future<void> Function() action,
) async {
  await tester.sendKeyDownEvent(modifier);
  await action();
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

void selectionTest(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });
}

void main() {
  late Directory root;
  late att.Rig rig;
  late AttachmentPanelState panel;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('attachment-multiselect-');
    rig = att.Rig(root);
    await rig.probe();
    rig.controller.task.attachments
      ..clear()
      ..addAll([
        for (var i = 0; i < 5; i++)
          AttachmentSummary.fromJson({
            ...att.metadata,
            'id': 12 + i,
            'display_id': 'A${12 + i}',
            'name': 'file-$i.log',
          }),
      ]);
  });
  tearDown(() async {
    rig.controller.dispose();
    try {
      await root.delete(recursive: true);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 32) rethrow;
      // The lane owner cleans this explicit TEMP root after Flutter exits.
      // ignore: avoid_print
      print('DEFERRED_FIXTURE_CLEANUP ${root.path}');
    }
  });

  Future<void> mount(WidgetTester tester, {ThemeData? theme}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(body: AttachmentPanel(controller: rig.controller)),
      ),
    );
    await tester.pumpAndSettle();
    panel = tester.state<AttachmentPanelState>(find.byType(AttachmentPanel));
  }

  Finder row(int i) => find.byKey(ValueKey(12 + i));
  Future<void> click(WidgetTester tester, int i) async {
    await tester.tap(row(i), kind: PointerDeviceKind.mouse);
    // Do not wait for double-click recognition before checking the selection.
    await tester.pump();
  }

  Set<int> selected(WidgetTester tester) => {
    for (var i = 0; i < rig.controller.task.attachments.length; i++)
      if (tester
              .getSemantics(row(i))
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          Tristate.isTrue)
        i,
  };

  selectionTest(
    'plain moves and programmatic selection do not announce counts',
    (tester) async {
      await mount(tester);
      rig.announcements.clear();
      await click(tester, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(rig.announcements, isEmpty);
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 4),
      );
      expect(rig.announcements.last, 'file-4.log selected, 2 selected');
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.space),
      );
      expect(rig.announcements.last, 'file-4.log not selected, 1 selected');
      rig.announcements.clear();
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.arrowUp),
      );
      expect(panel.list.selectedIndices, {2});
      expect(panel.item?.name, 'file-3.log');
      expect(rig.announcements, isEmpty);
      panel.list.selectIndex(1);
      panel.list.goToIndex(0);
      panel.focusList();
      await tester.pumpAndSettle();
      expect(rig.announcements, isEmpty);
    },
  );

  selectionTest('Ctrl+Shift adds ranges and Shift navigation keeps an anchor', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 0);
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => click(tester, 3),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await modified(
      tester,
      LogicalKeyboardKey.shiftLeft,
      () => click(tester, 4),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(selected(tester), {0, 3, 4});
    for (final key in [
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
    ]) {
      panel.list.goToIndex(2);
      panel.focusList();
      await tester.pumpAndSettle();
      await modified(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => tester.sendKeyEvent(key),
      );
      final lead = panel.list.selectedIndex!;
      expect(lead, isNot(2));
      expect(selected(tester), {
        for (var i = 0; i < 5; i++)
          if (i >= (lead < 2 ? lead : 2) && i <= (lead > 2 ? lead : 2)) i,
      });
    }
  });

  selectionTest(
    'refresh insertion and reorder retain attachment IDs and lead',
    (tester) async {
      await mount(tester);
      await click(tester, 1);
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 3),
      );
      final old = rig.controller.task.attachments.toList();
      rig.controller.task.attachments
        ..clear()
        ..addAll([
          old[3],
          AttachmentSummary.fromJson({
            ...att.metadata,
            'id': 99,
            'display_id': 'A99',
            'name': 'new.log',
          }),
          old[4],
          old[1],
          old[0],
          old[2],
        ]);
      await mount(tester);
      expect(
        panel.list.selectedIndices
            .map((i) => panel.c.task.attachments[i].id)
            .toSet(),
        {13, 15},
      );
      expect(panel.item?.id, 15);
      expect(panel.list.selectedIndex, 0);
    },
  );

  for (final highContrast in [false, true]) {
    selectionTest(
      'selection lead and focus have independent non-colour cues highContrast=$highContrast',
      (tester) async {
        await mount(
          tester,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.light,
              contrastLevel: highContrast ? 1 : 0,
            ),
          ),
        );
        Finder inside(int i, String key) =>
            find.descendant(of: row(i), matching: find.byKey(ValueKey(key)));
        Border outline(int i) =>
            (tester
                            .widget<DecoratedBox>(
                              inside(i, 'multi-focus-outline'),
                            )
                            .decoration
                        as BoxDecoration)
                    .border!
                as Border;
        await click(tester, 0);
        await modified(
          tester,
          LogicalKeyboardKey.controlLeft,
          () => click(tester, 1),
        );
        expect(inside(1, 'multi-selection-check'), findsOneWidget);
        expect(
          tester.widget<Icon>(inside(1, 'multi-selection-check')).icon,
          Icons.check,
        );
        expect(inside(1, 'multi-lead-marker'), findsOneWidget);
        expect(
          tester.widget<Icon>(inside(1, 'multi-lead-marker')).icon,
          Icons.arrow_right,
        );
        expect(outline(1).top.width, greaterThan(0));
        await modified(
          tester,
          LogicalKeyboardKey.controlLeft,
          () => click(tester, 2),
        );
        expect(inside(2, 'multi-selection-check'), findsOneWidget);
        expect(outline(2).top.width, greaterThan(0));
        await modified(
          tester,
          LogicalKeyboardKey.controlLeft,
          () => tester.sendKeyEvent(LogicalKeyboardKey.space),
        );
        expect(inside(2, 'multi-selection-check'), findsNothing);
        expect(inside(2, 'multi-lead-marker'), findsOneWidget);
        expect(outline(2).top.width, greaterThan(0));
        expect(selected(tester), {0, 1});
        final button = find.widgetWithText(TextButton, 'View (Alt+W)');
        Focus.of(
          tester.element(
            find.descendant(of: button, matching: find.byType(Text)).last,
          ),
        ).requestFocus();
        await tester.pumpAndSettle();
        expect(outline(2).top.width, 0);
        expect(inside(2, 'multi-lead-marker'), findsOneWidget);
        expect(inside(1, 'multi-selection-check'), findsOneWidget);
        expect(inside(1, 'multi-lead-marker'), findsNothing);
        for (final action in ['View', 'Save as']) {
          expect(find.byTooltip('$action file-2.log'), findsOneWidget);
          final target = find.widgetWithText(
            TextButton,
            '$action (${action == 'View' ? 'Alt+W' : 'Alt+S'})',
          );
          final data = tester.getSemantics(target).getSemanticsData();
          expect(data.hint, '$action file-2.log');
          expect(
            data.label,
            '$action (${action == 'View' ? 'Alt+W' : 'Alt+S'})',
          );
          expect(data.flagsCollection.isButton, isTrue);
        }
      },
    );
  }

  selectionTest('Windows multi-selection gestures and row selected semantics', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 1);
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => click(tester, 3),
    );
    expect(selected(tester), {1, 3});
    expect(panel.list.focusedRowIndex, 3);
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => click(tester, 3),
    );
    expect(selected(tester), {1});
    expect(panel.list.focusedRowIndex, 3);
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.space),
    );
    expect(selected(tester), {1, 3});
    await click(tester, 1);
    await modified(
      tester,
      LogicalKeyboardKey.shiftLeft,
      () => click(tester, 4),
    );
    expect(selected(tester), {1, 2, 3, 4});
    await modified(
      tester,
      LogicalKeyboardKey.shiftLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.arrowUp),
    );
    expect(selected(tester), {1, 2, 3});
    await modified(
      tester,
      LogicalKeyboardKey.shiftLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.arrowDown),
    );
    expect(selected(tester), {1, 2, 3, 4});
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.keyA),
    );
    expect(selected(tester), {0, 1, 2, 3, 4});
    expect(rig.announcements, contains('5 attachments selected'));
    expect(
      tester
          .getSemantics(find.byType(AccessibleVirtualList))
          .getSemanticsData()
          .value,
      '5 selected',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(selected(tester), {3});
    await click(tester, 0);
    expect(selected(tester), {0});
  });

  for (final shortcut in ['Delete', 'Alt+X']) {
    selectionTest(
      '$shortcut confirms once and detaches the selected IDs atomically',
      (tester) async {
        await mount(tester);
        await click(tester, 1);
        await modified(
          tester,
          LogicalKeyboardKey.shiftLeft,
          () => click(tester, 3),
        );
        if (shortcut == 'Delete') {
          await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        } else {
          await modified(
            tester,
            LogicalKeyboardKey.altLeft,
            () => tester.sendKeyEvent(LogicalKeyboardKey.keyX),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('Detach 3 attachments from TSK-042?'), findsOneWidget);
        for (final i in [1, 2, 3]) {
          expect(find.textContaining('file-$i.log'), findsWidgets);
        }
        rig.mutation('attachment_detach');
        // The refresh removes the detached rows before the panel regains focus.
        rig.controller.task.attachments.removeRange(1, 4);
        await tester.tap(find.text('Detach (Alt+D)'));
        await tester.pumpAndSettle();
        final writes = rig.launcher.launches
            .where((call) => call.arguments.contains('detach'))
            .toList();
        expect(writes, hasLength(1));
        final args = writes.single.arguments;
        expect(args.sublist(args.indexOf('attachment')), [
          'attachment',
          'detach',
          '42',
          'A13',
          'A14',
          'A15',
          '--expect-version',
          '7',
        ]);
        expect(rig.refreshes, 1);
        expect(panel.list.focusedRowIndex, 1);
        expect(panel.item?.name, 'file-4.log');
        expect(panel.list.hasListFocus, isTrue);
        expect(rig.announcements.last, 'Detached 3 attachments');
      },
    );
  }

  selectionTest(
    'failed detach and cancelled confirmation retain the selected set',
    (tester) async {
      await mount(tester);
      await click(tester, 1);
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 3),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel (Alt+C)'));
      await tester.pumpAndSettle();
      expect(selected(tester), {1, 3});
      expect(rig.launcher.launches, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      rig.launcher.exit = 4;
      rig.launcher.stderrBytes = [
        utf8.encode(
          '{"error":{"code":"version_conflict","message":"Task changed"}}',
        ),
      ];
      await tester.tap(find.text('Detach (Alt+D)'));
      await tester.pumpAndSettle();
      expect(selected(tester), {1, 3});
      expect(panel.list.focusedRowIndex, 3);
      expect(rig.refreshes, 0);
    },
  );

  selectionTest('an empty selection does not detach the focused row', (
    tester,
  ) async {
    await mount(tester);
    await click(tester, 2);
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.space),
    );
    expect(selected(tester), isEmpty);
    expect(panel.item?.displayId, 'A14');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentConfirmationDialog), findsNothing);
    expect(rig.launcher.launches, hasLength(1));
    expect(rig.controller.notice, 'Select an attachment first');
  });

  selectionTest(
    'View double-click and Save as use the focused unselected row',
    (tester) async {
      rig.controller.task.attachments[0] = AttachmentSummary.fromJson(
        att.metadata,
      );
      final file = File('${root.path}/run.log')..writeAsStringSync('Preview');
      rig.launcher.replyWith(
        att.envelope('attachment_get', {
          'id': 42,
          'items': [
            {'attachment': att.metadata, 'path': file.path, 'reused': false},
          ],
        }),
      );
      await mount(tester);
      await click(tester, 0);
      await tester.pump(const Duration(milliseconds: 400));
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 2),
      );
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 0),
      );
      expect(selected(tester), {2});
      expect(panel.item?.displayId, 'A12');
      await tester.tap(find.text('View (Alt+W)'));
      await att.settleFileIo(tester);
      expect(find.text('run.log'), findsWidgets);
      await tester.tap(find.text('Close (Alt+C)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as (Alt+S)'));
      await tester.pumpAndSettle();
      expect(rig.args.sublist(rig.args.indexOf('attachment')), [
        'attachment',
        'get',
        '42',
        'A12',
        '--out',
        r'C:\synthetic\saved.log',
        '--overwrite',
      ]);
      // Both pointer-downs apply Windows selection; activation still opens the
      // focused row without performing a third selection change on double-tap.
      await click(tester, 2);
      await tester.pump(const Duration(milliseconds: 400));
      final gesture = await tester.startGesture(
        tester.getCenter(row(0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row(0), kind: PointerDeviceKind.mouse);
      await att.settleFileIo(tester);
      expect(panel.item?.displayId, 'A12');
      final gets = rig.launcher.launches
          .where((call) => call.arguments.contains('get'))
          .toList();
      expect(gets, hasLength(3));
      expect(gets.last.arguments, contains('A12'));
    },
  );

  selectionTest('select all detach returns focus to the empty list region', (
    tester,
  ) async {
    await mount(tester);
    panel.focusList();
    await tester.pumpAndSettle();
    await modified(
      tester,
      LogicalKeyboardKey.controlLeft,
      () => tester.sendKeyEvent(LogicalKeyboardKey.keyA),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.text('Detach 5 attachments from TSK-042?'), findsOneWidget);
    rig.mutation('attachment_detach');
    rig.controller.task.attachments.clear();
    await tester.tap(find.text('Detach (Alt+D)'));
    await tester.pumpAndSettle();
    expect(panel.list.selectedIndex, isNull);
    expect(panel.list.hasListFocus, isTrue);
    expect(panel.list.focusedRowIndex, isNull);
    expect(panel.item, isNull);
  });

  selectionTest(
    'another list retains its single-selection semantics and activation',
    (tester) async {
      final list = VirtualListController();
      addTearDown(list.dispose);
      final activations = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AccessibleVirtualList(
            controller: list,
            itemCount: 5,
            itemExtent: 64,
            listLabel: 'Projects',
            emptyLabel: 'Empty',
            itemKeyBuilder: (i) => ValueKey(12 + i),
            rowSemanticsBuilder: (i) =>
                AccessibleRowSemantics(label: 'Project $i'),
            rowBuilder: (_, i, _) => Text('Project $i'),
            onActivate: activations.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('multi-selection-check')), findsNothing);
      expect(find.byKey(const ValueKey('multi-lead-marker')), findsNothing);
      await click(tester, 1);
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => click(tester, 3),
      );
      expect(selected(tester), {3});
      await modified(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => click(tester, 1),
      );
      expect(selected(tester), {1});
      await modified(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.arrowDown),
      );
      expect(selected(tester), {2});
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.space),
      );
      expect(activations, [2]);
      expect(selected(tester), {2});
      await modified(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.keyA),
      );
      expect(selected(tester), {2});
    },
  );
}
