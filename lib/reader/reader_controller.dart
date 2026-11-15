/// Reader state: format opening, navigation, persistence, highlights, PDF.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/ink.dart';
import '../core/models.dart';
import '../formats/dictionary.dart' as dictionary;
import '../formats/epub.dart';
import '../formats/mobi.dart';
import '../formats/pdf_book.dart';
import '../formats/pdf_reflow.dart';
import '../stats/reading_stats.dart';
import 'document_model.dart';

const double _minFontScale = 0.8;
const double _maxFontScale = 1.6;
const double _minZoom = 1.0;
const double _maxZoom = 3.0;
const double _zoomStep = 0.25;
const int _pdfCacheSize = 3;
const Duration _scrollSaveInterval = Duration(seconds: 1);

/// Supported reader formats, in primary-format priority order.
enum ReaderFormat { epub, pdf, mobi }

/// One navigable item: an EPUB chapter, a MOBI section, or a PDF page.
class ReaderItem {
  /// Creates a reader item.
  const ReaderItem({required this.key, required this.title});

  /// EPUB chapter href (empty for MOBI/PDF).
  final String key;

  /// Display title.
  final String title;
}

/// A persisted highlight, in document character offsets.
class ReaderHighlight {
  /// Creates a highlight.
  const ReaderHighlight({
    required this.id,
    required this.chapter,
    required this.start,
    required this.end,
    required this.color,
    required this.quote,
    required this.text,
  });

  final int id;

  /// Item (chapter/section) index the range belongs to.
  final int chapter;

  /// Inclusive document offset.
  final int start;

  /// Exclusive document offset.
  final int end;

  /// Colour name (`yellow`, `green`, `pink`).
  final String color;

  /// Short quote stored with the position.
  final String quote;

  /// Full selected text.
  final String text;

  /// Parses a `listHighlights` row, returning null when the position JSON is
  /// unusable.
  static ReaderHighlight? fromRow(Map<String, Object?> row) {
    final id = row['id'];
    if (id is! num) return null;
    var position = <String, Object?>{};
    final raw = row['position'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          position = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } on FormatException {
        return null;
      }
    }
    final chapter = position['chapter'];
    final start = position['start'];
    final end = position['end'];
    if (chapter is! num || start is! num || end is! num) return null;
    final textValue = row['text'];
    final text = textValue is String ? textValue : '';
    final quoteValue = position['quote'];
    final quote = quoteValue is String ? quoteValue : text;
    final colorValue = row['color'];
    return ReaderHighlight(
      id: id.toInt(),
      chapter: chapter.toInt(),
      start: start.toInt(),
      end: end.toInt(),
      color: colorValue is String ? colorValue : 'yellow',
      quote: quote,
      text: text,
    );
  }
}

/// Owns one open book: format selection, content, navigation, position,
/// highlights, and PDF page rendering.
class ReaderController extends ChangeNotifier {
  /// Opens [book] through [library].
  ///
  /// [stats] receives a reading session for the time the reader is open.
  /// When [initialChapter] is valid it overrides the saved position.
  ReaderController({
    required this.book,
    required Library library,
    required ReadingStatsTracker stats,
    this.initialChapter,
    bool pdfReflow = false,
    void Function(String message)? onToast,
  }) : _library = library,
       _stats = stats,
       _onToast = onToast,
       _kind = _selectFormat(book),
       _pdfWorker = _PdfWorker(book.path),
       _pdfReflow = pdfReflow,
       _zoom = defaultScale;

  /// The book being read.
  final Book book;

  /// Chapter requested by the caller, if any.
  final int? initialChapter;

  final Library _library;
  final ReadingStatsTracker _stats;
  final void Function(String message)? _onToast;
  final ReaderFormat _kind;
  final _PdfWorker _pdfWorker;

  final List<ReaderItem> _items = <ReaderItem>[];
  final List<ReaderHighlight> _highlights = <ReaderHighlight>[];
  final Map<int, Uint8List> _pdfCache = <int, Uint8List>{};
  final Map<int, PdfReflowPage> _pdfReflowCache = <int, PdfReflowPage>{};

  int _index = 0;
  int _direction = 0;
  int _documentSerial = 0;
  double _lastFraction = 0.0;
  double? _pendingScrollFraction;
  int? _pendingJumpOffset;
  double _fontScale = 1.0;
  double _zoom;
  int _pdfSerial = 0;
  int _pdfReflowSerial = 0;
  bool _pdfPageLoading = false;
  bool _pdfReflowLoading = false;
  bool _pdfReflow;
  String? _pdfRenderError;
  String? _pdfReflowError;
  bool _loaded = false;
  int? _sessionBookId;
  bool _disposed = false;
  String? _cacheDir;
  String? _error;
  bool _loading = true;
  DocumentModel? _document;
  EpubBook? _epub;
  MobiBook? _mobi;
  PdfBook? _pdf;
  DateTime _lastPositionWrite = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _saveTimer;

  final List<InkStroke> _inkStrokes = <InkStroke>[];
  final List<_InkOperation> _inkUndo = <_InkOperation>[];
  final List<_InkOperation> _inkRedo = <_InkOperation>[];
  bool _inkMode = false;
  InkTool _inkTool = InkTool.pen;
  int _inkColor = 0xFF1F1B16;
  double _inkWidth = 2.0;

