import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/controllers/task_controller.dart';
import 'package:tasks_viewer/ui/accessible_virtual_list.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'model_store.dart';
import 'viewer_test_support.dart';

/// Drives real panes while advancing every fake read and recording mid-read state.
class ModelViewerDriver {
  ModelViewerDriver(this.tester, this.store);
  final WidgetTester tester;
  final ModelStore store;
  late RealViewerHarness h;
  VoidCallback? onPump;
  Future<void> pump([int milliseconds = 50]) async {
    await tester.pump(Duration(milliseconds: milliseconds));
    onPump?.call();
  }

  Future<void> settle() async {
    for (var i = 0; i < 200; i++) {
      await pump(100);
      if (store.activeReads == 0 &&
          !h.model.projectList.isLoading &&
          !(h.model.tasks?.isLoading ?? false) &&
          !h.list(ViewerRegion.tasks).hasPendingTarget &&
          !h.list(ViewerRegion.projects).hasPendingTarget) {
        await pump(350);
        if (store.activeReads == 0 &&
            !h.model.projectList.isLoading &&
            !(h.model.tasks?.isLoading ?? false)) {
          return;
        }
      }
    }
    fail('Read lane or pending jump did not settle: ${store.step}');
  }

  Future<void> mount() async {
    h = await pumpRealViewer(
      tester,
      reads: store,
      update: store.writer,
      drafts: MemoryDraftSink(),
      settings: const ViewerSettingsDraft(
        projectState: ProjectStateFilter.all,
        projectSort: ProjectSort.name,
        projectDirection: SortDirection.ascending,
      ),
      settle: false,
    );
    await settle();
    h.model.selectProjectIndex(0);
    await settle();
    h.model.tasks!.restoreState(const TaskListState(sort: TaskSort.id));
    await start(h.model.tasks!.reload());
  }

  Future<void> start(Future<void> action) async {
    await settle();
    await action;
  }

  Future<void> focus(ViewerRegion region) async {
    h.list(region).focusRegion();
    await settle();
  }

  Future<void> select(ViewerRegion region, int index) async {
    await focus(region);
    h.list(region).goToIndex(index);
    await settle();
  }

  /// Scrolls a list as a mouse wheel would, so loaded rows mount without any
  /// change to selection or focus.
  Future<void> scrollToTop(ViewerRegion region) async {
    final list = h.list(region);
    final view = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is AccessibleVirtualList && identical(w.controller, list),
      ),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(view.first).position.jumpTo(0);
    await pump();
  }

  Future<void> close() async {
    onPump = null;
    await tester.pumpWidget(const SizedBox());
    store.close();
    await tester.pump(const Duration(seconds: 2));
  }
}
