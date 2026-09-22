/// A virtualized single-selection list that stays keyboard- and
/// screen-reader-operable, including rows that are not built yet.
///
/// Contract: viewer/spec.md sections 5 and 9, viewer/design.md section 6.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// What a screen reader says for one row: the identifying content once, plus an
/// optional non-duplicating position label.
class AccessibleRowSemantics {
  const AccessibleRowSemantics({required this.label, this.value});

  final String label;
  final String? value;
}

/// Imperative handle used by region shortcut handlers (F1/F2), End, Go to row
/// and post-save selection retention.
class VirtualListController extends ChangeNotifier {
  _AccessibleVirtualListState? _state;

  bool get isAttached => _state != null;

  int? get selectedIndex => _state?._selectedIndex;

  int? get forwardedIndex => _state?._forwardIndex;

  int? get pendingTargetIndex => _state?._pendingIndex;

  bool get hasPendingTarget => _state?._pendingIndex != null;

  bool get hasFocus => _state?._listHasFocus ?? false;

  /// Index of the row that currently owns keyboard focus, if any.
  int? get focusedRowIndex => _state?.focusedRowIndex;

  /// Focus the region: its selected row, or the first row when nothing is
  /// selected yet, or the list container when the list is empty.
  void focusRegion() => _state?._focusRegion();

  /// Move selection and focus to [index] (End, Go to row, programmatic jump).
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
    this.onSelectedIndexChanged,
    this.isRowReady,
    this.onPendingRowSlow,
    this.cacheExtent,
    this.onFocusChange,
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

  final ValueChanged<int>? onSelectedIndexChanged;

  /// False while the row exists only as a placeholder. Focus waits for the real
  /// row instead of landing on invented content.
  final bool Function(int index)? isRowReady;

  /// Called once when a pending jump has waited longer than the load
  /// announcement threshold (500 ms).
  final ValueChanged<int>? onPendingRowSlow;

  final double? cacheExtent;

  final ValueChanged<bool>? onFocusChange;

  @override
  State<AccessibleVirtualList> createState() => _AccessibleVirtualListState();
}

class _AccessibleVirtualListState extends State<AccessibleVirtualList> {
  static const Duration _slowRowThreshold = Duration(milliseconds: 500);

  final ScrollController _scroll = ScrollController();
  final FocusNode _containerFocus = FocusNode(
    debugLabel: 'list-region',
    skipTraversal: false,
  );
  final Map<int, FocusNode> _rowNodes = <int, FocusNode>{};

  int? _selectedIndex;

  /// Row the owner refused to move to; the next focus change is the dialog's
  /// restoration, which must not be reported as a fresh move.
  int? _refusedFocusIndex;
  int? _notifiedIndex;
  int? _pendingIndex;
  int? _forwardIndex;
  int _focusAttempts = 0;
  bool _pendingFocusIntent = false;
  Timer? _slowRowTimer;
  bool _containerFocused = false;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _syncSelectionWithItemCount();
  }

  @override
  void didUpdateWidget(covariant AccessibleVirtualList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
    _syncSelectionWithItemCount();
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
    widget.controller._detach(this);
    _containerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncSelectionWithItemCount() {
    if (widget.itemCount == 0) {
      _selectedIndex = null;
      return;
    }
    final selected = _selectedIndex;
    if (selected == null || selected >= widget.itemCount) {
      _selectedIndex = math.min(selected ?? 0, widget.itemCount - 1);
    }
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
    _requestIndex(index, moveFocus: true, forceFocus: true);
  }

  void _setSelectedIndex(int? index, {required bool notify}) {
    if (index != null && widget.itemCount > 0) {
      index = index.clamp(0, widget.itemCount - 1);
    } else {
      index = null;
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

  void _requestIndex(
    int index, {
    required bool moveFocus,
    bool forceFocus = false,
  }) {
    if (widget.itemCount == 0) {
      return;
    }
    _refusedFocusIndex = null;
    final target = index.clamp(0, widget.itemCount - 1);
    _setSelectedIndex(target, notify: true);
    if (!moveFocus) {
      return;
    }
    _pendingIndex = target;
    // Scrolling to the target disposes the row that owned focus, so by the
    // time the target row exists nothing in the list is focused any more.
    // Remember that this move was deliberate instead of mistaking the gap for
    // "the user focused something else" and forwarding the focus.
    _pendingFocusIntent =
        forceFocus || _listHasFocus || _containerFocus.hasFocus;
    _focusAttempts = 0;
    _scrollToIndex(target);
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
    final target = current + delta;
    if (target < 0 || target >= widget.itemCount) {
      return; // Stay in place at a boundary without repeated speech.
    }
    _requestIndex(target, moveFocus: true);
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
    final target =
        index * extent - math.max(0.0, position.viewportDimension - extent);
    final clamped = target.clamp(0.0, position.maxScrollExtent);
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
        _scrollToIndex(target);
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
      setState(() => _selectedIndex = index);
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
      _requestIndex(index, moveFocus: true);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // A key in the list is a deliberate move, so a refusal that never handed
    // focus back cannot claim a later focus change.
    _refusedFocusIndex = null;
    final key = event.logicalKey;
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
      if (_selectedIndex != 0) {
        _requestIndex(0, moveFocus: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_selectedIndex != widget.itemCount - 1) {
        _requestIndex(widget.itemCount - 1, moveFocus: true);
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

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) {
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
          child: ExcludeSemantics(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.emptyLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ),
      );
    }
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
            selected: index == _selectedIndex,
            semantics: widget.rowSemanticsBuilder(index),
            owner: this,
            onKeyEvent: _handleKeyEvent,
            child: widget.rowBuilder(context, index, index == _selectedIndex),
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
    required this.semantics,
    required this.owner,
    required this.onKeyEvent,
    required this.child,
  });

  final int index;
  final bool selected;
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

  @override
  void initState() {
    super.initState();
    widget.owner._registerRowNode(widget.index, _node);
  }

  @override
  void dispose() {
    widget.owner._unregisterRowNode(widget.index, _node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        explicitChildNodes: false,
        focusable: true,
        focused: _focused,
        selected: widget.selected,
        label: widget.semantics.label,
        value: widget.semantics.value,
        child: ExcludeSemantics(child: widget.child),
      ),
    );
  }
}
