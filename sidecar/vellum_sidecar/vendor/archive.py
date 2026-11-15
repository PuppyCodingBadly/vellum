"""Import calibre plugin zips as ``calibre_plugins.<name>`` packages.

One lazy, spec-based loader serves metadata and store plugins alike: an
archive is registered with a finder and each module is compiled from the
zip on first import, with ``__file__`` and ``__spec__`` set exactly as
calibre sets them.  Relative and sibling imports therefore work, including
packages nested inside the zip, and a module is only executed after its
siblings exist in ``sys.modules``.
"""

from __future__ import annotations

import importlib
import importlib.abc
import importlib.util
import posixpath
import re
import sys
import types
import zipfile
from dataclasses import dataclass

from . import calibre_shim

# Calibre installs every plugin package below this namespace.
_IMPORT_ROOT = "calibre_plugins"
_IDENTIFIER = re.compile(r"[a-zA-Z][_0-9a-zA-Z]*")
_MARKER = "plugin-import-name-"


class Archive:
    """The importable contents of one plugin zip."""

    def __init__(self, zip_path: str, plugin_name: str,
                 files: dict[str, str], packages: set[str]):
        self.zip_path = zip_path
        self.plugin_name = plugin_name
        self.files = files        # dotted module name -> zip member
        self.packages = packages  # dotted names that are packages

    def full_name(self, module: str) -> str:
        base = f"{_IMPORT_ROOT}.{self.plugin_name}"
        return f"{base}.{module}" if module else base

    def member_path(self, member: str) -> str:
        return f"{self.zip_path}/{member}"

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

    def relocate(self, zip_path: str) -> None:
        """Point this archive and its modules at the path it was installed to."""
        self.zip_path = zip_path
        prefix = self.full_name("")
        for name, module in list(sys.modules.items()):
            if module is None or not (name == prefix or name.startswith(prefix + ".")):
                continue
            loader = getattr(getattr(module, "__spec__", None), "loader", None)
            if isinstance(loader, ArchiveLoader) and loader.archive is self:
                module.__file__ = self.member_path(loader.member)


class ArchiveLoader(importlib.abc.Loader):
    def __init__(self, archive: Archive, member: str):
        self.archive = archive
        self.member = member

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        with zipfile.ZipFile(self.archive.zip_path) as zf:
            source = zf.read(self.member)
        module.__file__ = self.archive.member_path(self.member)
        module.__dict__["get_resources"] = self.archive.resource
        module.__dict__["get_icons"] = lambda *args, **kwargs: None
        module.__dict__["load_translations"] = (
            lambda *args, **kwargs: install_translations(module))
        code = compile(source, module.__file__, "exec", dont_inherit=True)
        exec(code, module.__dict__)


def install_translations(module) -> None:
    """Provide the gettext names calibre injects into plugin modules."""
    module.__dict__.setdefault("_", lambda text, *args, **kwargs: text)
    module.__dict__.setdefault(
        "ngettext",
        lambda singular, plural, n, *args, **kwargs: singular if n == 1 else plural)


class ArchiveFinder(importlib.abc.MetaPathFinder):
    """Resolve ``calibre_plugins.<plugin>.*`` from registered zip archives."""

    def __init__(self):
        self.archives: dict[str, Archive] = {}

    def register(self, archive: Archive) -> None:
        # Drop modules from an earlier load of the same plugin name so a
        # reinstalled archive cannot leave stale submodules behind.
        prefix = f"{_IMPORT_ROOT}.{archive.plugin_name}"
        for name in [n for n in sys.modules if n == prefix or n.startswith(prefix + ".")]:
            del sys.modules[name]
        self.archives[archive.plugin_name] = archive

    def find_spec(self, fullname, path=None, target=None):
        if fullname == _IMPORT_ROOT:
            return importlib.util.spec_from_loader(
                fullname, NamespaceLoader(), is_package=True)
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
                fullname, ArchiveLoader(archive, member), is_package=True)
        member = archive.files.get(module)
        is_package = module in archive.packages
        if member is None and is_package:
            member = archive.files.get(module + ".__init__")
        if member is None:
            return None
        return importlib.util.spec_from_loader(
            fullname, ArchiveLoader(archive, member), is_package=is_package)


class NamespaceLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None

    def exec_module(self, module):
        module.__path__ = []


_finder = ArchiveFinder()


def install_finder() -> None:
    if _finder not in sys.meta_path:
        sys.meta_path.insert(0, _finder)


def find_import_name(zf: zipfile.ZipFile) -> str:
    """Derive the package name from the marker's filename, like calibre.

    Modern calibre ignores the marker body; older archives stored the dotted
    import path there.  Both are accepted and validated, with the filename
    taking priority.
    """
    for name in zf.namelist():
        base = posixpath.basename(name)
        stem, ext = posixpath.splitext(base)
        if not stem.startswith(_MARKER) or ext != ".txt":
            continue
        candidate = stem[len(_MARKER):]
        if _IDENTIFIER.fullmatch(candidate):
            return candidate
        body = zf.read(name).decode("utf-8", "replace").strip()
        body = body.split(".")[-1] if body else ""
        if _IDENTIFIER.fullmatch(body):
            return body
        raise ValueError(f"invalid plugin import name: {candidate!r}")
    raise ValueError("plugin zip has no plugin-import-name-*.txt marker")


def module_files(zf: zipfile.ZipFile, import_name: str) -> tuple[dict[str, str], set[str]]:
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


@dataclass
class LoadedArchive:
    """One plugin zip, imported: its archive registration and package."""

    archive: Archive
    pkg: types.ModuleType

    @property
    def import_name(self) -> str:
        return self.archive.plugin_name

    @property
    def zip_path(self) -> str:
        return self.archive.zip_path

    @property
    def modules(self) -> list[types.ModuleType]:
        """Every module imported under the package, the package included."""
        prefix = self.pkg.__name__
        return [module for name, module in list(sys.modules.items())
                if module is not None
                and (name == prefix or name.startswith(prefix + "."))]

    def classes(self) -> list[type]:
        """Classes the plugin itself defines; imported bases are excluded."""
        prefix = self.pkg.__name__
        classes: list[type] = []
        seen: set[int] = set()
        for module in self.modules:
            for value in vars(module).values():
                if not isinstance(value, type) or id(value) in seen:
                    continue
                origin = getattr(value, "__module__", "") or ""
                if origin == prefix or origin.startswith(prefix + "."):
                    seen.add(id(value))
                    classes.append(value)
        return classes

    def import_all(self) -> None:
        """Import every module the archive declares.

        Store plugins ship loose helper modules that nothing in
        ``__init__`` imports; their search and resolution callables only
        become visible once each module is loaded.
        """
        for module in self.archive.files:
            if module != "__init__":
                importlib.import_module(self.archive.full_name(module))

    def relocate(self, zip_path: str) -> None:
        self.archive.relocate(zip_path)


def load_archive(zip_path: str) -> LoadedArchive:
    """Import one plugin zip under ``calibre_plugins.<marker name>``."""
    calibre_shim.install()
    install_finder()
    with zipfile.ZipFile(zip_path) as zf:
        import_name = find_import_name(zf)
        files, packages = module_files(zf, import_name)
        init_source = zf.read(files["__init__"])
    if b"InterfaceActionBase" in init_source:
        raise ValueError(
            "this is a Calibre GUI action plugin; Vellum supports "
            "metadata-source and store plugins"
        )
    archive = Archive(zip_path, import_name, files, packages)
    _finder.register(archive)
    try:
        pkg = importlib.import_module(archive.full_name(""))
    except BaseException:
        unload_import(import_name)
        raise
    return LoadedArchive(archive, pkg)


def unload_import(import_name: str) -> None:
    """Forget an archive and its modules.

    After this, ``import calibre_plugins.<import_name>`` raises
    ModuleNotFoundError until the archive is registered again.
    """
    _finder.archives.pop(import_name, None)
    prefix = f"{_IMPORT_ROOT}.{import_name}"
    for name in [n for n in sys.modules
                 if n == prefix or n.startswith(prefix + ".")]:
        del sys.modules[name]
