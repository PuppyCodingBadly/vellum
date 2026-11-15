/// Vellum's visual system.
///
/// One warm-paper world for light mode and one ink world for dark mode. The
/// chrome stays quiet — paper, ink, and a single user-chosen accent — while
/// cover art and the reading text carry the colour. Every surface reads its
/// colours from [VellumPalette] through [VellumPaletteContext.palette], so a
/// new widget picks tokens instead of inventing values.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The display face: book titles, page titles, and the wordmark.
const String kDisplayFont = 'Newsreader';

/// The interface face: navigation, labels, controls, and body copy.
const String kUiFont = 'InstrumentSans';

/// The reading face. Its optical size axis is tuned for long-form text.
const String kReaderFont = 'Literata';

/// Paths and other machine text; never used as a costume for prose.
const String kMonoFont = 'Adwaita Mono';
const List<String> kMonoFallback = ['Liberation Mono', 'monospace'];

const double _minTextContrast = 4.5;
const double _minButtonLabelContrast = 4.5;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The colours of one appearance mode.
@immutable
class VellumPalette extends ThemeExtension<VellumPalette> {
  const VellumPalette({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.surfaceHigh,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.text,
    required this.textDim,
    required this.warning,
    required this.onAccent,
    required this.shadow,
    required this.shadowAlpha,
    required this.shadowHoverAlpha,
    required this.placeholderInk,
    required this.placeholderText,
  });

  /// The page behind everything.
  final Color background;

  /// Navigation and secondary panels.
  final Color sidebar;

  /// Inputs, sheets, dialogs, and flat list surfaces.
  final Color surface;

  /// Selected rows, chips, and raised pieces of chrome.
  final Color surfaceHigh;

  /// Hairline borders. The covers carry the contrast; chrome only needs an
  /// edge to read as separate.
  final Color line;

  /// Primary action, selection, and focus.
  final Color accent;

  /// Accent blended toward the text colour until it reads on the background.
  final Color accentSoft;

  final Color text;
  final Color textDim;

  /// Failure and warning copy.
  final Color warning;

  /// Label colour on a filled accent control, derived for contrast.
  final Color onAccent;

  final Color shadow;
  final double shadowAlpha;
  final double shadowHoverAlpha;

  /// Cloth colour for a cover with no artwork, and the initial drawn on it.
  final Color placeholderInk;
  final Color placeholderText;

  /// Cover depth: matte at rest, a short lift under the pointer.
  BoxShadow coverShadow({required bool hovered}) => BoxShadow(
    color: shadow.withValues(alpha: hovered ? shadowHoverAlpha : shadowAlpha),
    blurRadius: hovered ? 20 : 6,
    offset: Offset(0, hovered ? 8 : 3),
  );

  /// Warm paper and ink, with the accent reserved for action and selection.
  static const VellumPalette light = VellumPalette(
    background: Color(0xFFF6F2EA),
    sidebar: Color(0xFFEFE9DE),
    surface: Color(0xFFFFFCF6),
    surfaceHigh: Color(0xFFE8E0D3),
    line: Color(0xFFD8CEBE),
    accent: Color(0xFF2190A4),
    accentSoft: Color(0xFF1B6C7A),
    text: Color(0xFF231F1A),
    textDim: Color(0xFF6B6357),
    warning: Color(0xFFA94733),
    onAccent: Color(0xFF101312),
    shadow: Colors.black,
    shadowAlpha: 0.06,
    shadowHoverAlpha: 0.16,
    placeholderInk: Color(0xFFDCD2C2),
    placeholderText: Color(0xFF4A4339),
  );

  /// The same room after dark: soft black-brown, parchment text.
  static const VellumPalette dark = VellumPalette(
    background: Color(0xFF14120F),
    sidebar: Color(0xFF191713),
    surface: Color(0xFF201D18),
    surfaceHigh: Color(0xFF2B2721),
    line: Color(0xFF3A342C),
    accent: Color(0xFF2190A4),
    accentSoft: Color(0xFF8FC7D0),
    text: Color(0xFFEFE8DC),
    textDim: Color(0xFFA79D8F),
    warning: Color(0xFFE08A76),
    onAccent: Color(0xFF101312),
    shadow: Colors.black,
    shadowAlpha: 0.18,
    shadowHoverAlpha: 0.42,
    placeholderInk: Color(0xFF2B2721),
    placeholderText: Color(0xFF8E8476),
  );

