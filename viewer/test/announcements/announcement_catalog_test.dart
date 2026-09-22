/// The shipped Bella catalog (viewer/spec.md 9.1).
///
/// These cases read the files that ship beside the viewer and load the catalog
/// through the same asset bundle the application uses at launch, so a missing
/// or renamed clip fails here instead of at the first announcement.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/controllers/announcement_catalog.dart';

/// The voice and model the clips were generated with (spec 9.1).
const String expectedVoiceId = 'hpp4J3VqNfWAUOO0d1Us';

Map<String, Object?> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _manifestEntries(Map<String, Object?> manifest) =>
    <Map<String, Object?>>[
      for (final entry in manifest['entries']! as List)
        (entry as Map<String, Object?>),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled catalog loads through the asset bundle', () async {
    final catalog = await AnnouncementCatalog.load(rootBundle);
    expect(catalog.entries, isNotEmpty);
    expect(catalog.voice, 'Bella');
  });

  test('every catalog entry ships a clip the manifest vouches for', () async {
    final catalog = await AnnouncementCatalog.load(rootBundle);
    final manifest = _readJson('assets/announcements/manifest.json');
    final voice = manifest['voice']! as Map<String, Object?>;
    expect(voice['id'], expectedVoiceId);
    expect(manifest['model_id'], 'eleven_multilingual_v2');
    expect(manifest['output_format'], 'mp3_44100_128');

    final byId = <String, Map<String, Object?>>{
      for (final entry in _manifestEntries(manifest))
        entry['id']! as String: entry,
    };
    expect(byId.length, catalog.entries.length);

    for (final clip in catalog.entries) {
      final entry = byId[clip.id];
      expect(entry, isNotNull, reason: 'manifest entry for ${clip.id}');
      expect(entry!['text'], clip.text, reason: 'text of ${clip.id}');
      expect(entry['file'], '${clip.id}.mp3');

      final file = File('assets/announcements/${clip.id}.mp3');
      expect(file.existsSync(), isTrue, reason: 'clip file for ${clip.id}');
      expect(file.lengthSync(), greaterThan(0), reason: 'clip ${clip.id}');
      expect(
        entry['bytes'],
        file.lengthSync(),
        reason: 'recorded size of ${clip.id}',
      );
      expect(
        entry['sha256'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: 'recorded hash of ${clip.id}',
      );
    }

    // The clip paths the player builds are the files that ship.
    for (final clip in catalog.entries) {
      expect(File('assets/announcements/${clip.id}.mp3').existsSync(), isTrue);
    }
  });

  test('the catalog helper finds clips and reports unknown ids', () async {
    final catalog = await AnnouncementCatalog.load(rootBundle);
    final first = catalog.entries.first;
    expect(catalog.clip(first.id)?.text, first.text);
    expect(catalog.clip('no-such-clip'), isNull);
  });

  group('parse failures', () {
    test('invalid JSON is refused', () {
      expect(
        () => AnnouncementCatalog.parse('{not json'),
        throwsA(isA<AnnouncementCatalogError>()),
      );
    });

    test('a catalog without a voice is refused', () {
      expect(
        () => AnnouncementCatalog.parse('{"entries": []}'),
        throwsA(isA<AnnouncementCatalogError>()),
      );
    });

    test('an entry without text is refused', () {
      expect(
        () => AnnouncementCatalog.parse(
          '{"voice": "Bella", "entries": [{"id": "saving"}]}',
        ),
        throwsA(isA<AnnouncementCatalogError>()),
      );
    });

    test('a duplicate id is refused', () {
      expect(
        () => AnnouncementCatalog.parse(
          '{"voice": "Bella", "entries": ['
          '{"id": "saving", "text": "Saving"},'
          '{"id": "saving", "text": "Saving again"}]}',
        ),
        throwsA(
          isA<AnnouncementCatalogError>().having(
            (error) => error.message,
            'message',
            contains('saving'),
          ),
        ),
      );
    });
  });
}
