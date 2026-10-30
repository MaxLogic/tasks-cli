import 'package:flutter_test/flutter_test.dart';
import 'package:tasks_viewer/controllers/paged_selection.dart';
import 'package:tasks_viewer/data/models.dart';
import 'paged_selection_core_test.dart' as base;

// Expected outcomes follow store membership and user intent, independently of
// the production transition reducer. The product's selection is output only.
void main() {
  for (final saved in [false, true]) {
    test(
      'pinned unknown becomes listed preserving origin saved=$saved',
      () async {
        final f = base.Fixture(count: 300);
        addTearDown(f.close);
        await f.start();
        final project = f.store.projects.first.projectId;
        f.store.mutate(project, 151, status: 'done');
        await f.core.reload(f.spec(), savedId: saved ? 151 : null);
        expect(f.core.selection, isA<Retained<int>>());
        f.core.isSelectionPinned = (_) => true;
        f.store.mutate(project, 151, status: 'todo');
        await f.core.reload(f.spec(query: 'body'));
        expect(f.core.selectedIndex, isNull);
        expect(f.core.selection, isA<Listed<int>>());
        f.core.isSelectionPinned = (_) => false;
        await f.core.reload(f.spec(query: 'no-such-task'));
        expect(f.core.selectedId, saved ? 151 : null);
      },
    );
  }

  test(
    'C6 membership present without materialization still owes saved identity',
    () async {
      final f = base.Fixture(count: 5000);
      addTearDown(f.close);
      await f.start(index: 1500);
      f.store.failure = (_) => base.locked;
      await f.core.reload(f.spec(), savedId: 1501);
      f.store.failure = null;
      await f.core.reload(f.spec(query: 'body'));
      await f.core.reload(
        f.spec(),
      ); // membership is present, no page scan for refilter
      expect(f.core.selectedIndex, isNull);
      await f.core.reload(f.spec(query: 'absent'));
      expect(f.core.selectedId, 1501);
      expect(f.core.retainedText, 'Saved task no longer matches these filters');
      f.core.select(1501, projectSwitch: true);
      await f.core.reload(f.spec(query: 'other-absent'));
      expect(f.core.selectedId, isNull);
    },
  );
  for (final focused in [false, true]) {
    for (final recovery in ['refresh', 'reverse', 'filter']) {
      test('C6 saved origin outranks row focus $focused $recovery', () async {
        final f = base.Fixture(count: 205);
        addTearDown(f.close);
        await f.start();
        f.store.mutate(f.store.projects.first.projectId, 151, status: 'done');
        f.store.failure = (_) => base.locked;
        await f.core.reload(f.spec(), savedId: 151);
        expect(f.core.refreshFailure, isNotNull);
        expect(f.core.selectedId, 151);
        f.core.listFocus = () =>
            ListFocus(ownsFocus: focused, key: 151, index: 150);
        f.store.failure = null;
        await f.core.reload(
          f.spec(
            query: recovery == 'filter' ? 'absent' : '',
            direction: recovery == 'reverse'
                ? SortDirection.descending
                : SortDirection.ascending,
          ),
        );
        expect(f.core.selectedId, 151);
        expect(
          f.core.retainedText,
          'Saved task no longer matches these filters',
        );
        expect(f.core.selectedIndex, isNull);
      });
    }
    for (final recovery in ['paging', 'commit', 'navigation']) {
      test('C6 saved origin discharged by $recovery focus=$focused', () async {
        final f = base.Fixture(count: 300);
        addTearDown(f.close);
        await f.start();
        f.store.failure = (_) => base.locked;
        await f.core.reload(f.spec(), savedId: 151);
        f.store.failure = null;
        await f.core.reload(f.spec(query: 'body'));
        f.core.listFocus = () =>
            ListFocus(ownsFocus: focused, key: 151, index: 150);
        expect(f.core.selectedId, 151);
        expect(f.core.selectedIndex, isNull);
        if (recovery == 'paging') {
          await f.core.ensureRow(150);
        } else if (recovery == 'commit') {
          await f.core.reload(f.spec(query: 'body'));
        } else {
          f.core.select(2);
        }
        // A deliberate change of controls with focus outside the list proves
        // exclusion, after the saved identity has already been resolved.
        f.core.listFocus = () => const ListFocus();
        await f.core.reload(f.spec(query: 'not-present-anywhere'));
        expect(f.core.selectedId, isNull);
        expect(f.core.retainedText, isNull);
      });
    }
  }
}