  /// Reader format chosen for this book.
  ReaderFormat get kind => _kind;

  /// True for PDF books.
  bool get isPdf => _kind == ReaderFormat.pdf;

  /// Highlights and dictionary lookup are available for EPUB/MOBI only.
  bool get supportsHighlights => !isPdf;

  /// Narrative items (chapters/sections/pages).
  List<ReaderItem> get items => List<ReaderItem>.unmodifiable(_items);

  /// Current item index.
  int get index => _index;

  /// Direction of the last navigation: 1 forward, -1 backward, 0 none.
  int get direction => _direction;

  /// Increments whenever a new chapter document is parsed.
  int get documentSerial => _documentSerial;

  /// Current chapter document (EPUB/MOBI), or null for PDF.
  DocumentModel? get document => _document;

  /// True while the book is being opened.
  bool get loading => _loading;

  /// Open failure title, or null.
  String? get error => _error;

  /// True when the book could not be opened.
  bool get hasError => _error != null;

  /// All highlights for the book.
  List<ReaderHighlight> get highlights =>
      List<ReaderHighlight>.unmodifiable(_highlights);

  /// Highlights on the current item.
  List<ReaderHighlight> get currentHighlights => [
    for (final highlight in _highlights)
      if (highlight.chapter == _index) highlight,
  ];

  /// Current highlights converted to renderable ranges.
  List<HighlightRange> get currentHighlightRanges => [
    for (final highlight in _highlights)
      if (highlight.chapter == _index && highlight.end > highlight.start)
        HighlightRange(
          start: highlight.start,
          end: highlight.end,
          color: highlightColor(highlight.color),
        ),
  ];

  /// True while ink strokes are being drawn over the page.
  bool get inkMode => _inkMode;

  /// Active ink tool (pen or eraser).
  InkTool get inkTool => _inkTool;

  /// Active ink colour, ARGB.
  int get inkColor => _inkColor;

  /// Active ink width in logical pixels.
  double get inkWidth => _inkWidth;

  /// Strokes belonging to the current item.
  List<InkStroke> get inkStrokes => List<InkStroke>.unmodifiable(_inkStrokes);

  /// Whether an undoable ink operation exists in this session.
  bool get canUndoInk => _inkUndo.isNotEmpty;

  /// Whether a redoable ink operation exists in this session.
  bool get canRedoInk => _inkRedo.isNotEmpty;

  /// Turns ink capture on or off.
  void setInkMode(bool enabled) {
    if (_inkMode == enabled) return;
    _inkMode = enabled;
    notifyListeners();
  }

  /// Selects the pen or the eraser.
  void setInkTool(InkTool tool) {
    if (_inkTool == tool) return;
    _inkTool = tool;
    notifyListeners();
  }

  /// Selects the ink colour from an ARGB value.
  void setInkColor(int argb) {
    if (_inkColor == argb) return;
    _inkColor = argb;
    notifyListeners();
  }

  /// Selects the ink width in logical pixels.
  void setInkWidth(double width) {
    if (!width.isFinite || width <= 0) return;
    if ((_inkWidth - width).abs() < 1e-9) return;
    _inkWidth = width;
    notifyListeners();
  }

  /// Loads the current item's strokes and forgets this chapter's undo history.
  ///
  /// Called after opening and on every chapter change; callers notify, so it
  /// does not notify itself.
  void loadInk() {
    _inkStrokes.clear();
    _inkUndo.clear();
    _inkRedo.clear();
    final bookId = book.id;
    if (bookId == null) return;
    try {
      _inkStrokes.addAll(_library.listInkStrokes(bookId, _index));
    } catch (_) {
      _inkStrokes.clear();
    }
  }

  /// Persists [stroke] on the current item and returns its row id.
  ///
  /// A book without an id keeps the stroke for the session and returns -1.
  /// A failed write reports a toast and returns -1 without changing the page.
  int addInkStroke(InkStroke stroke) {
    final bookId = book.id;
    var id = -1;
    if (bookId != null) {
      try {
        id = _library.addInkStroke(bookId, stroke);
      } catch (_) {
        _onToast?.call('Could not save ink');
        return -1;
      }
    }
    _inkStrokes.add(stroke);
    _inkUndo.add(_InkOperation.add(stroke));
    _inkRedo.clear();
    notifyListeners();
    return id;
  }

  /// Removes [stroke] from the current item and deletes its row.
  void eraseInkStroke(InkStroke stroke) {
    final at = _inkStrokes.indexWhere(
      (candidate) =>
          identical(candidate, stroke) ||
          (stroke.id != null && candidate.id == stroke.id),
    );
    if (at < 0) return;
    final removed = _inkStrokes.removeAt(at);
    final id = removed.id;
    if (id != null) {
      try {
        _library.deleteInkStroke(id);
      } catch (_) {
        // The row may already be gone; the page must still drop the stroke.
      }
    }
    _inkUndo.add(_InkOperation.erase(removed));
    _inkRedo.clear();
    notifyListeners();
  }

  /// Reverses the last ink add or erase of this session.
  void undoInk() {
    if (_inkUndo.isEmpty) return;
    final operation = _inkUndo.last;
    if (!_applyInkOperation(operation, undo: true)) return;
    _inkUndo.removeLast();
    _inkRedo.add(operation);
    notifyListeners();
  }

