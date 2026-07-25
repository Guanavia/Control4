# Version Validation & Deploy-Friction — open design thread

**Status: DISCUSSION / not built.** Design conversation 2026-07-24/25. No code written yet.
This is a design thread to resume, not a decided-and-implemented feature. Captured here so it
survives a context switch to other Control4 work.

## The question that started it

Composer's "virtual system" builder makes you pick a Director version when you design. Hypothesis
was that it spins up a VM per version. Reality: **"Virtual Director" is Director-the-real-software
running as a local process on the Windows machine**, and Composer bundles multiple Director
releases so you can pick one (evidence: version-numbered `Shared\<ver>\...` folders on the
workstation — `4.0.0`, `4.1.0`, `3.4.3`). Not a hypervisor/simulator — it's the same binary a
hardware controller runs.

**Core point:** compatibility assurance comes from loading the project into a *real Director of the
target version* and watching it ingest cleanly. That's the guarantee Composer relies on too —
Composer doesn't validate compatibility itself, it hands the project to Director and lets Director
judge. **We already have this** — the virtual director in the VMware Fusion VM has been our
validation oracle for the whole backend (every `VM LOAD-TEST — PASSED` note = this loop).

## Why the file-based model isn't a compatibility downgrade

- **Director is self-healing on load** (Test B): skeletal state → Director fills version-correct
  defaults; edited values → preserved exactly. So we don't replicate Director's validation logic;
  we let the target-version Director be the judge at load time — the *same* assurance point Composer
  uses.
- **Version-matched validation is trustworthy because it's the real thing.** Loading into a virtual
  director of the same version as the customer's hardware runs the *identical Director software* the
  controller runs — so it inherently covers version-specific hardware behavior, minus rare
  controller-physical-capability cases no virtual director would catch anyway.

## The real friction (user's sharpening)

Version-by-version validation matters — Director versions interact with hardware differently, and
most (not all) things are back/forward compatible. As a dealer, pushing an unvalidated design
straight to a customer's live controller is a HUGE risk. So the pipeline becomes:

> build with our tool → load into version-matched virtual director, check compatibility → if clean,
> deploy to hardware director.

That's an extra step vs. Composer's "always live on a director" feel.

**Key reframe:** the single final gate is NOT the enemy — a pro should always validate before
touching customer hardware (true even in Composer when designing offline on one version and
deploying to another). The friction that actually hurts is:
1. the **iterative debug loop** (build→load→fail→fix→reload×N), and
2. the **manual VM choreography** of even a single gate.

Target: make the gate **usually-pass-first-try** and make it **one action**, not a loop.

## Two levers we control now (the plan)

**1. Version-compatibility linter — catch it at edit time, before any Director load.**
Where we can beat Composer (which just lets Director complain on load). Encode a compat matrix,
flag problems in-tool as they're introduced. Data via the same "oracle on disk" method:
- **Diff bundled Director versions against each other** (`4.0.0` vs `4.1.0`, OS4+ scope only →
  narrow matrix): reveals changed agent/proxy versions, schema shifts. We copied the 4.1.0 def set
  into `research/director_drivers/`; would want the **4.0.0 def set** too (on the workstation, maybe
  not yet in repo).
- **Driver-declared minimum OS/firmware fields** — already parseable.
- Honest caveat: the software/schema dimension is fully derivable; the pure hardware-model dimension
  (this controller can't run that OS) is partly C4-matrix knowledge. But version-matching the gate
  already handles most hardware behavior, so the linter's main job is stopping "used a construct
  this Director version doesn't understand" before it costs a round-trip.

**2. Collapse the gate to one action.** Automate the virtual-director round-trip + `c4proj diff` so
"validate against Director 4.1.0" is a button reporting what Director accepted/rejected/rewrote.
Start manual (Restore in Composer, feed backup to `c4proj diff` — doable today); automate the
Composer-driving only if the manual gate proves too slow.

Together: linter → load passes first try; automated gate → that load is one click.

## Two endgames that collapse the gate to zero (not needed for beta)

1. **Sanctioned C4 integration** — C4 gives blessed API/code; our tool becomes a live Director
   client like Composer. Clean, but out of our hands, requires a partnership, long-term.
2. **Dealer-authorized c4soap client** — our tool speaks Director's own protocol (port 5021,
   mutual-TLS) using the dealer's OWN legitimate credentials typed fresh. The paused FINDINGS
   thread. Grayer, real RE work, but IN our control and inside the already-drawn line ("using the
   machine's own already-authorized access is fine"). If solved, gets us to live-director validation
   without waiting on C4. Paused because the cert handshake is hard, not because it's off-limits.

## Recommended order (not yet approved by user)

1. **Version linter** first — highest leverage (turns the loop into a single gate), pure data work,
   Composer-beating.
2. **One-click validation gate** second — productize the oracle round-trip we already run by hand.
3. Keep **dealer-authorized c4soap** as tracked long-term friction-killer; not a beta blocker.

## OPEN QUESTIONS for next session (user hadn't answered yet)

- Which friction does the user feel most: the **iterative loop** (→ linter) or the **manual VM
  choreography** (→ automated gate)?
- Is the version-compat matrix a **near-term build**, or is it enough for now to just always
  validate against a **version-matched** virtual director and treat the linter as phase 2?
- Also surfaced: `Project.new()` currently seeds from ONE fixed blank capture (capture-01, Director
  4.1.0). Supporting "new project for Director vX" needs **version-specific blank seeds** — a
  bounded task (capture a blank from each target-version virtual director).