  /// `mode + accent -> palette`. Any shipped accent keeps the structure and
  /// derives the two colours that depend on it: a readable [accentSoft] and an
  /// [onAccent] that stays legible on filled buttons.
  static VellumPalette forMode(Brightness brightness, Color accent) {
    final base = brightness == Brightness.dark
        ? VellumPalette.dark
        : VellumPalette.light;
    if (accent == base.accent) return base;
    final towards = brightness == Brightness.dark ? Colors.white : Colors.black;
    return base.copyWith(
      accent: accent,
      accentSoft: _readableOn(
        accent,
        towards,
        base.background,
        base.sidebar,
        brightness == Brightness.dark ? 0.4 : 0.22,
      ),
      onAccent: _onAccent(accent),
    );
  }

  static Color _readableOn(
    Color accent,
    Color towards,
    Color background,
    Color sidebar,
    double blend,
  ) {
    var factor = blend;
    var candidate = Color.lerp(accent, towards, factor)!;
    while (factor < 1 &&
        (_contrast(candidate, background) < _minTextContrast ||
            _contrast(candidate, sidebar) < _minTextContrast)) {
      factor = math.min(1, factor + 0.05);
      candidate = Color.lerp(accent, towards, factor)!;
    }
    return candidate;
  }

  static Color _onAccent(Color accent) =>
      _contrast(Colors.white, accent) >= _minButtonLabelContrast
      ? Colors.white
      : Colors.black;

  @override
  VellumPalette copyWith({
    Color? background,
    Color? sidebar,
    Color? surface,
    Color? surfaceHigh,
    Color? line,
    Color? accent,
    Color? accentSoft,
    Color? text,
    Color? textDim,
    Color? warning,
    Color? onAccent,
    Color? shadow,
    double? shadowAlpha,
    double? shadowHoverAlpha,
    Color? placeholderInk,
    Color? placeholderText,
  }) => VellumPalette(
    background: background ?? this.background,
    sidebar: sidebar ?? this.sidebar,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    line: line ?? this.line,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    text: text ?? this.text,
    textDim: textDim ?? this.textDim,
    warning: warning ?? this.warning,
    onAccent: onAccent ?? this.onAccent,
    shadow: shadow ?? this.shadow,
    shadowAlpha: shadowAlpha ?? this.shadowAlpha,
    shadowHoverAlpha: shadowHoverAlpha ?? this.shadowHoverAlpha,
    placeholderInk: placeholderInk ?? this.placeholderInk,
    placeholderText: placeholderText ?? this.placeholderText,
  );

  @override
  VellumPalette lerp(covariant VellumPalette? other, double t) {
    if (other == null) return this;
    return VellumPalette(
      background: Color.lerp(background, other.background, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      line: Color.lerp(line, other.line, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      shadowAlpha: shadowAlpha + (other.shadowAlpha - shadowAlpha) * t,
      shadowHoverAlpha:
          shadowHoverAlpha + (other.shadowHoverAlpha - shadowHoverAlpha) * t,
      placeholderInk: Color.lerp(placeholderInk, other.placeholderInk, t)!,
      placeholderText: Color.lerp(placeholderText, other.placeholderText, t)!,
    );
  }
}

/// The radius scale. Every surface picks a step instead of inventing a value
/// that almost matches its neighbours.
abstract final class VellumRadius {
  static const Radius small = Radius.circular(4);
  static const Radius medium = Radius.circular(8);
  static const Radius large = Radius.circular(12);
  static const Radius xlarge = Radius.circular(16);

  static const BorderRadius smallAll = BorderRadius.all(small);
  static const BorderRadius mediumAll = BorderRadius.all(medium);
  static const BorderRadius largeAll = BorderRadius.all(large);
  static const BorderRadius xlargeAll = BorderRadius.all(xlarge);
}

/// The spacing scale. Tight groups sit at 4–8, sections at 24–32.
abstract final class VellumSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// `context.palette` — the colours of the appearance mode in effect.
extension VellumPaletteContext on BuildContext {
  VellumPalette get palette =>
      Theme.of(this).extension<VellumPalette>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? VellumPalette.dark
          : VellumPalette.light);
}

/// Type helpers that keep the three faces speaking in their own roles.
abstract final class VellumType {
  /// Newsreader, with its optical-size axis matched to [size].
  static TextStyle display(
    double size, {
    FontWeight weight = FontWeight.w500,
    double height = 1.15,
    double? letterSpacing,
    Color? color,
  }) => TextStyle(
    fontFamily: kDisplayFont,
    fontSize: size,
    height: height,
    letterSpacing: letterSpacing,
    color: color,
    fontWeight: weight,
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      FontVariation('opsz', size.clamp(6, 72).toDouble()),
    ],
  );

