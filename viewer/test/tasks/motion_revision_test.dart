import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/tasks_pane.dart';
import 'package:tasks_viewer/ui/viewer_motion.dart';
import '../details/details_pane_test.dart' show pumpTaskDetails;
import '../support/viewer_test_support.dart';

void main() {
  testWidgets('Filters reserves its final viewport once, also after search', (
    tester,
  ) async {
    final h = await pumpTaskDetails(tester);
    final list = find.descendant(
      of: find.byType(ViewerTasksPane),
      matching: find.byType(AccessibleVirtualList),
    );
    for (final afterSearch in [false, true]) {
      if (afterSearch) {
        h.model.tasks!.setQuery('First');
        await h.model.tasks!.submitQuery();
        await tester.pumpAndSettle();
        h.model.tasks!.setQuery('');
        await h.model.tasks!.submitQuery();
        await tester.pumpAndSettle();
      }
      final focus = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Filters'))
          .focusNode;
      await tester.tap(find.byTooltip('Show filters (Alt+F)'));
      await tester.pump();
      final target = tester.getRect(list);
      final fade = find.descendant(
        of: find.byType(ViewerDisclosureTransition),
        matching: find.byWidgetPredicate(
          (w) => w is FadeTransition && w.alwaysIncludeSemantics,
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (i == 3) {
          expect(
            tester.widget<FadeTransition>(fade).opacity.value,
            inExclusiveRange(0, 1),
            reason: 'entrance runs even after a query',
          );
        }
        expect(
          tester.getRect(list),
          target,
          reason: 'list viewport must not resize per animation frame',
        );
      }
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Hide filters'))
            .focusNode,
        same(focus),
      );
      expect(focus!.hasFocus, isTrue);
      await tester.tap(find.widgetWithText(TextButton, 'Hide filters'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    '1280 project search has room and Clear search stays on one line',
    (tester) async {
      await pumpRealViewer(tester, surface: const Size(1280, 720));
      final search = textFieldWithLabel('Search projects (Ctrl+F)');
      expect(tester.getSize(search).width, greaterThanOrEqualTo(220));
      final clear = find.text('Clear search').first;
      expect(tester.getSize(clear).height, lessThan(25));
      expect(tester.takeException(), isNull);
    },
  );
}
