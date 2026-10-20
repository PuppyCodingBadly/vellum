/// Tests for vellum formats/dictionary.dart (mirrors tests/test_dictionary.py).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vellum/formats/dictionary.dart';

final _apiPayload = [
  {
    'word': 'test',
    'phonetic': '/tɛst/',
    'phonetics': [
      {'text': '/tɛst/'},
    ],
    'meanings': [
      {
        'partOfSpeech': 'noun',
        'definitions': [
          {'definition': 'A procedure.'},
          {'definition': 'An examination.'},
          {'definition': 'A trial.'},
          {'definition': 'A fourth one.'},
        ],
      },
      {
        'partOfSpeech': 'verb',
        'definitions': [
          {'definition': 'To challenge.'},
        ],
      },
      {
        'partOfSpeech': 'adjective',
        'definitions': [
          {'definition': 'For testing.'},
        ],
      },
      {
        'partOfSpeech': 'extra',
        'definitions': [
          {'definition': 'Should be capped.'},
        ],
      },
    ],
  },
];

final _wiktionaryPayload = {
  'en': [
    {
      'partOfSpeech': 'noun',
      'definitions': [
        {'definition': 'A <b>challenge</b> &amp; trial.'},
        {'definition': 'An examination.'},
      ],
    },
  ],
};

// The real APIs serve UTF-8 JSON; declare the charset so http.Response
// encodes/decodes the body as UTF-8 (it defaults to latin1 otherwise,
// which cannot encode phonetics like 'ɛ').
http.Response _json(Object? payload, [int status = 200]) =>
    http.Response(jsonEncode(payload), status,
        headers: const {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('normalizes entry with phonetic and caps', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return _json(_apiPayload);
    });
    final result = await lookup('Test', client: client);
    expect(seen!.url.toString(),
        'https://api.dictionaryapi.dev/api/v2/entries/en/test');
    expect(result!['word'], 'test');
    expect(result['phonetic'], '/tɛst/');
    final meanings = result['meanings'] as List;
    expect(meanings.length, 3); // MAX_MEANINGS
    expect((meanings[0] as Map)['partOfSpeech'], 'noun');
    expect(((meanings[0] as Map)['definitions'] as List).length, 3);
    expect((meanings[0] as Map)['definitions'],
        ['A procedure.', 'An examination.', 'A trial.']);
  });

  test('uses language in URL', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return _json(_apiPayload);
    });
    await lookup('hola', language: 'es', client: client);
    expect(seen!.url.toString(),
        'https://api.dictionaryapi.dev/api/v2/entries/es/hola');
  });

  test('phonetic falls back to phonetics list', () async {
    final client = MockClient((req) async => _json([
          {
            'word': 'test',
            'phonetic': '',
            'phonetics': [
              {'text': ''},
              {'text': '/fallback/'},
            ],
            'meanings': [],
          },
        ]));
    final result = await lookup('test', client: client);
    expect(result!['phonetic'], '/fallback/');
    expect(result['meanings'], isEmpty);
  });

  test('empty word returns null without request', () async {
    var called = false;
    final client = MockClient((req) async {
      called = true;
      return _json(_apiPayload);
    });
    expect(await lookup('   ', client: client), isNull);
    expect(called, isFalse);
  });

  test('404 on both providers returns null after two requests', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('not found', 404);
    });
    expect(await lookup('test', client: client), isNull);
    expect(calls, 2);
  });

  test('network error on both providers returns null, never throws', () async {
    final client = MockClient((req) async => throw http.ClientException('boom'));
    expect(await lookup('test', client: client), isNull);
  });

  test('bad payload returns null', () async {
    final client = MockClient((req) async => http.Response('{"oops": true', 200));
    expect(await lookup('test', client: client), isNull);
  });

  test('falls back to wiktionary on primary 5xx', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'api.dictionaryapi.dev') {
        return http.Response('server error', 530);
      }
      return _json(_wiktionaryPayload);
    });
    final result = await lookup('test', client: client);
    expect(result, isNotNull);
    expect(result!['word'], 'test');
    expect(result['phonetic'], '');
    final meanings = result['meanings'] as List;
    expect(meanings.length, 1);
    expect((meanings[0] as Map)['partOfSpeech'], 'noun');
    expect((meanings[0] as Map)['definitions'],
        ['A challenge & trial.', 'An examination.']);
  });

  test('falls back on primary network error and strips HTML', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'api.dictionaryapi.dev') {
        throw http.ClientException('connection refused');
      }
      expect(req.headers['User-Agent'], userAgent);
      return _json(_wiktionaryPayload);
    });
    final result = await lookup('test', client: client);
    expect((result!['meanings'] as List).length, 1);
  });

  test('wiktionary without definitions returns null', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'api.dictionaryapi.dev') {
        return http.Response('nope', 404);
      }
      return _json({
        'en': [
          {'partOfSpeech': 'noun', 'definitions': []},
        ],
      });
    });
    expect(await lookup('test', client: client), isNull);
  });
}
