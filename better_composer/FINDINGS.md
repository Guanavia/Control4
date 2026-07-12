# Better Composer — Investigation Findings

Goal: determine whether a modern replacement for Control4 Composer Pro is buildable, by
understanding how Composer authors a project (adds devices, creates bindings, writes
programming) against Director — the functionality pyControl4 does **not** cover.

Status: **investigation/analysis. No build started.** Last updated 2026-07-11.

---

## 1. System facts (from the log snapshot)

Snapshot: `better_composer/log_snapshot/snapshot-c4-control4_core5-core5-000FFF9FC470-2026-7-11-15-35-8/`

- **Controller:** `core5-000fff9fc470`, Core 5, IP **192.168.1.123**, MAC `00:0f:ff:9f:c4:70`.
- **Director** process (pid 1284, `/control4/bin/director`) listening ports (from `system_info/netstat.txt`):
  - `127.0.0.1:5020` and `127.0.0.1:3004` — **localhost-only, plaintext legacy channels**
  - `0.0.0.0:5021` and `0.0.0.0:3005` — **external-facing; 5021 is the SSL port Composer uses**
  - plus dynamic high ports, and `/var/run/director.socket` (unix)
- **Composer clients seen** (from cert handshakes in `project_change.log`):
  - `Composer_david@propertyrenewal.llc_AMIGA` @ 192.168.1.25 (a physical PC; persistent connection)
  - `Composer_david@propertyrenewal.llc_OSBORNEPC` @ **192.168.1.143** — **this is the VMware Fusion Windows VM on the Mac** (NAT'd, egresses as the Mac's en0 IP 192.168.1.143)

## 2. The two Director interfaces (the core architectural finding)

| | Legacy `c4soap` | Modern REST + WebSocket |
|---|---|---|
| Port | 5021 (SSL), 5020 (localhost plaintext) | `/v1/...` over HTTPS + WS |
| Auth | **mutual TLS w/ Composer client cert** (`CN: Composer_<login>_<machine>`) | bearer token |
| Envelope | `<c4soap name="..." async="1" seq="N">...<param>...` | JSON |
| Surface | **Full authoring** (add device, bindings, programming) + control | **control/state only** |
| Wrapped by | Composer Pro | **pyControl4** (and the HA Control4 integration) |

**Conclusion:** authoring does not live in the REST surface pyControl4 uses. It lives in the
undocumented `c4soap` channel on 5021, gated by a mutual-TLS client certificate. A "better
Composer" must speak this channel (or manipulate the on-disk project + trigger a reload).

## 3. The write path: "PIP"

Every Composer commit appears in `project_change.log` as a pair:
```
PIP received from remote client: 192.168.1.143:56988
Project Info Updated: project version: 88
```
**PIP = "Project Info Packet."** This is the actual authoring push: Composer sends a PIP to
Director, Director applies it and bumps `project version`. Capturing one decrypted PIP is the
single highest-value artifact for building the authoring half.

---

## 4. Data model recovered from the logs (the free win)

The logs are a detailed, structured **audit trail** (output), not the request protocol. But they
expose the complete data model with enough fidelity to reconstruct what each authoring op *means*.
Format = plain text with bracketed `key: value` fields plus an embedded XML payload.

### 4a. Programming — `programming_change.log`
Operations observed (counts from this snapshot): `added` 211, `Moved` 65, `Deleted` 79.
Each CodeItem carries: `codeitem id`, source `device id`/`device name`, `event id`, tree position
(`parent id`, `before id`, and for moves `else codeitem id`), `type`, target `code item device id`,
human `display name`, and a `conditional:` XML payload.

CodeItem `type` values:
- `CIT_COMMAND` (143) — an action; payload `<devicecommand>`
- `CIT_CONDITION` (49) — an "if"; payload `<deviceconditional>`
- `CIT_OPERATOR` (13) — logic node (`AND`/`OR`); empty payload
- `CIT_ELSE` (6) — else branch; empty payload

Payload `owneridtype`: `""` (plain device command, 109), `variable` (50), `agent` (18).

Examples:
```
# device command action
added [codeitem id: 1][device id: 100111][device name: Custom Buttons][event id: 28104]
  [type: CIT_COMMAND][code item device id: 232][display name: Set the speed on NAME to 1]
  [conditional: <devicecommand owneridtype="" owneriditem="-1"><command>SET_SPEED</command>
   <params><param><name>SPEED</name><value type="STRING"><static>1</static></value></param></params></devicecommand>]

# variable condition ("If {var} is True")
added [type: CIT_CONDITION][code item device id: 495][display name: #!"If {VNAME} is True";VNAME="VNAME:495,1002"]
  [conditional: <deviceconditional owneridtype="variable" owneriditem="1002" name="=="><param name="value" type="int">1</param></deviceconditional>]

# agent command (announcement)
added [type: CIT_COMMAND][display name: Execute Announcement 'Gin and Tonic to Nikkis Office']
  [conditional: <devicecommand owneridtype="agent" owneriditem="1"><command>execute_announcement</command>...]

# logic operator node
added [type: CIT_OPERATOR][code item device id: 100000][display name: AND][conditional: ]
```

