/// Bella clip playback over MCI (viewer/spec.md 9.1).
///
/// The MCI device is a recording double and the clips are injected bytes, so
/// these cases open no audio device and play nothing aloud; the staged files
/// live under a throwaway temp directory the test removes afterwards.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/controllers/announcement_catalog.dart';
import 'package:tasks_viewer/platform/announcement_player.dart';

/// Records every MCI command and answers with scripted results.
class ScriptedMciBridge implements MciBridge {
  /// Commands matching this predicate fail with [failureCode].
  bool Function(String command)? failOn;

  int failureCode = 259;
  String failureText = 'The device is not ready.';

  /// Answer for `status <alias> mode`; null stands for "no answer".
  String? mode = 'playing';

  final List<String> commands = <String>[];
  int queries = 0;

  @override
  int send(String command) {
    commands.add(command);
    if (failOn?.call(command) ?? false) {
      return failureCode;
    }
    return 0;
  }

  @override
  String errorText(int code) => 'code $code: $failureText';

  @override
  String? query(String command) {
    queries += 1;
    return mode;
  }
}

/// One catalog clip as the controller would hand it to the player.
AnnouncementClip clipFor(String id) => AnnouncementClip(id: id, text: id);

late Directory _clipRoot;
late ScriptedMciBridge _bridge;
late List<String> _requestedAssets;

/// Builds a player over the shared temp root and a fresh scripted bridge.
WindowsBellaClipPlayer _buildPlayer({
  Uint8List? bytes,
  Object? loadFailure,
  Duration pollInterval = const Duration(milliseconds: 20),
}) {
  _bridge = ScriptedMciBridge();
  final player = WindowsBellaClipPlayer(
    loadAsset: (assetPath) async {
      _requestedAssets.add(assetPath);
      final failure = loadFailure;
      if (failure != null) {
        throw failure;
      }
      return bytes ??
          Uint8List.fromList(utf8.encode('clip bytes for $assetPath'));
    },
    bridge: _bridge,
    tempRoot: _clipRoot.path,
    pollInterval: pollInterval,
  );
  addTearDown(player.dispose);
  return player;
}

/// Path the player stages one clip at for this process.
String _stagedPath(String clipId) =>
    '${_clipRoot.path}${Platform.pathSeparator}'
    'clips-$pid${Platform.pathSeparator}$clipId.mp3';