  /// Re-applies the last ink operation undone in this session.
  void redoInk() {
    if (_inkRedo.isEmpty) return;
    final operation = _inkRedo.last;
    if (!_applyInkOperation(operation, undo: false)) return;
    _inkRedo.removeLast();
    _inkUndo.add(operation);
    notifyListeners();
  }

  /// All page-anchored strokes of this book, across pages, for export.
  List<InkStroke> pageInkStrokes() {
    final bookId = book.id;
    if (bookId == null) return const <InkStroke>[];
    try {
      return [
        for (final stroke in _library.listInkStrokesForBook(bookId))
          if (stroke.anchor.kind == InkAnchorKind.page) stroke,
      ];
    } catch (_) {
      return const <InkStroke>[];
    }
  }

  bool _applyInkOperation(_InkOperation operation, {required bool undo}) {
    final adding = operation.isAdd != undo;
    if (adding) {
      final bookId = book.id;
      if (bookId != null) {
        try {
          _library.addInkStroke(bookId, operation.stroke);
        } catch (_) {
          _onToast?.call('Could not save ink');
          return false;
        }
      }
      _inkStrokes.add(operation.stroke);
      return true;
    }
    final at = _inkStrokes.indexOf(operation.stroke);
    if (at >= 0) _inkStrokes.removeAt(at);
    final id = operation.stroke.id;
    if (id != null) {
      try {
        _library.deleteInkStroke(id);
      } catch (_) {
        // A missing row still means the stroke is gone from the page.
      }
    }
    return true;
  }

  /// Reader text scale (0.8–1.6).
  double get fontScale => _fontScale;

  /// PDF zoom scale (1.0–3.0; starts at the 1.75 render scale).
  double get pdfZoom => _zoom;

  /// Current PDF page PNG, or null while rendering/uncached.
  Uint8List? get pdfPageBytes => isPdf ? _pdfCache[_index] : null;

  /// True while the current PDF page is still rendering.
  bool get pdfPageLoading => isPdf && _pdfPageLoading;

  /// Human-readable reason the current PDF page failed to render, if any.
  String? get pdfRenderError => isPdf ? _pdfRenderError : null;

  /// Whether PDF pages are laid out as reflowed text.
  bool get pdfReflow => isPdf && _pdfReflow;

  /// Layout for the current PDF page, or null while it is being built.
  PdfReflowPage? get pdfReflowPage =>
      isPdf && _pdfReflow ? _pdfReflowCache[_index] : null;

  /// True while the current reflow layout is still being built.
  bool get pdfReflowLoading => isPdf && _pdfReflow && _pdfReflowLoading;

  /// Human-readable reason reflow failed for the current page, if any.
  String? get pdfReflowError => isPdf && _pdfReflow ? _pdfReflowError : null;

  /// Switches PDF pages between the page bitmap and reflowed text.
  ///
  /// The page bitmap stays available for pages with no text layer, and the
  /// font size changes only re-lay out sprites; it does not refetch a page.
  void setPdfReflow(bool enabled) {
    if (isPdf && _pdfReflow == enabled) return;
    _pdfReflow = enabled;
    if (isPdf) {
      if (enabled) {
        _renderPdfReflow();
      } else {
        _pdfReflowLoading = false;
        _pdfReflowError = null;
        _pdfReflowCache.clear();
        _renderPdf();
      }
    }
    notifyListeners();
  }

  /// Title of the current item.
  String get itemTitle {
    if (_items.isEmpty) return book.title;
    return _items[_index].title;
  }

  /// Counter label (`2 / 30`, `Section 2 / 30`, `Page 3 / 120`).
  String get counter {
    if (_items.isEmpty) return '';
    final prefix = switch (_kind) {
      ReaderFormat.pdf => 'Page ',
      ReaderFormat.mobi => 'Section ',
      ReaderFormat.epub => '',
    };
    return '$prefix${_index + 1} / ${_items.length}';
  }

  /// Fraction read through the book, including the position inside the
  /// current section: `(index + scrollFraction) / count`.
  double get progress {
    if (_items.isEmpty) return 0;
    final within = isPdf ? 1.0 : _lastFraction.clamp(0.0, 1.0).toDouble();
    return ((_index + within) / _items.length).clamp(0.0, 1.0).toDouble();
  }

  /// Locator persisted for this book (`<kind>:<index>:<fraction>`).
  String get locator =>
      '${_kind.name}:$_index:${(isPdf ? 0.0 : _lastFraction).toStringAsFixed(4)}';

