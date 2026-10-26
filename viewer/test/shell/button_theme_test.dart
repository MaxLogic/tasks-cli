import 'dart:ui' show Tristate, ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:tasks_viewer/app.dart';
import 'package:tasks_viewer/data/settings_draft.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';

import '../support/viewer_test_support.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

void main() {
  for (final mode in [
    ViewerThemeMode.dark,
    ViewerThemeMode.highContrastDark,
    ViewerThemeMode.light,
    ViewerThemeMode.highContrastLight,
  ]) {
    testWidgets(
      '$mode secondary differs from tertiary and dialog surface',
      (tester) async {
        await tester.pumpWidget(
          TasksViewerApp(
            environment: viewerTestEnvironment(suffix: 'secondary'),
            initialSettings: ViewerSettingsDraft(themeMode: mode),
          ),
        );
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
        final secondary = theme.outlinedButtonTheme.style!.backgroundColor!
            .resolve({});
        expect(
          secondary,
          isNot(theme.textButtonTheme.style!.backgroundColor!.resolve({})),
        );
        expect(secondary, isNot(theme.colorScheme.surfaceContainerHigh));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
    testWidgets(
      '$mode destructive dialog roles and safe default',
      (tester) async {
        await tester.pumpWidget(
          TasksViewerApp(
            environment: viewerTestEnvironment(suffix: 'roles'),
            initialSettings: ViewerSettingsDraft(themeMode: mode),
          ),
        );
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
        for (final dialog in [
          const ViewerUnsavedChangesDialog(
            identity: 'TSK-042',
            title: 'Buttons',
            question: 'Save?',
          ),
          const ViewerMarkDoneDirtyDialog(
            identity: 'TSK-042',
            title: 'Buttons',
          ),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(body: dialog),
            ),
          );
          await tester.pumpAndSettle();
          final discard = tester.widget<OutlinedButton>(
            find.byType(OutlinedButton),
          );
          expect(
            discard.style?.backgroundColor?.resolve({}),
            theme.colorScheme.errorContainer,
          );
          expect(
            discard.style?.foregroundColor?.resolve({}),
            theme.colorScheme.onErrorContainer,
          );
          final colors = theme.colorScheme;
          for (final alpha in [0.0, .08, .12]) {
            expect(
              contrast(
                colors.onErrorContainer,
                Color.alphaBlend(
                  colors.onErrorContainer.withValues(alpha: alpha),
                  colors.errorContainer,
                ),
              ),
              greaterThanOrEqualTo(4.5),
            );
          }
          final cancel = find.widgetWithText(TextButton, 'Cancel (Alt+C)');
          final focus = Focus.of(
            tester.element(
              find.descendant(of: cancel, matching: find.byType(InkWell)),
            ),
          );
          expect(focus.hasFocus, isTrue);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      '$mode rendered focus differs outside the same button',
      (tester) async {
        await tester.pumpWidget(
          TasksViewerApp(
            environment: viewerTestEnvironment(suffix: 'ring'),
            initialSettings: ViewerSettingsDraft(themeMode: mode),
          ),
        );
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
        final node = FocusNode();
        addTearDown(node.dispose);
        for (final button in <Widget>[
          TextButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Edit'),
          ),
          OutlinedButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Secondary'),
          ),
          FilledButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('Primary'),
          ),
          FilledButton.tonal(
            focusNode: node,
            onPressed: () {},
            child: const Text('Tonal'),
          ),
          IconButton(
            focusNode: node,
            onPressed: () {},
            icon: const Icon(Icons.refresh),
          ),
        ]) {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Center(
                  child: RepaintBoundary(
                    child: ColoredBox(
                      color: theme.colorScheme.surface,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: button,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byType(RepaintBoundary).first,
          );
          final material = find.descendant(
            of: find.byWidget(button),
            matching: find.byType(Material),
          );
          final buttonRect = tester.getRect(material);
          final origin = boundary.localToGlobal(Offset.zero);
          final x = (buttonRect.center.dx - origin.dx).floor();
          final y = (buttonRect.top - origin.dy - 4).floor();
          Future<Color> pixel() async {
            final image = await boundary.toImage();
            final data = (await image.toByteData(
              format: ImageByteFormat.rawRgba,
            ))!;
            final offset = (y * image.width + x) * 4;
            final color = Color.fromARGB(
              data.getUint8(offset + 3),
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            );
            image.dispose();
            return color;
          }

          final normal = await tester.runAsync(pixel);
          node.requestFocus();
          await tester.pumpAndSettle();
          final focused = await tester.runAsync(pixel);
          expect(
            contrast(normal!, focused!),
            greaterThanOrEqualTo(3),
            reason: '$mode ${button.runtimeType}: separate outer ring',
          );
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
    testWidgets(
      '$mode action containers, contrast, states and semantics',
      (tester) async {
        await tester.pumpWidget(
          TasksViewerApp(
            environment: viewerTestEnvironment(suffix: 'button-theme'),
            initialSettings: ViewerSettingsDraft(themeMode: mode),
          ),
        );
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(find.text('Tasks Viewer')));
        for (final style in [
          theme.textButtonTheme.style!,
          theme.outlinedButtonTheme.style!,
          theme.filledButtonTheme.style!,
          theme.iconButtonTheme.style!,
        ]) {
          expect(
            style.shape!.resolve({WidgetState.focused}).runtimeType,
            isNot(style.shape!.resolve({}).runtimeType),
            reason:
                'Focus must add a separate ring, not thicken the same border',
          );
          expect(
            style.backgroundColor!.resolve({WidgetState.focused}),
            style.backgroundColor!.resolve({}),
            reason: 'Focus preserves role fill',
          );
        }
        expect(
          theme.outlinedButtonTheme.style!.backgroundColor!.resolve({}),
          isNot(theme.textButtonTheme.style!.backgroundColor!.resolve({})),
          reason: 'Secondary and tertiary surfaces differ',
        );
        for (final style in [
          theme.textButtonTheme.style,
          theme.outlinedButtonTheme.style,
          theme.filledButtonTheme.style,
          theme.iconButtonTheme.style,
        ]) {
          expect(style, isNotNull);
          final normal = style!.side!.resolve({})!;
          final focused = style.side!.resolve({WidgetState.focused})!;
          expect(normal.width, greaterThanOrEqualTo(1));
          expect(focused.width, greaterThanOrEqualTo(1));
          expect(
            style.minimumSize!.resolve({})!.height,
            greaterThanOrEqualTo(32),
          );
          final fill =
              style.backgroundColor?.resolve({}) ?? theme.colorScheme.surface;
          expect(
            [
              contrast(normal.color, theme.colorScheme.surface),
              contrast(fill, theme.colorScheme.surface),
            ].reduce((a, b) => a > b ? a : b),
            greaterThanOrEqualTo(3),
          );
          for (final states in <Set<WidgetState>>[
            {},
            {WidgetState.hovered},
            {WidgetState.pressed},
            {WidgetState.focused},
            {WidgetState.focused, WidgetState.hovered},
          ]) {
            final background = style.backgroundColor?.resolve(states);
            final foreground = style.foregroundColor?.resolve(states);
            if (background != null && foreground != null) {
              final overlay =
                  style.overlayColor?.resolve(states) ?? Colors.transparent;
              final painted = Color.alphaBlend(overlay, background);
              expect(contrast(foreground, painted), greaterThanOrEqualTo(4.5));
              expect(
                contrast(style.side!.resolve(states)!.color, painted),
                greaterThanOrEqualTo(3),
              );
            }
          }
          expect(
            style.side!.resolve({WidgetState.disabled})!.color.a,
            lessThan(1),
          );
        }
        final semantics = tester.ensureSemantics();
        var activations = 0;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Wrap(
                children: [
                  TextButton(
                    focusNode: focus,
                    onPressed: () => activations++,
                    child: const Text('Edit'),
                  ),
                  const TextButton(onPressed: null, child: Text('Mark done')),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('Copy reference'),
                  ),
                  FilledButton(onPressed: () {}, child: const Text('Save')),
                  FilledButton.tonal(
                    onPressed: () {},
                    child: const Text('Enrich clipboard (Alt+E)'),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.clear,
                      semanticLabel: 'Clear search',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final label in [
          'Edit',
          'Mark done',
          'Copy reference',
          'Save',
          'Enrich clipboard (Alt+E)',
          'Clear search',
        ]) {
          expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
          final node = tester.getSemantics(find.bySemanticsLabel(label));
          expect(node.flagsCollection.isButton, isTrue, reason: label);
          expect(
            node.flagsCollection.isEnabled,
            label != 'Mark done' ? Tristate.isTrue : Tristate.isFalse,
            reason: label,
          );
          expect(
            tester.getSize(find.bySemanticsLabel(label)).height,
            greaterThanOrEqualTo(32),
          );
        }
        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('Edit'))
              .flagsCollection
              .isFocused,
          Tristate.isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(activations, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isFalse);
        semantics.dispose();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: ViewerUnsavedChangesDialog(
                identity: 'TSK-042',
                title: 'Buttons',
                question: 'Save before leaving?',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final discard = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Discard (Alt+D)'),
        );
        expect(
          discard.style?.foregroundColor?.resolve({}),
          theme.colorScheme.onErrorContainer,
        );
        expect(
          discard.style?.backgroundColor?.resolve({}),
          theme.colorScheme.errorContainer,
        );
        expect(
          contrast(
            theme.colorScheme.onErrorContainer,
            theme.colorScheme.errorContainer,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Cancel (Alt+C)'),
              )
              .autofocus,
          isTrue,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
