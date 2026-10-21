"""Load calibre metadata-source plugin zips via the calibre shim."""

from __future__ import annotations

import importlib
import importlib.abc
import importlib.util
import posixpath
import queue
import re
import sys
import threading
import zipfile

from .metadata import Metadata, MetadataSource
from . import calibre_shim

log = calibre_shim.PluginLog(__name__)

# Calibre installs every plugin package below this namespace.
_IMPORT_ROOT = "calibre_plugins"
_IDENTIFIER = re.compile(r"[a-zA-Z][_0-9a-zA-Z]*")


class CalibrePluginAdapter(MetadataSource):
    """Adapt a wrapped calibre metadata-source plugin to MetadataSource."""

    def __init__(self, plugin):
        self._plugin = plugin
        self.id = str(getattr(plugin, "id", "") or getattr(plugin, "name", "") or "calibre-plugin")
        self.name = str(getattr(plugin, "name", self.id))
        self.version = str(getattr(plugin, "version", ""))
        self.description = str(getattr(plugin, "description", ""))

    # -- MetadataSource contract -------------------------------------------

    def search(self, title: str = "", authors: list[str] | None = None,
               isbn: str = "", timeout: float = 15.0) -> list[Metadata]:
        plugin = self._plugin

        # Pragmatic path: plugin exposes a direct search callable.
        search_fn = getattr(plugin, "search", None)
        if callable(search_fn):
            raw = search_fn(title=title, authors=authors, isbn=isbn, timeout=timeout)
            return [self._translate(m) for m in (raw or [])]

        # Calibre path: drive identify() through a result queue.
        identify = getattr(plugin, "identify", None)
        if callable(identify):
            results: queue.Queue = queue.Queue()
            abort = threading.Event()
            identifiers = {"isbn": isbn} if isbn else {}
            try:
                identify(log, results, abort, title=title or None,
                         authors=authors, identifiers=identifiers,
                         timeout=timeout)
            except Exception:
                log.exception("calibre plugin %r identify() failed", self.id)
            out = []
            while True:
                try:
                    out.append(self._translate(results.get_nowait()))
                except queue.Empty:
                    break
            return out

        return []

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        plugin = self._plugin
        fetch = getattr(plugin, "fetch_cover", None) or getattr(plugin, "download_cover", None)
        if not callable(fetch):
            if meta.cover_url:
                try:
                    import urllib.request
                    with urllib.request.urlopen(meta.cover_url, timeout=timeout) as resp:
                        return resp.read()
                except Exception:
                    log.exception("cover download failed for %r", meta.cover_url)
            return None
        results: queue.Queue = queue.Queue()
        abort = threading.Event()
        try:
            fetch(log, results, abort, title=meta.title or None,
                  authors=meta.authors or None,
                  identifiers={"isbn": meta.isbn} if meta.isbn else {},
                  timeout=timeout)
        except TypeError:
            # Some plugins define a simpler signature.
            try:
                data = fetch(meta)
                return bytes(data) if data else None
            except Exception:
                log.exception("calibre plugin %r download_cover() failed", self.id)
                return None
        except Exception:
            log.exception("calibre plugin %r download_cover() failed", self.id)
            return None
        try:
            item = results.get_nowait()
        except queue.Empty:
            return None
        if isinstance(item, (bytes, bytearray)):
            return bytes(item)
        if isinstance(item, tuple) and item and isinstance(item[-1], (bytes, bytearray)):
            return bytes(item[-1])
        return None

    # -- translation ---------------------------------------------------------

    def _translate(self, m) -> Metadata:
        if isinstance(m, Metadata):
            if not m.source_id:
                m.source_id = self.id
            if not m.source_name:
                m.source_name = self.name
            return m
        identifiers = getattr(m, "identifiers", None) or {}
        rating = getattr(m, "rating", None) or 0.0
        pubdate = getattr(m, "pubdate", None)
        languages = getattr(m, "languages", None) or []
        cover = (getattr(m, "cached_cover_url", None)
                 or getattr(m, "cover_url", None))
        if callable(cover):
            try:
                cover = cover(False)
            except Exception:
                cover = None
        return Metadata(
            title=str(getattr(m, "title", "") or ""),
            authors=[str(a) for a in (getattr(m, "authors", None) or [])],
            isbn=str(identifiers.get("isbn") or getattr(m, "isbn", "") or ""),
            publisher=str(getattr(m, "publisher", "") or ""),
            pubdate=str(pubdate) if pubdate else "",
            language=str(languages[0]) if languages else "",
            description=str(getattr(m, "comments", "") or ""),
            tags=[str(t) for t in (getattr(m, "tags", None) or [])],
            rating=float(rating),
            cover_url=str(cover) if cover else "",
            source_id=self.id,
            source_name=self.name,
        )


