/// "Generate Cover" dialog: picks a typographic treatment and previews the
/// exact PNG the details page will save.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/cover_generator.dart';
import '../core/models.dart';
import 'theme.dart';

/// Renders the cover PNG the dialog previews and pops.
///
/// The dialog renders once per style at the artifact size, so the preview and
/// the file are the same bytes; the seam exists so tests can drive the failure
/// and in-flight states without a broken rasteriser.
typedef CoverRenderer =
    Future<Uint8List> Function({
      required String title,
      required String author,
      required String publisher,
      required CoverStyle style,
      required int width,
      required int height,
    });

class CoverGeneratorDialog extends StatefulWidget {
  const CoverGeneratorDialog({
    super.key,
    required this.book,
    this.renderCover = generateCoverPng,
  });

  final Book book;
  final CoverRenderer renderCover;

  @override
  State<CoverGeneratorDialog> createState() => _CoverGeneratorDialogState();
}

class _CoverGeneratorDialogState extends State<CoverGeneratorDialog> {
  /// The displayed size of the preview. The artifact behind it is rendered at
  /// [kGeneratedCoverWidth]×[kGeneratedCoverHeight] and only decoded down to
  /// this size, so nothing is rendered twice.
  static const double _previewWidth = 260;
  static const double _previewHeight = 390;

  CoverStyle _style = CoverStyle.paper;

  /// The single render for the current [_style].
  Uint8List? _coverPng;

  /// True when the last render failed; the preview then offers a retry.
  bool _renderFailed = false;

  /// Set while "Use Cover" is on its way out, so a second tap cannot pop the
  /// details page as well.
  bool _confirming = false;

  /// Guards against a slow render for a style the user already left.
  int _renderGeneration = 0;

  @override
  void initState() {
    super.initState();
    _renderCover();
  }

  void _renderCover() {
    final generation = ++_renderGeneration;
    _coverPng = null;
    _renderFailed = false;
    final render = widget.renderCover(
      title: widget.book.title,
      author: widget.book.authors.join(', '),
      publisher: widget.book.publisher,
      style: _style,
      width: kGeneratedCoverWidth,
      height: kGeneratedCoverHeight,
    );
    render.then(
      (png) {
        if (!mounted || generation != _renderGeneration) return;
        setState(() => _coverPng = png);
      },
      onError: (Object _) {
        if (!mounted || generation != _renderGeneration) return;
        setState(() => _renderFailed = true);
      },
    );
  }

  void _selectStyle(CoverStyle style) {
    if (style == _style) return;
    setState(() {
      _style = style;
      _renderCover();
    });
  }

  void _retry() {
    setState(_renderCover);
  }

  void _useCover() {
    final cover = _coverPng;
    if (cover == null || _confirming) return;
    // The flag, not the disabled button, is the guard: a second tap in the same
    // frame still reaches the previous callback, and popping twice would take
    // the details page with it.
    setState(() => _confirming = true);
    Navigator.of(context).pop(cover);
  }

  String get _styleNote => switch (_style) {
    CoverStyle.paper => 'Warm stock, ink type, one copper rule.',
    CoverStyle.ink => 'Night stock, paper type, a warm rule.',
    CoverStyle.accent => 'Full copper stock with dark type.',
    CoverStyle.cloth => 'Bound-cloth teal with cream type.',
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final book = widget.book;
    final title = book.title.trim().isEmpty ? 'Untitled' : book.title.trim();
    final authors = book.authors.isEmpty
        ? 'Unknown author'
        : book.authors.join(', ');

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Generate Cover',
                      style: VellumType.display(
                        22,
                        weight: FontWeight.w600,
                        height: 1.2,
                        color: palette.text,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.line),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final preview = _previewPane(palette);
                    final options = _optionPane(palette, title, authors);
                    if (constraints.maxWidth < 480) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: preview),
                          const SizedBox(height: VellumSpace.lg),
                          options,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        preview,
                        const SizedBox(width: VellumSpace.xl),
                        Expanded(child: options),
                      ],
                    );
                  },
                ),
              ),
            ),
            Divider(height: 1, color: palette.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: VellumSpace.xs),
                  FilledButton(
                    onPressed: _coverPng == null || _confirming
                        ? null
                        : _useCover,
                    child: const Text('Use Cover'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewPane(VellumPalette palette) {
    final cacheWidth = (_previewWidth * MediaQuery.devicePixelRatioOf(context))
        .round();
    return Container(
      width: _previewWidth,
      decoration: BoxDecoration(
        borderRadius: VellumRadius.smallAll,
        border: Border.all(color: palette.line),
        boxShadow: [palette.coverShadow(hovered: false)],
      ),
      child: ClipRRect(
        borderRadius: VellumRadius.smallAll,
        child: AspectRatio(
          aspectRatio: _previewWidth / _previewHeight,
          child: _previewBody(palette, cacheWidth),
        ),
      ),
    );
  }

  Widget _previewBody(VellumPalette palette, int cacheWidth) {
    final cover = _coverPng;
    if (_renderFailed) {
      return ColoredBox(
        color: palette.surfaceHigh,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(VellumSpace.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.broken_image_outlined,
                  size: 26,
                  color: palette.textDim,
                ),
                const SizedBox(height: VellumSpace.xs),
                Text(
                  "Couldn't draw the cover.",
                  textAlign: TextAlign.center,
                  style: VellumType.ui(12, height: 1.4, color: palette.textDim),
                ),
                const SizedBox(height: VellumSpace.xxs),
                TextButton(onPressed: _retry, child: const Text('Try Again')),
              ],
            ),
          ),
        ),
      );
    }
    if (cover == null) {
      return ColoredBox(
        color: palette.surfaceHigh,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.textDim,
            ),
          ),
        ),
      );
    }
    return Image.memory(
      cover,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // The artifact is 1200×1800; decode no larger than the preview shows.
      cacheWidth: cacheWidth,
    );
  }

  Widget _optionPane(VellumPalette palette, String title, String authors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: VellumType.display(
            17,
            weight: FontWeight.w500,
            height: 1.3,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          authors,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: VellumType.ui(12.5, height: 1.4, color: palette.textDim),
        ),
        const SizedBox(height: VellumSpace.lg),
        Text(
          'Style',
          style: VellumType.ui(
            10.5,
            weight: FontWeight.w600,
            height: 1.2,
            color: palette.textDim,
          ),
        ),
        const SizedBox(height: VellumSpace.xs),
        Wrap(
          spacing: VellumSpace.xs,
          runSpacing: VellumSpace.xs,
          children: [
            for (final style in CoverStyle.values)
              ChoiceChip(
                label: Text(style.label),
                selected: _style == style,
                onSelected: (_) => _selectStyle(style),
              ),
          ],
        ),
        const SizedBox(height: VellumSpace.sm),
        Text(
          _styleNote,
          style: VellumType.ui(12, height: 1.45, color: palette.textDim),
        ),
        const SizedBox(height: VellumSpace.lg),
        Text(
          'Drawn locally from the title, author, and publisher with the '
          'bundled typefaces. Nothing is downloaded or sent anywhere.',
          style: VellumType.ui(12, height: 1.45, color: palette.textDim),
        ),
      ],
    );
  }
}
