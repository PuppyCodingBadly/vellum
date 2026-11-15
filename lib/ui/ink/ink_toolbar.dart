/// The handwriting toolbar: tool, ink colour, width, history and close.
///
/// The bar is deliberately compact — it shares one row of 26px controls so it
/// fits a 360px reader pane without wrapping. Colours and spacing come from
/// the caller and from the shared radius/space tokens; the toolbar never picks
/// a font or a palette of its own.
library;

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
    required this.onTool,
    required this.onColor,
    required this.onWidth,
    required this.onUndo,
    required this.onRedo,
    required this.onClose,
  });

  /// The four ink colours, in the order the bar shows them.
  static const List<Color> inkColors = <Color>[
    Color(0xFF1F1B16), // warm black
    Color(0xFFA6342B), // red
    Color(0xFF2B5F8F), // blue
    Color(0xFFA8761C), // ochre
  ];

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
            for (final ink in inkColors) _colourDot(ink),
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
