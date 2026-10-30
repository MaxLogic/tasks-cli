import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/attachment_controller.dart';
import 'package:tasks_viewer/ui/attachment_dialogs.dart';
import 'package:tasks_viewer/ui/attachment_preview_dialog.dart';
import 'package:tasks_viewer/ui/commands.dart';
import 'package:tasks_viewer/ui/real_workspace.dart';
import '../support/viewer_test_support.dart' as support;
import 'real_cli_attachments_test.dart' as real;
import 'real_cli_attachment_keyboard_test.dart' as keyboard;

void main() {
  test('command activators are unique by key and modifiers in every scope', () {
    final seen = <Object, String>{};
    final duplicates = <String>[];
    for (final spec in commandRegistry) {
      for (final activator in spec.activators) {
        expect(activator, isA<SingleActivator>());
        final a = activator as SingleActivator;
        final key = (
          spec.scope,
          a.trigger.keyId,
          a.control,
          a.alt,
          a.shift,
          a.meta,
        );
        final previous = seen[key];
        if (previous != null) {
          duplicates.add('$previous / ${spec.id}: ${spec.shortcutLabel}');
        }
        seen[key] = spec.id;
      }
    }
    expect(duplicates, isEmpty);
    for (final scope in CommandScope.values.where(isDialogScope)) {
      // Inspect the registry before map construction can coalesce identical
      // const activators from the dialog and its shared bindings.
      final registered = <Object, String>{};
      for (final spec in commandRegistry.where(
        (s) => s.scope == scope || s.scope == CommandScope.dialogs,
      )) {
        for (final activator in spec.activators.cast<SingleActivator>()) {
          final key = (
            activator.trigger.keyId,
            activator.control,
            activator.alt,
            activator.shift,
            activator.meta,
          );
          expect(
            registered[key],
            isNull,
            reason:
                '$scope shared-dialog collision: ${registered[key]} / ${spec.id}',
          );
          registered[key] = spec.id;
        }
      }
      final combined = <Object, String>{};
      for (final entry in shortcutMapForScope(scope).entries) {
        final a = entry.key as SingleActivator;
        final key = (a.trigger.keyId, a.control, a.alt, a.shift, a.meta);
        expect(
          combined[key],
          isNull,
          reason:
              '$scope shared-dialog collision: ${combined[key]} / ${entry.value}',
        );
        combined[key] = (entry.value as CommandIntent).id;
      }
    }
  });

  testWidgets(
    'real empty attachment clipboard falls through to Tasks text search',
    (tester) async {
      if (!real.available(real.clipboardCli)) return;
      final h = (await tester.runAsync(
        () => real.Harness.start(clipboard: true),
      ))!;
      final text = File('${h.clipboardFixture!.path}/text.txt')
        ..writeAsStringSync('Real attachment');
      await keyboard.mount(tester, h, clipboardText: text.readAsStringSync());
      final model = tester
          .widget<ViewerWorkspaceScope>(find.byType(ViewerWorkspaceScope))
          .model;
      await support.pressKey(tester, LogicalKeyboardKey.f2);
      await tester.runAsync(
        () => support.pressControl(tester, LogicalKeyboardKey.keyV),
      );
      await real.waitFor(tester, () => model.tasks!.query == 'Real attachment');
      expect(model.tasks!.query, 'Real attachment');
      expect(find.byType(AttachmentConfirmationDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Tasks list paste explains why editing blocks attachments', (
    tester,
  ) async {
    if (!real.available(real.clipboardCli)) return;
    final h = (await tester.runAsync(
      () => real.Harness.start(clipboard: true),
    ))!;
    final announcements = await keyboard.mount(tester, h);
    await support.pressKey(tester, LogicalKeyboardKey.f4);
    await support.pressKey(tester, LogicalKeyboardKey.f2);
    await tester.runAsync(
      () => support.pressControl(tester, LogicalKeyboardKey.keyV),
    );
    await tester.pumpAndSettle();
    expect(announcements.liveRegionText, 'Save or cancel your edits first');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'real refresh clamps attachment selection and View uses the highlighted row',
    (tester) async {
      if (!real.available(real.cli)) return;
      final h = (await tester.runAsync(real.Harness.start))!;
      final first = File('${h.root.path}/first.log')
        ..writeAsStringSync('first content');
      final last = File('${h.root.path}/last.log')
        ..writeAsStringSync('last content');
      h.dialogs.files = [first.path, last.path];
      await tester.runAsync(h.controller.addFiles);
      Widget panel() => MaterialApp(
        home: Scaffold(body: AttachmentPanel(controller: h.controller)),
      );
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();
      final state = tester.state<AttachmentPanelState>(
        find.byType(AttachmentPanel),
      );
      state.list.selectIndex(1);
      await tester.pumpAndSettle();
      final removed = state.item!;
      await tester.runAsync(() async {
        await h.command([
          'attachment',
          'detach',
          '${h.id}',
          removed.displayId,
          '--expect-version',
          '${h.detail.version}',
        ]);
        await h.refresh();
      });
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();
      expect(state.list.selectedIndex, 0);
      await tester.runAsync(() async {
        unawaited(state.view());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await real.waitFor(
        tester,
        () =>
            find.byType(AttachmentPreviewDialog).evaluate().isNotEmpty &&
            find.byType(TextField).evaluate().isNotEmpty &&
            tester
                .widget<TextField>(find.byType(TextField))
                .controller!
                .text
                .isNotEmpty,
        realAsyncPump: true,
      );
      expect(
        state.item?.id,
        h.detail.attachments.single.id,
        reason:
            'A highlighted row must remain actionable after the list clamps selection',
      );
      expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'real materialize exposes progress and every blocked View/Save reports a reason',
    () async {
      if (!real.available(real.cli)) return;
      final h = await real.Harness.start();
      final file = File('${h.root.path}/progress.log')
        ..writeAsStringSync('progress');
      h.dialogs.files = [file.path];
      await h.controller.addFiles();
      final item = h.detail.attachments.single;
      final pending = h.controller.materialize(item);
      expect(h.controller.busy, isTrue);
      expect(h.controller.notice, contains('Opening'));
      expect(await pending, isNotNull);
      expect(h.controller.busy, isFalse);
    },
  );

  test(
    'blocked materialize and save replace stale notices with a reason',
    () async {
      if (!real.available(real.cli)) return;
      final h = await real.Harness.start();
      final file = File('${h.root.path}/blocked.log')
        ..writeAsStringSync('blocked');
      h.dialogs.files = [file.path];
      await h.controller.addFiles();
      final item = h.detail.attachments.single;
      for (final editing in [true, false]) {
        h.controller.editing = editing;
        h.controller.busy = !editing;
        h.controller.notice = 'stale success';
        await h.controller.saveAs(item);
        expect(
          h.controller.notice,
          editing ? 'Save or cancel your edits first' : contains('in progress'),
        );
        h.controller.notice = 'stale success';
        expect(await h.controller.materialize(item), isNull);
        expect(
          h.controller.notice,
          editing ? 'Save or cancel your edits first' : contains('in progress'),
        );
      }
      h.controller.busy = false;
    },
  );

  test(
    'task changing during real materialize reports why no preview is opened',
    () async {
      if (!real.available(real.cli)) return;
      final h = await real.Harness.start();
      final file = File('${h.root.path}/stale.log')..writeAsStringSync('stale');
      h.dialogs.files = [file.path];
      await h.controller.addFiles();
      var current = true;
      final controller = AttachmentController(
        client: h.client,
        projectId: h.project,
        task: h.detail,
        refresh: h.refresh,
        announce: (_) {},
        dialogs: h.dialogs,
        isCurrent: () => current,
      );
      addTearDown(controller.dispose);
      final pending = controller.materialize(h.detail.attachments.single);
      current = false;
      expect(await pending, isNull);
      expect(controller.notice, contains('selected task changed'));
      controller.notice = 'stale success';
      await controller.saveAs(h.detail.attachments.single);
      expect(controller.notice, contains('selected task changed'));
    },
  );

  for (final outcome in [
    'Saved file.log',
    'Save cancelled',
    'Could not save file.log',
  ]) {
    testWidgets('preview retains Save focus after $outcome', (tester) async {
      if (!real.available(real.cli)) return;
      final h = (await tester.runAsync(real.Harness.start))!;
      final file = File('${h.root.path}/file.log')
        ..writeAsStringSync('preview');
      h.dialogs.files = [file.path];
      await tester.runAsync(h.controller.addFiles);
      final item = h.detail.attachments.single;
      final done = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentPreviewDialog(
            item: item,
            path: file.path,
            announce: (_) {},
            onSaveAs: () => done.future,
            saveNotice: () => outcome,
          ),
        ),
      );
      await real.waitFor(
        tester,
        () => find.text('preview').evaluate().isNotEmpty,
      );
      final focus = Focus.of(tester.element(find.text('Save as (Alt+S)')));
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      done.complete();
      await tester.pumpAndSettle();
      expect(
        focus.hasFocus,
        isTrue,
        reason: 'Save must retain its keyboard position',
      );
      expect(find.text(outcome), findsOneWidget);
      expect(
        find.text(
          outcome.startsWith('Saved ')
              ? 'Success'
              : outcome == 'Save cancelled'
              ? 'Cancelled'
              : 'Error',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
