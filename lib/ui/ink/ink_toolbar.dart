/// The handwriting toolbar: tool, ink colour, width, history and close.
///
/// The bar is deliberately compact — it shares one row of 26px controls so it
/// fits a 360px reader pane without wrapping. Colours and spacing come from
/// the caller and from the shared radius/space tokens; the toolbar never picks
/// a font or a palette of its own.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ink.dart';
import '../theme.dart';

/// A compact rounded bar of ink controls.
class InkToolbar extends StatelessWidget {
  const InkToolbar({
    super.key,
    required this.tool,
    required this.color,
    required this.width,
    required this.canUndo,
    required this.canRedo,
    required this.foreground,
    required this.background,
    required this.accent,
    this.paper,
    required this.onTool,
    required this.onColor,
    required this.onWidth,
    required this.onUndo,
    required this.onRedo,
    required this.onClose,
  });

  /// The four ink colours, in the order the bar shows them, on light paper.
  static const List<Color> inkColors = <Color>[
    Color(0xFF1F1B16), // warm black
    Color(0xFFA6342B), // red
    Color(0xFF2B5F8F), // blue
    Color(0xFFA8761C), // ochre
  ];

  /// The same four roles on a dark page: the neutral becomes parchment so
  /// notes stay visible, and the pigments brighten to keep their contrast.
  static const List<Color> darkInkColors = <Color>[
    Color(0xFFF4E7D4), // parchment
    Color(0xFFE06C5A), // red
    Color(0xFF86B7E6), // blue
    Color(0xFFE0AE5C), // ochre
  ];

  /// The ink palette that reads against [background].
  static List<Color> paletteFor(Color background) =>
      background.computeLuminance() < 0.35 ? darkInkColors : inkColors;

  /// The default ink colour for [background]: the palette's neutral, which is
  /// always the highest-contrast role in its palette.
  static Color defaultInkFor(Color background) => paletteFor(background).first;