# -- zip-backed module loading ---------------------------------------------


class _Archive:
    """The importable contents of one plugin zip."""

    def __init__(self, zip_path: str, plugin_name: str):
        self.zip_path = zip_path
        self.plugin_name = plugin_name
        self.files: dict[str, str] = {}  # dotted module name -> zip member
        self.packages: set[str] = set()

    def full_name(self, module: str) -> str:
        base = f"{_IMPORT_ROOT}.{self.plugin_name}"
        return f"{base}.{module}" if module else base

    def resource(self, name_or_names):
        names = [name_or_names] if isinstance(name_or_names, str) else list(name_or_names)
        out = {}
        with zipfile.ZipFile(self.zip_path) as zf:
            for name in names:
                try:
                    out[name] = zf.read(name)
                except KeyError:
                    continue
        if isinstance(name_or_names, str):
            return out.get(name_or_names)
        return out


class _ArchiveLoader(importlib.abc.Loader):
    def __init__(self, archive: _Archive, module: str, member: str):
        self.archive = archive
        self.module = module
        self.member = member

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        with zipfile.ZipFile(self.archive.zip_path) as zf:
            source = zf.read(self.member)
        filename = f"{self.archive.zip_path}/{self.member}"
        code = compile(source, filename, "exec", dont_inherit=True)
        module.__file__ = filename
        module.__dict__["get_resources"] = self.archive.resource
        module.__dict__["get_icons"] = lambda *args, **kwargs: None
        module.__dict__["load_translations"] = (
            lambda *args, **kwargs: _install_translations(module))
        exec(code, module.__dict__)


def _install_translations(module) -> None:
    """Provide the gettext names calibre injects into plugin modules."""
    module.__dict__.setdefault("_", lambda text, *args, **kwargs: text)
    module.__dict__.setdefault(
        "ngettext",
        lambda singular, plural, n, *args, **kwargs: singular if n == 1 else plural)


class _ArchiveFinder(importlib.abc.MetaPathFinder):
    """Resolve ``calibre_plugins.<plugin>.*`` from registered zip archives."""

    def __init__(self):
        self.archives: dict[str, _Archive] = {}

    def register(self, archive: _Archive) -> None:
        # Drop modules from an earlier load of the same plugin name so a
        # reinstalled archive cannot leave stale submodules behind.
        prefix = f"{_IMPORT_ROOT}.{archive.plugin_name}"
        for name in [n for n in sys.modules if n == prefix or n.startswith(prefix + ".")]:
            del sys.modules[name]
        self.archives[archive.plugin_name] = archive

    def find_spec(self, fullname, path=None, target=None):
        if fullname == _IMPORT_ROOT:
            return importlib.util.spec_from_loader(
                fullname, _NamespaceLoader(), is_package=True)
        if not fullname.startswith(_IMPORT_ROOT + "."):
            return None
        parts = fullname.split(".")
        archive = self.archives.get(parts[1])
        if archive is None:
            return None
        module = ".".join(parts[2:])
        if not module:
            member = archive.files.get("__init__")
            if member is None:
                return None
            return importlib.util.spec_from_loader(
                fullname, _ArchiveLoader(archive, "", member), is_package=True)
        member = archive.files.get(module)
        is_package = module in archive.packages
        if member is None and is_package:
            member = archive.files.get(module + ".__init__")
        if member is None:
            return None
        return importlib.util.spec_from_loader(
            fullname, _ArchiveLoader(archive, module, member),
            is_package=is_package)


class _NamespaceLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None

    def exec_module(self, module):
        module.__path__ = []


_finder = _ArchiveFinder()


def _install_finder() -> None:
    if _finder not in sys.meta_path:
        sys.meta_path.insert(0, _finder)


def _find_import_name(zf: zipfile.ZipFile) -> str:
    """Derive the package name from the marker's filename, like calibre.

    Modern calibre ignores the marker body; older archives stored the dotted
    import path there.  Both are accepted, with the filename taking priority.
    """
    for name in zf.namelist():
        base = posixpath.basename(name)
        stem, ext = posixpath.splitext(base)
        if not stem.startswith("plugin-import-name-") or ext != ".txt":
            continue
        candidate = stem[len("plugin-import-name-"):]
        if _IDENTIFIER.fullmatch(candidate):
            return candidate
        body = zf.read(name).decode("utf-8", "replace").strip()
        body = body.split(".")[-1] if body else ""
        if _IDENTIFIER.fullmatch(body):
            return body
        raise ValueError(f"invalid plugin import name: {candidate!r}")
    raise ValueError("plugin zip has no plugin-import-name-*.txt marker")


