import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/settings_dialog.dart';
import 'package:tasks_viewer/ui/viewer_motion.dart';
import 'package:tasks_viewer/ui/commands.dart';
import '../support/viewer_test_support.dart';

void main() {
  for (final reason in ['windows', 'setting', 'platform']) {
    testWidgets('$reason disables shell, dialogs and theme transitions', (
      tester,
    ) async {
      if (reason == 'platform') {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      await tester.pumpWidget(
        TasksViewerApp(
          environment: viewerTestEnvironment(suffix: reason),
          windowsAnimationsEnabled: () => reason != 'windows',
          initialSettings: ViewerSettingsDraft(
            animations: reason == 'setting'
                ? ViewerAnimations.off
                : ViewerAnimations.followWindows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        MediaQuery.disableAnimationsOf(
          tester.element(find.text('Tasks Viewer')),
        ),
        isTrue,
      );
      expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .themeAnimationDuration,
        Duration.zero,
      );
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(SettingsDialog));
      expect(MediaQuery.disableAnimationsOf(context), isTrue);
      expect(viewerDialogAnimationStyle(context), AnimationStyle.noAnimation);
    });
  }
  testWidgets('focus and resume refresh the Windows flag without restart', (
    tester,
  ) async {
    var enabled = true;
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(suffix: 'live-motion'),
        windowsAnimationsEnabled: () => enabled,
      ),
    );
    await tester.pumpAndSettle();
    bool motionOff() => MediaQuery.disableAnimationsOf(
      tester.element(find.text('Tasks Viewer')),
    );
    expect(motionOff(), isFalse);
    enabled = false;
    for (final listener in windowManager.listeners) {
      listener.onWindowFocus();
    }
    await tester.pump();
    expect(motionOff(), isTrue);
    enabled = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(motionOff(), isFalse);
  });
  testWidgets('Alt+N reaches the preference and Save persists Off', (
    tester,
  ) async {
    ViewerSettingsDraft? saved;
    await tester.pumpWidget(
      TasksViewerApp(
        environment: viewerTestEnvironment(suffix: 'motion-save'),
        windowsAnimationsEnabled: () => true,
        onSettingsPersist: (draft) async {
          saved = draft;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await pressAlt(tester, LogicalKeyboardKey.keyN);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'settings animations',
    );
    expect(commandSpecById('settings.animations')?.label, 'Animations');
    final dropdown = find.byType(DropdownButtonFormField<ViewerAnimations>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save (Ctrl+S)'));
    await tester.pumpAndSettle();
    expect(saved?.animations, ViewerAnimations.off);
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.text('Tasks Viewer'))),
      isTrue,
    );
  });
}
