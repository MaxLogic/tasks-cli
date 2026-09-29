/// Fixture manifest for the end-to-end viewer scenarios.
///
/// Contract: viewer/spec.md section 11. `viewer/tool/verify-windows.ps1` seeds
/// one real CLI store in a unique temporary root, writes `fixture.json` beside
/// it and passes that absolute path through
/// `--dart-define=TASKS_VIEWER_E2E_FIXTURE`. Nothing in this suite invents a
/// store path of its own, so a missing or unreadable manifest can only skip
/// with a reason that names the define; it can never quietly pass against the
/// developer's own data.
library;

import 'dart:convert';
import 'dart:io';

/// One project the harness seeded through the real CLI.
class ViewerE2eProject {
  const ViewerE2eProject({
    required this.role,
    required this.name,
    required this.projectId,
    required this.taskCount,
    required this.openTaskCount,
    required this.projectKey,
  });

  final String role;
  final String name;
  final String projectId;

  /// The project key the harness assigned (`ALPHA`). `init --key` is
  /// required (viewer/spec.md section 11, DAK-212), so the seeding script
  /// always writes one or throws; a manifest without one is malformed, not a
  /// legacy manifest to tolerate.
  final String projectKey;

  /// Total tasks the project statistics must report.
  final int taskCount;

  /// Tasks the default (open) list scope must report.
  final int openTaskCount;

  /// The Projects pane row name, `name (KEY)`.
  ///
  /// Mirrors `ProjectItem.displayName` in `lib/data/models.dart`, which the
  /// Projects pane row semantics label (`viewerProjectRowLabel`) is built
  /// from.
  String get displayName => '$name ($projectKey)';

  static ViewerE2eProject fromJson(Map<String, Object?> json) {
    return ViewerE2eProject(
      role: json['role']! as String,
      name: json['name']! as String,
      projectId: json['project_id']! as String,
      taskCount: json['task_count']! as int,
      openTaskCount: json['open_task_count']! as int,
      projectKey: json['project_key']! as String,
    );
  }
}

/// The seeded facts one scenario run asserts against.
class ViewerE2eChecks {
  const ViewerE2eChecks({
    required this.firstRowId,
    required this.firstRowTitle,
    required this.detailRowId,
    required this.detailBodyMarker,
    required this.searchQuery,
    required this.searchExpectedCount,
    required this.searchExpectedTitle,
    required this.saveTaskId,
    required this.saveNewTitle,
  });

  final String firstRowId;
  final String firstRowTitle;
  final String detailRowId;
  final String detailBodyMarker;

  /// Literal search text that the store must not read as a LIKE pattern.
  final String searchQuery;
  final int searchExpectedCount;
  final String searchExpectedTitle;

  final String saveTaskId;
  final String saveNewTitle;

  static ViewerE2eChecks fromJson(Map<String, Object?> json) {
    return ViewerE2eChecks(
      firstRowId: json['first_row_id']! as String,
      firstRowTitle: json['first_row_title']! as String,
      detailRowId: json['detail_row_id']! as String,
      detailBodyMarker: json['detail_body_marker']! as String,
      searchQuery: json['search_query']! as String,
      searchExpectedCount: json['search_expected_count']! as int,
      searchExpectedTitle: json['search_expected_title']! as String,
      saveTaskId: json['save_task_id']! as String,
      saveNewTitle: json['save_new_title']! as String,
    );
  }
}

/// One seeded store: roots, CLI path, projects and the expected facts.
class ViewerE2eFixture {
  const ViewerE2eFixture({
    required this.seed,
    required this.dataRoot,
    required this.settingsRoot,
    required this.cliPath,
    required this.projects,
    required this.checks,
  });

  /// The name of the `--dart-define` that carries the manifest path.
  static const String defineName = 'TASKS_VIEWER_E2E_FIXTURE';

  /// The manifest path baked into this build, or the empty string.
  static const String manifestPath = String.fromEnvironment(defineName);

  final int seed;
  final String dataRoot;
  final String settingsRoot;
  final String cliPath;
  final List<ViewerE2eProject> projects;
  final ViewerE2eChecks checks;

  /// The project the task scenarios drive; the harness always seeds it first.
  ViewerE2eProject get alpha =>
      projects.firstWhere((project) => project.role == 'alpha');

  /// Loads the manifest, or returns the reason the scenarios must skip.
  ///
  /// The reason is short enough for a test name and always names the define, so
  /// a plain `flutter test` without the harness reads as an unmet prerequisite
  /// rather than a failure.
  static (ViewerE2eFixture?, String?) load() {
    if (manifestPath.isEmpty) {
      return (
        null,
        'the end-to-end fixture is not provisioned: pass '
            '--dart-define=$defineName=<fixture.json> '
            '(viewer/tool/verify-windows.ps1 does this)',
      );
    }
    final file = File(manifestPath);
    if (!file.existsSync()) {
      return (null, 'the end-to-end fixture manifest $manifestPath is missing');
    }
    try {
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final rawProjects = decoded['projects']! as List<Object?>;
      final fixture = ViewerE2eFixture(
        seed: decoded['seed']! as int,
        dataRoot: decoded['data_root']! as String,
        settingsRoot: decoded['settings_root']! as String,
        cliPath: decoded['cli']! as String,
        projects: rawProjects
            .map(
              (project) =>
                  ViewerE2eProject.fromJson(project! as Map<String, Object?>),
            )
            .toList(growable: false),
        checks: ViewerE2eChecks.fromJson(
          decoded['checks']! as Map<String, Object?>,
        ),
      );
      return (fixture, null);
    } on Object catch (error) {
      return (
        null,
        'the end-to-end fixture manifest $manifestPath is unreadable: $error',
      );
    }
  }
}
