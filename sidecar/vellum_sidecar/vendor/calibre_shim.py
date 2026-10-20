"""Fake ``calibre`` module tree.

Calibre metadata-source plugins import from a well-known set of calibre
modules.  Installing this shim into ``sys.modules`` lets those plugins load
inside Vellum without a real calibre installation.
"""

from __future__ import annotations

import datetime
import logging
import os
import re
import sys
import threading
import types
import unicodedata
import urllib.request

log = logging.getLogger(__name__)

#: Version reported to plugins that branch on ``calibre.constants``.
CALIBRE_VERSION = (6, 0, 0)
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)


def as_unicode(value):
    """Decode bytes exactly like ``calibre.as_unicode``."""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def normalize(value):
    return unicodedata.normalize("NFC", str(value))


def clean_ascii_chars(value):
    """Strip control characters while keeping printable Unicode."""
    return "".join(c for c in str(value) if c in "\n\t\r" or ord(c) >= 32)


def _fixauthors(authors):
    if not authors:
        return authors
    fixed = []
    for author in authors:
        if "," in author:
            last, first = (part.strip() for part in author.split(",", 1))
            author = f"{first} {last}".strip()
        fixed.append(author)
    return fixed


def _fixcase(value):
    if not value:
        return value
    return value


def _lower(value):
    return str(value).casefold()


def _utcfromtimestamp(ts):
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)


utc_tz = datetime.timezone.utc


def _xml_to_unicode(raw, strip_encoding_pats=False, resolve_entities=False,
                    assume_utf8=False):
    """Decode an XML/HTML byte payload, returning ``(text, encoding)``."""
    if isinstance(raw, str):
        return raw, "utf-8"
    encoding = "utf-8"
    if not assume_utf8:
        match = re.match(rb'\s*<\?xml[^>]*encoding=["\']([^"\']+)', raw)
        if match:
            encoding = match.group(1).decode("ascii", "replace")
    try:
        return raw.decode(encoding, "replace"), encoding
    except LookupError:
        return raw.decode("utf-8", "replace"), "utf-8"


def _sanitize_comments_html(raw):
    return raw


class _UnicodeDisplayContext:
    """Approximate ``calibre.utils.localization``'s transliteration helper."""

    def decode(self, text):
        if not text:
            return text
        decomposed = unicodedata.normalize("NFKD", str(text))
        return decomposed.encode("ascii", "ignore").decode("ascii") or str(text)


_UDC = _UnicodeDisplayContext()


def _get_udc(*args, **kwargs):
    return _UDC


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
        self.series = None
        self.series_index = None
        self.title_sort = None
        self.author_sort = None
        self.timestamp = None
        for key, value in kwargs.items():
            setattr(self, key, value)

    @property
    def language(self):
        return self.languages[0] if self.languages else None

    @language.setter
    def language(self, value):
        self.languages = [value] if isinstance(value, str) else list(value or [])

    def set_identifier(self, key, value):
        self.identifiers[key] = value

    def has_identifier(self, key):
        return bool(self.identifiers.get(key))

    def get_identifiers(self):
        return dict(self.identifiers)

    def is_null(self, field):
        return getattr(self, field, None) in (None, "", [], {})


class Plugin:
    """Stand-in for ``calibre.customize.Plugin``."""

    name = "Plugin"
    author = "Unknown"
    version = (0, 0, 0)
    minimum_calibre_version = (0, 0, 0)
    description = ""
    supported_platforms = ["windows", "osx", "linux"]

    def __init__(self, plugin_path=None):
        self.plugin_path = plugin_path
        self.site_customization = None

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


class _Response:
    """Thin wrapper giving urllib responses the calibre browser API."""

    def __init__(self, response):
        self._response = response

    def read(self, *args, **kwargs):
        return self._response.read(*args, **kwargs)

    def info(self):
        return self._response.headers

    def geturl(self):
        return self._response.geturl()

    def getcode(self):
        return self._response.getcode()

    @property
    def headers(self):
        return self._response.headers

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self._response.close()