  /// Opens the book. Safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    _loading = true;
    _error = null;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return;
    try {
      _openBook();
      _loadHighlights();
      _restorePosition();
      _loadCurrentDocument();
      loadInk();
      _loading = false;
      final id = book.id;
      if (id != null) {
        _stats.startSession(id);
        _sessionBookId = id;
      }
      _savePosition();
    } catch (_) {
      _error = 'Cannot Open Book';
      _loading = false;
      _document = null;
    }
    if (_disposed) return;
    notifyListeners();
    if (!hasError && isPdf) _renderPdf();
  }

  /// Moves to the next item.
  void next() {
    if (_index < _items.length - 1) _goTo(_index + 1);
  }

  /// Moves to the previous item.
  void previous() {
    if (_index > 0) _goTo(_index - 1);
  }

  /// Jumps to [index] (clamped/no-op when unchanged or out of range).
  void goTo(int index) {
    if (index < 0 || index >= _items.length || index == _index) return;
    _goTo(index);
  }

  /// Updates the reader font scale (0.8–1.6).
  ///
  /// Reflowing the page changes every pixel offset, so the same scroll
  /// fraction is re-armed for the page to apply once the new layout exists.
  void setFontScale(double scale) {
    final clamped = scale.clamp(_minFontScale, _maxFontScale).toDouble();
    if ((clamped - _fontScale).abs() < 1e-9) return;
    _fontScale = clamped;
    if (isPdf && !_pdfReflow) {
      _pdfCache.clear();
      _renderPdf();
    } else {
      _pendingScrollFraction = _lastFraction;
    }
    notifyListeners();
  }

  /// Zooms PDF pages in by one step.
  void zoomIn() => _setZoom(_zoom + _zoomStep);

  /// Zooms PDF pages out by one step.
  void zoomOut() => _setZoom(_zoom - _zoomStep);

  /// Reports the current scroll fraction (EPUB/MOBI).
  void reportScroll(double fraction) {
    if (isPdf || _loading || hasError) return;
    final value = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0).toDouble();
    _lastFraction = value;
    final elapsed = DateTime.now().difference(_lastPositionWrite);
    if (elapsed >= _scrollSaveInterval) {
      _savePosition();
    } else {
      _saveTimer ??= Timer(_scrollSaveInterval - elapsed, () {
        _saveTimer = null;
        _savePosition();
      });
    }
  }

  /// Returns and clears the scroll fraction restored from the saved locator.
  double? takePendingScrollFraction() {
    final fraction = _pendingScrollFraction;
    _pendingScrollFraction = null;
    return fraction;
  }

  /// Returns and clears the document offset a highlight jump armed.
  int? takePendingJumpOffset() {
    final offset = _pendingJumpOffset;
    _pendingJumpOffset = null;
    return offset;
  }

  /// Jumps to the chapter of highlight [id] and arms its document offset.
  ///
  /// Returns false, without arming anything, when the highlight is gone or
  /// its chapter is not part of this book. The caller reports that case.
  bool goToHighlight(int id) {
    ReaderHighlight? target;
    for (final highlight in _highlights) {
      if (highlight.id == id) {
        target = highlight;
        break;
      }
    }
    if (target == null ||
        target.chapter < 0 ||
        target.chapter >= _items.length) {
      _pendingJumpOffset = null;
      return false;
    }
    if (target.chapter == _index) {
      _pendingJumpOffset = target.start;
      notifyListeners();
    } else {
      _goTo(target.chapter, jumpOffset: target.start);
    }
    return true;
  }

  /// Saves a highlight on the current item. Returns false on failure (a
  /// `Could not save highlight` toast is emitted).
  Future<bool> addHighlight({
    required int start,
    required int end,
    required String color,
    required String text,
  }) async {
    final bookId = book.id;
    if (bookId == null || end <= start) return false;
    // Truncate on rune boundaries so a surrogate pair is never split
    // (an unpaired surrogate would make the position JSON invalid).
    final quote = text.length > 200
        ? String.fromCharCodes(text.runes.take(200))
        : text;
    final position = jsonEncode(<String, Object?>{
      'chapter': _index,
      'start': start,
      'end': end,
      'quote': quote,
    });
    try {
      final id = _library.addHighlight(bookId, position, color, text);
      _highlights.add(
        ReaderHighlight(
          id: id,
          chapter: _index,
          start: start,
          end: end,
          color: color,
          quote: quote,
          text: text,
        ),
      );
      notifyListeners();
      return true;
    } catch (_) {
      _onToast?.call('Could not save highlight');
      return false;
    }
  }

  /// Deletes a highlight and updates the rendered ranges.
  void deleteHighlight(int id) {
    try {
      _library.deleteHighlight(id);
    } catch (_) {
      // Keep the UI consistent even when the row is already gone.
    }
    final before = _highlights.length;
    _highlights.removeWhere((highlight) => highlight.id == id);
    if (_highlights.length != before) notifyListeners();
  }

  /// Extracts the first word from [selectionText] and looks it up.
  ///
  /// Returns null for no word or no definition (the caller toasts).
  Future<Map<String, Object?>?> define(String selectionText) async {
    final match = _wordPattern.firstMatch(selectionText);
    if (match == null) return null;
    try {
      return await dictionary.lookup(match.group(0)!);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!hasError) _savePosition();
    final sessionBookId = _sessionBookId;
    if (sessionBookId != null) {
      _sessionBookId = null;
      try {
        _stats.endSession(sessionBookId, locator);
      } catch (_) {
        // Statistics failures must not break navigation away.
      }
    }
    _pdf?.close();
    _pdf = null;
    _pdfReflowCache.clear();
    _pdfWorker.dispose();
    super.dispose();
  }

  // -- opening ---------------------------------------------------------------

  static ReaderFormat _selectFormat(Book book) {
    final formats = book.formats.map((format) => format.toLowerCase()).toSet();
    for (final format in const <String>['epub', 'pdf', 'mobi']) {
      if (formats.contains(format)) {
        return switch (format) {
          'pdf' => ReaderFormat.pdf,
          'mobi' => ReaderFormat.mobi,
          _ => ReaderFormat.epub,
        };
      }
    }
    return ReaderFormat.epub;
  }

  static final RegExp _wordPattern = RegExp(r"[A-Za-z][A-Za-z'\-]*");

  void _openBook() {
    if (book.path.isEmpty || !File(book.path).existsSync()) {
      throw const FormatException('Book file is missing');
    }
    _cacheDir = _computeCacheDir();
    switch (_kind) {
      case ReaderFormat.pdf:
        final pdf = PdfBook(book.path);
        final count = pdf.pageCount();
        if (count <= 0) throw const FormatException('PDF has no pages');
        _pdf = pdf;
        for (var i = 0; i < count; i++) {
          String title;
          try {
            title = pdf.titleAt(i);
          } catch (_) {
            title = 'Page ${i + 1}';
          }
          _items.add(ReaderItem(key: '', title: title));
        }
        break;
      case ReaderFormat.mobi:
        final mobi = MobiBook(book.path);
        final sections = mobi.sections();
        if (sections.isEmpty) throw const FormatException('No sections');
        _mobi = mobi;
        mobi.extractTo('$_cacheDir/mobi');
        for (final section in sections) {
          _items.add(ReaderItem(key: '', title: section.$2));
        }
        break;
      case ReaderFormat.epub:
        final epub = EpubBook(book.path);
        final chapters = epub.chapters();
        if (chapters.isEmpty) throw const FormatException('No chapters');
        _epub = epub;
        epub.extractTo(_cacheDir!);
        for (final chapter in chapters) {
          _items.add(ReaderItem(key: chapter.$1, title: chapter.$2));
        }
        break;
    }
  }

  String _computeCacheDir() {
    final env = Platform.environment;
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : '${env['HOME'] ?? Directory.current.path}/.cache';
    var mtimeNs = 0;
    var size = 0;
    try {
      final stat = File(book.path).statSync();
      size = stat.size;
      mtimeNs = stat.modified.microsecondsSinceEpoch * 1000;
    } catch (_) {
      // Missing files fail during open; keep the all-zero signature.
    }
    final digest = sha1
        .convert(utf8.encode('${book.id}:${book.path}:$mtimeNs:$size'))
        .toString()
        .substring(0, 16);
    return '$base/vellum/reader/$digest';
  }

  void _loadHighlights() {
    final bookId = book.id;
    if (bookId == null) return;
    try {
      for (final row in _library.listHighlights(bookId)) {
        final highlight = ReaderHighlight.fromRow(row);
        if (highlight == null) continue;
        // A position saved before a re-import can point past the last item.
        if (highlight.chapter < 0 || highlight.chapter >= _items.length) {
          continue;
        }
        _highlights.add(highlight);
      }
    } catch (_) {
      _highlights.clear();
    }
  }

  void _restorePosition() {
    final requested = initialChapter;
    if (requested != null && requested >= 0 && requested < _items.length) {
      _index = requested;
      _lastFraction = 0;
      return;
    }
    final bookId = book.id;
    if (bookId == null) return;
    String? locator;
    try {
      locator = _library.getReadingPosition(bookId);
    } catch (_) {
      return;
    }
    if (locator == null || locator.isEmpty) return;
    final parts = locator.split(':');
    if (parts.length != 3 || parts[0] != _kind.name) return;
    final storedIndex = int.tryParse(parts[1]);
    if (storedIndex == null ||
        storedIndex < 0 ||
        storedIndex >= _items.length) {
      return;
    }
    _index = storedIndex;
    if (isPdf) {
      _lastFraction = 0;
      return;
    }
    final fraction = (double.tryParse(parts[2]) ?? 0)
        .clamp(0.0, 1.0)
        .toDouble();
    _lastFraction = fraction;
    if (fraction > 0) _pendingScrollFraction = fraction;
  }

  void _loadCurrentDocument() {
    if (isPdf) {
      _document = null;
      return;
    }
    final cacheDir = _cacheDir;
    if (cacheDir == null) throw const FormatException('No cache directory');
    final String html;
    final String baseDirectory;
    final String rootDirectory;
    if (_kind == ReaderFormat.epub) {
      final path = _epub!.chapterFile(cacheDir, _index);
      html = utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
      baseDirectory = File(path).parent.path;
      rootDirectory = cacheDir;
    } else {
      html = _mobi!.sectionHtml(_index);
      baseDirectory = '$cacheDir/mobi';
      rootDirectory = baseDirectory;
    }
    _document = DocumentModel.fromHtml(
      html,
      baseDirectory: baseDirectory,
      rootDirectory: rootDirectory,
    );
    _documentSerial++;
  }

  // -- navigation ------------------------------------------------------------

  void _goTo(int newIndex, {int? jumpOffset}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    _direction = newIndex > _index ? 1 : -1;
    _index = newIndex;
    _lastFraction = 0;
    _pendingScrollFraction = null;
    _pendingJumpOffset = null;
    _pdfSerial++;
    var loaded = true;
    if (isPdf) {
      _touchPdfCache(_index);
      _pdfPageLoading = !_pdfCache.containsKey(_index);
      _pdfReflowLoading = _pdfReflow && !_pdfReflowCache.containsKey(_index);
    } else {
      try {
        _loadCurrentDocument();
        _error = null;
      } catch (_) {
        _document = null;
        _error = 'Cannot Open Book';
        loaded = false;
      }
    }
    if (loaded) {
      _pendingJumpOffset = jumpOffset;
      _savePosition();
    }
    loadInk();
    notifyListeners();
    if (isPdf) _renderPdf();
  }

  void _savePosition() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _lastPositionWrite = DateTime.now();
    final bookId = book.id;
    if (bookId == null || _items.isEmpty) return;
    try {
      _library.setReadingPosition(bookId, locator, progress: progress);
    } catch (_) {
      // Position persistence is best-effort.
    }
  }

  // -- PDF -------------------------------------------------------------------

  void _setZoom(double value) {
    if (!isPdf) return;
    final clamped = value.clamp(_minZoom, _maxZoom).toDouble();
    if ((clamped - _zoom).abs() < 1e-9) return;
    _zoom = clamped;
    _pdfCache.clear();
    _renderPdf();
  }

  double get _pdfScale => _zoom * _fontScale;

  /// Kills the PDF worker isolate, as an unexpected exit would. Test-only.
  @visibleForTesting
  void debugKillPdfWorker() => _pdfWorker.kill();

  /// True while the PDF worker isolate is alive. Test-only.
  @visibleForTesting
  bool get debugPdfWorkerRunning => _pdfWorker.isRunning;

  void _renderPdf() {
    if (_disposed || !isPdf || _items.isEmpty) return;
    final serial = ++_pdfSerial;
    final scale = _pdfScale;
    final current = _index;
    _touchPdfCache(current);
    _pdfPageLoading = !_pdfCache.containsKey(current);
    _pdfRenderError = null;
    notifyListeners();

    // In reflow the page bitmap is only the fallback for pages without a
    // text layer, so prefetching its neighbours would delay the words.
    final targets = <int>[current];
    if (!_pdfReflow) {
      if (current > 0) targets.add(current - 1);
      if (current < _items.length - 1) targets.add(current + 1);
    }
    for (final target in targets) {
      if (_pdfCache.containsKey(target)) continue;
      unawaited(_renderPdfPage(serial, target, scale));
    }
    if (_pdfReflow) _renderPdfReflow();
  }

  void _renderPdfReflow() {
    if (_disposed || !isPdf || !_pdfReflow || _items.isEmpty) return;
    final serial = ++_pdfReflowSerial;
    final current = _index;
    _pdfReflowLoading = !_pdfReflowCache.containsKey(current);
    _pdfReflowError = null;
    notifyListeners();

    final cached = _pdfReflowCache[current];
    if (cached != null) {
      // A scanned page already cost its OCR run; only text-layer pages are
      // cheap enough to prefetch around.
      if (cached.hasText && !cached.usedOcr) {
        _prefetchPdfReflowNeighbours(serial);
      }
      return;
    }
    unawaited(_renderPdfReflowPage(serial, current));
  }

  /// Fetch the neighbours of the current page when they are cheap.
  ///
  /// Reflowing a text layer costs little, but a scan costs a Tesseract run;
  /// queuing three OCRs per page would starve the page being read.
  void _prefetchPdfReflowNeighbours(int serial) {
    if (_disposed || !isPdf || !_pdfReflow) return;
    if (serial != _pdfReflowSerial) return;
    final current = _index;
    final targets = <int>[
      if (current > 0) current - 1,
      if (current < _items.length - 1) current + 1,
    ];
    for (final target in targets) {
      if (_pdfReflowCache.containsKey(target)) continue;
      unawaited(_renderPdfReflowPage(serial, target));
    }
  }

  Future<void> _renderPdfReflowPage(int serial, int target) async {
    PdfReflowPage? page;
    String? failure;
    try {
      page = await _pdfWorker.reflow(target, 3.0);
    } catch (error) {
      if (_disposed) return;
      failure = error is PdfRenderException
          ? error.message
          : 'Could not reflow this page';
    }
    if (_disposed || serial != _pdfReflowSerial) return;
    if (page != null) {
      _putPdfReflowCache(target, page);
      if (target == _index) {
        _pdfReflowLoading = false;
        if (page.hasText && !page.usedOcr) {
          _prefetchPdfReflowNeighbours(serial);
        }
      }
    } else if (target == _index) {
      _pdfReflowLoading = false;
      _pdfReflowError = failure ?? 'Could not reflow this page';
    }
    notifyListeners();
  }

  void _putPdfReflowCache(int index, PdfReflowPage page) {
    _pdfReflowCache.remove(index);
    _pdfReflowCache[index] = page;
    while (_pdfReflowCache.length > _pdfCacheSize) {
      _pdfReflowCache.remove(_pdfReflowCache.keys.first);
    }
  }

  Future<void> _renderPdfPage(int serial, int target, double scale) async {
    Uint8List? bytes;
    String? failure;
    try {
      // All PDFium access belongs to the worker isolate: PDFium is
      // process-global and not thread-safe, so a UI-isolate fallback would
      // race a render already in flight and crash the process.
      bytes = await _pdfWorker.render(target, scale);
    } catch (error) {
      if (_disposed) return;
      failure = error is PdfRenderException
          ? error.message
          : 'Could not render this page';
    }
    if (_disposed) return;
    if (serial != _pdfSerial || (scale - _pdfScale).abs() > 1e-9) {
      return; // Superseded by a newer navigation/zoom: drop stale pixels.
    }
    if (bytes != null) {
      _putPdfCache(target, bytes);
      if (target == _index) _pdfPageLoading = false;
    } else if (target == _index) {
      _pdfPageLoading = false;
      _pdfRenderError = failure ?? 'Could not render this page';
    }
    notifyListeners();
  }

  void _touchPdfCache(int index) {
    final bytes = _pdfCache.remove(index);
    if (bytes != null) _pdfCache[index] = bytes;
  }

  void _putPdfCache(int index, Uint8List bytes) {
    _pdfCache.remove(index);
    _pdfCache[index] = bytes;
    while (_pdfCache.length > _pdfCacheSize) {
      _pdfCache.remove(_pdfCache.keys.first);
    }
  }
}

