/// Tests for the universal URL metadata grabber.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/metadata/universal.dart';

void main() {
  test('json-ld book metadata', () {
    const html = '''
    <html><head>
      <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "Book",
        "name": "Dune",
        "author": [{"@type": "Person", "name": "Frank Herbert"}],
        "isbn": "9780441013593",
        "publisher": {"@type": "Organization", "name": "Ace"},
        "datePublished": "1965-08-01",
        "inLanguage": "en",
        "description": "<p>Spice must flow.</p>",
        "image": "/covers/dune.jpg",
        "aggregateRating": {"ratingValue": "9", "bestRating": "10"},
        "genre": "Science Fiction"
      }
      </script>
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://shop.example/books/dune');
    expect(meta, isNotNull);
    expect(meta!.title, 'Dune');
    expect(meta.authors, ['Frank Herbert']);
    expect(meta.isbn, '9780441013593');
    expect(meta.publisher, 'Ace');
    expect(meta.pubdate, '1965-08-01');
    expect(meta.language, 'en');
    expect(meta.description, 'Spice must flow.');
    expect(meta.coverUrl, 'https://shop.example/covers/dune.jpg');
    expect(meta.rating, 4.5);
    expect(meta.tags, ['Science Fiction']);
  });

  test('opengraph and meta fallback', () {
    const html = '''
    <html><head>
      <title>Ignored because OG wins</title>
      <meta property="og:title" content="The OG Book">
      <meta property="og:description" content="A description.">
      <meta property="book:author" content="Jane Doe">
      <meta property="book:author" content="John Roe">
      <meta property="book:isbn" content="9780000000001">
      <meta property="book:release_date" content="2001-02-03">
      <meta property="og:image" content="cover.jpg">
      <meta property="og:site_name" content="Example Books">
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/book/1');
    expect(meta, isNotNull);
    expect(meta!.title, 'The OG Book');
    expect(meta.authors, ['Jane Doe', 'John Roe']);
    expect(meta.isbn, '9780000000001');
    expect(meta.pubdate, '2001-02-03');
    expect(meta.coverUrl, 'https://example.com/book/cover.jpg');
    expect(meta.sourceName, 'Example Books');
  });

  test('microdata and title fallback', () {
    const html = '''
    <html><head><title>A Plain Title</title></head><body>
      <div itemscope itemtype="https://schema.org/Book">
        <span itemprop="name">Microdata Book</span>
        <span itemprop="author">Ada Lovelace</span>
      </div>
    </body></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/x');
    expect(meta, isNotNull);
    expect(meta!.title, 'Microdata Book');
    expect(meta.authors, ['Ada Lovelace']);
  });

  test('no title returns null', () {
    expect(parseBookPage('<html><body>hello</body></html>'), isNull);
  });

  test('normalize url adds scheme', () {
    expect(normalizeUrl('example.com/book'), 'https://example.com/book');
    expect(normalizeUrl('https://example.com/book'), 'https://example.com/book');
    expect(normalizeUrl(''), '');
  });

  test('search string is not a url', () {
    expect(normalizeUrl('Dune Frank Herbert'), '');
    expect(normalizeUrl('dune'), '');
    expect(normalizeUrl('https://example.com/a book'), '');
    expect(normalizeUrl(''), '');
  });

  test('grab rejects search strings', () {
    expect(() => UniversalGrabber().grab('Dune Frank Herbert'),
        throwsFormatException);
  });

  test('grab decodes latin1 charset', () async {
    final client = MockClient((request) async {
      final body = latin1.encode(
          '<html><head><title>Caf\xe9 Society</title></head></html>');
      return http.Response.bytes(body, 200, headers: {
        'content-type': 'text/html; charset=iso-8859-1',
      });
    });
    final meta = await UniversalGrabber()
        .grab('https://example.com/book', client: client);
    expect(meta, isNotNull);
    expect(meta!.title, 'Caf\xe9 Society');
  });

  test('grab decodes latin1 for text/html without declared charset', () async {
    final client = MockClient((request) async => http.Response(
        '<html><head><title>Café</title></head></html>', 200,
        headers: {'content-type': 'text/html'}));
    final meta = await UniversalGrabber()
        .grab('https://example.com/book', client: client);
    expect(meta!.title, 'Café');
  });

  test('grab decodes utf-8 for non-text types without charset', () async {
    final client = MockClient((request) async => http.Response.bytes(
        utf8.encode('<html><head><title>Café</title></head></html>'), 200,
        headers: {'content-type': 'application/xhtml+xml'}));
    final meta = await UniversalGrabber()
        .grab('https://example.com/book', client: client);
    expect(meta!.title, 'Café');
  });

  test('json-ld numeric html entities are unescaped', () {
    const html = '''
    <html><head>
      <script type="application/ld+json">
      {"@type": "Book", "name": "Tom &#x26; Jerry &#65;"}
      </script>
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/');
    expect(meta!.title, 'Tom & Jerry A');
  });

  test('json-ld @graph keeps typed parent', () {
    const html = '''
    <html><head>
      <script type="application/ld+json">
      {
        "@type": "Book",
        "name": "Parent Book",
        "author": {"@type": "Person", "name": "Ann"},
        "@graph": [{"@type": "WebPage", "name": "Page"}]
      }
      </script>
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/');
    expect(meta, isNotNull);
    expect(meta!.title, 'Parent Book');
    expect(meta.authors, ['Ann']);
  });

  test('json-ld genre splits on commas only', () {
    const html = '''
    <html><head>
      <script type="application/ld+json">
      {"@type": "Book", "name": "T", "genre": "Science Fiction; Fantasy, Drama"}
      </script>
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/');
    expect(meta!.tags, ['Science Fiction; Fantasy', 'Drama']);
  });

  test('json-ld rating bestRating zero falls back to five', () {
    const html = '''
    <html><head>
      <script type="application/ld+json">
      {"@type": "Book", "name": "T",
       "aggregateRating": {"ratingValue": "3", "bestRating": "0"}}
      </script>
    </head></html>
    ''';
    final meta = parseBookPage(html, 'https://example.com/');
    expect(meta!.rating, 3.0);
  });

  test('engine merge results', () {
    final first =
        Metadata(title: 'Book', authors: ['A'], description: 'short', rating: 3.0);
    final second = Metadata(
      title: 'Book',
      authors: ['B'],
      isbn: '123',
      description: 'a much longer description',
      coverUrl: 'https://example.com/cover.jpg',
      rating: 4.0,
    );
    final merged = MetadataEngine.mergeResults([first, second]);
    expect(merged, isNotNull);
    expect(merged!.authors, ['A', 'B']);
    expect(merged.isbn, '123');
    expect(merged.description, 'a much longer description');
    expect(merged.coverUrl, 'https://example.com/cover.jpg');
    expect(merged.rating, 4.0);
    expect(merged.sourceName, 'Merged sources');
  });
}
