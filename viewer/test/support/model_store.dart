/// Store-backed reader/writer for selection tests. No real store is accessed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'viewer_test_support.dart';

String modelFold(String value) =>
    value.replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase());

class StoreRead {
  StoreRead(this.step, this.scope, this.offset, this.token, this.membership);
  final String step, scope;
  final int offset;
  final String? token;
  final bool membership;
  String outcome = 'pending';
}

class _Pending {
  final done = Completer<void>();
  Timer? timer;
}

class ModelStore extends FakeWorkspaceReads {
  ModelStore({
    int count = 205,
    int projectCount = 2,
    int seed = 49,
    Duration? delay,
  }) : random = Random(seed),
       fixedDelay = delay,
       super(
         projects: [
           for (var i = 1; i <= projectCount; i++)
             testProjectItem(
               i,
               name: 'Project ${i.toString().padLeft(3, '0')}',
             ),
         ],
       ) {
    for (final project in projects) {
      records[project.projectId] = {
        for (var id = 1; id <= count; id++)
          id: testTaskDetail(
            id,
            title: id % 3 == 0
                ? 'Éclair tie'
                : 'Task ${id.toString().padLeft(4, '0')}',
            body: 'body ${id % 2 == 0 ? 'needle' : 'hay'}',
            priority: 'P${id % 4}',
            labels: id.isEven ? ['even'] : [],
          ),
      };
    }
    writer = ModelWriter(this);
  }
  final Random random;
  final Duration? fixedDelay;
  late final ModelWriter writer;
  final Map<String, Map<int, TaskDetail>> records = {};
  final List<StoreRead> reads = [];
  final Map<String, List<TaskItem>> taskSnapshots = {};
  final Map<String, List<ProjectItem>> projectSnapshots = {};
  final Map<String, Map<int, TaskItem>> attachmentRows = {};
  final Map<String, _Pending> _pending = {};
  String step = 'setup';
  int version = 1, overlaps = 0;
  ViewerFailure? Function(StoreRead read)? failure;
  void Function(StoreRead read)? afterRead;
  int get activeReads => _pending.length;

  Future<void> _read(StoreRead read) async {
    reads.add(read);
    if (_pending.containsKey(read.scope)) {
      overlaps++;
      cancelScope(read.scope);
    }
    final pending = _Pending();
    _pending[read.scope] = pending;
    pending.timer = Timer(
      fixedDelay ?? Duration(milliseconds: 150 + random.nextInt(201)),
      () {
        if (!pending.done.isCompleted) pending.done.complete();
      },
    );
    try {
      await pending.done.future;
      final problem = failure?.call(read);
      if (problem != null) throw problem;
      read.outcome = 'ok';
      afterRead?.call(read);
    } on ViewerFailure catch (e) {
      read.outcome = e is ViewerCancelledFailure ? 'cancelled' : e.message;
      rethrow;
    } finally {
      pending.timer?.cancel();
      if (identical(_pending[read.scope], pending)) _pending.remove(read.scope);
    }
  }

  @override
  void cancelScope(String scope) {
    cancelledScopes.add(scope);
    final p = _pending.remove(scope);
    p?.timer?.cancel();
    if (p != null && !p.done.isCompleted) {
      p.done.completeError(const ViewerCancelledFailure());
    }
  }

  void close() {
    for (final scope in _pending.keys.toList()) {
      cancelScope(scope);
    }
  }

  String _token(String scope, Map<String, Object?> spec, int count) {
    final key = Map<String, Object?>.of(spec)
      ..remove('offset')
      ..remove('limit')
      ..remove('snapshot');
    return jsonEncode([scope, version, count, key]);
  }

  void _validate(String? supplied, String actual, StoreRead read) {
    if (supplied != null && supplied != actual) {
      read.outcome = 'stale_snapshot';
      throw const ViewerCliErrorFailure(
        code: 'stale_snapshot',
        message: 'store changed',
        exitCode: 4,
      );
    }
  }

