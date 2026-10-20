"""Fake ``calibre`` module tree.

Calibre metadata-source plugins import from a well-known set of calibre
modules.  Installing this shim into ``sys.modules`` lets those plugins load
inside Vellum without a real calibre installation.
"""

from __future__ import annotations

import logging
import sys
import types
import urllib.request

log = logging.getLogger(__name__)


def check_isbn(isbn):
    """Validate an ISBN-10/ISBN-13 checksum.

    Returns the normalized ISBN (digits, and 'X' for ISBN-10) when valid,
    otherwise ``None``.
    """
    if not isbn:
        return None
    raw = [c for c in str(isbn) if c not in " -"]
    if len(raw) == 10:
        total = 0
        for i, c in enumerate(raw[:-1]):
            if not c.isdigit():
                return None
            total += (10 - i) * int(c)
        last = raw[-1].upper()
        if last == "X":
            total += 10
        elif last.isdigit():
            total += int(last)
        else:
            return None
        if total % 11 == 0:
            return "".join(raw).upper()
        return None
    if len(raw) == 13:
        if not all(c.isdigit() for c in raw):
            return None
        total = sum((1 if i % 2 == 0 else 3) * int(c) for i, c in enumerate(raw))
        if total % 10 == 0:
            return "".join(raw)
        return None
    return None


class _Metadata:
    """Stand-in for ``calibre.ebooks.metadata.book.base.Metadata``."""

    def __init__(self, title="", authors=None, **kwargs):
        self.title = title
        self.authors = list(authors) if authors else []
        self.identifiers = {}
        self.tags = []
        self.rating = None
        self.publisher = None
        self.pubdate = None
        self.comments = None
        self.languages = []
        self.isbn = None
        for key, value in kwargs.items():
            setattr(self, key, value)

    def set_identifier(self, key, value):
        self.identifiers[key] = value

    def is_null(self, field):
        return getattr(self, field, None) in (None, "", [], {})


class Plugin:
    """Stand-in for ``calibre.customize.Plugin``."""

    name = "Plugin"
    author = "Unknown"
    version = (0, 0, 0)
    minimum_calibre_version = (0, 0, 0)
    description = ""

    @classmethod
    def load_actual_plugin(cls, pkg):
        """Instantiate the plugin class found in the package module.

        Classes imported into the package namespace (e.g. the shim base
        classes) are skipped; classes defined by the plugin's own modules
        are preferred.
        """
        own, imported = [], []
        for value in vars(pkg).values():
            if (
                isinstance(value, type)
                and issubclass(value, Plugin)
                and value is not Plugin
                and value.__module__ != __name__  # not a shim base class
            ):
                if value.__module__.startswith(pkg.__name__):
                    own.append(value)
                else:
                    imported.append(value)
        for value in own + imported:
            return value()
        raise ValueError(f"no Plugin subclass found in {pkg!r}")


def _build_source_class():
    class Source(Plugin):
        """Stand-in for ``calibre.ebooks.metadata.sources.base.Source``."""

        id = ""
        name = ""
        version = (0, 0, 0)
        author = ""
        description = ""
        capabilities = frozenset()
        touched_fields = frozenset()

        def __init__(self, *args, **kwargs):
            pass

        def identify(self, log, result_queue, abort, title=None, authors=None,
                     identifiers=None, timeout=30):
            return None

        def download_cover(self, log, result_queue, abort, title=None,
                           authors=None, identifiers=None, timeout=30,
                           get_best_cover=False):
            return None

    return Source


def _calibre_prints(*args, **kwargs):
    print(*args, **kwargs)


def _calibre_browser(*args, **kwargs):
    opener = urllib.request.build_opener()
    opener.addheaders = [("User-Agent", "Vellum/1.0")]
    return opener


def _canonicalize_lang(x):
    return x


def _clean_title(x):
    return x


def _module(name, **attrs):
    mod = types.ModuleType(name)
    mod.__package__ = name.rpartition(".")[0]
    for key, value in attrs.items():
        setattr(mod, key, value)
    return mod


