"""
agent_config.py — helpers that author an agent's configuration (its own sub-model in the agent
item's <state>), built on top of state.StateEditor.

First recipe: Advanced Lighting scenes. The agent's state is
<State><all_scenes><AdvScene>...</AdvScene>...</all_scenes><all_off_toggle_scenes/></State>;
each scene has <all_members><AdvSceneMember> load entries. Structures/defaults reverse-engineered
from captures 15-18. Other agent config models (scheduler entries, announcements, ...) would each
be an analogous helper class here.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import List, Optional

from .model import ProjectModel
from .state import edit_state

# Per-scene defaults (everything except the caller-supplied name / scene_id).
_SCENE_DEFAULTS = {
    "track_mode": "0",
    "top_active_color": "0000ff", "top_inactive_color": "000000",
    "btm_active_color": "000000", "btm_inactive_color": "0000ff",
    "toggle_active_color": "0000ff", "toggle_inactive_color": "000000",
    "hold_rate_up": "5000", "hold_rate_down": "5000",
    "toggle_id": "65535", "off_toggle_id": "65535",   # 65535 = "not togglable"
    "user_defined": "False", "lock_loads": "False",
}


class AdvancedLighting:
    """Edits an Advanced Lighting agent's scene configuration. Make changes, then flush()."""

    def __init__(self, model: ProjectModel, agent_id: str, editor=None):
        self.model = model
        # Accept a shared StateEditor (so the Project facade can keep one editor per item and avoid
        # lost updates); otherwise build our own.
        self.ed = editor if editor is not None else edit_state(model, agent_id)
        self.root = self.ed.init_root("State")
        for tag in ("all_scenes", "all_off_toggle_scenes"):
            if self.root.find(tag) is None:
                ET.SubElement(self.root, tag)

    # ---- read ---------------------------------------------------------------
    def scene_names(self) -> List[str]:
        return [(s.findtext("name") or "").strip()
                for s in self.root.find("all_scenes").findall("AdvScene")]

    def _find_scene(self, name: str) -> Optional[ET.Element]:
        for s in self.root.find("all_scenes").findall("AdvScene"):
            if (s.findtext("name") or "").strip() == name:
                return s
        return None

    # ---- write --------------------------------------------------------------
    def add_scene(self, name: str, scene_id: Optional[int] = None) -> int:
        """Create an empty scene. Auto-allocates the next scene_id if not given. Returns scene_id."""
        all_scenes = self.root.find("all_scenes")
        if scene_id is None:
            used = [int(s.findtext("scene_id") or -1) for s in all_scenes.findall("AdvScene")]
            scene_id = (max(used) + 1) if used else 0
        sc = ET.SubElement(all_scenes, "AdvScene")
        ET.SubElement(sc, "name").text = name
        ET.SubElement(sc, "track_mode").text = _SCENE_DEFAULTS["track_mode"]
        for tag in ("top_active_color", "top_inactive_color", "btm_active_color",
                    "btm_inactive_color", "toggle_active_color", "toggle_inactive_color",
                    "hold_rate_up", "hold_rate_down"):
            ET.SubElement(sc, tag).text = _SCENE_DEFAULTS[tag]
        ET.SubElement(sc, "scene_id").text = str(scene_id)
        ET.SubElement(sc, "toggle_id").text = _SCENE_DEFAULTS["toggle_id"]
        ET.SubElement(sc, "off_toggle_id").text = _SCENE_DEFAULTS["off_toggle_id"]
        ET.SubElement(sc, "user_defined").text = _SCENE_DEFAULTS["user_defined"]
        ET.SubElement(sc, "lock_loads").text = _SCENE_DEFAULTS["lock_loads"]
        ET.SubElement(sc, "all_members")
        return scene_id

    def add_member(self, scene_name: str, device_id: str, *, level: int = 100,
                   level_rate: int = 750, color_x: str = "0.380438",
                   color_y: str = "0.376746") -> ET.Element:
        """Add a light load (proxy device_id) to a scene at the given level. Mirrors capture 17."""
        scene = self._find_scene(scene_name)
        if scene is None:
            raise ValueError(f"no scene named {scene_name!r}")
        members = scene.find("all_members")
        m = ET.SubElement(members, "AdvSceneMember")
        ET.SubElement(m, "device_id").text = str(device_id)
        ET.SubElement(m, "track_level_tracking").text = "4"
        ET.SubElement(m, "track_level").text = str(level)
        ET.SubElement(m, "track_color_x").text = color_x
        ET.SubElement(m, "track_color_y").text = color_y
        ET.SubElement(m, "track_color_mode").text = "0"
        ET.SubElement(m, "track_color_tracking").text = "0"
        ET.SubElement(m, "flash").text = "False"
        ET.SubElement(m, "ignore_ramp").text = "False"
        elements = ET.SubElement(m, "all_elements")
        el = ET.SubElement(elements, "element")
        for tag, val in (("delay", "0"), ("levelEnabled", "True"), ("levelRate", str(level_rate)),
                         ("level", str(level)), ("levelPresetID", "1"), ("colorEnabled", "False"),
                         ("colorRate", "1000"), ("colorX", color_x), ("colorY", color_y),
                         ("colorMode", "0"), ("colorPresetID", "0"), ("colorPresetOrigin", "0")):
            ET.SubElement(el, tag).text = val
        return m

    def _next_scene_id(self) -> int:
        used = [int(s.findtext("scene_id") or -1)
                for s in self.root.find("all_scenes").findall("AdvScene")]
        used += [int(o.findtext("scene_id") or -1)
                 for o in self.root.find("all_off_toggle_scenes").findall("OffToggleScene")]
        return (max(used) + 1) if used else 0

    def set_togglable(self, scene_name: str, off_toggle_id: Optional[int] = None) -> int:
        """Enable the 'default toggle' option (capture 18): point the scene's off_toggle_id at a new
        OffToggleScene entry created under all_off_toggle_scenes. Auto-allocates the toggle scene id
        if not given. Returns it."""
        scene = self._find_scene(scene_name)
        if scene is None:
            raise ValueError(f"no scene named {scene_name!r}")
        if off_toggle_id is None:
            off_toggle_id = self._next_scene_id()
        scene.find("off_toggle_id").text = str(off_toggle_id)
        ots = ET.SubElement(self.root.find("all_off_toggle_scenes"), "OffToggleScene")
        ET.SubElement(ots, "name").text = f"{scene_name} (OffToggle)"
        ET.SubElement(ots, "parent_scene_id").text = scene.findtext("scene_id")
        ET.SubElement(ots, "scene_id").text = str(off_toggle_id)
        return off_toggle_id

    def flush(self) -> None:
        self.ed.flush()
