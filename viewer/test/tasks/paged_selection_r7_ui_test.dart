import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import '../support/model_store.dart';
import '../support/model_viewer_driver.dart';
import '../support/viewer_test_support.dart';
import 'paged_selection_status_layout_test.dart' show loadSegoe;

const locked = ViewerCliErrorFailure(
  code: 'locked',
  message:
      'The task database is busy because another process is writing. '
      'Close the other application, check that the network share is available '
      'and try the refresh again.',
  exitCode: 4,
);

Finder view(ModelViewerDriver d, ViewerRegion region) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) =>
            w is AccessibleVirtualList &&
            identical(w.controller, d.h.list(region)),
      ),
      matching: find.byType(Scrollable),
    )
    .first;
Future<void> key(ModelViewerDriver d, LogicalKeyboardKey k) async {
  await d.tester.sendKeyEvent(k, platform: 'windows');
  await d.settle();
}

Future<void> shiftTab(ModelViewerDriver d) async {
  await d.tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await key(d, LogicalKeyboardKey.tab);
  await d.tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await d.settle();
}

void main() {
  for (final focused in [false, true]) {
    for (final trigger in ['F5', 'reverse', 'filter', 'retry']) {
      testWidgets('C6c saved recovery $trigger focus=$focused', (tester) async {
        final d = ModelViewerDriver(
          tester,
          ModelStore(count: 205, delay: const Duration(milliseconds: 150)),
        );
        await d.mount();
        await d.select(ViewerRegion.tasks, 150);
        await key(d, LogicalKeyboardKey.f4);
        d.h.model.editor.setField(EditorField.status, 'done');
        d.store.failure = (r) => r.scope == 'tasks' ? locked : null;
        await pressControl(tester, LogicalKeyboardKey.keyS);
        await d.settle();
        final c = d.h.model.tasks!;
        expect(c.refreshFailure, isNotNull);
        if (focused) {
          await key(d, LogicalKeyboardKey.f2);
          expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, 150);
        }
        d.store.failure = null;
        switch (trigger) {
          case 'F5':
            await key(d, LogicalKeyboardKey.f5);
          case 'reverse':
            if (focused) {
              await pressAlt(tester, LogicalKeyboardKey.keyI);
            } else {
              c.setDirection(SortDirection.descending);
            }
            await d.settle();
          case 'filter':
            c.setQuery('not-present-anywhere');
            await d.start(c.submitQuery());
          case 'retry':
            await d.start(c.retry());
        }
        expect(c.selectedTaskId, 151);
        expect(c.retainedText, 'Saved task no longer matches these filters');
        if (c.totalCount > 0) {
          final scroll = tester
              .state<ScrollableState>(view(d, ViewerRegion.tasks))
              .position;
          final listWidget = tester.widget<AccessibleVirtualList>(
            find.byWidgetPredicate(
              (w) =>
                  w is AccessibleVirtualList &&
                  identical(w.controller, d.h.list(ViewerRegion.tasks)),
            ),
          );
          expect(
            c.itemAt((scroll.pixels / listWidget.itemExtent).floor()),
            isNotNull,
            reason: 'Saved recovery must keep its loaded anchor page visible',
          );
        }

        if (focused) {
          expect(d.h.list(ViewerRegion.tasks).hasFocus, isTrue);
          expect(d.h.list(ViewerRegion.tasks).focusedRowIndex, isNull);
        }
        await d.close();
      });
    }
  }
  for (final focused in [false, true]) {
    testWidgets('C6b Go to saved same ID then exclusion focus=$focused', (
      tester,
    ) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(count: 300, delay: const Duration(milliseconds: 150)),
      );
      await d.mount();
      await d.select(ViewerRegion.tasks, 150);
      await key(d, LogicalKeyboardKey.f4);
      d.h.model.editor.setField(EditorField.title, 'Edited task 151');
      d.store.failure = (r) => r.scope == 'tasks' ? locked : null;
      await pressControl(tester, LogicalKeyboardKey.keyS);
      await d.settle();
      final c = d.h.model.tasks!;
      expect(c.refreshFailure, isNotNull);
      d.store.failure = null;
      c.setQuery('body');
      await d.start(c.submitQuery());
      expect(c.selectedIndex, isNull);
      expect(c.selectedTaskId, 151);
      // Same-ID focus/navigation must not depend on select() changing identity.
      await d.select(ViewerRegion.tasks, 150);
      expect(c.selectedIndex, 150);
      expect(c.selectedTaskId, 151);
      if (!focused) {
        d.h.handles(ViewerRegion.tasks).filterFocus.requestFocus();
        await d.settle();
      }
      c.setQuery('not-present-anywhere');
      await d.start(c.submitQuery());
      expect(c.selectedTaskId, isNull);
      expect(c.retainedText, isNull);
      await d.close();
    });
  }
  for (final projects in [false, true]) {
    final region = projects ? ViewerRegion.projects : ViewerRegion.tasks;
    Future<ModelViewerDriver> mount(WidgetTester tester) async {
      final d = ModelViewerDriver(
        tester,
        ModelStore(
          count: projects ? 5 : 1000,
          projectCount: projects ? 300 : 2,
          delay: const Duration(milliseconds: 150),
        ),
      );
      await d.mount();
      return d;
    }

    testWidgets('UX-R6-1 query has visible loaded rows $region', (
      tester,
    ) async {
      final d = await mount(tester);
      await d.select(region, 150);
      final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
      final id = c.selection.id;
      c.setQuery(projects ? 'Project' : 'needle');
      await d.start(c.submitQuery() as Future<void>);
      final scroll = tester.state<ScrollableState>(view(d, region)).position;
      final listWidget = tester.widget<AccessibleVirtualList>(
        find.byWidgetPredicate(
          (w) =>
              w is AccessibleVirtualList &&
              identical(w.controller, d.h.list(region)),
        ),
      );
      final first = (scroll.pixels / listWidget.itemExtent).floor();
      expect(
        c.itemAt(first),
        isNotNull,
        reason: 'visible first row $first is a placeholder',
      );
      expect(c.selection.id, id);
      expect(c.selectedIndex, isNull);
      expect(d.h.list(region).focusedRowIndex, isNull);
      await d.close();
    });
    for (final activation in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
    ]) {
      testWidgets('UX-R6-2 Actions activates $region $activation', (
        tester,
      ) async {
        final d = await mount(tester);
        await d.select(region, 3);
        await key(d, LogicalKeyboardKey.tab);
        final action = FocusManager.instance.primaryFocus;
        expect(d.h.list(region).focusedRowIndex, 3);
        await shiftTab(d);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-row-3');
        await key(d, LogicalKeyboardKey.tab);
        expect(FocusManager.instance.primaryFocus, same(action));
        await key(d, activation);
        expect(
          find.byWidgetPredicate((w) => w is PopupMenuEntry),
          findsWidgets,
        );
        await key(d, LogicalKeyboardKey.escape);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'list-row-3');
        await d.focus(region);
        await key(d, LogicalKeyboardKey.tab);
        await key(d, LogicalKeyboardKey.tab);
        expect(d.h.list(region).hasFocus, isFalse);
        await d.close();
      });
    }
    testWidgets(
      'UX-R6-4 reverse traversal has named previous control $region',
      (tester) async {
        final d = await mount(tester);
        await d.select(region, 3);
        await shiftTab(d);
        final primary = FocusManager.instance.primaryFocus!;
        final listElement = tester.element(
          find.byWidgetPredicate(
            (w) =>
                w is AccessibleVirtualList &&
                identical(w.controller, d.h.list(region)),
          ),
        );
        expect(
          primary,
          isNot(same(Focus.of(listElement))),
          reason: 'unnamed pane key handler must not be a Tab stop',
        );
        expect(d.h.list(region).hasFocus, isFalse);
        await d.close();
      },
    );
    for (final width in [1366.0, 1600.0]) {
      testWidgets('UX-R6-5 status growth reveals focused row $region $width', (
        tester,
      ) async {
        await loadSegoe();
        tester.view.physicalSize = Size(width, width == 1366 ? 768 : 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final d = await mount(tester);
        tester.view.physicalSize = Size(width, width == 1366 ? 768 : 900);
        await d.pump();
        await d.select(region, 150);
        final focus = FocusManager.instance.primaryFocus!;
        final dynamic c = projects ? d.h.model.projectList : d.h.model.tasks!;
        d.store.failure = (_) => locked;
        unawaited(c.refresh() as Future<void>);
        await d.settle();
        expect(c.refreshFailure, isNotNull);
        expect(FocusManager.instance.primaryFocus, same(focus));
        await tester.pumpAndSettle();
        final viewport = tester.getRect(view(d, region));
        expect(focus.rect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(focus.rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
        await d.close();
      });
    }
  }
}
