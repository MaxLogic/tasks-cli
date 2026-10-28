import 'package:flutter/material.dart';
import 'viewer_icons.dart';

/// Finite paint-only motion. Focus and semantic children are never duplicated.
abstract final class ViewerMotion {
  static const short = Duration(milliseconds: 120);
  static const medium = Duration(milliseconds: 180);
  static const long = Duration(milliseconds: 220);
  static const staggerStep = Duration(milliseconds: 12);
  static const staggerMaxRows = 6;
  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const move = Curves.easeInOutCubic;
  static bool enabled(BuildContext context) =>
      !MediaQuery.disableAnimationsOf(context);
  static Duration of(BuildContext context, Duration duration) =>
      enabled(context) ? duration : Duration.zero;
}

class ViewerEnterTransition extends StatefulWidget {
  const ViewerEnterTransition({
    super.key,
    required this.transitionKey,
    required this.child,
    this.animate = true,
    this.axis = Axis.horizontal,
    this.distance = 24,
    this.direction = 1,
    this.duration = ViewerMotion.long,
    this.scaleBegin = 1,
  });
  final Object? transitionKey;
  final Widget child;
  final bool animate;
  final Axis axis;
  final double distance, direction, scaleBegin;
  final Duration duration;
  @override
  State<ViewerEnterTransition> createState() => _ViewerEnterTransitionState();
}

class _ViewerEnterTransitionState extends State<ViewerEnterTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _driver = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _driver,
    curve: ViewerMotion.enter,
  );
  @override
  void didUpdateWidget(ViewerEnterTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionKey != widget.transitionKey) {
      if (widget.animate && ViewerMotion.enabled(context)) {
        _driver.duration = widget.duration;
        _driver.forward(from: 0);
      } else {
        _driver.value = 1;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!ViewerMotion.enabled(context)) _driver.value = 1;
  }

  @override
  void dispose() {
    _opacity.dispose();
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _opacity,
    child: FadeTransition(
      opacity: _opacity,
      alwaysIncludeSemantics: true,
      child: widget.child,
    ),
    builder: (context, child) {
      final offset = (1 - _opacity.value) * widget.distance * widget.direction;
      return Transform.translate(
        offset: widget.axis == Axis.horizontal
            ? Offset(offset, 0)
            : Offset(0, offset),
        child: Transform.scale(
          scale: widget.scaleBegin + (1 - widget.scaleBegin) * _opacity.value,
          child: child,
        ),
      );
    },
  );
}

AnimationStyle viewerDialogAnimationStyle(BuildContext context) =>
    ViewerMotion.enabled(context)
    ? const AnimationStyle(
        duration: ViewerMotion.medium,
        curve: ViewerMotion.enter,
        reverseCurve: ViewerMotion.exit,
      )
    : AnimationStyle.noAnimation;

class ViewerDialogEntrance extends StatefulWidget {
  const ViewerDialogEntrance({super.key, required this.child});
  final Widget child;
  @override
  State<ViewerDialogEntrance> createState() => _ViewerDialogEntranceState();
}

class _ViewerDialogEntranceState extends State<ViewerDialogEntrance> {
  Animation<double>? _route;
  CurvedAnimation? _curve;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route != _route) {
      _curve?.dispose();
      _route = route;
      _curve = route == null
          ? null
          : CurvedAnimation(
              parent: route,
              curve: ViewerMotion.enter,
              reverseCurve: ViewerMotion.exit,
            );
    }
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _curve == null || !ViewerMotion.enabled(context)
        ? const AlwaysStoppedAnimation(1.0)
        : Tween(begin: .96, end: 1.0).animate(_curve!),
    child: widget.child,
  );
}

/// Copy success is decorative; existing announcements remain the only speech.
class ViewerFlashController extends ChangeNotifier {
  void flash() => notifyListeners();
}

class ViewerFlashIcon extends StatefulWidget {
  const ViewerFlashIcon({super.key, required this.controller});
  final ViewerFlashController controller;
  @override
  State<ViewerFlashIcon> createState() => _ViewerFlashIconState();
}

class _ViewerFlashIconState extends State<ViewerFlashIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _confirmed = false);
        }
      });
  bool _confirmed = false;
  void _flash() {
    setState(() => _confirmed = true);
    _hold.duration = Duration(
      milliseconds: ViewerMotion.enabled(context) ? 1620 : 1500,
    );
    _hold.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    _hold.value = 0;
    widget.controller.addListener(_flash);
  }

  @override
  void didUpdateWidget(ViewerFlashIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_flash);
      widget.controller.addListener(_flash);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_flash);
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ViewerEnterTransition(
    transitionKey: _confirmed,
    axis: Axis.vertical,
    distance: 0,
    duration: ViewerMotion.short,
    scaleBegin: .8,
    child: Icon(_confirmed ? ViewerIcons.check : ViewerIcons.copy),
  );
}

/// The target panel reserves its natural height immediately, so its sibling
/// list lays out once. Only the single incoming panel fades/translates; focus
/// and semantics are present from the first frame, including at zero opacity.
class ViewerDisclosureTransition extends StatelessWidget {
  const ViewerDisclosureTransition({
    super.key,
    required this.transitionKey,
    required this.child,
  });
  final Object transitionKey;
  final Widget child;
  @override
  Widget build(BuildContext context) => ViewerEnterTransition(
    transitionKey: transitionKey,
    axis: Axis.vertical,
    distance: 8,
    duration: ViewerMotion.medium,
    child: child,
  );
}
