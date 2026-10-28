import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'viewer_icons.dart';
import 'viewer_motion.dart';
import 'package:flutter/services.dart';
import '../data/models.dart';
import 'attachment_dialogs.dart' show AttachmentDialogFrame;

const attachmentTextPreviewLimit = 1024 * 1024;

final class AttachmentTextPreview {
  const AttachmentTextPreview(
    this.text,
    this.truncated,
    this.invalid,
    this.bytesRead,
  );
  final String text;
  final bool truncated, invalid;
  final int bytesRead;
}

/// Seek before reading so Tail never buffers the complete source file.
Future<AttachmentTextPreview> readAttachmentText(
  String path, {
  bool tail = false,
}) async {
  final file = await File(path).open();
  try {
    final size = await file.length();
    final count = math.min(size, attachmentTextPreviewLimit);
    if (tail) await file.setPosition(math.max(0, size - count));
    final bytes = await file.read(count);
    var invalid = false;
    try {
      utf8.decode(bytes);
    } on FormatException {
      invalid = true;
    }
    return AttachmentTextPreview(
      utf8.decode(bytes, allowMalformed: true),
      size > count,
      invalid,
      bytes.length,
    );
  } finally {
    await file.close();
  }
}

class AttachmentPreviewDialog extends StatefulWidget {
  const AttachmentPreviewDialog({
    super.key,
    required this.item,
    required this.path,
    required this.announce,
    required this.onSaveAs,
  });
  final AttachmentSummary item;
  final String path;
  final void Function(String) announce;
  final Future<void> Function() onSaveAs;
  @override
  State<AttachmentPreviewDialog> createState() =>
      _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<AttachmentPreviewDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _zoomDriver =
      AnimationController(vsync: this, duration: ViewerMotion.medium)
        ..addListener(() {
          final tween = _zoomTween;
          if (tween != null) {
            transform.value = tween.transform(
              ViewerMotion.move.transform(_zoomDriver.value),
            );
          }
        });
  Matrix4Tween? _zoomTween;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!ViewerMotion.enabled(context) && _zoomDriver.isAnimating) {
      _zoomDriver.value = 1;
    }
  }

  final transform = TransformationController();
  Future<AttachmentTextPreview>? text;
  bool tail = false;
  int _readGeneration = 0;
  int width = 0, height = 0;
  double zoom = 1;
  Size viewport = const Size(720, 420);
  final textController = TextEditingController();
  final contentFocus = FocusNode(debugLabel: 'Attachment preview content');
  bool splitLines = false;
  bool _announcedSplit = false;
  String? imageError;
  bool get image =>
      widget.item.kind == 'image' &&
      widget.item.originalSize <= 64 * 1024 * 1024 &&
      const [
        'image/png',
        'image/jpeg',
        'image/gif',
        'image/webp',
        'image/bmp',
      ].contains(widget.item.mediaType);
  @override
  void initState() {
    super.initState();
    _zoomDriver.value = 0;
    if (widget.item.kind == 'text') _read(false);
    if (image) _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(widget.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (!mounted) return;
      setState(() {
        width = descriptor!.width;
        height = descriptor.height;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    } on Object catch (error) {
      if (mounted) setState(() => imageError = '$error');
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _fit() {
    if (width == 0 || height == 0) return;
    _zoom(math.min(viewport.width / width, viewport.height / height));
  }

  void _read(bool last) {
    tail = last;
    final generation = ++_readGeneration;
    text = readAttachmentText(widget.path, tail: tail).then((value) {
      if (mounted && generation == _readGeneration) {
        final display = splitAttachmentPreviewLines(value.text);
        splitLines = display != value.text;
        textController.value = TextEditingValue(
          text: display,
          selection: const TextSelection.collapsed(offset: 0),
        );
        final notes = [
          if (value.truncated || value.invalid) _note(value),
          if (splitLines && !_announcedSplit) attachmentLongLineNotice,
        ].join(' ');
        if (splitLines) _announcedSplit = true;
        if (notes.isNotEmpty) widget.announce(notes);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) contentFocus.requestFocus();
        });
      }
      return value;
    });
  }

  String _note(AttachmentTextPreview value) => [
    if (value.truncated)
      'Showing ${tail ? 'last' : 'first'} 1 MiB; preview truncated.',
    if (value.invalid) 'Invalid UTF-8 replaced in preview.',
  ].join(' ');
  void _zoom(double value) {
    setState(() {
      zoom = value.clamp(0.00001, 16);
      final target = Matrix4.diagonal3Values(zoom, zoom, 1);
      if (ViewerMotion.enabled(context)) {
        _zoomTween = Matrix4Tween(begin: transform.value.clone(), end: target);
        _zoomDriver.forward(from: 0);
      } else {
        _zoomDriver.stop();
        transform.value = target;
      }
    });
    widget.announce('Zoom ${(zoom * 100).round()} percent');
  }

  @override
  void dispose() {
    _zoomDriver.dispose();
    contentFocus.dispose();
    transform.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.pop(context),
      const SingleActivator(LogicalKeyboardKey.keyC, alt: true): () =>
          Navigator.pop(context),
      const SingleActivator(LogicalKeyboardKey.keyS, alt: true): () {
        widget.onSaveAs();
      },
      if (widget.item.kind == 'text' &&
          widget.item.originalSize > attachmentTextPreviewLimit)
        const SingleActivator(LogicalKeyboardKey.keyH, alt: true): () =>
            setState(() => _read(false)),
      if (widget.item.kind == 'text' &&
          widget.item.originalSize > attachmentTextPreviewLimit)
        const SingleActivator(LogicalKeyboardKey.keyT, alt: true): () =>
            setState(() => _read(true)),
    },
    child: AttachmentDialogFrame(
      title: widget.item.name,
      content: SizedBox(
        width: 720,
        height: 480,
        child: image
            ? _image()
            : widget.item.kind == 'text'
            ? _text()
            : _fallback(),
      ),
      actions: [
        TextButton.icon(
          onPressed: widget.onSaveAs,
          icon: const Icon(ViewerIcons.saveAs),
          label: const Text('Save as (Alt+S)'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(ViewerIcons.close),
          label: const Text('Close (Alt+C)'),
        ),
      ],
    ),
  );
  Widget _fallback({bool nested = false}) => SelectableText(
    '${widget.item.rowLabel}\nPreview unavailable',
    autofocus: !nested,
    focusNode: nested ? null : contentFocus,
  );
  Map<ShortcutActivator, VoidCallback> get _imageBindings => {
    const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
        _zoom(zoom * 1.25),
    const SingleActivator(
      LogicalKeyboardKey.equal,
      control: true,
      shift: true,
    ): () =>
        _zoom(zoom * 1.25),
    const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
        _zoom(zoom / 1.25),
    const SingleActivator(LogicalKeyboardKey.digit0, control: true): _fit,
    const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
        _zoom(1),
    if (image)
      for (final entry in {
        LogicalKeyboardKey.arrowLeft: const Offset(40, 0),
        LogicalKeyboardKey.arrowRight: const Offset(-40, 0),
        LogicalKeyboardKey.arrowUp: const Offset(0, 40),
        LogicalKeyboardKey.arrowDown: const Offset(0, -40),
      }.entries)
        SingleActivator(entry.key): () {
          if (image) {
            setState(() {
              final matrix = transform.value.clone();
              matrix.setTranslationRaw(
                matrix.storage[12] + entry.value.dx,
                matrix.storage[13] + entry.value.dy,
                0,
              );
              transform.value = matrix;
            });
          }
        },
  };
  Widget _image() => imageError != null
      ? _fallback()
      : CallbackShortcuts(
          bindings: _imageBindings,
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => _zoom(zoom * 1.25),
                    icon: const Icon(ViewerIcons.zoomIn),
                    label: const Text('Zoom in'),
                  ),
                  TextButton.icon(
                    onPressed: () => _zoom(zoom / 1.25),
                    icon: const Icon(ViewerIcons.zoomOut),
                    label: const Text('Zoom out'),
                  ),
                  TextButton.icon(
                    onPressed: _fit,
                    icon: const Icon(ViewerIcons.fit),
                    label: const Text('Fit'),
                  ),
                  TextButton.icon(
                    onPressed: () => _zoom(1),
                    icon: const Icon(ViewerIcons.actualSize),
                    label: const Text('Actual size'),
                  ),
                ],
              ),
              Expanded(
                child: Focus(
                  autofocus: true,
                  focusNode: contentFocus,
                  child: Semantics(
                    label:
                        'Image ${widget.item.name}, $width by $height pixels, zoom ${(zoom * 100).round()} percent',
                    image: true,
                    excludeSemantics: true,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        viewport = constraints.biggest;
                        return InteractiveViewer(
                          constrained: false,
                          transformationController: transform,
                          minScale: 0.00001,
                          maxScale: 16,
                          onInteractionEnd: (_) {
                            setState(
                              () => zoom = transform.value.getMaxScaleOnAxis(),
                            );
                            widget.announce(
                              'Zoom ${(zoom * 100).round()} percent',
                            );
                          },
                          child: SizedBox(
                            width: width > 0 ? width.toDouble() : 1,
                            height: height > 0 ? height.toDouble() : 1,
                            child: Image(
                              image: ResizeImage(
                                FileImage(File(widget.path)),
                                width: 8192,
                                height: 8192,
                                policy: ResizeImagePolicy.fit,
                                allowUpscaling: false,
                              ),
                              frameBuilder: (context, child, frame, sync) =>
                                  child,
                              errorBuilder: (_, error, stack) =>
                                  _fallback(nested: true),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
  Widget _text() => Column(
    children: [
      if (widget.item.originalSize > attachmentTextPreviewLimit)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _read(false)),
              icon: const Icon(ViewerIcons.head),
              label: const Text('Head (Alt+H)'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _read(true)),
              icon: const Icon(ViewerIcons.tail),
              label: const Text('Tail (Alt+T)'),
            ),
          ],
        ),
      Expanded(
        child: FutureBuilder<AttachmentTextPreview>(
          future: text,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SelectableText('Preview unavailable: ${snapshot.error}');
            }
            final value = snapshot.data;
            if (value == null) return const Text('Loading preview');
            return Column(
              children: [
                if (value.truncated || value.invalid || splitLines)
                  Semantics(
                    key: const ValueKey('attachment-preview-notes'),
                    container: true,
                    child: Column(
                      children: [
                        if (value.truncated || value.invalid)
                          Text(_note(value)),
                        if (splitLines) const Text(attachmentLongLineNotice),
                      ],
                    ),
                  ),
                Expanded(
                  child: TextField(
                    key: ValueKey('${widget.path}:$tail'),
                    controller: textController,
                    autofocus: true,
                    focusNode: contentFocus,
                    readOnly: true,
                    maxLines: null,
                    expands: true,
                    decoration: const InputDecoration(
                      labelText: 'Attachment text',
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );
}

const attachmentLongLineNotice =
    'Long lines were split for preview; Save as keeps the original file.';

/// Insert display-only boundaries, retaining all original characters.
String splitAttachmentPreviewLines(String source) {
  const limit = 2048;
  final out = StringBuffer();
  var start = 0;
  while (start < source.length) {
    final newline = source.indexOf('\n', start);
    final end = newline < 0 ? source.length : newline;
    while (end - start > limit) {
      final boundary = start + limit;
      final window = source.substring(start + limit ~/ 2, boundary + 1);
      final space = window.lastIndexOf(' ');
      final comma = window.lastIndexOf(',');
      final relative = math.max(space, comma);
      final preferred = relative < 0 ? -1 : start + limit ~/ 2 + relative;
      var cut = preferred >= start + limit ~/ 2 ? preferred + 1 : boundary;
      // Keep a UTF-16 surrogate pair together at an inserted boundary.
      if (cut < source.length &&
          source.codeUnitAt(cut - 1) >= 0xD800 &&
          source.codeUnitAt(cut - 1) <= 0xDBFF &&
          source.codeUnitAt(cut) >= 0xDC00 &&
          source.codeUnitAt(cut) <= 0xDFFF) {
        cut--;
      }
      out.write(source.substring(start, cut));
      out.write('\n');
      start = cut;
    }
    out.write(source.substring(start, end));
    if (newline >= 0) out.write('\n');
    start = end + 1;
  }
  return out.toString();
}