  List<TaskDetail> orderedTasks(String projectId, TaskQuery q) {
    final values = records[projectId]!.values.where((t) {
      if (q.scope == TaskScope.open && viewerStatusIsTerminal(t.status)) {
        return false;
      }
      if (q.statuses.isNotEmpty && !q.statuses.contains(t.status)) return false;
      if (q.priorities.isNotEmpty && !q.priorities.contains(t.priority)) {
        return false;
      }
      if (!q.labels.every(t.labels.contains)) return false;
      final search = modelFold(q.query.trim());
      if (search.isEmpty) return true;
      final match = RegExp(r'^[a-z]+-0*(\d+)$').firstMatch(search);
      if (match != null) return t.id == int.parse(match[1]!);
      return modelFold('${t.title}\n${t.body}').contains(search);
    }).toList();
    values.sort((a, b) {
      final comparison = switch (q.sort) {
        TaskSort.id => a.id.compareTo(b.id),
        TaskSort.priority => a.priority.compareTo(b.priority),
        TaskSort.status =>
          viewerTaskStatuses
              .indexOf(a.status)
              .compareTo(viewerTaskStatuses.indexOf(b.status)),
        TaskSort.title => modelFold(a.title).compareTo(modelFold(b.title)),
        TaskSort.created => a.createdMs.compareTo(b.createdMs),
        TaskSort.updated => a.updatedMs.compareTo(b.updatedMs),
      };
      return comparison == 0
          ? a.id.compareTo(b.id)
          : comparison * (q.direction == SortDirection.ascending ? 1 : -1);
    });
    return values;
  }

  List<ProjectItem> orderedProjects(ProjectQuery q) {
    final search = modelFold(q.query.trim());
    final rows = projects
        .map((p) {
          final tasks = records[p.projectId]!.values.toList();
          final done = tasks.where((t) => t.status == 'done').length;
          final cancelled = tasks.where((t) => t.status == 'cancelled').length;
          final stats = ProjectStats(
            total: tasks.length,
            open: tasks.where((t) => !viewerStatusIsTerminal(t.status)).length,
            blocked: tasks.where((t) => t.status == 'blocked').length,
            done: done,
            cancelled: cancelled,
            startedMs: tasks.isEmpty
                ? null
                : tasks.map((t) => t.createdMs).reduce(min),
            lastWriteMs: tasks.isEmpty
                ? null
                : tasks.map((t) => t.updatedMs).reduce(max),
            progressPercent: tasks.length == cancelled
                ? null
                : 100 * done / (tasks.length - cancelled),
          );
          return ProjectItem.fromJson(
            p.toJson()..['stats'] = p.isAvailable ? stats.toJson() : null,
            path: 'store.project',
          );
        })
        .where(
          (p) =>
              _projectMatches(p, q.state) &&
              (search.isEmpty ||
                  modelFold(
                    '${p.projectId} ${p.name} ${p.roots.join(' ')}',
                  ).contains(search)),
        )
        .toList();
    rows.sort((a, b) {
      final d = q.sort == ProjectSort.name
          ? modelFold(a.name).compareTo(modelFold(b.name))
          : (a.stats?.lastWriteMs ?? 0).compareTo(b.stats?.lastWriteMs ?? 0);
      return d == 0
          ? a.projectId.compareTo(b.projectId)
          : d * (q.direction == SortDirection.ascending ? 1 : -1);
    });
    return rows;
  }

  bool _projectMatches(ProjectItem p, ProjectStateFilter state) {
    final tasks = records[p.projectId]!.values;
    final open = tasks.any((t) => !viewerStatusIsTerminal(t.status));
    return switch (state) {
      ProjectStateFilter.all => true,
      ProjectStateFilter.hasOpen => open,
      ProjectStateFilter.hasBlocked => tasks.any((t) => t.status == 'blocked'),
      ProjectStateFilter.complete => tasks.isNotEmpty && !open,
      ProjectStateFilter.empty => tasks.isEmpty,
      ProjectStateFilter.unavailable => !p.isAvailable,
      ProjectStateFilter.active => p.archivedAtMs == null,
      ProjectStateFilter.archived => p.archivedAtMs != null,
    };
  }

