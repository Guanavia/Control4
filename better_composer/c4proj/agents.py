"""
agents.py — resolve an agent's programmable vocabulary (commands/conditionals/events).

Agents ship as compiled native binaries with no XML command/event declarations, so DriverLibrary
(which parses driver XML) resolves NOTHING for them. Their vocab was reverse-engineered separately
(Ghidra; see research/agent_vocab/README.md) and the curated results are bundled as package data in
c4proj/agent_vocab/*.json. This module loads those and presents them as the SAME Command/Condition/
Event types the driver resolver returns, so the Project facade can expose an agent's programmable
surface uniformly with any other device.

Coverage is partial (the ~13 agents curated so far); an agent with no bundled vocab simply resolves
to empty — the API shape is correct, data fills in as more agents are decoded (CLAUDE.md gap #5).
"""

from __future__ import annotations

import json
import os
from typing import Dict, List, Optional

from .drivers import Command, Condition, Event, ResolvedApi

_VOCAB_DIR = os.path.join(os.path.dirname(__file__), "agent_vocab")


def _stem(driver_filename: str) -> str:
    return os.path.splitext(os.path.basename(driver_filename))[0]


class AgentVocab:
    """Index of the bundled per-agent vocab JSONs, keyed by agent driver stem
    (e.g. 'control4_agent_scheduler')."""

    def __init__(self, vocab_dir: str = _VOCAB_DIR):
        self.dir = vocab_dir
        self.by_stem: Dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        if not os.path.isdir(self.dir):
            return
        for f in os.listdir(self.dir):
            if not f.endswith(".json") or f.startswith("_"):
                continue
            try:
                with open(os.path.join(self.dir, f)) as fh:
                    data = json.load(fh)
            except Exception:
                continue
            stem = data.get("agent") or os.path.splitext(f)[0]
            self.by_stem[stem] = data

    def has(self, driver_filename: str) -> bool:
        return _stem(driver_filename) in self.by_stem

    def resolve(self, driver_filename: str) -> Optional[ResolvedApi]:
        """The agent's programmable surface as a ResolvedApi, or None if no vocab is bundled for it.

        Handles both curated schemas: 'legacy' agents (e.g. scheduler) store commands/conditionals
        as {name, params} objects; 'modern' agents store them as plain-string `likely_*` lists (real
        tokens, params not statically recoverable)."""
        data = self.by_stem.get(_stem(driver_filename))
        if data is None:
            return None

        def entries(rich_key: str, plain_key: str):
            """Yield (name, params) from either the {name,params} objects or the plain-string list."""
            for c in data.get(rich_key, []):
                if isinstance(c, dict) and c.get("name"):
                    yield c["name"], list(c.get("params", []))
            for name in data.get(plain_key, []):
                if isinstance(name, str) and name:
                    yield name, []

        commands = [Command(id=n, name=n, description="", params=p)
                    for n, p in entries("commands", "likely_commands")]
        conditions = [Condition(id=n, name=n, description="", params=p)
                      for n, p in entries("conditionals", "likely_conditionals")]
        events = [Event(id=n, name=n, description="")
                  for n, p in entries("events", "likely_events")]
        return ResolvedApi(commands=commands, conditions=conditions, events=events,
                           driver_chain=[_stem(driver_filename)], unresolved_proxy=None)