  /// Instrument Sans for interface copy.
  static TextStyle ui(
    double size, {
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    double? letterSpacing,
    Color? color,
  }) => TextStyle(
    fontFamily: kUiFont,
    fontSize: size,
    height: height,
    letterSpacing: letterSpacing,
    color: color,
    fontWeight: weight,
    fontVariations: [FontVariation('wght', weight.value.toDouble())],
  );

  /// Literata for reading text.
  static TextStyle reading(
    double size, {
    FontWeight weight = FontWeight.w400,
    double height = 1.65,
    Color? color,
  }) => TextStyle(
    fontFamily: kReaderFont,
    fontSize: size,
    height: height,
    color: color,
    fontWeight: weight,
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      FontVariation('opsz', size.clamp(7, 72).toDouble()),
    ],
  );

  /// Paths, IDs, and measurements.
  static TextStyle mono(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    fontFamily: kMonoFont,
    fontFamilyFallback: kMonoFallback,
    fontSize: size,
    color: color,
    fontWeight: weight,
  );
}

/// Theme data for both appearance modes, memoized per `(mode, accent)`.
class VellumTheme {
  static final Map<(Brightness, Color), ThemeData> _themes = {};

  static ThemeData themeFor(Brightness brightness, Color accent) =>
      _themes.putIfAbsent((
        brightness,
        accent,
      ), () => _build(VellumPalette.forMode(brightness, accent), brightness));

  static ThemeData _build(VellumPalette palette, Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          onPrimary: palette.onAccent,
          primaryContainer: palette.surfaceHigh,
          onPrimaryContainer: palette.text,
          secondary: palette.accentSoft,
          onSecondary: palette.onAccent,
          secondaryContainer: palette.surfaceHigh,
          onSecondaryContainer: palette.text,
          tertiary: palette.accentSoft,
          onTertiary: palette.onAccent,
          error: palette.warning,
          onError: Colors.white,
          surface: palette.background,
          onSurface: palette.text,
          onSurfaceVariant: palette.textDim,
          outline: palette.line,
          outlineVariant: palette.line,
          shadow: palette.shadow,
          scrim: palette.shadow,
          surfaceTint: Colors.transparent,
          surfaceContainerLowest: palette.background,
          surfaceContainerLow: palette.background,
          surfaceContainer: palette.surface,
          surfaceContainerHigh: palette.surface,
          surfaceContainerHighest: palette.surfaceHigh,
          inverseSurface: palette.text,
          onInverseSurface: palette.background,
          inversePrimary: palette.accentSoft,
        );

