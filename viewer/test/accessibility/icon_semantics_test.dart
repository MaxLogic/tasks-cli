// Material glyphs are decorative; audit the actual rendered action surfaces.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/editor_controller.dart';
import 'package:tasks_viewer/data/editor_models.dart';
import 'package:tasks_viewer/data/models.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import 'package:tasks_viewer/ui/editor_dialogs.dart';
import 'package:tasks_viewer/ui/viewer_icons.dart';
import 'package:tasks_viewer/ui/settings_dialog.dart';
import '../attachments/attachment_contract_test.dart' as att;
import '../details/details_pane_test.dart' show pumpTaskDetails;
import '../helpers/semantics_audit.dart';
import '../support/viewer_test_support.dart';

void auditIcons(WidgetTester tester) {
  final buttons = find.byWidgetPredicate(
    (w) => w is ButtonStyleButton && w is! IconButton,
  );
  expect(buttons, findsWidgets);
  for (final element in buttons.evaluate()) {
    final button = find.byElementPredicate((e) => identical(e, element));
    if (find
        .ancestor(of: button, matching: find.byType(IconButton))
        .evaluate()
        .isNotEmpty) {
      continue;
    }
    if (find
        .ancestor(
          of: button,
          matching: find.byWidgetPredicate((w) => w is SegmentedButton),
        )
        .evaluate()
        .isNotEmpty) {
      continue;
    }
    final texts = tester.widgetList<Text>(
      find.descendant(of: button, matching: find.byType(Text)),
    );
    final label = texts.map((w) => w.data ?? w.textSpan!.toPlainText()).join();
    final icons = tester
        .widgetList<Icon>(
          find.descendant(of: button, matching: find.byType(Icon)),
        )
        .toList();
    expect(icons, hasLength(1), reason: '$label has one leading glyph');
    expect(icons.single.semanticLabel, isNull, reason: label);
    // Read the platform-facing data: merged controls can keep their label on
    // a child while the parent contributes the target-file hint.
    final name = tester.getSemantics(button).getSemanticsData().label;
    final explicit = tester
        .widgetList<Semantics>(
          find.descendant(of: button, matching: find.byType(Semantics)),
        )
        .map((w) => w.properties.label)
        .whereType<String>()
        .toList();
    expect(
      name,
      explicit.isNotEmpty ? explicit.first : label,
      reason: 'unchanged name: $label',
    );
  }
  for (final element in find.byType(IconButton).evaluate()) {
    final button = find.byElementPredicate((e) => identical(e, element));
    final icons = tester
        .widgetList<Icon>(
          find.descendant(of: button, matching: find.byType(Icon)),
        )
        .toList();
    expect(icons, hasLength(1));
    expect(icons.single.semanticLabel, isNotEmpty);
    final tooltip = find.ancestor(of: button, matching: find.byType(Tooltip));
    expect(tooltip, findsWidgets);
    expect(tester.widget<Tooltip>(tooltip.first).excludeFromSemantics, isTrue);
  }
  for (final node in visibleSemanticsNodes(tester)) {
    expect(
      RegExp(r'[\uE000-\uF8FF]').hasMatch(node.label),
      isFalse,
      reason: node.label,
    );
  }
}

