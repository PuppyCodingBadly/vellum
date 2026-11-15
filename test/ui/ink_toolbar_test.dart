/// Widget tests for the ink toolbar: callbacks, disabled history, and the
/// width range it has to fit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/ink.dart';
import 'package:vellum/ui/ink/ink_toolbar.dart';

void main() {
  Widget harness({
    InkTool tool = InkTool.pen,
    Color? color,
    double width = 4,
    bool canUndo = true,
    bool canRedo = true,
    ValueChanged<InkTool>? onTool,
    ValueChanged<Color>? onColor,
    ValueChanged<double>? onWidth,
    VoidCallback? onUndo,
    VoidCallback? onRedo,
    VoidCallback? onClose,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: InkToolbar(
            tool: tool,
            color: color ?? InkToolbar.inkColors[0],
            width: width,
            canUndo: canUndo,
            canRedo: canRedo,
            foreground: Colors.black,
            background: Colors.white,
            accent: Colors.teal,
            onTool: onTool ?? (_) {},
            onColor: onColor ?? (_) {},
            onWidth: onWidth ?? (_) {},
            onUndo: onUndo ?? () {},
            onRedo: onRedo ?? () {},
            onClose: onClose ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('tool, colour, width, history and close callbacks fire', (
    tester,
  ) async {
    InkTool? tool;
    Color? color;
    double? width;
    var undos = 0;
    var redos = 0;
    var closes = 0;
    await tester.pumpWidget(
      harness(
        onTool: (value) => tool = value,
        onColor: (value) => color = value,
        onWidth: (value) => width = value,
        onUndo: () => undos++,
        onRedo: () => redos++,
        onClose: () => closes++,
      ),
    );

    await tester.tap(find.byTooltip('Eraser'));
    await tester.tap(find.byTooltip('Pen'));
    await tester.tap(find.byTooltip('Red ink'));
    await tester.tap(find.byTooltip('Blue ink'));
    await tester.tap(find.byTooltip('Thick stroke'));
    await tester.tap(find.byTooltip('Undo'));
    await tester.tap(find.byTooltip('Redo'));
    await tester.tap(find.byTooltip('Close ink'));
    await tester.pump();

    expect(tool, InkTool.pen);
    expect(color, InkToolbar.inkColors[2]);
    expect(width, InkToolbar.inkWidths[2]);
    expect(undos, 1);
    expect(redos, 1);
    expect(closes, 1);
  });

  testWidgets('undo and redo are inert when unavailable', (tester) async {
    var undos = 0;
    var redos = 0;
    await tester.pumpWidget(
      harness(
        canUndo: false,
        canRedo: false,
        onUndo: () => undos++,
        onRedo: () => redos++,
      ),
    );

    await tester.tap(find.byTooltip('Undo'), warnIfMissed: false);
    await tester.tap(find.byTooltip('Redo'), warnIfMissed: false);
    await tester.pump();

    expect(undos, 0);
    expect(redos, 0);
  });

  testWidgets('the bar fits a 360px reader pane and a 900px one', (
    tester,
  ) async {
    for (final width in const [360.0, 900.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: InkToolbar(
                  tool: InkTool.pen,
                  color: InkToolbar.inkColors[0],
                  width: 4,
                  canUndo: true,
                  canRedo: true,
                  foreground: Colors.black,
                  background: Colors.white,
                  accent: Colors.teal,
                  onTool: (_) {},
                  onColor: (_) {},
                  onWidth: (_) {},
                  onUndo: () {},
                  onRedo: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(
        tester.getSize(find.byType(InkToolbar)).width,
        lessThanOrEqualTo(width),
      );
    }
  });

  test('dark pages get a light palette with a contrasting default', () {
    const copper = Color(0xFF1B120E);
    expect(InkToolbar.paletteFor(copper), InkToolbar.darkInkColors);
    expect(InkToolbar.paletteFor(Colors.white), InkToolbar.inkColors);
    expect(InkToolbar.defaultInkFor(copper), InkToolbar.darkInkColors.first);
    expect(
      InkToolbar.hasContrast(InkToolbar.defaultInkFor(copper), copper),
      isTrue,
    );
    // Warm black is the light-page default; it disappears on copper.
    expect(InkToolbar.hasContrast(InkToolbar.inkColors.first, copper), isFalse);
    for (final ink in InkToolbar.darkInkColors) {
      expect(InkToolbar.hasContrast(ink, copper), isTrue, reason: '$ink');
    }
  });

  test('a retained colour keeps its role on the current palette', () {
    const copper = Color(0xFF1B120E);
    expect(
      InkToolbar.adaptInk(InkToolbar.inkColors.first, copper),
      InkToolbar.darkInkColors.first,
    );
    expect(
      InkToolbar.adaptInk(InkToolbar.inkColors.last, copper),
      InkToolbar.darkInkColors.last,
    );
    expect(
      InkToolbar.adaptInk(InkToolbar.darkInkColors[1], Colors.white),
      InkToolbar.inkColors[1],
    );
    expect(
      InkToolbar.adaptInk(const Color(0xFF123456), copper),
      InkToolbar.darkInkColors.first,
    );
    expect(
      InkToolbar.adaptInk(const Color(0xFF123456), Colors.white),
      InkToolbar.inkColors.first,
    );
  });

  testWidgets('a dark bar offers the light palette', (tester) async {
    const copper = Color(0xFF1B120E);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InkToolbar(
            tool: InkTool.pen,
            color: InkToolbar.darkInkColors.first,
            width: 4,
            canUndo: false,
            canRedo: false,
            foreground: const Color(0xFFEBD3B8),
            background: copper,
            accent: const Color(0xFFE8A15C),
            onTool: (_) {},
            onColor: (_) {},
            onWidth: (_) {},
            onUndo: () {},
            onRedo: () {},
            onClose: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('Parchment ink'), findsOneWidget);
    expect(find.byTooltip('Red ink'), findsOneWidget);
    expect(find.byTooltip('Black ink'), findsNothing);
  });
}
