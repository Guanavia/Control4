# Control4 Drivers Repo

Monorepo for all Control4 DriverWorks drivers built by Dave Woychek (david@propertyrenewal.llc).

## Working style (owner preference)

Dave wants to focus on **what we're building and the interesting ways to use/push the hardware** —
not on troubleshooting the plumbing behind the curtain. Default mode for all work here: **you drive
the toolchain, environment, and debugging end-to-end and just get it working**; surface decisions
and the interesting findings, keep the nuts-and-bolts friction off his plate. He owns his hardware
and is firmly of the view that an owner may do whatever they want with gear they own — so
authorized reverse-engineering / pushing devices past vendor locks **on his own equipment** is in
scope and encouraged. When a technique is gray for *client/dealer* installs, gate it behind an
**"Owner Approved"** toggle (see `Yamaha-YAS209/research/LINKPLAY_RE.md`) rather than
refusing or silently enabling it.

**Dave is a working Control4 dealer — do not explain Composer to him.** Skip walkthroughs of
updating/adding drivers, Manage Drivers, syncing, backups, navigating views: he does this for a
living. Say "update the driver and run X"; give the findings, the decisions and what to watch
for, not the click path. Surface a Composer mechanism ONLY when it is itself the finding (e.g.
"the local driver DB and the controller hold separate copies, which is why the version lagged").

## Repo conventions

