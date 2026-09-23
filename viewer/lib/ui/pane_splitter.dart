import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bevelled pane boundary with pointer and keyboard resizing.
class PaneSplitter extends StatefulWidget {
  const PaneSplitter({
    super.key,
    required this.label,
    required this.onResize,
    required this.onResizeEnd,
  });
  final String label;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  @override
  State<PaneSplitter> createState() => _PaneSplitterState();
}

class _PaneSplitterState extends State<PaneSplitter> {
  bool _focused = false;
  double _pending = 0;
  void _step(double delta) {
    widget.onResize(delta);
    widget.onResizeEnd();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      hint: 'Drag or use Left and Right arrow keys to resize panels',
      onIncrease: () => _step(20),
      onDecrease: () => _step(-20),
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _step(-20);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _step(20);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: Tooltip(
            message: widget.label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _pending = 0,
              onHorizontalDragUpdate: (event) {
                _pending += event.delta.dx;
                if (_pending.abs() >= 16) {
                  widget.onResize(_pending);
                  _pending = 0;
                }
              },
              onHorizontalDragEnd: (_) {
                if (_pending != 0) widget.onResize(_pending);
                widget.onResizeEnd();
              },
              child: Container(
                width: 8,
                decoration: BoxDecoration(
                  color: _focused
                      ? colors.primary
                      : colors.surfaceContainerHighest,
                  border: Border(
                    left: BorderSide(color: colors.outline, width: 2),
                    right: BorderSide(color: colors.surface, width: 2),
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
