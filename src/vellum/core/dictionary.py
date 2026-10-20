"""Dictionary lookups via the Free Dictionary API, with Wiktionary fallback."""

from __future__ import annotations

import html
import logging
import re
import urllib.parse

import requests

log = logging.getLogger(__name__)

API_URL = "https://api.dictionaryapi.dev/api/v2/entries/{language}/{word}"
WIKTIONARY_URL = "https://{language}.wiktionary.org/api/rest_v1/page/definition/{word}"
USER_AGENT = "Vellum/0.1 (ebook reader; contact: none)"

MAX_MEANINGS = 3
MAX_DEFINITIONS = 3

_TAG_RE = re.compile(r"<[^>]+>")


def lookup(word: str, language: str = "en") -> dict | None:
    """Look up a word's definition.

    Returns a normalized dict::

        {
            "word": str,
            "phonetic": str,
            "meanings": [
                {"partOfSpeech": str, "definitions": [str, ...]},
                ...
            ],
        }

    Meanings are capped at 3 and definitions at 3 per meaning.
    Tries dictionaryapi.dev first, then Wiktionary's REST API; returns
    None only when both providers fail.
    """
    word = word.strip().lower()
    if not word:
        return None

    result = _lookup_dictionaryapi(word, language)
    if result is not None:
        return result
    return _lookup_wiktionary(word, language)


def _lookup_dictionaryapi(word: str, language: str) -> dict | None:
    url = API_URL.format(language=language, word=urllib.parse.quote(word, safe=""))
    try:
        response = requests.get(url, timeout=8)
        if response.status_code == 404:
            log.info("dictionary: no entry for %r (%s)", word, language)
            return None
        response.raise_for_status()
        data = response.json()
        return _normalize_entry(data[0])
    except requests.RequestException as exc:
        log.warning("dictionary lookup failed for %r: %s", word, exc)
    except (IndexError, KeyError, TypeError, ValueError, AttributeError) as exc:
        log.warning("dictionary: could not parse entry for %r: %s", word, exc)
    return None


def _normalize_entry(entry: dict) -> dict:
    phonetic = entry.get("phonetic") or ""
    if not phonetic:
        for item in entry.get("phonetics") or []:
            text = (item.get("text") or "").strip()
            if text:
                phonetic = text
                break

    meanings = []
    for meaning in (entry.get("meanings") or [])[:MAX_MEANINGS]:
        definitions = []
        for definition in (meaning.get("definitions") or [])[:MAX_DEFINITIONS]:
            text = (definition.get("definition") or "").strip()
            if text:
                definitions.append(text)
        meanings.append(
            {
                "partOfSpeech": meaning.get("partOfSpeech") or "",
                "definitions": definitions,
            }
        )

    return {
        "word": entry.get("word") or "",
        "phonetic": phonetic,
        "meanings": meanings,
    }


def _lookup_wiktionary(word: str, language: str) -> dict | None:
    url = WIKTIONARY_URL.format(
        language=language, word=urllib.parse.quote(word, safe="")
    )
    try:
        response = requests.get(
            url, timeout=8, headers={"User-Agent": USER_AGENT}
        )
        if response.status_code == 404:
            log.info("wiktionary: no entry for %r (%s)", word, language)
            return None
        response.raise_for_status()
        data = response.json()
        return _normalize_wiktionary(word, data)
    except requests.RequestException as exc:
        log.warning("wiktionary lookup failed for %r: %s", word, exc)
    except (IndexError, KeyError, TypeError, ValueError, AttributeError) as exc:
        log.warning("wiktionary: could not parse entry for %r: %s", word, exc)
    return None


def _normalize_wiktionary(word: str, data: dict) -> dict:
    meanings = []
    for entries in data.values():
        for entry in (entries or [])[: MAX_MEANINGS - len(meanings)]:
            definitions = []
            for definition in (entry.get("definitions") or [])[:MAX_DEFINITIONS]:
                text = _strip_html(definition.get("definition") or "")
                if text:
                    definitions.append(text)
            if definitions:
                meanings.append(
                    {
                        "partOfSpeech": entry.get("partOfSpeech") or "",
                        "definitions": definitions,
                    }
                )
        if len(meanings) >= MAX_MEANINGS:
            break

    if not meanings:
        raise ValueError("wiktionary entry has no definitions")

    return {"word": word, "phonetic": "", "meanings": meanings[:MAX_MEANINGS]}


def _strip_html(text: str) -> str:
    return html.unescape(_TAG_RE.sub("", text)).strip()
