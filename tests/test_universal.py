"""Tests for the universal URL metadata grabber."""

from __future__ import annotations

from vellum.metadata.engine import MetadataEngine
from vellum.metadata.sources.base import Metadata
from vellum.metadata.universal import normalize_url, parse_book_page


def test_jsonld_book_metadata():
    html = """
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
    """
    meta = parse_book_page(html, "https://shop.example/books/dune")
    assert meta is not None
    assert meta.title == "Dune"
    assert meta.authors == ["Frank Herbert"]
    assert meta.isbn == "9780441013593"
    assert meta.publisher == "Ace"
    assert meta.pubdate == "1965-08-01"
    assert meta.language == "en"
    assert meta.description == "Spice must flow."
    assert meta.cover_url == "https://shop.example/covers/dune.jpg"
    assert meta.rating == 4.5
    assert meta.tags == ["Science Fiction"]


def test_opengraph_and_meta_fallback():
    html = """
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
    """
    meta = parse_book_page(html, "https://example.com/book/1")
    assert meta is not None
    assert meta.title == "The OG Book"
    assert meta.authors == ["Jane Doe", "John Roe"]
    assert meta.isbn == "9780000000001"
    assert meta.pubdate == "2001-02-03"
    assert meta.cover_url == "https://example.com/book/cover.jpg"
    assert meta.source_name == "Example Books"


def test_microdata_and_title_fallback():
    html = """
    <html><head><title>A Plain Title</title></head><body>
      <div itemscope itemtype="https://schema.org/Book">
        <span itemprop="name">Microdata Book</span>
        <span itemprop="author">Ada Lovelace</span>
      </div>
    </body></html>
    """
    meta = parse_book_page(html, "https://example.com/x")
    assert meta is not None
    assert meta.title == "Microdata Book"
    assert meta.authors == ["Ada Lovelace"]


def test_no_title_returns_none():
    assert parse_book_page("<html><body>hello</body></html>") is None


def test_normalize_url_adds_scheme():
    assert normalize_url("example.com/book") == "https://example.com/book"
    assert normalize_url("https://example.com/book") == "https://example.com/book"
    assert normalize_url("") == ""


def test_engine_merge_results():
    first = Metadata(
        title="Book", authors=["A"], description="short", rating=3.0
    )
    second = Metadata(
        title="Book",
        authors=["B"],
        isbn="123",
        description="a much longer description",
        cover_url="https://example.com/cover.jpg",
        rating=4.0,
    )
    merged = MetadataEngine.merge_results([first, second])
    assert merged is not None
    assert merged.authors == ["A", "B"]
    assert merged.isbn == "123"
    assert merged.description == "a much longer description"
    assert merged.cover_url == "https://example.com/cover.jpg"
    assert merged.rating == 4.0
    assert merged.source_name == "Merged sources"


def test_search_string_is_not_a_url():
    assert normalize_url("Dune Frank Herbert") == ""
    assert normalize_url("dune") == ""
    assert normalize_url("https://example.com/a book") == ""
    assert normalize_url("") == ""


def test_grab_rejects_search_strings():
    import pytest

    from vellum.metadata.universal import UniversalGrabber

    with pytest.raises(ValueError):
        UniversalGrabber().grab("Dune Frank Herbert")
