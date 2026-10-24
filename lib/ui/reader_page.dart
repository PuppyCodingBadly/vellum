/// Reader page: EPUB chapters, MOBI sections, and PDF pages.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../core/gestures.dart';
import '../core/models.dart';
import '../reader/document_model.dart';
import '../reader/reader_controller.dart';

const double _baseFontSize = 16.0;
const double _minFontScale = 0.8;
const double _maxFontScale = 1.6;
const Duration _animationDuration = Duration(milliseconds: 200);
const Duration _selectionDebounce = Duration(milliseconds: 350);

/// Reader page for a single [Book].
class ReaderPage extends StatefulWidget {
  /// Creates a reader for [book], optionally starting at [initialChapter].
  const ReaderPage({
    super.key,
    required this.book,
    this.initialChapter,
  });

  /// Book to render.
  final Book book;

  /// Chapter/section/page index override (defaults to the saved position).
  final int? initialChapter;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ReaderController? _controller;
  AppState? _appState;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'reader');

  Timer? _selectionTimer;
  OverlayEntry? _selectionOverlay;
  _PendingSelection? _pendingSelection;
  Offset _pointer = Offset.zero;

  int _lastIndex = 0;
  int _selectionEpoch = 0;
  double _contentWidth = 600;
  int? _pendingJumpOffset;
  double? _pendingRestore;
  String _currentContentKey = '';
  bool _focusRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = AppState.of(context);
    _appState = appState;
    final controller = _controller;
    if (controller == null) {
      appState.registerReader();
      final created = ReaderController(
        book: widget.book,
        library: appState.library,
        stats: appState.stats,
        initialChapter: widget.initialChapter,
        onToast: appState.showToast,
      );
      _controller = created;
      created.addListener(_onControllerChanged);
      created.setFontScale(appState.readerFontScale);
      unawaited(created.load());
      if (!_focusRequested) {
        _focusRequested = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    } else {
      controller.setFontScale(appState.readerFontScale);
    }
  }

  @override
  void dispose() {
    _selectionTimer?.cancel();
    _selectionTimer = null;
    _removeSelectionOverlay();
    _focusNode.dispose();
    _scrollController.dispose();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      controller.dispose();
      _appState?.unregisterReader();
    }
    final appState = _appState;
    if (appState != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(appState.refresh());
      });
    }
    super.dispose();
  }

  // -- controller events -----------------------------------------------------

  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final restore = controller.takePendingScrollFraction();
    final indexChanged = controller.index != _lastIndex;
    if (indexChanged) {
      _lastIndex = controller.index;
      _selectionEpoch++;
      _pendingSelection = null;
      _removeSelectionOverlay();
    }
    if (restore != null) _pendingRestore = restore;
    if (restore != null || indexChanged || _pendingJumpOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final restoreFraction = _pendingRestore;
        _pendingRestore = null;
        if (restoreFraction != null) {
          _applyScrollFraction(restoreFraction);
          return;
        }
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        final jump = _pendingJumpOffset;
        _pendingJumpOffset = null;
        if (jump != null) _jumpToDocumentOffset(jump);
      });
    }
  }

  void _applyScrollFraction(double fraction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final target = position.maxScrollExtent * fraction.clamp(0.0, 1.0);
    _scrollController.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble(),
    );
  }

  void _jumpToDocumentOffset(int documentOffset) {
    final controller = _controller;
    final document = controller?.document;
    if (controller == null || document == null) return;
    if (!_scrollController.hasClients) return;
    final colors = _currentColors();
    final span = _buildTextSpan(document, controller, colors, _contentWidth);
    final painter = TextPainter(
      text: _measurementSpan(span),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: _contentWidth);
    final renderedOffset = document.documentStartToRendered(documentOffset);
    final caret =
        painter.getOffsetForCaret(TextPosition(offset: renderedOffset), Rect.zero);
    final position = _scrollController.position;
    final target = caret.dy - position.viewportDimension / 3;
    _scrollController.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble(),
    );
  }

  // -- navigation ------------------------------------------------------------

  void _next() {
    final controller = _controller;
    if (controller == null || controller.loading || controller.hasError) return;
    _dismissSelection();
    controller.next();
  }

  void _previous() {
    final controller = _controller;
    if (controller == null || controller.loading || controller.hasError) return;
    _dismissSelection();
    controller.previous();
  }

  void _jumpToChapter(int index) {
    final controller = _controller;
    if (controller == null) return;
    if (index == controller.index) return;
    _dismissSelection();
    controller.goTo(index);
  }

  void _onSwipe(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond;
    final direction = swipeDirection(velocity.dx, velocity.dy);
    if (direction < 0) {
      _next();
    } else if (direction > 0) {
      _previous();
    }
  }

  void _changeFontScale(double delta) {
    final appState = _appState;
    final controller = _controller;
    if (appState == null || controller == null) return;
    final rounded = ((appState.readerFontScale + delta) * 10).round() / 10;
    final next = rounded.clamp(_minFontScale, _maxFontScale).toDouble();
    if ((next - appState.readerFontScale).abs() < 1e-9) return;
    appState.readerFontScale = next;
    controller.setFontScale(next);
  }

  Future<void> _toggleFullscreen() async {
    try {
      final fullscreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!fullscreen);
    } catch (_) {
      // Window management is unavailable outside a desktop window.
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Bare arrows only: Alt+Left/Right belong to app navigation.
    final bareArrows = !HardwareKeyboard.instance.isAltPressed;
    if (bareArrows && key == LogicalKeyboardKey.arrowLeft) {
      _previous();
      return KeyEventResult.handled;
    }
    if (bareArrows && key == LogicalKeyboardKey.arrowRight) {
      _next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    final controller = _controller;
    if (controller != null &&
        controller.isPdf &&
        HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.numpadAdd) {
        controller.zoomIn();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        controller.zoomOut();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // -- selection / highlights ------------------------------------------------

  void _onSelectionChanged(TextSelection selection, SelectionChangedCause? cause) {
    final controller = _controller;
    final document = controller?.document;
    if (controller == null ||
        document == null ||
        !controller.supportsHighlights) {
      return;
    }
    _selectionTimer?.cancel();
    _selectionTimer = null;
    if (selection.isCollapsed || selection.start < 0 || selection.end < 0) {
      _pendingSelection = null;
      _removeSelectionOverlay();
      return;
    }
    var start = document.renderedToDocument(selection.start);
    var end = document.renderedToDocument(selection.end);
    if (start > end) {
      final swap = start;
      start = end;
      end = swap;
    }
    final text = document.plainText;
    while (start < end && _isWhitespaceCode(text.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isWhitespaceCode(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (end <= start) {
      _pendingSelection = null;
      _removeSelectionOverlay();
      return;
    }
    _pendingSelection = _PendingSelection(
      start: start,
      end: end,
      text: text.substring(start, end),
    );
    _selectionTimer = Timer(_selectionDebounce, _showSelectionOverlay);
  }

  void _showSelectionOverlay() {
    _selectionTimer = null;
    if (!mounted || _pendingSelection == null || _selectionOverlay != null) {
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    final colors = _currentColors();
    final size = MediaQuery.sizeOf(context);
    final anchor = _pointer == Offset.zero
        ? Offset(size.width / 2, size.height / 2)
        : _pointer;
    final left = (anchor.dx - 90)
        .clamp(8.0, math.max(8.0, size.width - 220))
        .toDouble();
    final top = (anchor.dy - 130)
        .clamp(8.0, math.max(8.0, size.height - 170))
        .toDouble();
    final entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissSelection,
              child: const SizedBox.shrink(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: colors.background,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colors.foreground.withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Highlight',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.foreground.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final color in const [
                          'yellow',
                          'green',
                          'pink',
                        ])
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Tooltip(
                              message: 'Highlight $color',
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => unawaited(_saveHighlight(color)),
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: highlightColor(color),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => unawaited(_defineSelection()),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.foreground,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Define'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
    _selectionOverlay = entry;
  }

  Future<void> _saveHighlight(String color) async {
    final pending = _pendingSelection;
    final controller = _controller;
    _pendingSelection = null;
    _removeSelectionOverlay();
    if (pending == null || controller == null) return;
    final saved = await controller.addHighlight(
      start: pending.start,
      end: pending.end,
      color: color,
      text: pending.text,
    );
    if (!mounted) return;
    if (saved) _clearSelection();
  }

  Future<void> _defineSelection() async {
    final pending = _pendingSelection;
    final controller = _controller;
    _pendingSelection = null;
    _removeSelectionOverlay();
    if (pending == null || controller == null) return;
    _clearSelection();
    final entry = await controller.define(pending.text);
    if (!mounted) return;
    if (entry == null) {
      _appState?.showToast('No definition found');
      return;
    }
    await _showDefinition(entry);
  }

  void _dismissSelection() {
    _pendingSelection = null;
    _removeSelectionOverlay();
  }

  void _removeSelectionOverlay() {
    _selectionTimer?.cancel();
    _selectionTimer = null;
    final entry = _selectionOverlay;
    _selectionOverlay = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(() {
      _selectionEpoch++;
    });
  }

  Future<void> _showDefinition(Map<String, Object?> entry) async {
    final colors = _currentColors();
    final word = entry['word'] as String? ?? '';
    final phonetic = (entry['phonetic'] as String? ?? '').trim();
    final meanings = entry['meanings'] as List? ?? const [];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: colors.background,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        word,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: colors.foreground,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      color: colors.foreground,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
                if (phonetic.isNotEmpty)
                  Text(
                    phonetic,
                    style: TextStyle(
                      color: colors.foreground.withValues(alpha: 0.6),
                    ),
                  ),
                const SizedBox(height: 8),
                ..._definitionWidgets(meanings, colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _definitionWidgets(List<dynamic> meanings, _ReaderColors colors) {
    final widgets = <Widget>[];
    for (final raw in meanings) {
      if (raw is Map) {
        widgets.addAll(_meaningWidgets(raw, colors));
      }
    }
    return widgets;
  }

  List<Widget> _meaningWidgets(Map<dynamic, dynamic> meaning, _ReaderColors colors) {
    final widgets = <Widget>[];
    final part = (meaning['partOfSpeech'] as String? ?? '').trim();
    if (part.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Text(
          part,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: colors.foreground,
          ),
        ),
      ));
    }
    final definitions = meaning['definitions'] as List? ?? const [];
    for (final definition in definitions) {
      if (definition is String) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText(
            '• $definition',
            style: TextStyle(color: colors.foreground, height: 1.35),
          ),
        ));
      }
    }
    return widgets;
  }

  // -- menus -----------------------------------------------------------------

  PopupMenuButton<int> _buildTocMenu(
    ReaderController controller,
    _ReaderColors colors,
  ) {
    return PopupMenuButton<int>(
      tooltip: 'Table of contents',
      enabled: controller.items.isNotEmpty,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 400),
      onSelected: _jumpToChapter,
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (var i = 0; i < controller.items.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: SizedBox(
              width: 320,
              child: Text(
                controller.items[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight:
                      i == controller.index ? FontWeight.bold : FontWeight.normal,
                  color: colors.foreground,
                ),
              ),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Text('Chapters', style: TextStyle(color: colors.foreground)),
      ),
    );
  }

  PopupMenuButton<int> _buildHighlightsMenu(
    ReaderController controller,
    _ReaderColors colors,
  ) {
    return PopupMenuButton<int>(
      tooltip: 'Highlights',
      icon: const Icon(Icons.format_list_bulleted),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(maxWidth: 380, maxHeight: 400),
      onSelected: (id) => _jumpToHighlight(id),
      itemBuilder: (context) {
        final highlights = controller.highlights;
        if (highlights.isEmpty) {
          return <PopupMenuEntry<int>>[
            PopupMenuItem<int>(
              enabled: false,
              child: SizedBox(
                width: 340,
                height: 60,
                child: Center(
                  child: Text(
                    'No highlights yet',
                    style: TextStyle(
                      color: colors.foreground.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
            ),
          ];
        }
        return <PopupMenuEntry<int>>[
          for (final highlight in highlights)
            PopupMenuItem<int>(
              value: highlight.id,
              child: _highlightRow(context, highlight, controller, colors),
            ),
        ];
      },
    );
  }

  Widget _highlightRow(
    BuildContext menuContext,
    ReaderHighlight highlight,
    ReaderController controller,
    _ReaderColors colors,
  ) {
    final quote = highlight.quote.length > 120
        ? highlight.quote.substring(0, 120)
        : highlight.quote;
    return SizedBox(
      width: 340,
      child: Tooltip(
        message: 'Jump to highlight',
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: highlightColor(highlight.color),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                quote,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.foreground),
              ),
            ),
            IconButton(
              tooltip: 'Delete highlight',
              icon: const Icon(Icons.delete_outline, size: 18),
              color: colors.foreground,
              onPressed: () {
                controller.deleteHighlight(highlight.id);
                Navigator.of(menuContext).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _jumpToHighlight(int id) {
    final controller = _controller;
    if (controller == null) return;
    ReaderHighlight? target;
    for (final highlight in controller.highlights) {
      if (highlight.id == id) {
        target = highlight;
        break;
      }
    }
    if (target == null) return;
    _pendingJumpOffset = target.start;
    if (target.chapter == controller.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final offset = _pendingJumpOffset;
        _pendingJumpOffset = null;
        if (offset != null) _jumpToDocumentOffset(offset);
      });
    } else {
      controller.goTo(target.chapter);
    }
  }

  PopupMenuButton<String> _buildThemeMenu(AppState appState) {
    const entries = <String, String>{
      'follow': 'Follow System',
      'light': 'Light',
      'sepia': 'Sepia',
      'dark': 'Dark',
    };
    return PopupMenuButton<String>(
      tooltip: 'Reader theme',
      icon: const Icon(Icons.palette_outlined),
      position: PopupMenuPosition.under,
      onSelected: (value) => appState.readerTheme = value,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final entry in entries.entries)
          PopupMenuItem<String>(
            value: entry.key,
            child: Row(
              children: [
                Icon(
                  appState.readerTheme == entry.key
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(entry.value),
              ],
            ),
          ),
      ],
    );
  }

  // -- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = _resolveReaderColors(
          appState.readerTheme,
          Theme.of(context).brightness,
        );
        return Scaffold(
          backgroundColor: colors.background,
          body: Focus(
            autofocus: true,
            focusNode: _focusNode,
            onKeyEvent: _onKeyEvent,
            child: SafeArea(
              child: controller.hasError
                  ? _buildErrorView(colors)
                  : Column(
                      children: [
                        _buildHeader(controller, appState, colors),
                        Expanded(child: _buildBody(controller, colors)),
                        _buildProgress(controller, colors),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    ReaderController controller,
    AppState appState,
    _ReaderColors colors,
  ) {
    final hasItems = controller.items.isNotEmpty;
    return IconTheme(
      data: IconThemeData(color: colors.foreground),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.chevron_left),
              onPressed:
                  hasItems && controller.index > 0 ? _previous : null,
            ),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.chevron_right),
              onPressed: hasItems && controller.index < controller.items.length - 1
                  ? _next
                  : null,
            ),
            Expanded(
              child: Text(
                controller.itemTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.foreground,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (controller.counter.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  controller.counter,
                  style: TextStyle(
                    color: colors.foreground.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Decrease font size',
              icon: const Icon(Icons.text_decrease),
              onPressed: () => _changeFontScale(-0.1),
            ),
            IconButton(
              tooltip: 'Increase font size',
              icon: const Icon(Icons.text_increase),
              onPressed: () => _changeFontScale(0.1),
            ),
            _buildTocMenu(controller, colors),
            if (controller.supportsHighlights)
              _buildHighlightsMenu(controller, colors),
            _buildThemeMenu(appState),
            IconButton(
              tooltip: 'Toggle fullscreen (F11)',
              icon: const Icon(Icons.fullscreen),
              onPressed: () => unawaited(_toggleFullscreen()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ReaderController controller, _ReaderColors colors) {
    if (controller.loading) {
      return Center(
        child: CircularProgressIndicator(color: colors.foreground),
      );
    }
    if (controller.isPdf) return _buildPdfContent(controller, colors);
    return _buildTextContent(controller, colors);
  }

  Widget _buildTextContent(
    ReaderController controller,
    _ReaderColors colors,
  ) {
    final document = controller.document;
    if (document == null) {
      return Center(
        child: CircularProgressIndicator(color: colors.foreground),
      );
    }
    final fontSize = _baseFontSize * controller.fontScale;
    _currentContentKey = 'text-${controller.documentSerial}-${controller.index}';
    return GestureDetector(
      onHorizontalDragEnd: _onSwipe,
      child: Listener(
        onPointerDown: (event) => _pointer = event.position,
        onPointerMove: (event) => _pointer = event.position,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final metrics = notification.metrics;
            if (metrics.axis == Axis.vertical && metrics.maxScrollExtent > 0) {
              controller.reportScroll(
                metrics.pixels / metrics.maxScrollExtent,
              );
            }
            return false;
          },
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: fontSize,
              vertical: fontSize,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 46 * fontSize),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math
                        .min(46 * fontSize, constraints.maxWidth)
                        .toDouble();
                    _contentWidth = width;
                    return AnimatedSwitcher(
                      duration: _animationEnabled
                          ? _animationDuration
                          : Duration.zero,
                      transitionBuilder: _slideTransition,
                      child: SizedBox(
                        key: ValueKey<String>(_currentContentKey),
                        width: width,
                        child: SelectableText.rich(
                          _buildTextSpan(
                            document,
                            controller,
                            colors,
                            width,
                          ),
                          key: ValueKey<int>(_selectionEpoch),
                          maxLines: null,
                          style: TextStyle(
                            color: colors.foreground,
                            fontSize: fontSize,
                            height: 1.15,
                          ),
                          textScaler: TextScaler.noScaling,
                          selectionColor:
                              colors.foreground.withValues(alpha: 0.25),
                          onSelectionChanged: _onSelectionChanged,
                          contextMenuBuilder: (context, editableTextState) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPdfContent(
    ReaderController controller,
    _ReaderColors colors,
  ) {
    final bytes = controller.pdfPageBytes;
    final error = controller.pdfRenderError;
    _currentContentKey =
        error == null ? 'pdf-${controller.index}' : 'pdf-${controller.index}-error';
    return GestureDetector(
      onHorizontalDragEnd: _onSwipe,
      child: SizedBox.expand(
        child: AnimatedSwitcher(
          duration:
              _animationEnabled ? _animationDuration : Duration.zero,
          transitionBuilder: _slideTransition,
          child: SizedBox.expand(
            key: ValueKey<String>(_currentContentKey),
            child: bytes == null
                ? error == null
                    ? Center(
                        child:
                            CircularProgressIndicator(color: colors.foreground),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image_outlined,
                                size: 56,
                                color: colors.foreground.withValues(alpha: 0.7),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                error,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color:
                                      colors.foreground.withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                : Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress(ReaderController controller, _ReaderColors colors) {
    return SizedBox(
      height: 4,
      child: LinearProgressIndicator(
        value: controller.progress,
        backgroundColor: colors.foreground.withValues(alpha: 0.12),
        color: colors.foreground.withValues(alpha: 0.65),
      ),
    );
  }

  Widget _buildErrorView(_ReaderColors colors) {
    return Stack(
      children: [
        Positioned(
          top: 6,
          left: 6,
          child: IconButton(
            tooltip: 'Back',
            color: colors.foreground,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 72,
                  color: colors.foreground.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 16),
                Text(
                  'Cannot Open Book',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: colors.foreground,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This book file is not valid or is corrupted.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.foreground.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool get _animationEnabled => _appState?.readerAnimation ?? true;

  Widget _slideTransition(Widget child, Animation<double> animation) {
    if (!_animationEnabled) return child;
    final incoming = child.key == ValueKey<String>(_currentContentKey);
    final direction = _controller?.direction ?? 0;
    final factor = direction == 0 ? 0.0 : (direction > 0 ? 0.18 : -0.18);
    final tween = incoming
        ? Tween<Offset>(begin: Offset(factor, 0), end: Offset.zero)
        : Tween<Offset>(begin: Offset(-factor, 0), end: Offset.zero);
    return SlideTransition(position: tween.animate(animation), child: child);
  }

  /// Replaces inline widgets with a placeholder character so a standalone
  /// [TextPainter] can measure the line occupied by [span].
  TextSpan _measurementSpan(TextSpan span) {
    final children = <InlineSpan>[];
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is WidgetSpan) {
        children.add(TextSpan(text: '\uFFFC', style: span.style));
      } else if (child is TextSpan) {
        children.add(_measurementSpan(child));
      } else {
        children.add(child);
      }
    }
    return TextSpan(style: span.style, children: children);
  }

  TextSpan _buildTextSpan(
    DocumentModel document,
    ReaderController controller,
    _ReaderColors colors,
    double width,
  ) {
    final fontSize = _baseFontSize * controller.fontScale;
    return document.buildSpan(
      baseStyle: TextStyle(
        color: colors.foreground,
        fontSize: fontSize,
        height: 1.15,
      ),
      linkColor: colors.link,
      highlights: controller.currentHighlightRanges,
      maxImageWidth: width,
    );
  }

  _ReaderColors _currentColors() {
    final appState = _appState;
    return _resolveReaderColors(
      appState?.readerTheme ?? 'follow',
      Theme.of(context).brightness,
    );
  }
}

class _PendingSelection {
  const _PendingSelection({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}

class _ReaderColors {
  const _ReaderColors(this.background, this.foreground, this.link);

  final Color background;
  final Color foreground;
  final Color link;
}

const _ReaderColors _lightColors = _ReaderColors(
  Color(0xFFFFFFFF),
  Color(0xFF1A1A1A),
  Color(0xFF1A5FB4),
);
const _ReaderColors _sepiaColors = _ReaderColors(
  Color(0xFFF4ECD8),
  Color(0xFF5B4636),
  Color(0xFF7A5A2E),
);
const _ReaderColors _darkColors = _ReaderColors(
  Color(0xFF1E1E1E),
  Color(0xFFE8E8E8),
  Color(0xFF8AB4F8),
);

_ReaderColors _resolveReaderColors(String theme, Brightness brightness) {
  switch (theme) {
    case 'light':
      return _lightColors;
    case 'sepia':
      return _sepiaColors;
    case 'dark':
      return _darkColors;
    default:
      return brightness == Brightness.dark ? _darkColors : _lightColors;
  }
}

bool _isWhitespaceCode(int code) =>
    code == 0x20 ||
    code == 0x09 ||
    code == 0x0A ||
    code == 0x0B ||
    code == 0x0C ||
    code == 0x0D;
