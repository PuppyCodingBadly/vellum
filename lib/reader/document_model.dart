/// Lightweight chapter document model for the Flutter reader.
///
/// Parses chapter/section HTML into block-level text runs and inline images,
/// then builds a single [TextSpan] for selection. Character offsets are
/// tracked in two coordinate spaces:
///
/// * document offsets over [plainText] (images contribute nothing);
/// * rendered offsets over [renderedText] (each image contributes one U+FFFC
///   placeholder, matching Flutter's inline-widget selection offsets).
///
/// EPUB/MOBI highlights are stored in document offsets, so images between
/// text runs never shift a saved range.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// An image referenced by a chapter document.
class DocumentImage {
  /// Creates an image reference.
  const DocumentImage({this.path, this.alt = ''});

  /// Absolute filesystem path, or null when the source cannot be resolved
  /// (remote URLs and data URIs are not loaded).
  final String? path;

  /// Alternate text from the HTML `alt` attribute.
  final String alt;
}

/// A highlighted character range in document offsets.
class HighlightRange {
  /// Creates a highlight range.
  const HighlightRange({
    required this.start,
    required this.end,
    required this.color,
  });

  /// Inclusive start offset into [DocumentModel.plainText].
  final int start;

  /// Exclusive end offset into [DocumentModel.plainText].
  final int end;

  /// Background colour for the range.
  final Color color;
}

/// Highlight colours used by the reader (name → colour).
const Map<String, Color> highlightColors = <String, Color>{
  'yellow': Color(0xFFF2D94E),
  'green': Color(0xFFA8E6A3),
  'pink': Color(0xFFF7B6D2),
};

/// Resolves a highlight colour name, defaulting to yellow.
Color highlightColor(String name) =>
    highlightColors[name] ?? highlightColors['yellow']!;

/// Parsed chapter document: plain text, styled span, and offset mappings.
class DocumentModel {
  DocumentModel._(this.plainText, this._segments) {
    _docStart = List<int>.filled(plainText.length + 1, 0);
    _docEnd = List<int>.filled(plainText.length + 1, 0);
    final endSet = List<bool>.filled(plainText.length + 1, false);

    var rendered = 0;
    for (final segment in _segments) {
      rendered += segment is _TextSegment ? segment.text.length : 1;
    }
    renderedLength = rendered;
    _renderedToDoc = List<int>.filled(renderedLength + 1, 0);

    final renderedText = StringBuffer();
    var doc = 0;
    var render = 0;
    for (final segment in _segments) {
      if (segment is _TextSegment) {
        renderedText.write(segment.text);
        for (var i = 0; i <= segment.text.length; i++) {
          _docStart[doc + i] = render + i;
          if (!endSet[doc + i]) {
            _docEnd[doc + i] = render + i;
            endSet[doc + i] = true;
          }
          _renderedToDoc[render + i] = doc + i;
        }
        doc += segment.text.length;
        render += segment.text.length;
      } else if (segment is _ImageSegment) {
        renderedText.write('\uFFFC');
        // A range starting at this boundary begins after the image; a range
        // ending here (first-wins) stays before it.
        _docStart[doc] = render + 1;
        _renderedToDoc[render] = doc;
        _renderedToDoc[render + 1] = doc;
        render += 1;
      }
    }
    _docStart[plainText.length] = renderedLength;
    this.renderedText = renderedText.toString();
  }

  /// Parses [html] into a document. Relative image sources resolve against
  /// [baseDirectory].
  factory DocumentModel.fromHtml(
    String html, {
    required String baseDirectory,
  }) {
    final parsed = html_parser.parse(html);
    final root = parsed.body ?? parsed.documentElement;
    final blocks = <_Block>[];
    if (root != null) {
      for (final node in root.nodes) {
        _collectBlocks(node, blocks, baseDirectory);
      }
    }
    return _assemble(blocks);
  }

  /// Concatenated text of the chapter, with block separators and no image
  /// placeholders.
  final String plainText;

  /// Rendered text of the chapter (`\uFFFC` per image).
  late final String renderedText;

  /// Length of [renderedText].
  late final int renderedLength;

  final List<_Segment> _segments;
  late final List<int> _docStart;
  late final List<int> _docEnd;
  late final List<int> _renderedToDoc;

  /// Images in document order.
  List<DocumentImage> get images => [
        for (final segment in _segments)
          if (segment is _ImageSegment) segment.image,
      ];

  /// Maps a document offset where a selection starts to a rendered offset,
  /// skipping images that precede the text at the same boundary.
  int documentStartToRendered(int offset) {
    final clamped = offset < 0
        ? 0
        : (offset > plainText.length ? plainText.length : offset);
    return _docStart[clamped];
  }

