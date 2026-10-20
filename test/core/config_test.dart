import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vellum/core/config.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-config');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('defaults', () {
    final config = VellumConfig('${tmp.path}/config.json');
    expect(config.getString('color_scheme'), 'system');
    expect(config.getString('accent_color'), 'blue');
    expect(config.getBool('show_hidden'), isFalse);
    expect(config.getString('sort_key'), 'title');
    expect(config.getBool('reader_animation'), isTrue);
    expect(config.getDouble('reader_font_scale'), 1.0);
    expect(config.getString('reader_theme'), 'follow');
    expect(config.getBool('legacy_demo_books_purged'), isFalse);
    expect(config.getString('library_path'),
        '${VellumConfig.dataDir()}/library.db');
  });

  test('set saves on change and reloads', () {
    final path = '${tmp.path}/config.json';
    final config = VellumConfig(path);
    config.set('color_scheme', 'dark');
    config.set('show_hidden', true);
    config.set('reader_font_scale', 1.4);

    // File written immediately.
    final onDisk = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(onDisk['color_scheme'], 'dark');

    final reloaded = VellumConfig(path);
    expect(reloaded.getString('color_scheme'), 'dark');
    expect(reloaded.getBool('show_hidden'), isTrue);
    expect(reloaded.getDouble('reader_font_scale'), 1.4);
    // Untouched keys keep defaults.
    expect(reloaded.getString('accent_color'), 'blue');
  });

  test('corrupt file falls back to defaults', () {
    final path = '${tmp.path}/config.json';
    File(path).writeAsStringSync('{not json');
    final config = VellumConfig(path);
    expect(config.getString('color_scheme'), 'system');
  });

  test('dataDir honors XDG-style location and ends with vellum', () {
    // Env vars cannot be mutated per-test; verify shape only.
    expect(VellumConfig.dataDir(), endsWith('/vellum'));
    expect(VellumConfig.dataDir(), contains('.local/share'));
  });
}
