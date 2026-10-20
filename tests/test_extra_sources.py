"""Tests for the additional built-in metadata sources."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from vellum.metadata.sources.crossref import Crossref
from vellum.metadata.sources.internet_archive import InternetArchive
from vellum.metadata.sources.library_of_congress import LibraryOfCongress


def _response(payload):
    resp = MagicMock()
    resp.json.return_value = payload
    resp.raise_for_status.return_value = None
    resp.headers = {}
    return resp


IA_PAYLOAD = {
    "response": {
        "docs": [
            {
                "identifier": "dune",
                "title": "Dune",
                "creator": "Frank Herbert",
                "date": "1965",
                "publisher": "Chilton",
                "language": "eng",
                "description": ["<p>Spice must flow.</p>"],
                "subject": ["Science fiction"],
                "isbn": ["0441013597", "9780441013593"],
            }
        ]
    }
}

LOC_PAYLOAD = {
    "results": [
        {
            "id": "http://www.loc.gov/item/1",
            "title": "Dune",
            "contributor": ["Herbert, Frank"],
            "date": "1965",
            "description": ["A novel."],
            "image_url": ["https://example.com/cover.jpg#h=1"],
            "subject": ["Science fiction"],
            "language": ["eng"],
            "item": {
                "created_published": ["New York : Chilton, 1965."],
                "language": ["eng"],
            },
        }
    ]
}

CROSSREF_PAYLOAD = {
    "message": {
        "items": [
            {
                "DOI": "10.1234/dune",
                "title": ["Dune"],
                "author": [{"given": "Frank", "family": "Herbert"}],
                "publisher": "Chilton",
                "published": {"date-parts": [[1965]]},
                "ISBN": ["9780441013593"],
                "subject": ["Science fiction"],
                "abstract": "<jats:p>Spice must flow.</jats:p>",
            }
        ]
    }
}


def test_internet_archive_mapping():
    with patch(
        "vellum.metadata.sources.internet_archive.requests.get",
        return_value=_response(IA_PAYLOAD),
    ) as get:
        results = InternetArchive().search(title="Dune")
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Dune"
    assert meta.authors == ["Frank Herbert"]
    assert meta.isbn == "9780441013593"
    assert meta.publisher == "Chilton"
    assert meta.language == "eng"
    assert meta.description == "Spice must flow."
    assert meta.tags == ["Science fiction"]
    assert meta.cover_url.endswith("/dune")
    assert meta.source_id == "internet-archive:dune"
    assert "title:(Dune)" in get.call_args.kwargs["params"]["q"]


def test_internet_archive_free_text_query():
    with patch(
        "vellum.metadata.sources.internet_archive.requests.get",
        return_value=_response({"response": {"docs": []}}),
    ) as get:
        InternetArchive().search_free_text("dune herbert")
    assert get.call_args.kwargs["params"]["q"] == (
        "(dune herbert) AND mediatype:texts"
    )


def test_library_of_congress_mapping():
    with patch(
        "vellum.metadata.sources.library_of_congress.requests.get",
        return_value=_response(LOC_PAYLOAD),
    ):
        results = LibraryOfCongress().search(title="Dune")
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Dune"
    assert meta.authors == ["Herbert, Frank"]
    assert meta.publisher == "New York : Chilton, 1965."
    assert meta.language == "eng"
    assert meta.description == "A novel."
    assert meta.tags == ["Science fiction"]
    assert meta.cover_url == "https://example.com/cover.jpg"
    assert meta.source_id.startswith("loc:")


def test_crossref_mapping():
    with patch(
        "vellum.metadata.sources.crossref.requests.get",
        return_value=_response(CROSSREF_PAYLOAD),
    ) as get:
        results = Crossref().search(title="Dune")
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Dune"
    assert meta.authors == ["Frank Herbert"]
    assert meta.isbn == "9780441013593"
    assert meta.publisher == "Chilton"
    assert meta.pubdate == "1965"
    assert meta.description == "Spice must flow."
    assert meta.source_id == "10.1234/dune"
    assert get.call_args.kwargs["params"]["query.bibliographic"] == "Dune"


def test_extra_sources_swallow_network_errors():
    with patch(
        "vellum.metadata.sources.internet_archive.requests.get",
        side_effect=RuntimeError("down"),
    ):
        assert InternetArchive().search(title="x") == []
    with patch(
        "vellum.metadata.sources.library_of_congress.requests.get",
        side_effect=RuntimeError("down"),
    ):
        assert LibraryOfCongress().search(title="x") == []
    with patch(
        "vellum.metadata.sources.crossref.requests.get",
        side_effect=RuntimeError("down"),
    ):
        assert Crossref().search(title="x") == []
