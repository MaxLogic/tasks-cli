/// The production DTOs against a real `viewer projects` response
/// (viewer/spec.md section 4.2, test matrix V02).
///
/// The fixture is CLI output captured from a synthetic multi-project store;
/// see `test/fixtures/README.md`. It exists so the client's parsing, null
/// handling and ordering are checked against the real protocol rather than a
/// hand-written approximation of it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';

const String _fixturePath = 'test/fixtures/viewer-projects-real.json';

void main() {
  late ProjectPage page;
  late Map<String, ProjectItem> byName;

  setUpAll(() {
    final envelope = ViewerEnvelope.decode(
      File(_fixturePath).readAsStringSync(),
      expectedCommands: const <String>{'viewer_projects'},
    );
    page = ProjectPage.fromJson(envelope.data);
    byName = <String, ProjectItem>{
      for (final item in page.items) item.name: item,
    };
  });

  test('the captured catalog decodes with its exact count and order', () {
    expect(page.protocolVersion, 1);
    expect(page.totalCount, 5);
    expect(page.items.length, 5);
    expect(page.offset, 0);
    expect(page.limit, 100);
    expect(page.hasMore, isFalse);
    expect(page.nextOffset, isNull);
    expect(page.snapshot, startsWith('v1:'));
    expect(
      page.items.map((item) => item.name),
      <String>['alpha', 'gamma', 'ghost', 'orphan', 'vanished'],
      reason: 'name ascending, ASCII case-insensitive, is the CLI order',
    );
  });

  test('two roots for one UUID stay one row with both roots listed', () {
    final alpha = byName['alpha']!;
    expect(alpha.roots.length, 2);
    expect(alpha.rootSummary, contains(r'C:\viewer-fixture\mirror-alpha'));
    expect(alpha.isAvailable, isTrue);
    expect(
      page.items.where((item) => item.projectId == alpha.projectId).length,
      1,
      reason: 'a duplicate binding must not duplicate the row',
    );
  });

  test('the aggregate matches the documented counter definitions', () {
    final stats = byName['alpha']!.stats!;
    expect(stats.total, 10);
    expect(stats.open, 4);
    expect(stats.blocked, 1);
    expect(stats.done, 4);
    expect(stats.cancelled, 2);
    expect(
      stats.progressPercent,
      50.0,
      reason: '4 done of 10 non-cancelled tasks',
    );
    expect(stats.hasProgress, isTrue);
    expect(stats.startedMs, isNotNull);
    expect(stats.lastWriteMs, greaterThanOrEqualTo(stats.startedMs!));
  });

  test('an unreadable database is an error row, never zero statistics', () {
    final ghost = byName['ghost']!;
    expect(ghost.availability, ProjectAvailability.error);
    expect(ghost.isAvailable, isFalse);
    expect(ghost.error?.code, 'database');
    expect(ghost.error?.message, isNotEmpty);
    expect(ghost.stats, isNull);
  });

  test('an absent database is a missing row without an error payload', () {
    final orphan = byName['orphan']!;
    expect(orphan.availability, ProjectAvailability.missing);
    expect(orphan.error, isNull);
    expect(orphan.stats, isNull);
    expect(orphan.rootSummary, r'C:\viewer-fixture\orphan');
  });

  test('a project with no tasks reports nulls, not zeros or 100 percent', () {
    final stats = byName['vanished']!.stats!;
    expect(stats.total, 0);
    expect(stats.open, 0);
    expect(stats.startedMs, isNull);
    expect(stats.lastWriteMs, isNull);
    expect(stats.progressPercent, isNull);
    expect(stats.hasProgress, isFalse);
    expect(stats.hasRecordedTasks, isFalse);
  });

  test('every row carries a sample time so the shell can age it', () {
    expect(page.items.every((item) => item.sampledAtMs > 0), isTrue);
  });

  test('the query that produced the fixture is the documented default', () {
    const query = ProjectQuery();
    expect(query.query, isEmpty);
    expect(query.state, ProjectStateFilter.all);
    expect(query.sort, ProjectSort.name);
    expect(query.direction, SortDirection.ascending);
    expect(query.offset, 0);
    expect(query.limit, 100);
    expect(query.snapshot, isNull);
  });
}
