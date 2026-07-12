"""
c4p.py — read/repackage a Control4 Composer project archive (.c4p).

A .c4p is a zip of:
  meta/manifest.json   — per-file md5 + size + restore paths (integrity, NOT a signature)
  project.xml          — the entire authorable project (devices, bindings, programming, vars)
  identity.db, mm.db   — users/permissions and media metadata (SQLite)
  drivers/*.c4z|.c4i    — the driver files the project references

Editing flow proven for this system: modify project.xml, recompute its md5+size in
manifest.json, rezip. The md5 is a plain MD5 over raw file bytes (verified against a real
backup), so no signing key is involved.

This module deliberately does NOT interpret project.xml — see model.py for that. It only
handles the archive envelope and the integrity manifest, so the round-trip is lossless for
every file we don't touch.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import shutil
import tempfile
import zipfile
from dataclasses import dataclass, field
from typing import Dict, List, Optional


def _md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class IntegrityIssue:
    archive_path: str
    kind: str        # "md5-mismatch" | "missing-in-workdir" | "unlisted-in-manifest"
    detail: str = ""


@dataclass
class C4Package:
    """An opened .c4p, unpacked to a working directory."""

    workdir: str
    manifest: dict
    source_path: Optional[str] = None
    _owns_workdir: bool = False
    # archive-path -> manifest item dict (for the files that carry md5/size)
    _items: Dict[str, dict] = field(default_factory=dict)

    # ---- open / close -------------------------------------------------------
    @classmethod
    def open(cls, c4p_path: str, workdir: Optional[str] = None) -> "C4Package":
        owns = workdir is None
        if owns:
            workdir = tempfile.mkdtemp(prefix="c4p_")
        os.makedirs(workdir, exist_ok=True)
        with zipfile.ZipFile(c4p_path) as z:
            z.extractall(workdir)
        # Two .c4p shapes exist:
        #  - full BACKUP: meta/manifest.json (md5s) + identity.db + drivers + project.xml + mm.db
        #  - lightweight SAVE (virtual director / Save Project As): project.xml + mm.db + drivers,
        #    NO meta/manifest.json and NO identity.db (project metadata is in the zip comment).
        # project.xml is the common core; the manifest is optional.
        mpath = os.path.join(workdir, "meta", "manifest.json")
        if os.path.exists(mpath):
            with open(mpath) as f:
                manifest = json.load(f)
        elif os.path.exists(os.path.join(workdir, "project.xml")):
            manifest = {}  # lightweight save format
        else:
            raise ValueError("not a valid .c4p: no meta/manifest.json and no project.xml")
        pkg = cls(workdir=workdir, manifest=manifest,
                  source_path=os.path.abspath(c4p_path), _owns_workdir=owns)
        pkg._index_items()
        return pkg

    def _index_items(self) -> None:
        self._items = {}
        for src in self.manifest.get("manifest", {}).get("sources", []):
            for item in src.get("items", []):
                self._items[item["archive-path"]] = item

    def close(self) -> None:
        if self._owns_workdir and os.path.isdir(self.workdir):
            shutil.rmtree(self.workdir, ignore_errors=True)

    def __enter__(self) -> "C4Package":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ---- paths --------------------------------------------------------------
    def path(self, archive_path: str) -> str:
        return os.path.join(self.workdir, archive_path)

    @property
    def project_xml(self) -> str:
        return self.path("project.xml")

    # ---- identity -----------------------------------------------------------
    def identity(self) -> dict:
        """Fields that identify *which* project/version this archive is — surfaced to the
        user for confirmation before any edit, so a stale backup can't be edited by mistake."""
        m = self.manifest.get("manifest", {})
        info = {
            "director_version": m.get("director-version", "?"),
            "manifest_version": m.get("manifest-version", "?"),
            "file": self.source_path or "(unpacked)",
            "file_mtime": None,
            "file_size_mb": None,
        }
        if self.source_path and os.path.exists(self.source_path):
            st = os.stat(self.source_path)
            info["file_mtime"] = datetime.datetime.fromtimestamp(st.st_mtime).isoformat(
                timespec="seconds")
            info["file_size_mb"] = round(st.st_size / 1e6)
        return info

    # ---- integrity ----------------------------------------------------------
    def verify(self) -> List[IntegrityIssue]:
        """Check every manifest file against the bytes on disk. Empty list == clean."""
        issues: List[IntegrityIssue] = []
        for ap, item in self._items.items():
            p = self.path(ap)
            if not os.path.exists(p):
                issues.append(IntegrityIssue(ap, "missing-in-workdir"))
                continue
            if "md5" in item:
                got = _md5(p)
                if got != item["md5"]:
                    issues.append(
                        IntegrityIssue(ap, "md5-mismatch",
                                       f"manifest={item['md5']} actual={got}")
                    )
        return issues

    # ---- save ---------------------------------------------------------------
    def refresh_manifest(self) -> List[str]:
        """Recompute md5+size for every manifest file from current bytes on disk.
        Returns the list of archive-paths whose md5 changed."""
        changed: List[str] = []
        for ap, item in self._items.items():
            p = self.path(ap)
            if not os.path.exists(p):
                continue
            new_size = os.path.getsize(p)
            if "md5" in item:
                new_md5 = _md5(p)
                if item["md5"] != new_md5:
                    changed.append(ap)
                item["md5"] = new_md5
            if "size" in item:
                item["size"] = new_size
        # write manifest back
        with open(self.path("meta/manifest.json"), "w") as f:
            json.dump(self.manifest, f, indent=3)
        return changed

    def save(self, out_path: str) -> List[str]:
        """Recompute integrity, then repackage every file in the workdir into a new .c4p.
        Returns the archive-paths whose md5 changed since open()."""
        changed = self.refresh_manifest()
        # zip everything under workdir, preserving relative archive paths
        files: List[str] = []
        for root, _dirs, names in os.walk(self.workdir):
            for n in names:
                full = os.path.join(root, n)
                rel = os.path.relpath(full, self.workdir)
                files.append(rel)
        files.sort()
        tmp = out_path + ".tmp"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
            for rel in files:
                z.write(os.path.join(self.workdir, rel), arcname=rel)
        os.replace(tmp, out_path)
        return changed