  /// Maps a document offset where a selection ends to a rendered offset,
  /// excluding images that follow the text at the same boundary.
  int documentEndToRendered(int offset) {
    final clamped = offset < 0
        ? 0
        : (offset > plainText.length ? plainText.length : offset);
    return _docEnd[clamped];
  }

  /// Maps a rendered (selection) offset back to a document offset.
  int renderedToDocument(int offset) {
    final clamped = offset < 0
        ? 0
        : (offset > renderedLength ? renderedLength : offset);
    return _renderedToDoc[clamped];
  }

  /// Builds the selectable span for this document.
  ///
  /// [highlights] are document ranges and are painted as background colours;
  /// [maxImageWidth] caps inline image widths.
  TextSpan buildSpan({
    required TextStyle baseStyle,
    Color? linkColor,
    List<HighlightRange> highlights = const <HighlightRange>[],
    double maxImageWidth = 720,
  }) {
    final ranges = <_RenderedRange>[];
    for (final highlight in highlights) {
      if (highlight.end <= highlight.start) continue;
      final start = documentStartToRendered(highlight.start);
      final end = documentEndToRendered(highlight.end);
      if (end <= start) continue;
      ranges.add(_RenderedRange(start, end, highlight.color));
    }

    final children = <InlineSpan>[];
    for (final segment in _segments) {
      if (segment is _ImageSegment) {
        children.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _imageWidget(
            segment.image,
            baseStyle.color,
            maxImageWidth,
          ),
        ));
        continue;
      }
      final text = segment as _TextSegment;
      final start = text.renderedStart;
      final end = start + text.text.length;
      final cuts = <int>{start, end};
      for (final range in ranges) {
        if (range.start > start && range.start < end) cuts.add(range.start);
        if (range.end > start && range.end < end) cuts.add(range.end);
      }
      final boundaries = cuts.toList()..sort();
      final style = _textStyle(text.style, baseStyle, linkColor);
      for (var i = 0; i + 1 < boundaries.length; i++) {
        final from = boundaries[i];
        final to = boundaries[i + 1];
        if (to <= from) continue;
        Color? background;
        for (final range in ranges) {
          if (range.start <= from && to <= range.end) {
            background = range.color;
            break;
          }
        }
        children.add(TextSpan(
          text: text.text.substring(from - start, to - start),
          style: background == null
              ? style
              : style.copyWith(backgroundColor: background),
        ));
      }
    }
    return TextSpan(style: baseStyle, children: children);
  }

  Widget _imageWidget(
    DocumentImage image,
    Color? fallbackColor,
    double maxWidth,
  ) {
    final fallback = SizedBox(
      width: 48,
      height: 48,
      child: Icon(Icons.broken_image_outlined, color: fallbackColor),
    );
    final path = image.path;
    if (path == null) return fallback;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        semanticLabel: image.alt.isEmpty ? null : image.alt,
        errorBuilder: (context, error, stackTrace) => fallback,
      ),
    );
  }

  static const List<double> _headingScale = <double>[
    0,
    2.0,
    1.6,
    1.35,
    1.2,
    1.1,
    1.0,
  ];

  TextStyle _textStyle(
    _RunStyle run,
    TextStyle base,
    Color? linkColor,
  ) {
    final decorations = <TextDecoration>[
      if (run.underline) TextDecoration.underline,
      if (run.lineThrough) TextDecoration.lineThrough,
    ];
    var style = TextStyle(
      fontWeight:
          run.bold || run.heading > 0 ? FontWeight.bold : FontWeight.normal,
      fontStyle:
          run.italic || run.quote ? FontStyle.italic : FontStyle.normal,
      decoration:
          decorations.isEmpty ? null : TextDecoration.combine(decorations),
      fontFamily: run.code || run.pre ? 'monospace' : null,
    );
    if (run.heading > 0 && base.fontSize != null) {
      style = style.copyWith(
        fontSize: base.fontSize! * _headingScale[run.heading],
      );
    }
    if (run.link) {
      style = style.copyWith(
        color: linkColor ?? base.color,
        decoration: TextDecoration.underline,
      );
    }
    return style;
  }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const Set<String> _blockTags = <String>{
  'address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt',
  'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'header', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table',
  'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul',
};

const Set<String> _skipTags = <String>{
  'head', 'link', 'meta', 'script', 'style', 'title',
};

