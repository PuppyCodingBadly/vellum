/// Dictionary lookups via the Free Dictionary API, with Wiktionary
/// fallback — port of vellum/core/dictionary.py. Never throws.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const apiUrl = 'https://api.dictionaryapi.dev/api/v2/entries/{language}/{word}';
const wiktionaryUrl =
    'https://{language}.wiktionary.org/api/rest_v1/page/definition/{word}';
const userAgent = 'Vellum/0.1 (ebook reader; contact: none)';

const maxMeanings = 3;
const maxDefinitions = 3;

final _tagRe = RegExp(r'<[^>]+>');

/// Percent-encode like Python's `urllib.parse.quote(word, safe='')`:
/// everything except unreserved characters (A-Z a-z 0-9 - _ . ~) is
/// escaped (UTF-8 bytes, uppercase hex).
String _quote(String word) {
  final sb = StringBuffer();
  for (final b in utf8.encode(word)) {
    final unreserved = b >= 0x30 && b <= 0x39 || // 0-9
        b >= 0x41 && b <= 0x5A || // A-Z
        b >= 0x61 && b <= 0x7A || // a-z
        b == 0x2D || // -
        b == 0x2E || // .
        b == 0x5F || // _
        b == 0x7E; // ~
    if (unreserved) {
      sb.writeCharCode(b);
    } else {
      sb.write('%');
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return sb.toString();
}

/// Look up a word's definition.
///
/// Returns a normalized map:
/// `{ "word": str, "phonetic": str, "meanings": [
///   {"partOfSpeech": str, "definitions": [str, ...]}, ... ] }`.
/// Meanings are capped at 3 and definitions at 3 per meaning. Tries
/// dictionaryapi.dev first, then Wiktionary; returns null only when both
/// providers fail. Never throws.
Future<Map<String, Object?>?> lookup(
  String word, {
  String language = 'en',
  http.Client? client,
}) async {
  word = word.trim().toLowerCase();
  if (word.isEmpty) return null;
  final c = client ?? http.Client();
  try {
    final result = await _lookupDictionaryApi(word, language, c);
    if (result != null) return result;
    return await _lookupWiktionary(word, language, c);
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

Future<Map<String, Object?>?> _lookupDictionaryApi(
  String word,
  String language,
  http.Client client,
) async {
  final url = apiUrl
      .replaceAll('{language}', language)
      .replaceAll('{word}', _quote(word));
  try {
    final response =
        await client.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('HTTP ${response.statusCode}', Uri.parse(url));
    }
    final data = jsonDecode(response.body);
    return _normalizeEntry((data as List)[0] as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _normalizeEntry(Map<String, dynamic> entry) {
  var phonetic = (entry['phonetic'] as String?) ?? '';
  if (phonetic.isEmpty) {
    for (final item in (entry['phonetics'] as List?) ?? const []) {
      final text = ((item as Map)['text'] as String? ?? '').trim();
      if (text.isNotEmpty) {
        phonetic = text;
        break;
      }
    }
  }

  final meanings = <Map<String, Object?>>[];
  for (final meaning
      in ((entry['meanings'] as List?) ?? const []).take(maxMeanings)) {
    final m = meaning as Map;
    final definitions = <String>[];
    for (final definition in ((m['definitions'] as List?) ?? const [])) {
      final text = (((definition as Map)['definition']) as String? ?? '').trim();
      if (text.isNotEmpty) definitions.add(text);
      if (definitions.length >= maxDefinitions) break;
    }
    meanings.add({
      'partOfSpeech': (m['partOfSpeech'] as String?) ?? '',
      'definitions': definitions,
    });
  }

  return {
    'word': (entry['word'] as String?) ?? '',
    'phonetic': phonetic,
    'meanings': meanings,
  };
}

Future<Map<String, Object?>?> _lookupWiktionary(
  String word,
  String language,
  http.Client client,
) async {
  final url = wiktionaryUrl
      .replaceAll('{language}', language)
      .replaceAll('{word}', _quote(word));
  try {
    final response = await client
        .get(Uri.parse(url), headers: {'User-Agent': userAgent})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('HTTP ${response.statusCode}', Uri.parse(url));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return _normalizeWiktionary(word, data);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _normalizeWiktionary(
  String word,
  Map<String, dynamic> data,
) {
  final meanings = <Map<String, Object?>>[];
  for (final entries in data.values) {
    for (final entry
        in ((entries as List?) ?? const []).take(maxMeanings - meanings.length)) {
      final e = entry as Map;
      final definitions = <String>[];
      for (final definition in ((e['definitions'] as List?) ?? const [])) {
        final text =
            _stripHtml(((definition as Map)['definition']) as String? ?? '');
        if (text.isNotEmpty) definitions.add(text);
        if (definitions.length >= maxDefinitions) break;
      }
      if (definitions.isNotEmpty) {
        meanings.add({
          'partOfSpeech': (e['partOfSpeech'] as String?) ?? '',
          'definitions': definitions,
        });
      }
    }
    if (meanings.length >= maxMeanings) break;
  }
  if (meanings.isEmpty) {
    throw const FormatException('wiktionary entry has no definitions');
  }
  return {
    'word': word,
    'phonetic': '',
    'meanings': meanings.take(maxMeanings).toList(),
  };
}

String _stripHtml(String text) =>
    _unescapeHtml(text.replaceAll(_tagRe, '')).trim();

/// Minimal HTML entity unescaping (mirrors Python's html.unescape for the
/// entities realistically seen in Wiktionary output).
String _unescapeHtml(String text) {
  return text
      .replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (m) {
        final raw = m.group(1)!;
        final code = raw.startsWith('x') || raw.startsWith('X')
            ? int.tryParse(raw.substring(1), radix: 16)
            : int.tryParse(raw);
        if (code == null) return m.group(0)!;
        // Mirror Python's html.unescape: out-of-range and surrogate code
        // points become U+FFFD instead of throwing RangeError.
        if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
          return '\uFFFD';
        }
        return String.fromCharCode(code);
      })
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}
