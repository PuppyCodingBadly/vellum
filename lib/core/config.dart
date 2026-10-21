/// JSON-file-backed application configuration.
///
/// Ports the config handling of `vellum/app.py`.
library;

import 'dart:convert';
import 'dart:io';

/// Application settings persisted as plain JSON.
class VellumConfig {
  final String path;
  final Map<String, Object?> _values;

  VellumConfig._(this.path, this._values);

  /// Loads config from [path]; missing/corrupt files fall back to defaults.
  factory VellumConfig(String path) {
    var values = <String, Object?>{};
    try {
      final file = File(path);
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, Object?>) {
          values = Map<String, Object?>.of(decoded);
        } else if (decoded is Map) {
          values = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      }
    } catch (_) {
      // Corrupt config: start from defaults.
    }
    return VellumConfig._(path, values);
  }

  /// `~/.local/share/vellum`, honoring `XDG_DATA_HOME`.
  static String dataDir() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : '${Platform.environment['HOME'] ?? Directory.current.path}/.local/share';
    return '$base/vellum';
  }

  static final Map<String, Object?> _defaults = {
    'color_scheme': 'system',
    'accent_color': 'blue',
    'show_hidden': false,
    'sort_key': 'title',
    'reader_animation': true,
    'reader_font_scale': 1.0,
    'reader_theme': 'follow',
    'legacy_demo_books_purged': false,
  };

  /// Reads [key]; returns the default when unset. `library_path` defaults to
  /// `<dataDir>/library.db` and `null` when the key is unknown.
  Object? get(String key) {
    if (_values.containsKey(key)) return _values[key];
    if (key == 'library_path') return '${dataDir()}/library.db';
    return _defaults[key];
  }

  /// Typed getters fall back to the default when the stored value has the
  /// wrong type (corrupt config should never throw).
  String getString(String key) {
    final v = get(key);
    if (v is String) return v;
    return _defaults[key] as String;
  }

  bool getBool(String key) {
    final v = get(key);
    if (v is bool) return v;
    return _defaults[key] as bool;
  }

  double getDouble(String key) {
    final v = get(key);
    if (v is num) return v.toDouble();
    return (_defaults[key] as num).toDouble();
  }

  /// Sets [key] to [value] and saves immediately.
  void set(String key, Object? value) {
    _values[key] = value;
    save();
  }

  /// Persists the config to disk.
  void save() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(_values));
  }
}
