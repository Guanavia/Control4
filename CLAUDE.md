# Control4 Drivers Repo

Monorepo for all Control4 DriverWorks drivers built by Dave Woychek (david@propertyrenewal.llc).

## Repo conventions

- **One subfolder per driver.** All of a driver's source, docs, and research notes live in its folder (e.g. `nv_shield_tv/`, `sonoff_snzb02p/`).
- A `.c4z` file is just a **zip of the driver folder's contents** (files at zip root, not nested in a folder). `build.bat` / `build.ps1` are Windows scripts currently hardcoded to `nv_shield_tv`.
- Standard driver folder layout:
  - `driver.lua` — driver logic
  - `driver.xml` — driver metadata/config (devicedata XML)
  - `www/documentation.rtf` — dealer-facing docs shown in Composer
  - `www/icons/device_sm.gif`, `www/icons/device_lg.gif`, `www/icons/device/*.png`

## Drivers

### nv_shield_tv
NVIDIA Shield TV IP driver. Pre-existing, working. Built artifacts `nv_shield_tv-dmw.c4z` (own build) and `nv_shield_tv-fordev.c4z` at repo root.

### sonoff_snzb02p — CLOSED, no custom driver (research-only folder)
Original goal: get a Sonoff SNZB-02P temperature/humidity/battery sensor into Control4 for
dashboards, programmable threshold notifications, and history over time.

