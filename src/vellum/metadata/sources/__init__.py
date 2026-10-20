"""Built-in metadata sources."""

from vellum.metadata.sources.base import Metadata, MetadataSource
from vellum.metadata.sources.google_books import GoogleBooks
from vellum.metadata.sources.openlibrary import OpenLibrary

__all__ = ["Metadata", "MetadataSource", "GoogleBooks", "OpenLibrary"]
