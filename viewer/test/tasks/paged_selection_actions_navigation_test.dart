import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import '../support/model_store.dart';
import '../support/model_viewer_driver.dart';

Finder listView(ModelViewerDriver d, ViewerRegion region) =>
    find.byWidgetPredicate(
      (w) =>
          w is AccessibleVirtualList &&
          identical(w.controller, d.h.list(region)),
    );

Finder viewport(ModelViewerDriver d, ViewerRegion region) => find
    .descendant(of: listView(d, region), matching: find.byType(Scrollable))
    .first;

List<String> focusedLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isFocused == ui.Tristate.isTrue) {
      labels.add(data.label);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return labels;
}

Future<void> key(ModelViewerDriver d, LogicalKeyboardKey key) async {
  await d.tester.sendKeyEvent(key, platform: 'windows');
  await d.settle();
  await d.tester.pumpAndSettle();
}

void expectVisibleSelection(
  ModelViewerDriver d,
  ViewerRegion region,
  int index,
) {
  final controller = d.h.list(region);
  expect(controller.focusedRowIndex, index);
  expect(controller.selectedIndex, index);
  final dynamic model = region == ViewerRegion.projects
      ? d.h.model.projectList
      : d.h.model.tasks!;
  expect(model.selectedIndex, index);
  final primary = FocusManager.instance.primaryFocus!;
  final row = primary.debugLabel == 'list-row-$index'
      ? primary
      : primary.ancestors.firstWhere(
          (node) => node.debugLabel == 'list-row-$index',
        );
  final bounds = d.tester.getRect(viewport(d, region));
  expect(row.rect.top, greaterThanOrEqualTo(bounds.top - 0.5));
  expect(row.rect.bottom, lessThanOrEqualTo(bounds.bottom + 0.5));
  final identity =
      '${region == ViewerRegion.projects ? 'Project ' : 'T-'}'
      '${(index + 1).toString().padLeft(3, '0')}';
  expect(
    focusedLabels(d.tester).any((label) => label.contains(identity)),
    isTrue,
    reason: 'The focused row must remain exposed in the semantics tree',
  );
}

Future<void> actions(
  ModelViewerDriver d,
  ViewerRegion region,
  int index,
) async {
  await d.select(region, index);
  await key(d, LogicalKeyboardKey.tab);
  expect(
    FocusManager.instance.primaryFocus?.debugLabel,
    isNot('list-row-$index'),
  );
  expect(
    focusedLabels(d.tester).any((label) => label.startsWith('Actions for ')),
    isTrue,
  );
  expectVisibleSelection(d, region, index);
}

void main() {
  for (final region in [ViewerRegion.tasks, ViewerRegion.projects]) {
    Future<ModelViewerDriver> mount(WidgetTester tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(
          count: region == ViewerRegion.tasks ? 300 : 5,
          projectCount: region == ViewerRegion.projects ? 300 : 2,
          delay: const Duration(milliseconds: 150),
        ),
      );
      await d.mount();
      addTearDown(d.close);
      return d;
    }

    for (final navigation in [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
    ]) {
      testWidgets('R7-1 Actions navigation $region ${navigation.keyLabel}', (
        tester,
      ) async {
        final d = await mount(tester);
        const start = 99;
        await actions(d, region, start);
        await key(d, navigation);
        final index = d.h.list(region).selectedIndex!;
        if (navigation == LogicalKeyboardKey.arrowUp) {
          expect(index, start - 1);
        } else if (navigation == LogicalKeyboardKey.arrowDown) {
          expect(index, start + 1);
        } else if (navigation == LogicalKeyboardKey.home) {
          expect(index, 0);
        } else if (navigation == LogicalKeyboardKey.end) {
          expect(index, 299);
        } else {
          expect(
            index,
            navigation == LogicalKeyboardKey.pageUp
                ? lessThan(start)
                : greaterThan(start),
          );
        }
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'list-row-$index',
          reason:
              'Navigation from Actions lands on the row, not another button',
        );
        expectVisibleSelection(d, region, index);
      });
    }

    for (final first in [true, false]) {
      testWidgets('R7-1 Actions boundary $region first=$first', (tester) async {
        final d = await mount(tester);
        final index = first ? 0 : 299;
        await actions(d, region, index);
        final focusedAction = FocusManager.instance.primaryFocus;
        final position = tester
            .state<ScrollableState>(viewport(d, region))
            .position;
        final offset = position.pixels;
        for (final navigation
            in first
                ? [
                    LogicalKeyboardKey.arrowUp,
                    LogicalKeyboardKey.pageUp,
                    LogicalKeyboardKey.home,
                  ]
                : [
                    LogicalKeyboardKey.arrowDown,
                    LogicalKeyboardKey.pageDown,
                    LogicalKeyboardKey.end,
                  ]) {
          await key(d, navigation);
          expectVisibleSelection(d, region, index);
          expect(FocusManager.instance.primaryFocus, same(focusedAction));
          expect(
            position.pixels,
            offset,
            reason: 'Boundary keys must not scroll the focused row away',
          );
        }
      });
    }

    for (final activation in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.f10,
    ]) {
      testWidgets('R6-2 Actions menu $region ${activation.keyLabel}', (
        tester,
      ) async {
        final d = await mount(tester);
        await actions(d, region, 3);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await key(d, LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-row-3');
        await key(d, LogicalKeyboardKey.tab);
        if (activation == LogicalKeyboardKey.f10) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        }
        await key(d, activation);
        if (activation == LogicalKeyboardKey.f10) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
        expect(
          find.byWidgetPredicate((w) => w is PopupMenuEntry),
          findsWidgets,
        );
        await key(d, LogicalKeyboardKey.escape);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-row-3');
        expectVisibleSelection(d, region, 3);
      });
    }

    testWidgets('R6-2 Enter on $region row activates its pane', (tester) async {
      final d = await mount(tester);
      tester.view.physicalSize = const Size(600, 900);
      await d.settle();
      expect(d.h.shell.isReducedLayout, isTrue);
      d.h.shell.revealRegion(region);
      await d.settle();
      await d.select(region, 3);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-row-3');
      await key(d, LogicalKeyboardKey.enter);
      expect(listView(d, region), findsNothing);
      if (region == ViewerRegion.projects) {
        expect(listView(d, ViewerRegion.tasks), findsOneWidget);
      } else {
        expect(find.text('Task 0004'), findsWidgets);
      }
      expect(find.byWidgetPredicate((w) => w is PopupMenuEntry), findsNothing);
    });
  }
}
