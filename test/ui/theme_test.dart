/// Unit tests for the visual system's accent palette: resolution, the
/// derived soft accent, and the shared readable-ink decision.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/ui/theme.dart';

/// WCAG 2.1 contrast, computed here rather than reusing the theme's helper so
/// the expectation is independent.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  test('accent settings resolve through the named palette or as hex', () {
    expect(VellumAccents.named, hasLength(9));
    expect(VellumAccents.resolve('purple'), VellumAccents.named['purple']);
    expect(VellumAccents.resolve(' #123456 '), const Color(0xFF123456));
    expect(VellumAccents.resolve('chartreuse'), VellumAccents.named['blue']);
  });

  test('accentSoft clears 4.5:1 on every surface it is painted on', () {
    final palettes = <VellumPalette>[
      VellumPalette.light,
      VellumPalette.dark,
      for (final accent in VellumAccents.named.values)
        for (final brightness in Brightness.values)
          VellumPalette.forMode(brightness, accent),
    ];
    for (final palette in palettes) {
      for (final surface in [
        palette.background,
        palette.sidebar,
        palette.surface,
        palette.surfaceHigh,
      ]) {
        expect(
          _contrast(palette.accentSoft, surface),
          greaterThanOrEqualTo(4.5),
          reason: 'accentSoft ${palette.accentSoft} on $surface',
        );
      }
    }
  });

  test('an accentSoft that used to fail on raised chrome is now darkened', () {
    const blue = Color(0xFF3584E4);
    final palette = VellumPalette.forMode(Brightness.light, blue);
    // The old derivation blended only 22% toward black: that cleared the page
    // and sidebar but not the darker raised chrome (snackbars, chips).
    final oldSoft = Color.lerp(blue, Colors.black, 0.22)!;
    expect(_contrast(oldSoft, palette.surfaceHigh), lessThan(4.5));
    expect(
      _contrast(palette.accentSoft, palette.surfaceHigh),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('swatch ink matches the derived filled-button label', () {
    // The shipped default palette pins its own warm-black label ink; every
    // accent that goes through the derivation must match the shared helper.
    final derivedAccents = [
      ...VellumAccents.named.values.where(
        (accent) => accent != VellumPalette.light.accent,
      ),
      const Color(0xFF66CC99),
      const Color(0xFFF5C542),
    ];
    for (final accent in derivedAccents) {
      expect(
        readableInkOn(accent),
        VellumPalette.forMode(Brightness.light, accent).onAccent,
        reason: 'accent $accent must label itself the same way everywhere',
      );
      expect(
        readableInkOn(accent),
        VellumPalette.forMode(Brightness.dark, accent).onAccent,
        reason: 'accent $accent labels itself the same in both modes',
      );
    }
    // A mid-light accent: luminance alone says white, but white fails 4.5:1.
    expect(readableInkOn(const Color(0xFF66CC99)), Colors.black);
  });
}