- **One subfolder per project.** All of a project's source, docs, and research notes live in its folder (e.g. `nv_shield_tv/`, `sonoff_snzb02p/`, `better_composer/`).
- **Per-project context persistence (ALWAYS).** Each Control4 project must be workable independently. For EVERY conversation about a given project, save the conversation's decisions, design threads, and project status **inside that project's own folder** — never mixed with another project's, and never left only in chat/local memory. Practically: durable project status/decisions belong in that folder's docs (its own `CLAUDE.md`/`FINDINGS.md`/notes); the root `CLAUDE.md` keeps only the short per-project pointer under `## Drivers`. When a conversation produces new design thinking, write it to a file in the relevant project folder before ending. This keeps the many Control4 projects from getting confused with each other.
- **Scoped commits (ALWAYS).** This is a monorepo, but every project is versioned independently *by convention*. Each commit must touch **only one project's subfolder** (never span two projects), and its message must be **project-prefixed** — e.g. `better_composer: add version-validation note`, `nv_shield_tv: fix volume ramp`. This keeps each project's history cleanly filterable (`git log -- better_composer/`) and pushable on its own. The ONLY exception is a genuinely repo-wide change (this root `CLAUDE.md`, `.gitignore`, shared build scripts), which is prefixed `repo:`. Never bundle unrelated projects into one commit; stage per-folder and commit separately.
- **Versioning (ALWAYS, every project — owner's rule, 2026-07-29).** Product versions are
  **semantic**, and the **first RELEASE is `1.0.0`**. Anything still in the development pipeline is
  **`0.x`** — Dave explicitly dislikes a pre-release product carrying a high version number, so
  never let a build counter masquerade as the product version. Where a vendor format imposes its
  own version field, **keep the two separate**: e.g. Control4's `driver.xml` `<version>` must be a
  plain **integer** (verified across the catalog: Pioneer VSX-LX503 = 117, Onkyo TX-NR747 = 104) and
  is only a cache-buster Composer compares on update — it is NOT the product version and is not
  human-facing. Pattern to copy (`Yamaha-YAS209/`): a `VERSION` file holds the semantic version,
  the build script auto-increments the vendor integer, and both are stamped into one displayed
  string via a `@BUILD@` token so the number a user sees can never drift from the package.
- A `.c4z` file is just a **zip of the driver folder's contents** (files at zip root, not nested in a folder). `build.bat` / `build.ps1` are Windows scripts currently hardcoded to `nv_shield_tv`; the build outputs the `.c4z` into the driver's own folder and excludes existing `*.c4z` from the zip.
- Standard driver folder layout:
  - `driver.lua` — driver logic
  - `driver.xml` — driver metadata/config (devicedata XML)
  - `www/documentation.rtf` — dealer-facing docs shown in Composer
  - `www/icons/device_sm.gif`, `www/icons/device_lg.gif`, `www/icons/device/*.png`

## Drivers

### nv_shield_tv
NVIDIA Shield TV IP driver. Pre-existing, working. Built artifacts `nv_shield_tv-dmw.c4z` (own build) and `nv_shield_tv-fordev.c4z` live in the `nv_shield_tv/` folder (moved from repo root 2026-07-25 to keep the project self-contained). `build.ps1` outputs `-dmw.c4z` into that folder and excludes `*.c4z` from the zip so artifacts never nest into a build.

### Yamaha-YAS108 — OPEN, v0.9.0 (IR only, built 2026-07-30, NOT yet hardware-tested)
Second Yamaha soundbar. **Its own driver, not a second model on the 209's umbrella.** The umbrella
died on contact with a real second model: **`<connections>` and `<capabilities>` are STRUCTURAL**
(Director reads them at instantiation) so one driver cannot vary its surround-mode list or input
set per model — a YAS-108 would have shown six sound programs where it has two. Dave's call after
seeing the trade-off: **one driver per model.**
**No network interface AT ALL** (no wifi, no ethernet, no local API), so there is no feedback path
and everything follows from that: status properties are named **`Assumed …`** not `Current …`;
`<capabilities>` deliberately **omits discrete volume and discrete mute** because nothing could
ever correct an estimate; **power and mute are TOGGLE-ONLY** (the discrete codes in the capture are
empty) so discrete commands are synthesised from an assumed state, with **Resync actions** to fix
the assumption without sending IR. Mute uses the device-side toggle code (state-independent).
**18 codes captured from the real remote, RENUMBERED** into this driver's range — the capture's ids
collide semantically with the 209's (`1000` = Bass Extension there, HDMI here). Connections checked
against the owner's manual, not assumed: the YAS-108 **does** have a SUBWOOFER OUT jack.
**Nothing fired at real hardware yet.** IR-only harness covers every control path and fails hard on
any code id not declared in driver.xml.

### Yamaha-YAS209 — OPEN, v0.9.0 (BOTH control surfaces validated on real hardware)
**Renamed from `Yamaha-Soundbar/` and de-umbrella'd 2026-07-30** (Model property removed).
**ICONS: there is no soundbar icon to reuse anywhere** — Control4's own YSP-1000 driver just
references the generic built-in `devices_sm/receiver.gif`, Composer's built-in library has 168
icons with nothing closer than a receiver, and the Bose soundbar drivers ship their own brand
logos. Both drivers now use a **drawn** soundbar icon (body, two grilles, status LED) generated
by a script into 16/32/70/90/300px PNGs; the previous icons were **1x1 transparent GIF
placeholders**, i.e. the driver displayed nothing. **CONFIRMED IN COMPOSER 2026-07-30** — both
drivers load and render correctly, including the icon at tree size and the documentation's
hyperlinked table of contents (so Composer's RTF viewer does handle `\l` bookmark fields).
**MAJOR PIVOT (2026-07-26): the YAS-209 is NOT YXC/MusicCast — it's a Linkplay (WiiMu) module.**
*(Note on wording: "v1"/"v2" in this section historically meant the two ARCHITECTURES — YXC then
Linkplay — not product releases. Product version now lives in `Yamaha-YAS209/VERSION`, is
semantic, and is pre-release `0.x` until IR is verified and it ships as 1.0.0.)*
The original YXC premise (the FIRST architecture) was wrong for this unit (port 80 closed). Reverse-engineered the real
local control end-to-end and **validated power/input/volume live on the actual bar** — full RE
playbook (device map, cert-extraction, exact commands, the reusable **Owner-Approved** gray-area
toggle, and the general method for future locked devices) is in
`Yamaha-YAS209/research/LINKPLAY_RE.md`. Two control surfaces: **UPnP :49152** (no auth) =
volume/mute/transport; **Linkplay httpapi :443** (mutual-TLS, client cert extracted from Yamaha's
app) = power/input. Confirmed commands: power `YAMAHA_DATA_SET:{"power saving":"1"|"0"}` (1=on,
0=standby), input `setPlayerCmd:switchmode:HDMI|bluetooth|optical` (TV=optical).
**Second-architecture driver built** (`driver.xml`+`driver.lua`, compiles clean): umbrella "Yamaha Soundbar" (Model +
Control Method IR/IP/Serial; IP implemented, shipping default will be IR). IP = UPnP for
volume/mute/transport + httpapi for power/input **gated behind the `Owner Approved` property**
(default No). **ON-CONTROLLER STATUS (2026-07-26, REAL director on Dave's own hardware — NOT a
virtual director): UPnP half WORKS** — Connected goes true and volume/mute read live against the
actual bar (transport is the same layer). **All soundbar testing is on real hardware by necessity:**
a virtual director cannot exercise a live connection to the bar, so there is no VD test loop for
this project (unlike `better_composer`, where VD *is* the loop — don't carry that habit over). Getting there fixed several
DriverWorks gotchas now baked into the driver: `C4:Log` doesn't exist (use `C4:ErrorLog`); Composer
Actions arrive via `ExecuteCommand` as `strCommand="LUA_ACTION"` with the real name in
`tParams.ACTION`; and **`C4:url()` request headers go as the `Get`/`Post` 3rd arg, NOT via
`SetOptions`** (that was the UPnP 500 — a dropped SOAPACTION header). Also confirm the driver-reload
cycle: Composer caches by version, so **remove + re-add the driver** (build-tag log line confirms the
live build).

**SSL-SOCKET REWORK DONE (2026-07-27) — written + build-verified, NOT yet run
against the bar.** `C4:url()` has **no client-certificate support** (confirmed against Control4's
own `global/url.lua`), so the mutual-TLS path could never authenticate through it. `HttpApiGet` is
now a **raw SSL `network_connection`**: driver.xml declares binding **6002 / port 443**,
`classname SSL`, `method tlsv12`, `verify_mode none` (the bar's SERVER cert is private-CA), and the
driver speaks HTTP/1.1 over the socket itself — request queue, `Connection: close`, Content-Length
honoured, close-as-end-of-body, 10s timeout, parsed in `ReceivedFromNetwork`. The connection is
bound to the `IP Address` property via `C4:CreateNetworkConnection` so the dealer never types the
IP twice.

**BOTH OPEN QUESTIONS FROM LAST SESSION ARE ANSWERED — from Control4's own docs, no hardware trip
needed** (`snap-one/docs-driverworks-fundamentals` §TLS/SSL Driver Configuration +
`docs-driverworks-api` §GetPrivateKeyPassword / §SampleSSLConnection — note the *XML* reference
repo does NOT document `certificate`/`private_key`/`method` at all; they're only in those two):
1. **`protected="True"` is not a Control4-owned secret** — it just makes Director call
   `GetPrivateKeyPassword(Binding, Port)` in the driver, which returns whatever passphrase we
   choose. So an encrypted key is fully in our control, and a **plain key works too** (attribute
   omitted). Shipping default = plain; `ENCRYPT_KEY=1 ./build.sh` produces the encrypted variant
   *and* stamps `protected="True"` onto the staged driver.xml, with `driver.lua`'s
   `GetPrivateKeyPassword` already returning the matching passphrase (`yas209-linkplay`) — so the
   fallback is a rebuild, not a code edit. Both variants build-verified; the encrypted key was
   round-tripped through `openssl pkey` with the driver's passphrase.
2. **`certificate` / `private_key` / `cacert` may all point at the SAME file** (explicitly
   documented) — so the one-file `linkplay_client.pem` (leaf + issuing CA + key) is used for all
   three. No splitting needed. Also verified offline: the leaf cert and private key are a
   **matching pair** (public-key MD5s identical), removing one class of hardware-trip failure.

**HARDWARE BRINGUP PASSED (2026-07-27, real director, real bar) — httpapi WORKS.** `Test httpapi
(SSL)` returned: handshake SUCCEEDED, `getStatusEx` HTTP 200, 1598-byte body. Specifics worth
keeping:
- **The PLAIN key was accepted** — `ENCRYPT_KEY=1` was never needed (kept as insurance).
- **The second network binding (6002) coexists fine with 6001** — the risk flagged pre-test was a
  non-issue, and 6001's validated UPnP half was left untouched.
- **`C4:ReadFile()` DOES NOT EXIST in DriverWorks** (0 hits across Control4's published API — the
  same trap as `C4:Log`). Inside a `pcall` it fails silently, and it printed a bogus "cert not
  readable" line on the very run whose handshake succeeded. **Fixed to `C4:FileExists()`**, and the
  probe is now explicitly advisory in both directions (it never gates a request — which is the only
  reason the test passed rather than being blocked by a false negative). **Never probe with
  `C4:FileOpen()`: it CREATES the file when missing, manufacturing a false pass.**
- **Device fingerprint captured** into `research/LINKPLAY_RE.md` (new "Validated FROM the Control4
  driver" section). Two things matter downstream: `project`/`priv_prj` report **`YAS_109`** (wrong/
  shared Linkplay string — **do not use it for model detection**; `yamaha_model_name` = `YAS_209` is
  the trustworthy field), and **`uart_pass_port` 8899 is an unexplored UART passthrough to the MCU**
  — the most promising surface for DSP/sound-mode control that httpapi does not expose. Also
  `preset_key: 6` (6 hardware presets, unexplored) and undecoded capability bitfields.

**POWER + INPUT CONFIRMED WORKING ON THE BAR (2026-07-27).** `YAMAHA_DATA_SET:{"power saving":...}`
and `setPlayerCmd:switchmode:...` both drive the real hardware from Control4. **The IP control path
is now complete and fully validated end to end** — UPnP volume/mute/transport + httpapi
power/input. The Linkplay-architecture driver does what it was built to do.

**STATE FEEDBACK BUILT (2026-07-27) — needs one hardware session to finish its decode tables.**
Power/input are no longer write-only. New `State Poll Seconds` property (default **30s**, `0`
disables) drives a SEPARATE, slower timer from the 3s UPnP volume/mute poll — deliberate, because
every httpapi read is a **full mutual-TLS handshake** (one connect per request, `Connection:
close`), so matching the volume cadence would mean a TLS handshake every 3 seconds forever. Reads
`getPlayerStatus` (`mode` → input) and `YAMAHA_DATA_GET` (`power saving` → power) and applies state
WITHOUT re-sending commands. No poll fires on `StartStatePoll` itself — OnDriverLateInit walks every
property, so an immediate poll there would touch off a handshake burst on load.
**INPUT MAPPING CLOSED (2026-07-27) — `MODE_TO_CONN` learned on hardware**, via the `Learn Input
Codes` sweep (selects each input, reads `getPlayerStatus` back, so each number is
self-identifying): **`43`=optical/TV, `49`=HDMI, `41`=Bluetooth, `0`=network idle.** **HDMI=49 could
NOT have been guessed** from Linkplay's published codes — worth remembering as the general lesson:
soundbar-specific codes are not in the public Linkplay vocabulary, so learn them, don't infer them.
**Caveat on `0`:** it is Linkplay's generic *idle/no-source* value, not a real source id (the bar
returned it for wifi because playback was stopped). It is the one entry that could appear in
another idle condition — **standby being the obvious candidate** — so the driver now IGNORES mode 0
while power is known-off, rather than parking the room on "Network". Per-service streaming codes
(`1`/`2`/`10`/`31`) remain documentation-sourced, never observed here.

**`YAMAHA_DATA_GET` CAPTURED (2026-07-27) — power feedback CONFIRMED + the whole surround/EQ
surface found.** The command that was listed as "read" but never actually captured turns out to
hold every Yamaha-specific setting, and `"power saving"` is genuinely there, so the power-feedback
assumption was right. Full payload + key table in `research/LINKPLAY_RE.md`. Written back via
`YAMAHA_DATA_SET:{"<key>":"<value>"}` (already proven for power).
**Now exposed** (all gated on Owner Approved): surround via the RECEIVER PROXY (see below);
`3D Surround`, `Clear Voice`, `Bass Extension` as writable properties; `Subwoofer Volume`,
`Yamaha Volume`, `Audio Stream` as display-only properties. The state poll reads them all back.

**SURROUND/EQ UI FIXED (2026-07-27, Dave spotted the empty sections).** The Surround + EQ sections
of a receiver's control UI in Composer are driven ENTIRELY by `<capabilities>`, not by properties.
Surround needs `<has_discrete_surround_mode_select>` **plus** a `<surround_modes>` list of
`{<name>,<id>}`; we declared neither, hence blank. Now declares all 6 confirmed modes (ids 1-6),
handles proxy cmd `SET_SURROUND_MODE`, and sends `SURROUND_MODE_CHANGED` on external change.
**`Sound Program` was REMOVED as a property** — it is a proxy concept and belongs in the control
UI. The 3 DSP toggles stay properties because the receiver proxy models surround as ONE mode list
with no notion of independent toggles. **IDs must match between `driver.xml` `<surround_modes>` and
`driver.lua` `SURROUND_MODES`** — there is a cross-check script pattern in the commit; re-verify if
either is edited. Docs render the notification param inconsistently (`SURROUND MODE` with a space
vs `SurroundMode`), and DriverWorks docs have already proven unreliable on naming, so the driver
sends/accepts all spellings rather than burning a hardware trip to find out which.
**OFFLINE TEST HARNESS BUILT — `Yamaha-YAS209/test/simharness.lua` (2026-07-27).** Runs
`driver.lua` with NO controller and NO bar: stubs the `C4` API and simulates the SSL socket end to
end (`NetConnect`→`ONLINE`→`SendToNetwork`→`ReceivedFromNetwork`→`OFFLINE`), so it exercises the
real httpapi transport, HTTP parsing and queue. `lua test/simharness.lua driver.lua <clamp|reject|
acceptall> <ActionName>`. The `acceptall` archetype exists to prove the negative controls still
fire — if `acceptall LearnSoundPrograms` ever reports a clean all-pass, the control is broken and
every sweep result is unfalsifiable. **Found THREE real bugs hardware testing had not:**
(1) **stale-OFFLINE race** — the previous socket's close was attributed to the NEXT request,
failing it moments before its reply landed (fixed: `PUMP_GAP_MS` settling gap);
(2) **cooldown raised too late** — the gap was set AFTER the completion callback, and every sweep
issues its next request from inside that callback, so the one request the gap existed to protect
skipped it (fixed: raise `gCooldown` before invoking the callback);
(3) **unreliable baseline** in the subwoofer sweep — probes are classified by "did it change from
before", with no starting value established, making the negative control a coin flip.
**(1) and (2) are LATENT ON HARDWARE** — timing happened to work on the bar, so sweeps returned
correct results while silently logging failed writes. Use this harness before every hardware trip;
each trip costs a rebuild + Composer remove/re-add + a walk to the bar.

**⚠️ PROJECT LOST ONCE (2026-07-27) — DRIVER-UPDATE SAFETY IS NOW A HARD RULE.** Dave deleted the
device from the room, then ran **Add/Update Driver** in the same pass; the project refreshed EMPTY
and had to be restored from an online backup. The update flow expects the device to still exist —
delete-then-update is not a supported sequence. **My "remove + re-add" advice contributed to this:
it was aimed at dodging a Director restart, and I failed to pair it with "back up first".** Rules
now in `Yamaha-YAS209/README.md` ("Updating the driver safely"), and they generalise to EVERY
driver project in this repo:
1. **Local backup (File → Backup As) before ANY driver install/update/removal on a live project.**
2. **Know the change type:** `driver.lua` = hot, update in place. `<capabilities>`/`<connections>`
   = structural, read by the proxy at INSTANTIATION, so Composer's Director-restart prompt is
   LEGITIMATE, not a bug.
3. **For structural changes prefer the RESTART over remove/re-add on a live project** — ~1 min of
   no automation, but device + bindings + programming survive. Remove/re-add discards all of them.
4. **NEVER delete the device and then run Add/Update Driver.**
4b. **A re-add also resets every PROPERTY to its default** — this bit twice: `Owner Approved`
   fell back to `No` (caught, because the sweep refused loudly and said why) and `IP Address`
   fell back to BLANK (NOT caught — the driver received every Halo volume press and had nowhere
   to send it, failing silently while the device UI still worked because that path talks to the
   device directly). **If anything breaks right after a re-add, check properties BEFORE the
   code.** Fixed 2026-07-28: `CheckConfigured()` now sets `Connected` to
   `"false - NO IP ADDRESS SET"` and logs via the new `LogCritical`, which BYPASSES the Log Mode
   gate. That gate defaulted to `Off`, so the driver's most important message — "I cannot
   possibly work" — was the one message nobody could see. **General rule: misconfiguration
   diagnostics must never be silenceable by a log-level setting.**
5. **Batch structural changes** — each one is another restart.

**IR LAYER ADDED (2026-07-29).** IR output binding + `<irsection>` + routing when Control Method
= IR. Uses Control4's **conventional receiver IR code ids** (101/102/103 power, 106/107 volume,
137/138/139 mute) - identical across every receiver IR driver in the catalog, so do not invent
ids. **The IR connection class MUST be `IR_OUT`, NOT `IR`** - "IR" is not a class Composer
recognises, so the connection never appeared as bindable (Dave hit this immediately). Correct
shape: `type=1` (Control), `consumer=True`, `linelevel=True`, class `IR_OUT`. **The id must be 2,
not 1, in a DriverWorks (lua_gen) driver** - id 1 is the reserved serial binding. Pure `av_gen`
IR drivers DO use id 1, which is the trap when copying them; re-confirmed 2026-07-29 against
Pioneer VSX-LX503 (a real lua_gen IR driver), which uses id 2. An earlier version of this note
said `id=1` and "IR Sensor" - it was wrong and contradicted the driver's own comment.
**Patterns are CANDIDATES seeded from Control4's Yamaha YSP-1000 driver** (2005 soundbar vs our
2019 bar; Yamaha reuses system codes so power/volume/mute have a fair chance, nothing confirmed).
**`Verify IR Codes` Action** reads the field over IP, fires the code, waits, reads again =
objective per-code pass/fail. **IR is one-way, so the IP path is what makes IR testable at all.**
If nothing passes, the report says to check for a bound+placed emitter FIRST, since a missing
emitter is indistinguishable from a wrong code set. Input-select over IR deliberately REFUSES with
a message (the YSP set has TV/DVD/VCR/AUX, not this bar's inputs) rather than failing silently.
**`build.sh` now validates driver.xml before packaging** - luac compile + well-formedness + a
specific check for **`--` inside XML comments**, which is illegal and broke the file THREE times
in one day.

**IR BRINGUP FAILED, DIAGNOSED OFFLINE, THREE REAL BUGS FIXED (2026-07-29).** The
IR connection bound fine in Composer, but `Verify IR Codes` did nothing and no emitter blink was
ever seen. Dave's hypothesis was that Composer will not send IR while Control Method = IP.
**That was not it** - `Verify IR Codes` calls `C4:SendIR` directly and never consults
`UsingIR()`, so it is control-method-independent by design. The actual causes, found with the
offline harness plus Control4's own catalog, no hardware trip:
1. **The whole IR layer was invisible.** `Log Mode` defaults to **Off**, which gates every
   `Log()` call, and `Log Level` defaults to Warning while all the `[irverify]` progress is
   `LogInfo`. Adding the IR connection required re-adding the driver, and **a re-add resets
   properties** - so `Owner Approved` fell back to `No`, `Verify IR Codes` refused at its first
   guard, and it explained itself down a channel the same reset had just switched off. The
   refusal and a dead emitter produced byte-identical output: nothing. **This is the THIRD time
   the property-reset-on-re-add trap has bitten, and the second time a guard explained itself
   through a silenced channel.** All IR bringup output is now `LogCritical` (bypasses the gate).
2. **`SET_VOLUME_LEVEL` had no IR branch** - it fell straight through to UPnP SOAP and emitted
   ZERO IR. **`<capabilities>` is not per-control-method**: `has_discrete_volume_control` is
   declared once and applies in IR mode too, so Navigator/Halo send `SET_VOLUME_LEVEL` regardless
   of Control Method. Reproduced objectively against the pre-fix driver (`-- IR fired: none`).
   General rule now in the README: **every proxy command needs an IR branch or an explicit
   refusal**; one with neither is silently a no-op.
3. **Volume codes were `<transmit>SUSTAIN</transmit>`**, copied verbatim from the YSP-1000 seed.
   SUSTAIN is an **av_gen** convention where the PROXY drives `SendIRStart`/`Stop` for you; a
   DriverWorks driver calls `C4:SendIR` itself. Checked Control4's own shipping lua_gen IR driver
   (Pioneer VSX-LX503): **433 codes, all PULSE, `SendIRStart` never called**. Converted to PULSE
   rpt 5. **Lesson: do not copy IR metadata across driver families - `av_gen` and `lua_gen` split
   the work differently.** (Also confirmed while there: `<irsection>` belongs under `<config>`,
   which ours already was, and `C4:SendIR(idBinding, idIRCode)` is real. Control4's template
   passes the id as a **string** though the docs say numeric, so `SendIR` now tries numeric and
   falls back to string, logging which one worked - that removes a hypothesis for free.)
**A FOURTH bug the harness caught, and the nastiest**: `Verify IR Codes` scored a state code as
"field == want after firing", which **passes whenever the bar is already in the wanted state** -
so with the bar on and unmuted, POWER_ON and MUTE_OFF both reported WORKS **with no emitter
connected**. It would have produced confidently wrong conclusions, worse than a hang. Every code
now PREPARES the bar to the opposite state over IP first and reports `INCONCLUSIVE` if that
fails. **This is the same unreliable-baseline bug the subwoofer sweep had - it recurred in new
code, so treat "did you establish the baseline" as a standing review question for any
learn-by-readback sweep.**
**HARNESS EXTENDED** (`test/simharness.lua`): stubs `C4:SendIR`/`SendIRStart`/`SendIRStop`,
parses the declared `<ircode>` ids out of driver.xml and REJECTS any undeclared id, prints every
code the driver emitted, and adds `PROXY:<CMD>` / `IR:<CMD>` to drive the receiver proxy directly
(what a Navigator/Halo press really looks like). Two new archetypes give the IR sweep a control
in BOTH directions: **`noemitter`** (must report nothing working) and **`irworks`** (must report
everything working) - the positive one matters because "all codes failed" is the conclusion the
real run is meant to draw, so it has to be earned.
**NEW ACTIONS: `IR Emitter Test: Power On / Volume Up / Mute On`** - fire ONE code with nothing
else in the path (no proxy, no capabilities, no Control Method, no Owner Approved, no IP) and
report unsilenceably. **This is the instrument that was missing**: it splits "dead emitter or
unbound connection" from "wrong code", the two failures IR cannot tell apart. Run it FIRST next
hardware session; a blink clears the physical side, no blink means stop and fix the binding.
**Still unverified on hardware:** whether any seeded code actually drives the YAS-209.

**IR STILL DOES NOT TRANSMIT — narrowed to the controller-side IR path, NOT the driver
(2026-07-29, hardware).** `IR Emitter Test` fired every code with a brand-new emitter and correct
Composer connections: **no blink, ever, on any code, in either argument form.** What the on-driver
diagnostics established:
- **The binding IS bound.** `GetBoundProviderDevice(myId, 2) -> 85`. So Director agrees something
  (device 85) drives binding 2.
- **`C4:SendIR` never errors** — numeric id and string id both "sent without error". So the call
  is accepted and simply produces no RF/IR.
- **MY DIAGNOSTIC LIED AND I CORRECTED IT.** The first version printed "OnBindingChanged: Director
  has NEVER reported binding 2 ... nothing is attached to it" — **wrong**: `OnBindingChanged` fires
  only on a CHANGE, so a binding already bound at driver load never fires it. It contradicted
  `GetBoundProviderDevice` **in the same output block**. Now reworded to say absence is normal and
  to trust `GetBoundProviderDevice`. **Lesson (third time on this project): a diagnostic that can
  assert a false negative is worse than no diagnostic** — and the tell was that two lines of the
  same block disagreed.
**Everything driver-side is now ruled out by direct comparison with Control4's own shipping
lua_gen IR driver (Pioneer VSX-LX503), not by assumption:** `<irsection>` placement under
`<config>`, its attrs and `<ircode>` field set, the IR connection block (id 2 / type 1 / facing 1 /
consumer True / linelevel True / IR_OUT), `<control>lua_gen`, `<controlmethod>ip`, `IR_BINDING_ID
= 2`, and the `C4:SendIR(binding, code)` call shape — **all identical**. The 8 IR **patterns are
byte-identical** to Control4's YSP-1000 source (verified word-for-word). Note the emitter LED
blinks whenever Director transmits ANYTHING, right code or wrong — so **no blink proves Director
is not transmitting at all, which cannot be a code-data problem.**
**RESOLVED — THE DRIVER'S IR PATH WORKS; THE NEW EMITTER IS DEAD (2026-07-29, hardware).** The
positive control settled it in one pass. Dave ran three tests: (1) our `IR Emitter Test` on the
brand-new emitter — no blink; (2) the stock **YSP-1000 av_gen** driver on the same emitter — **also
no blink** (a Control4-authored driver on Director's own IR engine, i.e. a completely different
code path); (3) our driver against the **known-working emitter** already serving the family-room
TV — **its LED FIRED.** So `C4:SendIR` from this driver genuinely transmits, and the fault was
hardware all along. **Everything the driver could contribute was already correct** — the two
sessions of instrumentation found four real bugs but none of them were the no-blink cause.
**Method note worth keeping: the decisive move was not more instrumentation, it was a positive
control with a KNOWN-GOOD component.** Two drivers failing on one emitter, and one driver working
on another, isolates hardware in three tests. Reach for that earlier next time — the driver had
been instrumented well past the point of diminishing returns before this was tried.
**CONFOUND CLOSED — IT WAS THE PORT, NOT THE EMITTER (2026-07-30).** A second replacement emitter
ALSO failed on **IR OUT 1** and works perfectly on **IR OUT 3**. So the original "brand-new emitter
is faulty" call was WRONG — two emitters were blamed for a dead port. **IR OUT 1 is not registering
as an IR output on this controller**, even though Composer's Connections view shows it bound to the
driver's IR connection AND correctly greys out the serial connection as mutually exclusive, and the
controller's config page offers no serial/IR mode switch. Cause unknown. **NOT our problem to
solve** (owner's call) — using IR OUT 3. Worth remembering as a general trap: **an IR output can be
bound, displayed as correct, and still not transmit**, so when isolating IR faults, swap the PORT as
well as the emitter. The earlier note below kept the possibility open; this is the answer.
**Superseded (kept for the reasoning): emitter vs PORT.** If the working emitter sits in a different IR
output than the dead one did, the fault could be the port, not the emitter. Plug the known-good
emitter into the suspect port to separate them.
**There is NO IR feedback mechanism to add, and this is settled, not assumed:** DriverWorks exposes
exactly three IR functions — `SendIR`, `SendIRStart`, `SendIRStop` — all fire-and-forget with no
status or query call, because IR out is electrically one-way. The IP readback in `Verify IR Codes`
IS the substitute feedback loop and is already built.
**IR CODES CONFIRMED WORKING ON THE YAS-209 (2026-07-30, by ear + IP readback).** With a working
emitter on **IR OUT 3**, Dave confirmed **power, mute and volume all drive the bar**. So the
YSP-1000 seed set (2005 soundbar) DOES carry over to the 2019 YAS-209 — Yamaha's system-code reuse
held.
**BUT THE AUTOMATED VERIFY SCORED THREE OF THEM "no effect" — A FALSE NEGATIVE, AND MY BUG.**
`Verify IR Codes` read mute and volume from **`YAMAHA_DATA_GET`'s `mute` / `Master volume`, and
NEITHER TRACKS.** The proof was already in its own log and had nothing to do with IR: the PREP
steps `setPlayerCmd:mute:1` and `setPlayerCmd:vol:40` are plain IP writes, and those fields did not
move for them either. Power scored correctly throughout because `power saving` genuinely tracks.
**Fixes:** volume/mute now read over **UPnP RenderingControl** (`GetVolume`/`GetMute`) — the
surface the driver already polls every 3s and the one validated on this bar — and the prep writes
go over that SAME surface, so a prep can no longer "succeed" against a field the check cannot see.
Added **`prep_expect`**: if the baseline is not where the prep aimed it, the code is reported
INCONCLUSIVE instead of scored. That guard is the generalisation of the one that DID fire (on
MUTE_OFF) and was the tell that exposed the whole thing.
**Lessons, both general:** (1) **verify the READBACK FIELD tracks before trusting any sweep built
on it** — an unverified instrument produces confident wrong answers, which is worse than no
answer; (2) **when a sweep disagrees with the owner's ears, suspect the sweep.** Also note the
harness could not have caught this: its simulated bar answered every field, so only real hardware
could show that `Master volume` and `mute` are inert. The offline harness proves LOGIC, not that
the chosen fields mean anything.
**PIVOT (Dave's call): per-code Action BUTTONS, not one automated routine.** Every code in
`<irsection>` now has its own Action (`IR: Power On/Off/Toggle`, `Volume Up/Down`, `Mute On/Off/
Toggle`) firing **exactly one** code — the number-then-string double fire was removed, since the
numeric form is now hardware-confirmed and a second burst would move volume twice or toggle mute
back. Judge by ear, one button at a time; clean up the buttons later. `Verify IR Codes` stays for
the automated pass but is no longer the primary instrument.

**PER-CODE BUTTON RESULTS (2026-07-30): 7 of 8 WORK.** POWER_ON, POWER_OFF, VOLUME_UP,
VOLUME_DOWN, MUTE_ON, MUTE_OFF, MUTE_TOGGLE all drive the bar. **Only POWER_TOGGLE (103) fails, and
it does not matter** — nothing in the driver routes to it (`SetPower` sends discrete ON/OFF, and
the receiver proxy is discrete too), so it exists purely as a declared code. Discrete is the right
model anyway: a toggle desyncs the moment anything else changes the bar.
**I UNDER-PORTED THE SEED SET AND SAID SO WRONGLY.** Dave challenged "you said these were the only
codes available?" — correct challenge. The YSP-1000 driver has **72 codes; only 8 were ported**,
and driver.xml carried a comment claiming input select and sound programs "must be learned from the
real remote". They were in the file all along. **48 unported codes have real patterns:** inputs
(TV/DVD/VCR/AUX), programs (PLII Movie/Music/Game, Neo:6 Cinema/Music, ProLogic), beam modes, night
mode, sleep timers, memory presets, menu navigation. **Lesson: when seeding from a donor driver,
inventory the WHOLE set and say what was left out and why — do not describe the subset you chose as
the set that exists.**
**11 CANDIDATES NOW PORTED as `IR?`-prefixed buttons** (distinct from the proven `IR:` set):
INPUT_TV, INPUT_AUX, INPUT_MODE_AUTO, NIGHT_ON/OFF/TOGGLE, SLEEP, SLEEP_OFF, BEAM_STEREO,
PROGRAM_PLII_MOVIE, LEVEL — ids and patterns verbatim from the YSP file for traceability. Chosen
because the YAS-209 plausibly has the FUNCTION even though the label differs; most will likely
miss, since the YSP's inputs and programs are not this bar's. **TEST MODE deliberately NOT ported:
it can leave the bar emitting test tones with no documented exit — not something to ship as a
one-click button.** A cross-check script confirms every declared `<ircode>` has exactly one Action
and one `IR` table entry, in both directions (19/19, no orphans) — same discipline as the
`surround_modes` id cross-check.
**Note the YSP file declares 16 ids TWICE, the second time with an EMPTY pattern**, so keying codes
by id naively picks the useless duplicate. Take the entry that carries a pattern.
**CAPTURED — IR IS NOW AT NEAR-PARITY WITH IP (2026-07-30). This supersedes every donor-code
guess below.** The 11 ported candidates were a **waste of Dave's time and I should not have shipped
them** — I predicted most would miss, and they all did (`SLEEP` turned out to be the same key as
power; the bar has no night mode). Dave captured the real remote by building a driver in Composer:
`research/receiver_YSP-209-IRtest_Receiver.c4i`, **22 codes, 20 with patterns** (Menu and Cancel
came back empty).
**The capture covers everything the 2005 donor structurally could not:** all four real inputs
(`HDMI` 1001, `TV-INPUT` 1002, `BLUETOOTH` 1003, `NET` 1004), **all six sound programs** (MOVIE
1007, TV-SURROUND 1008, MUSIC 1009, SPORTS 1010, GAME 1011, STEREO 1012), the three DSP switches
(3D SURROUND 1006, CLEAR VOICE 1005, BASS EXTENSION 1000) and **subwoofer trim** (Bass Up 143 /
Down 144).
**Donor codes were only ever working on receiver tolerance.** Where both sets share an id, the
patterns differ by **21 to 72 of 72 words** (103/106/107/139) — same command, different measured
timing. Captured patterns now replace them wholesale.
**KEPT FROM THE DONOR ON PURPOSE (Dave's call): the four DISCRETE codes.** The remote has only
`Power Toggle` and `Mute Toggle`; `POWER_ON` 101 / `POWER_OFF` 102 / `MUTE_ON` 137 / `MUTE_OFF` 138
have no key on it but are hardware-confirmed working, and discrete is what the receiver proxy and
any sane automation need — **a toggle desyncs the moment anything else touches the bar.** So the
driver ships BOTH: discrete for control, captured toggles as buttons. **General rule: where a
verified extended command exists beyond what the remote exposes, keep it.**
**WIRED, not just declared** — IR now drives: input select (was a hard REFUSAL before this),
sound-program select, the three DSP toggles, subwoofer trim by stepping from the last known value,
volume, mute and power. **Cross-check enforced in both directions: 24 `<ircode>` = 24 Actions = 24
`IR` table entries, no orphans.**
**TRANSPORT REMOVED ENTIRELY (2026-07-30, Dave's call — correct).** Play/pause/stop/next/previous
are gone from the driver: **the bar has no transport keys on the remote or the front panel**, they
exist only in the Android app for the bar's own built-in streaming, and **anything Control4 (or any
automation system) is controlling has its own transport on the SOURCE device** — the soundbar is
downstream of it. So the control was superfluous by construction, not merely unimplemented over IR.
UPnP `AVTransport` service, `Transport()`, the five Actions and the IR refusal all deleted rather
than left as dead code. **General lesson: before building a control, ask whether the DEVICE is the
right thing to aim it at** — a receiver sitting downstream of a source should not be growing
transport controls.

**STATE FEEDBACK FOLLOWS CONTROL METHOD — SETTLED BY THE OWNER (2026-07-30). DO NOT RE-DECOUPLE.**
Investigating "make sure state feedback works" found both polls gated on `Control Method == "IP"`,
so selecting IR switched off all feedback including the UPnP volume/mute poll (which needs no
certificate and no Owner Approved). **I proposed decoupling it** — feedback keyed on whether the IP
path is REACHABLE rather than on how commands leave — and briefly shipped that, arguing IR-out /
IP-back was a better hybrid. **Dave rejected it: "if the user is controlling it over IP, whether
wifi or ethernet, have state feedback. If controlling over IR, disable state feedback."** Reverted;
both polls are gated on Control Method again, plus the added `DeviceAddress()` guard.
**His reasoning, which is right:** a driver set to IR is controlling a device it is not talking to
over the network, and it should not quietly read state behind that choice. **An IR install is
one-way and the honest model is that the driver knows only the last command it sent.** A dealer
choosing IR is not running a cable to the bar, so no IP gets entered and there would be nothing to
poll anyway.
**I also got a fact wrong here and was corrected:** I asserted the YAS-209 is WiFi-only with no
ethernet port. **It has one and Dave is using it.** The claim never reached these docs, but the
lesson does: do not state a hardware fact about the owner's own equipment as established when it
has not been checked.
**Consequence to keep in mind:** IR volume is inferred and NOTHING corrects it — the pulse-toward-
target estimate in `SetVolumeLevelIR` is the only level the driver has while Control Method = IR.
Verified in the harness: IR mode issues 0 UPnP polls and 0 state reads; IP mode issues 8 and 2.

**"Current Input" SHOWED A WIRE VALUE, NOT AN INPUT NAME (2026-07-30, Dave spotted it).** With the
bar on TV, the property read **`optical`**. `UpdateProp("Current Input", sw)` was writing
`INPUT_MAP`'s value — the **Linkplay protocol token** — instead of the input's user-facing name.
Two things wrong with that: it exposes an internal wire string in a property a dealer reads, and
`optical` **names a physically separate input this bar does not have** — the optical jack is part
of the TV input, not a selectable source, which is precisely why the standalone "Optical In"
connection was removed earlier. Fixed with an `INPUT_NAME` table (TV (ARC / Optical) / HDMI In /
Bluetooth / Network / Streaming) whose entries are **cross-checked against driver.xml's
`<connectionname>` values**, since they are two hand-maintained lists that must agree. The wire
value is still logged, because protocol debugging needs it — it just must never be the thing shown.
**General rule: never surface a protocol token in a user-visible property.** The harness now
asserts the property is not one of the four wire strings, so this cannot come back silently.

**SHIPPING CLEANUP DONE (2026-07-30) — 36 Actions down to 3, ~600 lines of Lua removed.** Every
discovery and verification tool is gone from the driver now that what it discovered is baked in:
`Learn Input Codes`, `Learn Sound Programs`, `Learn Subwoofer Range`, `Probe Yamaha Settings`,
`Query Device Info`, `Verify IR Codes`, the 24 per-code `IR:` buttons, the duplicate `Power On/Off
(IP)` actions and `httpapi Diagnostics` (still called internally by the IP test). **The FINDINGS
survive in the driver — the six sound programs, the -4..+4 subwoofer range, `MODE_TO_CONN`, the IR
code set — only the machinery that found them is deleted, and that is recoverable from git plus the
method notes here.**
**KEPT, deliberately, three Actions:** `Refresh Now`; **`Test IR Emitter`** (fires one code with
nothing else in the path and dumps the IR binding state — keep this, working out that IR OUT 1 was
dead cost three sessions and it is the only tool that separates a wrong code from a dead
emitter/port on a one-way bus); and **`Test IP Connection`** (exercises cert, handshake, request and
parse in one press, the fastest way to tell a certificate problem from a network one).
**FOURTH ACTION ADDED: `Get Device Status` (Dave's ask).** Reads everything available right now
and prints what the driver ended up knowing, so nobody has to shorten `State Poll Seconds` to see
current values and then remember to put it back — that interval is slow BECAUSE every httpapi read
is a full mutual-TLS handshake, so temporarily speeding it up is the wrong fix. Three bugs were
caught building it, all the same family as ones already fixed here:
1. **It inherited the `State Poll Seconds <= 0` gate**, so it did nothing for exactly the user it
   was for — someone who disabled automatic polling. `PollHttpApiState(manual)` now skips the
   INTERVAL check only; Control Method / address / Owner Approved still apply, because those are
   about whether reading is permitted at all, not how often.
2. **It printed the DSP switches as `1`/`0`** — the wire value — instead of the On/Off the property
   shows. Same bug as `Current Input` showing `optical`, reintroduced within a day of fixing it.
   Now decoded through the table's own `dec`, so dump and property cannot disagree.
3. **`READONLY_SETTINGS` was pushed to the property but never recorded**, so `Audio Stream` read
   back as "unknown". Now stored in `gDeviceSettings` like every other setting.
**Also made `Connected` honest:** it is set by the UPnP poll, which does not run under IR, so it
sat at its last value and kept claiming a live link to a bar the driver had stopped talking to. It
now reads `n/a - IR control (one-way, nothing is polled)`. Under IR the status dump also states up
front that the values are **what the driver last SENT, not what the bar reports**.

**MUTE TOGGLE RESOLVED AGAINST A CACHE — FIRST PRESS DID NOTHING (2026-07-30, Dave hit it, and
his diagnosis was right).** The Control4 remote's mute button has no discrete on/off; it sends
`MUTE_TOGGLE`. The handler was `SetMute(not gMute)` — it inverted the driver's BELIEF about the
bar. Whenever that belief was stale or unknown (`nil`, so `not nil` = true = MUTE_ON) it commanded
the state the bar was already in, so nothing happened and the SECOND press worked because the
belief had flipped. **The status line looked correct while nothing changed**, which is the tell.
**Fixed differently per path, and the IR half is the more interesting one:**
- **IP:** read `GetMute` from the bar first, then command the opposite discretely. Cannot be wrong,
  because nothing cached is consulted. If the read fails it falls back to the belief and SAYS so.
- **IR:** send the remote's own captured `MUTE_TOGGLE` code (139). **State-independent by
  construction — the BAR decides what to flip** — so it is correct even though IR gives nothing to
  read back. Strictly better than choosing a discrete code from a guess, which is what it did
  before (verified: the old build fired `MUTE_ON`, the new one fires `MUTE_TOGGLE`).
**GENERAL RULE: never resolve a toggle against cached state.** Either read the device first, or use
a device-side toggle that does not need to know the current value. **`CycleInput` (PULSE_INPUT) has
the same shape** — it picks the next input from `gInputSw` — but it is far less harmful, since
cycling from a wrong position still moves and the user simply presses again.
**Honest limit on the testing:** the offline harness could NOT reproduce Dave's exact failure,
because its 3s poll refreshes the belief before the action runs, so both old and new builds
happened to land correctly there. What is verified is the behaviour change itself — the new build
issues a `GetMute` before commanding (log: "bar reports muted=..., commanding ...") and the old one
commands straight from cache, and the IR path now sends the toggle code instead of a guessed
discrete one.

**PROPERTY REMOVED: `Yamaha Volume`.** It surfaced `YAMAHA_DATA_GET`'s `Master volume`, which is
**proven not to track** — it read 24 across IP volume writes and IR presses alike, and is what made
the IR verification score working codes as failures. A readonly number that silently stops matching
reality is worse than no number; same call as withdrawing proxy bass. **`Audio Stream` MOVED, not kept as a property (2026-07-30, Dave: "it seems to have no purpose").**
He was right that it earns nothing in the Properties tab: it refreshed only on the 30s poll, was
visible only if someone opened that tab, and cannot drive programming since this driver declares no
property-changed events. **What it actually reports is the format the bar is decoding (PCM / Dolby
/ DTS)**, which answers exactly one useful question — is the TV bitstreaming over ARC or downmixing
everything to PCM, the usual reason surround "does not work" — so the VALUE is worth keeping. It is
now read into `gDeviceSettings` and reported by **Get Device Status** only, which is where a
diagnostic belongs. **UNVERIFIED: every capture so far reads `PCM`; whether the field ever changes
has never been tested.** One hardware check settles it — play genuine Dolby content over ARC and
run Get Device Status. If it still says PCM the field is inert and should go entirely.
**Harness note:** the archetypes that existed for the sweeps (`clamp`/`reject`/`acceptall`/
`irworks`/`noemitter`) now have no target and are kept only because the sweep code would need them
again if another model joins this umbrella driver. The harness still covers IR routing, property
control, the httpapi transport, the feedback gate, and the `Current Input` wire-value assertion.

**SHIPPING CONFIGURATION SETTLED (2026-07-30, Dave's decisions).** Six changes that together move
this from "owner's experiment" to something an integrator could install:
1. **IR is the DEFAULT and standard control method.** It needs no certificate, no network and no
   documentation.
2. **Serial REMOVED from the dropdown** — the bar has no serial port, so offering it only invited
   mis-configuration.
3. **The IP option is relabelled `IP - See Documentation for Usage`.** LIST items are free text, so
   a dropdown entry can carry its own signpost. `driver.lua` now normalises on the leading `IP`/`IR`
   token rather than matching the whole label, so the wording can change without a code edit —
   comparing full labels is exactly how a UI text tweak silently disables a control path.
4. **`Test IP Control Compatibility`** replaces the old httpapi test and answers ONE question in the
   Lua window: does THIS unit accept the certificate this driver ships? `COMPATIBLE` prints the
   model and firmware; `NOT COMPATIBLE` says the cert is no longer accepted and to use IR. All three
   verdicts (compatible / rejected / no address) are harness-tested, via a new `certfail` archetype
   — the failure branch is the one that matters and it would otherwise have shipped unexercised.
5. **Documentation fully rewritten**, including `www/documentation.rtf`, which is the dealer-facing
   doc Composer shows and which the new dropdown label points at. It has an **IP Control** section:
   a short paragraph on where the cert came from and the firmware risk, then a bulleted list of the
   test button and everything IP gives that IR cannot.
6. **`Owner Approved` REMOVED ENTIRELY.** It gated the gray-area IP path behind a consent toggle,
   but — Dave's reasoning — it is unlike anything in any other driver, easy to forget even for the
   person who built it, and its silent refusal was a repeat cause of "the driver does nothing".
   **The consent it represented is now carried by documentation**: the dropdown names the document,
   the document explains what IP control involves. **This is a deliberate departure from the repo's
   general "gate gray-area behind Owner Approved" convention** — the convention still stands
   elsewhere, but where a control method can be self-documenting in its own label, that is better
   than a toggle nobody expects.

**CERTIFICATE PROVENANCE — SETTLED BY INSPECTION (2026-07-30).** `subject = C=CN, ST=Shanghai,
O=Linkplay, CN=www.linkplay.com`, **self-signed**, `serial=01`, **no X509v3 extensions**, valid
2018-11-15 → **2046-04-01**. **Nothing device-specific** — no MAC, no serial, no per-unit id — and
the identity is **Linkplay's, not Yamaha's**. So it is one shared credential baked into the Linkplay
stack: **it should work on any YAS-209 with no re-extraction, and plausibly on other Linkplay-based
products** (WiiM, Arylic, Audio Pro and similar — unverified). Consequence: **time is not the
threat, only a deliberate rotation is** — and a rotation would break every device at once, not one.
**RE-AUTHENTICATION FROM INSIDE THE DRIVER IS IMPOSSIBLE, checked not assumed:** `NetPortOptions`
carries only `return_encoding`/`key_encoding`/`iv_encoding`/`data_encoding`/`padding`; **no
DriverWorks API supplies a client certificate at runtime**; Director reads the cert from the
driver.xml paths; the `.c4z` is read-only; and mutual TLS means the bar demands a cert, never issues
one. The Encryption Interface (`LoadPKCS12`/`GenerateCSR_*`) manipulates cert DATA but cannot bind
it to a connection. **Open question worth one test if it ever matters:** whether `<certificate>` can
point at a writable Director filesystem path rather than one inside the archive — if it can, a
paste-a-PEM-into-a-property flow becomes possible. Recovery today = re-extract, rebuild, update.

**FIRMWARE UPDATE OVER httpapi — POSSIBLE, DELIBERATELY NOT BUILT.** Linkplay exposes the whole
flow on the same transport: `getMvRemoteUpdateStartCheck`, `getMvRemoteUpdateStart` (download AND
burn), `getMvRemoteUpdateStatus` (40 new version / 10 checking / 21-23 failures / 25 downloading /
27,30 burning), `getMvRomBurnPrecent` (`{"status":"0","progress":"50"}`). **Not shipping the burn:**
a failed burn can brick the bar and an Action invites clicking it and walking away; **firmware
update is the single most likely thing to rotate the certificate**, so building it without a
recovery path is building the hazard without the mitigation; and this firmware has prior RCE
scrutiny (WithSecure advisory). **Check-only is the safe half** and is the agreed direction if
revisited.

**COMPOSER POPUPS: NOT POSSIBLE, and the better answer is events.** No DriverWorks API displays a
dialog in Composer — only `SendDataToUI`/`SendUIRequest`, which target Navigator. Verified against
the catalog: no shipping driver does it. **The idiomatic mechanism is a declared `<event>` fired
with `C4:FireEvent`/`C4:FireEventByID`** — confirmed on a shipping third-party driver (Venstar
declares `Error` and `Thermostat Offline`) — which appears in Programming as a trigger, so the
owner can wire a push notification, a Navigator announcement popup, an email, anything. **Our driver
declares ZERO events; that is a real gap.** For THIS project Dave's call is that a user-facing
notification is not wanted and the **Lua/log window is the target**, so events are not being built
now — but the mechanism is recorded because it is the answer whenever driver-originated alerting is
needed.
**`build.sh` gap found and fixed:** version auto-bump compared only `driver.lua`/`driver.xml`, so a
**documentation-only change shipped without a version bump** and Composer would refuse it as
"versions are equal" while the dealer kept reading the old docs. It now compares packaged `www/`
content too.

**STATUS PROPERTIES NOW GATED ON IP (2026-07-30, Dave spotted the confusion IR-by-default would
cause).** With IR the default, the five read-only status fields (`Connected`, `Power State`,
`Current Input`, `Current Volume`, `Muted`) would have shown the last value the driver SENT — a
guess wearing the clothes of a status field, and the first thing a new installer would see. They
now read **"IP Control Only - see documentation"** under IR (that is also their driver.xml default,
so a fresh install shows it immediately) and are populated only under IP. `UpdateStatus()` replaces
the direct `UpdateProp` calls for those five, and `ResetStatusProps()` runs on every Control Method
change so switching modes never leaves yesterday's text sitting there. Same principle as removing
`Yamaha Volume` and fixing `Current Input`: **do not display something the driver cannot stand
behind.**
**DOCUMENTATION IS NOW THE FULL REFERENCE, not just an IP note.** `www/documentation.rtf` (the
dealer-facing doc Composer shows) rewritten end to end: Quick start, Connections, Control Method,
IR Control, IP Control, **every one of the 17 properties grouped by purpose**, all 4 Actions, and
Troubleshooting. **`build.sh` now WARNS when a property or Action is missing from it** — verified
by adding a dummy property and watching it flag, then removing it. Documentation drifting from the
driver surface was a recurring failure this session (the RTF still described transport, Owner
Approved and "IR/Serial placeholders" long after all three were gone), so the check exists to make
that drift visible at build time rather than at install time.

**OPEN, UNTESTABLE FOR NOW: are the DONOR discrete power codes valid from DEEP standby?** The
YAS-209's remote has no discrete power key, so `POWER_ON` 101 / `POWER_OFF` 102 / `MUTE_ON` 137 /
`MUTE_OFF` 138 are the four codes kept from the 2005 YSP-1000 donor. They are hardware-verified,
but **only ever from NORMAL standby** — never from a cold bar. If the cold-start fault (below)
turns out to be reproducible over IR too, a donor code that does not reach deep standby is a prime
suspect, and the captured `POWER_TOGGLE` 103 would be the fix. **Cannot be tested at present: Dave
has removed the IR emitter from the bar** and is running IP. Three single-code power Actions were
added for this and then REMOVED again the same day, because shipping diagnostics for a hypothesis
nobody can currently test is exactly the clutter the cleanup existed to prevent. Recorded here so
the question is not lost.

**STATE FEEDBACK NEVER REPEATED — THE POLL TIMERS WERE ONE-SHOT (2026-07-31). This is why state
feedback was "never observed working".** Both polls did
`C4:SetTimer(ms, fn, false)` and re-armed themselves by calling `timer:Reset()` from inside their
own callback. **`bRepeat` defaults to false, and whether `Reset` restarts an ALREADY-FIRED one-shot
is undocumented — the evidence says it does not.** So each poll ran once at startup and then stopped
forever. Measured in the harness: the old build issues 2 state reads (a single cycle) and no
repeats; fixed, it issues 8. Both now pass **`bRepeat = true`**, which is what Control4's own
drivers do (Pioneer uses `C4:AddTimer(interval, units, repeating)` with an explicit flag).
**Symptom that exposed it:** Dave watched `Current Input` sit on "HDMI In" while the bar had
physically switched to TV/ARC, and it only corrected when he ran `Get Device Status` by hand — i.e.
the only remaining code path that reads the bar. It also explains the long-standing "power/input
feedback has never been seen tracking an external change", and quite possibly the volume drift.
**THE HARNESS COULD NOT HAVE CAUGHT THIS AND THAT WAS MY BUG:** its `C4:SetTimer` stub ignored
`bRepeat` and fired every timer exactly once, so a timer that never repeated on hardware looked
identical to one that did. The stub now honours `bRepeat` (capped so the sim terminates) and its
`Reset` is deliberately a **no-op**, so the sim can never again assume behaviour the docs do not
promise. **General lesson: a stub that is more forgiving than the real API converts a real bug into
a passing test.**

**INPUT-ON-WAKE: THE TIMING THEORY IS CONFIRMED, AND THE CHECK MEANT TO CATCH IT WAS DEAD CODE
(2026-08-01).** Room-on log: at 07:32:35 the driver sent `switchmode:HDMI` about one second after
power-on; the bar answered **200**; the poll at 07:32:59 reported **`mode 43` (optical)**. A second
attempt at 07:33:15 with the bar already awake gave `mode 49` (HDMI). **So the input command IS
discarded while the bar wakes, and the 200 hides it** — the "a 200 OK means nothing on this device"
rule, now demonstrated on the input path too.
**The verification added to catch exactly this never executed.** `VerifyInput` calls `jsonstr`,
declared 140 lines later; **a local used before its declaration compiles to a GLOBAL lookup, nil at
runtime**, so the readback fired, the reply arrived, and the callback died before logging a verdict
or resending. Fixed by moving it after `jsonstr` with real forward declarations.
**THIRD OCCURRENCE of nil-at-runtime names in this project** (`C4:Log`, `C4:ReadFile`, now
`jsonstr`) and **`luac -p` cannot see any of them**, so `build.sh` now runs `scopecheck.py`, a
static check for file-level locals used before declaration. Validated against the broken build
(correctly reports `jsonstr` used line 847, declared line 978). **Two bugs in the CHECKER itself
were found and fixed before trusting it:** block-scoped locals produced false positives, and a
string-stripping regex that could span newlines silently renumbered the file so it reported
nothing. **Never adopt a checker without running it against a known-bad input.**
**STILL OPEN — and probably not ours:** the TV does not switch to HDMI 1 on wake, and a plausible
mechanism now is that **the bar AUTO-FOLLOWS the active signal**: with the TV sitting on HDMI 4
(Shield) its ARC output keeps the bar on optical, so the bar reverts no matter what we command.
That makes the TV's input the root cause and the bar's behaviour a symptom. The retry will now say
so out loud rather than failing silently.

**REGRESSION I INTRODUCED AND THEN FIXED: DISCONNECT_OUTPUT IS NOT A POWER COMMAND (2026-08-01).**
Wiring `CONNECT_OUTPUT`/`DISCONNECT_OUTPUT` to power (build 49) made the bar **switch itself off**
whenever the user selected a source that bypasses it. Dave's report was blunt and correct: the
driver worked WORSE than before.
**Why:** this bar is only in the VIDEO path for sources plugged INTO it. Choosing the Shield --
wired straight to the TV -- takes the bar's HDMI output out of that path, so Control4 sends
`DISCONNECT_OUTPUT` **with no `OFF`**, while the bar must stay ON to keep playing that source's
audio back over ARC. Visible in his log at 07:33:07: `cmd=DISCONNECT_OUTPUT` followed immediately
by `power saving:0`, with no `OFF` anywhere.
**Where my reasoning went wrong:** I copied the pattern from Control4's own receiver driver, which
genuinely does drive power from these. But that is a **multi-zone AVR that every source passes
through**, so its outputs only disconnect when the zone truly shuts down. **A soundbar sits BESIDE
the TV, not in front of it** -- the topology assumption silently failed to transfer. Power belongs
to `ON`/`OFF` alone.
**Why the harness missed it:** every test drove ONE command. The bug only exists in a SEQUENCE
(`ON -> CONNECT_OUTPUT -> DISCONNECT_OUTPUT`), and each command in isolation looked right. The
harness now takes `SEQ:CMD,CMD,CMD` to replay a whole room interaction and prints the power
commands actually sent. Verified: build 54 emits `ON -> OFF`, the fix emits `ON`; a real room-off
still emits `ON -> OFF`. **General lesson: proxy commands arrive as sequences, so testing them
individually can pass while the interaction is broken.**

**REMAINING IR LIMITS, both inherent to one-way IR and neither now costing feedback:** absolute volume is approximated by
pulsing (no absolute IR code exists), and the three DSP switches are **toggle-only over IR**, so
the driver flips them and SAYS it flipped rather than claiming it set an absolute state.
**`INFO` (120), `POWER_TOGGLE` and `MUTE_TOGGLE` are declared and buttoned but deliberately routed
to nothing** — they exist for manual use, not for control paths that need determinism.

**SUPERSEDED: capture from the real remote.** No amount of porting from a 2005
bar can produce codes for functions the YAS-209 has and the YSP-1000 did not — its six sound
programs, HDMI/Bluetooth/Network inputs, subwoofer trim.

**SUPERSEDED: whether the YSP-1000 codes drive the YAS-209 —** Untested, because the only
working emitter is at the TV and not aimed at the bar. **A working emitter must be physically at
the bar's IR window before `Verify IR Codes` means anything** — an unaimed emitter fails every code
and is indistinguishable from a wrong code set (exactly what the report's "check the emitter FIRST"
warning exists for). Borrowing the TV's emitter for one run is enough; it need not be stuck down.

**SUPERSEDED (kept for the reasoning) — a positive control with a Control4-authored driver.** Add the stock **Yamaha
YSP-1000** IR driver (`receiver_ir_yamaha_ysp-1000.c4i`, av_gen, from the online database), bind it
to the SAME IR output, fire its Power. Blink = the controller's IR path is fine and the fault is in
our lua_gen SendIR path. No blink = the controller port/emitter is the fault and our driver is
exonerated. It also happens to test the SAME code ids (101/102/...) our set was seeded from, so a
working blink would answer the code-validity question in the same step. **Do this before writing
any more driver instrumentation** — the driver has now been instrumented past the point of
diminishing returns, and the remaining unknown is outside it.

**"VERSIONS ARE EQUAL" ON UPDATE — TWO DIFFERENT VERSIONS, AND THEY HAD DRIFTED (2026-07-29).**
Dave hit "versions are equal" updating the driver, and reported Composer showing **2.1.0** while
the package said 6. Both observations were right, because a Control4 driver carries **two
unrelated version strings**:
1. **`<version>` in driver.xml** - a plain INTEGER (was 5, now stamped automatically). **This is
   the only one Composer compares on Add/Update Driver**, and the only one that decides whether
   new code loads.
2. **A "Driver Version" PROPERTY** - our own cosmetic readonly string, hardcoded `2.1.0` in BOTH
   driver.xml (default) and driver.lua (`UpdateProp`). **This is what Composer DISPLAYS**, and it
   was hand-maintained, so it froze at 2.1.0 while `<version>` climbed 3->4->5 and the code moved
   on. The number on screen had not tracked reality for four builds.
**So "Composer is reading 2.1.0" is the display property, not the update comparison.** If the
update still refuses, the .c4z Composer opened is genuinely still `<version>` 5 - i.e. a stale
copy (OneDrive not yet synced into the Windows VM, or an older file transferred earlier). **The
Mac's built artifact was verified as the new version at the time; check WHICH FILE the VM is
opening before touching code.**
**FIXED SO IT CANNOT DRIFT AGAIN — one stamp, three places.** driver.xml's property default,
driver.lua's `UpdateProp`, and the load-line log are now all the token **`@BUILD@`**, replaced at
package time by `build.sh` with `v<version> build <sha8>` (fingerprint over driver.lua+driver.xml).
The build FAILS if the token is missing, because a version display that can lie is worse than
none. `build.sh` also **auto-bumps `<version>`**: if the driver content changed but the version
did not, it increments (an unchanged rebuild keeps its number, so iterating does not churn it) -
the forgotten manual bump was the root cause. The build now prints the version, fingerprint and
package sha, and the driver logs the same string through the unsilenceable path on load, so
**"did Composer actually take my file" is answerable in one glance** instead of being guessed at.
**Never hardcode a version string in this driver again.**

**EQ: BASS TRIED VIA THE PROXY AND WITHDRAWN (2026-07-28) — subwoofer is a PROPERTY instead.**
**The receiver proxy cannot declare a bass RANGE** — there is no bass equivalent of
`volume_number_of_steps` in its capability set. With `has_*_bass_control` declared, Composer renders
an **UNBOUNDED number box** (Dave held the up arrow past 1000) while the bar accepts only -4..+4, so
the driver clamps and the on-screen number becomes fiction. A control that misrepresents its own
range is worse than none, so bass capabilities + `SET_BASS_LEVEL`/`PULSE_BASS_*`/`BASS_LEVEL_CHANGED`
were REMOVED (not left as dead code), and the subwoofer is now the **`Subwoofer Boost`** property
(`RANGED_INTEGER` -4..4), which Composer bounds correctly. **Do not re-add
`has_discrete_bass_control` without solving the range problem.** The 0-100-vs-native scale question
is moot and gone with it. General lesson: check whether a proxy can express a control's CONSTRAINTS,
not just its value, before mapping onto it.
**Superseded note (kept for context):** `Learn Subwoofer Range` ran on
hardware: **range is -4..+4 signed, 0 = flat** (5 and -5 both refused, bar held 4/-4; negative
control passed). **INDEPENDENTLY CONFIRMED** — Dave then opened the Yamaha app and its Subwoofer
Boost scale is also ±4. Two independent methods agreeing is the strongest validation available
without vendor docs, and a good sanity check on the learn-by-readback technique generally. Baked into `SUBWOOFER_RANGE` and wired to the proxy's BASS control
(`has_discrete_bass_control` + `has_up_down_bass_control`, `SET_BASS_LEVEL`, `PULSE_BASS_UP/DOWN`,
`BASS_LEVEL_CHANGED`). **Treble/balance/loudness stay undeclared — the bar has no such controls**,
and declaring them would give dealers sliders that silently do nothing.
**UNVERIFIED ASSUMPTION in the bass path:** Control4 declares NO bass scale (there is no
`bass_number_of_steps` capability) and the `SET_BASS_LEVEL` doc omits its level param entirely
(`BASS_LEVEL_CHANGED` documents `LEVEL`, so it is a doc bug). We assume **0-100 with 50 = flat**,
the convention when no steps are declared. The first 5 `SET_BASS_LEVEL` calls LOG THE RAW incoming
value — **one drag of the slider confirms or refutes it**; if it is actually native (-4..4), only
`C4BassToNative`/`NativeToC4Bass` change. Mapping unit-tested: all 9 native values round-trip, 50
maps to flat, out-of-range clamps.
**Echo-loop guard (important if editing this):** reading a setting updates its property, which
fires `OnPropertyChanged`, which would send it straight back. Two guards: `gInitDone` (Composer
walks every property on load — without it the driver would push its DEFAULTS onto the bar on every
single load) and a per-key compare against `gDeviceSettings` (the last value the BAR reported), so
only a genuine user edit writes.
**SOUND PROGRAMS — all six ACCEPTED (2026-07-27):** `movie`, `music`, `sports`, `game`,
`tv program`, `stereo` (lowercase, space in `tv program`). Written then read back; the bar reported
each correctly, so no pruning was needed.
**NEGATIVE CONTROL PASSED (re-run, same day) — so the all-pass is REAL evidence, not an echo.**
Writing `c4_not_a_real_program` returned HTTP 200 `OK` (the write is always acknowledged) but the
bar then reported `movie` — it kept its previous value and silently discarded the junk. The field
is validated device-side. **Two transferable lessons: (1) a `200 OK` on a write means NOTHING on
this device — garbage is acknowledged exactly like a valid value, so only the READBACK
distinguishes them; (2) every learn-by-readback sweep needs a deliberate junk value or an all-pass
is unfalsifiable.** Apply both to the next locked device.
**Other finds:** `Model name`=`YAS-209` is the trustworthy model string (vs `getStatusEx`'s bogus
`project`=`YAS_109`); `Master volume` (24) is NOT the UPnP 0-100 scale (Linkplay `vol` read 63 at
the same moment) — relationship unresolved, so it is display-only; `NET Standby`/`HDMI Control`/
`Auto Power Stby`/`voice control`/`Dimmer` exist but are not exposed yet.
**EQ — CLOSED, NOT PURSUING (owner's call, 2026-07-29). Do not re-raise.** `getPlayerStatus`
carries an **`eq`** field (reads `0`) and Linkplay's generic API would write it via
`setPlayerCmd:equalizer:<n>`. But that is the LINKPLAY layer, not the Yamaha one: **Yamaha does not
expose any EQ**, in the app or in `YAMAHA_DATA_GET`, and the odds were that it is either inert or
affects only the network-streaming path (the Linkplay module handles only that chain, so HDMI/
optical would likely be unaffected). Dave's call: **Subwoofer Boost already covers the need and the
bar sounds good as-is — not worth digging further.** The field stays documented in case it ever
matters; it is not a TODO. `setPlayerCmd:*` writes return a 2-byte `OK` with HTTP 200.
The JSON parser is unit-tested against BOTH real payloads (space-containing keys, parenthesised
keys like `DSP(AC)`, and a substring-collision guard).

**OPTICAL IN REMOVED (housekeeping, user-spotted).** The bar has ONE optical/ARC input and Linkplay
exposes ONE `switchmode` for it (`optical`) — the same target the TV input selects, so the separate
"Optical In" (conn 3002) was a duplicate control for the identical source. Inputs are now TV
(ARC/optical) 3000, HDMI In 3001, Bluetooth 3003, Network 3004.

**SURROUND / EQ — cannot be built without a capture; probe action added instead.** `YAMAHA_DATA_GET`
is a known read command but **its response was never captured**, so the Yamaha-specific key names
for surround/EQ are unknown and guessing them would ship broken UI. New Action **Probe Yamaha
Settings** dumps raw payloads of `YAMAHA_DATA_GET` + `getPlayerStatus` + `getStatusEx`; run once per
surround mode / EQ preset / input and **diff — the fields that move are the ones to drive**. Note
`getPlayerStatus` already carries an `eq` field, so EQ is likely `setPlayerCmd:equalizer:<n>`.

**SDDP AUTO-DISCOVERY — answered: true SDDP is NOT achievable, and it is not a driver-side
limitation.** SDDP is *device-side*: the bar itself would have to broadcast announcements naming
the driver (`driver`/`primary_proxy` are fields IN the announcement), which needs Snap One's SDDP
SDK under a signed licence and would have to live in Yamaha's firmware. **However, Director's
discovery is not SDDP-only** — `C4:GetDiscoveryInfo(binding)` documents **SDDP, DDDP and UPNP**,
returning uuid/ip/model/manufacturer/name/location for UPnP-discovered devices, and this bar IS a
UPnP MediaRenderer with a stable `upnp_uuid` (`FFB8F002-0E74-2090-E14B-CD76FFB8F002`). **So the
realistic feature is auto-CONFIGURATION, not auto-discovery:** have the driver self-locate via
SSDP/UPnP (match on that uuid or the Linkplay model string) and auto-populate the IP Address
property, which also self-heals when DHCP moves the bar. NOT BUILT. Open question if resumed: how
far Composer's own "Discovered Devices" list goes toward binding a UPnP-discovered device to a
custom driver, vs. the driver simply self-locating. Also relevant: `C4:SendBroadcast` exists (UDP
broadcast, `SO_BROADCAST`) though SSDP M-SEARCH is normally multicast — verify the multicast path
before committing to a design.

**`getStatusEx` RULED OUT FOR STATE (2026-07-27, proven not assumed).** Dave captured it at five
different physical inputs; programmatic diff = **identical except the clock (65 of 66 fields)**, and
the payload has NO `mode`/`source`/`input`/`eq`/`surround` key at all. It is an identity/capability
dump, full stop. Input state is in **`getPlayerStatus` (`mode`)** — which is why the `Probe Yamaha
Settings` Action exists; `Query Device Info` will never show it. Action renamed to say so, and the
driver now logs that caveat after every `getStatusEx` dump. **Do not re-test this.**

**CERT PROBE REMOVED ENTIRELY — Lua cannot see inside a `.c4z`, period.** `C4:ReadFile` doesn't
exist, and `C4:FileExists` **also returns false** for a bundled file; both were observed reporting
"cert missing" on runs whose handshake SUCCEEDED. Only Director reads the archive (via the
driver.xml paths). There is no Lua-side probe that can be truthful, so the per-request check is
gone rather than merely demoted — a cert warning that fires on a working system is worse than no
warning at all.

**NEXT (in order):**
0. **IR bringup, in this exact order** (all four fixes above are written + harness-verified but
   NOT yet run against the bar). Back up the project first. **Before touching code, check the
   PROPERTIES** — the re-add that added the IR connection reset them: `Owner Approved` must be
   `Yes`, `IP Address` must be set, `Log Mode` = `Print and Log`, `Log Level` = `3 - Info` or
   higher. (The new bringup output no longer needs the log settings, but everything else does.)
   Then: (a) run **`IR Emitter Test: Power On`** and watch the emitter — a blink clears the
   physical side, no blink means the binding/emitter is the problem and no code change will help;
   (b) only if it blinks, run **`Verify IR Codes`** (Control Method can stay IP) for an objective
   per-code verdict; (c) if codes fail, that is now trustworthy evidence the YSP-1000 patterns do
   not match this bar → capture from the real remote (item 4).
1. **Re-run `Learn Sound Programs`** — only to see the negative control land (should print
   "negative control OK: nonsense value was rejected"). If it instead prints NEGATIVE CONTROL
   FAILED, the all-pass above is meaningless and the modes need checking by ear.
2. **Spot-check the settings properties** (Sound Program / 3D Surround / Clear Voice / Bass
   Extension) write correctly from Composer, and confirm power/input feedback tracks an EXTERNAL
   change — the whole point of the state poll, still never observed working.
   **REMOTE FOUND (2026-07-28) — but its battery is on order, so it is not usable yet.** Until it
   arrives, use any of: (a) the **Yamaha/Linkplay phone app** — already installed, it is where the
   client cert came from (`com.wifiaudio.Yamaha`), so it is the easiest; (b) the bar's **top-panel
   touch buttons**; or (c) **HDMI-CEC from the TV**. Any of them proves the poll reconciles state
   it did not originate. (Partial evidence already exists: during the subwoofer sweep the poll
   logged `input changed at the bar -> optical` and `power changed at the bar -> On`, i.e. it
   picked up state the driver had not set — but that was reconciling from *unknown*, not tracking
   a genuine external change.)
4. **IR as the shipping default** control method (per the original design: IP is the owner's path,
   IR is what ships to dealers). **REMOTE FOUND 2026-07-28 (battery on order), so learning codes
   by CAPTURE is back on the table** — this supersedes the earlier "remote is lost, database only"
   plan. Two sources now, and they check each other: (a) **capture from the real remote** once the
   battery arrives (authoritative for THIS unit, and the only way to get codes for buttons no
   database happens to list); (b) a **code database** — Control4's own IR sets for YAS-209 or a
   sibling Yamaha bar, or a public set (Global Caché, iRule/JP1) — which is faster to try first and
   may simply work.
   **Either way, verification is the same and is the nice part: the IP path is the test instrument
   for the IR path.** Fire an IR code, then read state back over mutual TLS and see whether it
   actually landed — objective ground truth per button, no listening-by-ear required. Building IP
   first turned out to be the right order.
5. **Optional:** UPnP self-location for auto-IP (above); `uart_pass_port` 8899 (UART passthrough to
   the MCU — the likely route to DSP/sound-mode control httpapi does not expose); the 6 hardware
   presets (`preset_key: 6`).

The extracted client cert (`linkplay_client.pem`) and the `.c4z` are **gitignored** (gray-area;
regenerate the cert via LINKPLAY_RE.md, then `./build.sh`). `research/DESIGN.md` is the superseded
superseded FIRST-architecture (YXC) design, kept for reference. `Yamaha-YAS209/README.md` was rewritten 2026-07-27 (it still
described the dead v1 YXC premise) and now carries the per-project status, the two-surface
explanation, the build/fallback procedure, and the bringup checklist.

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
    modeled/editable). ~~Driver files have no static `<properties>` schema~~ **[CORRECTED
    2026-07-13 — this was WRONG: the PARENT device driver (`.c4z`/`.c4i`) DOES declare a full static
    `<properties>` schema (name/type/items/min/max/default/readonly), direct-child or under
    `<config>`; only the PROXY drivers like light_v2 lack it. `drivers.py` now parses it; values
    live in the item state under `<properties>/<property>`. See the "MAC SESSION PROGRESS" #2c-
    REFRAMED entry. Dynamic/Lua properties are a small residual, not the whole problem.]**
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

- **GAP #2 (property/config write-side) — STARTED: generic state editor DONE (Mac-side machinery).**
  `c4proj/state.py` `StateEditor` reads/edits an item's `<state>` blob (escaped XML; ET unescapes on
  read, re-escapes on save). Path notation matches `c4proj diff`: `/TAG/CHILD` with `[i]` on
  repeats (e.g. `/BUTTON_LIST_INFO/KEYPAD_BUTTON_INFO[1]/BUTTON_ID`). API: `fields()`, `get`, `find`,
  `set` (creates missing single-occurrence ancestors/leaf), `append`/`remove` (repeated structures),
  `init_root` (for empty/skeletal items, e.g. agents), `flush`. Module helper `edit_state(model,
  item_id)`. Tested end-to-end: read, set existing+new+nested, append/remove keypad buttons,
  full save+reload round-trip, correct escaping (no raw `<State>` leaks into project.xml).
  CLI added: `c4proj properties <c4p> <item_id>` (read) and `c4proj set-property <c4p> <item_id>
  <state_path> <value> -o out.c4p [--yes]` (write, with the identity-card confirm). Both exercised.
  - **VM test — PASSED (2026-07-13). Director PRESERVES edited property values on load.** Loaded
    `test projects/state-edit-property-test [MAX_ON_LEVEL=77].c4p` (capture-12 base, item 16 dimmer
    MAX_ON_LEVEL 100->77); backed up; diff of item 16's state: **27 fields in -> 27 out, nothing
    added/removed, MAX_ON_LEVEL=77 survived, no other value changed** (1-byte state-size delta was
    whitespace normalization only). **Complete state rule now empirically established:** empty/
    skeletal state -> Director fills driver defaults (Test B); PROVIDED/edited values -> Director
    preserves them exactly (this test). **=> the StateEditor approach to configuration authoring is
    VALIDATED end-to-end.** (Same benign "substituting driver" backup warnings as the controller
    compound — expected for file-synthesized projects, not a defect.)
  - **#2c REFRAMED — NOT a manual capture campaign (2026-07-13, user pushed back, correctly).**
    User's model: "install a driver in Composer, load it, and all its config options are ready to
    configure" — the config surface comes FROM THE DRIVER, not from manually capturing each op.
    Investigated and CONFIRMED this is exactly right, and it collapses #2c to metadata parsing:
    - **Property SCHEMA is driver-declared and parseable** — the driver's `driver.xml`/`.c4i`
      declares `<properties>` (direct child, or nested under `<config>`) with per-property
      `<name>/<type>/<items>/<minimum>/<maximum>/<default>/<readonly>` (types LIST/RANGED_INTEGER/
      STRING/LABEL/...). This is the Composer Properties view, verbatim. `drivers.py` now parses it
      (`Property` dataclass + `_parse_properties`). Coverage: 55/295 bundled `.c4i` proxies + **146
      of 417 Russell House devices** resolve a full property schema this way. **NO capture needed —
      sourced like commands/events already are.**
    - **Property VALUES live in the item's `<state>`** under `<properties><property><name>X</name>
      <value>Y</value></property>`, keyed by the same display name (NOT in `<state_values>`, which
      is vestigial/empty on all 118 RH items that have it). `StateEditor.driver_properties()` /
      `get_driver_property` / `set_driver_property` read+write them (create-if-missing); round-trip
      + VM-preserve already validated.
    - **Defaults + dynamic values materialize on Director load** (already proven) — so even
      dynamically-added (Lua `C4:AddProperty`) values come back in the state; the static parse
      covers the declared baseline and their schema.
    - `c4proj properties <c4p> <item_id>` now shows the MERGED config surface: driver-declared
      schema (type/options/default) joined with each property's current stored value, then the raw
      state fields. This is the "install driver -> options ready" surface, reconstructed offline.
    - **Residual (small, NOT manual capture):** fully-dynamic/conditional properties (appear based
      on other selections, Lua-driven) — their schema only fully materializes in a live driver
      instance; get them by reading back a Director-loaded instance's state (automatable), not by
      hand. And the proxy-layer config (keypad buttons, dimmer levels in `<State>`) is edited via
      the generic StateEditor path API (several such shapes already captured, e.g. BUTTON_LIST_INFO).
  - **Advanced Lighting scene helper — DONE + validated.** `c4proj/agent_config.py`
    `AdvancedLighting(model, agent_id)` with `add_scene` (auto scene_id), `add_member` (add a light
    load at a level), `set_togglable` (enables default toggle — creates the `<OffToggleScene>` under
    `all_off_toggle_scenes` + points the scene's `off_toggle_id` at it, auto-allocating the id), and
    `scene_names`/`flush`. Structures/defaults reverse-engineered from captures 15-18 (`<AdvScene>`
    under `all_scenes`; `<AdvSceneMember>` under the scene's `all_members` with an `all_elements/
    element` level/color block). **Validation:** rebuilding the "House Off" scene from the empty
    capture-15 agent (add scene + 2 loads + toggle) yields state that is **data-identical to
    Composer's own capture-18** — 0 differing leaf paths, matching element order; only residual is
    empty-element serialization style (`<x/>` vs `<x></x>`), which Director normalizes on load. This
    is the template for other agent-config recipes (scheduler entries, announcements, ...): decode
    the state sub-model from captures once, wrap it as a helper on StateEditor.

  **=> GAP #2 (property/config write-side) is now substantially COMPLETE:** generic StateEditor
  (VM-validated: Director preserves edits), driver-property schema+values (metadata-derived, no
  capture), and the first agent-config recipe (Advanced Lighting, data-identical to Composer). What
  remains is additive: decode more agent-config sub-models the same way as they're needed (each is a
  bounded ~1-capture-series task, not an open-ended campaign), and fully-dynamic Lua properties
  (read back from a Director-loaded instance). Backend is close to virtual-director parity for
  authoring.

**Still open after #2:** GAP #5 (2 null + ~8 raw agents; Ghidra now runs on the Mac).

## API COHERENCE PASS — DONE (2026-07-14), pre-UI

Before UI work, reviewed the c4proj surface and fixed the gaps that would fight a UI. The backend was
a set of validated PRIMITIVES with no cohesion layer, inconsistent return types/error handling, and
partial write coverage. Decision: UI is built last (with a design-focused tool consuming this as an
API), so a clean, consistent library contract matters. Changes:
- **`c4proj/project.py` — the `Project` facade** (the one object a UI binds to). Owns the
  open->edit->save lifecycle (wraps C4Package + ProjectModel + DriverLibrary), exposes every area
  (items/properties/bindings/variables/programming/agents) through consistent methods, tracks
  `dirty`, hands out ONE cached `StateEditor` per item (flushed on save — fixes the lost-update
  hazard), and raises one `ProjectError` on bad input. `Project.open(path)` / `with` / `save(out)`.
- **`surface_of(item_id) -> EditableSurface`** — the unified "editable surface of a selection": config
  properties (schema+values as `PropertyValue`, with `.is_valid()` validation), programmable API
  (commands/events/conditions), bindable connection points, current outgoing bindings, and whether a
  dedicated agent-config helper exists. One call replaces the UI hand-joining three resolution paths.
- **Consistency:** `model.py` gained `ItemKind` enum (named type codes, no more magic "6"/"8"/"9")
  + `Device.kind`; `Item` alias for `Device` (honest name); `Consumer`/`Variable` are now dataclasses
  (were bare dicts). Uniform error model (facade raises `ProjectError`; primitives keep None/bool).
- **Write coverage filled:** programming `remove_event_handler`/`replace_event_actions` (rules are now
  editable/deletable, not append-only); `authoring.remove_item` (subtree + its bindings), variable
  CRUD (`add_variable`/`set_variable_value`/`remove_variable`). `set_property` validates against the
  driver schema before writing (LIST membership, RANGED_INTEGER bounds, readonly).
- `__init__.py` now exports the facade as the primary API; CLI gained `c4proj surface <c4p> <id>`.
- **Tested end-to-end:** facade drives every area on a copied capture (surface, agent scene add,
  validated set_property incl. rejecting a bad LIST value, variable CRUD, rule add/replace/remove,
  remove_item, dirty transitions) then save->reload CLEAN with edits persisted. All existing CLI
  commands + earlier #3 controller-compound build re-verified against the changed model (no regress).
- **Intentionally deferred (additive, as the UI surfaces them):** Media area API (add streaming
  service/station — the one genuinely under-built functional area), move-item, undo/redo (likely a
  UI-layer concern), more agent-config helpers. `_AGENT_CONFIG_HELPERS` in project.py is the registry
  to extend as each agent's config sub-model is decoded.

**Backend is now a coherent application API ready for a UI to consume.**

### DEBUG LOGGING (2026-07-14) + DESIGN HANDOFF READY
- **Togglable debug logging** built (`c4proj/_logging.py`): off by default (NullHandler), enable via
  `c4proj.enable_debug_logging(path)` / API `POST /debug {enabled,path}` / env `C4PROJ_DEBUG=1
  [C4PROJ_DEBUG_LOG=...]`. Logs facade ops (open/save/set_property/remove_item/install_driver/add_rule
  w/ args) + API requests. Stdlib logging, no dep. Wire the UI "create debug logs" switch to it.
- **DESIGN HANDOFF PACKAGE COMPLETE** — `better_composer/design_brief/`: `README.md` (index +
  recommended process), `UI_BUILD_PROMPT.md` (the prompt), `API_REFERENCE.md` (contract+domain),
  `sample_data.json` (real payloads), `openapi.json` (33-endpoint machine-readable spec). Ready to
  hand to the design tool + the user's visual direction.
- **DECISION (user, 2026-07-14): API-server concurrency left OPEN deliberately.** The server holds one
  Project/session and the facade is NOT thread-safe; a UI must serialize its WRITE calls. Rather than
  add a request lock, the user chose to leave it open as a free check of the UI's own behavior (a UI
  firing parallel writes = a UI bug to catch). Debug logging helps distinguish "backend bug" from "UI
  concurrency." Do NOT "fix" this as an oversight — it's intentional; revisit only if it causes real
  pain during UI dev. Symptom to watch: intermittent corruption/errors only under rapid/parallel UI
  actions.
- **CONFIDENCE VERDICT (2026-07-14): READY for UI design.** Core (7 passes) + UI-enabler code (its own
  pressure pass, 4 bugs found+fixed) both at high confidence. Remaining unknowns are ERGONOMIC (only
  surface by building a UI against the API) — which is the reason to start now, not pressure-test
  further in a vacuum.

### Second review pass (2026-07-14) — UI-boundary hitches found + fixed
A deeper pass specifically for "what will fight a UI" surfaced three real hitches, all fixed:
- **Serialization boundary.** `EditableSurface`/`Item`/`Event`/`CodeItem` couldn't cross a JSON
  boundary (ItemKind enum wasn't JSON-serializable; the live read models carry ET elements +
  parent<->child cycles = infinite recursion). A web/design-tool UI must serialize. Added
  `project.jsonable()` (recursive dataclass/enum/list -> JSON), `EditableSurface.to_dict()`, and
  serializable snapshot methods `Project.tree_view()` / `rules_view()` (the live `tree()`/`rules()`
  stay for in-process editing). Binding/Variable/Consumer/Command/etc. were already serializable.
- **Agent programming vocab wasn't wired in.** `surface_of` on an agent returned 0 commands/events
  even though vocab was extracted (Ghidra) for ~13 agents — a programming UI would show every agent
  as un-programmable. Bundled the curated vocab as PACKAGE DATA (`c4proj/agent_vocab/*.json`, copied
  from research/) + new `c4proj/agents.py` `AgentVocab` loader that presents it as the same
  Command/Condition/Event types the driver resolver uses (handles BOTH curated schemas: legacy
  `commands:[{name,params}]` and modern `likely_commands:[str]`). `Project.resolve()` now falls back
  to agent vocab, so `surface_of` exposes agents uniformly. Verified: **9 of Russell House's agents
  now show real programmable vocab** (Media Sessions 42 cmds, Scheduler 9+6, Media Scenes w/ events,
  ...). Remaining agents = the known #5 data tail (no wiring change needed to add them later).
- **No stable rule handle.** Composer `<event>`s have no unique id and two rules can share a trigger,
  so a UI couldn't target one across a boundary. `rules_view()` now emits a session-stable `handle`
  per rule; `remove_rule`/`replace_rule` accept an Event OR a handle string.
- All committed/pushed. Serialization, agent-vocab coverage, and handle round-trip tested; existing
  CLI + facade re-verified, no regressions. `__init__` exports `Project/jsonable/AgentVocab/...`.

### Third review pass (2026-07-14) — create-flow blockers found + fixed
Reviewed by walking the actual end-to-end CREATE flows a beta UI must support. Found TWO real
blockers (both now fixed) plus two ergonomic gaps:
- **Add-device flow was broken end-to-end.** `add_device` only referenced the driver filename; it
  never installed the driver file into the package's `drivers/`, and the facade exposed no catalog
  search/download/install — so a UI couldn't do "search catalog -> pick -> add." Added
  `Project.search_drivers(query)` (live Control4 Solr catalog -> serializable DriverHits),
  `install_driver(hit_or_filename)` (downloads into the package's drivers/, md5-verified, re-indexes
  the DriverLibrary), `add_device_from_catalog(hit, name, room)` (one-call install+add), and
  `missing_drivers()` / `bundled_driver_files()`. **Verified against the LIVE catalog**: searched
  "Sony", installed `um_SonyLIV.c4z` into the package, added the device, driver resolves.
- **No new-project-from-scratch seed.** The facade only opened existing `.c4p`s; a UI "New Project"
  had nothing to start from. Shipped a tiny blank seed as package data (`c4proj/templates/blank.c4p`
  = the clean 1-item capture-01, 137 KB; a `!` exception added to `.gitignore`'s `*.c4p` rule so it
  tracks) + `Project.new(name=None)` classmethod. Verified: New -> add_controller compound -> rooms
  -> device -> save -> reload CLEAN.
- **`add_room` required a template room** (couldn't create the first room). Now `template_room_id` is
  optional: clones a given/auto-picked room, or synthesizes a fresh one from roomdevice defaults.
- **Programming rule builders weren't discoverable** (importable but not exported). `__init__` now
  exports `command/agent_command/set_variable/delay/break_/stop/if_/while_` + the `programming`
  module so a UI can construct rule actions from the top-level API.
- save() re-entrancy (edit->save->edit->save) confirmed working — not a blocker.
- All tested end-to-end (new project, live-catalog install+add device, first room, exported builder)
  + facade/CLI regression; committed/pushed.

**Verdict: no remaining backend blockers to a full, mostly-workable beta UI.** All five functional
areas + the core create flows (new/import project, add controller/room/device incl. from catalog,
configure properties, wire bindings, program rules incl. agents, edit/delete) work end-to-end
through one serializable facade. Residual is additive coverage (Media area depth, more agent-config
recipes/vocab, binding-legality validation) — build as the UI reaches it.

### Fourth review pass (2026-07-14) — stress/edge/error-surface; one real bug + one gap fixed
Reviewed by hammering the flows harder (heavy from-scratch builds, edge inputs, bad inputs, lightly
touched areas). Found ONE real bug and ONE genuine gap:
- **BUG (would break every UI-built conditional): `if_()` returns a LIST** (`[if]` or `[if, else]`,
  since else is a sibling codeitem), while every other builder returns a single `_Item`. So the
  natural `actions=[cmd, if_(...), delay(...)]` crashed (`'list' object has no attribute 'build'`).
  Fixed: `programming._flatten_actions()` expands list elements one level, applied in
  `add_event_handler` and `_Item.build` (covers top-level + nested then/else/body). Verified: mixed
  rules with if/else build correct sibling structure.
- **GAP: networkbindings (IP device addresses) weren't exposed at all.** 42 in Russell House
  (`addr=192.168.1.133`, uuid, ssdp, status) — a UI couldn't even display a device's IP. Added
  `model.NetworkBinding` + `ProjectModel.network_bindings()`, `Project.network_bindings()`,
  `EditableSurface.network` (per-device, serializable), and `set_network_address(device_id, addr)`.
  (Media area confirmed NOT a blocker: adding a streaming service = `add_device` with that driver,
  works via catalog; only the deep media-DB is additive.)
- **Error-surface audit PASSED:** 13 bad-input cases (bad ids, wrong item kind, bad rule handle,
  agent-on-non-agent, ...) all raise clean `ProjectError` — no raw crashes. Edge-item surfaces
  (project root/room/location) return empty surfaces without crashing. Unicode/special-char names
  (`Café & Bar <Main>`, quotes) survive XML round-trip. Remove-controller leaves a consistent,
  CLEAN-loading project. save() re-entrancy holds.
- Committed/pushed. `__init__` exports `NetworkBinding`; 37 exports total.

**Pattern note:** each successively deeper pass has found less (pass 3 = 2 blockers; pass 4 = 1 bug
+ 1 exposure gap, both minor). What remains is additive coverage and UX-decisions that only surface
while building the UI — appropriate to handle in-beta, not pre-UI blockers.

### Fifth review pass (2026-07-14) — programming primitives + edit-existing flows; 1 silent-write bug
Went after the programming compiler (every primitive vs Composer captures) and the edit-EXISTING-
content flows (where a UI spends most of its time). One real bug, now fixed:
- **BUG (silent wrong write): `set_property` targeted the driver-property `<property><name>/<value>`
  surface, but proxy state fields (a dimmer's `MAX_ON_LEVEL`, keypad button config) live as DIRECT
  `<State>` fields.** Calling `set_property("16","MAX_ON_LEVEL",55)` silently created a bogus
  `<property>` entry and DIDN'T change the real field — a UI would think the edit succeeded. Fixed:
  `set_property` now (validate=True, default) rejects any name that isn't a real config property
  (raises ProjectError instead of silently creating). Added `Project.set_state_field(item_id, path,
  value)` + `state_fields(item_id)` as the explicit, separate proxy-state-config surface (edits the
  raw `<State>` fields by path). Both device-config representations are now cleanly distinct:
  driver `<properties>` (set_property / surface.properties) vs proxy `<State>` fields (set_state_field
  / state_fields). ~equal split in practice (4 proxy-state vs 5 driver-property items in one capture).
- **Everything else validated:** all 11 programming primitives (command±params, set_variable, delay,
  break, stop, agent_command, if/else, while, if+AND, if+OR, nested if) build + reload CLEAN;
  `set_variable` output is STRUCTURALLY IDENTICAL to Composer's prog08 (`owneridtype="variable"`,
  `name="="`, param, display template). Edit-existing flows work: edit a real device's state field,
  add member to an existing scene, clone_device (independent state — verified), change_driver,
  remove existing binding, multi-item concurrent edits in one session (cached editors flush
  correctly), all save + reload CLEAN. Unicode/special-char content round-trips.

### Sixth review pass (2026-07-14) — least-tested surfaces (mm.db, file preservation, binding legality, churn)
Aimed at what prior passes hadn't touched. One footgun-guardrail fix; everything else clean:
- **FIX (footgun): `add_binding` did zero validation** — accepted a binding between two nonexistent
  devices, creating a dangling binding that breaks Director load. A UI with a stale/typo id would
  silently corrupt the project. Facade `add_binding` now validates both endpoints exist (raises
  ProjectError). Internal `authoring.add_binding` (used by the controller compound) left permissive;
  compound still builds fine.
- **File preservation across save — CLEAN:** `identity.db` + `mm.db` byte-identical; the 6
  `announcements/*.mp3` (custom audio) + `meta/manifest.json` + all 115 drivers preserved; only empty
  zip DIRECTORY-marker entries (`drivers/`, `meta/`, `announcements/`) are dropped (harmless — files
  read by path). project.xml manifest md5 refreshes correctly.
- **Heavy churn — CLEAN:** 40 add / 20 remove / 20 re-add devices + 15 vars + 15 rules -> 45 items,
  ZERO id collisions, reload CLEAN. Id allocation solid under churn.
- **`mm.db` characterized = NOT a blocker:** it's the media LIBRARY db (movies/songs/albums/playlists/
  broadcast) — EMPTY in the real project, runtime-populated by Director scanning media sources /
  streaming catalogs. A dealer never authors it. Media sources = `add_device`; room media lists =
  room `<state>`. Confirms the earlier "Media is additive" call.
- **Remaining known-additive (not blockers), for in-beta:** a binding class-COMPATIBILITY helper (a
  UI can compute valid targets from `surface.connections`; existence now validated), deeper Media,
  more agent-config recipes/vocab.

**Convergence: pass 3 = 2 blockers; pass 4 = 1 bug + 1 gap; pass 5 = 1 silent bug; pass 6 = 1
footgun-guardrail (mildest yet).** Findings shrinking in count AND severity each pass.

### Seventh review pass (2026-07-14) — CLEAN. No blockers, no bugs found.
Aimed at the last untested corners: driver-resolution edges, change_driver interactions, multi-save
durability, degenerate cases. Everything held:
- **`surface_of` swept across ALL 417 items: 0 crashes**; unbundled-driver items (51 of them),
  combo drivers, proxy subs all degrade gracefully and serialize.
- **`change_driver`** strips state (Director regenerates on load), drops the stale cached editor,
  works on a parent that has proxy subs.
- **9 edit/save cycles with a LIVE mid-session catalog install** (Roku) -> reload CLEAN.
- **Remove-room cascade** (removes room + all descendants + their bindings, consistent),
  **save-overwrite-in-place** (UI "Save" over the open file) then continue editing, **deep
  programming nesting** (if>while>if>cmd, depth 4), **variable conditionals**, **5000-char property
  values**, **400-char unicode names**, **degenerate empty project** (read/serialize/save on 1 item)
  — all CLEAN.
- **Shared-cached-editor invariant CONFIRMED:** `set_property` + `set_state_field` on the same item
  use ONE editor and both persist — the lost-update hazard is genuinely closed.
- **Only soft note (NOT a blocker):** empty/whitespace names are accepted (`rename("")`,
  `add_variable("")`). Doesn't crash or corrupt; name validation is conventionally the UI's job.
  Left as a UI-layer choice, not fixed as a backend finding. (If desired later, add a non-empty
  check to rename/add_* — trivial.)

**VERDICT: the backend passed a clean deep-review pass — no blockers to a full beta UI.** Six passes
of escalating adversarial review (create flows -> serialization -> stress/edge -> silent-write bugs
-> footguns -> resolution/durability edges) found progressively fewer, milder issues; pass 7 found
none. This pass made NO code changes (nothing needed fixing). What remains is purely additive and
best driven by the UI itself: Media depth, binding class-compatibility helper, more agent-config
recipes/vocab, optional name validation.

## PRESSURE PASS on the UI-enabler code (2026-07-14) — 4 real bugs found + fixed

The UI enablers below (delete-safety, connection_candidates, API server, decompiler) initially got
only happy-path tests. A dedicated adversarial pass (same rigor as the core's 7 passes) found FOUR
real bugs — all fixed + committed:
1. **Variable-conditional operator drift (pre-existing).** `_conditional_cmdcond` hardcoded `name="=="`
   for variable conditions, so `if var > 5` silently became `if var == 5` on any rebuild — a UI edit
   would corrupt logic. Fixed (use the passed operator). All 39 real Russell House rules now
   round-trip BYTE-IDENTICAL.
2. **`clean_references` clobbered by a stale cached StateEditor.** If a cached editor existed for an
   item whose `<state>` clean_references edits directly (UI viewed a room, then deleted a device that
   room references), the stale cache flushed on save and re-introduced the dangling ref. Fixed:
   `remove_item(clean_references=True)` flushes editors -> cleans -> drops caches. Verified 0 dangling
   after reload.
3. **API server unhandled 500s.** `Project.open` on a bad/nonexistent/non-zip path (FileNotFoundError/
   BadZipFile) and `add_device_from_catalog` with a bad filename (urllib HTTP 404) crashed to 500.
   Fixed: exception handlers map all client-caused errors -> 400 with a clean message; catch-all never
   leaks a stack trace. Every edge case in the suite now returns 4xx.
4. **`StateEditor.set` empty-path** silently set the state root's text — now rejects empty path.
- **Validated clean:** `connection_candidates` sweep (408 devices, 0.4s, 0 crashes; unscoped can be
  large on many-port devices — UI should scope by `connection_id`); decompiler FULL node-type coverage
  (real rules + a synthetic all-types rule with variable operators / AND+OR chains / nested while+if
  round-trip identical); API session lifecycle (double-open, new, op-after-close -> 409); broad
  read/serialize sweep 0 crashes. **UI-enabler code now at core-level confidence.**

## UI ENABLERS BUILT (2026-07-14) — designer-ready

Beyond the facade, built the glue + safety a beta UI needs (all tested + pushed):
- **API SERVER (`better_composer/api_server/`)** — FastAPI wrapper over the `Project` facade, the
  desktop app's backend **sidecar**. 31 endpoints (one open project/session), reads return the same
  JSON the UI binds to, `ProjectError`->HTTP 400, `/docs` interactive console. Includes an
  **action-JSON rule compiler** (`POST /rules` takes structured action nodes -> programming builders;
  also the shape a linked AI model emits). Boots under `uvicorn api_server.server:app`; verified
  end-to-end via TestClient + live uvicorn. Its `requirements.txt` (fastapi, uvicorn) is the ONLY
  dependency outside stdlib — kept isolated from the stdlib-only `c4proj` core.
- **`connection_candidates(id[, connection_id])`** (+ `ConnectionCandidate.as_binding_args`) — valid
  wiring targets (complementary provider/consumer endpoints sharing a binding class) so the
  Connections UI never proposes an illegal binding. Verified (TV HDMI inputs -> controller HDMI out).
- **Name validation** — rename/add_device/add_room/add_controller/add_variable reject empty/whitespace.
- Design brief refreshed (`design_brief/`): `sample_data.json` now includes references_to +
  connection_candidates shapes; API_REFERENCE points the UI at the running API server.

## UI BUILD PHASE — decisions (2026-07-14)

Backend is done; UI is next, built with a design-focused tool. Full brief in
`better_composer/design_brief/` (`API_REFERENCE.md`, `UI_BUILD_PROMPT.md`, `sample_data.json` = real
serialized payloads). Key decisions:
- **Architecture: cross-platform DESKTOP app** (Windows/macOS), React UI in a native shell (**Tauri**
  preferred; Electron fallback), with the validated Python `c4proj` backend bundled as a local
  sidecar (thin JSON wrapper = one endpoint per facade method, generated separately). DO NOT rewrite
  the backend.
- **Mobile/tablet-FORWARD (phase 2 goal, design for it now):** on-site programmers should eventually
  use iPads/tablets/phones (Composer Express is barely usable). Build desktop-first but make no
  desktop-only choices — responsive/adaptive, touch-first-friendly. Eventual mobile client talks to a
  backend (Python can't run on-device); React + adaptive keeps that cheap.
- **Interaction model: NO persistent tree-left/detail-right master-detail** (explicit anti-goal —
  user flagged it as a core Composer failure; I wrongly re-proposed it and corrected). Use a
  **focus+lenses** model: current object of focus travels with the user across the five areas
  (System Design/Connections/Media/Agents/Programming), navigated by search/command-palette, spatial/
  canvas, and/or AI — not a rigid tree. `surface_of(id)` is the portable "context bundle" that powers
  the focus view.
- **Programming: THREE modes over one engine** — visual drag-drop, advanced expression building
  (Composer-parity grammar), AI-driven NL — all compile to `add_rule`.
- **AI: LINKABLE, not hard-baked** — provider-agnostic "connect a model" setting (Claude or other);
  core editor fully works with no model linked; features light up when linked, consuming the same
  serializable project data + proposing reviewable actions.
- **SCOPE: Control4 OS 4+ only.** Disregard OS 3 and earlier (formats/agents/directors). Old DEVICES
  stay supported (legacy drivers run on OS 4 directors; catalog + backend handle old driver files).
  Our tool is file-based so — unlike Composer Pro — it needs no "pick OS version on open" gate; read
  director version from `identity()`, preserve it, align driver/agent vocab to OS 4.x.
- **HARD INVARIANT — "do no harm": nothing in an OS4+ project may break when our tool touches it.**
  Both DEVICES and AGENTS must keep working (agents evolve across OS versions; we have full vocab for
  only ~13 of ~39). Two parts, one VALIDATED, one a KNOWN GAP:
  - *Round-trip/preserve (VALIDATED):* anything not explicitly edited round-trips verbatim; unknown
    agents/devices (no vocab / unbundled driver) DISPLAY + PRESERVE and never crash (`surface_of` = 0
    crashes across all 417 RH items, degrades gracefully). UI rule: only offer STRUCTURED edits where
    we have a known model (`agent_config_kind` set, or a driver schema); for anything unknown, show
    read-only / preserve — never let a user write a partial/wrong state blob.
  - *Referential integrity on DELETE (FIXED 2026-07-14):* `remove_item` used to leave dangling
    references to a removed device in OTHER items' state (lighting-scene `AdvSceneMember/device_id`,
    room `OrderedWatch/ListenList` entries) + programming. **Now closed:** `authoring.find_references`
    / `clean_references` scan+clean device-id refs across connections, network bindings, programming
    (rules triggered by / actions targeting the device), and state blobs. Facade:
    `Project.references_to(id) -> [Reference]` (serializable — for the UI to show "used by N scenes /
    M rules" before delete) and `remove_item(id, clean_references=True)` for the safe cascade
    (default `remove_item` unchanged/backward-compatible). Verified: scene-member + programming refs
    detected and fully cleaned, 0 dangling refs, reload CLEAN. **UI must call `references_to` before a
    delete, show dependencies, and use `clean_references=True` on confirm** (warn-and-cascade).

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
