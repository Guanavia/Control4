# Labeling rules — where every visible string comes from

Non-negotiable. Every user-visible label in the UI is supplied by the driver data; none of it is
invented by the UI. The field to read differs per object type, and the wrong choice yields either a
blank label or an ALL_CAPS wire token. Both failure modes are common because the source data is
inconsistent by design.

All shapes below are as serialized by `surface_of(item_id)` / `tree_view()` — see
`sample_data.json` for real payloads.

## 1. Commands, Events, Conditions — label is `description`, NEVER `name` or `id`

These three carry both a machine identifier and a human sentence. Only the sentence is a label.

Measured across the 295 bundled driver files:

| object     | total | has `name` | has `description` |
|------------|-------|-----------|-------------------|
| commands   | 731   | 238 (33%) | **731 (100%)**    |
| events     | 713   | 508 (71%) | **713 (100%)**    |
| conditions | 185   | 58 (31%)  | **185 (100%)**    |

`description` is the only field that is always populated. `name` is empty on two thirds of commands,
and when it is present it is a wire token (`ON`, `IS_ON`, `REORDER_PRESETS_BY_NAMES`) meant for the
protocol, not the screen. Whether a driver populates `id` or `name` is an authoring-convention
difference between driver vintages and carries no meaning for display.

```
cable.c4i command 0 → id:"0"  name:""     description:"Turn On the NAME"
cd.c4i    command   → id:""   name:"ON"   description:"Turn On the NAME"
```

Both render identically: **"Turn On the Living Room TV"**.

## 2. `description` contains placeholders that MUST be substituted

Uppercase tokens inside `description` are slots, not literal text. Rendering them raw is the single
most visible labeling bug.

- **`NAME`** → the device's own instance name (the `name` on the item/surface). Appears in 669 of
  731 command descriptions. `"Turn On the NAME"` → `"Turn On the Living Room TV"`.
- **Every other uppercase token** → a user-supplied parameter, rendered as an inline input control
  inside the sentence. The token list is already extracted for you as the `params` array; you never
  need to parse the string yourself.

```
description: "last channel is LOGIC INTEGER on the NAME"
params:      ["LOGIC", "INTEGER"]
renders as:  last channel is [ == ▾ ] [  5  ] on the Living Room TV
```

Token vocabulary in order of frequency: `INTEGER` (89), `LOGIC` (40), `STRING` (24), `COLOR` (15),
`BTN_ID` (15), `VALUE`, `WHAT`, `TIME_STRING`, `TIME`, `MODE`, `VARIABLE`. `LOGIC` is a comparison
operator picker; `INTEGER`/`STRING` are typed text entry; `COLOR` is a color picker; `BTN_ID` is a
button selector.

This inline-substitution model is the whole point — the sentence *is* the UI. Do not restructure it
into a label-above-field form; that discards the grammar the driver author wrote.

## 3. Actions — the rule INVERTS. Label is `name`, not `description`

Actions (the device's Actions tab) use the opposite convention from commands. This is the most
likely source of confusion, since Actions and Commands sit next to each other on the same surface.

```json
{ "name": "Reorder Presets by Names",     ← the label
  "command": "REORDER_PRESETS_BY_NAMES",  ← the wire token, never displayed
  "params": [ { "name": "NAMES", "type": "STRING", "items": [], "multiselect": false } ] }
```

Action params are structured objects, not string tokens: label each from its `name`, choose the
control from `type` (`STRING` → text, a `*_SELECTOR` type → picker constrained by `items`), and
allow multiple selection when `multiselect` is true.

## 4. Properties — label is `name` verbatim, EXCEPT type `LABEL`

For normal properties, `name` is already the human string ("Log Level", "Agent Version") and is
displayed as-is. Type drives the control: `LIST` → dropdown over `options`; `RANGED_INTEGER` →
numeric input bounded by `minimum`/`maximum`; `STRING` → text field. `readonly: true` renders as
display-only text, never an editable control.

**`type: "LABEL"` is not a field.** It is a section header dividing the property list. Render
`value` as the heading and never show `name` — the `name` on these is an internal key like
`LABEL_Log_Settings` and must never reach the screen. There is no separate grouping structure in
the data: a `LABEL` property applies to every property following it until the next `LABEL`.

```
LABEL_Log_Settings  (LABEL, value "Log Settings")   →  ── Log Settings ──────────
Log Level           (LIST)                          →      Log Level    [5 - Trace ▾]
Log Mode            (LIST)                          →      Log Mode     [Off ▾]
LABEL_General_Information (LABEL, "General Information") → ── General Information ──
Device ID           (STRING, readonly)              →      Device ID    11
```

## 5. Device labels — instance `name`, not driver name

The item's `name` is the user-assigned instance name ("Living Room TV") and is what appears in the
tree, in breadcrumbs, in focus headers, and substituted for `NAME` in every sentence above.

`driver_info.name` / `manufacturer` / `model` describe the *driver*, not this device. They belong
only in a driver-info panel or catalog result. Never label a device with them — a project with three
identical TVs would show three identical labels.

## Summary

| Object | Label field | Identifier (never shown) |
|---|---|---|
| Command / Event / Condition | `description`, placeholders substituted | `id`, `name` |
| Action | `name` | `command` |
| Action param | `name` | — |
| Property | `name` | — |
| Property, type `LABEL` | `value`, as a section heading | `name` |
| Device / room / agent | item `name` | `id`, `driver` |
| Driver (catalog/info only) | `driver_info.name` + `manufacturer` + `model` | `filename` |