class _Browser:
    """Small urllib-backed stand-in for ``calibre.utils.browser.Browser``."""

    def __init__(self, user_agent=USER_AGENT, verify_ssl_certificates=True):
        import http.cookiejar
        self.user_agent = user_agent
        self.addheaders = [("User-Agent", user_agent)]
        self.cookiejar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookiejar))

    def clone_browser(self):
        clone = _Browser(self.user_agent)
        clone.addheaders = list(self.addheaders)
        clone.cookiejar = self.cookiejar
        clone._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookiejar))
        return clone

    def open_novisit(self, url, timeout=30, **kwargs):
        headers = dict(self.addheaders)
        headers.update(kwargs.get("headers") or {})
        request = url if isinstance(url, urllib.request.Request) else \
            urllib.request.Request(str(url), headers=headers)
        return _Response(self._opener.open(request, timeout=timeout))

    open = open_novisit

    def set_handle_gzip(self, value):
        pass

    def set_header(self, key, value):
        self.addheaders = [(k, v) for k, v in self.addheaders if k.lower() != key.lower()]
        self.addheaders.append((key, value))

    def add_cookie(self, cookie):
        self.cookiejar.set_cookie(cookie)

    def get_cookie(self, name):
        for cookie in self.cookiejar:
            if cookie.name == name:
                return cookie
        return None


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
        has_html_comments = False
        supports_gzip_transfer_encoding = False
        ignore_ssl_errors = False
        cached_cover_url_is_reliable = True
        options = ()
        config_help_message = None
        can_get_multiple_covers = False
        auto_trim_covers = False
        prefer_results_with_isbn = True

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.running_a_test = False
            self._isbn_to_identifier_cache = {}
            self._identifier_to_cover_url_cache = {}
            self.cache_lock = threading.RLock()
            self._config_obj = None
            self._browser = None

        # -- configuration --------------------------------------------------

        def is_configured(self):
            return True

        def is_customizable(self):
            return True

        def customization_help(self, gui=False):
            return "This plugin can only be customized using the GUI"

        def config_widget(self):
            from calibre.gui2.metadata.config import ConfigWidget
            return ConfigWidget(self)

        def save_settings(self, config_widget):
            commit = getattr(config_widget, "commit", None)
            if callable(commit):
                commit()

        @property
        def prefs(self):
            if self._config_obj is None:
                from calibre.utils.config import JSONConfig
                self._config_obj = JSONConfig("metadata_sources/%s.json" % self.name)
            return self._config_obj

        # -- browser --------------------------------------------------------

        @property
        def user_agent(self):
            return random_common_chrome_user_agent()

        @property
        def browser(self):
            if self._browser is None:
                self._browser = _Browser(user_agent=self.user_agent)
            return self._browser.clone_browser()

        # -- caches ---------------------------------------------------------

        def get_related_isbns(self, id_):
            with self.cache_lock:
                for isbn, q in self._isbn_to_identifier_cache.items():
                    if q == id_:
                        yield isbn

        def cache_isbn_to_identifier(self, isbn, identifier):
            with self.cache_lock:
                self._isbn_to_identifier_cache[isbn] = identifier

        def cached_isbn_to_identifier(self, isbn):
            with self.cache_lock:
                return self._isbn_to_identifier_cache.get(isbn)

        def cache_identifier_to_cover_url(self, id_, url):
            with self.cache_lock:
                self._identifier_to_cover_url_cache[id_] = url

        def cached_identifier_to_cover_url(self, id_):
            with self.cache_lock:
                return self._identifier_to_cover_url_cache.get(id_)

        def dump_caches(self):
            with self.cache_lock:
                return {
                    "isbn_to_identifier": self._isbn_to_identifier_cache.copy(),
                    "identifier_to_cover": self._identifier_to_cover_url_cache.copy(),
                }

        def load_caches(self, dump):
            with self.cache_lock:
                self._isbn_to_identifier_cache.update(dump["isbn_to_identifier"])
                self._identifier_to_cover_url_cache.update(dump["identifier_to_cover"])

        # -- query helpers --------------------------------------------------

        def get_author_tokens(self, authors, only_first_author=True):
            if not authors:
                return
            remove_pat = re.compile(r'[!@#$%^&*()（）「」{}`~"\s\[\]/]')
            replace_pat = re.compile(r"[-+.:;,，。；：]")
            if only_first_author:
                authors = authors[:1]
            for author in authors:
                has_comma = "," in author
                author = replace_pat.sub(" ", author)
                parts = author.split()
                if has_comma:
                    parts = parts[1:] + parts[:1]
                for token in parts:
                    token = remove_pat.sub("", token).strip()
                    if len(token) > 2 and token.lower() not in ("von", "van"):
                        yield token

        def get_title_tokens(self, title, strip_joiners=True, strip_subtitle=False):
            if not title:
                return
            if strip_subtitle:
                subtitle = re.compile(r"([\(\[\{].*?[\)\]\}]|[/:\\].*$)")
                if len(subtitle.sub("", title)) > 1:
                    title = subtitle.sub("", title)
            patterns = [
                (r"(?i)[({\[](\d{4}|omnibus|anthology|hardcover|audiobook|"
                 r"audio\scd|paperback|turtleback|mass\s*market|edition|ed\.)[\])}]", ""),
                (r"(?i)[({\[].*?(edition|ed.).*?[\]})]", ""),
                (r"(\d+),(\d+)", r"\1\2"),
                (r"(\s-)", " "),
                (r'''[:,;!@$%^&*(){}.`~"\s\[\]/]《》「」“”''', " "),
            ]
            for pattern, repl in patterns:
                title = re.sub(pattern, repl, title)
            for token in title.split():
                token = token.strip().strip('"').strip("'")
                if token and (not strip_joiners or token.lower() not in
                               ("a", "and", "the", "&")):
                    yield token

        def split_jobs(self, jobs, num):
            groups = [[] for _ in range(num)]
            jobs = list(jobs)
            while jobs:
                for group in groups:
                    try:
                        group.append(jobs.pop())
                    except IndexError:
                        break
            return [g for g in groups if g]

        def test_fields(self, mi):
            for key in self.touched_fields:
                if key.startswith("identifier:"):
                    key = key.partition(":")[-1]
                    if not mi.has_identifier(key):
                        return "identifier: " + key
                elif mi.is_null(key):
                    return key

        def clean_downloaded_metadata(self, mi):
            mi.title = _fixcase(mi.title)
            mi.authors = _fixauthors(mi.authors)
            mi.isbn = check_isbn(mi.isbn)

        def identify_results_keygen(self, title=None, authors=None, identifiers=None):
            def keygen(mi):
                same_title = bool(title and mi.title and
                                  str(title).lower() in str(mi.title).lower())
                return (0 if same_title else 1, str(getattr(mi, "title", "")))
            return keygen

        # -- metadata API ---------------------------------------------------

        def get_book_url(self, identifiers):
            return None

        def get_book_url_name(self, idtype, idval, url):
            return idtype

        def get_book_urls(self, identifiers):
            url = self.get_book_url(identifiers)
            return [url] if url else []

        def get_cached_cover_url(self, identifiers):
            return None

        def id_from_url(self, url):
            return None

        def identify(self, log, result_queue, abort, title=None, authors=None,
                     identifiers=None, timeout=30):
            return None

        def download_cover(self, log, result_queue, abort, title=None,
                           authors=None, identifiers=None, timeout=30,
                           get_best_cover=False):
            return None

    return Source


