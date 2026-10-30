import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';

void main() {
  testWidgets(
    'UX3 source reverse reuses focused node without region transition',
    (tester) async {
      final list = VirtualListController();
      final changed = ValueNotifier(0);
      var rows = List.generate(205, (i) => i + 1);
      int? selected;
      final sequence = <FocusNode?>[];
      void record() => sequence.add(FocusManager.instance.primaryFocus);
      FocusManager.instance.addListener(record);
      addTearDown(() => FocusManager.instance.removeListener(record));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ValueListenableBuilder(
                valueListenable: changed,
                builder: (context, value, _) => AccessibleVirtualList(
                  controller: list,
                  itemCount: rows.length,
                  itemExtent: 40,
                  listLabel: 'Tasks',
                  emptyLabel: 'Empty',
                  motionKey: ListMotionKey(scope: 'tasks', epoch: value),
                  selectionSource: VirtualListSelection(
                    selectedKey: selected == null ? null : ValueKey(selected),
                    selectedIndex: selected == null
                        ? null
                        : rows.indexOf(selected!),
                  ),
                  itemKeyBuilder: (i) => ValueKey(rows[i]),
                  rowBuilder: (c, i, s) => Text('${rows[i]} $s'),
                  rowSemanticsBuilder: (i) =>
                      AccessibleRowSemantics(label: 'Task ${rows[i]}'),
                  onSelectedIndexChanged: (i) {
                    selected = rows[i];
                    changed.value++;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      list.focusRegion();
      await tester.pumpAndSettle();
      list.goToIndex(7);
      await tester.pumpAndSettle();
      final node = FocusManager.instance.primaryFocus;
      expect(selected, 8);
      sequence.clear();
      rows = rows.reversed.toList();
      changed.value++;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(identical(FocusManager.instance.primaryFocus, node), isTrue);
      expect(list.focusedRowIndex, 197);
      expect(list.selectedIndex, 197);
      expect(
        sequence.where((n) => n != node),
        isEmpty,
        reason: 'No intermediate region/scope/window focus',
      );
      await tester.pumpWidget(const SizedBox());
      changed.dispose();
      list.dispose();
    },
  );
  testWidgets(
    'UX2 source has no seed highlight; retained entry does not select',
    (tester) async {
      final list = VirtualListController();
      var notifications = 0;
      Widget view(VirtualListSelection source) => MaterialApp(
        home: Scaffold(
          body: AccessibleVirtualList(
            controller: list,
            itemCount: 3,
            itemExtent: 40,
            listLabel: 'Tasks',
            emptyLabel: 'Empty',
            selectionSource: source,
            itemKeyBuilder: (i) => ValueKey(i),
            rowBuilder: (c, i, s) => Text('$i $s'),
            rowSemanticsBuilder: (i) =>
                AccessibleRowSemantics(label: 'Task $i'),
            onSelectedIndexChanged: (_) => notifications++,
          ),
        ),
      );
      await tester.pumpWidget(
        view(
          const VirtualListSelection(selectedKey: null, selectedIndex: null),
        ),
      );
      expect(list.selectedIndex, isNull);
      expect(list.selectedIndices, isEmpty);
      await tester.pumpWidget(
        view(
          const VirtualListSelection(
            selectedKey: ValueKey(99),
            selectedIndex: null,
            unplacedLabel: 'Selected task T-099 is not in the loaded rows',
          ),
        ),
      );
      list.focusRegion();
      await tester.pumpAndSettle();
      expect(list.focusedRowIndex, isNull);
      expect(notifications, 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-region');
      await tester.pumpWidget(const SizedBox());
      list.dispose();
    },
  );
  testWidgets(
    'U2 unloaded jump retains current row focus and failPending stops timer',
    (tester) async {
      final list = VirtualListController();
      var slow = 0;
      int? requested;
      var selected = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: AccessibleVirtualList(
                controller: list,
                itemCount: 205,
                itemExtent: 40,
                listLabel: 'Tasks',
                emptyLabel: 'Empty',
                selectionSource: VirtualListSelection(
                  selectedKey: ValueKey(selected),
                  selectedIndex: 0,
                ),
                itemKeyBuilder: (i) => ValueKey(i + 1),
                isRowReady: (i) => i < 100,
                rowBuilder: (c, i, s) => Text('$i'),
                rowSemanticsBuilder: (i) =>
                    AccessibleRowSemantics(label: 'Task $i'),
                onRowRequested: (i) => requested = i,
                onPendingRowSlow: (_) => slow++,
                onSelectedIndexChanged: (i) => selected = i + 1,
              ),
            ),
          ),
        ),
      );
      list.focusRegion();
      await tester.pumpAndSettle();
      final node = FocusManager.instance.primaryFocus;
      list.goToIndex(150);
      await tester.pump();
      expect(requested, 150);
      expect(FocusManager.instance.primaryFocus, node);
      expect(selected, 1);
      expect(list.selectedIndex, 0);
      list.failPending(150);
      await tester.pump(const Duration(seconds: 2));
      expect(list.hasPendingTarget, isFalse);
      expect(slow, 0);
      expect(FocusManager.instance.primaryFocus, node);
      await tester.pumpWidget(const SizedBox());
      list.dispose();
    },
  );
  testWidgets('unlocated container arrow targets first real row', (
    tester,
  ) async {
    final list = VirtualListController();
    int? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleVirtualList(
            controller: list,
            itemCount: 3,
            itemExtent: 40,
            listLabel: 'Tasks',
            emptyLabel: 'Empty',
            selectionSource: const VirtualListSelection(
              selectedKey: ValueKey(99),
              selectedIndex: null,
            ),
            itemKeyBuilder: (i) => ValueKey(i),
            rowBuilder: (c, i, s) => Text('$i'),
            rowSemanticsBuilder: (i) =>
                AccessibleRowSemantics(label: 'Task $i'),
            onSelectedIndexChanged: (i) => requested = i,
          ),
        ),
      ),
    );
    list.focusRegion();
    await tester.pumpAndSettle();
    expect(list.focusedRowIndex, isNull);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.arrowDown,
      platform: 'windows',
    );
    await tester.pumpAndSettle();
    expect(requested, 0);
    expect(list.focusedRowIndex, 0);
    await tester.pumpWidget(const SizedBox());
    list.dispose();
  });

  testWidgets('refusal with no located row keeps the labelled container', (
    tester,
  ) async {
    final list = VirtualListController();
    final requests = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleVirtualList(
            controller: list,
            itemCount: 3,
            itemExtent: 40,
            listLabel: 'Tasks',
            emptyLabel: 'Empty',
            selectionSource: const VirtualListSelection(
              selectedKey: null,
              selectedIndex: null,
            ),
            itemKeyBuilder: (i) => ValueKey(i),
            rowBuilder: (c, i, s) => Text('$i'),
            rowSemanticsBuilder: (i) =>
                AccessibleRowSemantics(label: 'Task $i'),
            onSelectedIndexChanged: (i) {
              requests.add(i);
              list.refuseMove(i, null);
            },
          ),
        ),
      ),
    );
    list.focusRegion();
    await tester.pumpAndSettle();
    expect(requests, [0]);
    expect(list.focusedRowIndex, isNull);
    expect(list.hasListFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    list.dispose();
  });
}
