import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/data/settings_store.dart';
import 'package:tasks_viewer/ui/pane_splitter.dart';
import '../support/viewer_test_support.dart';

void main() {
  for (final mode in ViewerThemeMode.values) {
    testWidgets('theme $mode renders and persists', (tester) async {
      final draft = ViewerSettingsDraft(themeMode: mode);
      expect(
        decodeSettingsDocument(encodeSettingsDocument(draft)).themeMode,
        mode,
      );
      await tester.pumpWidget(
        TasksViewerApp(
          environment: viewerTestEnvironment(suffix: 'theme'),
          initialSettings: draft,
        ),
      );
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
      expect(
        theme.brightness,
        mode == ViewerThemeMode.dark || mode == ViewerThemeMode.highContrastDark
            ? Brightness.dark
            : Brightness.light,
      );
      if (mode == ViewerThemeMode.highContrastDark ||
          mode == ViewerThemeMode.highContrastLight) {
        expect(theme.dividerTheme.thickness, 2);
      }
    });
  }
  testWidgets('system theme follows platform brightness and contrast changes', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(suffix: 'system-theme'),
      ),
    );
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
    expect(theme.brightness, Brightness.dark);
    expect(theme.dividerTheme.thickness, 2);
  });
  testWidgets('splitter supports drag and keyboard resizing', (tester) async {
    var movement = 0.0;
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              PaneSplitter(
                label: 'Resize panels',
                onResize: (delta) => movement += delta,
                onResizeEnd: () => saves++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.byType(PaneSplitter), const Offset(100, 0));
    expect(movement, greaterThan(0));
    expect(saves, 1);
    final previous = movement;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(movement, previous + 20);
    expect(saves, 2);
  });
}