/// One reversible ink edit: an add or an erase of a stroke.
class _InkOperation {
  _InkOperation.add(this.stroke) : isAdd = true;

  _InkOperation.erase(this.stroke) : isAdd = false;

  /// The stroke the operation added or removed.
  final InkStroke stroke;

  /// True for an add, false for an erase.
  final bool isAdd;
}

/// Renders PDF pages on a long-lived worker isolate so navigation does not
/// block the UI. Results are copied back as PNG bytes.
class _PdfWorker {
  _PdfWorker(this.path);

  final String path;

  /// How long one request may wait before its session is abandoned.
  ///
  /// The budget covers three queued reflow requests at 20 s of OCR each plus
  /// raster and encode time, so a slow scan is not mistaken for a dead worker.
  static const Duration _requestTimeout = Duration(seconds: 75);

  /// How long the worker gets to close its document before it is killed.
  ///
  /// A running 20 s OCR has to finish so the worker can call `pdf.close()`;
  /// killing the isolate skips that cleanup and leaks the `FPDF_DOCUMENT`.
  static const Duration _closeTimeout = Duration(seconds: 25);

  final Map<int, Completer<Object>> _pending = <int, Completer<Object>>{};
  int _nextId = 0;
  bool _closed = false;
  _WorkerSession? _session;
  Future<SendPort>? _starting;
  Completer<void>? _closeAck;

