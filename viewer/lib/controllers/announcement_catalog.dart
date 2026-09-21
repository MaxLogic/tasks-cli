/// Fixed spoken-feedback catalog shared by the Dart app and the development-time
/// ElevenLabs generator (viewer/spec.md section 9.1).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show AssetBundle;

/// One fixed spoken phrase. Text is exact and must never be generated at
/// runtime or spliced with task data.
class AnnouncementClip {
  const AnnouncementClip({required this.id, required this.text});

  final String id;
  final String text;
}

/// Raised when the bundled catalog is missing or malformed.
class AnnouncementCatalogError implements Exception {
  AnnouncementCatalogError(this.message);

  final String message;

  @override
  String toString() => 'AnnouncementCatalogError: $message';
}

/// The fixed announcement catalog.
class AnnouncementCatalog {
  const AnnouncementCatalog({required this.voice, required this.entries});

  static const String assetPath = 'assets/announcements/catalog.json';

  final String voice;
  final List<AnnouncementClip> entries;

  AnnouncementClip? clip(String id) {
    for (final entry in entries) {
      if (entry.id == id) {
        return entry;
      }
    }
    return null;
  }

  static AnnouncementCatalog parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw AnnouncementCatalogError(
        'Announcement catalog is not valid JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw AnnouncementCatalogError(
        'Announcement catalog must be a JSON object.',
      );
    }
    final voice = decoded['voice'];
    final entries = decoded['entries'];
    if (voice is! String || voice.isEmpty) {
      throw AnnouncementCatalogError(
        'Announcement catalog is missing a "voice" string.',
      );
    }
    if (entries is! List) {
      throw AnnouncementCatalogError(
        'Announcement catalog is missing an "entries" list.',
      );
    }
    final clips = <AnnouncementClip>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        throw AnnouncementCatalogError('Catalog entry is not an object.');
      }
      final id = entry['id'];
      final text = entry['text'];
      if (id is! String || id.isEmpty || text is! String || text.isEmpty) {
        throw AnnouncementCatalogError(
          'Catalog entry needs non-empty "id" and "text" strings.',
        );
      }
      if (clips.any((clip) => clip.id == id)) {
        throw AnnouncementCatalogError('Duplicate announcement id "$id".');
      }
      clips.add(AnnouncementClip(id: id, text: text));
    }
    return AnnouncementCatalog(voice: voice, entries: List.unmodifiable(clips));
  }

  static Future<AnnouncementCatalog> load(AssetBundle bundle) async {
    final String raw;
    try {
      raw = await bundle.loadString(assetPath);
    } on FlutterError catch (error) {
      throw AnnouncementCatalogError(
        'Bundled announcement catalog $assetPath is unavailable: '
        '${error.message}',
      );
    }
    return parse(raw);
  }
}
