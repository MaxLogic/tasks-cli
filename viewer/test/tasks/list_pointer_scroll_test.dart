import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';

Future<(VirtualListController, List<int>, ScrollPosition)> mount(
  WidgetTester tester,
  int count, {
  bool multiSelect = false,
}) async {
  final controller = VirtualListController();
  addTearDown(controller.dispose);
  final activated = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            height: 300,
            child: AccessibleVirtualList(
              controller: controller,
              multiSelect: multiSelect,
              itemCount: count,
              itemExtent: 64,
              listLabel: 'Attachments',
              emptyLabel: 'Empty',
              itemKeyBuilder: (index) => ValueKey(index),
              rowSemanticsBuilder: (index) =>
                  AccessibleRowSemantics(label: 'Attachment $index'),
              rowBuilder: (_, index, selected) => SizedBox.expand(
                key: ValueKey('body-$index'),
                child: Text('Attachment $index'),
              ),
              activateOnDoubleTap: true,
              onActivate: activated.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final position = tester
      .state<ScrollableState>(find.byType(Scrollable))
      .position;
  return (controller, activated, position);
}

void main() {
  testWidgets(
    'multi-select focus return retains selection across virtualized rows',
    (tester) async {
      final (controller, _, position) = await mount(
        tester,
        100,
        multiSelect: true,
      );
      await tester.tap(
        find.byKey(const ValueKey('body-1')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(
        find.byKey(const ValueKey('body-3')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.selectedIndices, {1, 3});
      final outside = FocusNode();
      addTearDown(outside.dispose);
      FocusScope.of(
        tester.element(find.byType(AccessibleVirtualList)),
      ).requestFocus(outside);
      await tester.pumpAndSettle();
      expect(outside.hasFocus, isTrue);
      position.jumpTo(64 * 80);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('body-3')), findsNothing);
      controller.focusRegion();
      await tester.pumpAndSettle();
      expect(controller.focusedRowIndex, 3);
      expect(controller.selectedIndices, {1, 3});
    },
  );

  testWidgets('multi-select pointer gestures never scroll the clicked rows', (
    tester,
  ) async {
    final (controller, activated, position) = await mount(
      tester,
      20,
      multiSelect: true,
    );
    position.jumpTo(37);
    await tester.pumpAndSettle();
    Future<void> click(int index) async {
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('body-$index'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(position.pixels, 37);
      expect(controller.focusedRowIndex, index);
      await pointer.up();
    }

    await click(1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click(3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.selectedIndices, {1, 3});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.selectedIndices, {2, 3});
    expect(position.pixels, 37);
    expect(activated, isEmpty);
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpWidget(const SizedBox());
  });

  for (final count in [3, 8, 20, 100]) {
    testWidgets('visible rows stay under the pointer, count=$count', (
      tester,
    ) async {
      final (controller, activated, position) = await mount(tester, count);
      final viewport = tester.getRect(find.byType(AccessibleVirtualList));
      for (final offset in {0.0, 37.0, 192.0, position.maxScrollExtent}) {
        if (offset > position.maxScrollExtent) continue;
        position.jumpTo(offset);
        await tester.pumpAndSettle();
        final first = (offset / 64).floor();
        final end = math.min(count, ((offset + 300) / 64).ceil());
        for (var index = first; index < end; index++) {
          final row = find.byKey(ValueKey('body-$index'));
          final before = tester.getRect(row);
          final point = before.intersect(viewport).center;
          controller.selectIndex(null);
          activated.clear();
          await tester.pump();
          final pointer = await tester.startGesture(
            point,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          expect(controller.selectedIndex, index);
          expect(controller.focusedRowIndex, index);
          expect(position.pixels, offset, reason: 'mouse-down must not scroll');
          expect(tester.getRect(row), before);
          await pointer.up();
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tapAt(point, kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          expect(activated, [index], reason: 'same row activates exactly once');
          expect(controller.selectedIndex, index);
          expect(position.pixels, offset);
          expect(tester.getRect(row), before);
          await tester.pump(kDoubleTapTimeout);
        }
      }
    });
  }

  testWidgets(
    'keyboard reveals hidden edges minimally and leaves visible rows',
    (tester) async {
      final (controller, _, position) = await mount(tester, 20);
      position.jumpTo(192);
      await tester.pumpAndSettle();
      controller.selectIndex(4);
      controller.focusRegion();
      await tester.pumpAndSettle();
      for (final index in [4, 6]) {
        controller.goToIndex(index);
        await tester.pumpAndSettle();
        expect(position.pixels, 192);
        expect(controller.focusedRowIndex, index);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.selectedIndex, 7);
      expect(position.pixels, 212); // Reveal the hidden bottom 20 pixels.
      controller.goToIndex(3);
      await tester.pumpAndSettle();
      expect(position.pixels, 192);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(controller.selectedIndex, 2);
      expect(position.pixels, 128); // Reveal the next row's top edge.
    },
  );

  testWidgets(
    'touch drag leaves selection alone, touch tap selects after release',
    (tester) async {
      final (controller, activated, position) = await mount(tester, 20);
      controller.selectIndex(0);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('body-2'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.selectedIndex, 0);
      await pointer.moveBy(const Offset(0, -40));
      await tester.pump();
      await pointer.moveBy(const Offset(0, -60));
      await tester.pump();
      await pointer.up();
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(controller.selectedIndex, 0);
      expect(activated, isEmpty);

      position.jumpTo(0);
      await tester.pumpAndSettle();
      final tap = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('body-2'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(controller.selectedIndex, 0);
      await tap.up();
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(controller.selectedIndex, 2);
      expect(position.pixels, 0);
      expect(activated, isEmpty);
    },
  );
}