  /// True while an isolate session owns a spawned worker.
  bool get isRunning => _session?.isolate != null;

  /// Kills the current isolate, as an unexpected exit would. Test-only.
  void kill() => _session?.isolate?.kill(priority: Isolate.immediate);

  Future<Uint8List> render(int index, double scale) async {
    final result = await _request(index, scale, null);
    if (result is Uint8List) return result;
    throw const PdfRenderException('PDF render failed');
  }

  Future<PdfReflowPage> reflow(int index, double scale) async {
    final result = await _request(index, scale, 'reflow');
    if (result is PdfReflowPage) return result;
    throw const PdfRenderException('PDF reflow failed');
  }

  Future<Object> _request(int index, double scale, String? operation) async {
    final port = await _ensureSession();
    if (_closed) throw const PdfRenderException('PDF renderer is closed');
    final id = _nextId++;
    final completer = Completer<Object>();
    _pending[id] = completer;
    port.send(<Object?>[id, index, scale, operation]);
    try {
      return await completer.future.timeout(_requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      final error = const PdfRenderException('PDF renderer did not respond');
      final session = _session;
      if (session != null) _failSession(session, error);
      throw error;
    }
  }

  /// Returns a port for the live session, starting one when there is none.
  ///
  /// Concurrent callers share one start attempt. A failed attempt is
  /// forgotten so the next caller starts a fresh worker.
  Future<SendPort> _ensureSession() async {
    if (_closed) throw const PdfRenderException('PDF renderer is closed');
    final session = _session;
    if (session != null) return _sessionPort(session);
    final starting = _starting;
    if (starting != null) return starting;
    final future = _startSession();
    _starting = future;
    try {
      return await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<SendPort> _sessionPort(_WorkerSession session) async {
    final port = session.sendPort ?? await session.ready.future;
    if (port == null) {
      throw (session.failure ??
          const PdfRenderException('PDF renderer is unavailable'));
    }
    if (_closed) throw const PdfRenderException('PDF renderer is closed');
    return port;
  }

  Future<SendPort> _startSession() async {
    final receive = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final session = _WorkerSession(
      receive: receive,
      errorPort: errorPort,
      exitPort: exitPort,
    );
    _session = session;
    receive.listen((message) => _onMessage(session, message));
    errorPort.listen((message) {
      _failSession(
        session,
        PdfRenderException('PDF renderer failed: $message'),
      );
    });
    exitPort.listen((_) {
      if (_closed) {
        _closeSession(session);
        return;
      }
      _failSession(
        session,
        const PdfRenderException('PDF renderer exited unexpectedly'),
      );
    });
    try {
      final isolate = await Isolate.spawn(
        _entry,
        <Object>[receive.sendPort, path],
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: false,
      );
      session.isolate = isolate;
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        throw const PdfRenderException('PDF renderer is closed');
      }
      if (!identical(_session, session)) {
        isolate.kill(priority: Isolate.immediate);
        throw (session.failure ??
            const PdfRenderException('PDF renderer exited unexpectedly'));
      }
    } catch (error) {
      final failure = error is PdfRenderException
          ? error
          : const PdfRenderException('PDF renderer failed to start');
      _failSession(session, failure);
      throw failure;
    }
    return _sessionPort(session);
  }

  /// Drops [session] and fails everything queued on it.
  ///
  /// Only the current session can be dropped, so a late message from a dead
  /// isolate cannot tear down its replacement.
  void _failSession(_WorkerSession session, PdfRenderException error) {
    if (!identical(_session, session)) return;
    session.failure = error;
    _closeSession(session);
    _failPending(error);
  }

  void _closeSession(_WorkerSession session) {
    if (identical(_session, session)) _session = null;
    session.isolate?.kill(priority: Isolate.immediate);
    session.isolate = null;
    session.close();
    if (!session.ready.isCompleted) {
      // Wake callers waiting for the port; they read [failure].
      session.failure ??= const PdfRenderException('PDF renderer is closed');
      session.ready.complete(null);
    }
  }

  void _failPending(PdfRenderException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void _onMessage(_WorkerSession session, Object? message) {
    if (message is SendPort) {
      session.sendPort = message;
      if (!session.ready.isCompleted) session.ready.complete(message);
      return;
    }
    if (message is List && message.length == 1 && message[0] == 'closed') {
      final ack = _closeAck;
      if (ack != null && !ack.isCompleted) ack.complete();
      return;
    }
    if (!identical(_session, session)) return; // A dead session's late reply.
    if (message is List && message.length == 3) {
      final id = message[0];
      final bytes = message[1];
      final error = message[2];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (bytes is Uint8List || bytes is PdfReflowPage) {
        completer.complete(bytes);
      } else {
        // Keep the failure typed and readable: the reader shows this text.
        completer.completeError(
          PdfRenderException(error is String ? error : 'PDF render failed'),
        );
      }
    }
  }

  @pragma('vm:entry-point')
  static void _entry(List<Object> args) {
    final replyPort = args[0] as SendPort;
    final path = args[1] as String;
    final receive = ReceivePort();
    replyPort.send(receive.sendPort);
    PdfBook? pdf;
    var closing = false;
    var chain = Future<void>.value();
    receive.listen((message) {
      final request = message as List;
      if (request.length == 1 && request[0] == 'close') {
        closing = true;
        chain = chain.then((_) {
          pdf?.close();
          pdf = null;
          replyPort.send(const <Object>['closed']);
        });
        return;
      }
      chain = chain.then((_) async {
        final id = request[0] as int;
        // Requests prefetched behind the close must not start another OCR.
        if (closing) {
          replyPort.send(<Object?>[id, null, 'PDF renderer is closed']);
          return;
        }
        final index = request[1] as int;
        final scale = (request[2] as num).toDouble();
        final operation = request.length > 3 ? request[3] : null;
        try {
          pdf ??= PdfBook(path);
          final result = operation == 'reflow'
              ? await pdf!.reflowPage(index, renderScale: scale)
              : await pdf!.renderPage(index, scale: scale);
          replyPort.send(<Object?>[id, result, null]);
        } catch (error) {
          // Release native FPDF handles; the next request reopens the file.
          pdf?.close();
          pdf = null;
          replyPort.send(<Object?>[id, null, error.toString()]);
        }
      });
    });
  }

  /// Stops the worker: asks it to close its document, then kills it.
  ///
  /// [Isolate.kill] does not run cleanup, so the handshake is what releases
  /// the worker's `FPDF_DOCUMENT`. PDFium itself is process-global and stays
  /// alive for the isolates that still render.
  void dispose() {
    if (_closed) return;
    _closed = true;
    final session = _session;
    _session = null;
    _failPending(const PdfRenderException('PDF renderer is closed'));
    if (session == null) return;
    final port = session.sendPort;
    if (port == null) {
      _closeSession(session);
      return;
    }
    final ack = Completer<void>();
    _closeAck = ack;
    port.send(const <Object>['close']);
    unawaited(
      ack.future.timeout(_closeTimeout).catchError((_) {}).whenComplete(() {
        if (identical(_closeAck, ack)) _closeAck = null;
        _closeSession(session);
      }),
    );
  }
}

/// One worker isolate and the ports that talk to it.
///
/// [ready] completes with the worker's reply port, or with null once the
/// session failed; [failure] then says why. Keeping the failure as data
/// instead of an error future avoids unhandled errors when a start fails
/// before anyone awaits the port.
class _WorkerSession {
  _WorkerSession({
    required this.receive,
    required this.errorPort,
    required this.exitPort,
  });

  final ReceivePort receive;
  final ReceivePort errorPort;
  final ReceivePort exitPort;
  final Completer<SendPort?> ready = Completer<SendPort?>();
  SendPort? sendPort;
  Isolate? isolate;
  PdfRenderException? failure;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    receive.close();
    errorPort.close();
    exitPort.close();
  }
}
