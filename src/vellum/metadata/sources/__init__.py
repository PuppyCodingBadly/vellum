"""Built-in metadata sources."""

from vellum.metadata.sources.base import Metadata, MetadataSource
from vellum.metadata.sources.crossref import Crossref
from vellum.metadata.sources.google_books import GoogleBooks
from vellum.metadata.sources.internet_archive import InternetArchive
from vellum.metadata.sources.library_of_congress import LibraryOfCongress
from vellum.metadata.sources.openlibrary import OpenLibrary

__all__ = [
    "Metadata",
    "MetadataSource",
    "Crossref",
    "GoogleBooks",
    "InternetArchive",
    "LibraryOfCongress",
    "OpenLibrary",
]
