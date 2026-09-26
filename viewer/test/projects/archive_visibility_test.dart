import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/project_archive.dart';
import 'package:tasks_viewer/data/settings_draft.dart';

import '../support/viewer_test_support.dart';

class _ArchiveWriter implements ProjectArchiveWriter {
  _ArchiveWriter(this.reads);

  final FakeWorkspaceReads reads;

  @override
  Future<int?> setProjectArchived(
    String projectId, {
    required bool archived,
  }) async {
    final index = reads.projects.indexWhere(
      (item) => item.projectId == projectId,
    );
    final item = reads.projects[index];
    final archivedAtMs = archived ? 1700000005000 : null;
    reads.projects[index] = ProjectItem.fromJson(<String, Object?>{
      ...item.toJson(),
      'archived_at_ms': archivedAtMs,
    }, path: 'archived project');
    return archivedAtMs;
  }
}

void main() {
  testWidgets('archiving removes a project until Archived is selected', (
    tester,
  ) async {
    final reads = fakeWorkspaceReads();
    final harness = await pumpRealViewer(
      tester,
      reads: reads,
      projectArchive: _ArchiveWriter(reads),
      settings: const ViewerSettingsDraft(projectState: ProjectStateFilter.all),
    );

    await pressKey(tester, LogicalKeyboardKey.f1);
    await pressKey(tester, LogicalKeyboardKey.keyA);
    expect(harness.model.projectList.totalCount, 1);
    expect(
      harness.model.selectedProjectId,
      isNot(testProjectItem(1).projectId),
    );
    expect(find.text('Project 1'), findsNothing);
    expect(find.text('Project 2'), findsWidgets);

    harness.model.projectList.setState(ProjectStateFilter.archived);
    await tester.pumpAndSettle();
    expect(harness.model.projectList.totalCount, 1);
    expect(find.text('Project 1'), findsWidgets);
    expect(find.text('Project 2'), findsNothing);

    await pressKey(tester, LogicalKeyboardKey.f1);
    await pressKey(tester, LogicalKeyboardKey.keyA);
    expect(harness.model.projectList.totalCount, 0);
    expect(find.text('Project 1'), findsNothing);

    harness.model.projectList.setState(ProjectStateFilter.all);
    await tester.pumpAndSettle();
    expect(harness.model.projectList.totalCount, 2);
    expect(find.text('Project 1'), findsWidgets);
  });
}