def install():
    """Install the fake calibre module tree into ``sys.modules``.

    Idempotent: repeated calls reuse already-installed shim modules.
    """
    if "calibre" in sys.modules and getattr(sys.modules["calibre"], "__vellum_shim__", False):
        return

    def put(mod):
        mod.__vellum_shim__ = True
        sys.modules[mod.__name__] = mod
        return mod

    Source = _build_source_class()

    calibre = put(_module("calibre", prints=_calibre_prints, browser=_calibre_browser,
                          ispy3=True, iswindows=False, islinux=True, isosx=False))
    calibre.__path__ = []

    customize = put(_module("calibre.customize", Plugin=Plugin, StoreBase=StoreBase))
    customize.__path__ = []
    builtins = put(_module("calibre.customize.builtins"))
    builtins.__path__ = []

    ebooks = put(_module("calibre.ebooks"))
    ebooks.__path__ = []

    book_base = put(_module("calibre.ebooks.metadata.book.base", Metadata=_Metadata))
    book = put(_module("calibre.ebooks.metadata.book", base=book_base, Metadata=_Metadata))
    book.__path__ = []

    sources_base = put(_module("calibre.ebooks.metadata.sources.base", Source=Source))
    sources = put(_module("calibre.ebooks.metadata.sources", base=sources_base, Source=Source))
    sources.__path__ = []

    metadata = put(_module("calibre.ebooks.metadata", check_isbn=check_isbn,
                           book=book, sources=sources, MetaInformation=_Metadata,
                           MetaData=_Metadata, Metadata=_Metadata))
    metadata.__path__ = []

    utils = put(_module("calibre.utils"))
    utils.__path__ = []
    put(_module("calibre.utils.localization", canonicalize_lang=_canonicalize_lang))
    put(_module("calibre.utils.cleantitle", clean_title=_clean_title))
    put(_module("calibre.utils.config", JSONConfig=dict))

    _install_store_shims(put, calibre)


class _Dummy:
    """Permissive stand-in for Qt / calibre GUI classes.

    Accepts any constructor arguments, returns dummy callables for any
    attribute access, and can be subclassed by plugin code.
    """

    def __init__(self, *args, **kwargs):
        pass

    def __getattr__(self, name):
        return _dummy_callable

    def __call__(self, *args, **kwargs):
        return _Dummy()

    def __iter__(self):
        return iter(())

    def __bool__(self):
        return False


def _dummy_callable(*args, **kwargs):
    return _Dummy()


def _dummy_module_getattr(name):
    return _Dummy


class SearchResult:
    """Stand-in for ``calibre.gui2.store.search_result.SearchResult``."""

    DRM_UNLOCKED = 0
    DRM_UNKNOWN = 1
    DRM_LOCKED = 2

    def __init__(self):
        self.title = ""
        self.author = ""
        self.price = ""
        self.detail_item = ""
        self.cover_url = ""
        self.formats = ""
        self.drm = self.DRM_UNKNOWN
        self.downloads = {}

    def __getattr__(self, name):
        # Permissive: unknown attributes read as empty string rather than
        # raising, mirroring calibre's loosely-initialized result objects.
        return ""


class StorePlugin(Plugin):
    """Stand-in for ``calibre.gui2.store.StorePlugin``."""

    def __init__(self, *args, **kwargs):
        pass

    def __getattr__(self, name):
        return _dummy_callable


class StoreBase(Plugin):
    """Stand-in for ``calibre.customize.stores``-style store base class."""

    def __init__(self, *args, **kwargs):
        pass


class BasicStoreConfig:
    """Permissive stand-in for calibre's BasicStoreConfig."""

    def __init__(self, *args, **kwargs):
        self.options = {}

    def get(self, key, default=None):
        return default

    def __getattr__(self, name):
        return _dummy_callable


class _WebStoreDialog(_Dummy):
    pass


def _open_url(url):
    import webbrowser
    webbrowser.open(str(url))


def _url_slash_cleaner(url):
    while url.endswith("/"):
        url = url[:-1]
    return url


def _install_store_shims(put, calibre):
    """Install PyQt5 / calibre.gui2 stubs needed by calibre store plugins."""

    pyqt5 = put(_module("PyQt5"))
    pyqt5.__path__ = []
    pyqt5.__getattr__ = _dummy_module_getattr
    qt = put(_module("PyQt5.Qt"))
    qt.__getattr__ = _dummy_module_getattr
    pyqt5.Qt = qt

    calibre.url_slash_cleaner = _url_slash_cleaner

    gui2 = put(_module("calibre.gui2", open_url=_open_url))
    gui2.__path__ = []
    gui2.__getattr__ = _dummy_module_getattr

    store = put(_module("calibre.gui2.store", StorePlugin=StorePlugin))
    store.__path__ = []
    gui2.store = store

    put(_module("calibre.gui2.store.basic_config",
                BasicStoreConfig=BasicStoreConfig,
                BasicStoreConfigWidget=_Dummy))
    put(_module("calibre.gui2.store.search_result", SearchResult=SearchResult))
    put(_module("calibre.gui2.store.web_store_dialog",
                WebStoreDialog=_WebStoreDialog))