void _collectBlocks(dom.Node node, List<_Block> out, String baseDirectory) {
  if (node is dom.Text) {
    if (node.data.trim().isEmpty) return;
    _addBlock(
      out,
      _normalize(<_RawFragment>[_RawText(node.data, const _RunStyle())]),
    );
    return;
  }
  if (node is! dom.Element) return;
  final tag = (node.localName ?? '').toLowerCase();
  if (_skipTags.contains(tag)) return;

  if (tag.length == 2 && tag[0] == 'h') {
    final level = int.tryParse(tag.substring(1));
    if (level != null && level >= 1 && level <= 6) {
      _addBlock(
        out,
        _normalize(
          _inline(node, _RunStyle(heading: level), baseDirectory),
        ),
      );
      return;
    }
  }

  switch (tag) {
    case 'p':
      _addBlock(
        out,
        _normalize(_inline(node, const _RunStyle(), baseDirectory)),
      );
      break;
    case 'blockquote':
      _addBlock(
        out,
        _normalize(
          _inline(node, const _RunStyle(quote: true), baseDirectory),
        ),
      );
      break;
    case 'pre':
      _addBlock(
        out,
        _normalize(
          <_RawFragment>[
            _RawText(node.text, const _RunStyle(pre: true, code: true)),
          ],
          pre: true,
        ),
      );
      break;
    case 'ul':
    case 'ol':
      for (final child in node.nodes) {
        _collectBlocks(child, out, baseDirectory);
      }
      break;
    case 'li':
      _addBlock(
        out,
        _normalize(_inline(node, const _RunStyle(), baseDirectory)),
      );
      break;
    case 'img':
      final image = _image(node, baseDirectory);
      if (image != null) _addBlock(out, <_Fragment>[_ImageFragment(image)]);
      break;
    case 'tr':
      _addBlock(
        out,
        _normalize(_inline(node, const _RunStyle(), baseDirectory)),
      );
      break;
    case 'table':
    case 'tbody':
    case 'thead':
    case 'tfoot':
      for (final child in node.nodes) {
        _collectBlocks(child, out, baseDirectory);
      }
      break;
    case 'body':
    case 'html':
    case 'div':
    case 'section':
    case 'article':
    case 'header':
    case 'footer':
    case 'main':
    case 'aside':
    case 'nav':
    case 'figure':
    case 'figcaption':
    case 'dl':
    case 'dd':
    case 'dt':
      _container(node, out, baseDirectory);
      break;
    case 'br':
    case 'hr':
      return;
    default:
      _addBlock(
        out,
        _normalize(_inline(node, const _RunStyle(), baseDirectory)),
      );
      break;
  }
}

void _container(dom.Element element, List<_Block> out, String baseDirectory) {
  if (_containsBlock(element)) {
    for (final child in element.nodes) {
      _collectBlocks(child, out, baseDirectory);
    }
  } else {
    _addBlock(
      out,
      _normalize(_inline(element, const _RunStyle(), baseDirectory)),
    );
  }
}

bool _containsBlock(dom.Element element) {
  for (final child in element.children) {
    final tag = (child.localName ?? '').toLowerCase();
    if (_blockTags.contains(tag)) return true;
    if (_containsBlock(child)) return true;
  }
  return false;
}

List<_RawFragment> _inline(
  dom.Node node,
  _RunStyle style,
  String baseDirectory,
) {
  final out = <_RawFragment>[];
  _walkInline(node, style, baseDirectory, out);
  return out;
}

void _walkInline(
  dom.Node current,
  _RunStyle style,
  String baseDirectory,
  List<_RawFragment> out,
) {
  if (current is dom.Text) {
    out.add(_RawText(current.data, style));
    return;
  }
  if (current is! dom.Element) return;
  final tag = (current.localName ?? '').toLowerCase();
  if (_skipTags.contains(tag)) return;

  switch (tag) {
    case 'br':
      out.add(const _RawBreak());
      break;
    case 'img':
      final image = _image(current, baseDirectory);
      if (image != null) out.add(_RawImage(image));
      break;
    case 'b':
    case 'strong':
      _walkInlineChildren(current, style.copyWith(bold: true), baseDirectory, out);
      break;
    case 'i':
    case 'em':
      _walkInlineChildren(current, style.copyWith(italic: true), baseDirectory, out);
      break;
    case 'u':
    case 'ins':
      _walkInlineChildren(current, style.copyWith(underline: true), baseDirectory, out);
      break;
    case 's':
    case 'strike':
    case 'del':
      _walkInlineChildren(current, style.copyWith(lineThrough: true), baseDirectory, out);
      break;
    case 'code':
    case 'kbd':
    case 'samp':
      _walkInlineChildren(current, style.copyWith(code: true), baseDirectory, out);
      break;
    case 'a':
      _walkInlineChildren(current, style.copyWith(link: true), baseDirectory, out);
      break;
    case 'pre':
      out.add(_RawText(
        current.text,
        style.copyWith(pre: true, code: true),
      ));
      break;
    case 'td':
    case 'th':
      out.add(_RawText(' ', style));
      _walkInlineChildren(current, style, baseDirectory, out);
      break;
    case 'p':
    case 'div':
    case 'section':
    case 'article':
    case 'blockquote':
    case 'li':
    case 'ul':
    case 'ol':
    case 'tr':
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
    case 'table':
      out.add(const _RawBreak());
      _walkInlineChildren(current, style, baseDirectory, out);
      out.add(const _RawBreak());
      break;
    default:
      _walkInlineChildren(current, style, baseDirectory, out);
      break;
  }
}