  TaskItem row(TaskDetail t) => TaskItem(
    id: t.id,
    displayId: t.displayId,
    title: t.title,
    status: t.status,
    priority: t.priority,
    version: t.version,
    labels: t.labels,
    dependencyCount: t.deps.length,
    waitingDependencyCount: 0,
    createdMs: t.createdMs,
    updatedMs: t.updatedMs,
    attachmentCount: t.attachments.length,
  );
  @override
  Future<TaskPage> fetchTasks(String projectId, TaskQuery q) async {
    taskRequests.add(q);
    taskProjectIds.add(projectId);
    final items = orderedTasks(projectId, q);
    final token = _token(projectId, q.toJson(), items.length);
    taskSnapshots[token] = items.map(row).toList();
    final read = StoreRead(
      step,
      'tasks',
      q.offset,
      q.snapshot,
      RegExp(r'^[A-Za-z]+-\d+$').hasMatch(q.query),
    );
    await _read(read);
    _validate(q.snapshot, token, read);
    final page = items.skip(q.offset).take(q.limit).map(row).toList();
    return TaskPage(
      protocolVersion: 1,
      items: page,
      totalCount: items.length,
      offset: q.offset,
      limit: q.limit,
      hasMore: q.offset + page.length < items.length,
      nextOffset: q.offset + page.length < items.length
          ? q.offset + page.length
          : null,
      snapshot: token,
      projectKey: projectKey,
    );
  }

  @override
  Future<ProjectPage> fetchProjects(ProjectQuery q) async {
    projectRequests.add(q);
    final items = orderedProjects(q);
    final token = _token('projects', q.toJson(), items.length);
    projectSnapshots[token] = List.of(items);
    final read = StoreRead(
      step,
      'projects',
      q.offset,
      q.snapshot,
      RegExp(r'^[0-9a-f-]{36}$').hasMatch(q.query),
    );
    await _read(read);
    _validate(q.snapshot, token, read);
    final page = items.skip(q.offset).take(q.limit).toList();
    return ProjectPage(
      protocolVersion: 1,
      items: page,
      totalCount: items.length,
      offset: q.offset,
      limit: q.limit,
      hasMore: q.offset + page.length < items.length,
      nextOffset: q.offset + page.length < items.length
          ? q.offset + page.length
          : null,
      snapshot: token,
    );
  }

  @override
  Future<TaskDetail> fetchTaskDetail(String projectId, int taskId) async {
    detailRequests.add(taskId);
    final detail = records[projectId]![taskId];
    if (detail == null) {
      throw const ViewerCliErrorFailure(
        code: 'not_found',
        message: 'missing',
        exitCode: 5,
      );
    }
    return detail;
  }

  void mutate(
    String projectId,
    int id, {
    String? title,
    String? status,
    String? priority,
    String? body,
  }) {
    final json = detailJson(records[projectId]![id]!);
    json['title'] = title ?? json['title'];
    json['status'] = status ?? json['status'];
    json['priority'] = priority ?? json['priority'];
    json['body'] = body ?? json['body'];
    json['version'] = (json['version'] as int) + 1;
    json['updated_ms'] = (json['updated_ms'] as int) + 1;
    records[projectId]![id] = TaskDetail.fromJson(json);
    version++;
  }
}

class ModelWriter extends FakeTaskWriter {
  ModelWriter(this.store);
  final ModelStore store;
  @override
  Future<ViewerUpdateResult> updateTask(
    String projectId,
    ViewerUpdateRequest request,
  ) async {
    requests.add(request);
    projectIds.add(projectId);
    final old = store.records[projectId]![request.id]!;
    if (old.version != request.expectVersion) {
      throw const ViewerCliErrorFailure(
        code: 'version_conflict',
        message: 'changed',
        exitCode: 4,
      );
    }
    final json = detailJson(old)..addAll(request.changes.toJson());
    json['version'] = old.version + 1;
    json['updated_ms'] = old.updatedMs + 1;
    store.records[projectId]![request.id] = TaskDetail.fromJson(json);
    store.version++;
    return ViewerUpdateResult(
      id: request.id,
      status: store.records[projectId]![request.id]!.status,
      version: old.version + 1,
      eventId: store.version,
    );
  }
}

Map<String, Object?> detailJson(TaskDetail t) => {
  'id': t.id,
  'project_key': t.projectKey,
  'display_id': t.displayId,
  'title': t.title,
  'body': t.body,
  'status': t.status,
  'priority': t.priority,
  'version': t.version,
  'labels': t.labels,
  'deps': t.deps,
  'dependency_summaries': <Object?>[],
  'rule_version': t.ruleVersion,
  'rules': t.rules,
  'created_ms': t.createdMs,
  'updated_ms': t.updatedMs,
};
