import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import 'package:tasks_viewer/ui/workspace_model.dart';

import '../support/viewer_test_support.dart';

void main() {
  testWidgets('project filter and sort survive a viewer restart', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'viewer-project-preferences-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final store = SettingsStore(settingsRoot: root.path);
    ViewerSettingsDraft? pendingSave;
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
    );
    addTearDown(announcements.dispose);
    final reads = fakeWorkspaceReads();
    ViewerDataReader readers() => ViewerDataReader(
      projects: reads,
      tasks: reads,
      detail: reads,
      probe: reads.probe,
    );

    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(),
        announcements: announcements,
        readers: readers(),
        onSettingsPersist: (draft) async {
          pendingSave = draft;
        },
      ),
    );
    await tester.pumpAndSettle();
    final model = tester
        .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
        .model;
    expect(reads.lastProjectRequest.state, ProjectStateFilter.hasOpen);
    expect(reads.lastProjectRequest.sort, ProjectSort.lastWrite);
    expect(reads.lastProjectRequest.direction, SortDirection.descending);

    model.projectList.setState(ProjectStateFilter.archived);
    model.projectList.setSort(ProjectSort.name);
    model.projectList.setDirection(SortDirection.descending);
    await tester.pumpAndSettle();
    expect(pendingSave, isNotNull);
    final saved = await tester.runAsync(() async {
      await store.save(pendingSave!);
      return store.load();
    });
    expect(saved, isNotNull);
    expect(saved!.draft.projectState, ProjectStateFilter.archived);
    expect(saved.draft.projectSort, ProjectSort.name);
    expect(saved.draft.projectDirection, SortDirection.descending);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(),
        announcements: announcements,
        readers: readers(),
        initialSettings: saved.draft,
      ),
    );
    await tester.pumpAndSettle();
    expect(reads.lastProjectRequest.state, ProjectStateFilter.archived);
    expect(reads.lastProjectRequest.sort, ProjectSort.name);
    expect(reads.lastProjectRequest.direction, SortDirection.descending);
  });
}
