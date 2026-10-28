import 'package:flutter/material.dart';
import 'viewer_motion.dart';

/// A separate 3px ring, with a 2px contrasting gap. It paints outside the
/// unchanged button boundary, so focus never changes the role's fill or size.
class ViewerFocusBorder extends StadiumBorder {
  const ViewerFocusBorder({required this.ring, required this.gap, super.side});
  final Color ring;
  final Color gap;

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => t < .5 ? a : this;
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => t < .5 ? this : b;

  @override
  StadiumBorder copyWith({BorderSide? side}) =>
      ViewerFocusBorder(ring: ring, gap: gap, side: side ?? this.side);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final outer = const StadiumBorder().getOuterPath(rect.inflate(5));
    final inner = const StadiumBorder().getOuterPath(rect.inflate(2));
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = ring,
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        inner,
        const StadiumBorder().getOuterPath(rect),
      ),
      Paint()..color = gap,
    );
    super.paint(canvas, rect, textDirection: textDirection);
  }
}

/// Error-tinted destructive actions retain their existing SDK button semantics.
ButtonStyle viewerDestructiveButtonStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return ButtonStyle(
    foregroundColor: WidgetStatePropertyAll(colors.onErrorContainer),
    iconColor: WidgetStatePropertyAll(colors.onErrorContainer),
    animationDuration: ViewerMotion.of(context, ViewerMotion.short),
    backgroundColor: WidgetStatePropertyAll(colors.errorContainer),
    side: WidgetStatePropertyAll(BorderSide(color: colors.onErrorContainer)),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => colors.onErrorContainer.withValues(
        alpha: states.contains(WidgetState.pressed)
            ? .12
            : states.contains(WidgetState.hovered)
            ? .08
            : 0,
      ),
    ),
  );
}

/// Container and state treatments only. SDK widgets still own focus, actions,
/// accessible names, roles and disabled semantics.
ThemeData viewerButtonTheme(
  ThemeData theme, {
  required bool highContrast,
  bool motionOff = false,
}) {
  final colors = theme.colorScheme;
  ButtonStyle style({
    required bool filled,
    bool secondary = false,
    bool icon = false,
  }) {
    return ButtonStyle(
      visualDensity: VisualDensity.standard,
      iconSize: const WidgetStatePropertyAll(18),
      animationDuration: motionOff ? Duration.zero : ViewerMotion.short,
      minimumSize: WidgetStatePropertyAll(
        icon ? const Size(32, 32) : const Size(64, 36),
      ),
      shape: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.focused) &&
                !states.contains(WidgetState.disabled)
            ? ViewerFocusBorder(ring: colors.onSurface, gap: colors.surface)
            : const StadiumBorder(),
      ),
      padding: WidgetStatePropertyAll(
        icon
            ? const EdgeInsets.all(6)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(color: colors.onSurface.withValues(alpha: .12));
        }
        return BorderSide(
          color: secondary
              ? colors.onSecondaryContainer
              : highContrast
              ? colors.onSurface
              : colors.onSurfaceVariant,
          width: highContrast ? 2 : 1,
        );
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.onSurface.withValues(alpha: .08);
        }
        if (filled) return null; // Preserve FilledButton / .tonal role colors.
        return secondary
            ? colors.secondaryContainer
            : colors.surfaceContainerLow;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.onSurface.withValues(alpha: .38);
        }
        return filled
            ? null
            : secondary
            ? colors.onSecondaryContainer
            : colors.onSurface;
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.onSurface.withValues(alpha: .38);
        }
        return filled
            ? null
            : secondary
            ? colors.onSecondaryContainer
            : colors.onSurface;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        // Filled controls retain the SDK's foreground-relative ink treatment.
        if (filled) return null;
        if (states.contains(WidgetState.pressed)) {
          return (secondary ? colors.onSecondaryContainer : colors.onSurface)
              .withValues(alpha: .12);
        }
        if (states.contains(WidgetState.hovered)) {
          return (secondary ? colors.onSecondaryContainer : colors.onSurface)
              .withValues(alpha: .08);
        }
        return Colors.transparent;
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: style(filled: true)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: style(filled: false, secondary: true),
    ),
    textButtonTheme: TextButtonThemeData(style: style(filled: false)),
    iconButtonTheme: IconButtonThemeData(
      style: style(filled: false, icon: true),
    ),
  );
}
