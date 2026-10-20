/// Tests for the universal URL metadata grabber.
library;

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
