import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/ui/viewer_motion.dart';
import 'package:tasks_viewer/ui/viewer_icons.dart';

void main() {
  testWidgets('copy cue swaps once, holds finitely and retains its label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final flash = ViewerFlashController();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextButton.icon(
              onPressed: flash.flash,
              icon: ViewerFlashIcon(controller: flash),
              label: const Text('Copy reference'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(ViewerIcons.copy), findsOneWidget);
      await tester.tap(find.text('Copy reference'));
      await tester.pump();
      expect(find.byIcon(ViewerIcons.check), findsOneWidget);
      expect(find.bySemanticsLabel('Copy reference'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 140));
      expect(find.byIcon(ViewerIcons.check), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(ViewerIcons.copy), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
      flash.dispose();
    }
  });
  testWidgets('dialog entrance has one semantic child and reaches identity', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    late BuildContext launch;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            launch = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final closing = showDialog<void>(
      context: launch,
      animationStyle: viewerDialogAnimationStyle(launch),
      builder: (_) => ViewerDialogEntrance(
        child: Dialog(child: TextField(focusNode: focus, autofocus: true)),
      ),
    );
    await tester.pump();
    final scale = find.descendant(
      of: find.byType(ViewerDialogEntrance),
      matching: find.byType(ScaleTransition),
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<ScaleTransition>(scale).scale.value, .96);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.widget<ScaleTransition>(scale).scale.value, 1);
    Navigator.of(focus.context!).pop();
    await tester.pumpAndSettle();
    await closing;
  });

  testWidgets(
    'disclosure paints only its toggle, reserves target size and Off never asserts',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      Widget frame(bool expanded, double height, {bool off = false}) =>
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(disableAnimations: off),
                child: ViewerDisclosureTransition(
                  transitionKey: expanded,
                  child: SizedBox(
                    height: height,
                    child: TextField(focusNode: focus),
                  ),
                ),
              ),
            ),
          );
      await tester.pumpWidget(frame(false, 100));
      focus.requestFocus();
      await tester.pumpAndSettle();
      final field = tester.element(find.byType(TextField));
      await tester.pumpWidget(frame(false, 160));
      expect(
        tester.getSize(find.byType(ViewerDisclosureTransition)).height,
        160,
        reason: 'unrelated layout changes are instant',
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(frame(true, 260));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getSize(find.byType(ViewerDisclosureTransition)).height,
        260,
      );
      expect(tester.element(find.byType(TextField)), same(field));
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(frame(true, 300));
      expect(
        tester.getSize(find.byType(ViewerDisclosureTransition)).height,
        300,
      );
      await tester.pumpWidget(frame(false, 100, off: true));
      expect(
        tester.getSize(find.byType(ViewerDisclosureTransition)).height,
        100,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final off in [false, true]) {
    testWidgets(
      'entry keeps focus and semantic identity, reduced motion $off',
      (tester) async {
        final semantics = tester.ensureSemantics();

        final focus = FocusNode();
        addTearDown(focus.dispose);
        Widget frame(int epoch) => MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: off),
              child: ViewerEnterTransition(
                transitionKey: epoch,
                child: TextField(
                  focusNode: focus,
                  decoration: const InputDecoration(labelText: 'Only body'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(frame(0));
        focus.requestFocus();
        await tester.pump();
        final element = tester.element(find.byType(TextField));
        final node = tester.getSemantics(find.byType(TextField));
        await tester.pumpWidget(frame(1));
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.element(find.byType(TextField)), same(element));
        expect(tester.getSemantics(find.byType(TextField)).id, node.id);
        expect(focus.hasFocus, isTrue);
        final fade = find.descendant(
          of: find.byType(ViewerEnterTransition),
          matching: find.byWidgetPredicate(
            (w) => w is FadeTransition && w.alwaysIncludeSemantics,
          ),
        );
        expect(fade, findsOneWidget);
        final opacity = tester.widget<FadeTransition>(fade);
        expect(opacity.alwaysIncludeSemantics, isTrue);
        expect(opacity.opacity.value, off ? 1 : lessThan(1));
        await tester.pumpAndSettle();
        expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      },
    );
  }
}
