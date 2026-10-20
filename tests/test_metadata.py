"""Tests for metadata sources and engine. All network access is mocked."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from vellum.metadata.engine import MetadataEngine
from vellum.metadata.sources.base import Metadata, MetadataSource
from vellum.metadata.sources.google_books import GoogleBooks
from vellum.metadata.sources.openlibrary import OpenLibrary

GOOGLE_PAYLOAD = {
    "items": [
        {
            "id": "gb-1",
            "volumeInfo": {
                "title": "Example Book",
                "authors": ["Jane Doe", "John Smith"],
                "industryIdentifiers": [
                    {"type": "ISBN_10", "identifier": "0123456789"},
                    {"type": "ISBN_13", "identifier": "9780123456789"},
                ],
                "publisher": "Example Press",
                "publishedDate": "2020-05-01",
                "language": "en",
                "description": "A fine book.",
                "categories": ["Fiction", "Adventure"],
                "averageRating": 4.5,
                "imageLinks": {"thumbnail": "http://books.google.com/img?zoom=1&id=x"},
            },
        }
    ]
}

OPENLIBRARY_PAYLOAD = {
    "docs": [
        {
            "key": "/works/OL1W",
            "title": "Example Book",
            "author_name": ["Jane Doe"],
            "isbn": ["0123456789", "9780123456789"],
            "publisher": ["Example Press", "Other Press"],
            "first_publish_year": 2020,
            "language": ["eng"],
            "subject": ["Fiction", "Adventure", "Drama", "History", "Magic",
                        "Mystery", "Romance", "Science", "Travel"],
            "cover_i": 12345,
        }
    ]
}


def make_response(payload, content=b""):
    resp = MagicMock()
    resp.json.return_value = payload
    resp.content = content
    resp.raise_for_status.return_value = None
    return resp


def test_google_books_mapping():
    with patch(
        "vellum.metadata.sources.google_books.requests.get",
        return_value=make_response(GOOGLE_PAYLOAD),
    ) as mock_get:
        source = GoogleBooks()
        results = source.search(title="Example Book", authors=["Jane Doe"])
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Example Book"
    assert meta.authors == ["Jane Doe", "John Smith"]
    assert meta.isbn == "9780123456789"  # ISBN_13 preferred over ISBN_10
    assert meta.publisher == "Example Press"
    assert meta.pubdate == "2020-05-01"
    assert meta.language == "en"
    assert meta.tags == ["Fiction", "Adventure"]  # from categories
    assert meta.rating == 4.5
    assert meta.cover_url == "http://books.google.com/img?zoom=0&id=x"  # zoom tweak
    assert meta.source_id == "gb-1"
    assert meta.source_name == "Google Books"
    params = mock_get.call_args.kwargs["params"]
    assert "intitle:Example Book" in params["q"]
    assert "inauthor:Jane Doe" in params["q"]
    assert params["maxResults"] == 20


def test_google_books_error_returns_empty():
    with patch(
        "vellum.metadata.sources.google_books.requests.get",
        side_effect=Exception("boom"),
    ):
        assert GoogleBooks().search(title="x") == []


def test_openlibrary_mapping():
    with patch(
        "vellum.metadata.sources.openlibrary.requests.get",
        return_value=make_response(OPENLIBRARY_PAYLOAD),
    ) as mock_get:
        source = OpenLibrary()
        results = source.search(title="Example Book")
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Example Book"
    assert meta.authors == ["Jane Doe"]
    assert meta.isbn == "9780123456789"  # 13-digit preferred
    assert meta.publisher == "Example Press"
    assert meta.pubdate == "2020"
    assert meta.language == "eng"
    assert len(meta.tags) == 8  # subject[:8]
    assert meta.cover_url == "https://covers.openlibrary.org/b/id/12345-L.jpg"
    assert meta.source_id == "/works/OL1W"
    assert meta.source_name == "Open Library"
    params = mock_get.call_args.kwargs["params"]
    assert params["title"] == "Example Book"
    assert params["limit"] == 20


def test_openlibrary_error_returns_empty():
    with patch(
        "vellum.metadata.sources.openlibrary.requests.get",
        side_effect=Exception("boom"),
    ):
        assert OpenLibrary().search(title="x") == []


def _stub_source(source_id, results):
    source = MagicMock(spec=MetadataSource)
    source.id = source_id
    source.search.return_value = results
    return source


def test_engine_dedupes_by_isbn_and_sorts_rating_desc():
    low = Metadata(title="Book", authors=["A"], isbn="111", rating=3.0, source_id="s1")
    high = Metadata(title="Book", authors=["A"], isbn="111", rating=4.5, source_id="s2")
    other = Metadata(title="Other", authors=["B"], isbn="222", rating=4.0, source_id="s1")
    engine = MetadataEngine()
    engine.register_source(_stub_source("s1", [low, other]))
    engine.register_source(_stub_source("s2", [high]))
    results = engine.find(title="Book")
    assert len(results) == 2
    assert results[0].rating == 4.5
    assert results[0].source_id == "s2"  # higher-rating copy kept
    assert results[1].rating == 4.0


def test_engine_dedupes_by_title_authors_without_isbn():
    a = Metadata(title="Same", authors=["X"], rating=1.0)
    b = Metadata(title="same", authors=["x"], rating=2.0)
    engine = MetadataEngine()
    engine.register_source(_stub_source("s1", [a]))
    engine.register_source(_stub_source("s2", [b]))
    results = engine.find(title="Same")
    assert len(results) == 1
    assert results[0].rating == 2.0


def test_engine_swallows_failing_source():
    failing = MagicMock(spec=MetadataSource)
    failing.id = "bad"
    failing.search.side_effect = Exception("source exploded")
    good = _stub_source("good", [Metadata(title="Ok", rating=1.0)])
    engine = MetadataEngine()
    engine.register_source(failing)
    engine.register_source(good)
    results = engine.find(title="Ok")
    assert len(results) == 1
    assert results[0].title == "Ok"


def test_engine_fetch_cover_returns_bytes():
    meta = Metadata(title="Book", source_id="good", cover_url="http://x/cover.jpg")
    source = _stub_source("good", [])
    source.download_cover.return_value = b"JPEGDATA"
    engine = MetadataEngine()
    engine.register_source(source)
    assert engine.fetch_cover(meta) == b"JPEGDATA"
    source.download_cover.assert_called_once_with(meta)


def test_engine_fetch_cover_unknown_source():
    engine = MetadataEngine()
    assert engine.fetch_cover(Metadata(source_id="nope")) is None


def test_download_cover_google_books():
    meta = Metadata(cover_url="http://x/cover.jpg")
    with patch(
        "vellum.metadata.sources.google_books.requests.get",
        return_value=make_response({}, content=b"IMG"),
    ):
        assert GoogleBooks().download_cover(meta) == b"IMG"


def test_download_cover_openlibrary():
    meta = Metadata(cover_url="https://covers.openlibrary.org/b/id/1-L.jpg")
    with patch(
        "vellum.metadata.sources.openlibrary.requests.get",
        return_value=make_response({}, content=b"IMG"),
    ):
        assert OpenLibrary().download_cover(meta) == b"IMG"