def _module_files(zf: zipfile.ZipFile, import_name: str) -> tuple[dict[str, str], set[str]]:
    """Map dotted module names to zip members using calibre's layout rules."""
    names = [n[1:] if n.startswith("/") else n for n in zf.namelist()]
    prefix = f"{import_name}/"
    if f"{prefix}__init__.py" not in names:
        # Real calibre zips keep modules at the archive root.
        prefix = ""
    py_files = {
        n[len(prefix):]: n
        for n in names
        if n.startswith(prefix) and n.endswith(".py")
    }
    if not py_files:
        raise ValueError(f"no Python modules for package {import_name!r}")

    # A directory is importable only when it and every ancestor carry an
    # __init__.py; loose .py files in resource directories are ignored.
    packages = set()
    for rel in sorted(py_files, key=lambda p: p.count("/")):
        if posixpath.basename(rel) != "__init__.py":
            continue
        directory = posixpath.dirname(rel)
        parent = posixpath.dirname(directory)
        if parent and parent.replace("/", ".") not in packages:
            continue
        packages.add(directory.replace("/", "."))

    files: dict[str, str] = {}
    for rel, member in py_files.items():
        directory = posixpath.dirname(rel)
        if directory and directory.replace("/", ".") not in packages:
            continue
        dotted = rel[:-3].replace("/", ".")
        if dotted == "__init__":
            files["__init__"] = member
        elif dotted.endswith(".__init__"):
            files[dotted[:-len(".__init__")]] = member
        else:
            files[dotted] = member
    if "__init__" not in files:
        # Legacy plugins named their entry module ``<name>_plugin.py``.
        for dotted, member in list(files.items()):
            if "." not in dotted and dotted.endswith("plugin"):
                files["__init__"] = member
                break
    if "__init__" not in files:
        raise ValueError("plugin zip has no top-level __init__.py")
    return files, packages


def _find_plugin_instance(pkg, modules):
    from calibre.ebooks.metadata.sources.base import Source

    # Prefer the declared entry point: Plugin subclass with load_actual_plugin.
    # Only classes defined by the plugin's own modules qualify; base classes
    # imported from the shim (Source, Plugin) are excluded.
    candidates = []
    seen = set()
    for mod in [pkg, *modules]:
        for value in vars(mod).values():
            if (
                isinstance(value, type)
                and issubclass(value, Source)
                and value is not Source
                and value.__module__.startswith(pkg.__name__)
                and id(value) not in seen
            ):
                seen.add(id(value))
                candidates.append(value)
    if not candidates:
        raise ValueError("no metadata Source subclass found in plugin")
    candidates.sort(key=lambda cls: cls.__module__.count("."))
    cls = candidates[0]
    try:
        return cls.load_actual_plugin(pkg)
    except Exception:
        return cls()


def load_plugin_zip(zip_path: str) -> MetadataSource:
    """Load a calibre plugin zip and return a MetadataSource adapter."""
    calibre_shim.install()
    _install_finder()
    with zipfile.ZipFile(zip_path) as zf:
        import_name = _find_import_name(zf)
        files, packages = _module_files(zf, import_name)
        init_member = files["__init__"]
        source = zf.read(init_member).decode("utf-8", "replace")
        if "InterfaceActionBase" in source:
            raise ValueError(
                "this is a Calibre GUI action plugin; Vellum supports "
                "metadata-source and store plugins"
            )
    archive = _Archive(zip_path, import_name)
    archive.files = files
    archive.packages = packages
    _finder.register(archive)

    pkg = importlib.import_module(archive.full_name(""))
    modules = [
        mod for name, mod in list(sys.modules.items())
        if name.startswith(pkg.__name__ + ".") and mod is not None
    ]
    plugin = _find_plugin_instance(pkg, modules)
    adapter = CalibrePluginAdapter(plugin)
    adapter.import_name = import_name
    return adapter


def unload_plugin(import_name: str) -> None:
    """Remove a loaded plugin's modules and archive registration.

    After this, ``import calibre_plugins.<import_name>`` raises
    ModuleNotFoundError (until the archive is registered again).
    """
    prefix = f"{_IMPORT_ROOT}.{import_name}"
    for name in [n for n in sys.modules
                 if n == prefix or n.startswith(prefix + ".")]:
        del sys.modules[name]
    _finder.archives.pop(import_name, None)
