/// Application-root tests: theme, in-app text size and the injected shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/controllers/announcement_controller.dart';
import 'package:tasks_viewer/data/settings_draft.dart';

import 'support/viewer_test_support.dart';

void main() {
  testWidgets('the root shows the shell for injected test paths', (
    WidgetTester tester,
  ) async {
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
    );
    addTearDown(announcements.dispose);

    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(),
        announcements: announcements,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tasks Viewer'), findsOneWidget);
    expect(find.text('Settings (Ctrl+,)'), findsOneWidget);
    expect(find.text('Hotkey help (F10)'), findsOneWidget);
    expect(find.textContaining('test mode'), findsOneWidget);
    expect(find.textContaining('Configuration ready'), findsOneWidget);
  });

  testWidgets('the in-app text size scales the window', (
    WidgetTester tester,
  ) async {
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
    );
    addTearDown(announcements.dispose);

    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(),
        initialSettings: const ViewerSettingsDraft(textScalePercent: 150),
        announcements: announcements,
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.text('Tasks Viewer'));
    expect(MediaQuery.textScalerOf(context).scale(10), closeTo(15, 0.001));
  });

  testWidgets('the saved theme mode drives the window theme', (
    WidgetTester tester,
  ) async {
    final announcements = AnnouncementController(
      clipPlayer: RecordingClipPlayer(),
    );
    addTearDown(announcements.dispose);

    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(),
        initialSettings: const ViewerSettingsDraft(
          themeMode: ViewerThemeMode.dark,
        ),
        announcements: announcements,
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.text('Tasks Viewer'));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  test('viewerTextScaler multiplies the platform scale', () {
    expect(
      viewerTextScaler(TextScaler.noScaling, 200).scale(10),
      closeTo(20, 0.001),
    );
    expect(
      viewerTextScaler(const TextScaler.linear(1.5), 100).scale(10),
      closeTo(15, 0.001),
    );
  });
}