void _walkInlineChildren(
  dom.Element element,
  _RunStyle style,
  String baseDirectory,
  List<_RawFragment> out,
) {
  for (final child in element.nodes) {
    _walkInline(child, style, baseDirectory, out);
  }
}

DocumentImage? _image(dom.Element element, String baseDirectory) {
  final source = (element.attributes['src'] ?? '').trim();
  if (source.isEmpty) return null;
  return DocumentImage(
    path: _resolveImagePath(source, baseDirectory),
    alt: (element.attributes['alt'] ?? '').trim(),
  );
}

String? _resolveImagePath(String source, String baseDirectory) {
  final hash = source.indexOf('#');
  final clean = hash < 0 ? source : source.substring(0, hash);
  if (clean.isEmpty) return null;
  final uri = Uri.tryParse(clean);
  if (uri != null) {
    if (uri.scheme == 'file') {
      try {
        return uri.toFilePath();
      } on UnsupportedError {
        return null;
      }
    }
    if (uri.hasScheme) return null;
  }
  var path = clean;
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    // Keep the raw path when percent-decoding fails.
  }
  if (path.isEmpty) return null;
  if (path.startsWith('/')) return path;
  return '$baseDirectory/$path';
}

// ---------------------------------------------------------------------------
// Inline whitespace normalisation
// ---------------------------------------------------------------------------

