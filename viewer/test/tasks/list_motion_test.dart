import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';

Widget listFrame(
  VirtualListController controller,
  List<String> items,
  int epoch, {
  bool off = false,
  String scope = 'tasks',
  bool transient = false,
  double extent = 50,
  double height = 300,
  bool Function(int)? ready,
}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(disableAnimations: off),
      child: SizedBox(
        height: height,
        child: AccessibleVirtualList(
          controller: controller,
          itemCount: items.length,
          itemExtent: extent,
          listLabel: 'Tasks',
          emptyLabel: 'Loading tasks',
          emptyIsTransient: transient,
          motionKey: ListMotionKey(scope: scope, epoch: epoch),
          isRowReady: ready,
          itemKeyBuilder: (i) => ValueKey(items[i]),
          rowSemanticsBuilder: (i) => AccessibleRowSemantics(label: items[i]),
          rowBuilder: (context, i, selected) => Text(items[i]),
        ),
      ),
    ),
  ),
);
Finder get listFades => find.descendant(
  of: find.byType(AccessibleVirtualList),
  matching: find.byWidgetPredicate(
    (w) => w is FadeTransition && w.alwaysIncludeSemantics,
  ),
);
Finder get listTransforms => find.descendant(
  of: find.byType(AccessibleVirtualList),
  matching: find.byType(Transform),
);
void expectStatic(WidgetTester tester) {
  expect(
    tester
        .widgetList<FadeTransition>(listFades)
        .every((w) => w.opacity.value == 1),
    isTrue,
  );
  expect(
    tester
        .widgetList<Transform>(listTransforms)
        .every((w) => w.transform.storage[13] == 0),
    isTrue,
  );
}

