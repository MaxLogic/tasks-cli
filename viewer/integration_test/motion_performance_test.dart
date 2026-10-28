/// Opt-in profile benchmark. No CLI, database, settings file, or live viewer.
/// flutter drive --profile -d windows --driver=test_driver/perf_driver.dart
///   --target=integration_test/motion_performance_test.dart
library;

import 'dart:math' as math;
import 'dart:ui' show FrameTiming;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';
import '../test/support/viewer_test_support.dart';

/// Generate only requested pages. The timed route measures viewer UI work,
/// including the real controller's sparse result storage, not fake-reader scans.
class _SyntheticReads extends FakeWorkspaceReads {
  _SyntheticReads(this.count)
    : super(
        projects: [testProjectItem(1, total: count, open: count)],
        details: {1: testTaskDetail(1, body: 'Frame-time fixture body')},
      );
  final int count;
  int requests = 0;
  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery query) async {
    requests++;
    final filtered = query.query.isNotEmpty;
    final total = filtered ? count ~/ 2 : count;
    final end = math.min(total, query.offset + query.limit);
    final items = <TaskItem>[
      for (var i = query.offset; i < end; i++)
        testTaskItem(
          (query.direction == SortDirection.ascending ? i : total - 1 - i) *
                  (filtered ? 2 : 1) +
              1,
          title: 'Synthetic task row $i',
        ),
    ];
    return TaskPage(
      protocolVersion: 1,
      items: items,
      totalCount: total,
      offset: query.offset,
      limit: query.limit,
      hasMore: end < total,
      nextOffset: end < total ? end : null,
      snapshot: 'fixture',
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const smoke = bool.fromEnvironment('MOTION_SMOKE');
  const repeats = int.fromEnvironment('MOTION_REPEATS', defaultValue: 5);
  testWidgets(
    'visible-window transitions, 1000 and 100000 tasks',
    (tester) async {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1280, 720));
      final results = <String, Object?>{};
      for (final count in smoke ? [1000] : [1000, 100000]) {
        for (final off in [true, false]) {
          final reads = _SyntheticReads(count);
          await tester.pumpWidget(
            TasksViewerApp(
              key: UniqueKey(),
              environment: viewerTestEnvironment(suffix: 'motion-perf'),
              windowsAnimationsEnabled: () => true,
              initialSettings: ViewerSettingsDraft(
                animations: off
                    ? ViewerAnimations.off
                    : ViewerAnimations.followWindows,
              ),
              readers: ViewerDataReader(
                projects: reads,
                tasks: reads,
                detail: reads,
                probe: reads.probe,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final model = tester
              .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
              .model;
          model.selectProjectIndex(0);
          await tester.pumpAndSettle();
          await model.openTaskIndex(0);
          await tester.pumpAndSettle();
          Future<void> journey({
            required int sorts,
            required int filters,
            required int tabs,
          }) async {
            final tasks = model.tasks!;
            for (var i = 0; i < sorts; i++) {
              tasks.setDirection(
                tasks.direction == SortDirection.ascending
                    ? SortDirection.descending
                    : SortDirection.ascending,
              );
              await tester.pumpAndSettle(const Duration(milliseconds: 16));
            }
            for (var i = 0; i < filters; i++) {
              tasks.setQuery(i.isEven ? 'even' : '');
              await tasks.submitQuery();
              await tester.pumpAndSettle(const Duration(milliseconds: 16));
            }
            for (var i = 0; i < tabs; i++) {
              model.showTab(
                i.isEven ? TaskDetailTab.rules : TaskDetailTab.details,
              );
              await tester.pumpAndSettle(const Duration(milliseconds: 16));
            }
          }

          // Warm all production transition paths before collecting samples.
          await journey(sorts: 4, filters: 4, tabs: 4);
          for (var repeat = 0; repeat < (smoke ? 1 : repeats); repeat++) {
            final frames = <FrameTiming>[];
            void collect(List<FrameTiming> timings) => frames.addAll(timings);
            final requestsBefore = reads.requests;
            final key = '$count-${off ? 'off' : 'on'}-$repeat';
            binding.addTimingsCallback(collect);
            try {
              await binding.watchPerformance(
                () => journey(sorts: 20, filters: 20, tabs: 10),
                reportKey: key,
              );
            } finally {
              binding.removeTimingsCallback(collect);
            }
            expect(frames, isNotEmpty);
            results[key] = {
              'task_count': count,
              'motion': !off,
              'repeat': repeat,
              'sorts': 20,
              'filters': 20,
              'tabs': 10,
              'page_requests': reads.requests - requestsBefore,
              'frames': [
                for (final f in frames)
                  {
                    'build_us': f.buildDuration.inMicroseconds,
                    'raster_us': f.rasterDuration.inMicroseconds,
                  },
              ],
            };
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      }
      binding.reportData!['motion_raw'] = results;
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
