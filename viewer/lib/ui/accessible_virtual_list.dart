/// A virtualized list (single-selection by default) that stays keyboard- and
/// screen-reader-operable, including rows that are not built yet.
///
/// Contract: viewer/spec.md sections 5 and 9, viewer/design.md section 6.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'viewer_motion.dart';

/// What a screen reader says for one row: the identifying content once, plus an
/// optional non-duplicating position label.
class AccessibleRowSemantics {
  const AccessibleRowSemantics({required this.label, this.value});

  final String label;
  final String? value;
}

/// A user selection gesture worth announcing, separate from ordinary row focus
/// speech and silent programmatic selection (for example after a detach).
class VirtualListSelectionChange {
  const VirtualListSelectionChange(this.indices, {this.toggledIndex});
  final Set<int> indices;
  final int? toggledIndex;
}

/// Imperative handle used by region shortcut handlers (F1/F2), End
/// and post-save selection retention.
class VirtualListController extends ChangeNotifier {
  _AccessibleVirtualListState? _state;

  bool get isAttached => _state != null;

  int? get selectedIndex => _state?._selectedIndex;

  /// Selected row indices. In multi-select mode [selectedIndex] is the
  /// focus/activation row and may itself be unselected (Ctrl+click/Space).
  Set<int> get selectedIndices => _state?._selection ?? const <int>{};

  int? get forwardedIndex => _state?._forwardIndex;

  int? get pendingTargetIndex => _state?._pendingIndex;

  bool get hasPendingTarget => _state?._pendingIndex != null;

  bool get hasFocus => _state?._listHasFocus ?? false;

  /// Index of the row that currently owns keyboard focus, if any.
  int? get focusedRowIndex => _state?.focusedRowIndex;

  /// Focus the region: its selected row, or the first row when nothing is
  /// selected yet, or the list container when the list is empty.
  void focusRegion() => _state?._focusRegion();

  /// Move selection and focus to [index] (End or a programmatic jump).
  void goToIndex(int index) => _state?._requestIndex(index, moveFocus: true);

  /// Change the selection without moving keyboard focus.
  void selectIndex(int? index) =>
      _state?._setSelectedIndex(index, notify: true);

  /// Returns the highlight to [restoreIndex] after the owner refused a move
  /// to [refusedIndex] (spec.md section 7).
  ///
  /// The dialog that asked the question hands keyboard focus back to the row
  /// it was opened from. That focus return is a restoration, not a fresh user
  /// move, so it must not re-run the guard: the next focus change is consumed
  /// once and, when it lands on the refused row, focus is pulled back to the
  /// row the owner still has open.
  void refuseMove(int refusedIndex, int restoreIndex) =>
      _state?._refuseMove(refusedIndex, restoreIndex);

  /// Called by the owner when data for the pending target row arrived.
  void retryPending() => _state?._settleFocus();

  /// True while the list container or one of its rendered rows has focus.
  ///
  /// Commands that belong to "the list itself" (for example Ctrl+E on the
  /// Projects list) must not fire from a sibling filter field, so they ask the
  /// controller instead of guessing from the active region.
  bool get hasListFocus => _state?._listHasFocus ?? false;

  void _attach(_AccessibleVirtualListState state) {
    _state = state;
  }

