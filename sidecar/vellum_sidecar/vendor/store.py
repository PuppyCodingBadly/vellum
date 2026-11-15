"""Adapt calibre *store* plugin packages (e.g. Library Genesis) to Vellum.

Store zips are imported through the shared archive loader, so relative and
sibling imports work exactly as in calibre.  Download resolution probes the
strategies real store plugins use and reports why none worked: a generic
"no link" toast cannot be debugged from a silent ``None``.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from .archive import LoadedArchive
from .budget import Budget, plugin_timeout

log = logging.getLogger(__name__)


class StoreDownloadError(RuntimeError):
    """No download link could be resolved; ``str()`` carries the reason."""


@dataclass
class StoreResult:
    title: str = ""
    author: str = ""
    formats: str = ""
    detail_item: str = ""
    cover_url: str = ""
    download_url: str = ""
    store_name: str = ""
    #: Direct links a search hit already carries, keyed by format.
    downloads: dict[str, str] = field(default_factory=dict)


def find_store_plugin(loaded: LoadedArchive):
    """Return the store plugin instance a loaded package defines, if any."""
    from calibre.customize import Plugin
    from calibre.gui2.store import StorePlugin

    classes = [cls for cls in loaded.classes()
               if issubclass(cls, Plugin) and cls is not Plugin]
    # A declared store base beats a plain Plugin subclass that happens to
    # live in the same archive.
    classes.sort(key=lambda cls: 0 if issubclass(cls, StorePlugin) else 1)
    for cls in classes:
        try:
            return cls()
        except Exception:
            log.debug("could not instantiate store plugin class %r", cls, exc_info=True)
    return None


def find_search_fn(loaded: LoadedArchive):
    """The plugin's search callable: ``search_libgen`` first, then any ``search*``."""
    modules = loaded.modules
    for module in modules:
        fn = getattr(module, "search_libgen", None)
        if callable(fn):
            return fn
    for module in modules:
        for key, value in vars(module).items():
            if key.startswith("search") and callable(value) and not isinstance(value, type):
                return value
    return None


class StoreAdapter:
    """Adapt a calibre store plugin to Vellum's StoreResult contract."""

    def __init__(self, name: str, description: str, modules: list,
                 plugin=None, search_fn=None):
        self.name = name
        self.description = description
        self.version = ""
        self._modules = modules
        self._plugin = plugin
        self._search_fn = search_fn

    def search(self, query: str, max_results: int = 10,
               budget: Budget | None = None) -> list[StoreResult]:
        timeout = plugin_timeout(budget, 60.0)
        raw = self._search_fn(query, max_results=max_results, timeout=timeout)
        out = []
        for r in raw or []:
            downloads = getattr(r, "downloads", None) or {}
            out.append(StoreResult(
                title=str(getattr(r, "title", "") or ""),
                author=str(getattr(r, "author", "") or ""),
                formats=str(getattr(r, "formats", "") or ""),
                detail_item=str(getattr(r, "detail_item", "") or ""),
                cover_url=str(getattr(r, "cover_url", "") or ""),
                store_name=self.name,
                downloads={str(k): str(v) for k, v in downloads.items() if v},
            ))
        return out

    def fetch_download(self, result: StoreResult,
                       budget: Budget | None = None) -> StoreResult:
        """Resolve a direct download link for ``result``.

        Raises StoreDownloadError with the reason when no strategy yields
        one; the bridge turns that into an ``{error: reason}`` response.
        """
        timeout = plugin_timeout(budget, 60.0)
        downloads = dict(result.downloads or {})
        if not downloads:
            downloads = self._resolve_downloads(result, timeout)
        chosen, url = self._choose(result.formats, downloads)
        if not url:
            raise StoreDownloadError(
                f"store plugin {self.name!r} returned no non-empty download "
                f"link for {result.title!r}")
        result.download_url = url
        result.formats = chosen or result.formats
        return result

    # -- resolution strategies ----------------------------------------------

    def _resolve_downloads(self, result: StoreResult, timeout: float) -> dict[str, str]:
        """Try each way a store plugin can fill in download links.

        Order: the legacy module-level ``resolve_spa_download(sr, timeout)``
        hook, then calibre's own ``get_details(result)`` on the plugin
        instance.  Search hits that already carried ``downloads`` never get
        here.  Every attempt that finds nothing adds its reason.
        """
        errors: list[str] = []
        sr = self._search_result(result)

        module_resolver = None
        for module in self._modules:
            fn = getattr(module, "resolve_spa_download", None)
            if callable(fn):
                module_resolver = fn
                break
        if module_resolver is not None:
            downloads = self._attempt(
                "resolve_spa_download", sr, errors,
                lambda: module_resolver(sr, timeout))
            if downloads:
                return downloads

        get_details = getattr(self._plugin, "get_details", None)
        if callable(get_details):
            downloads = self._attempt(
                "get_details", sr, errors, lambda: get_details(sr))
            if downloads:
                return downloads

        if not errors:
            errors.append("plugin exposes neither resolve_spa_download() "
                          "nor get_details()")
        raise StoreDownloadError("; ".join(errors))

    @staticmethod
    def _attempt(strategy: str, sr, errors: list[str], resolve) -> dict[str, str]:
        """Run one resolution strategy; record why it produced no links."""
        try:
            resolve()
        except Exception as exc:
            errors.append(f"{strategy}() failed: {exc}")
            return {}
        downloads = {str(k): str(v)
                     for k, v in (getattr(sr, "downloads", None) or {}).items() if v}
        if not downloads:
            errors.append(f"{strategy}() found no downloads")
        return downloads

    @staticmethod
    def _search_result(result: StoreResult):
        from calibre.gui2.store.search_result import SearchResult
        sr = SearchResult()
        sr.title = result.title
        sr.author = result.author
        sr.formats = result.formats
        sr.detail_item = result.detail_item
        sr.cover_url = result.cover_url
        return sr

    @staticmethod
    def _choose(formats: str, downloads: dict[str, str]) -> tuple[str, str]:
        """Pick the format the caller asked for, else the first non-empty link."""
        wanted = [f.strip() for f in (formats or "").split(",") if f.strip()]
        for fmt in wanted:
            for key, value in downloads.items():
                if key.upper() == fmt.upper() and value:
                    return fmt, value
        for key, value in downloads.items():
            if value:
                return key, value
        return "", ""


def adapt_store_plugin(loaded: LoadedArchive) -> StoreAdapter:
    """Adapt an imported store plugin package; raises when it cannot search."""
    loaded.import_all()
    search_fn = find_search_fn(loaded)
    if search_fn is None:
        raise ValueError(
            f"store plugin {loaded.import_name!r} has no search callable")
    plugin = find_store_plugin(loaded)
    name = str(getattr(plugin, "name", "") or loaded.import_name)
    description = str(getattr(plugin, "description", "") or "")
    return StoreAdapter(name, description, loaded.modules,
                        plugin=plugin, search_fn=search_fn)
