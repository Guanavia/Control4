# Control4 Programming — decoded codeitem grammar (compiler spec)

Decoded from the `prog01–prog09` capture series (diffing `event_mgr` + `variables`). This is the
target format for the rule→codeitem **write compiler**.

## Event-anchored model (IMPORTANT / architectural)
ALL programming hangs off an `<event>` = a device event (trigger). There is no event-free
"if"/"while" in Director — every script starts with a "when <device> <event>". Structure:

```xml
<event_mgr>
  <event>
    <deviceid>17</deviceid>          <!-- the device that fires the trigger -->
    <eventid>5001</eventid>          <!-- which event on that device -->
    <codeitem>                        <!-- ROOT container: id=0, device=0, type=1, empty -->
      <id>0</id><device>0</device><type>1</type><display/><cmdcond/>
      <subitems> ...the actual script codeitems... </subitems>
      <creator>0</creator><creatorstate/><enabled>True</enabled>
    </codeitem>
  </event>
</event_mgr>
```

## Codeitem
```xml
<codeitem>
  <id>N</id>                 <!-- sequential within the event, root=0 -->
  <device>DEVID</device>     <!-- device the item acts on (100000 = programming pseudo-device) -->
  <type>T</type>             <!-- see type codes -->
  <display>human text</display>
  <cmdcond> devicecommand | deviceconditional | empty </cmdcond>
  <subitems> nested codeitems (then-branch, else-branch, loop body) </subitems>
  <creator>0</creator><creatorstate/><enabled>True</enabled>
</codeitem>
```

### Type codes (`<type>`) — COMPLETE (prog01–14)
- `1` = COMMAND (action) — device commands, agent cmds, variable ops, AND the programming controls
  DELAY / BREAK / STOP, which are all commands on pseudo-device `100000`
- `2` = CONDITION (if); also the additional conditions inside an `<expression>` (see And/Or)
- `3` = WHILE (loop)
- `4` = ELSE (device=100000)
- `6` = OPERATOR (AND/OR), lives inside an If's `<expression>` block
- (`5` not observed)

## Primitives (exact encodings)

**Command** (prog02) — `<cmdcond>` holds `<devicecommand>`:
```xml
<devicecommand owneridtype="" owneriditem="-1"><command>ON</command><params/></devicecommand>
```

**Command with parameter** (prog03) — device-command params use nested `<value>`:
```xml
<params><param><name>LIGHT_BRIGHTNESS_TARGET_PERCENT</name>
  <value type="INTEGER"><static>50</static></value></param></params>
```

**Conditional / If** (prog04) — type=2, `<deviceconditional>`, then-branch in `<subitems>`:
```xml
<codeitem><device>20</device><type>2</type><display>If NAME is on</display>
  <cmdcond><deviceconditional owneridtype="" owneriditem="-1"><name>LOAD_ON</name></deviceconditional></cmdcond>
  <subitems> ...then... </subitems></codeitem>
```

**Else** (prog05) — type=4, device=100000, sibling of the If, else-branch in `<subitems>`:
```xml
<codeitem><device>100000</device><type>4</type><display>Else</display><cmdcond/>
  <subitems> ...else... </subitems></codeitem>
```

**Delay** (prog06) — type=1, device=100000, DELAY command, `time` in **milliseconds**:
```xml
<devicecommand><command>DELAY</command>
  <params><param><name>time</name><value type="INT"><static>5000</static></value></param></params></devicecommand>
```

**Custom variable definition** (prog07, Variables agent id=100001):
```xml
<variable deviceid="100001" variableid="23" name="variable-test" type="4"
          readonly="0" hidden="0" description="...">0</variable>
```
`type=4` = boolean; value `0/1`. (Variables agent device id = 100001.)

**Set variable** (prog08) — `owneridtype="variable"`, `name="="` (assign), INLINE param:
```xml
<devicecommand owneridtype="variable" owneriditem="23" name="=">
  <param name="value" type="int">1</param></devicecommand>
```
Display uses the `#!"{VNAME} = True";VNAME="VNAME:100001,23"` template (owner deviceid,variableid).

**If variable** (prog09) — type=2, `deviceconditional owneridtype="variable"`, `name="=="`:
```xml
<deviceconditional owneridtype="variable" owneriditem="23" name="==">
  <param name="value" type="int">1</param></deviceconditional>
```

**Agent command** (prog09, toggle scene) — `owneridtype="agent"`:
```xml
<devicecommand owneridtype="agent" owneriditem="0"><command>TOGGLE_SCENE</command>
  <params><param><name>SCENE_ID</name><value type="INTEGER"><static>0</static></value></param></params></devicecommand>
```

