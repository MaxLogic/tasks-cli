/// The persistent Status region.
///
/// Exactly one channel speaks per event: a Bella clip, or one live announcement
/// (viewer/spec.md section 9.1). The full text always stays readable.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../controllers/announcement_controller.dart';

/// Focusable, readable status area with an optional single live region.
class StatusBar extends StatefulWidget {
  const StatusBar({
    super.key,
    required this.controller,
    this.onRetry,
    this.onDetails,
    this.focusNode,
  });

  final AnnouncementController controller;

  /// Shown only while an operation can be retried.
  final VoidCallback? onRetry;

  /// Shown only while there are details to read.
  final VoidCallback? onDetails;

  final FocusNode? focusNode;

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  String _liveText = '';
  String _lastLiveSource = '';
  int _lastRevision = -1;
  bool _flip = false;

  /// Windows answers the engine `announce` channel, so dynamic status goes
  /// through it. The live region stays the fallback for platforms where
  /// announcements are unsupported or discouraged (dart:ui
  /// `AccessibilityFeatures.supportsAnnounce`).
  bool _supportsAnnounce = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onAnnouncementChanged);
    _onAnnouncementChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _supportsAnnounce = MediaQuery.supportsAnnounceOf(context);
  }

  @override
  void didUpdateWidget(covariant StatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onAnnouncementChanged);
      widget.controller.addListener(_onAnnouncementChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAnnouncementChanged);
    super.dispose();
  }

  void _onAnnouncementChanged() {
    final revision = widget.controller.liveRegionRevision;
    final text = widget.controller.liveRegionText ?? '';
    if (revision != _lastRevision) {
      _lastRevision = revision;
      if (text.isNotEmpty && text == _lastLiveSource) {
        // A repeated identical message must still fire exactly once.
        _flip = !_flip;
        _liveText = _flip ? '$text\u200B' : text;
      } else {
        _liveText = text;
      }
      _lastLiveSource = text;
      if (_supportsAnnounce && text.isNotEmpty) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          text,
          Directionality.maybeOf(context) ?? TextDirection.ltr,
        );
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final statusText = controller.statusText;
    final isLive =
        !_supportsAnnounce &&
        controller.liveRegionText != null &&
        _liveText.isNotEmpty;
    final text = Text(
      statusText,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    return Focus(
      focusNode: widget.focusNode,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: isLive
                  ? Semantics(
                      container: true,
                      liveRegion: true,
                      label: _liveText,
                      child: ExcludeSemantics(child: text),
                    )
                  : text,
            ),
            if (controller.audioWarnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'Audio warning (${controller.audioWarnings.length})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (widget.onDetails != null)
              TextButton(
                onPressed: widget.onDetails,
                child: const Text('Details'),
              ),
            if (widget.onRetry != null)
              TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