### 4b. Project structure — `project_change.log` (+ `.1.gz`, `.2.gz`)
Operations observed (counts): `Bound Consumer Added` 882, `Binding Added` 613, `Project Info
Updated` 255, `Binding Deleted` 215, `UpdateProjectC4i` 168, `PIP received` 118, `Bound Consumer
Removed` 112, `Bound Consumer Updated` 23, plus `Add <room>-->..<device>`, `Name Change`, and
agent add/remove.

Examples:
```
Binding Added: [device id: 555][device name: PC - UI Button][binding id: 5001][binding name: UIBUTTON]
Bound Consumer Added [consumer device id: 545][consumer device name: Pioneer VSX-834]
  [consumer binding id: 1032][consumer binding name: INPUT STRM BOX]
  [provider device id: 24][provider device name: Shield TV - Theater][provider binding id: 2000]
  [provider binding name: Output Main][class: HDMI]
Add Theater(26)-->PC - UI Button(555) Version 103          # device added to project
Name Change Kitchen()-->Lux Wired Keypad() Version ...      # rename
Project Info Updated: project version: 88                   # commit / version bump
```
Project metadata (System Owner / Dealer / Installation Notes) is also logged as structured
`<tab><entry .../></tab>` XML — same shape Director stores internally.

### Coverage caveat
The two loggers are an after-the-fact audit trail, so they give the **data model** but not the
**request wire format**. They are also `info`-level and may not capture *every* edit type, and
writes can lag disk (the 2026-07-11 snapshot's newest programming entry was 07-10 — no edit was
made on 07-11 before the pull, which is why nothing from "today" appeared).

---

## 5. Feasibility verdict & gating item

- **Reading** a project is largely solved: REST/WS for live state (pyControl4), logs for the model.
- **Writing/authoring** is the unsolved gate. It requires reproducing the `c4soap`/PIP request on
  5021 behind the mutual-TLS client cert. The logs decode the *destination* model, not the request.

**Not ready to build the authoring half until we have ONE of:**
1. A **decrypted capture** of a Composer authoring request (PIP / c4soap) on 5021. Viable here
   because we own both endpoints (Composer VM + Mac in the NAT path). Needs a mutual-TLS MITM.
2. Confirmation we can **edit the on-disk project + trigger a Director reload** (bypasses the
   request protocol). Project lives on the controller under `/opt/control4/...`; not in this
   snapshot, so unverified.

## 5b. UPDATE (2026-07-11, post-capture): pivot to project.db

Ran the recon capture during a live Composer edit (added a relay in Electrical Closet, bound it
to slot 5 of the lighting rack). Results changed the recommended path.

**Transport is fully locked down (MITM is hard):**
- Composer↔Director uses mutual TLS on **5021** (authoring/c4soap), **5810** (2nd channel), and
  **443** (nginx/REST) — all with ECDHE (forward secrecy), so **passive decryption is impossible**.
- The controller's server cert **chains to a real "Control4 Corporation CA"** (issuer strings
  `Control4 Corporation CA`, `Controller Certificates`, `CONTROL4HOME` seen in the handshake) —
  it is *not* merely self-signed. Composer validates the controller against Control4's CA.
- Composer's client cert `CN: Composer_david@propertyrenewal.llc_OSBORNEPC` is presented on 5021
  and 443 (mutual auth confirmed).
- **Implication:** a transparent mitmproxy using a *forged* CA will be rejected by Composer. A
  working MITM would require extracting the **real** keys from endpoints we control — the
  controller's server key/cert (on-disk as `/opt/control4/etc/*.p12`, `certs/`, `cvm-device.pem`)
  and Composer's client key from the Windows store — then relaying with genuine certs. Doable but
  heavy. **Deprioritized.**
- Port 80 is plaintext but only serves driver icon assets (`GET /driver/<name>/device_sm.png`).

**The project is a SQLite database (the real opening):**
From the snapshot's `file_descriptors_director.txt`, Director holds these open:
- `/opt/control4/var/director/project.db`  ← **the project: devices, bindings, programming** (rw, fd 16)
- `/opt/control4/var/director/system.db`, `state.db`, `drivers.db`, `identity.db`
- `/control4/db/mm.db` (media), `/control4/db/history.db`

`project.db` (~348 KB) was last modified at the exact time of the last commit (`Project Info
Updated: version 133`). So Director's write path is: receive PIP → apply to `project.db` → bump
version. **The semantic model we decoded from the logs (§4) is almost certainly these tables.**

**Revised build strategy:**
- **Read side = essentially solved.** A "better Composer" can read `project.db` directly (plus
  `drivers.db`, live state via REST/WS). This covers visualize/analyze/audit immediately.
- **Write side = tractable without cracking TLS.** Two options to validate, in order of safety:
  1. **Offline edit + reload:** copy `project.db`, edit it, and determine Director's reload path
     (restart director, or a reload command) so changes take effect. Start READ-ONLY.
  2. Speak PIP over 5021 (needs the real-key MITM above to first decode the wire format).
