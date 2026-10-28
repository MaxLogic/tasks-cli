import 'dart:ui' show SemanticsRole;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/viewer_motion.dart';
import 'package:tasks_viewer/ui/app_shell.dart';
import 'package:tasks_viewer/controllers/detail_controller.dart';
import 'details_pane_test.dart' show pumpTaskDetails;
import '../support/viewer_test_support.dart';

void main() {
  testWidgets('underline snaps to resized geometry without tab motion', (
    tester,
  ) async {
    final h = await pumpTaskDetails(tester);
    h.model.showTab(TaskDetailTab.rules);
    await tester.pump();
    expect(
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).curve,
      ViewerMotion.enter,
    );
    await tester.pumpAndSettle();
    final indicator = find.byType(AnimatedPositioned);
    tester.view.physicalSize = const Size(2000, 900);
    await tester.pump();
    final bar = tester.widget<AnimatedPositioned>(indicator);
    final parent = find
        .ancestor(of: indicator, matching: find.byType(Stack))
        .first;
    final rect = tester.getRect(indicator);
    final stack = tester.getRect(parent);
    expect(rect.width, closeTo(stack.width / 4, .1));
    expect(rect.left - stack.left, closeTo(stack.width * .75, .1));
    expect(bar.duration, Duration.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('indicator settles under tab and a new task does not fade', (
    tester,
  ) async {
    final h = await pumpTaskDetails(tester);
    h.model.showTab(TaskDetailTab.rules);
    await tester.pumpAndSettle();
    final indicator = find.byType(AnimatedPositioned);
    expect(indicator, findsOneWidget);
    final bar = tester.widget<AnimatedPositioned>(indicator);
    final parent = find
        .ancestor(of: indicator, matching: find.byType(Stack))
        .first;
    expect(bar.left, closeTo(tester.getSize(parent).width * .75, .1));
    await h.model.openTaskIndex(1);
    await tester.pump();
    for (final fade in tester.widgetList<FadeTransition>(
      find.descendant(
        of: find.byType(ViewerEnterTransition),
        matching: find.byType(FadeTransition),
      ),
    )) {
      if (fade.alwaysIncludeSemantics) expect(fade.opacity.value, 1);
    }
    await tester.pumpAndSettle();
  });

  for (final off in [false, true]) {
    testWidgets('tab and edit focus identity with motion off $off', (
      tester,
    ) async {
      final h = await pumpTaskDetails(tester);
      if (off) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pump();
      }
      await pressKey(tester, LogicalKeyboardKey.f3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(h.model.detail!.tab.name, 'history');
      final panels = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.role == SemanticsRole.tabPanel,
      );
      expect(panels, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(h.handles(ViewerRegion.details).bodyFocus.hasFocus, isTrue);
      final paneFade = tester
          .widgetList<FadeTransition>(
            find.descendant(of: panels, matching: find.byType(FadeTransition)),
          )
          .where((f) => f.alwaysIncludeSemantics)
          .first;
      expect(paneFade.opacity.value, off ? 1 : lessThan(1));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pump();
      expect(h.model.editor.isEditing, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'editor title');
      await tester.pumpAndSettle();
    });
  }

  testWidgets('History and F3 focus land before paint motion completes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    final harness = await pumpTaskDetails(tester);
    await pressKey(tester, LogicalKeyboardKey.f3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text('History', skipOffstage: false), findsWidgets);
    await tester.pump(const Duration(milliseconds: 60));
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(
        of: find.byType(ViewerEnterTransition),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(
      fades.any((f) => f.opacity.value < 1 && f.alwaysIncludeSemantics),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('details-body')), findsOneWidget);
    expect(harness.handles(ViewerRegion.details).bodyFocus.hasFocus, isTrue);
    await tester.pumpAndSettle();
    semantics.dispose();
  });
}