def random_common_chrome_user_agent():
    return USER_AGENT


def random_chrome_ua():
    return USER_AGENT


def all_chrome_versions():
    return [{"chrome_version": "120.0.0.0", "webkit_version": "537.36"}]


def random_desktop_platform():
    return "X11; Linux x86_64"


def _random_user_agent():
    return USER_AGENT


def _calibre_prints(*args, **kwargs):
    print(*args, **kwargs)


def _calibre_browser(*args, **kwargs):
    user_agent = kwargs.get("user_agent") or USER_AGENT
    return _Browser(user_agent=user_agent)


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


class PluginLog:
    """Callable logger matching calibre's ``ThreadSafeLog`` interface."""

    def __init__(self, name="vellum.plugins"):
        self._logger = logging.getLogger(name)

    @staticmethod
    def _message(args, kwargs):
        if args and isinstance(args[0], str) and "%" in args[0] and len(args) > 1:
            return args[0] % tuple(args[1:])
        return " ".join(str(a) for a in args)

    def __call__(self, *args, **kwargs):
        self._logger.info(self._message(args, kwargs))

    def debug(self, *args, **kwargs):
        self._logger.debug(self._message(args, kwargs))

    def info(self, *args, **kwargs):
        self._logger.info(self._message(args, kwargs))

    def warning(self, *args, **kwargs):
        self._logger.warning(self._message(args, kwargs))

    warn = warning

    def error(self, *args, **kwargs):
        self._logger.error(self._message(args, kwargs))

    def exception(self, *args, **kwargs):
        self._logger.exception(self._message(args, kwargs))


