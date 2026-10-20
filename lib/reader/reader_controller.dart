/// Reader state: format opening, navigation, persistence, highlights, PDF.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/models.dart';
import '../formats/dictionary.dart' as dictionary;
import '../formats/epub.dart';
import '../formats/mobi.dart';
import '../formats/pdf_book.dart';
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
          position = decoded.map((key, value) => MapEntry(key.toString(), value));
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
    void Function(String message)? onToast,
  })  : _library = library,
        _stats = stats,
        _onToast = onToast,
        _kind = _selectFormat(book),
        _pdfWorker = _PdfWorker(book.path),
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

  int _index = 0;
  int _direction = 0;
  int _documentSerial = 0;
  double _lastFraction = 0.0;
  double? _pendingScrollFraction;
  double _fontScale = 1.0;
  double _zoom;
  int _pdfSerial = 0;
  bool _pdfPageLoading = false;
  bool _loaded = false;
  bool _sessionStarted = false;
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

  /// Reader text scale (0.8–1.6).
  double get fontScale => _fontScale;

  /// PDF zoom scale (1.0–3.0; starts at the 1.75 render scale).
  double get pdfZoom => _zoom;

  /// Current PDF page PNG, or null while rendering/uncached.
  Uint8List? get pdfPageBytes => isPdf ? _pdfCache[_index] : null;

  /// True while the current PDF page is still rendering.
  bool get pdfPageLoading => isPdf && _pdfPageLoading;

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

  /// Fraction read through the book, `(index + 1) / count`.
  double get progress {
    if (_items.isEmpty) return 0;
    return (_index + 1) / _items.length;
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
      _loading = false;
      final id = book.id;
      if (id != null) {
        _stats.startSession(id);
        _sessionStarted = true;
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
  void setFontScale(double scale) {
    final clamped = scale.clamp(_minFontScale, _maxFontScale).toDouble();
    if ((clamped - _fontScale).abs() < 1e-9) return;
    _fontScale = clamped;
    if (isPdf) {
      _pdfCache.clear();
      _renderPdf();
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
    final quote = text.length > 200 ? text.substring(0, 200) : text;
    final position = jsonEncode(<String, Object?>{
      'chapter': _index,
      'start': start,
      'end': end,
      'quote': quote,
    });
    try {
      final id = _library.addHighlight(bookId, position, color, text);
      _highlights.add(ReaderHighlight(
        id: id,
        chapter: _index,
        start: start,
        end: end,
        color: color,
        quote: quote,
        text: text,
      ));
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
    if (_sessionStarted) {
      _sessionStarted = false;
      try {
        _stats.endSession(locator);
      } catch (_) {
        // Statistics failures must not break navigation away.
      }
    }
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
        if (highlight != null) _highlights.add(highlight);
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
    if (storedIndex == null || storedIndex < 0 || storedIndex >= _items.length) {
      return;
    }
    _index = storedIndex;
    if (isPdf) {
      _lastFraction = 0;
      return;
    }
    final fraction =
        (double.tryParse(parts[2]) ?? 0).clamp(0.0, 1.0).toDouble();
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
    if (_kind == ReaderFormat.epub) {
      final path = _epub!.chapterFile(cacheDir, _index);
      html = utf8.decode(
        File(path).readAsBytesSync(),
        allowMalformed: true,
      );
      baseDirectory = File(path).parent.path;
    } else {
      html = _mobi!.sectionHtml(_index);
      baseDirectory = '$cacheDir/mobi';
    }
    _document = DocumentModel.fromHtml(html, baseDirectory: baseDirectory);
    _documentSerial++;
  }

  // -- navigation ------------------------------------------------------------

  void _goTo(int newIndex) {
    _saveTimer?.cancel();
    _saveTimer = null;
    _direction = newIndex > _index ? 1 : -1;
    _index = newIndex;
    _lastFraction = 0;
    _pendingScrollFraction = null;
    _pdfSerial++;
    if (isPdf) {
      _touchPdfCache(_index);
      _pdfPageLoading = !_pdfCache.containsKey(_index);
    } else {
      try {
        _loadCurrentDocument();
      } catch (_) {
        _document = null;
        _error = 'Cannot Open Book';
      }
    }
    _savePosition();
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
      _library.setReadingPosition(bookId, locator);
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

  void _renderPdf() {
    if (_disposed || !isPdf || _items.isEmpty) return;
    final serial = ++_pdfSerial;
    final scale = _pdfScale;
    final current = _index;
    _touchPdfCache(current);
    _pdfPageLoading = !_pdfCache.containsKey(current);
    notifyListeners();

    final targets = <int>[current];
    if (current > 0) targets.add(current - 1);
    if (current < _items.length - 1) targets.add(current + 1);
    for (final target in targets) {
      if (_pdfCache.containsKey(target)) continue;
      unawaited(_renderPdfPage(serial, target, scale));
    }
  }

  Future<void> _renderPdfPage(int serial, int target, double scale) async {
    Uint8List? bytes;
    try {
      bytes = await _pdfWorker.render(target, scale);
    } catch (_) {
      if (_disposed) return;
      try {
        bytes = await _pdf!.renderPage(target, scale: scale);
      } catch (_) {
        bytes = null;
      }
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

/// Renders PDF pages on a long-lived worker isolate so navigation does not
/// block the UI. Results are copied back as PNG bytes.
class _PdfWorker {
  _PdfWorker(this.path);

  final String path;
  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _sendPort;
  final Completer<SendPort> _ready = Completer<SendPort>();
  Future<void>? _startFuture;
  final Map<int, Completer<Uint8List>> _pending =
      <int, Completer<Uint8List>>{};
  int _nextId = 0;
  bool _closed = false;

  Future<Uint8List> render(int index, double scale) async {
    if (_closed) throw StateError('PDF renderer is closed');
    await _start();
    if (_closed) throw StateError('PDF renderer is closed');
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _sendPort!.send(<Object>[id, index, scale]);
    return completer.future;
  }

  Future<void> _start() {
    final existing = _startFuture;
    if (existing != null) return existing;
    final future = _startWorker();
    _startFuture = future;
    return future;
  }

  Future<void> _startWorker() async {
    final receive = ReceivePort();
    _receive = receive;
    receive.listen(_onMessage);
    final errorPort = ReceivePort();
    errorPort.listen((message) {
      if (!_ready.isCompleted) {
        _ready.completeError(StateError('PDF renderer failed: $message'));
      }
      errorPort.close();
    });
    try {
      final isolate = await Isolate.spawn(
        _entry,
        <Object>[receive.sendPort, path],
        onError: errorPort.sendPort,
        errorsAreFatal: false,
      );
      _isolate = isolate;
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('PDF renderer is closed');
      }
    } catch (error) {
      errorPort.close();
      if (!_ready.isCompleted) _ready.completeError(error);
    }
    _sendPort = await _ready.future;
    errorPort.close();
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is List && message.length == 3) {
      final id = message[0];
      final bytes = message[1];
      final error = message[2];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (bytes is Uint8List) {
        completer.complete(bytes);
      } else {
        completer.completeError(
          StateError(error is String ? error : 'PDF render failed'),
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
    var chain = Future<void>.value();
    receive.listen((message) {
      chain = chain.then((_) async {
        final request = message as List;
        final id = request[0] as int;
        final index = request[1] as int;
        final scale = (request[2] as num).toDouble();
        try {
          pdf ??= PdfBook(path);
          final bytes = await pdf!.renderPage(index, scale: scale);
          replyPort.send(<Object?>[id, bytes, null]);
        } catch (error) {
          replyPort.send(<Object?>[id, null, error.toString()]);
        }
      });
    });
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('PDF renderer is closed'));
      }
    }
    _pending.clear();
    _receive?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}
