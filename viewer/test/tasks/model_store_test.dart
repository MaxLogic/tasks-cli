import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import '../support/model_store.dart';

void main() {
  test(
    'store ordering, membership, mutations, stale tokens and cancellation',
    () async {
      final s = ModelStore(count: 205, delay: Duration.zero);
      addTearDown(s.close);
      final id = s.projects.first.projectId;
      for (final sort in TaskSort.values) {
        final asc = s.orderedTasks(id, TaskQuery(sort: sort));
        final desc = s.orderedTasks(
          id,
          TaskQuery(sort: sort, direction: SortDirection.descending),
        );
        expect(asc.length, 205);
        expect(desc.length, 205);
        if (sort == TaskSort.id) expect(desc.first.id, 205);
      }
      expect(
        s
            .orderedTasks(id, const TaskQuery(query: 'NEEDLE'))
            .every((t) => t.id.isEven),
        isTrue,
      );
      expect(
        s.orderedTasks(id, const TaskQuery(query: 'T-151')).single.id,
        151,
      );
      final page = await s.fetchTasks(id, const TaskQuery(sort: TaskSort.id));
      s.mutate(id, 151, title: 'changed');
      await expectLater(
        s.fetchTasks(
          id,
          TaskQuery(offset: 100, snapshot: page.snapshot, sort: TaskSort.id),
        ),
        throwsA(isA<ViewerCliErrorFailure>()),
      );
      final first = s.fetchTasks(id, const TaskQuery());
      final cancelled = expectLater(
        first,
        throwsA(isA<ViewerCancelledFailure>()),
      );
      await s.fetchTasks(id, const TaskQuery());
      await cancelled;
      expect(s.overlaps, 1);
      expect(s.activeReads, 0);
    },
  );
  test(
    'project last-write ordering and state derive from real records',
    () async {
      final s = ModelStore(count: 2, projectCount: 2, delay: Duration.zero);
      addTearDown(s.close);
      final first = s.projects.first.projectId,
          second = s.projects.last.projectId;
      s.mutate(second, 2, title: 'later');
      final q = ProjectQuery(
        sort: ProjectSort.lastWrite,
        direction: SortDirection.descending,
        state: ProjectStateFilter.all,
      );
      expect(s.orderedProjects(q).first.projectId, second);
      s.mutate(first, 1, status: 'done');
      s.mutate(first, 2, status: 'done');
      expect(
        s
            .orderedProjects(
              const ProjectQuery(state: ProjectStateFilter.complete),
            )
            .single
            .projectId,
        first,
      );
      expect(s.orderedProjects(q).first.stats!.done, 2);
    },
  );
}
