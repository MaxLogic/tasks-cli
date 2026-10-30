/// Synthetic-store smoke of the real CLI path; never uses the default backlog.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as real;
import 'real_cli_attachment_keyboard_test.dart' as keyboard;

void main() {
  testWidgets(
    'real CLI 1000 rows: distant F5, ID reverse and bounded filter',
    (tester) async {
      final h = (await tester.runAsync(() async {
        final h = await real.Harness.start();
        final body = '${h.root.path}/body.md';
        for (var id = 2; id <= 1000; id++) {
          final result = await h.command([
            'create',
            '--title',
            '${id.isEven ? 'Even' : 'Odd'} task $id',
            '--body-file',
            body,
            '--status',
            'todo',
          ]);
          expect(result['id'], id);
        }
        return h;
      }))!;
      await keyboard.mount(tester, h);
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      final shell = tester.state<ViewerShellState>(find.byType(ViewerShell));
      final list = shell.handlesFor(ViewerRegion.tasks).list;
      await tester.runAsync(() async {
        model.tasks!.setSort(TaskSort.id);
        await model.tasks!.refresh();
      });
      await real.waitFor(tester, () => !model.tasks!.isLoading);
      debugPrint(
        'SMOKE sorted total=${model.tasks!.totalCount} selected=${model.tasks!.selectedTaskId} failure=${model.tasks!.refreshFailure}',
      );
      list.focusRegion();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.sync(() => list.goToIndex(950)));
      await real.waitFor(
        tester,
        () => model.tasks!.selectedTaskId == 951 && list.focusedRowIndex == 950,
      );
      var before = h.launcher.calls.length;
      await tester.runAsync(
        () => support.pressKey(tester, LogicalKeyboardKey.f5),
      );
      await real.waitFor(
        tester,
        () =>
            !model.tasks!.isLoading &&
            !model.projectList.isLoading &&
            !model.detail!.isLoading,
      );
      expect(model.tasks!.selectedTaskId, 951);
      expect(list.selectedIndex, 950);
      expect(list.focusedRowIndex, 950);
      expect(model.detail!.detail!.id, 951);
      expect(
        h.launcher.calls
            .skip(before)
            .where((a) => a.contains('viewer') && a.contains('tasks'))
            .length,
        1,
      );
      before = h.launcher.calls.length;
      await tester.runAsync(
        () => support.pressAlt(tester, LogicalKeyboardKey.keyI),
      );
      await real.waitFor(
        tester,
        () => !model.tasks!.isLoading && list.focusedRowIndex == 49,
      );
      expect(model.tasks!.selectedTaskId, 951);
      expect(list.selectedIndex, 49);
      expect(
        h.launcher.calls
            .skip(before)
            .where((a) => a.contains('viewer') && a.contains('tasks'))
            .length,
        1,
      );
      shell.handlesFor(ViewerRegion.tasks).filterFocus.requestFocus();
      await tester.pumpAndSettle();
      before = h.launcher.calls.length;
      await tester.runAsync(() async {
        model.tasks!.setQuery('Even');
        await model.tasks!.submitQuery();
      });
      await real.waitFor(tester, () => !model.tasks!.isLoading);
      expect(model.tasks!.totalCount, 500);
      expect(model.tasks!.selectedTaskId, 951);
      expect(list.selectedIndex, isNull);
      expect(model.detail!.detail!.id, 951);
      expect(
        h.launcher.calls
            .skip(before)
            .where((a) => a.contains('viewer') && a.contains('tasks'))
            .length,
        1,
      );
      await support.pressKey(tester, LogicalKeyboardKey.f2);
      expect(list.focusedRowIndex, isNull);
      expect(model.tasks!.selectedTaskId, 951);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => h.launcher.idle);
    },
    skip: real.cli.isEmpty,
  );
}