  void _detach(_AccessibleVirtualListState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

/// Builds the visual content of one row.
typedef VirtualRowBuilder =
    Widget Function(BuildContext context, int index, bool selected);

@immutable
class ListMotionKey {
  const ListMotionKey({required this.scope, required this.epoch});
  final Object scope;
  final Object epoch;
}

/// A virtualized, keyboard-navigable, screen-reader-friendly list.
class AccessibleVirtualList extends StatefulWidget {
  const AccessibleVirtualList({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemExtent,
    required this.listLabel,
    required this.emptyLabel,
    required this.rowBuilder,
    required this.rowSemanticsBuilder,
    required this.itemKeyBuilder,
    this.onActivate,
    this.activateOnDoubleTap = false,
    this.onSelectedIndexChanged,
    this.excludeRowChildSemantics = true,
    this.isRowReady,
    this.onPendingRowSlow,
    this.cacheExtent,
    this.onFocusChange,
    this.emptyAction,
    this.motionKey,
    this.emptyIsTransient = false,
    this.multiSelect = false,
    this.onSelectionChanged,
  });

  final VirtualListController controller;
  final int itemCount;
  final double itemExtent;

  /// Accessible name of the list region, for example `Projects`.
  final String listLabel;

  /// Accessible message shown when the list has no rows.
  final String emptyLabel;

  final VirtualRowBuilder rowBuilder;

  /// Semantics for one row; called only for rendered rows.
  final AccessibleRowSemantics Function(int index) rowSemanticsBuilder;

  /// Stable per-item key (project UUID or canonical task ID).
  final Key Function(int index) itemKeyBuilder;

  /// Enter/Space on the selected row.
  final ValueChanged<int>? onActivate;

  /// Select the clicked row before using the same activation as Enter/Space.
  final bool activateOnDoubleTap;

  final ValueChanged<int>? onSelectedIndexChanged;

  /// Opt-in Windows selection gestures. Other lists retain their original
  /// focus-is-selection contract, including Ctrl+Space activation.
  final bool multiSelect;

  /// User selection changes requiring speech. Ordinary single-row moves and
  /// programmatic selection/focus restoration never call this callback.
  final ValueChanged<VirtualListSelectionChange>? onSelectionChanged;

  /// Allow embedded row actions to remain independently accessible.
  final bool excludeRowChildSemantics;

  /// False while the row exists only as a placeholder. Focus waits for the real
  /// row instead of landing on invented content.
  final bool Function(int index)? isRowReady;

  /// Called once when a pending jump has waited longer than the load
  /// announcement threshold (500 ms).
  final ValueChanged<int>? onPendingRowSlow;

  final double? cacheExtent;

  final ValueChanged<bool>? onFocusChange;

  /// Optional control under the empty message, for example Clear filters.
  /// It is the next Tab stop after the empty list and keeps its own
  /// accessible name.
  final Widget? emptyAction;
  final ListMotionKey? motionKey;
  final bool emptyIsTransient;

  @override
  State<AccessibleVirtualList> createState() => _AccessibleVirtualListState();
}

class _AccessibleVirtualListState extends State<AccessibleVirtualList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 292),
  );
  final Map<Key, _VirtualRowState> _mountedRows = {};
  Map<Key, double>? _pendingSnapshot;
  Duration? _snapshotAt;
  Map<Key, double>? _playSnapshot;
  int _motionGeneration = 0;
  bool _motionEnabled = false;
  double _snapshotViewport = 0;
  int _snapshotFirstIndex = 0;
  int _snapshotLastIndex = 0;
  bool _fadeReorder = false;

  // Compare only the previously mounted window. A dense crossing (notably a
  // reversal) is more legible as staggered entry at the final row positions.
  bool _mostlyCrossing(Map<Key, double> snapshot) {
    final first = _snapshotFirstIndex;
    final last = math.min(_snapshotLastIndex, widget.itemCount - 1);
    if (last - first >= 80) return true;
    final positions = <double>[];
    for (var i = first; i <= last; i++) {
      final oldY = snapshot[widget.itemKeyBuilder(i)];
      if (oldY != null) positions.add(oldY);
    }
    final crossing = <int>{};
    for (var i = 0; i < positions.length; i++) {
      for (var j = i + 1; j < positions.length; j++) {
        if (positions[i] > positions[j]) {
          crossing.addAll([i, j]);
        }
      }
    }
    return crossing.length > positions.length / 2;
  }

  void _finishMotion() {
    if (_motion.value != 1) _motion.value = 1;
  }

  void _captureMotion() {
    if (_mountedRows.isEmpty ||
        _mountedRows.length > 80 ||
        _pendingIndex != null ||
        !_scroll.hasClients) {
      return;
    }
    if (_mountedRows.values.any((row) => !row.widget.ready)) return;
    final offset = _scroll.offset;
    _pendingSnapshot = {
      for (final entry in _mountedRows.entries)
        entry.key: entry.value.widget.index * widget.itemExtent - offset,
    };
    _snapshotAt = SchedulerBinding.instance.currentFrameTimeStamp;
    _snapshotViewport = _scroll.position.viewportDimension;
    final indices = _mountedRows.values.map((row) => row.widget.index);
    _snapshotFirstIndex = indices.reduce(math.min);
    _snapshotLastIndex = indices.reduce(math.max);
  }

  void _updateMotion(AccessibleVirtualList oldWidget) {
    final before = oldWidget.motionKey;
    final after = widget.motionKey;
    final changed = before?.epoch != after?.epoch;
    if (!_motionEnabled ||
        before == null ||
        after == null ||
        before.scope != after.scope ||
        _pendingIndex != null ||
        _mountedRows.length > 80) {
      _finishMotion();
      _pendingSnapshot = null;
      _playSnapshot = null;
      return;
    }
    if (changed) _finishMotion();
    if (oldWidget.itemCount > 0 && widget.itemCount == 0) _captureMotion();
    if (!changed || widget.itemCount == 0) return;
    if (_pendingSnapshot == null) _captureMotion();
    final snapshot = _pendingSnapshot;
    final age = _snapshotAt == null
        ? null
        : SchedulerBinding.instance.currentFrameTimeStamp - _snapshotAt!;
    _pendingSnapshot = null;
    if (snapshot == null || age == null || age > const Duration(seconds: 1)) {
      return;
    }
    _playSnapshot = snapshot;
    _fadeReorder = _mostlyCrossing(snapshot);
    final generation = ++_motionGeneration;
    _motion.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _motionGeneration) _playSnapshot = null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled = ViewerMotion.enabled(context);
    if (!_motionEnabled) {
      _finishMotion();
      _pendingSnapshot = null;
      _playSnapshot = null;
    }
  }

  static const Duration _slowRowThreshold = Duration(milliseconds: 500);

  final ScrollController _scroll = ScrollController();
  final FocusNode _containerFocus = FocusNode(
    debugLabel: 'list-region',
    skipTraversal: false,
  );
  final Map<int, FocusNode> _rowNodes = <int, FocusNode>{};

  int? _selectedIndex;
  Set<int> _selectedIndices = {};
  Set<Key> _selectedKeys = {};
  Key? _leadKey;
  Key? _anchorKey;
  int? _rangeAnchor;

  Set<int> get _selection => Set.unmodifiable(
    widget.multiSelect ? _selectedIndices : {?_selectedIndex},
  );

  bool _isSelected(int index) => widget.multiSelect
      ? _selectedIndices.contains(index)
      : index == _selectedIndex;

  /// Row the owner refused to move to; the next focus change is the dialog's
  /// restoration, which must not be reported as a fresh move.
  int? _refusedFocusIndex;
  int? _notifiedIndex;
  int? _pendingIndex;
  bool _pendingReveal = true;
  int? _forwardIndex;
  int _focusAttempts = 0;
  bool _pendingFocusIntent = false;
  Timer? _slowRowTimer;
  bool _containerFocused = false;

  @override
  void initState() {
    super.initState();
    _motion.value = 1;
    widget.controller._attach(this);
    _syncSelectionWithItemCount();
  }

  @override
  void didUpdateWidget(covariant AccessibleVirtualList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
    _syncSelectionWithItemCount();
    if (widget.multiSelect) {
      if (oldWidget.multiSelect) {
        final indices = <int>{};
        int? lead;
        int? anchor;
        for (var i = 0; i < widget.itemCount; i++) {
          final key = widget.itemKeyBuilder(i);
          if (_selectedKeys.contains(key)) indices.add(i);
          if (key == _leadKey) lead = i;
          if (key == _anchorKey) anchor = i;
        }
        _selectedIndices = indices;
        _selectedIndex = lead ?? _selectedIndex;
        _rangeAnchor = anchor ?? _selectedIndex;
      } else {
        _selectedIndices = {?_selectedIndex};
      }
      _rememberSelection();
    }
    if (oldWidget.itemCount != widget.itemCount) {
      // The rows changed under the selection, so whatever the owner was last
      // told describes a different list; let the next row focus speak again.
      _notifiedIndex = null;
    }
    final pending = _pendingIndex;
    if (pending != null && pending >= widget.itemCount) {
      _pendingIndex = null;
      _pendingFocusIntent = false;
      _cancelSlowTimer();
    }
  }

  @override
  void dispose() {
    _cancelSlowTimer();
    _motion.dispose();
    widget.controller._detach(this);
    _containerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncSelectionWithItemCount() {
    if (widget.itemCount == 0) {
      _selectedIndex = null;
      _selectedIndices = {};
      return;
    }
    final selected = _selectedIndex;
    if (selected == null || selected >= widget.itemCount) {
      _selectedIndex = math.min(selected ?? 0, widget.itemCount - 1);
    }
    if (widget.multiSelect && _leadKey == null) {
      _selectedIndices = {_selectedIndex!};
      _rangeAnchor = _selectedIndex;
      _rememberSelection();
    }
  }

  void _rememberSelection() {
    _selectedKeys = {
      for (final i in _selectedIndices) widget.itemKeyBuilder(i),
    };
    _leadKey = _selectedIndex == null
        ? null
        : widget.itemKeyBuilder(_selectedIndex!);
    final anchor = _rangeAnchor;
    _anchorKey = anchor != null && anchor < widget.itemCount
        ? widget.itemKeyBuilder(anchor)
        : null;
  }

  bool get _listHasFocus =>
      _containerFocus.hasFocus || _rowNodes.values.any((node) => node.hasFocus);

  int? get focusedRowIndex {
    for (final entry in _rowNodes.entries) {
      if (entry.value.hasFocus) {
        return entry.key;
      }
    }
    return null;
  }

  /// Keeps the container's `focused` semantics flag describing the container
  /// alone.
  ///
  /// `hasFocus` is ancestor-inclusive: the container reports it while a row
  /// holds the focus, and a row reports it while one of *its* descendants does.
  /// The platform builds the element it reports as focused from these flags, so
  /// a container that keeps advertising focus after a row took it leaves two
  /// nodes claiming the same focus and hands the region to the screen reader
  /// instead of the row (viewer/design.md section 9).
  void _syncContainerFocusFlag() {
    final focused = _containerFocus.hasPrimaryFocus;
    if (focused == _containerFocused) {
      return;
    }
    setState(() => _containerFocused = focused);
  }

  // --------------------------------------------------------------- selection

  void _focusRegion() {
    if (widget.itemCount == 0) {
      _containerFocus.requestFocus();
      return;
    }
    final index = _selectedIndex ?? 0;
    if (_selectedIndex == null) {
      _setSelectedIndex(index, notify: true);
    }
    final node = _rowNodes[index];
    if (node != null && (widget.isRowReady?.call(index) ?? true)) {
      node.requestFocus();
      return;
    }
    _requestIndex(
      index,
      moveFocus: true,
      forceFocus: true,
      preserveSelection: widget.multiSelect,
    );
  }

  void _setSelectedIndex(int? index, {required bool notify}) {
    if (index != null && widget.itemCount > 0) {
      index = index.clamp(0, widget.itemCount - 1);
    } else {
      index = null;
    }
    if (widget.multiSelect) {
      _changeMultiSelection(index, notify: notify);
      return;
    }
    if (index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
    if (notify && index != null) {
      _notifiedIndex = index;
      widget.onSelectedIndexChanged?.call(index);
    }
  }

  void _changeMultiSelection(
    int? index, {
    bool extend = false,
    bool toggle = false,
    bool preserve = false,
    bool additive = false,
    bool userInitiated = false,
    required bool notify,
  }) {
    final before = _selection;
    final previous = _selectedIndex;
    setState(() {
      if (index == null) {
        _selectedIndices = {};
        _rangeAnchor = null;
      } else if (extend) {
        final anchor = (_rangeAnchor ?? previous ?? index).clamp(
          0,
          widget.itemCount - 1,
        );
        _rangeAnchor = anchor;
        _selectedIndices = {
          if (additive) ..._selectedIndices,
          for (
            var i = math.min(anchor, index);
            i <= math.max(anchor, index);
            i++
          )
            i,
        };
      } else if (toggle) {
        _selectedIndices = {..._selectedIndices};
        if (!_selectedIndices.add(index)) _selectedIndices.remove(index);
        _rangeAnchor = index;
      } else if (!preserve) {
        _selectedIndices = {index};
        _rangeAnchor = index;
      }
      _selectedIndex = index;
      _rememberSelection();
    });
    if (notify && index != null && previous != index) {
      _notifiedIndex = index;
      widget.onSelectedIndexChanged?.call(index);
    }
    if (notify &&
        userInitiated &&
        !setEquals(before, _selectedIndices) &&
        (extend ||
            toggle ||
            before.length > 1 ||
            _selectedIndices.length > 1)) {
      widget.onSelectionChanged?.call(
        VirtualListSelectionChange(
          _selection,
          toggledIndex: toggle ? index : null,
        ),
      );
    }
  }

  void _pointerSelect(int index) => _requestIndex(
    index,
    moveFocus: true,
    forceFocus: true,
    reveal: false,
    userInitiated: true,
    additive: widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
    extend: widget.multiSelect && HardwareKeyboard.instance.isShiftPressed,
    toggle:
        widget.multiSelect &&
        !HardwareKeyboard.instance.isShiftPressed &&
        HardwareKeyboard.instance.isControlPressed,
  );

  void _requestIndex(
    int index, {
    required bool moveFocus,
    bool forceFocus = false,
    bool reveal = true,
    bool extend = false,
    bool toggle = false,
    bool preserveSelection = false,
    bool additive = false,
    bool userInitiated = false,
  }) {
    if (widget.itemCount == 0) {
      return;
    }
    _refusedFocusIndex = null;
    _finishMotion();
    _pendingSnapshot = null;
    final target = index.clamp(0, widget.itemCount - 1);
    if (widget.multiSelect) {
      _changeMultiSelection(
        target,
        extend: extend,
        toggle: toggle,
        preserve: preserveSelection,
        additive: additive,
        userInitiated: userInitiated,
        notify: true,
      );
    } else {
      _setSelectedIndex(target, notify: true);
    }
    if (!moveFocus) {
      return;
    }
    _pendingIndex = target;
    _pendingReveal = reveal;
    // Scrolling to the target disposes the row that owned focus, so by the
    // time the target row exists nothing in the list is focused any more.
    // Remember that this move was deliberate instead of mistaking the gap for
    // "the user focused something else" and forwarding the focus.
    _pendingFocusIntent =
        forceFocus || _listHasFocus || _containerFocus.hasFocus;
    _focusAttempts = 0;
    if (reveal) _scrollToIndex(target);
    _settleFocus();
    if (_pendingIndex != null && !_containerFocus.hasFocus) {
      // design.md section 6: during an unloaded jump the focus stays in the
      // list region with a pending target instead of falling to the window.
      _containerFocus.requestFocus();
    }
  }

  /// Puts the selection back on [restoreIndex] after the owner refused the
  /// move to [refusedIndex]; the dialog's focus restoration is consumed by
  /// [_onRowFocusGained] instead of looking like a fresh move.
  void _refuseMove(int refusedIndex, int restoreIndex) {
    if (widget.itemCount == 0) {
      return;
    }
    _refusedFocusIndex = refusedIndex.clamp(0, widget.itemCount - 1);
    // The refused move is no longer a pending jump to that row.
    _pendingIndex = null;
    _pendingFocusIntent = false;
    _cancelSlowTimer();
    _setSelectedIndex(restoreIndex, notify: true);
  }

  void _moveSelection(int delta) {
    if (widget.itemCount == 0) {
      return;
    }
    final current = _selectedIndex ?? 0;
    final target = widget.multiSelect
        ? (current + delta).clamp(0, widget.itemCount - 1)
        : current + delta;
    if (target < 0 || target >= widget.itemCount) {
      return; // Stay in place at a boundary without repeated speech.
    }
    _requestIndex(
      target,
      moveFocus: true,
      extend: widget.multiSelect && HardwareKeyboard.instance.isShiftPressed,
      additive:
          widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
      userInitiated: true,
      preserveSelection:
          widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
    );
  }

  int _pageRows() {
    final extent = widget.itemExtent;
    if (extent <= 0 ||
        !_scroll.hasClients ||
        !_scroll.position.hasContentDimensions) {
      return 10;
    }
    final rows = (_scroll.position.viewportDimension / extent).floor();
    return math.max(1, rows - 1);
  }

  void _scrollToIndex(int index) {
    // A pane the layout hid was never laid out, so its position has no
    // dimensions yet; the reveal produces them and the retry scrolls again.
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
      return;
    }
    final position = _scroll.position;
    final extent = widget.itemExtent;
    final rowTop = index * extent;
    final rowBottom = rowTop + extent;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    if (rowTop >= viewTop && rowBottom <= viewBottom) return;
    final target = rowTop < viewTop
        ? rowTop
        : rowBottom - position.viewportDimension;
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - clamped).abs() < 0.5) {
      return;
    }
    _scroll.jumpTo(clamped);
  }

  // ------------------------------------------------------------ focus settle

  void _settleFocus() {
    if (!mounted) {
      return;
    }
    final target = _pendingIndex;
    if (target == null) {
      _cancelSlowTimer();
      return;
    }
    if (target >= widget.itemCount) {
      _pendingIndex = null;
      _pendingFocusIntent = false;
      _cancelSlowTimer();
      return;
    }
    final ready = widget.isRowReady?.call(target) ?? true;
    if (ready) {
      final node = _rowNodes[target];
      if (node != null) {
        _pendingIndex = null;
        // Take the focus when the move was deliberate, when the list already
        // owned it, or when nothing else does (the previous row was disposed
        // mid-jump). Only a real move to another control forwards instead.
        final takeFocus =
            _pendingFocusIntent ||
            _listHasFocus ||
            _containerFocus.hasFocus ||
            FocusManager.instance.primaryFocus == null;
        _pendingFocusIntent = false;
        _cancelSlowTimer();
        if (takeFocus) {
          node.requestFocus();
          _confirmRowFocus(target, node);
        } else {
          _focusAttempts = 0;
          // Focus moved elsewhere while the row was loading: do not steal it.
          _forwardIndex = target;
        }
        return;
      }
      if (_focusAttempts < 20) {
        _focusAttempts++;
        // Once the pane has a viewport, scroll to the row that is still
        // waiting for focus.
        if (_pendingReveal) _scrollToIndex(target);
        // The row is built by the next layout pass, so make sure one happens
        // even when nothing else changed this frame.
        SchedulerBinding.instance.scheduleFrame();
        WidgetsBinding.instance.addPostFrameCallback((_) => _settleFocus());
        return;
      }
    }
    _startSlowTimer(target);
  }

  /// Confirms one frame later that a completed jump really took focus.
  ///
  /// A jump can settle in the same frame that swaps a placeholder row for the
  /// loaded row. That rebuild keys the row differently, so it disposes the node
  /// the request targeted; the request lands nowhere and the list would be left
  /// unfocused with nothing pending. Re-arm the jump against the rebuilt row
  /// instead (viewer/design.md section 6: rows that are not built yet must
  /// still be reachable). Retrying is bounded, and a row that survived without
  /// taking focus is left alone because another control holds it on purpose.
  void _confirmRowFocus(int target, FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingIndex != null) {
        return; // A newer jump owns the pending state.
      }
      final current = _rowNodes[target];
      if (node.hasFocus || (current?.hasFocus ?? false)) {
        _focusAttempts = 0;
        return;
      }
      if (identical(current, node)) {
        return; // The row survived, so another control kept the focus.
      }
      if (_focusAttempts >= 20) {
        return; // Stop instead of fighting a row that keeps being rebuilt.
      }
      _focusAttempts++;
      _pendingIndex = target;
      _pendingFocusIntent = true;
      SchedulerBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) => _settleFocus());
    });
  }

  void _startSlowTimer(int target) {
    if (_slowRowTimer != null) {
      return;
    }
    _slowRowTimer = Timer(_slowRowThreshold, () {
      _slowRowTimer = null;
      if (!mounted || _pendingIndex != target) {
        return;
      }
      widget.onPendingRowSlow?.call(target);
    });
  }

  void _cancelSlowTimer() {
    _slowRowTimer?.cancel();
    _slowRowTimer = null;
  }

  // ------------------------------------------------------------------- rows

  void _registerRowNode(int index, FocusNode node) {
    _rowNodes[index] = node;
  }

  void _unregisterRowNode(int index, FocusNode node) {
    if (identical(_rowNodes[index], node)) {
      _rowNodes.remove(index);
    }
  }

  void _onRowFocusGained(int index) {
    // The container callback also fires for this transition, because the
    // container's ancestor-inclusive `hasFocus` turned true with the row's.
    _syncContainerFocusFlag();
    final refused = _refusedFocusIndex;
    if (refused != null) {
      _refusedFocusIndex = null;
      if (index == refused) {
        // The dialog that asked the guarding question handed focus back to the
        // row the owner refused; the highlight stays where the owner put it.
        final selected = _selectedIndex;
        if (selected != null && selected != index) {
          _requestIndex(selected, moveFocus: true, forceFocus: true);
        }
        return;
      }
    }
    if (index != _selectedIndex) {
      if (widget.multiSelect) {
        // Focus returning from a dialog must not collapse the selected set.
        _changeMultiSelection(index, preserve: true, notify: false);
      } else {
        setState(() => _selectedIndex = index);
      }
    }
    // A row that takes focus *is* the selection, so the owner hears about it
    // even when the index already matched: a selection seeded while the list
    // loaded never reached the owner, and the pane that reads "the selected
    // task" would keep showing nothing while a row looks selected, leaving F3
    // with no body to focus. Each index is reported once, so a rebuild that
    // re-focuses the same row does not repeat the selection to the owner.
    if (index == _notifiedIndex) {
      return;
    }
    _notifiedIndex = index;
    widget.onSelectedIndexChanged?.call(index);
  }

  void _onContainerFocusChange(bool hasFocus) {
    _syncContainerFocusFlag();
    widget.onFocusChange?.call(
      hasFocus || _rowNodes.values.any((n) => n.hasFocus),
    );
    if (!hasFocus || widget.itemCount == 0) {
      return;
    }
    if (!_containerFocus.hasPrimaryFocus) {
      // A row took the focus: this callback only heard that the region became
      // focused, and that row is the focus target. Tab entry is the case the
      // seed below exists for.
      return;
    }
    // Tab enters the collection at its selected row, or the first row.
    final index = _selectedIndex ?? 0;
    if (_selectedIndex == null) {
      setState(() => _selectedIndex = index);
      _notifiedIndex = index;
      widget.onSelectedIndexChanged?.call(index);
    }
    final node = _rowNodes[index];
    if (node != null && (widget.isRowReady?.call(index) ?? true)) {
      node.requestFocus();
    } else {
      _requestIndex(
        index,
        moveFocus: true,
        reveal: _pendingIndex != index || _pendingReveal,
        preserveSelection: widget.multiSelect,
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _finishMotion();
    _pendingSnapshot = null;
    // A key in the list is a deliberate move, so a refusal that never handed
    // focus back cannot claim a later focus change.
    _refusedFocusIndex = null;
    final key = event.logicalKey;
    if (widget.multiSelect && HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.space) {
        if (event is KeyDownEvent && _selectedIndex != null) {
          final index = _selectedIndex!;
          _changeMultiSelection(
            index,
            toggle: true,
            notify: true,
            userInitiated: true,
          );
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        final before = _selection;
        setState(() {
          _selectedIndices = {for (var i = 0; i < widget.itemCount; i++) i};
          _rememberSelection();
        });
        if (!setEquals(before, _selectedIndices)) {
          widget.onSelectionChanged?.call(
            VirtualListSelectionChange(_selection),
          );
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _moveSelection(_pageRows());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _moveSelection(-_pageRows());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      // A relative move can never reach row zero from inside the list, so ask
      // for the first row directly, exactly like End asks for the last one.
      if (_selectedIndex != 0 || widget.multiSelect) {
        _requestIndex(
          0,
          moveFocus: true,
          extend:
              widget.multiSelect && HardwareKeyboard.instance.isShiftPressed,
          additive:
              widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
          preserveSelection:
              widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
          userInitiated: true,
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_selectedIndex != widget.itemCount - 1 || widget.multiSelect) {
        _requestIndex(
          widget.itemCount - 1,
          moveFocus: true,
          extend:
              widget.multiSelect && HardwareKeyboard.instance.isShiftPressed,
          additive:
              widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
          preserveSelection:
              widget.multiSelect && HardwareKeyboard.instance.isControlPressed,
          userInitiated: true,
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      final index = _selectedIndex;
      if (index != null && node.hasFocus) {
        widget.onActivate?.call(index);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildEmpty(BuildContext context) {
    return Focus(
      focusNode: _containerFocus,
      includeSemantics: false,
      onFocusChange: _onContainerFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: Semantics(
        container: true,
        focusable: true,
        focused: _containerFocused,
        // One name carries both the collection and its empty message, so a
        // screen reader speaks the reason the region is empty either when
        // focus lands here or while reviewing the tree.
        label: '${widget.listLabel}. ${widget.emptyLabel}',
        explicitChildNodes: widget.emptyAction != null,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: _TransientEmptyText(
                    transient: widget.emptyIsTransient,
                    child: Text(
                      widget.emptyLabel,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                if (widget.emptyAction case final action?) ...<Widget>[
                  const SizedBox(height: 8),
                  action,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Widget order keeps an empty action as the Tab stop right after the list
  // itself; reading order would rank the nested rects unpredictably. Both
  // states share the group so the container's Focus keeps its element.
  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    policy: WidgetOrderTraversalPolicy(),
    child: widget.itemCount == 0 ? _buildEmpty(context) : _buildRows(context),
  );

  Widget _buildRows(BuildContext context) {
    return Focus(
      focusNode: _containerFocus,
      includeSemantics: false,
      onFocusChange: _onContainerFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        focusable: true,
        focused: _containerFocused,
        label: widget.listLabel,
        value: widget.multiSelect
            ? '${_selectedIndices.length} selected'
            : null,
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (_) {
            _finishMotion();
            _pendingSnapshot = null;
            return false;
          },
          child: ListView.builder(
            controller: _scroll,
            itemExtent: widget.itemExtent,
            scrollCacheExtent: widget.cacheExtent == null
                ? null
                : ScrollCacheExtent.pixels(widget.cacheExtent!),
            itemCount: widget.itemCount,
            itemBuilder: (context, index) => _VirtualRow(
              key: widget.itemKeyBuilder(index),
              index: index,
              selected: _isSelected(index),
              ready: widget.isRowReady?.call(index) ?? true,
              semantics: widget.rowSemanticsBuilder(index),
              owner: this,
              onKeyEvent: _handleKeyEvent,
              child: widget.rowBuilder(context, index, _isSelected(index)),
            ),
          ),
        ),
      ),
    );
  }
}

class _VirtualRow extends StatefulWidget {
  const _VirtualRow({
    super.key,
    required this.index,
    required this.selected,
    required this.ready,
    required this.semantics,
    required this.owner,
    required this.onKeyEvent,
    required this.child,
  });

  final int index;
  final bool selected;
  final bool ready;
  final AccessibleRowSemantics semantics;
  final _AccessibleVirtualListState owner;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;
  final Widget child;

  @override
  State<_VirtualRow> createState() => _VirtualRowState();
}

class _VirtualRowState extends State<_VirtualRow> {
  late final FocusNode _node = FocusNode(
    debugLabel: 'list-row-${widget.index}',
    skipTraversal: true,
  );
  bool _focused = false;
  bool _hovered = false;
  double _fromY = 0;
  bool _entering = false;
  double _delay = 0;
  int _generation = -1;

  void _prepareMotion() {
    final owner = widget.owner;
    if (_generation == owner._motionGeneration) return;
    _generation = owner._motionGeneration;
    final snapshot = owner._playSnapshot;
    _fromY = 0;
    _entering = false;
    _delay = 0;
    if (snapshot == null ||
        !(owner.widget.isRowReady?.call(widget.index) ?? true)) {
      return;
    }
    final newY =
        widget.index * owner.widget.itemExtent -
        (owner._scroll.hasClients ? owner._scroll.offset : 0);
    final oldY = snapshot[widget.key];
    if (!owner._fadeReorder &&
        oldY != null &&
        (oldY - newY).abs() <=
            math.min(owner._snapshotViewport, owner.widget.itemExtent * 3)) {
      _fromY = oldY - newY;
    } else {
      _fromY = 6;
      _entering = true;
      final rank = math.max(0, (newY / owner.widget.itemExtent).floor());
      _delay = math.min(rank, ViewerMotion.staggerMaxRows) * 12 / 292;
    }
  }

  @override
  void didUpdateWidget(_VirtualRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.owner != widget.owner) {
      oldWidget.owner._unregisterRowNode(oldWidget.index, _node);
      widget.owner._registerRowNode(widget.index, _node);
    }
    _prepareMotion();
  }

  @override
  void initState() {
    super.initState();
    widget.owner._registerRowNode(widget.index, _node);
    widget.owner._mountedRows[widget.key!] = this;
    _prepareMotion();
  }

  @override
  void dispose() {
    widget.owner._unregisterRowNode(widget.index, _node);
    if (identical(widget.owner._mountedRows[widget.key], this)) {
      widget.owner._mountedRows.remove(widget.key);
    }
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final multi = widget.owner.widget.multiSelect;
    final stroke = _focused ? 3.0 : (!multi && widget.selected ? 2.0 : 0.0);
    final borderColor = _focused ? colors.onSurface : colors.primary;
    return Focus(
      focusNode: _node,
      includeSemantics: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      onFocusChange: (hasFocus) {
        setState(() => _focused = hasFocus);
        if (hasFocus) {
          widget.owner._onRowFocusGained(widget.index);
        }
      },
      child: Semantics(
        container: true,
        explicitChildNodes: !widget.owner.widget.excludeRowChildSemantics,
        focusable: true,
        focused: _focused,
        selected: widget.selected,
        label: widget.semantics.label,
        value: widget.semantics.value,
        onTap: () => widget.owner._requestIndex(
          widget.index,
          moveFocus: true,
          forceFocus: true,
          userInitiated: true,
        ),
        child: Listener(
          onPointerDown: widget.owner.widget.activateOnDoubleTap
              ? (event) {
                  if (event.kind == PointerDeviceKind.mouse &&
                      event.buttons == kPrimaryButton) {
                    // Selection and focus cannot wait for double-tap recognition:
                    // a following keyboard command must target this row now.
                    widget.owner._pointerSelect(widget.index);
                  }
                }
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onDoubleTap: widget.owner.widget.activateOnDoubleTap
                ? () {
                    widget.owner._requestIndex(
                      widget.index,
                      moveFocus: true,
                      forceFocus: true,
                      reveal: false,
                      preserveSelection: true,
                    );
                    widget.owner.widget.onActivate?.call(widget.index);
                  }
                : null,
            onTapUp: (details) {
              // Mouse double-click rows selected on down. Other taps select
              // only after recognition, so a touch scroll cannot select a row.
              if (!widget.owner.widget.activateOnDoubleTap ||
                  details.kind != PointerDeviceKind.mouse) {
                widget.owner._pointerSelect(widget.index);
              }
            },
            child: _RowMotion(
              driver: widget.owner._motion,
              fromY: _fromY,
              entering: _entering,
              delay: _delay,
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: AnimatedContainer(
                  duration: _focused || widget.selected
                      ? Duration.zero
                      : ViewerMotion.of(context, ViewerMotion.short),
                  color: _hovered && !_focused && !widget.selected
                      ? colors.onSurface.withValues(alpha: .06)
                      : colors.onSurface.withValues(alpha: 0),
                  child: DecoratedBox(
                    key: multi ? const ValueKey('multi-focus-outline') : null,
                    decoration: BoxDecoration(
                      border: Border(
                        left: stroke > 0
                            ? BorderSide(color: borderColor, width: stroke)
                            : BorderSide.none,
                        top: stroke > 0
                            ? BorderSide(color: borderColor, width: stroke)
                            : BorderSide.none,
                        right: stroke > 0
                            ? BorderSide(color: borderColor, width: stroke)
                            : BorderSide.none,
                        bottom: BorderSide(
                          color: stroke > 0
                              ? borderColor
                              : colors.outlineVariant,
                          width: stroke > 0 ? stroke : 1,
                        ),
                      ),
                    ),
                    child: ExcludeSemantics(
                      excluding: widget.owner.widget.excludeRowChildSemantics,
                      child: multi
                          ? Padding(
                              padding: const EdgeInsets.all(4),
                              child: ColoredBox(
                                color: widget.selected
                                    ? colors.primaryContainer
                                    : colors.surface,
                                child: DefaultTextStyle.merge(
                                  style: TextStyle(
                                    color: widget.selected
                                        ? colors.onPrimaryContainer
                                        : colors.onSurface,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 24,
                                        child: widget.selected
                                            ? Icon(
                                                Icons.check,
                                                key: const ValueKey(
                                                  'multi-selection-check',
                                                ),
                                                size: 20,
                                                color:
                                                    colors.onPrimaryContainer,
                                              )
                                            : null,
                                      ),
                                      SizedBox(
                                        width: 20,
                                        child:
                                            widget.index ==
                                                widget.owner._selectedIndex
                                            ? Icon(
                                                Icons.arrow_right,
                                                key: const ValueKey(
                                                  'multi-lead-marker',
                                                ),
                                                size: 20,
                                                color: widget.selected
                                                    ? colors.onPrimaryContainer
                                                    : colors.onSurface,
                                              )
                                            : null,
                                      ),
                                      Expanded(child: widget.child),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Only the transform and opacity rebuild per tick; row content is the child.
class _RowMotion extends StatelessWidget {
  const _RowMotion({
    required this.driver,
    required this.fromY,
    required this.entering,
    required this.delay,
    required this.child,
  });
  final Animation<double> driver;
  final double fromY, delay;
  final bool entering;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final progress = CurveTween(
      curve: Interval(
        delay,
        (delay + 220 / 292).clamp(0, 1),
        curve: entering ? ViewerMotion.enter : ViewerMotion.move,
      ),
    ).animate(driver);
    return AnimatedBuilder(
      animation: progress,
      child: FadeTransition(
        opacity: entering ? progress : const AlwaysStoppedAnimation(1.0),
        alwaysIncludeSemantics: true,
        child: child,
      ),
      builder: (context, child) => Transform.translate(
        offset: Offset(0, fromY * (1 - progress.value)),
        child: ColoredBox(
          color: driver.value < 1
              ? Theme.of(context).colorScheme.surface
              : Colors.transparent,
          child: child,
        ),
      ),
    );
  }
}

class _TransientEmptyText extends StatefulWidget {
  const _TransientEmptyText({required this.transient, required this.child});
  final bool transient;
  final Widget child;
  @override
  State<_TransientEmptyText> createState() => _TransientEmptyTextState();
}

class _TransientEmptyTextState extends State<_TransientEmptyText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _driver = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 330),
  );
  bool _wasTransient = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(_TransientEmptyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    if (widget.transient && !_wasTransient && ViewerMotion.enabled(context)) {
      _driver.forward(from: 0);
    }
    if (!widget.transient || !ViewerMotion.enabled(context)) _driver.value = 1;
    _wasTransient = widget.transient;
  }

  @override
  void dispose() {
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    alwaysIncludeSemantics: true,
    opacity: CurveTween(
      curve: const Interval(150 / 330, 1, curve: ViewerMotion.enter),
    ).animate(_driver),
    child: widget.child,
  );
}