**Outcome (decided 2026-07-07): not building this.** A stock SNZB-02P cannot pair to a
Control4 zigbee mesh at all — see `sonoff_snzb02p/RESEARCH.md` for the full technical
reasoning (Control4's proprietary 0xC25D identify/product-string binding mechanism, which
stock Zigbee 3.0 firmware never speaks; plus C4's Zigbee 3.0 mesh currently only admitting
Control4 Lux lighting). Zigbee2MQTT was also considered as a bridge and ruled impractical for
this use case (see RESEARCH.md's mesh-topology section) in favor of the option below.

**Going with instead: Shelly H&T Gen3 (WiFi, battery) + Chowmain's Shelly Suite driver**
(https://chowmain.software/drivers/control4-shelly-generic — Dave is an authorized Chowmain
dealer). Works because the Shelly is a plain WiFi/IP device; DriverWorks IP drivers face none
of the zigbee gatekeeping. Battery life is worse than zigbee (~18mo vs ~4yr) but acceptable for
this scale. No driver-development work needed for the sensor itself.

**Remaining possible follow-on work** (not started): threshold-notification programming in
Composer, and a history/dashboard layer for long-term trends, once Shelly hardware + Chowmain
license are in place.

### better_composer — OPEN, investigation (feasibility of a modern Composer Pro replacement)

**ARCHITECTURE CLARIFICATION (don't get this wrong):** Composer is ALWAYS a live client of *a*
Director — there is no Composer-only project representation that later gets "applied." Editing in
Composer == editing that Director live (real controller = live changes to the home; "Virtual
Director" = identical, just Director running on a VM instead of hardware). The only discrete "load"
event is **Restore** (pushing a `.c4p` backup into a Director), which is when Director ingests +
completes it (this is what regenerates skeletal state). Our tool lives entirely on the `.c4p`
(backup/restore) side; it never talks to Director. Flow: Director → (backup) `.c4p` → our tool edits
→ `.c4p` → (restore) Director. So "open in Composer" already means "live in Director, fully
instantiated" — no load-then-program step.

**WORKSTATION HANDOFF — DONE (2026-07-13).** Found and copied Composer's built-in driver defs into
`better_composer/research/director_drivers/` (295 `.c4i` + 12 `.c4z`, ~15MB, committed to git — not
gitignored, small enough). Actual location on this workstation: `C:\Program Files (x86)\Control4\
Shared\4.1.0\Drivers\Virtual\` (version-numbered per installed Director release; matched to the live
project's director 4.1.0.743847 — `3.4.3`/`4.0.0` sibling folders also exist for older projects).
`roomdevice.c4i` and all 9 target proxy drivers (`tv`/`light_v2`/`keypad_proxy`/`media_player`/
`avswitch`/`fan`/`thermostatV2`/`controller`/`uidevice`) confirmed present as real XML `.c4i` and
copied — **closes the room/proxy half of the vocab gap.**

**AGENT VOCAB GAP — NOT closed, and the original handoff's assumption was wrong.**
`control4_agent_*.c4i` do not exist anywhere on disk in any form — there is no XML source file to
copy. Agents ship ONLY as compiled `control4_agent_*.c4w` (PE32 native DLLs, ~5MB each) in
`Shared\4.1.0\Director\Drivers\`. Confirmed via three checks: (1) not present under any version's
`Drivers\Virtual\` folder; (2) not referenced anywhere in Composer's own device-catalog XML
(`%APPDATA%\Control4\Composer\devices_41.xml`, the source for the "Add Device" tree) — agents are
apparently never added via that generic flow; (3) byte-level scan of `control4_agent_adv_lighting.c4w`
for embedded XML markers (`<commands>`, `<events>`, `<proxy>`) found nothing — no plaintext schema
embedded in the binary. **Conclusion: agent command/event vocab isn't a file-retrieval problem, it's
either compiled into native code (would need PE resource extraction / disassembly to confirm even
that) or generated dynamically by Director at runtime.** Decided path forward (2026-07-13, user's
call): don't chase binary extraction — treat agent vocab like the scene/keypad state model was
solved, i.e. reverse-engineer via `c4proj diff` captures of the Agents view in Composer against a
virtual director, same method as the capture campaigns already documented below. Not started.

**AGENT SCHEMA UNDERSTOOD + GAP RE-SCOPED SMALLER (2026-07-13), via snap-one's public GitHub
(`github.com/snap-one` — 18 public repos, all DriverWorks SDK docs/templates/samples).**
`docs-driverworks-fundamentals` has a dedicated "DriverWorks Agents" chapter (OS 3.1.3+): an agent
is just a normal self-proxy/combo driver `.c4z` with **`<agent>true</agent>`** added to
`<devicedata>` — same `<commands>`/`<events>`/`<conditionals>`/`<properties>` schema as any other
driver, just a singleton hidden from the room hierarchy. So `c4proj/drivers.py`'s existing parser
needs zero changes to handle agents — it's a vocab-sourcing problem only, not a schema/format one.
None of our 27 target legacy `control4_agent_*` names are in the public Solr catalog (they're
OS-bundled, not third-party-distributed), **but 9 newer first-party Control4 agents ARE** (search
`q=agent`): Routines, Quick Actions, Timeline, Recently Played Manager, MultiDisplay Manager, OvrC
Sync, Vibrant Smart Bulb, OVRC WiFi QRCode. Downloaded + inspected 6 of them
(`research/agent_probe/`, via `c4proj.repo.search()`/`.download()` — first real use of the repo
module end-to-end). **Finding: 5 of 6 have completely empty `<commands/>` and `<events/>`**
(Routines, Timeline, Quick Actions, Recently Played, OvrC Sync) — these manage everything through
a self-contained Composer UI tab + internal state, confirming the "own sub-model, state-blob-based"
pattern already seen for keypad/scene config, NOT the classic event/command programming model.
Only **MultiDisplay Manager** (an older 2023-era agent) has real populated `<commands>` (4, incl.
`CUSTOM_SELECT:GetMultiDisplaysForProgramming` dynamic-dropdown params) — and even it has **no
`<events>`**.
**Revised plan:** the "39 agents in the project" concern is likely overblown — most probably expose
NOTHING to the classic Programming view (no capture needed, out of scope by design) and are already
covered by the state-blob approach. Before running any manual capture campaign, do a **fast triage
first**: in Composer's Programming view device picker, for each of the ~12 agents actually present
in Russell House, just check whether it lists ANY events/commands at all (a few minutes, no program-
building). That tells us the *real* size of the remaining gap — likely 1-4 agents, not 27. Full
capture campaign (prog01-14-style) only needed for whichever agents survive that triage.

**TRIAGE DONE BY USER (2026-07-13) — prediction above was WRONG, gap is much bigger than 1-4.**
User manually checked every agent in the Russell House virtual-director project's Programming tab.
**Only 10 of the ~39 agents have NO programmable events**: ChowMain agent, Data Analytics, Halo
Remote Hub, History, Navigation, Programming Control, Remote Access, System Diagnostics, UI
Configuration, Update Manager. **Every other agent (the large majority) DOES expose real events** —
opposite of the public-catalog sample (Routines/Timeline/etc., all empty), because those newer
(2024-2026) agents are a different generation from the classic OS-bundled ones actually used in
real projects. **Conclusion: the classic legacy agents are the ones that matter, and most of them
need real vocab capture.** This is a much larger campaign than hoped — not started.

**DLL REVERSE-ENGINEERING ATTEMPT (2026-07-13) — partial success, not a full solution.** User asked
whether the compiled `control4_agent_*.c4w` binaries (native PE DLLs, confirmed via
`[System.Reflection.AssemblyName]::GetAssemblyName()` throwing "not a valid assembly") can be
decoded. Findings:
- PE resource enumeration (Win32 `EnumResourceTypes`/`EnumResourceNames` via P/Invoke, read-only,
  `LOAD_LIBRARY_AS_DATAFILE` so no code executes) found only resource type `#24` (RT_MANIFEST, the
  standard app manifest) — **no embedded data/string-table resource** to extract.
- Raw string extraction (ASCII + UTF-16LE scan of the full byte content) works and the binaries are
  **not stripped** — real C++ symbol names survive, e.g. `scheduler_agent::calculate_events_to_fire_`,
  `scheduler_agent::TestCondition`, `scheduler_agent::ExecuteCommand`, plus internal literals
  (`Sunrise:`, `Sunset:`, `GET_SUNRISE_SUNSET`, `start_weekday`) and even a build path
  (`C:\j\workspace\4.1.0-virtual-director@2\control4\agents\scheduler\c4w\scheduler_agent.cpp`) —
  confirms Control4's internal build layout (`control4/agents/<name>/`) and that scheduler entries
  are parsed as `pugi::xml_node` internally. **Useful for confirming implementation behavior, but
  did NOT surface a clean list of user-facing event/command display names** — those are presumably
  sourced from a separate localization/resource bundle (not found by filename search in the install
  tree) or constructed at a point string-scanning can't cleanly recover.
- Separately: `ComposerPro.exe` and its `Control4.Designer.*.dll` (incl. `Control4.Designer.Agents.dll`,
  `Control4.Designer.Programming.dll`) **are managed .NET** (confirmed via
  `ReflectionOnlyLoadFrom`) — much easier to inspect — but their embedded resources are only
  compiled WinForms `.resources` (control layout/icons/generic label text), **not per-agent
  vocabulary**. This confirms Composer queries the live Director at runtime (via c4soap on 5021) for
  each device/agent's actual command/event list rather than having it baked into the client — so
  there is no static client-side file that shortcuts this.
- **Verdict: binary extraction is not a practical shortcut.** Getting a clean vocab list would
  require full disassembly (Ghidra/IDA-level effort) per agent, high effort for uncertain yield.
  **The `c4proj diff` capture-campaign method (proven for scenes/keypads/programming grammar)
  remains the only reliable path** for the ~29 legacy agents that do have events.

**SCOPE EXPANDED (2026-07-13, user's call): agent CONFIGURATION is in scope, not just agent
programming events.** Configuring agents (not just wiring their events into programming) is used
very frequently in real system builds and must be supported, even if it lands after the initial
pass. **FUNCTIONALITY checklist only — explicitly NOT a UI/layout mandate** (user was emphatic:
Composer's UI/UX is "awful" and a core reason this project exists at all; the replacement will
**completely overhaul** the UX once UI design starts — we haven't gotten there yet, still on the
backend). The following are the *capabilities* that must exist somewhere in the finished tool,
regardless of how they end up laid out:
- System Design, Connections, Media, Agents, Programming — all five functional areas, not just
  Connections+Programming as previously implied.
- Properties, Summary, List View, and sub-properties — full property-editing surface for whatever's
  selected, not just top-level fields.
- Items and Drivers — the device/room tree + driver catalog/search.
This reframes the backend-scope gaps already documented above (device instance properties/`<state>`
modeling, agent config models) as core v1 surface, not stretch goals — the tool needs functional
parity across all of the above, agents included, before it can replace Composer for daily use. UI
design is a separate, later phase.

**LIVE-DIRECTOR ACCESS INVESTIGATION (2026-07-13) — PAUSED, not abandoned. Real progress, no
breakthrough yet.** Prompted by the agent-vocab dead end: since this workstation has a fully
licensed, authorized Composer Pro install (dealer account `S508194`, `david@propertyrenewal.llc`),
explored whether our tool could use that same legitimate access to query (or eventually author
against) a live Director directly via the `c4soap` protocol on port 5021, instead of/in addition to
the file-based `.c4p` round-trip. **Explicit scope boundary set by user:** using the machine's own
already-authorized access is fine; extracting secrets from Control4's compiled software to defeat
its own protection is a separate, greyer line — user is comfortable crossing THAT line too (their
hardware, their license), but decrypting/using the actual dealer *account password*
(`dealeraccount.xml`, DPAPI-encrypted) is explicitly OFF LIMITS for now — if truly needed later, the
user will type credentials fresh rather than have the stored copy touched.
- **Confirmed live and reachable:** port 5021 is listening on this machine right now (virtual
  director running). `composer.p12` (`%APPDATA%\Control4\Composer\composer.p12`) is the mutual-TLS
  client cert Composer uses — NOT in the Windows cert store (CurrentUser\My / LocalMachine\My
  checked, absent), exists only as a standalone PKCS12 file. Common/default passwords (blank,
  `control4`, `composer`, `changeit`) all failed to unlock it.
- **Static password extraction attempted, dead-ended.** Managed DLLs (`Control4.Client.dll`,
  `Control4.Broker.dll`, `Control4.Broker-RT.dll`, `Control4.Client-RT.dll`, `ComposerPro-RT.dll` —
  all confirmed managed .NET via PE CLR-header parsing) contain **no** string literal referencing
  `.p12`/`.pfx`/`composer.p12` anywhere (checked via raw UTF-16LE byte search across all 92 DLLs in
  Composer/Pro). The native `Control4BrokerRT.dll`/`Control4ClientRT.dll` (different from the
  managed `Control4.Broker-RT.dll` — extracted at runtime to per-session folders under
  `%TEMP%\<guid>\`) had apparent `p12`/`pfx` string hits that turned out to be false positives
  (substrings inside unrelated longer strings, e.g. `p12v`, `pfxta`). **Conclusion: the password is
  almost certainly derived at runtime** (e.g. from machine ID + account hash via a KDF), not a
  static literal — which static string analysis fundamentally cannot recover. Would need dynamic
  analysis (debugger attach to the running Composer process, catching the password at the moment it
  unlocks the file) to go further this way — not attempted, higher effort/more invasive, paused per
  user call.
- **Pivoted to look for a legitimate cert-(re)enrollment flow instead of extracting the existing
  cert's password** — cleaner technically and ethically (would mean getting our OWN freshly-issued
  cert, not cracking Composer's). Found `dealeraccount.xml` (`%APPDATA%\Control4\`) — dealer login
  (username, account `S508194`, DPAPI-encrypted password — **not decrypted, off limits per user**)
  — and `remoteaccounts.json` confirming a real cloud API host: `apis.control4.com/account/v2/rest/
  customers/<id>`. Composer logs (`%APPDATA%\Control4\Logs\Composer-*.log`) from Jul 9 (the day
  `composer.p12`'s mtime last changed) show `Control4.ComposerPro.RegistrationForm` — "ComposerPro
  is registering the license" — but this reads as **Composer's own software-license activation**,
  a different mechanism from the Director mTLS client cert, not confirmed as the same flow. No
  SSL/TLS/X509/cert/5021-specific logging exists at INFO level anywhere in Composer's logs — that
  layer is silent unless DEBUG logging is enabled (not explored).
- **Verdict: real progress (confirmed live port, confirmed cert isn't in the cert store, ruled out
  static extraction, found the account/API surface, found the registration flow class name), but no
  working path to either read the cert password or complete a clean re-enrollment yet.** Paused
  here per user call (2026-07-13) rather than escalating to dynamic analysis or live credentials —
  explicitly NOT abandoned, revisit with a fresh time budget. If resumed, next concrete steps in
  order of promise: (1) try enabling Composer's DEBUG-level logging and repeat a fresh
  registration/connection cycle to see if the TLS/cert layer becomes visible; (2) if that's a dead
  end too, either dynamic analysis (debugger attach) or the user typing fresh credentials into a
  purpose-built enrollment-flow test are the remaining options — both bigger commitments to be
  scoped with the user first, not started unilaterally.

**CORRECTION (2026-07-13, user's call) on how the live-Director thread relates to the core goal:**
reverse-engineering the read/query side (whichever method — captures, disassembly, live query) is
NOT "most of the way to live authoring." It's the thing that unblocks the ALREADY-WORKING `.c4p`
authoring engine (`authoring.py`'s `add_device`/`clone_device`, proven to load correctly in a
virtual director) to build a COMPLETE project with full programming + agent configuration, which
then round-trips through Composer to Director exactly as already validated. That's the actual
remaining lift, and vocab-completeness is what closes it. Live Director access (bypassing the
Composer round-trip entirely) is a separate, additional, later feature, not a blocker for
"author a complete project."

**GHIDRA DISASSEMBLY — BREAKTHROUGH (2026-07-13). Automated agent-vocab extraction WORKS.**
Installed **Ghidra 12.1.2** (`github.com/NationalSecurityAgency/ghidra` releases, no winget
package) + **OpenJDK 21** (`winget install Microsoft.OpenJDK.21`) — Ghidra 12.x dropped built-in
Jython, so scripts must be **Java**, not Python, for headless use (no PyGhidra/jep setup needed).
**Gotcha:** Ghidra's OSGi script loader only resolves scripts placed in a *registered* script
directory — `-scriptPath <arbitrary dir>` alone silently fails ("Failed to get OSGi bundle") even
for trivial scripts. Fix: drop scripts in the default `%USERPROFILE%\ghidra_scripts\` and omit
`-scriptPath` entirely. Real compile errors (as opposed to this OSGi resolution failure) DO show up
clearly in the headless log, so iterate there.
- **Method that worked, against `control4_agent_scheduler.c4w`:** don't search for named functions
  (release binaries have no real symbol table — the `scheduler_agent::ExecuteCommand`-style strings
  seen in the initial PowerShell string scan are RTTI/exception-metadata strings, not Ghidra
  function symbols). Instead: **decompile every function in the binary** (10,121 for this one
  binary; full pass took a few minutes), and for each, **regex-extract every `PTR_s_<NAME>_<addr>`
  token** from the decompiled C output — this is Ghidra's own auto-generated label for any string
  data reference, so it requires zero manual xref-tracing. Rank functions by token count; functions
  with many are command/event/conditional dispatchers (sequential string-comparison chains); their
  tokens ARE the vocabulary. This works on stripped/unnamed binaries and needs no per-agent tuning.
  Script: `ExtractVocab.java` (also `FindDispatch.java` for the earlier, more manual xref-based
  approach, superseded by this one; both in `%USERPROFILE%\ghidra_scripts\` on this workstation —
  **not yet copied into the repo**, next-session TODO).
- **Full Scheduler agent vocab extracted, clean, structured, zero manual work after the script ran:**
  - Commands (w/ params): `ADD_ENTRY`(`ENTRY_XML`), `MODIFY_ENTRY`, `DELETE_ENTRY`(`EVENT_ID`),
    `DELETE_ENTRIES_BY_CREATOR`(`CREATOR_ID`), `GET_ALL_ENTRIES`, `GET_ENTRIES_BY_CREATOR`
    (`CREATOR_ID`), `GET_ENTRY`(`EVENT_ID`), `GET_ENTRY_OCCURRENCES`(`EVENT_ID`,`FROM_YEAR`,
    `FROM_MONTH`,`FROM_DAY`,`TO_YEAR`,`TO_MONTH`,`TO_DAY`), `GET_SUNRISE_SUNSET`(`month`,`timezone`
    → `sunrise`,`sunset`).
  - Conditionals: `IF_TIME`, `IF_TODAY`, `IF_DATE`, `IF_MONTH`, `IF_YEAR`, `IF_LEAP` (wrapped in a
    `CONDITIONAL_XML` param), each with its own comparator sub-vocab (e.g. IF_DATE:
    `date_between`/`date_from`/`date_to`; IF_TODAY: `day_between`/`day_names`/etc; similarly for
    month/year).
  - Full entry/config schema (the scheduler entry's property model): `eventid`, `description`,
    `category`, `enabled`, `locked`, `creatorid`, `creatorstate`, `hidden`, `user_hidden`, `start`,
    `offset`, `offset_minutes`, `start_date/day/month/year/period/weekday`, `randomize`,
    `next_occurrence`, `repeat`, `frequency`, `daymask`, `end_date/day/month/year`, `timezone`.
  - This is the ENTIRE programmable + configuration surface for one agent, fully automated, no
    per-agent manual reverse engineering. Matches the shape `c4proj/drivers.py` already models for
    regular `.c4i` drivers (commands/conditions/events + property schema) — next step is normalizing
    this extraction format to feed the same `Driver`/`ResolvedApi` structures.
- **GENERALIZATION TEST RESULT (2026-07-13): technique does NOT universally generalize as-is —
  TWO agent architecture families exist.** Ran the identical unmodified `ExtractVocab.java` against
  Notification, Advanced Lighting, and Custom Buttons: **all 3 came back with only OpenSSL/protobuf
  noise, zero real command vocab** (vs. Scheduler's complete clean extraction). Root cause found by
  inspecting the shared `CmdDispatcher::ExecuteCmd` function (statically linked into every agent,
  `C4LibDriverBases\CmdDispatcher.cpp`): it does a **map lookup by command-name string** (`std::map`-
  style find, dispatching through function-pointer slots at offsets +0x20/+0x40/+0x60/+0x80 in the
  found entry — supports multiple handler signatures), NOT sequential string comparison. Command
  names are passed as arguments to some `Register`-style call **at agent construction/init time**,
  scattered across the agent's own code — not concentrated in one big comparison chain, so they
  don't trip the "many `PTR_s_` tokens in one function" heuristic. **Two families:**
  - **"Legacy" style (Scheduler):** agent overrides `ExecuteCommand`/`TestCondition` itself with
    hand-written sequential string comparisons — `ExtractVocab.java` as-is works great.
  - **"Modern" style (Notification, Advanced Lighting, Custom Buttons, likely most others):** agent
    relies entirely on the generic `CmdDispatcher`/`CondDispatcher` map-based registration — no
    per-agent `ExecuteCommand` override, no per-agent `__PRETTY_FUNCTION__`-style debug strings at
    all (confirmed: raw string search for `*_agent::`/`*Agent::` patterns in
    `control4_agent_notification.c4w` found ZERO matches, unlike scheduler's rich
    `scheduler_agent::*` strings) — much harder to anchor on with simple string search; needs actual
    control-flow tracing (find the registration function via what calls the map's insert operation,
    then extract string-literal arguments at each call site) rather than a decompile-and-regex pass.
  - **Not yet attempted:** locating the registration function and its call sites for a "modern"-style
    agent. This is the concrete next step if/when this thread resumes — the map-based architecture
    is actually GOOD news for generalization once cracked (one shared function to anchor on across
    ~25+ agents, versus each legacy agent needing its own bespoke comparison-chain scan), it's just a
    different, not-yet-solved technique.
  - **Honest bottom line for this session:** proved the disassembly approach is viable and can be
    FULLY automated (Scheduler, zero manual work) — but "automate agent details generically" is only
    solved for one of two architecture families so far. Real, demonstrable progress; not a finished
    pipeline.
- Scripts copied into the repo: `better_composer/research/agent_vocab/ghidra_scripts/`
  (`ExtractVocab.java`, `TraceCreation.java`, `TraceCallees.java`, `FindDispatch.java`,
  `DumpCapsStrings.java`). Extracted results: `better_composer/research/agent_vocab/*.json` +
  `README.md` (methodology). Ghidra itself (546MB) is NOT persisted — still only in this session's
  scratchpad; reinstall next session via `winget install Microsoft.OpenJDK.21` +
  download from `github.com/NationalSecurityAgency/ghidra` releases (see README for the OSGi
  scripts-directory gotcha).

**MODERN-STYLE REGISTRATION PATTERN — CRACKED (2026-07-13, autonomous continuation, user stepped
away).** Triaged all 27 `control4_agent_*.c4w`: only **6 are "legacy" style** (own class name in a
TestCondition/ExecuteCommand debug string: hospitality, lightingscenes, remoteaccess, scheduler,
screensaver, wakeup_goodnight) — but running `ExtractVocab.java` on all 6 showed **only Scheduler
actually yields real vocab**; the other 5 also turn out to rely on the generic map-based
registration despite having their own class name string somewhere. So in practice ~26 of 27 need
the "modern" technique; only Scheduler is fully solved by the simple approach.
- **Found the universal factory pattern:** every agent `.c4w` exports exactly two PE symbols,
  `GetAgentName` and `GetCreationFunc` (confirmed via a raw PE export-table parser,
  `research/agent_vocab/pe_exports.py`). `GetCreationFunc` returns a
  pointer to the real factory function; Ghidra imports these exports as properly-named functions
  (unlike the thousands of anonymous `FUN_xxxx`), so they're a reliable, symbol-name-based entry
  point into ANY agent regardless of how obfuscated/stripped the rest of the binary is.
  `TraceCreation.java` finds+decompiles these two exports; `TraceCallees.java` (script args via
  `getScriptArgs()`, NOT `askString` — that needs a GUI and silently breaks headless) then
  recursively decompiles a function's callees up to depth 3, which is how the chain
  `GetCreationFunc → factory → subclass ctor → C4BaseAgentDriver ctor → registration call` was
  found by hand for Notification.
- **Confirmed registration call shape:** `FUN_1005e160("COMMAND_NAME", len)` builds a std::string,
  then a second call (`FUN_1009c790` in this binary — address differs per agent since statically
  linked) commits `{name, handler_fn_ptr}` into the dispatcher. This IS the CmdDispatcher
  registration Composer would see. Found and validated one real base-class registration this way:
  `GET_LAST_ACTION`.
- **Key fix that unlocked real signal — Ghidra represents the SAME kind of string reference two
  different ways** depending on how the compiler emitted it: either a named `PTR_s_<NAME>_<addr>`
  pointer (my original regex) OR an inline `"LITERAL"` string directly in the decompiled C (missed
  entirely before). `GET_LAST_ACTION` itself only appeared in the inline-literal form — the
  original script would never have found it. Fixed `ExtractVocab.java` to match both forms, added
  a small stoplist (OpenSSL/XML/crypto constants that coincidentally match the `ALL_CAPS` shape:
  `SOAP_ENV`, `AES_128_WRAP`, `ENCRYPTED_PRIVATE_KEY`, etc.), and lowered the per-function
  threshold from 4 tokens to 1 (registration is often one small function per command, not one big
  comparison chain) — re-running against Notification went from 0 real tokens → 73, including
  confirmed universal base-agent commands.
- **UNIVERSAL BASE-AGENT API FOUND (`_base_agent_api.json`) — applies to all ~39 agents for free:**
  `GET_LAST_ACTION`, `GET_CAPABILITIES`, `GET_COMMAND_INFO` (commands), `CAPABILITIES_CHANGED`
  (event), plus shared comparator operators `GREATER_THAN`/`GREATER_THAN_OR_EQUAL`/`LESS_THAN`/
  `LESS_THAN_OR_EQUAL`/`NOT_EQUAL` used across conditionals generically.
- **PROMISING UNTESTED LEAD:** if `GET_CAPABILITIES`/`GET_COMMAND_INFO` can be invoked on a live
  agent instance and their result captured (e.g. author a programming rule that calls
  `GET_COMMAND_INFO` and writes the result to a Variable, load via the ALREADY-PROVEN `.c4p` →
  Composer → virtual-director pipeline, trigger it, read the result back from a saved state or
  Director's own logs) — that could give complete, runtime-authoritative vocab for every agent
  **without** the live-Director access problem that was separately paused. This does NOT require
  resuming the live-c4soap-query thread — it uses the existing file-based authoring loop. Not
  attempted yet; strong candidate for next session.
- **UPDATE — the fix generalizes better than the Notification test alone suggested.** Batch re-run
  (autonomous, user stepped away) across the remaining agents found REAL per-agent vocab well
  beyond the shared base API: **Announcements** → `SHOW_POPUP`, `HIDE_POPUP`, `PLAY_ANNOUNCEMENT`;
  **AudioScenes** → rich scene/volume/room-linking vocab (`SCENE_ID`, `SCENE_XML`,
  `SET_SCENE_DEFAULT_VOLUME_LEVEL`, `IS_ACTIVATED`/`IS_DEACTIVATED`, `CURRENT_SCENE_VOLUME`,
  `SET_ROOM_LINKS`, `MUTE_LINKED`/`VOLUME_LINKED`/`SELECTIONS_LINKED`/`ROOMOFF_LINKED`,
  `ACTIVATE_EVENT_OFFSET`/`CHANGE_EVENT_OFFSET`/`DEACTIVATE_EVENT_OFFSET`). So Notification was
  apparently more resistant than most, not representative — the dual-pattern + shape-filter +
  stoplist fix is a genuinely useful general-purpose extractor, just not a 100%-complete one per
  agent (some commands still won't surface, e.g. still no clean "send notification"-style command
  found for Notification itself).
- **BATCH COMPLETE (2026-07-13).** All 18 batched agents finished; combined with the 9 processed
  earlier, **all 27 `control4_agent_*` binaries have been run through the extractor.** Final tally
  (`summarize_vocab.py`, copied into `research/agent_vocab/`, subtracts known shared-noise tokens
  to rank agents by real signal): **17 of 27 yielded real, non-noise vocab** (some rich — Media
  Sessions 54 real tokens, Video Intercom 36, AudioScenes 20 — some sparse but genuine — Macros,
  Navigation, UI Configuration, Services, Hospitality WMB, Timer); **2 confirmed null results**
  (Access, Light Properties — base API only, same dead-end as Notification, needs manual
  `GetCreationFunc`/`TraceCallees.java` tracing to progress further); **the remaining ~8 have raw
  uncurated signal** (Backup, Diagnostics, DriverUpdate, EmailNotification, History, Identity —
  see `*.raw_tokens.json`). Fully curated to clean per-agent JSON (commands/conditionals/params,
  like Scheduler got): Announcements, Macros, Navigation, UIConfiguration, Services,
  HospitalityWMB, Timer, MediaSessions, VideoIntercom, AudioScenes, Access, LightProperties — 12
  files. Stoplist grew substantially mid-batch (media-type constants, OpenSSL/logging noise, TLS
  1.3 handshake secret labels, `PROXY_NAME`/`DIR_ADD`/`DIR_LOAD`/`LIST_ADD` all confirmed generic
  across 3+ agents) — a fresh re-run of any early-processed agent would come back cleaner than
  what's currently saved; not worth re-running given the returns already captured by hand.
  Scripts: `parse_vocab_logs.py` + `summarize_vocab.py`, both now in `research/agent_vocab/`.
  **Bottom line: the agent-vocab gap that blocked full programming for ~39 agents is now
  substantially (not completely) closed** — most agents have actionable command vocab, a
  documented and reproducible extraction method exists for adding more later, and the two
  remaining null results are a known, bounded problem (not a mystery).

**PROGRAMMING COMPILER BUILT — `c4proj/programming.py` (2026-07-13, autonomous continuation).**
`PROGRAMMING.md`'s grammar was fully decoded but never implemented — this closes that gap. Builds
`<event>`/`<codeitem>` trees exactly per spec and appends them to a `ProjectModel`'s `event_mgr`.
Primitives implemented and tested end-to-end (built real rules against the `prog14` capture
project, `.c4p`-repackaged, integrity-verified with `c4proj`'s own checker — all passed):
- `command()` / `agent_command()` — device and agent commands, with typed params
  (`<value type=T><static>`).
- `set_variable()` — `owneridtype="variable"`, inline int param, auto-generates the
  `#!"..."` display template.
- `delay()`, `break_()`, `stop()` — pseudo-device-100000 programming primitives.
- `if_()` / `else_` — type=2/4, else as a SIBLING codeitem (not nested), `extra_conditions` param
  chains And/Or via an `<expression>` block (type=6 operator node + next condition, repeatable).
- `while_()` — type=3, deviceconditional + body in subitems.
- Codeitem ids are sequential **in document order, parent before children** (root=0), matching
  what a human authoring top-down in Composer would produce — fixed from an initial
  children-before-parent bug caught by testing.
- **Two real bugs found and fixed via testing, not just spec-reading:** (1) the And/Or operator
  node was hardcoding `id="0"`, colliding with the event's root codeitem id — now takes an id from
  the same ambient counter as everything else; (2) a chained extra-condition was reusing the OUTER
  if's display text instead of its own — fixed by taking a per-condition display string.
- **Not yet built:** the "declarative → event-hooks" synthesis layer (CLAUDE.md's stated
  core-value-add UX design, e.g. "while X, maintain Y" compiling to reactive event handlers) — this
  module is the low-level codeitem-tree primitive layer that synthesis would compile DOWN to, not
  the synthesis itself.
- Test artifact: `test projects/programming-compiler-smoketest.c4p` (variable set + while + delay +
  break, built from the `prog14` capture base). `agent_command()` separately validated (toggle-scene
  against the real Advanced Lighting agent, matches PROGRAMMING.md's prog09 example exactly).
- **CLI wired up:** `python -m c4proj add-rule <file.c4p> <trigger_dev> <trigger_event> <target_dev>
  <command> -o out.c4p [--yes]` — demo single-command rule builder (same identity-card-confirm
  pattern as `rename`). End-to-end verified: built a rule this way, then read it back with the
  EXISTING `c4proj rules` command and it rendered correctly (`WHEN SvrRm - Light: When SvrRm -
  Light turns on -> ON on Lux Universal Dimmer") — proves the new write side and the pre-existing
  read side agree on the wire format, not just that the compiler's output looks plausible in
  isolation.

**Python installed (2026-07-13).** This workstation had no real Python (only the Microsoft Store
`python`/`python3` alias stubs) — installed **Python 3.12.10** via `winget install Python.Python.3.12`.
`c4proj` confirmed working: `python -m c4proj info "research/Russell House.c4p"` parses the live
417-device/version-133 project correctly. VS Code's Python extension pack (`ms-python.python`,
`pylance`, `debugpy`, `python-envs`) was already present from a prior setup — it only provides
editor tooling, not an interpreter, which is why this was still needed. Note: a terminal session
open *before* the install won't see the new PATH entry (`%LOCALAPPDATA%\Programs\Python\Python312\`)
until restarted — open a fresh terminal / restart VS Code if `python` still resolves to the Store
stub.

Goal: determine whether a modern, streamlined replacement UI for Composer Pro is buildable.
Composer is just a client of Director; the open question was whether Director exposes a
project-*authoring* API (add device, bindings, programming) beyond the control/state surface
pyControl4 wraps. Full detail: `better_composer/FINDINGS.md`.

Key findings so far (2026-07-11):
- **Two Director interfaces.** (1) Modern REST + WebSocket (`/v1`, bearer token) = control/state
  only — what pyControl4/HA use; **no authoring**. (2) Legacy `c4soap` on port **5021 (SSL)**,
  gated by a **mutual-TLS client cert** (`CN: Composer_<login>_<machine>`) = the **full authoring
  surface** Composer uses. Controller = `core5-000fff9fc470` @ 192.168.1.123.
- **Write path = "PIP" (Project Info Packet).** Each Composer commit logs as `PIP received from
  remote client` → `Project Info Updated: project version: N`. Capturing one decrypted PIP is the
  highest-value artifact.
- **Logs give the data model for free.** `programming_change.log` (CodeItems: CIT_COMMAND/
  CONDITION/OPERATOR/ELSE with `<devicecommand>`/`<deviceconditional>` payloads, tree via
  parent/before ids) and `project_change.log` (Binding Added/Deleted, Bound Consumer add/remove,
  device Add, Name Change, version bumps) are a detailed audit trail — enough to reconstruct what
  each op *means*, but they are OUTPUT, not the request wire format.
- **Gate to building the authoring half:** need either a *decrypted* capture of a Composer
  authoring request on 5021 (mutual-TLS MITM — viable since we own both ends: Composer runs in a
  VMware Fusion Windows VM NAT'd through this Mac), OR confirmation we can edit the on-disk project
  + trigger a Director reload. Reading is largely solved; writing is the unsolved blocker.

**Capture done (2026-07-11) — strategy pivoted to project.db:**
- Recon capture during a live Composer edit confirmed Composer↔Director is **mutual TLS on 5021
  (authoring), 5810, and 443**, all ECDHE (no passive decrypt). Server cert **chains to a real
  "Control4 Corporation CA"**, so a forged-cert mitmproxy is rejected — MITM would need the *real*
  keys extracted from endpoints (controller `.p12`/`certs`, Composer client cert). **Deprioritized.**
- **Key discovery:** the project is a **SQLite DB** — `/opt/control4/var/director/project.db`
  (~348 KB; devices, bindings, programming), plus `system.db`/`state.db`/`drivers.db`/`identity.db`.
  Director keeps them open rw; `project.db` mtime tracks each commit. The log data-model (CodeItems,
  bindings) is almost certainly these tables.
- **Revised plan:** read side is basically solved (read `project.db` directly). Write side is
  tractable via offline-edit + Director reload (validate reload/locking semantics; do NOT write the
  live DB blindly). Cracking the PIP/c4soap wire protocol is no longer the critical path.
- **FEASIBILITY CONFIRMED — BUILDABLE.** Analyzed the local Composer project
  `better_composer/research/Russell House.c4p` (a zip of: **`project.xml`** = the entire authorable
  project; `drivers/` = the 38 `.c4z` + 22 `.c4i` referenced drivers; `mm.db`/`identity.db`;
  `meta/`). Composer saves the project as XML; the controller runtime is the SQLite equivalent.
- `project.xml` (root `<currentstate>`) sections: `properties`, `systemitems` (nested device/room
  tree), `bindings` (`boundbinding`→`boundconsumers/bound` with `boundclass`), `networkbindings`,
  `variables`, `event_mgr` (41 `event`→`codeitem` = programming; `codeitem/cmdcond` holds
  `devicecommand`/`deviceconditional`), `plugins`. **Maps 1:1 to the audit-log vocabulary.**
- **Read side solved** (parse project.xml + driver metadata). **Write side tractable** (edit
  project.xml, repackage .c4p); only open question is the **apply/load mechanism** — prefer
  round-tripping a `.c4p` through Composer's load, else controller `project.db` replace + reload.
- **Integrity = plain MD5, not a signature.** `meta/manifest.json` records md5+size per file
  (verified: project.xml md5 matches raw bytes). So edit project.xml → recompute md5/size → rezip.
  Restore writes `project.xml`→`.../project.xml.imported` and Director imports it into project.db.
- **SCAFFOLD BUILT & VERIFIED — `better_composer/c4proj/`** (Python, stdlib only). Reads a .c4p,
  verifies integrity, parses project.xml into a navigable model (devices tree, bindings,
  programming, variables), edits it, and repackages a valid self-consistent .c4p (manifest md5
  auto-refreshed). CLI: `python3 -m c4proj {info,tree,bindings,program,roundtrip,identify,rename}`.
  Every editing command shows a **version-confirmation card** (project/version/director/backup-date/
  counts) and asks "is this the current/desired project version?" before writing (`--yes` bypasses)
  — added after a stale 2025 (director 4.0.0) backup was nearly edited instead of the live 4.1.0.
- Verified on the **current** project: director **4.1.0.743847**, project **version 133**, **417
  devices**, 330 bindings, 98 programming events; parses a 125 MB archive in ~0.3s. Parser is
  version-tolerant (also handled the older 4.0.0 file).
- **APPLY PATH VALIDATED (Stage 1 done):** Composer opened a c4proj-generated `.c4p` against a
  **virtual director** — it parses AND imports. So the round-trip works end-to-end. The virtual
  director is our safe test loop. **Testing progression: virtual director → spare Core Lite
  controller → live home.** (Never test on production until proven on real spare hardware.)
- Current test artifact: `better_composer/test projects/Russell House v133 [c4proj-test].c4p`.
  **Convention: all generated/test .c4p files go in `better_composer/test projects/`** (gitignored;
  keep only current-version artifacts). MITM of the live protocol is **not** the path.
- **DRIVER-METADATA READER BUILT — `c4proj/drivers.py`.** A device driver declares
  `<proxy>NAME</proxy>`; the proxy driver (`light_v2.c4i` etc., bundled in `drivers/`) declares the
  real `<commands>`/`<conditions>`/`<events>`. `DriverLibrary.resolve(c4i)` walks device→proxy and
  returns the effective API; command params are inferred from UPPERCASE placeholders in the
  description. CLI: `c4proj drivers <c4p>`, `c4proj device <c4p> <id>`. NOTE: a device's driver is
  the `<c4i>` child of `<item>` (sibling of `<itemdata>`), not under itemdata (model.py fixed).
- Coverage (current project, 417 devices): **186 programmable devices resolve** (commands+events);
  171 empty (rooms/containers/agents w/o proxy); 51 driver files not bundled = **built-in agents
  (`control4_agent_*.c4i`) + `roomdevice.c4i` (×28)**, which live in Director/Composer, not the
  archive. **Gap:** programming against agents/rooms needs their command defs from Director or the
  online driver DB.
- **Online driver DB (Solr): https://drivers.control4.com/solr/drivers/browse** — live faceted
  catalog, **24,523 drivers** (facets: manufacturer, device type, control method IP/IR/Serial/
  Relay/ZigBee/Z-Wave, certification), each record has a **download link** to its `.c4z`/`.c4i`.
  `/browse` (Velocity HTML) works; `/select?q=` returns 404 (locked down — revisit query params
  when building "add device"). This is the source to fetch any driver file + metadata on demand →
  unlocks *adding devices* later. Note: the catalog's "AV" skew is a **legacy categorization
  artifact** (dealer-created drivers get tagged AV regardless of function — C4's AV/lighting
  origins), NOT a real content limit. Still, the built-in **agents/rooms** are Director-internal
  and not third-party drivers, so source those from a Composer/Director install, not this catalog.
- **`c4proj rules <c4p>`** renders existing `event_mgr` programming as human-readable "WHEN X: ->
  do Y" by resolving eventids against driver metadata — the read-side of the programming interface,
  the full stack working together. (Events on rooms/agents show "event NNNN" = the agent/room gap.)
- **BACKEND SCOPE CHECK (2026-07-12): NOT complete for "build a whole project from scratch =
  virtual-director parity."** What exists is a read + envelope + one edit-primitive + driver-
  capability layer (~a foundation). Verified gaps toward full parity:
  - Device **instance properties** live in the item's `<state>` escaped-XML blob (readable, not yet
    modeled/editable). Driver files have **no static `<properties>` schema** (light_v2=proxy only;
    core5=config) — property defs are often **dynamic/Lua**, so per-driver property schema+defaults
    is an unsolved discovery problem.
  - **No "add a device" engine**: id allocation (`iditemcurrent`), default `<state>` instantiation,
    connections, manifest+driver-file placement — none built. This is the linchpin for devices,
    controllers, sub-controllers.
  - **No blank/new-project seed** (baseline ~30 built-in agents + root item + identity.db defaults).
  - **Agents' config models unmapped**: agent item `<state>` is often empty (scheduler=0), so
    schedule/scene/announcement config lives elsewhere per-agent; each is its own sub-model.
  - **Controller + identity/network provisioning**: controller item carries a 13KB `<state>` +
    identity.db + certs (set aside). Hardest tier; provisioning NEW hardware likely DOES require
    Director/Control4 cloud (identity/certs/licensing) → may not be fully offline-synthesizable.
  - **51 Director-internal drivers** (agents, `roomdevice.c4i`, some proxies) not in archive — must
    be sourced from a Composer/Director install or controller `/opt/control4/...`.
  - **Write/authoring engine** (incl. programming rule→XML compiler) and **online-driver
    download/install** not built.
  - **REVISED SCOPE (2026-07-12, user's call). Composer bookends via the FILE, our tool is the
    editor:** Composer downloads current project from controller → `.c4p`; our tool imports → edits
    → exports `.c4p`; **Composer loads the `.c4p` back to the controller (APPLY is Composer, not our
    tool)**. Our tool NEVER interfaces Director. It owns all authoring: project info, rooms/
    locations, add devices/drivers, properties, connections/bindings, programming, agents.
  - **Controller nuance (user, likely correct):** virtual director opens a *blank* project; you then
    add a *controller driver* (an item) — hardware *registration* is deferred to load/identify time
    (Composer's job). So adding a controller driver is plausibly just project.xml data our tool
    could do too. OPEN EMPIRICAL Q: does Composer's "add controller" touch only project.xml, or also
    seed identity.db/certs at add-time? The blank→add-controller diff answers it. If project.xml-
    only → our tool can add controllers like any device; if it seeds identity.db → replicate or
    leave that step to Composer.
  - **Method to complete the backend:** use Composer + virtual director as an **oracle** — perform
    each operation (add room, add device, set property, add schedule…), save, and diff
    project.xml/manifest vs the prior save to reverse-engineer each operation's data transform.
    Baseline capture is now a *Composer-created blank project (with controller)* = our import start.
  - **Capture baseline note:** virtual director has no "New Project" — use **Clear Project** (yields
    a project named "new project"). This is fine because diffs are *differential* (residue is on both
    sides and cancels). Caveat: Clear may retain the old `drivers/` cache + stale identity/media, so
    (a) don't treat `01-blank` as a pristine seed template, and (b) adding a device whose driver was
    already cached won't show driver-file placement — use a novel/uncommon driver to capture that.
    Rule: captures must be a consecutive series on the SAME cleared project, one op at a time.
  - **DIFF INSTRUMENT BUILT: `c4proj diff <a.c4p> <b.c4p>`** (`c4proj/diff.py`) — reports manifest
    file changes (flags `identity.db` specifically → answers the controller-identity question),
    items added (with full XML = instantiation template) / removed / changed, and binding/variable/
    programming deltas. Self-tested. This is the oracle instrument for the capture campaign.
- **CAPTURE CAMPAIGN #1 DECODED (2026-07-12, 20 captures `research/captures/`):** built a project
  in virtual director one op at a time; `c4proj diff` down the series. Major decodings:
  - **Save format:** virtual-director "Save As" = LEAN zip: `project.xml` + `mm.db` + `drivers/`,
    **NO `meta/manifest.json`, NO `identity.db`** (metadata in zip comment). So this format has no
    MD5 integrity and no identity payload. (c4p.py now handles manifest-optional.)
  - **CONTROLLER QUESTION ANSWERED:** adding a Core Lite writes only project.xml + driver files;
    **identity.db is never present/touched** → identity/registration is deferred to hardware load
    (Composer). **Our tool CAN add controllers.**
  - **Item `type` codes:** 1=Project, 2=Site/Home, 3=Building/House, 4=Floor, 6=physical device
    (or controller/agent-parent), 7=proxy sub-device, 8=Room, 9=Agent.
  - **Add-controller is COMPOUND:** seeds the location tree (Home>House>Floor>Room), the controller
    (type6 `control4_corelite.c4i` w/ big state) + `controller.c4i` + `uidevice.c4i` subs, and media
    services (AddMusic/Stations/Channels + `control4_digitalaudio.c4i` at id 100002). +10 bindings.
  - **Add-device pattern:** one parent (type6, the driver c4z/c4i, default `<state>` from driver) +
    proxy sub-devices (type7) — a keypad-dimmer = parent `combo_dimmer.c4i` + `light_v2.c4i` +
    `keypad_proxy.c4i`. Each proxy sub adds a binding.
  - **Device/keypad CONFIG lives in the item's `<state>` blob** (steps 07–12: button add/rename/
    engraving/behavior all = edits to the keypad item's `<state>` BUTTON_LIST_INFO/BUTTON_BEHAVIORS/
    LED_BEHAVIORS). Property model = the escaped-XML `<state>`.
  - **AGENTS are type9 items; their config lives in the agent item's `<state>`** — Advanced Lighting
    starts `<State><all_scenes/><all_off_toggle_scenes/></State>`; creating a scene / adding loads /
    toggle all edit that state (+ the member load items).
  - **"Connections screen" = bindings** (step 19: connect keypad button→scene = +1 provider binding
    + keypad state change).
  - **ID allocation:** user devices get sequential low ints (2,3,…); system services high (100002);
    tracked by `properties/iditemcurrent`.
  - **STATE-DELTA DECODES (diff `--detail`, exact write recipes):**
    - *Create lighting scene* = add `<AdvScene>` under agent(22) state `all_scenes` with fields
      (name, scene_id, toggle_id/off_toggle_id=65535, colors, hold rates, all_members empty).
    - *Add load to scene* = add `AdvScene/all_members/AdvSceneMember[n]` with `device_id` (the light
      proxy id, e.g. 16/20) + level/color element (level=100, levelEnabled=True, levelRate=750…).
    - *Keypad button behavior* = edit keypad(17) state `BUTTON_LIST_INFO/KEYPAD_BUTTON_INFO[n]/
      BUTTON_BEHAVIOR` (0=Load On, 1=Load Off, 3=Keypad) + `BINDING` flag + `LED_BEHAVIOR`.
    - *Connect button→scene (Connections screen)* = add provider binding **agent#22/3 (scene) →
      consumer keypad#17/312 (button) [BUTTON_LINK]** + minor keypad LED_BEHAVIOR/LOCK_COLORS edit.
  - `c4proj diff <a> <b> --detail` now shows `<state>` field deltas + added/removed bindings.
- **WRITE ENGINE STARTED — `c4proj/authoring.py` `clone_device()`.** Adds a device by cloning an
  in-project template: deep-copies the parent+proxy-sub subtree, allocates fresh IDs (bumps
  `properties/iditemcurrent`), remaps `<state>`/bindings, inserts under the room's `<subitems>`,
  clones bindings remapped. Proven: from capture 05 (controller + Server Room + 1 dimmer), added a
  2nd dimmer (ids 18/19/20) with correct LIGHT_V2 + KEYPAD bindings.
- **ASSEMBLY LOAD TEST — TEST A PASSED (2026-07-12).** `test-A-full-clone.c4p` (2nd dimmer cloned
  from a template, full state) **loaded in virtual director; the added dimmer is present.** Diffs:
  (a) base capture 05 → test-A = ONLY the 3 dimmer items + 2 bindings added, nothing else touched
  (tool is faithful); (b) test-A → Composer's post-import save = only item(1) project-root bumped,
  our device kept intact (Director accepts a tool-ASSEMBLED project wholesale). So: **our tool can
  add a device instance and Director loads it.** `test-C-on-full-project.c4p` = same add on the full
  capture-19 project, whole project preserved (for user reassurance).
  - NOTE: test-A/B were built on capture **05** (early, 18 devices) not final 19 (23) — so they
    lack the later laundry/agent/scene; not data loss, just the chosen base. Always state the base.
  - **TEST B PASSED — DECISIVE (2026-07-12): Director REGENERATES device state on load.** The
    skeletal clone (empty `<state>`) loaded fine; diff of our input vs Director's post-import save
    shows items 18/19/20 came back with the FULL default state (PRESET_LEVEL=100, BACKLIGHT/STATUS
    LED settings, button layout, click rates…) — identical to a normally-added device. **⇒ NO
    per-driver template library needed.** Our tool can add a device as a skeletal item (driver ref +
    id + name + proxy-sub skeletons + bindings + room placement, empty state) and Director fills in
    all driver-specific defaults on load. **Tier-3 resolved: from-scratch project creation is not
    blocked.** User's intuition was correct.
  - **"Add ANY device (incl. not-yet-in-project driver)" path now clear:** (1) fetch driver `.c4z`/
    `.c4i` from the online DB → place in `drivers/`; (2) read its metadata (proxies/connections) to
    build skeletal parent(type6)+proxy-sub(type7) items; (3) wire internal proxy bindings from the
    driver's connection defs; (4) place in room; (5) Director completes state + validates on load.
    Open micro-Q (non-blocking): can the skeleton omit the proxy subs (does Director create them)?
  - Clone binding logic fixed: clones only the device's OWN provider bindings, not inbound external
    connections.
- **REPOSITORY ENGINE BUILT — `c4proj/repo.py`.** Control4 driver DB is a public Solr:
  `https://drivers.control4.com/solr/drivers/browse?q=<solr>&wt=json&fl=...` returns driver docs
  (fields: name, manufacturer, model, `proxy` [list], control, **`filename`**, `md5sum`, combo).
  Download direct from `https://drivers.control4.com/<filename>`. `repo.search()` + `repo.download()`
  (md5-verified). Parent driver's `<proxies proxybindingid=.. name=..>PROXYNAME</proxies>` declares
  its proxy sub-items (combo_dimmer→light_v2+keypad_proxy; core5→controller+uidevice; tv→tv).
- **ADD-DEVICE ENGINE (parent-only) — `c4proj/authoring.py`:** `add_device()` injects a PARENT-ONLY
  skeletal item (driver ref + id + name, empty state, no subs, no bindings) in a room — relies on
  Director to complete proxy subs/bindings/state on load (per the proven state-regeneration). Also
  `add_room()` (clones a room template under a floor) and `change_driver()` (repoint+strip state,
  used to swap controller type).
- **PRESSURE TEST — `test projects/pressure-test-theater.c4p` (pending user load).** Built from
  capture 03 base (Composer-made location scaffold + controller): swapped Core Lite→**Core5**,
  renamed Room→**Server Room**, added **Theater** room, added **dimmer keypad** (parent-only) to
  Server Room, downloaded a **Sony KDL-50WF660 TV** from the repo and added it (parent-only) to
  Theater. Bundled proxy drivers light_v2/keypad_proxy for the dimmer; **`tv.c4i` proxy NOT bundled**
  (potential TV break). Open Qs the load answers: (1) does Director complete a parent-only device
  (subs/bindings/state)? (2) controller-type swap OK? (3) tool-created rooms OK? (4) repo TV OK
  despite missing tv proxy? NOTE: `roomdevice.c4i` is referenced but never bundled (Director-
  internal) — proxy drivers may likewise be Director-internal. Started from cap-03 base, NOT absolute
  blank (synthesizing controller's compound location/media seeding from nothing still unproven).
- **PRESSURE TEST v2 — PASSED (2026-07-12): `test projects/theater-from-blank.c4p` loaded in VD
  exactly as expected (clean Core5, no Core-Lite artifacts, rooms/dimmer/TV correct). Built FROM
  BLANK capture 01.**
  Redo after user feedback (v1 wrongly started from cap-03 and left a "CORE LITE" name remnant from
  swapping instead of building). This one starts from the genuine blank project and **reproduces the
  "add controller" compound** — location scaffold Home>House>Main>Room + controller trio + media
  services (Manage Music/Stations/Channels/Digital Media) — with a real **Core5** and correct names
  throughout (0 "corelite"/"core lite" remnants incl. nav icons). Then Room→Server Room, add Theater,
  add dimmer (parent-only) to Server Room, download+add Sony TV (parent-only) to Theater.
  - v1 (`pressure-test-theater.c4p`) LOADED OK in VD: rooms/dimmer/TV correct; only issue was the
    Core-Lite-swap remnant (now fixed in v2). So: tool-assembled controller project loads; repo
    download + add-device engine work.
  - HONEST CAVEAT: the add-controller compound's structure is reproduced from our characterization
    template (the cap01→cap03 diff), Core5 substituted — i.e. replaying a decoded operation, not yet
    a fully code-generated `add_controller()`. Generalizing that into code is a later step.
- **DEVICE PROGRAMMING VOCAB IS METADATA-DERIVED (no capture needed for the per-device explosion).**
  `drivers.py` extracts per device: **events (triggers), commands (actions), conditionals** — all
  `id/name/description(+placeholder params)`. Russell House totals: **1507 events, 2891 commands,
  1149 conditionals** across 186 devices. FIXED bug: conditions live in `<conditionals>/<conditional>`
  (parser wrongly used `<conditions>`; now correct). GAP: **agents (type9, 12 in RH) + rooms**
  vocab is Director-internal (not in bundled drivers) — source from a Composer/Director install or
  capture programming against them.
- **Composer programming MODEL (from guide + logs):** event-driven. Pick a device event (trigger) →
  build a Script = ordered codeitems. Primitives: **Command, Conditional(if), Loop(While), Delay,
  Stop, Break, And, Or, Else**, + variables (bool/number/string, room, custom-agent). Codeitem XML:
  `event(deviceid,eventid)→codeitem(type=CIT_*, device, cmdcond=devicecommand|deviceconditional,
  subitems=nesting)`. Two UI paradigms in Composer: drag-drop (Programming view) + Connections tab
  (bindings — already decoded).
- **WHAT PROGRAMMING CAPTURES MUST PIN DOWN (finite — the primitives, NOT device combos):** exact
  codeitem XML for each of Command(static param), command w/ variable-ref & device-ref params,
  Conditional(operator+value), If/Else, And/Or, Delay, Stop, Break, While, and a variable set +
  compare. Then: (device vocab from metadata) + (primitive encodings from captures) + (value
  encodings) = the rule→codeitem **compiler**, which drives all 3 modes (manual drag-drop UI,
  connections, AI agent).
- **PROGRAMMING GRAMMAR FULLY DECODED (prog01–14) → `better_composer/PROGRAMMING.md` (compiler spec).
  COMPLETE — nothing more to capture.** Event-anchored: every script hangs off
  `<event>(deviceid,eventid)` → root container codeitem → `<subitems>` script. Codeitem `<type>`:
  1=command (incl. DELAY/BREAK/STOP on dev 100000), 2=if, 3=while, 4=else, 6=operator(AND/OR).
  And/Or = an `<expression>` block inside the If holding operator node(type6, AND|OR in display) +
  next condition. While(type3)=deviceconditional + body in subitems. Break=`command BREAK`,
  Stop=`command RETURN` (both type1 on dev 100000). `owneridtype`: ""=device (owneriditem=-1),
  "variable"=var op (owneriditem=variableid, name "="/"=="), "agent"=agent cmd. Device-cmd params
  `<value type><static>`; var-op params inline `<param name="value" type="int">`. Pseudo-devices
  100000=programming, 100001=Variables agent. DELAY time in ms. Nesting = parent's `<subitems>`.
- **DESIGN DECISION — open-ended logic:** Director is fundamentally event-anchored (no event-free
  if/while — confirmed by captures). USER WANTS declarative logic like "while var-test is true, keep
  light at 75%". SOLUTION (doesn't change Director): the compiler SYNTHESIZES event hooks — a
  declarative rule compiles to event handlers on the variable's change event + relevant device-state
  events (or a timer). Reactive/edge-triggered, not a literal loop, but equivalent for most cases.
  This declarative→event-hooks compilation is THE core value-add of our interface over Composer.

---

## MAC SESSION PROGRESS (2026-07-13) — bindings + add_controller done, backend-completion push

**Context correction:** the user CAN drive Composer + a virtual director in the VMware Fusion
Windows VM on this Mac — load-validation and new capture campaigns are all doable here, in the VM.
The only thing the Mac can't do is read the Windows *install* files directly (already extracted on
the workstation; results in the repo). So nothing is "queued for another machine" — it's just
user-in-the-loop in the VM. Toolchain matched: Ghidra 12.1.2 + OpenJDK 21 now installed on the Mac
too (see the updated "Practical continuity notes" bullet below).

**Plan decided:** UI comes LAST and will be done with a design-focused tool (user is better at
visual iteration there); first make sure ALL backend pieces are in place. Order for the backend
gaps: **#4 bindings → #3 add_controller → #2 property/config**. Progress this session:

- **GAP #4 (standalone bindings) — DONE + validated.** `authoring.add_binding()` / `remove_binding()`
  wire an arbitrary provider→consumer connection (append to an existing `<boundbinding>` if the
  provider endpoint already exists, else create it; idempotent; remove drops the boundbinding when
  its last consumer goes). Validated by replaying the capture-18 Connections-screen op: output is a
  **byte-for-byte structural match** to what real Composer wrote in capture 19.
- **GAP #3 (add_controller generalization) — code-complete + structurally validated.** Decoded the
  full add-controller compound (cap02→cap03): 14 items (location scaffold Home>House>Floor>Room +
  controller type6 + `controller.c4i`/`uidevice.c4i` proxy subs + 3 media-service drivers + a
  digital-audio service at id 100002) wired by 11 bindings. Generalized into:
  - `authoring.add_location_scaffold()` — the 4-level tree (shared site-tag GUID), returns role→id.
  - `authoring.add_controller(model, room_id, controller_driver, controller_name, seed_media=True)`
    — controller + proxy subs emitted SKELETAL (Director regenerates model-specific state/icons on
    load, per Test B), media services + digital audio reused from captured generic (model-INDEPENDENT)
    state. Wires the full binding topology. Returns role→id.
  - Generic scaffolding + binding topology extracted once from cap03 into `c4proj/_compound.py`
    (data module, so the library doesn't depend on a capture file at runtime).
  - **Validation:** building from the blank project (cap01) produces an item topology (type,c4i
    multiset) and binding topology that **exactly match Composer's own cap03 output**; controller
    lands at id 6, digital audio at 100002, integrity-clean, re-parses.
  - **VM LOAD-TEST — PASSED + fully analyzed (2026-07-13).** Artifact
    `test projects/controller-compound-from-blank [gen-code].c4p` (Core Lite, from blank, drivers
    bundled) loaded in the VM virtual director without issue; user did **Backup As** (virtual
    director's equivalent of Save-out) → `...[gen-code] - saved out.c4p`. `c4proj diff` of our input
    vs Director's post-load backup is DECISIVE:
    - **0 items added, 0 removed** → Director does NOT auto-seed media services; our explicit
      `seed_media` emission was exactly right, no duplicates. (Answers the open question: keep
      emitting media services ourselves.)
    - **The 3 skeletal controller items regenerated to full state, at the EXACT byte sizes Composer
      itself produces** — controller 0→979b, controller-sub 0→18b, UIDevice 0→422b (identical to
      cap03). **Skeletal-controller-state assumption is now LOAD-PROVEN for controllers, not just
      devices.** Reused generic-state items (room 1484b, media services, digital audio) came back
      unchanged in size; media-service subs stayed empty (as in cap03).
    - **10 bindings accepted unchanged; `iditemcurrent` stayed 14** (our id allocation matched
      Composer's). Same-size items show only internal state-blob normalization, no identity-field
      changes.
  - **Benign warning documented:** on Backup, Composer emits "Unable to retrieve driver <item> from
    the controller. Substituting with the local or online copy of the driver" for every
    driver-bearing item we synthesized. This is EXPECTED and benign for a file-synthesized project —
    the drivers weren't registered into the controller's runtime driver DB via Composer's normal
    install flow, so backup falls back to the (correct) local/online copy. The project loaded and
    fully instantiated regardless (state regenerated correctly). Worth remembering for the eventual
    real-hardware deployment path, but NOT a defect for the Composer-round-trip authoring model.
  - Other controller models: same call with a different `controller_driver` (fetch via
    `repo.download()`); Core5 already load-proven via the earlier theater-from-blank pressure test.

**Still open, next in order:** GAP #2 (property/config write-side) — the generic `<state>`-blob
editor primitive + generalizing the one captured agent-config recipe (Advanced Lighting scenes),
then the #2c capture campaign in the VM for the per-driver property maps + other agents' config
models. Then GAP #5 (2 null + ~8 raw agents; Ghidra now runs on the Mac).

---

## NEXT-SESSION HANDOFF (laptop, 2026-07-13 end of workstation session)

**Where things stand, in one paragraph:** the workstation session closed two big gaps —
agent-command vocabulary (17 of 27 agents now have real extracted vocab, via Ghidra disassembly,
fully documented and reproducible — see "GHIDRA DISASSEMBLY" / "MODERN-STYLE REGISTRATION PATTERN"
/ "BATCH COMPLETE" entries above) and the programming-rule compiler (`c4proj/programming.py`,
fully implements `PROGRAMMING.md`'s grammar, tested end-to-end, wired into the CLI as
`c4proj add-rule`). Combined with the already-proven read side and device-add engine, **authoring
a complete project with real device programming is now largely unblocked.**

**User's question this session, and the honest answer:** "what's left before we have a fully
usable UI that can create-new-or-import a project, fully build it out (rooms/controllers/drivers/
agents/programming), and save back out for Composer to load?" Answer, ranked by how blocking each
is:

1. **There is no UI.** Everything built so far (`c4proj`) is a Python library + CLI. This is the
   most literal blocker for "a fully usable UI" — it's a from-scratch layer, not started.
2. **Device/agent instance PROPERTIES and agent CONFIGURATION are not systematized.** Adding a bare
   device/agent is solid (Director fills in defaults on load — proven). But *configuring* one
   (device property values from its `<state>` blob; agent config like a scheduler entry, a
   lighting scene, guest-services settings) is a different, much less complete problem. Only ONE
   config recipe has ever been captured as a documented write-shape (Advanced Lighting scenes, in
   the capture-campaign notes above: `<AdvScene>` under the agent's state) — nothing generalized
   into reusable code the way `add_device`/`clone_device`/`programming.py` are. This is the most
   load-bearing remaining backend gap for "fully create" (not just "add").
3. **`add_controller()` is not generalized.** Current pressure tests replay one decoded operation
   (Core5 substituted in); works for that case, not proven for other controller models or a truly
   from-scratch blank project. Only blocks NEW-project creation, not editing an imported one.
4. **Standalone binding/connection authoring** — bindings that come bundled with `clone_device`
   work; a general "wire an arbitrary new binding between two arbitrary devices" function doesn't
   clearly exist as its own primitive yet.
5. **Remaining agent vocab** — 2 confirmed null results (Access, Light Properties) + ~8 agents with
   raw uncurated signal (Backup, Diagnostics, DriverUpdate, EmailNotification, History, Identity).
   Lowest priority — already mostly closed, this is finishing touches.

**User has not yet said which of these to tackle next** — that's the first thing to settle when
resuming. My own suggested order was #2 (property/config write-side) before UI work, since UI
without a complete backend to drive would just be a shell — but this wasn't decided, just proposed.

**Practical continuity notes for the laptop:**
- Ghidra + OpenJDK 21 toolchain is now installed on BOTH machines (both environments matched,
  2026-07-13 Mac session). **Mac install:** `brew install ghidra` (formula, not a cask — pulls
  stable **12.1.2**, the same version used on the workstation, and auto-installs its `openjdk@21`
  dependency; no sudo). Headless launcher: `/opt/homebrew/Cellar/ghidra/12.1.2/libexec/support/analyzeHeadless`
  (confirmed boots on JDK 21.0.10). The vocab-extraction scripts are copied into the Mac's
  registered scripts dir `~/ghidra_scripts/` (Mac equivalent of the workstation's
  `%USERPROFILE%\ghidra_scripts\` — same OSGi gotcha applies: scripts MUST live in that registered
  dir or they silently fail to load). **Workstation install** (for reference): `winget install
  Microsoft.OpenJDK.21` + download Ghidra from `github.com/NationalSecurityAgency/ghidra` releases.
  The RESULTS (`research/agent_vocab/*.json`) are portable and committed to the repo/synced via
  OneDrive — no need to redo extraction, just to add to it.
- `c4proj/programming.py` and the `add-rule` CLI command need no special environment beyond Python
  3.12 (stdlib only, like the rest of `c4proj`) — fully portable, works on the laptop immediately.
- The live-Director access investigation (mutual-TLS cert, dealer credentials) is paused, per
  earlier user call — not touched further this session, still sitting exactly where the
  "LIVE-DIRECTOR ACCESS INVESTIGATION" section above left it.

---

## Reference resources (better_composer)

- **Composer Pro User Guide** (v3.3, 590 pp): `better_composer/research/composer-pro-user-guide-rev-aa.pdf`
  — publicly available from Control4/SnapOne. THE reference for every authoring operation we must
  characterize. Use `pdftotext -f N -l M <pdf> -` (poppler installed) for targeted section reads.
  Key sections: Adding a controller / Register controller from Composer; How to add devices /
  Adding drivers manually / My Drivers tab; Configuring device properties; Connections view
  (Control/AV + Network); Agents view; Programming view; Loading a project's configuration to a
  controller (the apply flow).
- Online driver DB (Solr): https://drivers.control4.com/solr/drivers/browse (see above).

## Reference docs (Control4 DriverWorks)

- DriverWorks repo: https://github.com/snap-one/docs-driverworks
- API reference: https://snap-one.github.io/docs-driverworks-api
- Driver XML reference: https://snap-one.github.io/docs-driverworks-xml
- Fundamentals: https://snap-one.github.io/docs-driverworks-fundamentals/
- Zigbee implementation guide: https://snap-one.github.io/docs-zigbee
- Proxy protocol docs (per-proxy): linked from the DriverWorks README
