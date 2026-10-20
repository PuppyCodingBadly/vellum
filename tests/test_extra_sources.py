"""Tests for the additional built-in metadata sources."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

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
        " AND language:(eng OR English)"
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


INVENTAIRE_SEARCH = {
    "results": [
        {
            "id": "Q190192",
            "uri": "wd:Q190192",
            "image": "/img/entities/hash",
        }
    ]
}

INVENTAIRE_ENTITIES = {
    "entities": {
        "wd:Q190192": {
            "uri": "wd:Q190192",
            "wdId": "Q190192",
            "labels": {"en": "Dune"},
            "descriptions": {"en": "1965 science fiction novel"},
            "claims": {
                "wdt:P50": ["wd:Q7934"],
                "wdt:P136": ["wd:Q1"],
                "wdt:P577": ["1965"],
                "wdt:P407": ["wd:Q1860"],
            },
        },
        "wd:Q7934": {"labels": {"en": "Frank Herbert"}},
        "wd:Q1": {"labels": {"en": "Science fiction"}},
        "wd:Q1860": {"labels": {"en": "English"}},
    }
}


def test_inventaire_mapping():
    from vellum.metadata.sources.inventaire import Inventaire

    calls = []

    def fake_get(url, **kwargs):
        calls.append(kwargs.get("params") or {})
        if "entities" in url:
            return _response(INVENTAIRE_ENTITIES)
        return _response(INVENTAIRE_SEARCH)

    with patch(
        "vellum.metadata.sources.inventaire.requests.get",
        side_effect=fake_get,
    ):
        results = Inventaire().search(title="Dune")
    assert len(results) == 1
    meta = results[0]
    assert meta.title == "Dune"
    assert meta.authors == ["Frank Herbert"]
    assert meta.publisher == ""
    assert meta.pubdate == "1965"
    assert meta.language == "English"
    assert meta.description == "1965 science fiction novel"
    assert meta.tags == ["Science fiction"]
    assert meta.cover_url == "https://inventaire.io/img/entities/hash"
    assert meta.source_id == "inventaire:Q190192"
    assert calls[0]["types"] == "works"


def test_inventaire_skips_non_english_works():
    from vellum.metadata.sources.inventaire import Inventaire

    search = {"results": [{"uri": "wd:Q2", "image": ""}]}
    entities = {
        "entities": {
            "wd:Q2": {
                "wdId": "Q2",
                "labels": {"fr": "Livre"},
                "descriptions": {"fr": "Un livre"},
                "claims": {},
            }
        }
    }

    def fake_get(url, **kwargs):
        if "entities" in url:
            return _response(entities)
        return _response(search)

    with patch(
        "vellum.metadata.sources.inventaire.requests.get",
        side_effect=fake_get,
    ):
        assert Inventaire().search(title="Livre") == []
