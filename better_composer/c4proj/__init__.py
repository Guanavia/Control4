"""c4proj — read and edit Control4 Composer .c4p project archives.

The primary entry point is the `Project` facade (project.py): open a .c4p, read/edit every
functional area through one consistent API, save it back. The lower-level modules (model, drivers,
state, authoring, programming, agent_config, c4p) remain available for direct use.
"""
from .project import Project, ProjectError, EditableSurface, PropertyValue, jsonable
from .agents import AgentVocab
from .c4p import C4Package, IntegrityIssue
from .model import (
    ProjectModel, Item, Device, ItemKind, Binding, Consumer, Variable, Event, CodeItem,
)
from .drivers import (
    DriverLibrary, Driver, Command, Condition, Connection, Property, ResolvedApi, load_driver,
)
from .state import StateEditor, edit_state

__all__ = [
    # facade
    "Project", "ProjectError", "EditableSurface", "PropertyValue", "jsonable", "AgentVocab",
    # package + model
    "C4Package", "IntegrityIssue",
    "ProjectModel", "Item", "Device", "ItemKind", "Binding", "Consumer", "Variable",
    "Event", "CodeItem",
    # drivers
    "DriverLibrary", "Driver", "Command", "Condition", "Connection", "Property",
    "ResolvedApi", "load_driver",
    # state editing
    "StateEditor", "edit_state",
]
