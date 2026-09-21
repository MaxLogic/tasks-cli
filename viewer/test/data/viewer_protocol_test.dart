/// Strict success-envelope and payload decoding (viewer/spec.md section 4.1).
///
/// The viewer must never accept a document it cannot trust: a protocol
/// mismatch, a duplicate key, a missing required field or a wrong type is an
/// error the user can act on, never a silently empty list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/data/models.dart';

/// A complete, valid `viewer_projects` stdout document.
String projectsDocument({
  String command = 'viewer_projects',
  String availability = 'available',
  String? stats =
      '{"total":10,"open":4,"blocked":1,"done":4,"cancelled":2,'
      '"started_ms":1700000000000,"last_write_ms":1700000001000,'
      '"progress_percent":50.0}',
  String? error = 'null',
  String extra = '',
}) =>
    '''
{
  "schema_version": 1,
  "project_id": null,
  "data": {
    "command": "$command",
    "protocol_version": 1,
    "items": [
      {
        "project_id": "2f6f0a54-1b1a-4c3a-9a3e-6a1f7e9d1111",
        "name": "Alpha",
        "roots": ["C:\\\\work\\\\alpha", "D:\\\\mirror\\\\Żółć"],
        "availability": "$availability",
        "error": $error,
        "sampled_at_ms": 1700000002000,
        "stats": $stats$extra
      }
    ],
    "total_count": 1,
    "offset": 0,
    "limit": 100,
    "has_more": false,
    "next_offset": null,
    "snapshot": "p1.deadbeef"
  }
}
''';