List<_Fragment> _normalize(List<_RawFragment> raw, {bool pre = false}) {
  final out = <_Fragment>[];
  final buffer = StringBuffer();
  _RunStyle? bufferStyle;
  var pendingSpace = false;

  void flush() {
    if (buffer.isEmpty) return;
    out.add(_TextFragment(
      buffer.toString(),
      bufferStyle ?? const _RunStyle(),
    ));
    buffer.clear();
    bufferStyle = null;
  }

  void append(String text, _RunStyle style) {
    if (text.isEmpty) return;
    if (bufferStyle != style) {
      flush();
      bufferStyle = style;
    }
    buffer.write(text);
  }

  bool hasContent() {
    if (buffer.isNotEmpty) return true;
    for (final fragment in out) {
      if (fragment is _ImageFragment) return true;
      if (fragment is _TextFragment && fragment.text.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  for (final fragment in raw) {
    if (fragment is _RawText) {
      // A <pre> nested inside an inline container (blockquote/li/td) is
      // recorded on the run style; honor it even when the container called
      // _normalize with pre: false.
      if (pre || fragment.style.pre) {
        append(
          fragment.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
          fragment.style,
        );
        continue;
      }
      final text = fragment.text;
      var chunkStart = -1;
      for (var i = 0; i < text.length; i++) {
        final code = text.codeUnitAt(i);
        if (_isWhitespace(code)) {
          if (chunkStart >= 0) {
            append(text.substring(chunkStart, i), fragment.style);
            chunkStart = -1;
          }
          pendingSpace = true;
        } else {
          if (pendingSpace) {
            if (hasContent()) append(' ', fragment.style);
            pendingSpace = false;
          }
          if (chunkStart < 0) chunkStart = i;
        }
      }
      if (chunkStart >= 0) {
        append(text.substring(chunkStart), fragment.style);
      }
    } else if (fragment is _RawBreak) {
      pendingSpace = false;
      append('\n', const _RunStyle());
    } else if (fragment is _RawImage) {
      if (pendingSpace && hasContent()) {
        append(' ', const _RunStyle());
      }
      pendingSpace = false;
      flush();
      out.add(_ImageFragment(fragment.image));
    }
  }
  flush();
  _trimEdges(out);
  return out;
}

void _trimEdges(List<_Fragment> fragments) {
  while (fragments.isNotEmpty) {
    final first = fragments.first;
    if (first is _TextFragment) {
      final trimmed = first.text.replaceFirst(RegExp(r'^\s+'), '');
      if (trimmed.isEmpty) {
        fragments.removeAt(0);
        continue;
      }
      fragments[0] = _TextFragment(trimmed, first.style);
    }
    break;
  }
  while (fragments.isNotEmpty) {
    final last = fragments.last;
    if (last is _TextFragment) {
      final trimmed = last.text.replaceFirst(RegExp(r'\s+$'), '');
      if (trimmed.isEmpty) {
        fragments.removeLast();
        continue;
      }
      fragments[fragments.length - 1] = _TextFragment(trimmed, last.style);
    }
    break;
  }
}

bool _isWhitespace(int code) =>
    code == 0x20 ||
    code == 0x09 ||
    code == 0x0A ||
    code == 0x0B ||
    code == 0x0C ||
    code == 0x0D;

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

void _addBlock(List<_Block> blocks, List<_Fragment> fragments) {
  if (fragments.isEmpty) return;
  blocks.add(_Block(fragments));
}

DocumentModel _assemble(List<_Block> blocks) {
  final segments = <_Segment>[];
  final plain = StringBuffer();
  var documentOffset = 0;
  var renderedOffset = 0;
  var first = true;

  for (final block in blocks) {
    if (block.fragments.isEmpty) continue;
    if (!first) {
      segments.add(_TextSegment(
        '\n\n',
        const _RunStyle(),
        documentOffset,
        renderedOffset,
      ));
      plain.write('\n\n');
      documentOffset += 2;
      renderedOffset += 2;
    }
    first = false;
    for (final fragment in block.fragments) {
      if (fragment is _TextFragment) {
        segments.add(_TextSegment(
          fragment.text,
          fragment.style,
          documentOffset,
          renderedOffset,
        ));
        plain.write(fragment.text);
        documentOffset += fragment.text.length;
        renderedOffset += fragment.text.length;
      } else if (fragment is _ImageFragment) {
        segments.add(_ImageSegment(
          fragment.image,
          documentOffset,
          renderedOffset,
        ));
        renderedOffset += 1;
      }
    }
  }
  return DocumentModel._(plain.toString(), segments);
}

// ---------------------------------------------------------------------------
// Internal model
// ---------------------------------------------------------------------------

class _RunStyle {
  const _RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.lineThrough = false,
    this.code = false,
    this.link = false,
    this.heading = 0,
    this.quote = false,
    this.pre = false,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool lineThrough;
  final bool code;
  final bool link;
  final int heading;
  final bool quote;
  final bool pre;

  _RunStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? lineThrough,
    bool? code,
    bool? link,
    int? heading,
    bool? quote,
    bool? pre,
  }) {
    return _RunStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      lineThrough: lineThrough ?? this.lineThrough,
      code: code ?? this.code,
      link: link ?? this.link,
      heading: heading ?? this.heading,
      quote: quote ?? this.quote,
      pre: pre ?? this.pre,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _RunStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.lineThrough == lineThrough &&
      other.code == code &&
      other.link == link &&
      other.heading == heading &&
      other.quote == quote &&
      other.pre == pre;

  @override
  int get hashCode => Object.hash(
        bold,
        italic,
        underline,
        lineThrough,
        code,
        link,
        heading,
        quote,
        pre,
      );
}

sealed class _RawFragment {
  const _RawFragment();
}

class _RawText extends _RawFragment {
  const _RawText(this.text, this.style);
  final String text;
  final _RunStyle style;
}

class _RawBreak extends _RawFragment {
  const _RawBreak();
}

class _RawImage extends _RawFragment {
  const _RawImage(this.image);
  final DocumentImage image;
}

sealed class _Fragment {
  const _Fragment();
}

class _TextFragment extends _Fragment {
  const _TextFragment(this.text, this.style);
  final String text;
  final _RunStyle style;
}

class _ImageFragment extends _Fragment {
  const _ImageFragment(this.image);
  final DocumentImage image;
}

class _Block {
  const _Block(this.fragments);
  final List<_Fragment> fragments;
}

sealed class _Segment {
  const _Segment(this.documentStart, this.renderedStart);
  final int documentStart;
  final int renderedStart;
}

class _TextSegment extends _Segment {
  const _TextSegment(
    this.text,
    this.style,
    super.documentStart,
    super.renderedStart,
  );
  final String text;
  final _RunStyle style;
}

class _ImageSegment extends _Segment {
  const _ImageSegment(
    this.image,
    super.documentStart,
    super.renderedStart,
  );
  final DocumentImage image;
}

class _RenderedRange {
  const _RenderedRange(this.start, this.end, this.color);
  final int start;
  final int end;
  final Color color;
}