- **Do NOT write to the live `project.db` while Director runs** until reload/locking semantics are
  understood (likely WAL + in-memory cache; direct writes may be ignored or corrupt state).

**Next artifact needed:** a **read-only copy of `project.db`** (and `drivers.db`, `system.db` for
context) pulled from the controller. Dave has controller access (pulled the log snapshot). With
that, we can dump the schema and confirm exactly how to read — and how to write — a project.

## 5c. UPDATE (2026-07-11): project.xml schema decoded — feasibility CONFIRMED

Analyzed the local Composer project `research/Russell House.c4p` (40 MB). It is a **zip** containing:
- **`project.xml` (531 KB) — the entire authorable project** (devices, bindings, programming, vars)
- `drivers/` — the 60 driver files the project references (**38 `.c4z` + 22 `.c4i`**)
- `mm.db` (media metadata, SQLite), `identity.db` (users/permissions/experiences, SQLite)
- `meta/` (manifest json)

So Composer's **saved** format stores the project as XML; the controller's **runtime** copy is the
SQLite `project.db`. Same model, two encodings. `project.xml` is the one to build against.

### project.xml structure (root `<currentstate>`)
| section | contents |
|---|---|
| `properties` | project meta: `iditemcurrent`, version, owner/dealer tabs, geo, UI defaults |
| `systemitems` | the **device/room/agent tree** — nested `<item>` via `<subitems>` (148 items total) |
| `bindings` | the **binding graph** — `<boundbinding>` provider → `<boundconsumers>/<bound>` |
| `networkbindings` | IP/serial network bindings |
| `variables` | project/device `<variable>` definitions |
| `event_mgr` | **programming** — 41 `<event>` each holding `<codeitem>` trees |
| `plugins` | agents/plugins |

### Confirmed 1:1 mapping between project.xml and the audit logs
**Device `<item>`:** `id`, `name`, `type`, `created_datetime`, `itemdata` (`uuid`, `c4i` driver ref,
`config_data_file`, `small_image`/`large_image`, driver config), and nested `subitems`.

**Binding (matches "Bound Consumer Added ... class: X" log):**
```xml
<boundbinding><deviceid>3</deviceid><bindingid>3</bindingid>
  <boundconsumers><bound><deviceid>64</deviceid><bindingid>300</bindingid>
    <name>FamRm - Evening Lights Button Link</name>
    <boundclasses><boundclass>BUTTON_LINK</boundclass></boundclasses></bound></boundconsumers>
</boundbinding>
```

**Programming (matches programming_change.log CodeItem exactly):**
```xml
<event><deviceid>28</deviceid><eventid>..</eventid>
  <codeitem><id>1</id><device>28</device><type>1</type>
    <display>Select the Prime Video as the video source in NAME</display>
    <cmdcond><devicecommand><command>SELECT_VIDEO_DEVICE</command>
      <params><param><name>deviceid</name><value type="INT"><static>45</static></value></param></params>
    </devicecommand></cmdcond>
    <subitems/><creator>0</creator><enabled>True</enabled>
  </codeitem>
</event>
```
`codeitem.type`/`cmdcond` correspond to the log's `CIT_*` types and `<devicecommand>`/
`<deviceconditional>` payloads; `subitems` is the if/else tree nesting the log encodes as
`parent id`/`before id`.

**Variable:** `<variable deviceid= variableid= name= type= readonly= hidden= description=>value</variable>`

### Feasibility verdict: **BUILDABLE.**
- **Read side is solved.** The complete project model is a single, legible XML document; driver
  metadata is in the bundled `.c4z`/`.c4i` files. A modern viewer/editor can parse this today.
- **Write side is tractable.** Generate/modify `project.xml`, repackage the `.c4p`. The one
  remaining unknown is the **apply/load mechanism** — how a modified project reaches a running
  Director. Candidates (in order of preference to test):
  1. Composer's own "load/restore project" flow (round-trip a `.c4p`).
  2. Controller-side: replace `project.db` (or import project.xml) + trigger a Director reload.
  This is a *much* smaller unknown than reverse-engineering the encrypted PIP protocol.

**Recommended next step:** start the read-model parser (project.xml + driver `.c4z`/`.c4i` metadata)
and, in parallel, run a low-risk "apply" test — make a trivial change to a copy of the project and
see whether Composer/Director will load it back.

## 6. Capture experiment (completed — recon pass)

Topology: Composer VM → VMware NAT → Mac en0 (192.168.1.143) → controller 192.168.1.123:5021.

- **Recon capture:** `scratchpad/capture.sh` — plain `tcpdump` of Mac↔controller to a pcap.
  Confirms port/encryption and checks for any plaintext. (Needs `sudo` — run by Dave.)
- **Decrypt path:** mitmproxy 12.2.3 installed (`/opt/homebrew/bin/mitmdump`). Mutual-TLS MITM
  will additionally need, from the Windows VM side: (a) install the mitmproxy CA in the VM trust
  store, (b) export Composer's client cert+key. Risk: Composer may pin Director's cert, which
  would defeat interception — the recon capture is run first to confirm before investing in this.