void main() {
  group('decodeStrictJson', () {
    test('rejects a duplicate key in any object', () {
      expect(
        () => decodeStrictJson('{"a":1,"a":2}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('duplicate JSON key "a"'),
          ),
        ),
      );
      expect(
        () => decodeStrictJson('{"outer":{"b":1,"b":2}}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeStrictJson('{"list":[{"c":1,"c":2}]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects trailing content and unparsed input', () {
      expect(() => decodeStrictJson('{} {}'), throwsA(isA<FormatException>()));
      expect(
        () => decodeStrictJson('not json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodes surrogate pairs and refuses an unpaired surrogate', () {
      expect(decodeStrictJson('"\\ud83d\\ude00"'), '😀');
      // Rust output is valid UTF-8, so a lone surrogate is never legitimate
      // and must not be guessed at.
      expect(
        () => decodeStrictJson('"\\ud83d"'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('unpaired UTF-16 surrogate'),
          ),
        ),
      );
    });
  });

  group('ViewerEnvelope', () {
    test('accepts the documented envelope and ignores additive fields', () {
      final envelope = ViewerEnvelope.decode(
        projectsDocument(extra: ',"future_field":42'),
        expectedCommands: const <String>{'viewer_projects'},
      );
      expect(envelope.schemaVersion, 1);
      expect(envelope.projectId, isNull);
      expect(envelope.command, 'viewer_projects');
    });

    test('rejects a different schema_version', () {
      final source = projectsDocument().replaceFirst(
        '"schema_version": 1',
        '"schema_version": 2',
      );
      expect(
        () => ViewerEnvelope.decode(source),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('rejects a command the caller did not ask for', () {
      expect(
        () => ViewerEnvelope.decode(
          projectsDocument(command: 'viewer_tasks'),
          expectedCommands: const <String>{'viewer_projects'},
        ),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('rejects malformed JSON instead of returning an empty payload', () {
      expect(
        () => ViewerEnvelope.decode('{"schema_version": 1,'),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });
  });

  group('ProjectPage', () {
    test('maps every documented field including null statistics', () {
      final envelope = ViewerEnvelope.decode(projectsDocument());
      final page = ProjectPage.fromJson(envelope.data);
      expect(page.protocolVersion, 1);
      expect(page.totalCount, 1);
      expect(page.limit, 100);
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, isNull);
      expect(page.snapshot, 'p1.deadbeef');

      final item = page.items.single;
      expect(item.name, 'Alpha');
      expect(item.roots, <String>[r'C:\work\alpha', r'D:\mirror\Żółć']);
      expect(item.isAvailable, isTrue);
      expect(item.error, isNull);
      expect(item.stats?.total, 10);
      expect(item.stats?.open, 4);
      expect(item.stats?.progressPercent, 50.0);
      expect(item.rootSummary, contains(r'D:\mirror\Żółć'));
    });

    test('an unavailable project carries an error and no statistics', () {
      final envelope = ViewerEnvelope.decode(
        projectsDocument(
          availability: 'error',
          stats: 'null',
          error: '{"code":"locked","message":"database is locked"}',
        ),
      );
      final item = ProjectPage.fromJson(envelope.data).items.single;
      expect(item.isAvailable, isFalse);
      expect(item.availability, ProjectAvailability.error);
      expect(item.stats, isNull, reason: 'never report unavailable as zero');
      expect(item.error?.code, 'locked');
      expect(item.error?.message, 'database is locked');
    });

    test('rejects an unsupported availability value', () {
      final envelope = ViewerEnvelope.decode(
        projectsDocument(availability: 'locked', stats: 'null'),
      );
      expect(
        () => ProjectPage.fromJson(envelope.data),
        throwsA(
          isA<ViewerMalformedResponseFailure>().having(
            (error) => error.message,
            'message',
            contains('unsupported project availability'),
          ),
        ),
      );
    });

    test('rejects a page whose required count is missing', () {
      final envelope = ViewerEnvelope.decode(projectsDocument());
      final data = Map<String, Object?>.from(envelope.data)
        ..remove('total_count');
      expect(
        () => ProjectPage.fromJson(data),
        throwsA(
          isA<ViewerMalformedResponseFailure>().having(
            (error) => error.message,
            'message',
            contains('total_count'),
          ),
        ),
      );
    });

    test('rejects a wrong-type protocol_version', () {
      final envelope = ViewerEnvelope.decode(
        projectsDocument().replaceFirst(
          '"protocol_version": 1',
          '"protocol_version": "1"',
        ),
      );
      expect(
        () => ProjectPage.fromJson(envelope.data),
        throwsA(isA<ViewerMalformedResponseFailure>()),
      );
    });

    test('a future protocol version is a specific, actionable failure', () {
      final envelope = ViewerEnvelope.decode(
        projectsDocument().replaceFirst(
          '"protocol_version": 1',
          '"protocol_version": 2',
        ),
      );
      expect(
        () => ProjectPage.fromJson(envelope.data),
        throwsA(
          isA<ViewerProtocolMismatchFailure>().having(
            (error) => error.message,
            'message',
            contains('protocol version 2 is not supported'),
          ),
        ),
      );
    });
  });

  group('ViewerErrorEnvelope', () {
    test('decodes a conflict with both versions', () {
      final decoded = ViewerErrorEnvelope.tryDecode(
        '{"schema_version":1,"error":{"code":"version_conflict",'
        '"message":"expected 3, found 4",'
        '"conflict":{"expected":3,"current":4}}}',
      );
      expect(decoded, isNotNull);
      expect(decoded!.code, 'version_conflict');
      expect(decoded.conflictExpected, 3);
      expect(decoded.conflictCurrent, 4);
      final failure = decoded.asFailure(4);
      expect(failure.exitCode, 4);
      expect(failure.isStaleSnapshot, isFalse);
    });

    test('recognises a stale snapshot and refuses a non-error document', () {
      final decoded = ViewerErrorEnvelope.tryDecode(
        '{"schema_version":1,"error":{"code":"stale_snapshot",'
        '"message":"page expired"}}',
      );
      expect(decoded!.asFailure(4).isStaleSnapshot, isTrue);
      expect(ViewerErrorEnvelope.tryDecode('{"schema_version":1}'), isNull);
      expect(ViewerErrorEnvelope.tryDecode('boom'), isNull);
      expect(
        ViewerErrorEnvelope.tryDecode(
          '{"schema_version":1,"error":{"code":7,"message":"x"}}',
        ),
        isNull,
      );
    });
  });

  group('ProjectQuery', () {
    test('serialises the documented request defaults', () {
      expect(const ProjectQuery().toJson(), <String, Object?>{
        'query': '',
        'state': 'all',
        'sort': 'name',
        'direction': 'asc',
        'offset': 0,
        'limit': 100,
        'snapshot': null,
      });
    });

    test('copyWith can clear a snapshot deliberately', () {
      const query = ProjectQuery(snapshot: 'p1.abc', offset: 100);
      expect(query.copyWith(offset: 0).snapshot, 'p1.abc');
      expect(query.copyWith(offset: 0, clearSnapshot: true).snapshot, isNull);
    });
  });
}