void main() {
  testWidgets('short reversals enter near final rows instead of crossing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final controller = VirtualListController();
      addTearDown(controller.dispose);
      final rows = ['A', 'B', 'C', 'D', 'E', 'F'];
      for (final blankDuringRead in [false, true]) {
        await tester.pumpWidget(listFrame(controller, rows, 0));
        await tester.pumpAndSettle();
        if (blankDuringRead) {
          await tester.pumpWidget(listFrame(controller, [], 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpWidget(
          listFrame(controller, rows.reversed.toList(), 1),
        );
        await tester.pump(const Duration(milliseconds: 110));
        final top = tester.getTopLeft(find.byType(AccessibleVirtualList)).dy;
        for (var i = 0; i < rows.length; i++) {
          final label = rows.reversed.elementAt(i);
          expect(
            tester.getTopLeft(find.text(label)).dy - top - i * 50,
            inInclusiveRange(0, 6),
            reason: '$label stays in its final row',
          );
          expect(find.bySemanticsLabel(label), findsOneWidget);
        }
        expect(
          tester
              .widgetList<FadeTransition>(listFades)
              .any((w) => w.opacity.value < 1),
          isTrue,
        );
        await tester.pumpAndSettle();
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('small row moves paint an opaque surface during motion', (
    tester,
  ) async {
    final controller = VirtualListController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      listFrame(controller, ['A', 'B', 'C', 'D', 'E', 'F'], 0),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      listFrame(controller, ['B', 'A', 'C', 'D', 'E', 'F'], 1),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final fills = find.descendant(
      of: find.byType(AccessibleVirtualList),
      matching: find.byType(ColoredBox),
    );
    expect(
      tester.widgetList<ColoredBox>(fills).any((w) => w.color.a == 1),
      isTrue,
      reason: 'moving labels cannot overprint through another row',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('reorder focus selection and announcement match motion Off', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final outcomes = <(int?, int?, String, String)>[];
      for (final off in [false, true]) {
        final controller = VirtualListController();
        var rows = ['A', 'B', 'X', 'C', 'D', 'E'];
        var announced = '';
        Widget frame(int epoch) => MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: off),
              child: SizedBox(
                height: 350,
                child: AccessibleVirtualList(
                  controller: controller,
                  itemCount: rows.length,
                  itemExtent: 50,
                  listLabel: 'Tasks',
                  emptyLabel: 'Empty',
                  motionKey: ListMotionKey(
                    scope: 'same task project',
                    epoch: epoch,
                  ),
                  itemKeyBuilder: (i) => ValueKey(rows[i]),
                  rowSemanticsBuilder: (i) =>
                      AccessibleRowSemantics(label: rows[i]),
                  rowBuilder: (context, i, selected) => Text(rows[i]),
                  onSelectedIndexChanged: (i) => announced = rows[i],
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(frame(0));
        await tester.pumpAndSettle();
        controller.goToIndex(2);
        await tester.pumpAndSettle();
        rows = ['B', 'A', 'C', 'D', 'E', 'X'];
        await tester.pumpWidget(frame(1));
        // The owner restores the selected identity after its result commit.
        controller.selectIndex(5);
        controller.focusRegion();
        await tester.pump(const Duration(milliseconds: 60));
        expect(controller.hasFocus, isTrue);
        expect(find.bySemanticsLabel('X'), findsOneWidget);
        await tester.pumpAndSettle();
        outcomes.add((
          controller.selectedIndex,
          controller.focusedRowIndex,
          tester.getSemantics(find.bySemanticsLabel('X')).label,
          announced,
        ));
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
      expect(outcomes[0], outcomes[1]);
      expect(outcomes[0], (5, 5, 'X', 'X'));
    } finally {
      semantics.dispose();
    }
  });

  for (final scenario in [
    'first load',
    'scope switch',
    'stale snapshot',
    'more than 80 mounted',
    'pending jump',
    'page fill',
  ]) {
    testWidgets('no list motion on $scenario', (tester) async {
      final controller = VirtualListController();
      addTearDown(controller.dispose);
      final large = scenario == 'more than 80 mounted';
      final items = List.generate(large ? 160 : 10, (i) => 'Row $i');
      final extent = large ? 2.0 : 50.0;
      bool ready(int i) =>
          scenario != 'page fill' && scenario != 'pending jump';
      await tester.pumpWidget(
        listFrame(controller, items, 0, extent: extent, ready: ready),
      );
      await tester.pumpAndSettle();
      expectStatic(tester);
      switch (scenario) {
        case 'first load':
          break;
        case 'scope switch':
          await tester.pumpWidget(
            listFrame(controller, items.reversed.toList(), 1, scope: 'other'),
          );
        case 'stale snapshot':
          await tester.pumpWidget(listFrame(controller, [], 0));
          await tester.pump(const Duration(milliseconds: 1100));
          await tester.pumpWidget(
            listFrame(controller, items.reversed.toList(), 1),
          );
        case 'more than 80 mounted':
          expect(
            find.textContaining('Row ', skipOffstage: false).evaluate().length,
            greaterThan(80),
          );
          await tester.pumpWidget(
            listFrame(controller, items.reversed.toList(), 1, extent: extent),
          );
        case 'pending jump':
          controller.goToIndex(9);
          expect(controller.hasPendingTarget, isTrue);
          await tester.pumpWidget(
            listFrame(controller, items.reversed.toList(), 1, ready: ready),
          );
        case 'page fill':
          await tester.pumpWidget(
            listFrame(controller, items.reversed.toList(), 0),
          );
      }
      await tester.pump();
      expectStatic(tester);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    '100000 rows retain only the visible window; transient empty semantics are immediate',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final controller = VirtualListController();
        addTearDown(controller.dispose);
        final rows = List.generate(100000, (i) => 'Row $i');
        await tester.pumpWidget(listFrame(controller, rows, 0));
        await tester.pumpAndSettle();
        expect(listFades.evaluate().length, lessThan(80));
        await tester.pumpWidget(listFrame(controller, [], 0, transient: true));
        expect(find.bySemanticsLabel('Tasks. Loading tasks'), findsOneWidget);
        expect(tester.widget<FadeTransition>(listFades).opacity.value, 0);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.widget<FadeTransition>(listFades).opacity.value,
          inExclusiveRange(0, 1),
        );
        await tester.pumpWidget(listFrame(controller, rows, 1));
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('scroll finishes motion in the same frame', (tester) async {
    final controller = VirtualListController();
    addTearDown(controller.dispose);
    final rows = List.generate(40, (i) => 'Row $i');
    await tester.pumpWidget(listFrame(controller, rows, 0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(listFrame(controller, rows.reversed.toList(), 1));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester
          .widgetList<FadeTransition>(listFades)
          .any((f) => f.opacity.value < 1),
      isTrue,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();
    expectStatic(tester);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'reorder is paint-only, uniquely named, and keyboard completes it',
    (tester) async {
      final semantics = tester.ensureSemantics();

      final controller = VirtualListController();
      addTearDown(controller.dispose);
      Widget frame(
        List<String> items,
        int epoch, {
        bool off = false,
        String scope = 'tasks',
      }) => MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(disableAnimations: off),
            child: SizedBox(
              height: 300,
              child: AccessibleVirtualList(
                controller: controller,
                itemCount: items.length,
                itemExtent: 50,
                listLabel: 'Tasks',
                emptyLabel: 'Loading tasks',
                motionKey: ListMotionKey(scope: scope, epoch: epoch),
                itemKeyBuilder: (i) => ValueKey(items[i]),
                rowSemanticsBuilder: (i) =>
                    AccessibleRowSemantics(label: items[i]),
                rowBuilder: (context, i, selected) => Text(items[i]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(frame(['A', 'B', 'C', 'D'], 0));
      await tester.pumpAndSettle();
      controller.goToIndex(2);
      await tester.pumpAndSettle();
      await tester.pumpWidget(frame(['B', 'A', 'D', 'C', 'E'], 1));
      await tester.pump(const Duration(milliseconds: 60));
      final transforms = tester
          .widgetList<Transform>(
            find.descendant(
              of: find.byType(AccessibleVirtualList),
              matching: find.byType(Transform),
            ),
          )
          .toList();
      expect(transforms.any((w) => w.transform.storage[13].abs() > .1), isTrue);
      for (final label in ['A', 'B', 'C', 'D', 'E']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
      final fades = tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(AccessibleVirtualList),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(
        fades.any((w) => w.opacity.value < 1 && w.alwaysIncludeSemantics),
        isTrue,
      );
      controller.focusRegion();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        tester
            .widgetList<Transform>(
              find.descendant(
                of: find.byType(AccessibleVirtualList),
                matching: find.byType(Transform),
              ),
            )
            .every((w) => w.transform.storage[13] == 0),
        isTrue,
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(frame(['E', 'D', 'C'], 2, off: true));
      await tester.pump();
      expect(
        tester
            .widgetList<FadeTransition>(
              find.descendant(
                of: find.byType(AccessibleVirtualList),
                matching: find.byType(FadeTransition),
              ),
            )
            .every((w) => w.opacity.value == 1),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
