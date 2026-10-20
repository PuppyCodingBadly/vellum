"""Minimal EPUB (zip) parser — pure stdlib, GTK-free."""

from __future__ import annotations

import os
import zipfile
import xml.etree.ElementTree as ET

_CONTAINER = "META-INF/container.xml"
_MARKER = ".extracted"

_NS = {
    "container": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
    "xhtml": "http://www.w3.org/1999/xhtml",
}


def _localname(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


class EpubBook:
    """Parse an EPUB file: spine order, chapter titles, extraction."""

    def __init__(self, path: str):
        self._path = path
        try:
            self._zip = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, OSError) as exc:
            raise ValueError(f"Not a valid epub file: {path}") from exc

        try:
            container_data = self._zip.read(_CONTAINER)
        except KeyError as exc:
            raise ValueError(f"Not an epub (missing {_CONTAINER}): {path}") from exc

        try:
            container = ET.fromstring(container_data)
        except ET.ParseError as exc:
            raise ValueError(f"Corrupt container.xml in: {path}") from exc

        self._opf_path = None
        for elem in container.iter():
            if _localname(elem.tag) == "rootfile":
                self._opf_path = elem.get("full-path")
                break
        if not self._opf_path:
            raise ValueError(f"No OPF rootfile in container: {path}")

        self._opf_dir = os.path.dirname(self._opf_path)

        try:
            opf = ET.fromstring(self._zip.read(self._opf_path))
        except (KeyError, ET.ParseError) as exc:
            raise ValueError(f"Corrupt OPF in: {path}") from exc

        # manifest: id -> (href, media-type)
        manifest: dict[str, tuple[str, str]] = {}
        # spine: ordered idrefs
        idrefs: list[str] = []
        ncx_href: str | None = None
        nav_href: str | None = None

        for elem in opf.iter():
            name = _localname(elem.tag)
            if name == "item":
                item_id = elem.get("id")
                href = elem.get("href")
                if item_id and href:
                    manifest[item_id] = (href, elem.get("media-type", ""))
                    if "nav" in (elem.get("properties") or "").split():
                        nav_href = href
            elif name == "itemref":
                idref = elem.get("idref")
                if idref:
                    idrefs.append(idref)
            elif name == "spine":
                toc_id = elem.get("toc")
                if toc_id and toc_id in manifest:
                    ncx_href = manifest[toc_id][0]

        # NCX fallback: find by media-type if spine toc attr missing
        if ncx_href is None:
            for href, mtype in manifest.values():
                if mtype == "application/x-dtbncx+xml":
                    ncx_href = href
                    break

        # Build spine list of XHTML hrefs (relative to OPF dir)
        self._spine: list[str] = []
        for idref in idrefs:
            entry = manifest.get(idref)
            if not entry:
                continue
            href, mtype = entry
            if mtype in ("application/xhtml+xml", "text/html") or \
                    href.lower().endswith((".xhtml", ".html", ".htm")):
                self._spine.append(href)

        titles = self._load_titles(ncx_href, nav_href, manifest)

        self._chapters: list[tuple[str, str]] = []
        for href in self._spine:
            title = titles.get(href) or self._stem(href)
            self._chapters.append((href, title))

    # -- public API ----------------------------------------------------------

    def chapters(self) -> list[tuple[str, str]]:
        """(href relative to OPF dir, title) for each spine chapter."""
        return list(self._chapters)

    def extract_to(self, dest_dir: str) -> str:
        """Extract the whole epub into dest_dir; return abs OPF directory.

        Idempotent: skips extraction when a marker file already exists.
        """
        os.makedirs(dest_dir, exist_ok=True)
        marker = os.path.join(dest_dir, _MARKER)
        if not os.path.exists(marker):
            self._zip.extractall(dest_dir)
            with open(marker, "w") as fh:
                fh.write("ok")
        return os.path.abspath(os.path.join(dest_dir, self._opf_dir))

    def chapter_file(self, dest_dir: str, index: int) -> str:
        """Absolute filesystem path to chapter `index` after extraction."""
        href, _title = self._chapters[index]
        opf_dir = self.extract_to(dest_dir)
        return os.path.join(opf_dir, *href.split("/"))

    # -- internals -----------------------------------------------------------

    def _load_titles(self, ncx_href, nav_href, manifest) -> dict[str, str]:
        titles: dict[str, str] = {}
        if ncx_href:
            titles.update(self._titles_from_ncx(ncx_href))
        if nav_href and not titles:
            titles.update(self._titles_from_nav(nav_href))
        return titles

    def _titles_from_ncx(self, ncx_href: str) -> dict[str, str]:
        try:
            root = ET.fromstring(self._zip.read(self._opf_join(ncx_href)))
        except (KeyError, ET.ParseError):
            return {}
        titles = {}
        for point in root.iter():
            if _localname(point.tag) not in ("navPoint", "navTarget"):
                continue
            label = None
            src = None
            for child in point.iter():
                name = _localname(child.tag)
                if name == "text" and label is None:
                    label = (child.text or "").strip()
                elif name == "content" and src is None:
                    src = child.get("src")
            if label and src:
                titles[self._normalize_href(src)] = label
        return titles

    def _titles_from_nav(self, nav_href: str) -> dict[str, str]:
        try:
            root = ET.fromstring(self._zip.read(self._opf_join(nav_href)))
        except (KeyError, ET.ParseError):
            return {}
        titles = {}
        for elem in root.iter():
            if _localname(elem.tag) == "a":
                href = elem.get("href")
                text = "".join(elem.itertext()).strip()
                if href and text:
                    titles[self._normalize_href(href)] = text
        return titles

    def _opf_join(self, href: str) -> str:
        return f"{self._opf_dir}/{href}" if self._opf_dir else href

    @staticmethod
    def _normalize_href(href: str) -> str:
        return href.split("#", 1)[0]

    @staticmethod
    def _stem(href: str) -> str:
        base = os.path.basename(href)
        stem = os.path.splitext(base)[0]
        return stem.replace("_", " ").replace("-", " ").strip() or href
