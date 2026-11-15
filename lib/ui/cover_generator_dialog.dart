/// "Generate Cover" dialog: picks a typographic treatment and previews the
/// exact PNG the details page will save.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/cover_generator.dart';
import '../core/models.dart';
import 'theme.dart';

class CoverGeneratorDialog extends StatefulWidget {
  const CoverGeneratorDialog({super.key, required this.book});

  final Book book;

  @override
  State<CoverGeneratorDialog> createState() => _CoverGeneratorDialogState();
}

class _CoverGeneratorDialogState extends State<CoverGeneratorDialog> {
  static const int _previewWidth = 260;
  static const int _previewHeight = 390;

  CoverStyle _style = CoverStyle.paper;
  late Future<Uint8List> _preview;

  @override
  void initState() {
    super.initState();
    _preview = _render();
  }

  Future<Uint8List> _render() => generateCoverPng(
        title: widget.book.title,
        author: widget.book.authors.join(', '),
        publisher: widget.book.publisher,
        style: _style,
        width: _previewWidth,
        height: _previewHeight,
      );

  void _selectStyle(CoverStyle style) {
    if (style == _style) return;
    setState(() {
      _style = style;
      _preview = _render();
    });
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
    final authors =
        book.authors.isEmpty ? 'Unknown author' : book.authors.join(', ');

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
                    onPressed: () async {
                      final png = await _preview;
                      if (context.mounted) Navigator.of(context).pop(png);
                    },
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
    return Container(
      width: _previewWidth.toDouble(),
      decoration: BoxDecoration(
        borderRadius: VellumRadius.smallAll,
        border: Border.all(color: palette.line),
        boxShadow: [palette.coverShadow(hovered: false)],
      ),
      child: ClipRRect(
        borderRadius: VellumRadius.smallAll,
        child: AspectRatio(
          aspectRatio: _previewWidth / _previewHeight,
          child: FutureBuilder<Uint8List>(
            future: _preview,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
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
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              );
            },
          ),
        ),
      ),
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
