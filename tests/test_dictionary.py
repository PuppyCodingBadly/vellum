"""Tests for vellum.core.dictionary.lookup."""

from unittest.mock import Mock, patch

import pytest
import requests

from vellum.core.dictionary import lookup

_API_PAYLOAD = [
    {
        "word": "test",
        "phonetic": "",
        "phonetics": [
            {"text": ""},
            {"text": "/tɛst/"},
            {"text": "/test/"},
        ],
        "meanings": [
            {
                "partOfSpeech": "noun",
                "definitions": [
                    {"definition": "A procedure for evaluation."},
                    {"definition": "An examination."},
                    {"definition": "A trial."},
                    {"definition": "A cupel."},
                ],
            },
            {
                "partOfSpeech": "verb",
                "definitions": [
                    {"definition": "To challenge."},
                    {"definition": "To refine."},
                ],
            },
            {
                "partOfSpeech": "adjective",
                "definitions": [
                    {"definition": "Relating to evaluation."},
                ],
            },
            {
                "partOfSpeech": "obsolete",
                "definitions": [
                    {"definition": "A witness."},
                ],
            },
        ],
    }
]


def _mock_response(payload=_API_PAYLOAD, status_code=200):
    response = Mock(spec=requests.Response)
    response.status_code = status_code
    response.json.return_value = payload
    response.raise_for_status.return_value = None
    return response


def test_lookup_normalizes_entry():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value = _mock_response()
        result = lookup("  TEST ")

    assert get.call_args.kwargs["timeout"] == 8
    assert result["word"] == "test"
    # First non-empty phonetic text is chosen.
    assert result["phonetic"] == "/tɛst/"
    # Meanings capped at 3, definitions capped at 3.
    assert [m["partOfSpeech"] for m in result["meanings"]] == [
        "noun",
        "verb",
        "adjective",
    ]
    assert result["meanings"][0]["definitions"] == [
        "A procedure for evaluation.",
        "An examination.",
        "A trial.",
    ]
    assert result["meanings"][1]["definitions"] == [
        "To challenge.",
        "To refine.",
    ]


def test_lookup_uses_top_level_phonetic():
    payload = [
        {
            "word": "test",
            "phonetic": "/tɛst/",
            "phonetics": [{"text": "/other/"}],
            "meanings": [],
        }
    ]
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value = _mock_response(payload)
        result = lookup("test")
    assert result["phonetic"] == "/tɛst/"
    assert result["meanings"] == []


def test_lookup_url_and_language():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value = _mock_response()
        lookup("Hola", language="es")
    url = get.call_args.args[0]
    assert url == "https://api.dictionaryapi.dev/api/v2/entries/es/hola"


def test_lookup_404_returns_none():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value = _mock_response(status_code=404)
        assert lookup("asdfqwer") is None
    get.return_value.raise_for_status.assert_not_called()


def test_lookup_http_error_returns_none():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value.raise_for_status.side_effect = requests.HTTPError("500")
        assert lookup("test") is None


def test_lookup_network_error_returns_none():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.side_effect = requests.ConnectionError("offline")
        assert lookup("test") is None
        get.side_effect = requests.Timeout("slow")
        assert lookup("test") is None


def test_lookup_bad_payload_returns_none():
    with patch("vellum.core.dictionary.requests.get") as get:
        get.return_value = _mock_response([])
        assert lookup("test") is None
        get.return_value = _mock_response({"not": "a list"})
        assert lookup("test") is None


def test_lookup_empty_word_returns_none_without_request():
    with patch("vellum.core.dictionary.requests.get") as get:
        assert lookup("   ") is None
    get.assert_not_called()


@pytest.mark.parametrize("word", ["test"])
def test_lookup_never_raises(word):
    with patch(
        "vellum.core.dictionary.requests.get",
        side_effect=requests.RequestException("boom"),
    ):
        assert lookup(word) is None


_WIKTIONARY_PAYLOAD = {
    "en": [
        {
            "partOfSpeech": "noun",
            "language": "English",
            "definitions": [
                {
                    "definition": '<span class="ib-brac">(</span>obsolete'
                    '<span class="ib-brac">)</span> A witness.',
                    "examples": [],
                },
                {
                    "definition": "A procedure for <b>evaluation</b>.",
                },
                {
                    "definition": "An academic &lt;examination&gt;.",
                },
                {
                    "definition": "A fourth definition (capped).",
                },
            ],
        },
        {
            "partOfSpeech": "verb",
            "definitions": [
                {"definition": "To <i>challenge</i>."},
            ],
        },
        {
            "partOfSpeech": "adjective",
            "definitions": [
                {"definition": "Relating to evaluation."},
            ],
        },
        {
            "partOfSpeech": "extra",
            "definitions": [
                {"definition": "Beyond the cap."},
            ],
        },
    ]
}


def _wiktionary_response(payload=_WIKTIONARY_PAYLOAD, status_code=200):
    response = Mock(spec=requests.Response)
    response.status_code = status_code
    response.json.return_value = payload
    response.raise_for_status.return_value = None
    return response


def _error_response(status_code=530):
    response = Mock(spec=requests.Response)
    response.status_code = status_code
    response.raise_for_status.side_effect = requests.HTTPError(
        f"{status_code} Server Error"
    )
    return response


def _dispatch_primary_fail_wiktionary_ok(url, **kwargs):
    if "dictionaryapi.dev" in url:
        return _error_response()
    return _wiktionary_response()


def test_lookup_falls_back_to_wiktionary_on_5xx():
    with patch(
        "vellum.core.dictionary.requests.get",
        side_effect=_dispatch_primary_fail_wiktionary_ok,
    ) as get:
        result = lookup("test")

    assert get.call_count == 2
    wiktionary_call = get.call_args_list[1]
    assert wiktionary_call.args[0].startswith(
        "https://en.wiktionary.org/api/rest_v1/page/definition/test"
    )
    assert wiktionary_call.kwargs["timeout"] == 8
    assert "Vellum" in wiktionary_call.kwargs["headers"]["User-Agent"]

    assert result["word"] == "test"
    assert result["phonetic"] == ""
    # Meanings capped at 3, definitions capped at 3.
    assert [m["partOfSpeech"] for m in result["meanings"]] == [
        "noun",
        "verb",
        "adjective",
    ]
    # HTML tags stripped and entities unescaped.
    assert result["meanings"][0]["definitions"] == [
        "(obsolete) A witness.",
        "A procedure for evaluation.",
        "An academic <examination>.",
    ]


def test_lookup_falls_back_on_network_error():
    def dispatch(url, **kwargs):
        if "dictionaryapi.dev" in url:
            raise requests.ConnectionError("offline")
        return _wiktionary_response()

    with patch("vellum.core.dictionary.requests.get", side_effect=dispatch):
        result = lookup("test")
    assert result is not None
    assert result["meanings"][0]["partOfSpeech"] == "noun"


def test_lookup_none_when_both_providers_fail():
    def dispatch(url, **kwargs):
        if "dictionaryapi.dev" in url:
            return _error_response()
        raise requests.ConnectionError("offline")

    with patch("vellum.core.dictionary.requests.get", side_effect=dispatch):
        assert lookup("test") is None


def test_lookup_wiktionary_404_after_primary_404_returns_none():
    with patch(
        "vellum.core.dictionary.requests.get",
        return_value=_mock_response(status_code=404),
    ) as get:
        assert lookup("asdfqwer") is None
    assert get.call_count == 2