  /// WCAG relative-luminance contrast ratio for two opaque colours.
  static double contrastRatio(Color a, Color b) {
    final first = a.computeLuminance();
    final second = b.computeLuminance();
    final lighter = math.max(first, second);
    final darker = math.min(first, second);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Whether [ink] stays legible on [background]; 3:1 is the UI-text floor.
  static bool hasContrast(
    Color ink,
    Color background, {
    double minimum = 3.0,
  }) => contrastRatio(ink, background) >= minimum;

  /// The same colour role in the palette that reads on [paper].
  ///
  /// A colour the user picked on the other palette keeps its role (ochre stays
  /// ochre) instead of snapping to the neutral; anything unrecognized becomes
  /// the neutral, which is guaranteed to contrast.
  static Color adaptInk(Color ink, Color paper) {
    final palette = paletteFor(paper);
    final argb = ink.toARGB32();
    if (palette.any((candidate) => candidate.toARGB32() == argb)) return ink;
    final opposite = identical(palette, inkColors) ? darkInkColors : inkColors;
    final index = opposite.indexWhere(
      (candidate) => candidate.toARGB32() == argb,
    );
    if (index >= 0) {
      final mapped = palette[index];
      if (hasContrast(mapped, paper)) return mapped;
    }
    return palette.first;
  }

  /// The three stroke widths offered by the bar, in logical pixels.
  static const List<double> inkWidths = <double>[2, 4, 6];

  final InkTool tool;

  /// The ink colour in use; one of [inkColors] is marked selected.
  final Color color;

  /// The stroke width in use; one of [inkWidths] is marked selected.
  final double width;

  final bool canUndo;
  final bool canRedo;
  final Color foreground;
  final Color background;

  /// The surface the ink is drawn on, when it differs from [background].
  ///
  /// Defaults to [background]; a PDF page bitmap, for example, is white under
  /// a dark-painted bar.
  final Color? paper;

  final Color accent;

  final ValueChanged<InkTool> onTool;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onWidth;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClose;

  static const double _iconHit = 26;
  static const double _dotHit = 26;
  static const double _widthHit = 24;
  static const double _groupGap = 4;

  @override
  Widget build(BuildContext context) {
    final muted = foreground.withValues(alpha: 0.15);
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: VellumRadius.largeAll,
        side: BorderSide(color: muted),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VellumSpace.xxs,
          vertical: VellumSpace.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconAction(
              icon: Icons.edit_outlined,
              tooltip: 'Pen',
              selected: tool == InkTool.pen,
              onPressed: () => onTool(InkTool.pen),
            ),
            _iconAction(
              icon: Icons.cleaning_services_outlined,
              tooltip: 'Eraser',
              selected: tool == InkTool.eraser,
              onPressed: () => onTool(InkTool.eraser),
            ),
            _gap(),
            _divider(muted),
            _gap(),
            for (final ink in paletteFor(paper ?? background)) _colourDot(ink),
            _gap(),
            _divider(muted),
            _gap(),
            for (final strokeWidth in inkWidths) _widthDot(strokeWidth),
            _gap(),
            _divider(muted),
            _gap(),
            _iconAction(
              icon: Icons.undo,
              tooltip: 'Undo',
              onPressed: canUndo ? onUndo : null,
            ),
            _iconAction(
              icon: Icons.redo,
              tooltip: 'Redo',
              onPressed: canRedo ? onRedo : null,
            ),
            _iconAction(
              icon: Icons.close,
              tooltip: 'Close ink',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _gap() => const SizedBox(width: _groupGap);

  Widget _divider(Color color) => Container(
    width: 1,
    height: 18,
    decoration: BoxDecoration(
      color: color,
      borderRadius: VellumRadius.smallAll,
    ),
  );

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool selected = false,
  }) {
    final enabled = onPressed != null;
    final iconColor = !enabled
        ? foreground.withValues(alpha: 0.3)
        : selected
        ? accent
        : foreground;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 18,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(_iconHit),
        maximumSize: const Size.square(_iconHit),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: selected ? accent.withValues(alpha: 0.14) : null,
        shape: const RoundedRectangleBorder(
          borderRadius: VellumRadius.smallAll,
        ),
      ),
      icon: Icon(icon, color: iconColor),
    );
  }

  Widget _colourDot(Color ink) {
    final selected = ink.toARGB32() == color.toARGB32();
    return Tooltip(
      message: _colourName(ink),
      child: Semantics(
        button: true,
        selected: selected,
        label: _colourName(ink),
        child: InkResponse(
          onTap: () => onColor(ink),
          radius: _dotHit / 2,
          child: SizedBox(
            width: _dotHit,
            height: _dotHit,
            child: Center(
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: ink,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? accent
                        : foreground.withValues(alpha: 0.25),
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _colourName(Color ink) => switch (ink.toARGB32()) {
    0xFF1F1B16 => 'Black ink',
    0xFFA6342B => 'Red ink',
    0xFF2B5F8F => 'Blue ink',
    0xFFF4E7D4 => 'Parchment ink',
    0xFFE06C5A => 'Red ink',
    0xFF86B7E6 => 'Blue ink',
    0xFFE0AE5C => 'Ochre ink',
    _ => 'Ochre ink',
  };

  Widget _widthDot(double strokeWidth) {
    final selected = (width - strokeWidth).abs() < 0.01;
    return Tooltip(
      message: _widthName(strokeWidth),
      child: Semantics(
        button: true,
        selected: selected,
        label: _widthName(strokeWidth),
        child: InkResponse(
          onTap: () => onWidth(strokeWidth),
          radius: _widthHit / 2,
          child: SizedBox(
            width: _widthHit,
            height: _widthHit,
            child: Center(
              child: Container(
                width: 4 + strokeWidth * 2,
                height: 4 + strokeWidth * 2,
                decoration: BoxDecoration(
                  color: selected ? accent : foreground,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _widthName(double width) => switch (width) {
    2.0 => 'Thin stroke',
    4.0 => 'Medium stroke',
    _ => 'Thick stroke',
  };
}