class JSONConfig(dict):
    """Dictionary-backed stand-in for calibre's persistent JSONConfig."""

    def __init__(self, name="", defaults=None):
        super().__init__(defaults or {})
        self.name = name
        self.defaults = self

    def get(self, key, default=None):
        return super().get(key, default)

    def set(self, key, value):
        self[key] = value


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

    calibre = put(_module(
        "calibre", prints=_calibre_prints, browser=_calibre_browser,
        as_unicode=as_unicode, ispy3=True, iswindows=False, islinux=True,
        isosx=False, numeric_version=CALIBRE_VERSION, __version__="6.0.0"))
    calibre.__path__ = []

    put(_module("calibre.constants", numeric_version=CALIBRE_VERSION,
                is64bit=True, islinux=True, iswindows=False, isosx=False,
                platform="linux", __version__="6.0.0"))

    customize = put(_module("calibre.customize", Plugin=Plugin, StoreBase=StoreBase))
    customize.__path__ = []
    builtins = put(_module("calibre.customize.builtins"))
    builtins.__path__ = []

    ebooks = put(_module("calibre.ebooks", normalize=normalize))
    ebooks.__path__ = []

    put(_module("calibre.ebooks.chardet", xml_to_unicode=_xml_to_unicode))
    put(_module("calibre.ebooks.normalize", normalize=normalize))

    book_base = put(_module("calibre.ebooks.metadata.book.base", Metadata=_Metadata))
    book = put(_module("calibre.ebooks.metadata.book", base=book_base, Metadata=_Metadata))
    book.__path__ = []

    sources_base = put(_module("calibre.ebooks.metadata.sources.base",
                               Source=Source, fixcase=_fixcase,
                               fixauthors=_fixauthors))
    sources = put(_module("calibre.ebooks.metadata.sources", base=sources_base, Source=Source))
    sources.__path__ = []

    metadata = put(_module("calibre.ebooks.metadata", check_isbn=check_isbn,
                           book=book, sources=sources, MetaInformation=_Metadata,
                           MetaData=_Metadata, Metadata=_Metadata))
    metadata.__path__ = []

    library = put(_module("calibre.library"))
    library.__path__ = []
    put(_module("calibre.library.comments",
                sanitize_comments_html=_sanitize_comments_html))

    utils = put(_module("calibre.utils"))
    utils.__path__ = []
    put(_module("calibre.utils.localization", canonicalize_lang=_canonicalize_lang,
                get_udc=_get_udc))
    put(_module("calibre.utils.cleantitle", clean_title=_clean_title))
    put(_module("calibre.utils.cleantext", clean_ascii_chars=clean_ascii_chars))
    put(_module("calibre.utils.icu", lower=_lower))
    put(_module("calibre.utils.config", JSONConfig=JSONConfig,
                config_dir=os.path.join(os.path.expanduser("~"), ".config", "calibre")))
    put(_module("calibre.utils.date", utcfromtimestamp=_utcfromtimestamp,
                utc_tz=utc_tz, now=datetime.datetime.now,
                format_date=lambda *a, **k: "",
                UNDEFINED_DATE=datetime.datetime(101, 1, 1)))
    put(_module("calibre.utils.random_ua",
                random_common_chrome_user_agent=random_common_chrome_user_agent,
                random_chrome_ua=random_chrome_ua,
                random_user_agent=_random_user_agent,
                all_chrome_versions=all_chrome_versions,
                random_desktop_platform=random_desktop_platform))
    put(_module("calibre.utils.logging", default_log=PluginLog("calibre"),
                ThreadSafeLog=PluginLog))
    put(_module("calibre.utils.browser", Browser=_Browser))
    put(_module("calibre.ptempfile",
                NamedTemporaryFile=__import__("tempfile").NamedTemporaryFile))

    devices = put(_module("calibre.devices"))
    devices.__path__ = []
    usbms = put(_module("calibre.devices.usbms"))
    usbms.__path__ = []
    put(_module("calibre.devices.usbms.driver", debug_print=_calibre_prints))

    gui2 = put(_module("calibre.gui2", open_url=_open_url))
    gui2.__path__ = []
    gui2.__getattr__ = _dummy_module_getattr
    put(_module("calibre.gui2.complete2", EditWithComplete=_Dummy))
    metadata_gui = put(_module("calibre.gui2.metadata"))
    metadata_gui.__path__ = []
    put(_module("calibre.gui2.metadata.config", ConfigWidget=_Dummy))
    gui_library = put(_module("calibre.gui2.library"))
    gui_library.__path__ = []
    put(_module("calibre.gui2.library.delegates", DateDelegate=_Dummy))
    put(_module("calibre.gui2.dialogs"))
    put(_module("calibre.gui2.dialogs.message_box", MessageBox=_Dummy))

    qt = put(_module("qt"))
    qt.__path__ = []
    qt_core = put(_module("qt.core"))
    qt_core.__getattr__ = _dummy_module_getattr
    qt.core = qt_core

    _install_store_shims(put, calibre)


class _DummyMeta(type):
    def __getattr__(cls, name):
        return _Dummy


class _Dummy(metaclass=_DummyMeta):
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
