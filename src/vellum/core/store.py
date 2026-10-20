"""Load calibre *store* plugin zips (e.g. Library Genesis) via the shim."""

from __future__ import annotations

import logging
import sys
import types
import zipfile
from dataclasses import dataclass
from pathlib import Path

from vellum.plugins import calibre_shim

log = logging.getLogger(__name__)


@dataclass
class StoreResult:
    title: str = ""
    author: str = ""
    formats: str = ""
    detail_item: str = ""
    cover_url: str = ""
    download_url: str = ""
    store_name: str = ""


def is_store_plugin(zip_path: str) -> bool:
    """Cheap check: zip carries a plugin-import-name-store_*.txt marker."""
    try:
        with zipfile.ZipFile(zip_path) as zf:
            for name in zf.namelist():
                base = name.rsplit("/", 1)[-1]
                if base.startswith("plugin-import-name-store_") and base.endswith(".txt"):
                    return True
    except zipfile.BadZipFile:
        pass
    return False


def _find_import_name(zf: zipfile.ZipFile) -> str:
    for name in zf.namelist():
        base = name.rsplit("/", 1)[-1]
        if base.startswith("plugin-import-name-") and base.endswith(".txt"):
            content = zf.read(name).decode("utf-8").strip()
            if content:
                return content
            # Empty marker (some store plugins): derive from the filename.
            return base[len("plugin-import-name-"):-len(".txt")]
    raise ValueError("plugin zip has no plugin-import-name-*.txt marker")


def _load_package(zf: zipfile.ZipFile, import_name: str):
    prefix = import_name + "/"
    py_files = sorted(
        n for n in zf.namelist()
        if n.startswith(prefix) and n.endswith(".py")
        and "/" not in n[len(prefix):]
    )
    if not py_files:
        # Store plugins sometimes ship their modules at the zip root.
        prefix = ""
        py_files = sorted(
            n for n in zf.namelist()
            if n.endswith(".py") and "/" not in n
        )
    if not py_files:
        raise ValueError(f"no top-level .py files for package {import_name!r}")

    pkg = types.ModuleType(import_name)
    pkg.__path__ = []
    pkg.__package__ = import_name
    sys.modules[import_name] = pkg

    def sort_key(n):
        stem = n[len(prefix):]
        return (stem != "__init__.py", stem)

    modules = []
    for name in sorted(py_files, key=sort_key):
        stem = name[len(prefix):-3]
        if stem == "__init__":
            mod = pkg
        else:
            mod = types.ModuleType(f"{import_name}.{stem}")
            mod.__package__ = import_name
            sys.modules[mod.__name__] = mod
        code = compile(zf.read(name).decode("utf-8"), name, "exec")
        exec(code, mod.__dict__)
        modules.append(mod)
    return pkg, modules


def _find_search_fn(modules):
    for mod in modules:
        fn = getattr(mod, "search_libgen", None)
        if callable(fn):
            return fn
    for mod in modules:
        for key, value in vars(mod).items():
            if key.startswith("search") and callable(value) and not isinstance(value, type):
                return value
    return None


def _find_module_with(modules, attr):
    for mod in modules:
        if callable(getattr(mod, attr, None)):
            return mod
    return None


class StoreAdapter:
    """Adapt a calibre store plugin to Vellum's StoreResult contract."""

    def __init__(self, name: str, description: str, zip_path: str, modules):
        self.name = name
        self.description = description
        self.zip_path = zip_path
        self._modules = modules
        self._search_fn = _find_search_fn(modules)

    def search(self, query: str, max_results: int = 10,
               timeout: float = 60.0) -> list[StoreResult]:
        if self._search_fn is None:
            log.warning("store plugin %s has no search callable", self.name)
            return []
        try:
            raw = self._search_fn(query, max_results=max_results, timeout=timeout)
        except Exception:
            log.exception("store plugin %s search failed", self.name)
            return []
        out = []
        for r in raw or []:
            out.append(StoreResult(
                title=str(getattr(r, "title", "") or ""),
                author=str(getattr(r, "author", "") or ""),
                formats=str(getattr(r, "formats", "") or ""),
                detail_item=str(getattr(r, "detail_item", "") or ""),
                cover_url=str(getattr(r, "cover_url", "") or ""),
                store_name=self.name,
            ))
        return out

    def fetch_download(self, result: StoreResult,
                       timeout: float = 60.0) -> StoreResult | None:
        mod = _find_module_with(self._modules, "resolve_spa_download")
        if mod is None:
            return None
        try:
            from calibre.gui2.store.search_result import SearchResult
            sr = SearchResult()
            sr.title = result.title
            sr.author = result.author
            sr.formats = result.formats
            sr.detail_item = result.detail_item
            sr.cover_url = result.cover_url
            ok = mod.resolve_spa_download(sr, timeout)
            if not ok:
                return None
            downloads = getattr(sr, "downloads", None) or {}
            wanted = [
                f.strip() for f in (result.formats or "").split(",") if f.strip()
            ]
            chosen = ""
            url = ""
            for fmt in wanted:
                for key, value in downloads.items():
                    if key.upper() == fmt.upper() and value:
                        chosen, url = fmt, value
                        break
                if url:
                    break
            if not url and downloads:
                # Last resort: take the plugin's first download but keep
                # the extension consistent with the URL's format key.
                key, value = next(iter(downloads.items()))
                if value:
                    chosen, url = key, value
            if not url:
                return None
            result.download_url = str(url)
            result.formats = chosen or result.formats
            cover = getattr(sr, "cover_url", "")
            if cover:
                result.cover_url = str(cover)
            return result
        except Exception:
            log.exception("store plugin %s fetch_download failed", self.name)
            return None


def load_store_plugin(zip_path: str) -> StoreAdapter | None:
    """Load a store plugin zip; None when it is not a store plugin."""
    if not is_store_plugin(zip_path):
        return None
    calibre_shim.install()
    try:
        with zipfile.ZipFile(zip_path) as zf:
            import_name = _find_import_name(zf)
            pkg, modules = _load_package(zf, import_name)
    except Exception:
        log.exception("failed to load store plugin %s", zip_path)
        return None

    name = Path(zip_path).stem
    description = ""
    from calibre.customize import Plugin
    for value in vars(pkg).values():
        if (
            isinstance(value, type)
            and issubclass(value, Plugin)
            and value is not Plugin
            and value.__module__ == pkg.__name__
        ):
            name = str(getattr(value, "name", "") or name)
            description = str(getattr(value, "description", "") or "")
            break
    return StoreAdapter(name, description, zip_path, modules)
