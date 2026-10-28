// Exercise all four themes and focus roles in the normal suite.
// Optionally pass PROBE_OUT and --update-goldens to retain review renders.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/button_theme.dart';
import 'package:tasks_viewer/ui/viewer_icons.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';

const _segoe = [
  r'C:\Windows\Fonts\segoeui.ttf',
  r'C:\Windows\Fonts\segoeuib.ttf',
  r'C:\Windows\Fonts\seguisb.ttf',
];
const _out = String.fromEnvironment('PROBE_OUT');

Future<void> _fonts() async {
  final s = FontLoader('Segoe UI');
  for (final p in _segoe) {
    s.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
  }
  await s.load();
  final i = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await i.load();
}

ThemeData _theme(Brightness b, bool hc) => viewerButtonTheme(
  ThemeData(
    fontFamily: 'Segoe UI',
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: b,
      contrastLevel: hc ? 1 : 0,
    ),
  ),
  highContrast: hc,
);

void main() {
  for (final (name, b, hc) in [
    ('dark', Brightness.dark, false),
    ('darkhc', Brightness.dark, true),
    ('light', Brightness.light, false),
    ('lighthc', Brightness.light, true),
  ]) {
    testWidgets(
      'states $name',
      (t) async {
        await _fonts();
        t.view.physicalSize = const Size(900, 420);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final f = List.generate(5, (_) => FocusNode());
        addTearDown(() {
          for (final node in f) {
            node.dispose();
          }
        });
        Widget row(String label, List<Widget> ws) => Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              SizedBox(width: 120, child: Text(label)),
              ...ws.expand((w) => [w, const SizedBox(width: 10)]),
            ],
          ),
        );
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(b, hc),
            home: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row('normal', [
                    FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Filled'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Tonal'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Outlined'),
                    ),
                    TextButton.icon(
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Text'),
                    ),
                    IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                  row('focused', [
                    FilledButton.icon(
                      focusNode: f[0],
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Filled'),
                    ),
                    FilledButton.tonalIcon(
                      focusNode: f[1],
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Tonal'),
                    ),
                    OutlinedButton.icon(
                      focusNode: f[2],
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Outlined'),
                    ),
                    TextButton.icon(
                      focusNode: f[3],
                      onPressed: () {},
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Text'),
                    ),
                    IconButton(
                      focusNode: f[4],
                      onPressed: () {},
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                  row('disabled', [
                    FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Filled'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Tonal'),
                    ),
                    OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Outlined'),
                    ),
                    TextButton.icon(
                      onPressed: null,
                      icon: const Icon(ViewerIcons.save),
                      label: const Text('Text'),
                    ),
                    const IconButton(
                      onPressed: null,
                      icon: Icon(Icons.refresh),
                    ),
                  ]),
                  const Padding(
                    padding: EdgeInsets.all(6),
                    child: SizedBox(height: 1),
                  ),
                  Expanded(
                    child: ViewerUnsavedChangesDialog(
                      identity: 'T-042',
                      title: 'Buttons look like buttons',
                      question: 'Save your changes before leaving?',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        if (_out.isNotEmpty) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              Uri.file('$_out/dialog_${name}_cancel_focus.png'),
            ),
          );
        }
        // Focus each node in turn is impossible simultaneously; capture with one focus per pass.
        for (var i = 0; i < 5; i++) {
          f[i].requestFocus();
          await t.pumpAndSettle();
          expect(f[i].hasFocus, isTrue);
          expect(t.takeException(), isNull);
          if (_out.isNotEmpty) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(Uri.file('$_out/states_${name}_f$i.png')),
            );
          }
        }
      },
      skip: !Platform.isWindows,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
