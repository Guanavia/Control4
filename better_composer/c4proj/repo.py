"""
repo.py — search and download drivers from Control4's online driver database.

Endpoint (public, no auth): https://drivers.control4.com/solr/drivers/browse?wt=json
  - q=<solr query>  e.g. q=manufacturer:Sony
  - fl=<fields>     e.g. fl=name,manufacturer,model,proxy,control,filename,md5sum,combo
Each result doc has a `filename`; the driver downloads directly from
  https://drivers.control4.com/<filename>
"""

from __future__ import annotations

import hashlib
import json
import os
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import List, Optional

BROWSE = "https://drivers.control4.com/solr/drivers/browse"
DOWNLOAD = "https://drivers.control4.com/"


@dataclass
class DriverHit:
    name: str
    manufacturer: str
    model: str
    proxy: List[str]
    control: str
    filename: str
    md5sum: str
    combo: bool


def search(query: str, rows: int = 10) -> List[DriverHit]:
    fl = "name,manufacturer,model,proxy,control,filename,md5sum,combo"
    url = f"{BROWSE}?q={urllib.parse.quote(query)}&rows={rows}&wt=json&fl={fl}"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.load(r)
    out = []
    for d in data["response"]["docs"]:
        out.append(DriverHit(
            name=d.get("name", ""),
            manufacturer=d.get("manufacturer", ""),
            model=d.get("model", ""),
            proxy=d.get("proxy", []) or [],
            control=d.get("control", ""),
            filename=d.get("filename", ""),
            md5sum=d.get("md5sum", ""),
            combo=bool(d.get("combo", False)),
        ))
    return out


def download(filename: str, dest_dir: str, expect_md5: Optional[str] = None) -> str:
    """Download a driver file into dest_dir. Verifies md5 if provided. Returns the path."""
    os.makedirs(dest_dir, exist_ok=True)
    url = DOWNLOAD + urllib.parse.quote(filename)
    dest = os.path.join(dest_dir, filename)
    with urllib.request.urlopen(url, timeout=60) as r:
        blob = r.read()
    if expect_md5:
        got = hashlib.md5(blob).hexdigest()
        if got != expect_md5:
            raise ValueError(f"md5 mismatch for {filename}: expected {expect_md5} got {got}")
    with open(dest, "wb") as f:
        f.write(blob)
    return dest
