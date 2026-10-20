"""Stdlib-only PalmDOC/MOBI extractor."""

from __future__ import annotations

import os
import re
import struct
import tempfile

_PDB_HEADER_LEN = 78
_MOBI_HEADER_OFF = 16  # MOBI header starts after the 16-byte PalmDOC header
_FIRST_NON_BOOK_OFF = 0x50
_FIRST_IMAGE_OFF = 0x6C
_MIN_MOBI_HEADER = 0x70

_PAGEBREAK_RE = re.compile(r"(?i)<mbp:pagebreak\s*/?>")
_HEADING_SPLIT_RE = re.compile(r"(?i)(?=<h[12][^>]*>)")
_HEADING_RE = re.compile(r"(?is)<h[12][^>]*>(.*?)</h[12]>")
_TAG_RE = re.compile(r"<[^>]+>")
_RECINDEX_RE = re.compile(r'(?i)(<img\b[^>]*?)\brecindex="(\d+)"([^>]*)/?>')

_IMAGE_MAGIC = (
    (b"\xff\xd8\xff", ".jpg"),
    (b"GIF87a", ".gif"),
    (b"GIF89a", ".gif"),
    (b"\x89PNG\r\n\x1a\n", ".png"),
)


def _palmdoc_decompress(data: bytes) -> bytes:
    """Standard PalmDOC LZ77 decompression."""
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        c = data[i]
        i += 1
        if c == 0:
            out.append(0)
        elif c <= 8:
            out += data[i:i + c]
            i += c
        elif c <= 0x7F:
            out.append(c)
        elif c <= 0xBF:
            if i >= n:
                break
            pair = (c << 8) | data[i]
            i += 1
            distance = pair >> 3
            length = (pair & 0x07) + 3
            if distance > len(out):
                break
            for _ in range(length):
                out.append(out[-distance])
        else:
            out.append(0x20)
            out.append(c ^ 0x80)
    return bytes(out)


def _image_ext(data: bytes) -> str | None:
    for magic, ext in _IMAGE_MAGIC:
        if data.startswith(magic):
            return ext
    return None


