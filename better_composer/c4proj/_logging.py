"""
_logging.py — togglable debug logging for c4proj.

Off by default (a NullHandler, zero output). Call enable_debug_logging() to start writing DEBUG
records to a file; disable_debug_logging() to stop. Stdlib-only (Python `logging`). The rest of the
package logs through `logger` (`logging.getLogger("c4proj")`), so enabling this captures every
operation without changing call sites.

The API server exposes this as GET/POST /debug and honors the C4PROJ_DEBUG / C4PROJ_DEBUG_LOG env
vars at startup; a desktop UI can wire a "create debug logs" toggle to the same.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

logger = logging.getLogger("c4proj")
logger.addHandler(logging.NullHandler())   # silent unless explicitly enabled
logger.setLevel(logging.WARNING)
logger.propagate = False

_FMT = logging.Formatter("%(asctime)s %(levelname)-5s %(name)s: %(message)s")
_file_handler: Optional[logging.Handler] = None
_console_handler: Optional[logging.Handler] = None


def default_log_path() -> str:
    """Default debug log location: ~/.c4proj/debug.log (cross-platform)."""
    return os.path.join(os.path.expanduser("~"), ".c4proj", "debug.log")


def enable_debug_logging(path: Optional[str] = None, *, console: bool = False) -> str:
    """Turn debug logging ON, writing to `path` (default ~/.c4proj/debug.log). Idempotent — calling
    again re-points to the new path. Returns the resolved log file path."""
    global _file_handler, _console_handler
    disable_debug_logging()
    path = path or default_log_path()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fh = logging.FileHandler(path, encoding="utf-8")
    fh.setFormatter(_FMT)
    logger.addHandler(fh)
    _file_handler = fh
    if console:
        ch = logging.StreamHandler()
        ch.setFormatter(_FMT)
        logger.addHandler(ch)
        _console_handler = ch
    logger.setLevel(logging.DEBUG)
    logger.debug("=== debug logging enabled -> %s ===", path)
    return path


def disable_debug_logging() -> None:
    """Turn debug logging OFF (back to silent)."""
    global _file_handler, _console_handler
    for h in (_file_handler, _console_handler):
        if h is not None:
            logger.removeHandler(h)
            try:
                h.close()
            except Exception:
                pass
    _file_handler = _console_handler = None
    logger.setLevel(logging.WARNING)


def is_debug_enabled() -> bool:
    return _file_handler is not None


def debug_log_path() -> Optional[str]:
    return getattr(_file_handler, "baseFilename", None)