void main() {
  setUp(() {
    _clipRoot = Directory.systemTemp.createTempSync('viewer-clips-test-');
    _requestedAssets = <String>[];
    addTearDown(() {
      if (_clipRoot.existsSync()) {
        _clipRoot.deleteSync(recursive: true);
      }
    });
  });

  group('clip identity', () {
    test('clip ids resolve to the bundled asset paths', () {
      expect(
        WindowsBellaClipPlayer.assetPathFor('saving'),
        'assets/announcements/saving.mp3',
      );
      expect(WindowsBellaClipPlayer.alias, isNot(contains(' ')));
      expect(WindowsBellaClipPlayer.alias, isNot(contains(r'\')));
    });
  });

  group('play', () {
    test('stages the clip once and hands MCI open, volume and play', () async {
      final player = _buildPlayer();
      await player.play(clipFor('saving'), volume: 0.7);

      expect(_requestedAssets, <String>['assets/announcements/saving.mp3']);
      final staged = File(_stagedPath('saving'));
      expect(staged.existsSync(), isTrue);
      expect(staged.readAsBytesSync(), isNotEmpty);
      expect(player.isPlaying, isTrue);
      expect(_bridge.commands, <String>[
        'open "${staged.path}" type mpegvideo alias ${WindowsBellaClipPlayer.alias}',
        'setaudio ${WindowsBellaClipPlayer.alias} volume to 700',
        'play ${WindowsBellaClipPlayer.alias}',
      ]);
    });

    test(
      'never overlaps: the previous clip closes before the next opens',
      () async {
        final player = _buildPlayer();
        await player.play(clipFor('saving'), volume: 1);
        await player.play(clipFor('refreshed'), volume: 0.4);

        final alias = WindowsBellaClipPlayer.alias;
        expect(_bridge.commands, <String>[
          'open "${_stagedPath('saving')}" type mpegvideo alias $alias',
          'setaudio $alias volume to 1000',
          'play $alias',
          'stop $alias',
          'close $alias',
          'open "${_stagedPath('refreshed')}" type mpegvideo alias $alias',
          'setaudio $alias volume to 400',
          'play $alias',
        ]);
      },
    );

    test('a repeated clip reuses the staged file', () async {
      final player = _buildPlayer();
      await player.play(clipFor('saving'), volume: 1);
      await player.stop();
      await player.play(clipFor('saving'), volume: 1);

      expect(_requestedAssets, hasLength(1));
      expect(
        _bridge.commands.where((command) => command.startsWith('open ')),
        hasLength(2),
      );
    });

    test('volume maps onto the MCI 0..1000 range and is clamped', () async {
      final player = _buildPlayer();
      for (final (volume, level) in <(double, int)>[
        (0, 0),
        (0.55, 550),
        (1, 1000),
        (2, 1000),
        (-1, 0),
      ]) {
        await player.play(clipFor('saving'), volume: volume);
        expect(
          _bridge.commands.last,
          'play ${WindowsBellaClipPlayer.alias}',
          reason: 'every play still runs',
        );
        expect(
          _bridge.commands,
          contains('setaudio ${WindowsBellaClipPlayer.alias} volume to $level'),
          reason: 'volume $volume maps to $level',
        );
      }
    });

    test('a missing bundle asset is a typed error naming the clip', () async {
      final player = _buildPlayer(loadFailure: StateError('asset missing'));
      await expectLater(
        player.play(clipFor('saving'), volume: 1),
        throwsA(
          isA<AnnouncementPlaybackError>().having(
            (error) => error.message,
            'message',
            contains('"saving"'),
          ),
        ),
      );
      expect(player.isPlaying, isFalse);
      expect(_bridge.commands, isEmpty);
    });

    test('an empty bundle asset is refused before MCI is asked', () async {
      final player = _buildPlayer(bytes: Uint8List(0));
      await expectLater(
        player.play(clipFor('saving'), volume: 1),
        throwsA(isA<AnnouncementPlaybackError>()),
      );
      expect(_bridge.commands, isEmpty);
    });

    test('an MCI failure is a typed error naming the command', () async {
      final player = _buildPlayer();
      _bridge.failOn = (command) => command.startsWith('play ');
      await expectLater(
        player.play(clipFor('saving'), volume: 1),
        throwsA(
          isA<AnnouncementPlaybackError>().having(
            (error) => error.message,
            'message',
            contains('play ${WindowsBellaClipPlayer.alias}'),
          ),
        ),
      );
      // The failed play is still cleaned up by the next stop.
      await player.stop();
      expect(
        _bridge.commands,
        containsAllInOrder(<String>[
          'stop ${WindowsBellaClipPlayer.alias}',
          'close ${WindowsBellaClipPlayer.alias}',
        ]),
      );
    });

    test('a path that cannot be quoted never reaches MCI', () async {
      final root = Directory.systemTemp.createTempSync('viewer-clips-quote-');
      addTearDown(() {
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });
      final bridge = ScriptedMciBridge();
      final player = WindowsBellaClipPlayer(
        loadAsset: (assetPath) async => Uint8List.fromList(<int>[1, 2, 3]),
        bridge: bridge,
        tempRoot: '${root.path}${Platform.pathSeparator}odd"quote',
        pollInterval: const Duration(milliseconds: 20),
      );
      addTearDown(player.dispose);

      await expectLater(
        player.play(clipFor('saving'), volume: 1),
        throwsA(isA<AnnouncementPlaybackError>()),
      );
      expect(
        bridge.commands.where((command) => command.startsWith('open ')),
        isEmpty,
      );
    });
  });

  group('stop and poll', () {
    test('stop closes the alias and stops polling', () async {
      final player = _buildPlayer();
      await player.play(clipFor('saving'), volume: 1);
      await player.stop();

      expect(player.isPlaying, isFalse);
      expect(
        _bridge.commands,
        containsAllInOrder(<String>[
          'stop ${WindowsBellaClipPlayer.alias}',
          'close ${WindowsBellaClipPlayer.alias}',
        ]),
      );
      final queries = _bridge.queries;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_bridge.queries, queries);
    });

    test(
      'the poll closes the alias once MCI reports the clip stopped',
      () async {
        final player = _buildPlayer();
        await player.play(clipFor('saving'), volume: 1);
        _bridge.mode = 'stopped';

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(_bridge.queries, greaterThan(0));
        expect(player.isPlaying, isFalse);
        expect(
          _bridge.commands,
          containsAllInOrder(<String>[
            'stop ${WindowsBellaClipPlayer.alias}',
            'close ${WindowsBellaClipPlayer.alias}',
          ]),
        );

        final queries = _bridge.queries;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(_bridge.queries, queries);
      },
    );

    test('stop is safe when no clip is open', () async {
      final player = _buildPlayer();
      await player.stop();
      expect(_bridge.commands, isEmpty);
      expect(player.isPlaying, isFalse);
    });
  });

  group('dispose', () {
    test('removes the staged clips and refuses further playback', () async {
      final player = _buildPlayer();
      await player.play(clipFor('saving'), volume: 1);
      final staged = File(_stagedPath('saving'));
      expect(staged.existsSync(), isTrue);

      await player.dispose();
      expect(staged.existsSync(), isFalse);
      expect(player.isPlaying, isFalse);
      final leftovers = _clipRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.mp3'));
      expect(leftovers, isEmpty);

      // Repeating dispose is a no-op, and playback afterwards is refused.
      await player.dispose();
      await expectLater(
        player.play(clipFor('saving'), volume: 1),
        throwsA(isA<AnnouncementPlaybackError>()),
      );
    });
  });
}