class MobiBook:
    """Parse a MOBI/PalmDOC file into HTML sections plus image records."""

    def __init__(self, path: str):
        self._path = path
        self._image_files: dict[int, str] = {}
        self._image_dir = ""
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            raise ValueError(f"cannot read MOBI file: {path}") from exc
        self._parse(data)

    # -- parsing ---------------------------------------------------------------

    def _parse(self, data: bytes) -> None:
        if len(data) < _PDB_HEADER_LEN + 8 or data[60:68] != b"BOOKMOBI":
            raise ValueError("not a MOBI file")
        num_records = struct.unpack(">H", data[76:78])[0]
        if num_records < 1 or len(data) < _PDB_HEADER_LEN + 8 * num_records:
            raise ValueError("corrupt MOBI record table")
        offsets = []
        for i in range(num_records):
            off = struct.unpack(">I", data[_PDB_HEADER_LEN + i * 8:
                                          _PDB_HEADER_LEN + i * 8 + 4])[0]
            offsets.append(off)
        records = []
        for i, off in enumerate(offsets):
            end = offsets[i + 1] if i + 1 < len(offsets) else len(data)
            if off > len(data) or end > len(data) or end < off:
                raise ValueError("corrupt MOBI record offsets")
            records.append(data[off:end])

        rec0 = records[0]
        if len(rec0) < _MOBI_HEADER_OFF + _MIN_MOBI_HEADER:
            raise ValueError("corrupt MOBI record 0")
        compression = struct.unpack(">H", rec0[0:2])[0]
        if compression not in (1, 2):
            raise ValueError(f"unsupported PalmDOC compression: {compression}")
        text_length = struct.unpack(">I", rec0[4:8])[0]
        text_record_count = struct.unpack(">H", rec0[8:10])[0]
        mobi = rec0[_MOBI_HEADER_OFF:]
        if mobi[0:4] != b"MOBI":
            raise ValueError("missing MOBI header")
        self._first_non_book = struct.unpack(
            ">I", mobi[_FIRST_NON_BOOK_OFF:_FIRST_NON_BOOK_OFF + 4])[0]
        self._first_image = struct.unpack(
            ">I", mobi[_FIRST_IMAGE_OFF:_FIRST_IMAGE_OFF + 4])[0]

        self._records = records
        self._first_image = min(self._first_image, num_records)

        chunks = []
        for record in records[1:1 + text_record_count]:
            if compression == 2:
                chunks.append(_palmdoc_decompress(record))
            else:
                chunks.append(record)
        text = b"".join(chunks)[:text_length]
        self._html = text.decode("utf-8", errors="replace")
        self._sections = self._split_sections()

    def _split_sections(self) -> list[tuple[int, str]]:
        html = self._html
        bounds = [0]
        breaks = list(_PAGEBREAK_RE.finditer(html))
        if breaks:
            bounds += [m.end() for m in breaks]
        else:
            bounds += [m.start() for m in _HEADING_SPLIT_RE.finditer(html)
                       if m.start() > 0]
        bounds = sorted(set(bounds))
        sections = []
        for pos, start in enumerate(bounds):
            end = bounds[pos + 1] if pos + 1 < len(bounds) else len(html)
            chunk = html[start:end]
            if not _TAG_RE.sub("", chunk).strip():
                continue
            heading = _HEADING_RE.search(chunk)
            if heading:
                title = _TAG_RE.sub("", heading.group(1)).strip()
            else:
                title = ""
            if not title:
                title = f"Section {len(sections) + 1}"
            sections.append((start, title, chunk))
        self._chunks = [chunk for _, _, chunk in sections]
        return [(start, title) for start, title, _ in sections]

    # -- public API --------------------------------------------------------------

    def sections(self) -> list[tuple[int, str]]:
        """Return (record_offset, title) for each section."""
        return list(self._sections)

    def section_html(self, index: int) -> str:
        """Full XHTML document for section *index* with image refs rewritten."""
        if not 0 <= index < len(self._chunks):
            raise IndexError(f"section index out of range: {index}")
        if not self._image_dir:
            self.extract_to(tempfile.mkdtemp(prefix="vellum-mobi-"))
        body = _RECINDEX_RE.sub(self._rewrite_img, self._chunks[index])
        return (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            '<head><meta charset="utf-8"/></head>'
            f"<body>{body}</body></html>"
        )

    def _rewrite_img(self, match: re.Match) -> str:
        pre, recindex, post = match.group(1), int(match.group(2)), match.group(3)
        filename = self._image_files.get(recindex)
        if filename is None:
            return f"{pre}{post}>"
        uri = "file://" + os.path.join(self._image_dir, filename)
        return f'{pre}src="{uri}"{post}>'

    def extract_to(self, dest_dir: str) -> str:
        """Extract image records into *dest_dir* (idempotent); returns the dir."""
        dest_dir = os.path.abspath(dest_dir)
        os.makedirs(dest_dir, exist_ok=True)
        marker = os.path.join(dest_dir, ".extracted")
        self._image_dir = dest_dir
        if os.path.exists(marker):
            self._image_files = {
                int(name.split("-", 1)[1].rsplit(".", 1)[0]): name
                for name in os.listdir(dest_dir)
                if name.startswith("img-") and "." in name
            }
            return dest_dir
        self._image_files = {}
        for recindex in range(self._first_image, len(self._records)):
            ext = _image_ext(self._records[recindex])
            if ext is None:
                continue
            name = f"img-{recindex}{ext}"
            with open(os.path.join(dest_dir, name), "wb") as fh:
                fh.write(self._records[recindex])
            self._image_files[recindex] = name
        with open(marker, "w") as fh:
            fh.write("ok\n")
        return dest_dir
