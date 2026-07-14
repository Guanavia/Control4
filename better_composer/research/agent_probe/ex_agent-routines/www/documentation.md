# Routines Agent

## Overview

This agent enables the Routines experience in Control4 X4.

Routines are Driverworks drivers that make it possible for customers to add and configure common programming & automation experiences themselves through any Navigator UI.

The Routines Agent will initially add a new, hidden room called `Routines` to your project.

To configure that Routines should be added to a different specific room, set the `Add Routines To Room` property to choose the room that this Agent will add user-selected routines to.

If the room that is specified is deleted from the project, the Routines Agent will add a new, hidden room again.

Routines do not have to remain in this room to work, but it is recommended that they do.

## Agent Properties

### Agent Version - [ READ ONLY ]

Shows the version of the Agent as reported by Director

### Debug Mode - [ On | **Off** ]

Controls whether debug output is printed on the Lua tab in Composer Pro.

### Add Routines To Room - [ Device Selector ]

Which room new routines will be added to when chosen from a Navigator UI.

### Connect Subscription - [ READ ONLY ]

Indicates whether this system has an active connect subscription ("Subscribed") or not ("Not Subscribed").

### Connect Required for Routines - [ READ ONLY ]

Indicates whether this system needs an active connect subscription ("Required") or not ("Not Required") for Routines to work on X4.

## Agent Actions

### Update Routines

Trigger an update of all routines from the online repository of routines. This will also happen whenever the Scheduler event "Component Auto Update Event" runs.

## Driver Events

## Troubleshooting

## Change Log

35

- DRIV-14647 - on failure to install/update routine, re-sync URLs for routines

34

- Setup behavior for X4 Routines when they require a Connect subscription

32

- DRIV-13738 - newly installed systems could not add routines

31

- Update translations

29

- Initial Release