void main() {
  testWidgets(
    'workspace, tabs, editor, Settings and Help keep label-only names',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpTaskDetails(tester);
        auditIcons(tester);
        final markDone = find.widgetWithText(TextButton, 'Mark done');
        expect(
          find.descendant(
            of: markDone,
            matching: find.byIcon(ViewerIcons.markDone),
          ),
          findsOneWidget,
        );
        final filtersFocus = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Filters'))
            .focusNode;
        await tester.tap(find.byTooltip('Show filters (Alt+F)'));
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.widgetWithText(TextButton, 'Hide filters'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Filters'), findsNothing);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Hide filters'),
              )
              .focusNode,
          same(filtersFocus),
        );
        auditIcons(tester);
        await tester.pumpAndSettle();
        for (final key in [
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit1,
        ]) {
          await pressAlt(tester, key);
          auditIcons(tester);
        }
        await pressKey(tester, LogicalKeyboardKey.f4);
        auditIcons(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel (Alt+C)'));
        await tester.pumpAndSettle();
        await pressControl(tester, LogicalKeyboardKey.comma);
        final scrollable = find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        for (double y = 0; ; y += position.viewportDimension / 2) {
          position.jumpTo(y.clamp(0, position.maxScrollExtent));
          await tester.pumpAndSettle();
          // Offscreen form buttons have no semantic rect, so audit visible names separately.
          for (final icon in tester.widgetList<Icon>(
            find.descendant(
              of: find.byType(SettingsDialog),
              matching: find.byType(Icon),
            ),
          )) {
            expect(icon.semanticLabel, isNull);
          }
          for (final node in visibleSemanticsNodes(tester)) {
            expect(RegExp(r'[\uE000-\uF8FF]').hasMatch(node.label), isFalse);
          }
          if (y >= position.maxScrollExtent) break;
        }
        await pressKey(tester, LogicalKeyboardKey.escape);
        await pressKey(tester, LogicalKeyboardKey.f10);
        auditIcons(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  final conflict = EditorConflict(
    baseVersion: 1,
    baseFields: TaskEditFields.fromDetail(testTaskDetail(1, title: 'Base')),
    draftFields: TaskEditFields.fromDetail(testTaskDetail(1, title: 'Mine')),
    current: testTaskDetail(1, title: 'Current', version: 2),
    changedFields: const [EditorField.title],
    conflictFields: const [EditorField.title],
  );
  final dialogs = <String, Widget>{
    'unsaved': const ViewerUnsavedChangesDialog(
      identity: 'T-001',
      title: 'Fixture',
      question: 'Save before leaving?',
    ),
    'dirty done': const ViewerMarkDoneDirtyDialog(
      identity: 'T-001',
      title: 'Fixture',
    ),
    'conflict': ViewerConflictDialog(conflict: conflict),
    'review': ViewerConflictReviewDialog(conflict: conflict),
    'restore': const ViewerRestoreDraftDialog(
      identity: 'T-001',
      title: 'Fixture',
      baseVersion: 1,
      currentVersion: 2,
    ),
    'slow save': const ViewerSlowSaveCloseDialog(identity: 'T-001'),
    'attach': const AttachmentConfirmationDialog(
      title: 'Attach',
      content: 'Fixture',
      accept: 'Attach (Alt+A)',
    ),
    'detach': const AttachmentConfirmationDialog(
      title: 'Detach',
      content: 'Fixture',
      accept: 'Detach (Alt+D)',
      cancelDefault: true,
      acceptIcon: ViewerIcons.detach,
    ),
    'attachment conflict': AttachmentOnlyConflictDialog(conflict: conflict),
  };
  for (final entry in dialogs.entries) {
    testWidgets('${entry.key} dialog uses decorative action icons', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: entry.value)));
        await tester.pumpAndSettle();
        auditIcons(tester);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final kind in ['text', 'image', 'binary', 'panel']) {
    testWidgets('attachment $kind names exclude decorative glyphs', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final root = Directory.systemTemp.createTempSync('icon-surfaces-');
        addTearDown(() => root.deleteSync(recursive: true));
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rig = att.Rig(root);
        addTearDown(rig.controller.dispose);
        await tester.runAsync(rig.probe);
        final file = File('${root.path}/preview');
        file.writeAsBytesSync(
          kind == 'image'
              ? base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
                )
              : utf8.encode('Synthetic text\n'),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: kind == 'panel'
                  ? AttachmentPanel(controller: rig.controller)
                  : AttachmentPreviewDialog(
                      item: AttachmentSummary.fromJson({
                        ...att.metadata,
                        'kind': kind,
                        'media_type': kind == 'image'
                            ? 'image/png'
                            : 'text/plain',
                        'original_size': file.lengthSync(),
                      }),
                      path: file.path,
                      announce: (_) {},
                      onSaveAs: () async {},
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await att.settleFileIo(tester);
        auditIcons(tester);
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      } finally {
        semantics.dispose();
      }
    });
  }
}