**Compound condition — And / Or** (prog10/prog11) — extra conditions go in an `<expression>` block
inside the If (type=2). The block holds an operator node (type=6, device=100000, `<display>AND</display>`
or `OR`, empty cmdcond) followed by the next condition (type=2). The If's own `cmdcond` is the first
condition; `<expression>` chains the rest. (AND vs OR distinguished by `<display>` — verify against
these captures when building the compiler.)
```xml
<codeitem><device>16</device><type>2</type><display>If NAME is on</display>
  <cmdcond><deviceconditional owneridtype="" owneriditem="-1"><name>LOAD_ON</name></deviceconditional></cmdcond>
  <expression>
    <codeitem><device>100000</device><type>6</type><display>AND</display><cmdcond/><subitems/></codeitem>
    <codeitem><device>20</device><type>2</type><display>If NAME is on</display>
      <cmdcond><deviceconditional ...><name>LOAD_ON</name></deviceconditional></cmdcond><subitems/></codeitem>
  </expression>
  <subitems> ...then... </subitems></codeitem>
```

**While loop** (prog12) — type=3, a `deviceconditional` = the loop condition, body in `<subitems>`:
```xml
<codeitem><device>16</device><type>3</type><display>While NAME Top (Ramp Up) is pressed</display>
  <cmdcond><deviceconditional owneridtype="" owneriditem="-1"><name>BUTTON_PRESSED</name>
    <params><param><name>BUTTON_ID</name><value type="INTEGER"><static>0</static></value></param></params>
  </deviceconditional></cmdcond>
  <subitems> ...loop body... </subitems></codeitem>
```

**Break** (prog13) — type=1 command on device 100000, `command=BREAK`, no params. Runtime behavior is
positional (exits innermost While/If; acts like Stop if bare — see the guide's Break rules):
```xml
<devicecommand><command>BREAK</command></devicecommand>
```

**Stop** (prog14) — type=1 command on device 100000, `command=RETURN` (Stop's internal name):
```xml
<devicecommand><command>RETURN</command></devicecommand>
```

## Key fields summary
- **`owneridtype`**: `""` = plain device command/conditional (owneriditem=-1); `"variable"` = variable op
  (owneriditem = variableid); `"agent"` = agent command (owneriditem = agent/scene instance).
- **param value forms**: device commands use `<value type="INTEGER"><static>V</static></value>`;
  variable ops use inline `<param name="value" type="int">V</param>`.
- **pseudo-devices**: `100000` = programming/control (Else, Delay); `100001` = Variables agent.
- **nesting**: then/else/loop bodies live in the parent codeitem's `<subitems>` (matches the log's
  parent/before-id tree).

## Grammar status: COMPLETE
All core primitives captured and decoded (prog01–14): command, command+param, if, else, and/or
(expression block), while, break, stop, delay, variable define/set/compare, agent command. Nothing
further needs capturing for the codeitem compiler. Remaining programming-side item is the agent/room
*vocabulary* (event/command/conditional names), sourced from a Composer/Director install — separate.

## Design decisions — UX improvements over Composer (storage format is DECOUPLED from the UI)
The codeitem XML is just storage; our authoring UX can differ freely as long as the compiler emits
valid XML. Running list of Composer pain points we intend to fix:

1. **Open-ended / declarative logic.** Director is fundamentally event-anchored (proven above) — no
   event-free if/while. To give users declarative authoring ("while X, maintain Y"; "whenever C
   holds, do A"), the compiler SYNTHESIZES the event hooks: it compiles the rule to handlers on the
   variable's change event + relevant device-state events (or a timer). Reactive/edge-triggered, not
   a literal loop, but equivalent for most cases. THE core value-add over Composer.
2. **Inline compound conditions (no "expression editor" mode).** Composer interrupts the flow with a
   separate expression-editor context to build And/Or — confusing to new programmers. We build
   compound conditions INLINE: an If row has a "+ and/or" affordance that adds a second condition
   slot in place, same view, no mode switch. Also make boolean **precedence explicit** (show
   grouping) rather than an ambiguous flat A-and-B-or-C list. (Verify whether the `<expression>`
   block supports real grouping/nesting or only a flat chain; constrain UI to what compiles.)
3. **Clear Break/Stop semantics.** `BREAK` is positional (exits innermost While/If; = Stop if bare)
   and `Stop`=`RETURN` — confusing. Offer plainly-labeled actions ("exit this loop", "skip rest of
   this If", "stop this script") and/or a live preview of what Break does given its placement,
   compiling to the right BREAK/RETURN codeitem.
