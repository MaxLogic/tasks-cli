/// Versioned settings, atomic replacement and corrupt-file preservation
/// (viewer/spec.md section 5).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/data/settings_store.dart';

late Directory _root;

Directory _newRoot(String name) {
  final directory = Directory.systemTemp.createTempSync('viewer-$name-');
  addTearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });
  return directory;
}

void main() {
  setUp(() {
    _root = _newRoot('settings');
  });

  group('paths', () {
    test('joinViewerPath never doubles a separator', () {
      final separator = Platform.pathSeparator;
      expect(joinViewerPath(r'C:\root', 'file.json'), r'C:\root\file.json');
      expect(joinViewerPath(r'C:\root\', 'file.json'), r'C:\root\file.json');
      // The viewer targets Windows, so a trailing forward slash is stripped
      // and the platform separator is used.
      expect(
        joinViewerPath('/tmp/root', 'file.json'),
        '/tmp/root${separator}file.json',
      );
      // An already-terminated directory keeps the separator it was given.
      expect(joinViewerPath('/tmp/root/', 'file.json'), '/tmp/root/file.json');
    });

    test('settings and drafts live under the injected settings root', () {
      final store = SettingsStore(settingsRoot: _root.path);
      expect(
        store.settingsFilePath,
        joinViewerPath(_root.path, viewerSettingsFileName),
      );
      expect(
        store.recoveryFilePath,
        joinViewerPath(_root.path, viewerRecoveryFileName),
      );
    });
  });

  group('load', () {
    test('a missing file yields defaults without creating anything', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      final result = await store.load();
      expect(result.loadedFromFile, isFalse);
      expect(result.hasWarning, isFalse);
      expect(result.draft.startWithWindows, isTrue);
      expect(result.draft.announcementMode, AnnouncementMode.bella);
      expect(result.draft.bellaVolumePercent, 70);
      expect(result.draft.projectState, ProjectStateFilter.hasOpen);
      expect(result.draft.projectSort, ProjectSort.lastWrite);
      expect(result.draft.projectDirection, SortDirection.descending);
      expect(_root.listSync(), isEmpty);
    });

    test('a saved document round-trips every preference', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      const draft = ViewerSettingsDraft(
        cliPath: r'C:\tools\tasks.exe',
        dataRoot: r'D:\Zadania\store',
        themeMode: ViewerThemeMode.dark,
        textScalePercent: 175,
        projectsPanePercent: 30,
        tasksPanePercent: 30,
        detailsPanePercent: 40,
        startWithWindows: false,
        announcementMode: AnnouncementMode.nvdaOnly,
        bellaVolumePercent: 30,
        projectState: ProjectStateFilter.archived,
        projectSort: ProjectSort.name,
        projectDirection: SortDirection.ascending,
      );
      await store.save(draft);

      final result = await store.load();
      expect(result.loadedFromFile, isTrue);
      expect(result.hasWarning, isFalse);
      expect(result.draft.cliPath, draft.cliPath);
      expect(result.draft.dataRoot, draft.dataRoot);
      expect(result.draft.themeMode, ViewerThemeMode.dark);
      expect(result.draft.textScalePercent, 175);
      expect(result.draft.projectsPanePercent, 30);
      expect(result.draft.detailsPanePercent, 40);
      expect(result.draft.startWithWindows, isFalse);
      expect(result.draft.announcementMode, AnnouncementMode.nvdaOnly);
      expect(result.draft.bellaVolumePercent, 30);
      expect(result.draft.projectState, ProjectStateFilter.archived);
      expect(result.draft.projectSort, ProjectSort.name);
      expect(result.draft.projectDirection, SortDirection.ascending);
    });

    test(
      'a second save replaces the file and leaves no temporary behind',
      () async {
        final store = SettingsStore(settingsRoot: _root.path);
        await store.save(const ViewerSettingsDraft(textScalePercent: 125));
        await store.save(const ViewerSettingsDraft(textScalePercent: 200));
        expect((await store.load()).draft.textScalePercent, 200);
        expect(
          _root
              .listSync()
              .map((entity) => entity.path.split(Platform.pathSeparator).last)
              .where((name) => name.contains('.tmp-')),
          isEmpty,
        );
        expect(_root.listSync().length, 1);
      },
    );

    test('the document declares its own schema version', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await store.save(const ViewerSettingsDraft());
      final decoded =
          jsonDecode(await File(store.settingsFilePath).readAsString())
              as Map<String, Object?>;
      expect(decoded['schema_version'], viewerSettingsSchemaVersion);
    });

    test('a corrupt file is preserved and defaults take over', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      final file = File(store.settingsFilePath);
      await file.writeAsString('{ this is not json');

      final fixed = DateTime(2026, 9, 21, 22, 51, 43, 123);
      final result = await SettingsStore(
        settingsRoot: _root.path,
        clock: () => fixed,
      ).load();

      expect(result.loadedFromFile, isFalse);
      expect(result.preservedPath, isNotNull);
      expect(result.preservedPath, contains('viewer-settings.corrupt-'));
      expect(result.preservedPath, contains('20260921T225143123'));
      expect(result.warning, contains('unreadable'));
      expect(result.warning, contains(result.preservedPath!));
      expect(result.draft.textScalePercent, 100);
      expect(
        await File(result.preservedPath!).readAsString(),
        '{ this is not json',
        reason: 'the user keeps their original file',
      );
      expect(await file.exists(), isFalse);
    });

    test('a second corrupt load does not overwrite the first copy', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      final file = File(store.settingsFilePath);
      final fixed = DateTime(2026, 9, 21, 22, 51, 43);
      final stamped = SettingsStore(
        settingsRoot: _root.path,
        clock: () => fixed,
      );

      await file.writeAsString('first');
      final first = await stamped.load();
      await file.writeAsString('second');
      final second = await stamped.load();

      expect(second.preservedPath, isNot(first.preservedPath));
      expect(await File(first.preservedPath!).readAsString(), 'first');
      expect(await File(second.preservedPath!).readAsString(), 'second');
    });

    test('a future schema version counts as corruption, not as data', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await File(
        store.settingsFilePath,
      ).writeAsString('{"schema_version": 2, "text_scale_percent": 500}');
      final result = await store.load();
      expect(result.loadedFromFile, isFalse);
      expect(result.draft.textScalePercent, 100);
      expect(result.warning, contains('unsupported settings schema_version'));
    });

    test('a wrong field type is refused instead of guessed', () {
      expect(
        () => decodeSettingsDocument(
          '{"schema_version":1,"text_scale_percent":"200"}',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeSettingsDocument(
          '{"schema_version":1,"start_with_windows":1}',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            decodeSettingsDocument('{"schema_version":1,"theme_mode":"neon"}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeSettingsDocument('[]'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeSettingsDocument('{"schema_version":1,"a":1,"a":2}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown additive fields are ignored and nulls mean unset', () {
      final draft = decodeSettingsDocument(
        '{"schema_version":1,"cli_path":null,"data_root":"",'
        '"future_option":true}',
      );
      expect(draft.cliPath, isNull);
      expect(draft.dataRoot, isNull);
    });
  });

  group('recovery drafts', () {
    ViewerRecoveryDraft draft({
      String taskId = 'T-007',
      String dataRoot = r'C:\store',
      String projectId = 'p1',
      int version = 3,
    }) => ViewerRecoveryDraft(
      dataRoot: dataRoot,
      projectId: projectId,
      taskId: taskId,
      baseVersion: version,
      baseFields: const <String, Object?>{'title': 'Original'},
      draftFields: const <String, Object?>{'title': 'Edited'},
      updatedMs: 1700000000000,
    );

    test('a draft survives a restart and keeps its identity', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await store.recoveryDrafts.save(draft());
      final restored = await SettingsStore(
        settingsRoot: _root.path,
      ).recoveryDrafts.loadAll();
      expect(restored.length, 1);
      expect(restored.single.taskId, 'T-007');
      expect(restored.single.baseVersion, 3);
      expect(restored.single.baseFields['title'], 'Original');
      expect(restored.single.draftFields['title'], 'Edited');
    });

    test(
      'drafts for different tasks coexist and delete independently',
      () async {
        final store = SettingsStore(settingsRoot: _root.path);
        await store.recoveryDrafts.save(draft(taskId: 'T-001'));
        await store.recoveryDrafts.save(draft(taskId: 'T-002'));
        await store.recoveryDrafts.save(draft(taskId: 'T-002', version: 9));
        final all = await store.recoveryDrafts.loadAll();
        expect(all.length, 2);
        expect(
          all.singleWhere((entry) => entry.taskId == 'T-002').baseVersion,
          9,
        );

        await store.recoveryDrafts.delete(draft(taskId: 'T-002').draftId);
        final remaining = await store.recoveryDrafts.loadAll();
        expect(remaining.length, 1);
        expect(remaining.single.taskId, 'T-001');

        await store.recoveryDrafts.delete('missing|p1|T-404');
        expect((await store.recoveryDrafts.loadAll()).length, 1);
      },
    );

    test('the same task in two stores keeps two independent drafts', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await store.recoveryDrafts.save(draft(dataRoot: r'C:\one'));
      await store.recoveryDrafts.save(draft(dataRoot: r'D:\two', version: 8));
      final all = await store.recoveryDrafts.loadAll();
      expect(all.length, 2);
      expect(all.map((entry) => entry.baseVersion).toSet(), <int>{3, 8});
    });

    test('a corrupt draft index degrades to no drafts', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await File(store.recoveryFilePath).writeAsString('{"drafts": [');
      expect(await store.recoveryDrafts.loadAll(), isEmpty);
    });

    test('one damaged entry does not discard the healthy ones', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await store.recoveryDrafts.save(draft(taskId: 'T-001'));
      final file = File(store.recoveryFilePath);
      final document =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final drafts = document['drafts']! as List<Object?>;
      drafts.add(<String, Object?>{'task_id': 'T-999'});
      await file.writeAsString(jsonEncode(document));

      final loaded = await store.recoveryDrafts.loadAll();
      expect(loaded.length, 1);
      expect(loaded.single.taskId, 'T-001');
    });

    test('projectKeys survives a restart (TSK-011)', () async {
      final store = SettingsStore(settingsRoot: _root.path);
      await store.recoveryDrafts.save(
        ViewerRecoveryDraft(
          dataRoot: r'C:\store',
          projectId: 'p1',
          taskId: 'T-007',
          baseVersion: 3,
          baseFields: const <String, Object?>{'title': 'Original'},
          draftFields: const <String, Object?>{'title': 'Edited'},
          updatedMs: 1700000000000,
          projectKeys: const <String>['OLD', 'NEW'],
        ),
      );
      final restored = await SettingsStore(
        settingsRoot: _root.path,
      ).recoveryDrafts.loadAll();
      expect(restored.single.projectKeys, <String>['OLD', 'NEW']);
    });

    test(
      'a draft with no project_keys field decodes to an empty list',
      () async {
        // Backward compatibility: a draft saved before TSK-011 added the
        // field must still load, with an empty list rather than a decode
        // failure.
        final draftWithoutKeys = draft();
        expect(
          draftWithoutKeys.toJson().containsKey('project_keys'),
          isFalse,
          reason: 'an empty list is omitted, not written as []',
        );
        final decoded = ViewerRecoveryDraft.fromJson(draftWithoutKeys.toJson());
        expect(decoded.projectKeys, isEmpty);
      },
    );

    test('a non-string project_keys entry is rejected', () {
      final json = draft().toJson()..['project_keys'] = <Object?>['OLD', 3];
      expect(
        () => ViewerRecoveryDraft.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