    final textTheme = TextTheme(
      displayLarge: VellumType.display(
        52,
        weight: FontWeight.w600,
        height: 1.02,
        letterSpacing: -0.9,
        color: palette.text,
      ),
      displayMedium: VellumType.display(
        42,
        weight: FontWeight.w600,
        height: 1.05,
        letterSpacing: -0.7,
        color: palette.text,
      ),
      displaySmall: VellumType.display(
        34,
        weight: FontWeight.w600,
        height: 1.08,
        letterSpacing: -0.5,
        color: palette.text,
      ),
      headlineMedium: VellumType.display(
        28,
        weight: FontWeight.w600,
        height: 1.12,
        letterSpacing: -0.35,
        color: palette.text,
      ),
      headlineSmall: VellumType.display(
        23,
        weight: FontWeight.w600,
        height: 1.16,
        letterSpacing: -0.2,
        color: palette.text,
      ),
      titleLarge: VellumType.display(
        19,
        weight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.1,
        color: palette.text,
      ),
      titleMedium: VellumType.ui(
        14,
        weight: FontWeight.w600,
        height: 1.35,
        color: palette.text,
      ),
      titleSmall: VellumType.ui(
        12.5,
        weight: FontWeight.w600,
        height: 1.35,
        color: palette.text,
      ),
      bodyLarge: VellumType.ui(14.5, height: 1.6, color: palette.text),
      bodyMedium: VellumType.ui(13.5, height: 1.55, color: palette.text),
      bodySmall: VellumType.ui(12, height: 1.5, color: palette.textDim),
      labelLarge: VellumType.ui(
        13,
        weight: FontWeight.w600,
        height: 1.2,
        color: palette.text,
      ),
      labelMedium: VellumType.ui(
        11.5,
        weight: FontWeight.w500,
        height: 1.2,
        color: palette.textDim,
      ),
      labelSmall: VellumType.ui(
        10.5,
        weight: FontWeight.w500,
        height: 1.2,
        color: palette.textDim,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: kUiFont,
      fontFamilyFallback: const ['Noto Sans', 'sans-serif'],
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      cardColor: palette.surface,
      splashFactory: InkRipple.splashFactory,
      focusColor: palette.accent.withValues(alpha: 0.18),
      hoverColor: palette.surfaceHigh.withValues(alpha: 0.6),
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      extensions: [palette],
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: palette.textDim, size: 18),
      primaryIconTheme: IconThemeData(color: palette.text, size: 18),
      dividerTheme: DividerThemeData(
        color: palette.line,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 58,
        titleSpacing: 20,
        titleTextStyle: VellumType.display(
          22,
          weight: FontWeight.w600,
          height: 1.2,
          letterSpacing: -0.2,
          color: palette.text,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          palette.textDim.withValues(alpha: 0.38),
        ),
        thickness: const WidgetStatePropertyAll(4),
        radius: const Radius.circular(3),
        crossAxisMargin: 3,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: palette.surfaceHigh,
          borderRadius: VellumRadius.smallAll,
          border: Border.all(color: palette.line),
        ),
        textStyle: VellumType.ui(11.5, height: 1.35, color: palette.text),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: VellumRadius.largeAll,
          side: BorderSide(color: palette.line),
        ),
        textStyle: VellumType.ui(13, color: palette.text),
        labelTextStyle: WidgetStatePropertyAll(
          VellumType.ui(13, color: palette.text),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(12),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: VellumRadius.largeAll,
              side: BorderSide(color: palette.line),
            ),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: VellumRadius.largeAll,
              side: BorderSide(color: palette.line),
            ),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        shape: RoundedRectangleBorder(
          borderRadius: VellumRadius.xlargeAll,
          side: BorderSide(color: palette.line),
        ),
        titleTextStyle: VellumType.display(
          24,
          weight: FontWeight.w600,
          color: palette.text,
        ),
        contentTextStyle: VellumType.ui(13.5, color: palette.textDim),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: VellumRadius.large),
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: VellumRadius.largeAll,
          side: BorderSide(color: palette.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        hintStyle: VellumType.ui(13, color: palette.textDim),
        prefixIconColor: palette.textDim,
        suffixIconColor: palette.textDim,
        iconColor: palette.textDim,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: VellumRadius.mediumAll,
          borderSide: BorderSide(color: palette.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: VellumRadius.mediumAll,
          borderSide: BorderSide(color: palette.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: VellumRadius.mediumAll,
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: VellumRadius.mediumAll,
          borderSide: BorderSide(color: palette.warning),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: VellumRadius.mediumAll,
          borderSide: BorderSide(color: palette.warning, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          disabledBackgroundColor: palette.surfaceHigh,
          disabledForegroundColor: palette.textDim,
          elevation: 0,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: VellumRadius.mediumAll,
          ),
          textStyle: VellumType.ui(13, weight: FontWeight.w600, height: 1.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.text,
          side: BorderSide(color: palette.line),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: VellumRadius.mediumAll,
          ),
          textStyle: VellumType.ui(13, weight: FontWeight.w600, height: 1.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accentSoft,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: const RoundedRectangleBorder(
            borderRadius: VellumRadius.mediumAll,
          ),
          textStyle: VellumType.ui(13, weight: FontWeight.w600, height: 1.2),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textDim,
          minimumSize: const Size(32, 32),
          maximumSize: const Size(40, 40),
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(
            borderRadius: VellumRadius.mediumAll,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: palette.surfaceHigh,
        disabledColor: palette.surface,
        side: BorderSide(color: palette.line),
        shape: const RoundedRectangleBorder(
          borderRadius: VellumRadius.smallAll,
        ),
        labelStyle: VellumType.ui(11.5, height: 1.2, color: palette.text),
        secondaryLabelStyle: VellumType.ui(
          11.5,
          height: 1.2,
          color: palette.text,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.surfaceHigh
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.text
                : palette.textDim,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: palette.line)),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: VellumRadius.mediumAll),
          ),
          textStyle: WidgetStatePropertyAll(
            VellumType.ui(12.5, weight: FontWeight.w600),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: palette.text,
        iconColor: palette.textDim,
        titleTextStyle: VellumType.ui(
          13.5,
          weight: FontWeight.w500,
          height: 1.35,
          color: palette.text,
        ),
        subtitleTextStyle: VellumType.ui(
          12,
          height: 1.45,
          color: palette.textDim,
        ),
        selectedColor: palette.text,
        selectedTileColor: palette.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        horizontalTitleGap: 10,
        minVerticalPadding: 8,
        shape: const RoundedRectangleBorder(
          borderRadius: VellumRadius.mediumAll,
        ),
        visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.onAccent
              : palette.textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.surfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : palette.line,
        ),
        thumbIcon: const WidgetStatePropertyAll(null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(palette.onAccent),
        side: BorderSide(color: palette.line, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        visualDensity: VisualDensity.compact,
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.textDim,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.surfaceHigh,
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.12),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: palette.surfaceHigh,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: VellumRadius.mediumAll,
        ),
        useIndicator: true,
        selectedIconTheme: IconThemeData(color: palette.accent, size: 19),
        unselectedIconTheme: IconThemeData(color: palette.textDim, size: 19),
        selectedLabelTextStyle: VellumType.ui(
          12.5,
          weight: FontWeight.w600,
          height: 1.3,
          color: palette.text,
        ),
        unselectedLabelTextStyle: VellumType.ui(
          12.5,
          weight: FontWeight.w500,
          height: 1.3,
          color: palette.textDim,
        ),
        minWidth: 64,
        minExtendedWidth: 184,
        groupAlignment: -1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.sidebar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: palette.surfaceHigh,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: VellumRadius.mediumAll,
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 20,
            color: states.contains(WidgetState.selected)
                ? palette.accent
                : palette.textDim,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => VellumType.ui(
            11,
            weight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? palette.text
                : palette.textDim,
          ),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accent.withValues(alpha: 0.24),
        selectionHandleColor: palette.accent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceHigh,
        contentTextStyle: VellumType.ui(13, color: palette.text),
        actionTextColor: palette.accentSoft,
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: VellumRadius.mediumAll,
          side: BorderSide(color: palette.line),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accent,
        linearTrackColor: palette.surfaceHigh,
        circularTrackColor: palette.surfaceHigh,
      ),
      dividerColor: palette.line,
      disabledColor: palette.textDim.withValues(alpha: 0.55),
    );
  }
}
