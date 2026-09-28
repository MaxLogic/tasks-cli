/// Editor field mapping, change detection and Dart-side validation
/// (viewer/spec.md section 7).
///
/// The store stays authoritative. These tests pin the draft-side contract:
/// which normalized values travel in a `viewer update` request, when a draft
/// counts as changed, and which limit messages the form shows before a save
/// is even attempted. The concrete messages and boundaries mirror the real
/// CLI behaviour captured in the slice-5 evidence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/editor_validation.dart';

import '../support/viewer_test_support.dart';

TaskEditFields baseFields({
  String title = 'Review parser',
  String body = 'Full text\n',
  String status = 'todo',
  String priority = 'P1',
  String labelsText = 'needs-human, zeta',
  String depsText = 'T-002',
}) => TaskEditFields(
  title: title,
  body: body,
  status: status,
  priority: priority,
  labelsText: labelsText,
  depsText: depsText,
);

void main() {
  group('TaskEditFields', () {
    test('maps a detail record to canonical editor text', () {
      final detail = testTaskDetail(
        7,
        title: 'Review parser',
        body: 'Body\n',
        status: 'in-progress',
        priority: 'P0',
        labels: <String>['alpha', 'needs-human'],
        deps: <int>[2, 4],
      );

      final fields = TaskEditFields.fromDetail(detail);

      expect(fields.title, 'Review parser');
      expect(fields.body, 'Body\n');
      expect(fields.status, 'in-progress');
      expect(fields.priority, 'P0');
      expect(fields.labelsText, 'alpha, needs-human');
      expect(fields.depsText, 'T-002, T-004');
    });

    test('a keyed project shows and parses KEY-N dependencies', () {
      final detail = testTaskDetail(7, deps: <int>[2, 4], projectKey: 'DAK');
      final fields = TaskEditFields.fromDetail(detail);
      expect(fields.depsText, 'DAK-002, DAK-004');

      final parsed = parseEditorDependencyText(
        'DAK-2, dak-004 T-5 6',
        projectKey: 'DAK',
      );
      expect(parsed.ids, <int>[2, 4, 5, 6]);
      expect(parsed.isValid, isTrue);

      final foreign = parseEditorDependencyText('DS-2', projectKey: 'DAK');
      expect(foreign.errors.single.token, 'DS-2');
      expect(parseEditorDependencyText('DAK-2').isValid, isFalse);

      // Respelling DAK-002 as T-2 or 2 is not a change.
      final respelled = fields.copyWith(depsText: 'T-2, 4');
      expect(
        EditorFieldChanges.between(fields, respelled, projectKey: 'DAK').deps,
        isNull,
      );
      final result = validateEditorFields(
        fields.copyWith(depsText: 'DS-2, DAK-7'),
        taskId: 7,
        projectKey: 'DAK',
      );
      expect(
        result.errors[EditorField.deps],
        'Dependencies: "DS-2" belongs to another project; dependencies must '
        'be in this project (DAK-N, T-N or N). '
        'the task cannot depend on itself (DAK-007).',
      );
    });

    test('treats reordered, recased or spaced labels as unchanged', () {
      final base = baseFields();
      final draft = base.copyWith(labelsText: '  ZETA ,needs-human ');

      final changes = EditorFieldChanges.between(base, draft);

      expect(changes.isEmpty, isTrue);
      expect(changes.fields, isEmpty);
    });

    test('treats equivalent dependency spellings as unchanged', () {
      final base = baseFields(depsText: 'T-002, T-004');
      final draft = base.copyWith(depsText: 't-4, 2');

      expect(EditorFieldChanges.between(base, draft).isEmpty, isTrue);
    });

    test('detects each changed field once', () {
      final base = baseFields();
      final draft = base.copyWith(
        title: 'Review parser v2',
        body: 'Full text with more\n',
        status: 'done',
        priority: 'P0',
        labelsText: 'needs-human',
        depsText: '',
      );

      final changes = EditorFieldChanges.between(base, draft);

      expect(changes.isEmpty, isFalse);
      expect(changes.fields, <EditorField>{
        EditorField.title,
        EditorField.body,
        EditorField.status,
        EditorField.priority,
        EditorField.labels,
        EditorField.deps,
      });
    });

    test('a syntactically broken dependency list still counts as changed', () {
      final base = baseFields();
      final draft = base.copyWith(depsText: 'T-abc');

      expect(EditorFieldChanges.between(base, draft).isEmpty, isFalse);
    });
  });

  group('EditorFieldChanges.toJson', () {
    test('sends only the changed fields with normalized values', () {
      final base = baseFields(labelsText: 'alpha');
      final draft = base.copyWith(
        labelsText: '  Needs-Human ,ZETA ',
        depsText: '4, T-2',
      );

      final json = EditorFieldChanges.between(base, draft).toJson();

      expect(json.keys.toSet(), <String>{'labels', 'deps'});
      expect(json['labels'], <String>['needs-human', 'zeta']);
      expect(json['deps'], <int>[4, 2]);
    });

    test('a cleared collection is an explicit empty array', () {
      final base = baseFields();
      final draft = base.copyWith(labelsText: '', depsText: '');

      final json = EditorFieldChanges.between(base, draft).toJson();

      expect(json['labels'], isEmpty);
      expect(json['deps'], isEmpty);
    });

    test('a clean draft produces no changes at all', () {
      final base = baseFields();

      final changes = EditorFieldChanges.between(base, base);

      expect(changes.isEmpty, isTrue);
      expect(changes.toJson(), isEmpty);
    });
  });

  group('validateEditorFields', () {
    test('accepts a clean canonical draft', () {
      final result = validateEditorFields(baseFields());

      expect(result.isValid, isTrue);
      expect(result.normalizedLabels, <String>['needs-human', 'zeta']);
      expect(result.normalizedDeps, <int>[2]);
      expect(result.summary, isNull);
    });

    test('rejects an empty title', () {
      final result = validateEditorFields(baseFields(title: ''));

      expect(result.isValid, isFalse);
      expect(result.errors[EditorField.title], contains('title'));
    });

    test('rejects 501 characters but accepts 500', () {
      final tooLong = validateEditorFields(baseFields(title: 'x' * 501));
      final atLimit = validateEditorFields(baseFields(title: 'y' * 500));

      expect(tooLong.errors[EditorField.title], contains('501'));
      expect(atLimit.isValid, isTrue);
    });

    test('counts Unicode scalar values, not UTF-16 code units', () {
      final emoji = String.fromCharCode(0x1F600);
      final sixHundredUnits = emoji * 300;

      final result = validateEditorFields(baseFields(title: sixHundredUnits));

      expect(result.isValid, isTrue);
    });

    test('rejects a body over 1048576 UTF-8 bytes and accepts the limit', () {
      final tooBig = validateEditorFields(baseFields(body: 'z' * 1048577));
      final atLimit = validateEditorFields(baseFields(body: 'z' * 1048576));
      final multibyte = validateEditorFields(
        baseFields(body: '\u0107' * 524289),
      );

      expect(tooBig.errors[EditorField.body], contains('1048577'));
      expect(atLimit.isValid, isTrue);
      expect(multibyte.errors[EditorField.body], isNotNull);
    });

    test('rejects 33 labels and accepts 32', () {
      String labels(int count) =>
          List<String>.generate(count, (int index) => 'l$index').join(', ');

      expect(
        validateEditorFields(
          baseFields(labelsText: labels(33)),
        ).errors[EditorField.labels],
        contains('32'),
      );
      expect(
        validateEditorFields(baseFields(labelsText: labels(32))).isValid,
        isTrue,
      );
    });

    test('rejects an invalid label character and an over-long label', () {
      final space = validateEditorFields(
        baseFields(labelsText: 'ok, Bad Label'),
      );
      final long = validateEditorFields(baseFields(labelsText: 'a' * 65));

      expect(space.errors[EditorField.labels], contains('Bad Label'));
      expect(long.errors[EditorField.labels], contains('65'));
    });

    test('rejects an unparsable dependency entry', () {
      final result = validateEditorFields(baseFields(depsText: 'T-002, T-abc'));

      expect(result.errors[EditorField.deps], contains('T-abc'));
    });

    test('rejects a self dependency by canonical ID', () {
      final result = validateEditorFields(
        baseFields(depsText: 'T-007, T-002'),
        taskId: 7,
      );

      expect(result.errors[EditorField.deps], contains('T-007'));
    });

    test('rejects more than 1000 distinct dependencies', () {
      final text = List<String>.generate(
        1001,
        (int index) => 'T-${(index + 1).toString().padLeft(3, '0')}',
      ).join(', ');

      final result = validateEditorFields(
        baseFields(depsText: text),
        taskId: 5000,
      );

      expect(result.errors[EditorField.deps], contains('1000'));
    });

    test('summarizes every invalid field once', () {
      final result = validateEditorFields(
        baseFields(title: '', labelsText: 'Bad Label'),
      );

      expect(
        result.errors.keys,
        containsAll(<EditorField>[EditorField.title, EditorField.labels]),
      );
      expect(result.summary, isNotNull);
      expect(result.summary!.split('; ').length, result.errors.length);
    });
  });

  group('ViewerUpdateResult', () {
    test('decodes a real saved response', () {
      final result = ViewerUpdateResult.fromJson(<String, Object?>{
        'command': 'viewer_update',
        'protocol_version': 1,
        'id': 7,
        'status': 'todo',
        'version': 4,
        'event_id': 12,
      });

      expect(result.id, 7);
      expect(result.status, 'todo');
      expect(result.version, 4);
      expect(result.eventId, 12);
      expect(result.isNoop, isFalse);
    });

    test('decodes a real no-op response with a null event id', () {
      final result = ViewerUpdateResult.fromJson(<String, Object?>{
        'command': 'viewer_update',
        'protocol_version': 1,
        'id': 7,
        'status': 'done',
        'version': 2,
        'event_id': null,
      });

      expect(result.isNoop, isTrue);
      expect(result.version, 2);
    });

    test('rejects a response for another command', () {
      expect(
        () => ViewerUpdateResult.fromJson(<String, Object?>{
          'command': 'viewer_show',
          'protocol_version': 1,
          'id': 7,
          'status': 'todo',
          'version': 4,
          'event_id': null,
        }),
        throwsA(anything),
      );
    });
  });

  group('ViewerUpdateRequest', () {
    test('serializes the documented request shape', () {
      final request = ViewerUpdateRequest(
        id: 7,
        expectVersion: 3,
        changes: EditorFieldChanges.between(
          baseFields(),
          baseFields(title: 'Review parser v2'),
        ),
      );

      expect(request.toJson(), <String, Object?>{
        'id': 7,
        'expect_version': 3,
        'changes': <String, Object?>{'title': 'Review parser v2'},
      });
    });
  });
}
