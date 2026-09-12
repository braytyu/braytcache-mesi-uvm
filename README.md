# braytcache — MESI-Coherent L1 Data Cache and UVM Verification Environment

braytcache is a two-core, set-associative, write-back L1 data cache that
maintains **MESI coherence** over a snooping interconnect. It is verified by a
constrained-random **UVM** environment that combines transaction-level data
checking with coherence-invariant checking, functional coverage, and protocol
assertions.

---

### Status

**12 / 12 tests pass** &nbsp;·&nbsp; **5 / 5 injected bugs detected** &nbsp;·&nbsp;
**2 / 2 geometries** &nbsp;·&nbsp; **98.92 %** functional coverage (best single
run)

| | |
|---|---|
| **RTL** | Two MESI L1 caches, snooping interconnect, AXI4-Lite memory. 8 files. |
| **Verification** | UVM: 4 agents, 6 covergroups, 6 independent checking mechanisms, 12 tests, 3 SVA modules. 29 files. |
| **Toolchain** | Questa Altera FPGA Starter Edition 2025.2 for compilation and elaboration; Synopsys VCS on EDA Playground for simulation. |
| **Evidence** | [Results](#results) · [Run screenshots](docs/RUN_SCREENSHOTS.md) · [What the runs revealed](#what-the-runs-revealed) · [Bug injection](#bug-injection) · [Debug log](docs/DEBUG_LOG.md) |

---

## Project motivation

I wanted to use this project to exercise my RTL design and verification skills that I had developed over the course of my most recent internship. After deliberating on a project to demonstrate these skills, I chose to develop a two core L1 data cache with MESI cache coherence. This is because I believe there would be interesting interactions between independent components, shared state, ownership, data movement, and timing; making this a suitable option.

The verification methodology I was most interested in exploring was
**constrained-random verification (CRV)**. Rather than relying solely on
directed tests, I wanted to build an environment that could generate varied
traffic, compare results against reference models, collect functional coverage,
and continuously check protocol rules with assertions.

A cache-coherence design provides a useful setting for that methodology. Random
traffic can expose interactions that are difficult to anticipate manually, while
targeted constraints can increase pressure on specific behaviors such as
ownership transfers, sharing, false sharing, evictions, writebacks, and
replacement. The scoreboard and coverage model then provide feedback about both
correctness and which parts of the design the stimulus actually exercised.

This project is my attempt to develop those design and verification skills in a
way I find technically interesting. The cache implementation is
intentionally focused enough to remain manageable, while the verification
environment is designed to demonstrate the CRV workflow: constrained stimulus,
transaction monitoring, reference-model checking, functional coverage,
assertions, and failure diagnosis.

---

## Table of contents

- [Project motivation](#project-motivation)
- [Architecture](#architecture)
- [Design decisions](#design-decisions)
- [The cache](#the-cache)
- [Coherence protocol](#coherence-protocol)
- [Interfaces](#interfaces)
- [Verification environment](#verification-environment)
- [What gets checked](#what-gets-checked)
- [Functional coverage](#functional-coverage)
- [Assertions](#assertions)
- [Stimulus](#stimulus)
  - [Tests — what each one is for](#tests-veriftestscache_testssv)
- [Bug injection](#bug-injection)
- [Running it](#running-it)
- [Results](#results)
- [What the runs revealed](#what-the-runs-revealed)
- [Scope decisions and limitations](#scope-decisions-and-limitations)
- [Future extensions](#future-extensions)
- [Repository layout](#repository-layout)

---

## Architecture

```mermaid
graph TB
  subgraph DUT["DUT — cache_top"]
    L0["l1_cache #(CORE_ID=0)<br/>tag / state / data / PLRU"]
    L1["l1_cache #(CORE_ID=1)<br/>tag / state / data / PLRU"]
    BUS["coherence_bus<br/>round-robin arbiter<br/>snoop broadcast<br/>AXI4-Lite master"]
  end

  C0["core 0"] -->|core_if<br/>OBI req/gnt/rvalid| L0
  C1["core 1"] -->|core_if<br/>OBI req/gnt/rvalid| L1
  L0 <-->|bus_if<br/>ACE-style snoop bus| BUS
  L1 <-->|bus_if<br/>ACE-style snoop bus| BUS
  BUS -->|axil_if<br/>AXI4-Lite| MEM["memory"]
```

There are three protocol boundaries and three different protocols:

| Boundary | Protocol | Purpose and rationale |
|---|---|---|
| core ↔ L1 | OBI-style `req`/`gnt`/`rvalid` | Matches the request and response behavior of a typical core-to-cache interface while keeping the cache-side agent simple. |
| L1 ↔ L1 | Simplified ACE-inspired bus | Provides the snoop, ownership, and cache-line data signaling required for MESI coherence; AXI4-Lite cannot carry these transactions. |
| Interconnect ↔ memory | AXI4-Lite | Uses a standard point-to-point memory protocol for line fills and writebacks, with each cache-line word transferred as a separate single-beat transaction. |

Protocol choice and design is justified in [Design decisions](#design-decisions) below.

---

## Design decisions

All design decisions made and their rationale during bring up of this project are discussed here.

Note: decisions are marked in repo with a `DECISION:` comment, so
`grep -rn "DECISION:" rtl/ verif/` allows you to locate where these decisions live. 

### Interfaces

#### OBI-style req/gnt/rvalid for core, not AXI.
Real cores do not talk to their L1 over AXI (real cores such as Ibex and CV32E40P, which are open source cores by lowRISC and OpenHW Group), they present a
`req`/`gnt` address phase followed by an `rvalid` response phase. Putting AXI here would add five independent channels, IDs and
burst logic to a boundary that issues one aligned word at a time, which brings driver
and monitor complexity with no additional coverage. 
*Trade-off:* the core agent is custom, so it is not reusable outside this
project.

#### The coherence bus is a simplified ACE, not AXI4-Lite.
AXI4-Lite physically cannot carry coherence. It has no snoop address channel, no
snoop response channel, no snoop data channel, and no way for a master to
declare or know of a cache-line state. It is a single-beat, point-to-point
read/write protocol. 

In the AMBA family there exists **ACE**, ARM's coherency extension to
AXI, which adds exactly those channels (AC / CR / CD) and whose transaction set
maps one-to-one onto MESI. Our custom bus borrows ACE's vocabulary: `ReadShared`,
`ReadUnique`, `CleanUnique`, `WriteBack`, and the `IsShared` / `PassDirty`
response attributes to make the design legible. 

The coherence bus is simplified to a single atomic shared bus instead of ACE's independent
channels, ordering rules, barriers and distributed virtual memory transactions.
*Trade-off:* this is **ACE-inspired, not ACE-compliant**, implementing full ACE is a [Future extension](Future-extensions).

#### AXI4-Lite for memory side.
This is the one boundary where a standard protocol is both a natural fit and
cheap: a line fill really is a sequence of plain address/data/response
transactions with no coherence content. Making it real AXI4-Lite yields a
reusable slave agent, a full set of protocol assertions, and a place to inject randomised latency and backpressure that stimulates the
timing relationship between fills and coherence traffic.
*Trade-off:* AXI4-Lite has no bursts, so a line fill is `LINE_WORDS` separate
single-beat transactions rather than one burst. AXI4 with bursts would be more realistic (at the cost of
burst and ID handling).

#### Why not just use one protocol everywhere?
Different protocols are exercised at different boundaries, like in real SoC's. 

### Microarchitecture START FROM HERE WHEN YOU ARE BACK AUG 25 3:50AM 2026

#### The bus is atomic, so MESI has no transient states.
A grant is held across snoop, memory access and response, so a cache is never
snooped while it owns the bus and every line is in one of the four stable states
at every clock edge. See [Why the bus is atomic](#why-the-bus-is-atomic).
*Trade-off:* a split-transaction bus — the realistic next step — requires the
transient state machine (`IM_AD`, `SM_AD`, …), which is where most genuine MESI
difficulty lives.

#### The cache is blocking, with one outstanding miss.
MSHRs, hit-under-miss and memory-level parallelism would have consumed the whole
schedule and displaced the coherence work, which is the point of the project.
Blocking also keeps the scoreboard's ordering argument tractable: a completing
access always retires before the ownership transfer that follows it.
*Trade-off:* the design has no memory-level parallelism and its performance is
uninteresting. This is a correctness project, not a performance one.

#### Invalid ways are preferred over the PLRU victim, lowest index first.
Allocating into a free way avoids a pointless eviction. Breaking ties by lowest
index rather than arbitrarily keeps victim selection deterministic, which makes
failures reproducible across seeds.
*Trade-off:* it biases which ways fill first, so `cg_alloc` covers free-way and
PLRU-driven victim selection as separate cases to prove both paths run

**The bus operation is re-derived every cycle rather than latched at request
time.**
This is the only genuine race an atomic bus does not remove, and it is handled
in the RTL rather than assumed away. Details in
[The one race an atomic bus does not remove](#the-one-race-an-atomic-bus-does-not-remove).

#### Silent clean eviction is implemented, not avoided.
Dropping an `S` or `E` line without telling anyone is legal MESI, and it means a
cache can sit in `S` believing a line is shared when it is the only holder. It
would have been easier to notify on every eviction; implementing the
conservative-but-imprecise behaviour is more faithful, and it forces the
reference model to avoid assuming precision.

---

### Configuration and parameterisation

#### Geometry is a verification variable, not a constant.
`NUM_WAYS`, `NUM_SETS`, `LINE_BYTES` and `NUM_CORES` are all configurable, for
three distinct reasons:

1. *It catches baked-in assumptions.* The same environment has to pass at 2-way
   and 4-way. Anything in the RTL or the checkers that silently assumed two ways
   fails the moment the 4-way build runs.
2. *It makes the PLRU claim honest.* At `NUM_WAYS=2` a tree-PLRU is a single bit,
   which is just LRU. Only at 4 ways is the tree actually a tree. Shipping
   2-way-only and calling it PLRU would not survive the question "how many bits
   per set?"
3. *It lets the default geometry be chosen for verification throughput.* 512
   bytes per cache is absurdly small for a real design, and that is the point:
   under random stimulus over a 4 KB region, conflict misses, evictions and
   writebacks happen constantly instead of rarely.

#### Both geometries are exercised, and the second one is not a formality.
`eviction_test` passes at 4-way/8-set with no source changes, which is what makes
the first two claims above evidence rather than intent — at four ways the PLRU is
genuinely two levels of decision over three bits per set, not a single LRU bit.
The run also reproduces a textbook microarchitectural effect: writebacks fall
from 14 to 3, because a working set that thrashed a 2-way set largely fits in a
4-way one. Associativity reducing conflict misses is not a new result, but seeing
it fall out of your own design is a useful check that the replacement logic is
doing what it claims.

#### Configuration is by `+define+`, not module parameters.
The geometry has to be visible inside a `package` — the address field widths,
`tag_t` / `index_t` / `line_t`, and the helper functions all depend on it — and
SystemVerilog packages cannot be parameterised. The UVM classes import that same
package, so they need the identical values. Build-time defines with
`` `ifndef `` defaults are the standard way around this.
*Trade-off:* changing geometry needs a recompile, so it cannot be randomised
per-run inside a single build. It is a per-build regression axis instead.

### Verification architecture

#### The environment is whitebox on purpose.
SWMR is a statement about *state*, not about transactions, and it cannot be
checked from the core interfaces at all. A blackbox-only testbench catches a
coherence bug only in the seeds where it happens to surface as a wrong load
result, possibly thousands of cycles after the violation. Tapping the tag and
state arrays turns a latent, seed-dependent bug into an immediate error.
*Trade-off:* the testbench is coupled to RTL internal signal names. Contained by
routing everything through one interface and one generate block in
[verif/tb/tb_top.sv](verif/tb/tb_top.sv), so a rename touches one file.

#### The probe is wired with hierarchical assignments rather than `bind`.
`bind` is the more idiomatic construct, but the target flow was uncertain and
hierarchical references index identically on every simulator. `bind` *is* used
for the assertion modules, where it is both standard and well supported.
*Trade-off:* slightly less elegant; trivially switchable once the flow is known.

**Golden memory is ordered by monitor completion time, with an argument rather
than a mechanism.**
No global-order reconstruction, no timestamping infrastructure. Coherence
already serialises same-address accesses, and the reasoning is written out in
[What gets checked](#what-gets-checked). Building an order-reconstruction engine
would have been more code and more places to be wrong.

#### Unwritten memory returns a deterministic hash of its address.
`mem_model::backing_value()` is used both by the AXI4-Lite slave and to seed the
scoreboard's golden memory, so a load from a location the test never wrote still
has exactly one correct answer. The usual "X on the first read" blind spot
disappears without pre-initialising memory or restricting the address space.

#### *Coverage is reported by the testbench itself.
The target flow has no coverage database and no way to merge across runs, so
`final_phase` prints its own table via `get_inst_coverage()`. This is
simulator-independent and survives any flow.
*Trade-off:* no cross-run merging, so the reported number is per-run rather than
cumulative.

#### Forbidden protocol states are `illegal_bins`, not uncovered bins.
An uncovered bin is something you failed to hit. An illegal bin is something the
protocol forbids, and hitting it is an error at the moment it happens. Encoding
the eight forbidden MESI state pairs this way turns the coverage model into a
checker.

#### Bugs are injectable by `+define+`.
Five one-line RTL mutations, each of which must make the regression fail. It is
the cheapest available evidence that the checkers actually check something,
rather than a testbench that passes because it looks at nothing.

---

## The cache

| Parameter | Default | Override |
|---|---|---|
| `NUM_CORES` | 2 | `+define+CFG_NUM_CORES=n` |
| `NUM_SETS` | 16 | `+define+CFG_NUM_SETS=n` |
| `NUM_WAYS` | 2 | `+define+CFG_NUM_WAYS=n` (power of two) |
| `LINE_BYTES` | 16 (4 words) | `+define+CFG_LINE_BYTES=n` |

512 bytes per cache by default — deliberately tiny, so conflict misses and
evictions are common rather than rare. Reasoning in
[Design decisions](#configuration-and-parameterisation).

**Policy:** write-back, write-allocate, blocking (one outstanding miss).

**Replacement:** parameterised **tree-PLRU**, `NUM_WAYS-1` bits per set. Invalid
ways are preferred over the PLRU choice, lowest index first so victim selection
stays deterministic across seeds.

**Control FSM:**

```
IDLE ──req&gnt──► LOOKUP ──┬── hit, load                 ──► RESP
                           ├── hit, store, M/E           ──► RESP   (silent E→M)
                           ├── hit, store, S             ──► BUS    (CleanUnique)
                           └── miss                      ──► WB ──► BUS ──► RESP
```

`WB` issues a `WriteBack` only if the selected victim is still `M`; a snoop may
have downgraded it in the meantime, in which case the state is re-evaluated and
the writeback is skipped.

---

## Coherence protocol

### Local requests

| State | Load | Store |
|---|---|---|
| **I** | `ReadShared` → **S** if `IsShared`, else **E** | `ReadUnique` → **M** |
| **S** | hit, stays **S** | `CleanUnique` → **M** (no data moves) |
| **E** | hit, stays **E** | silent → **M**, no bus transaction |
| **M** | hit, stays **M** | hit, stays **M** |

### Snoop responses

| State | `ReadShared` | `ReadUnique` | `CleanUnique` |
|---|---|---|---|
| **I** | miss | miss | miss |
| **S** | hit, `IsShared`, stays **S** | hit → **I** | hit → **I** |
| **E** | hit, `IsShared` → **S** | hit → **I** | cannot occur (SWMR) |
| **M** | hit, `IsShared`, `PassDirty` → **S** | hit, `PassDirty` → **I** | cannot occur (SWMR) |

A `CleanUnique` is only ever issued by a cache already holding the line in **S**.
By SWMR no other cache can then hold it **E** or **M**, so those table entries
are unreachable — which is why the RTL re-derives its bus operation at grant
time (see below).

### Eviction

| Victim state | Action |
|---|---|
| **I** | free way, no bus traffic |
| **S** / **E** | silent drop, no bus traffic |
| **M** | `WriteBack` to memory, then **I** |

Silent clean eviction is legal MESI and is deliberately implemented: it means
another cache can sit in **S** believing the line is shared when it is in fact
the only holder. The protocol is conservative rather than precise, and the
reference model must not assume otherwise.

### Where dirty data goes

Every coherence protocol has to answer one question: *at any moment, who is
responsible for the only up-to-date copy of a line?* MESI answers it with a
single rule — **only a cache in M may hold data that memory does not have**.
Everything below is a consequence of that rule.

The consequence that is easy to miss: **S** means *clean and shared*, so a line
cannot be both dirty and shared. The moment a modified line becomes shared, the
dirtiness has to go somewhere, and the only place available is memory.

- `ReadShared` hitting **M** → the snooper supplies the line to the requester
  **and** the interconnect writes it back to memory in the same atomic
  transaction. Both caches end in **S** and memory is current, so the rule holds.
- `ReadUnique` hitting **M** → the dirty line is handed straight to the
  requester, which becomes **M** while the snooper goes to **I**. Memory is
  *not* updated, and does not need to be: there is still exactly one **M**
  holder, so responsibility has simply changed hands.

**This is exactly what the O state in MOESI buys.** MOESI adds *Owned* — dirty
but shared — letting one cache remain responsible for modified data while others
read it, deferring the writeback until eviction. That saves a memory write on
every `ReadShared` that hits a modified line. MESI cannot express that state, so
it pays the write immediately.

The cost is visible in this project's own results: `cg_axil` reaches 100 % on
tests that report `WriteBack=0`, because dirty *interventions* generate AXI
writes even when no line is ever evicted.

### Why the bus is atomic

The interconnect grants one master at a time and holds that grant across snoop,
memory access and response. A cache is therefore **never snooped while it holds
a grant**, which means every line is in one of the four stable states at every
clock edge.

**What that buys is the absence of transient states**, and it is worth spelling
out why they would otherwise be necessary. MESI is usually drawn as a four-state
diagram, but that diagram is only accurate if state changes are instantaneous.
On a real bus they are not. Consider a cache in **I** that wants to store: it
issues `ReadUnique` and waits. Between issuing the request and receiving the
line it is in neither **I** nor **M** — it has committed to an upgrade that has
not completed. If a snoop arrives during that window the cache must answer
something, and neither "I hold this line" nor "I do not" is truthful.

Protocols resolve this by adding **transient states**, conventionally named for
the transition in progress and the events still outstanding: `IM_AD` reads as
"moving from I to M, awaiting Address (bus grant) and Data". A realistic MESI
implementation carries a handful of them, and each one adds rows to the
snoop-response table, because a cache caught mid-flight still has to reply
correctly.

Holding the grant across the entire transaction collapses that window to zero.
A cache is only ever snooped while it is *not* mid-transaction, so the
four-state diagram is literally true and the snoop-response table stays 4×3.

This is a scoping decision rather than an oversight, and it is the honest
boundary of the project: **most of the genuine difficulty in MESI lives in the
transient states**, and this design does not have them. The natural next step is
a split-transaction bus, which requires the transient state machine and roughly
triples both the RTL and the verification effort.

### The one race an atomic bus does not remove

A cache can decide it needs the bus, and then be snooped before it is granted:

> Cache 0 holds line X in **S** and requests the bus intending `CleanUnique`.
> Cache 1 wins arbitration first and issues `ReadUnique` on X, invalidating
> cache 0. Cache 0's pending upgrade is now wrong — it no longer has the data.

The RTL handles this by deriving `bus.op` **combinationally from current state
every cycle** rather than latching it at request time. The pending `CleanUnique`
degrades into a `ReadUnique`, and a pending `WriteBack` whose victim was
downgraded simply withdraws its request. A consequence is that `bus.req` may
deassert before it is granted, which is legal on this bus and is checked by
assertion `a_bus_progress` ("grant or retire, but do not hang").

**Measured.** `upgrade_race_test` drives both caches into **S** and issues
simultaneous stores. The number of rounds is randomised in `[4:8]` and this seed
chose six; the lines themselves are consecutive from the region base, one per
round, so no round can conflict with another in the same set. The result:

```
ReadShared=12  ReadUnique=6  CleanUnique=6  WriteBack=0
state transitions=42
```

Six rounds produced **six `CleanUnique` and six `ReadUnique`** — a perfect 1:1.
Every round had one winner that completed its upgrade and one loser whose pending
`CleanUnique` had to be re-derived as a `ReadUnique` after being invalidated. The
degradation path executed on 100 % of rounds, and no data was lost.

The transition count is exactly derivable, which is a useful independent check:
per round the line goes `I→E` (first load), `E→S` plus `I→S` (second load),
`S→M` plus `S→I` (the race), then `M→I` plus `I→M` (the loser's `ReadUnique`).
Seven transitions × six rounds = 42, which is what the scoreboard counted.

---

## Interfaces

| File | Interface | Notes |
|---|---|---|
| [rtl/core_if.sv](rtl/core_if.sv) | `core_if` | OBI-style. Clocking blocks for driver and monitor. |
| [rtl/bus_if.sv](rtl/bus_if.sv) | `bus_if` | Per-master fields are **unpacked arrays** so each cache drives only its own element; no modports, to avoid false multi-driver errors on a shared packed vector. |
| [rtl/axil_if.sv](rtl/axil_if.sv) | `axil_if` | Full AXI4-Lite, five channels. |
| [rtl/cache_probe_if.sv](rtl/cache_probe_if.sv) | `cache_probe_if` | Whitebox tap, driven by hierarchical assignment from [verif/tb/tb_top.sv](verif/tb/tb_top.sv). |

---

## Verification environment

```mermaid
graph TB
  VSQ["cache_vsequencer"] --> CA0 & CA1
  CA0["core_agent[0]<br/>driver / sequencer / monitor"] --> SB & COV
  CA1["core_agent[1]"] --> SB & COV
  BM["bus_monitor (passive)"] --> SB & COV
  PM0["probe_monitor[0]<br/>MESI transition stream"] --> SB & COV
  PM1["probe_monitor[1]"] --> SB & COV
  AX["axil_agent<br/>slave responder + mem_model"] --> COV
  AX -.->|mem_model shared| SB
  SB["coherence_scoreboard<br/>golden memory · SWMR · transition legality"]
  COV["cache_coverage<br/>cg_core cg_bus cg_mesi cg_share cg_alloc cg_axil"]
```

| Component | Role |
|---|---|
| [core_agent](verif/agents/core_agent/core_agent.sv) | Active OBI master, one per core. Monitor pairs the address phase with the response phase and emits a completed transaction. |
| [axil_agent](verif/agents/axil_agent/axil_agent.sv) | AXI4-Lite **slave** responder backed by [mem_model](verif/agents/axil_agent/mem_model.sv), with randomised per-channel latency. Its monitor feeds coverage; the scoreboard reads the memory model directly at end of test. |
| [bus_monitor](verif/agents/bus_agent/bus_monitor.sv) | Passive. Reconstructs each coherent transaction: op, requester, snoop hits, `PassDirty`, `IsShared`, line data. |
| [probe_monitor](verif/agents/probe_agent/probe_monitor.sv) | Whitebox. Emits one item per observed line-state change, giving a clean MESI transition stream. |
| [coherence_scoreboard](verif/env/coherence_scoreboard.sv) | All checking. |
| [cache_coverage](verif/env/cache_coverage.sv) | All functional coverage, plus a self-printed coverage table. |

### Sampling discipline

Monitors read signals immediately after `@(posedge clk)` rather than through a
clocking block.

That needs justifying, because sampling a signal on the same edge that drives it
is the classic SystemVerilog race. It is safe here because of scheduling
semantics rather than luck: the RTL drives these signals from **non-blocking**
assignments, which are *evaluated* in the Active region but do not *update* until
the NBA region, strictly later within the same time step. A monitor that wakes in
the Active region therefore reads the pre-edge value — the same value the RTL
itself used when it made its decision — and does so deterministically on every
simulator.

A clocking block expresses that intent directly and would be the default choice.
It is not used because `bus_if` carries unpacked arrays, whose support inside
clocking blocks varies between simulators, and portability across the two
toolchains mattered more than idiom.
*Trade-off:* the guarantee now rests on an RTL coding convention — drive this
interface with non-blocking assignments — rather than being enforced by the
language. A signal driven combinationally into the interface would break the
argument silently, with no error anywhere.

---

## What gets checked

Six independent mechanisms, chosen so that no single one has to catch everything:

**1. Data-value invariant (golden memory).**
Every store observed at a core interface is applied to a reference memory; every
load is compared against it. Ordering is by monitor completion time. That is
sound because coherence serialises same-address accesses — a core can only write
while it is **M**, and transferring ownership takes several cycles, so a
completing access always retires before the transfer that follows it. Two
same-address accesses completing in the same cycle would itself be an SWMR
violation, which mechanism 3 catches.

**2. MESI transition legality.**
Every state change from the probe stream is checked against a legality table. A
change of *tag* is an allocation, and is legal only if the previous occupant was
clean — so allocating over a modified way (dirty data dropped without a
writeback) is caught immediately rather than thousands of cycles later.

**3. SWMR invariant.**
Single-Writer / Multiple-Reader is the defining safety property of any coherence
protocol, and it is worth stating precisely: *for any one line, at any one
moment, either exactly one cache may write it and no other cache holds a copy,
or any number of caches may read it and none may write.* Every MESI state encodes
a position in that statement — **M** and **E** are the single-writer case, **S**
is the multiple-reader case, **I** is abstention.

The check is a per-line census across both caches, re-run whenever any line
changes state: at most one **M**-or-**E** holder, and never an exclusive holder
coexisting with sharers.

Note what kind of statement this is. SWMR constrains *state*, not transactions,
which is why no amount of watching the core interfaces can verify it, and why
the whitebox probe exists at all. The sweep is gated on the transition stream
rather than run blindly every cycle, which is both cheaper and sufficient: state
can only become illegal at the moment it changes.

**4. Sharer data agreement.**
Every cache holding a line in **S** must hold identical data for it.

**5. Bus-level consistency.**
`IsShared` must agree with the observed snoop hits, and an upgrade must never
move data. These check the interconnect's own aggregation logic rather than the
caches.

**6. End-of-test memory reconciliation.**
For every word the test touched, the expected value is compared against the
*actual* system state: the dirty cached copy if some cache still holds the line
**M**, otherwise the AXI4-Lite memory. This is the backstop that catches dirty
data quietly lost anywhere in the run.

---

## Functional coverage

| Covergroup | Covers |
|---|---|
| `cg_core` | op × core × set index × word offset × byte-enable pattern (full word, single byte, partial) |
| `cg_bus` | coherent op × requester × snoop hit × `PassDirty` × `IsShared`; includes dirty intervention, where a snooper supplies data instead of memory |
| `cg_mesi` | old state × new state × tag-changed, per core |
| `cg_share` | **cache 0 state × cache 1 state for one line** |
| `cg_alloc` | victim state at allocation × way × set × core — proves every way gets replaced and that both free-way and PLRU-driven victim selection occur |
| `cg_axil` | AXI4-Lite direction × word position within the line — proves every beat of a line is both fetched and written back |

### The illegal bins

`cg_mesi` and `cg_share` are written so the forbidden cases are `illegal_bins`,
i.e. simulation errors:

```systemverilog
// cg_share — every state pair MESI forbids
illegal_bins mm = binsof(cp_c0) intersect {MESI_M} && binsof(cp_c1) intersect {MESI_M};
illegal_bins ms = binsof(cp_c0) intersect {MESI_M} && binsof(cp_c1) intersect {MESI_S};
illegal_bins ee = binsof(cp_c0) intersect {MESI_E} && binsof(cp_c1) intersect {MESI_E};
// ...

// cg_mesi — allocating over a modified way is dropped dirty data
illegal_bins dirty_dropped = binsof(cp_old)  intersect {MESI_M} &&
                             binsof(cp_tagc) intersect {1};
```

The derivation is worth doing explicitly, because "eight of sixteen" is the kind
of number that should not be taken on trust. Two caches and four states give
4 × 4 = 16 ordered pairs. SWMR admits a pair if and only if it places neither two
writers, nor a writer alongside a reader, on the same line:

| | c1 = **I** | c1 = **S** | c1 = **E** | c1 = **M** |
|---|---|---|---|---|
| **c0 = I** | legal | legal | legal | legal |
| **c0 = S** | legal | legal | illegal `se` | illegal `sm` |
| **c0 = E** | legal | illegal `es` | illegal `ee` | illegal `em` |
| **c0 = M** | legal | illegal `ms` | illegal `me` | illegal `mm` |

Eight legal, eight illegal, and the eight illegal entries are exactly the
`illegal_bins` in the source, named `<c0><c1>`. The **I** row and column are
legal throughout for a simple reason: an invalid cache holds no copy, so it
constrains nobody.

The table is also asymmetric in name only — `se` and `es` are distinct bins
because the cross is over ordered pairs, but they describe the same physical
violation seen from opposite cores. Keeping both named separately means a failure
report says *which* cache was the exclusive holder.

Unreachable cross bins (same state with no tag change; allocation producing an
invalid line) are excluded with `ignore_bins` so that 100 % is an achievable
target rather than a permanently unreachable one.

### Coverage reporting

There is no tool coverage database in the target flow, so
[cache_coverage.sv](verif/env/cache_coverage.sv) prints its own table from
`final_phase` using `get_inst_coverage()` and `$get_coverage()`:

```
UVM_INFO ... [COV] ---------------- functional coverage ----------------
UVM_INFO ... [COV]   cg_core    ..... %
UVM_INFO ... [COV]   cg_bus     ..... %
UVM_INFO ... [COV]   cg_mesi    ..... %
UVM_INFO ... [COV]   cg_alloc   ..... %
UVM_INFO ... [COV]   cg_axil    ..... %
UVM_INFO ... [COV]   cg_share   ..... %
UVM_INFO ... [COV]   OVERALL    ..... %
```

This is simulator-independent and survives flows that cannot merge UCDBs.

**Every run is independent — coverage does not accumulate.** Each run launches a
fresh `simv`, the covergroups are constructed in the coverage component's
constructor, and nothing is written to disk. `get_inst_coverage()` therefore
reports what *this one simulation* sampled and nothing else. Running twelve tests
in sequence does not produce a twelve-test number; it produces twelve unrelated
numbers. Since different tests close different bins — the directed walk closes
transitions the random tests miss, `eviction_test` closes victim states nothing
else reaches — the true union is strictly higher than any figure quoted in this
README. Merging requires a coverage database (`vcs -cm line+cond+fsm+branch`,
then `urg`), which is the first item under
[Future extensions](#1-a-simulator-without-a-licence-ceiling).

---

## Assertions

| File | Scope | Representative properties |
|---|---|---|
| [verif/sva/cache_sva.sv](verif/sva/cache_sva.sv) | `bind` into every `l1_cache` | OBI request stability and payload stability; exactly one response per accepted request; **`a_grant_excludes_snoop`** — a cache holding a grant is never snooped, which is the assumption the whole no-transient-state argument rests on; `a_op_frozen_while_granted`; `a_bus_progress` |
| [verif/sva/bus_sva.sv](verif/sva/bus_sva.sv) | interconnect | grant and response one-hot-zero; ownership never transfers without an idle cycle; snoop never targets the owner; **`a_single_pass_dirty`** — at most one cache may supply dirty data, because at most one may hold it |
| [verif/sva/axil_sva.sv](verif/sva/axil_sva.sv) | AXI4-Lite | per-channel valid/payload stability until ready, `OKAY` responses, address alignment, no `B` without a preceding `AW` **and** `W`, no `R` without `AR` |

`cache_sva` is attached with `bind`, so the assertions live outside the RTL and
are instantiated per cache automatically.

---

## Stimulus

### Directed vs constrained-random

Eight of the eleven virtual sequences are **constrained-random** and differ only
in how tightly they are constrained — narrowing the address window, fixing the
set, or pinning the load/store mix in order to steer randomisation at a
particular coherence behaviour.

Three are **fully directed**, and they exist for reasons random stimulus cannot
cover:

| Directed sequence | Why it must be directed |
|---|---|
| `mesi_walk_vseq` | Walks every legal same-line MESI transition in a known order on an empty cache. Closes `cg_mesi` **by construction** instead of hoping a seed reaches `M→S`. A failure names the exact transition rather than "somewhere in 80 random accesses". |
| `upgrade_race_vseq` | Deliberately creates the `CleanUnique`→`ReadUnique` degradation — the one race an atomic bus does not remove. Random traffic hits it only by coincidence. |
| `producer_consumer_vseq` | Message-passing litmus test. The ordering claim it checks is meaningless unless the ordering is fixed. |

The directed sequences drive both cores through `do_access()`, which blocks until
`rvalid`, so calling it sequentially gives a strict interleaving between the two
caches. That determinism is the whole point.

### Core-level sequences ([verif/agents/core_agent/core_seq_lib.sv](verif/agents/core_agent/core_seq_lib.sv))

| Sequence | Intent |
|---|---|
| `core_base_seq` | Random ops over a configurable address region, with a `store_pct` weight |
| `core_line_seq` | All traffic inside one line — the false-sharing primitive |
| `core_pingpong_seq` | All traffic to one word |
| `core_set_conflict_seq` | More live tags than ways in a chosen set, forcing evictions and writebacks |
| `core_store_streak_seq` | Repeated stores to one address — silent `E→M` then long runs of `M` hits with no bus traffic at all |
| `core_read_only_seq` | Loads only, so lines settle into `S`/`E` |
| `core_single_seq` | One explicit access, for directed litmus sequences |

### Virtual sequences ([verif/env/seq_lib/cache_vseq_lib.sv](verif/env/seq_lib/cache_vseq_lib.sv))

The base virtual sequence forks one core-level sequence per core; subclasses only
override `run_core_seq()`.

| Virtual sequence | Coherence behaviour it targets |
|---|---|
| `random_vseq` | Broad random traffic |
| `shared_region_vseq` | Both cores confined to four lines — maximum coherence pressure |
| `false_sharing_vseq` | Same line, different words: invalidation storms with no real data sharing |
| `pingpong_vseq` | Same word: ownership migrates on nearly every access |
| `eviction_vseq` | Both cores thrashing the same set |
| `read_mostly_vseq` | Wide `S` sharing that stays stable |
| `store_streak_vseq` | Bursts of stores to one address, then a new one — silent `E→M`, long bus-silent `M` runs, then migration |
| `producer_consumer_vseq` | **Directed.** Message-passing litmus test (below) |
| `mesi_walk_vseq` | **Directed.** Every legal MESI transition, in order, on an empty cache |
| `upgrade_race_vseq` | **Directed.** Simultaneous stores from `S` to force an upgrade to degrade |
| `mixed_vseq` | Chains 3–6 randomly chosen phases in one seed — the regression workhorse |

### Message-passing litmus test

Core 0 writes a payload, then sets a flag **on a different cache line**. Core 1
spins on the flag and, once it observes value *k*, must see payload *k*.

Because the caches are blocking and the bus is atomic, the memory model is
sequentially consistent and the payload can never be stale. The sequence asserts
this explicitly, and the golden-memory checker would independently catch a
violation. It is a small test that makes the consistency claim concrete.

### Tests ([verif/tests/cache_tests.sv](verif/tests/cache_tests.sv))

Twelve tests. Each is a thin wrapper selecting a virtual sequence — build,
objection handling and drain are inherited from `cache_base_test` — so a test
carries no logic of its own. It is a statement about *which architectural
mechanism is being placed under stress*, and nothing more.

The organising principle is **attribution**. A cache is a small set of
interacting mechanisms: lookup, allocation, replacement, writeback, snoop
response, ownership transfer. A random workload exercises all of them at once, so
when one fails the failure is real but unattributable. Each test below constrains
stimulus until a single mechanism dominates the traffic, so that a failure
implicates that mechanism rather than the design as a whole.

#### Structural

**`smoke_test`** — fifteen random loads and stores per core, spread over the
default 4 KB region.

Not intended to find protocol bugs; intended to establish that the *measuring
apparatus* works. A coherent cache is observable only through the driver
handshake, the bus monitor, the whitebox probe and the golden memory, and all
four must be functioning before any statement about the design means anything.
Fifteen transactions is deliberately too short to construct a subtle coherence
scenario, and that is what makes it a clean test of infrastructure: what fails
here is the testbench, not the cache.

**`random_test`** — 40 to 90 random accesses per core over 4 KB, with the
load/store mix itself randomised.

Architecturally the weakest coherence test in the suite and the strongest
structural one. Addresses are spread widely, so most accesses miss in a way that
involves no other cache and coherence events are comparatively rare; but the same
spread produces many distinct tags per set, natural capacity pressure, and index
and tag decode exercised across their full range. It asks whether the addressing
and allocation machinery is right, with coherence as incidental traffic.

#### Coherence pressure

These narrow the address space until sharing becomes the dominant behaviour
rather than a rare event. Each isolates a different consequence of sharing.

**`shared_region_test`** — the same random traffic as `random_test`, but confined
to four cache lines.

The question is what happens when the *rate* of coherence events approaches the
rate of accesses. In a widely spread workload a cache spends most of its time in
the uncontended hit path; here it spends most of its time responding to snoops or
waiting for the bus. Any dependence on quiet periods between coherence events is
exposed here. A design that is correct only because snoops are rare has not been
tested.

**`false_sharing_test`** — one randomly chosen line, both cores accessing it, but
each mostly touching different words within it.

Coherence operates on lines; programs operate on words. False sharing is the case
where those two granularities disagree, and it is what separates *invalidation*
from *data loss*. When core 0 writes word 0 and core 1 writes word 1 of the same
line, correctness requires that ownership transfer carry the whole line
faithfully — including the words the requester is not writing. A design that
fills correctly but merges incorrectly is indistinguishable from a correct one
under genuine sharing, because both cores read the same word. This test exists to
make that distinction observable.

**`pingpong_test`** — one randomly chosen word, hammered by both cores, with the
mix pinned near 50/50 loads and stores.

Ownership migrates on nearly every access, which is the highest sustained rate of
state change the protocol permits. This is the *ownership transfer* test: every
mechanism involved in moving a line between caches — snoop lookup, response
encoding, dirty intervention, invalidation — runs continuously, with no idle path
in between. It is correspondingly the heaviest load the arbiter sees, since both
caches are requesting the bus almost constantly.

**`eviction_test`** — one randomly chosen set, both cores cycling through more
distinct tags than there are ways, weighted 50–90 % stores.

This is the *replacement and writeback* test, and the only one that stresses the
interaction between coherence and capacity. Everywhere else in the suite a line
leaves a cache because another cache asked for it; here a line leaves because the
cache needed the way. Those are different paths with different obligations. In
particular, a modified line evicted for capacity reasons must be written back,
and since nothing external requested it, nothing external will notice if it is
silently dropped. That is precisely why the end-of-test memory reconciliation
does real work only in this test.

**`read_mostly_test`** — loads only, no stores at all, over eight lines.

The property of interest is negative: once a set of lines has been read into **S**
by both caches, the protocol should generate no further bus traffic at all. The
test asks whether the design recognises *stable sharing* — that a shared line
requires no action on a read hit — and whether `IsShared` is derived from the
actual presence of other copies rather than assumed. A cache installing **E**
while a sharer exists violates the single-writer/multiple-reader invariant
immediately, and a read-only workload is the cleanest place to observe that,
because nothing else is happening.

**`store_streak_test`** — two to four bursts per core, each burst being repeated
stores to a single address, with a new address chosen between bursts. Confined to
four lines so the cores collide.

This targets the **M**-hit silence, where correct behaviour is the absence of an
action. A cache holding a line in **M** may modify it repeatedly with no bus
transaction at all, because no other cache can be affected. That is a performance
property rather than a correctness one, and a design that broadcasts
unnecessarily still returns correct data — which is why it is invisible to a data
checker and observable only through bus-transaction counts. The address changes
between bursts are what make periods of silence alternate with genuine ownership
acquisition.

**Measured: 90 stores produced 5 bus transactions.** One `ReadUnique` per new
address, then nothing — 85 of 90 stores were completely silent, and the run
finished in 3.4 us, the fastest in the suite.

*What this test does **not** cover.* MESI has a second silent path, the `E→M`
upgrade, and this sequence cannot reach it. Entering **E** requires a
`ReadShared` that finds no other holder, and `ReadShared` is only issued on a
*load* miss. `store_streak_test` issues no loads at all (`loads=0`,
`ReadShared=0`), so every acquisition is a `ReadUnique` straight to **M** and no
line is ever **E**. The `E→M` upgrade is covered by `mesi_walk_test`, which loads
before storing. Two silent paths, two different tests — an earlier draft of this
section claimed both were covered here, which the traffic counters disproved.

#### Directed

Three sequences abandon randomisation, each for a specific reason. All three
drive the cores through a blocking helper that does not return until `rvalid`, so
the interleaving between the two caches is fixed rather than a property of the
seed.

**`mesi_walk_test`** — ten specific accesses across three adjacent lines, chosen
so that the two caches walk every legal same-line MESI transition in a known
order, starting from an empty cache.

The purpose is *constructive* coverage: the MESI transition graph is small enough
to traverse exhaustively, so leaving that traversal to chance is a choice to be
less certain for no benefit. Its diagnostic role matters equally. Because each
access completes before the next begins, the transition sequence is a property of
the test rather than of the seed, and a failure identifies a named transition
instead of a position in a random stream.

**`producer_consumer_test`** — core 0 writes a payload to one line then a counter
to a *second* line; core 1 polls the second line and, on seeing counter value *k*,
reads the first line and requires payload *k*. Repeated four to twelve times.

The distinction being drawn is between **coherence** and **consistency**.
Coherence is a per-line property, and both lines here are independently coherent
regardless of the order in which the two writes become visible; nothing in MESI
alone forbids the flag being seen before the payload. The property under test
belongs to the memory model, and it holds in this design for a structural
reason — the caches are blocking and the bus is atomic, so no core can have two
accesses in flight and no two accesses can be reordered. The test makes that
argument checkable rather than merely asserted.

**`upgrade_race_test`** — for each of four to eight lines, taken consecutively
from the region base: both cores load it so both hold **S**, then both issue a
store to it in the same instant.

An atomic bus removes almost every race in the design by construction; this test
targets the one it does not. A cache that decides to issue `CleanUnique` while in
**S** may lose arbitration and be invalidated before it is granted, at which point
its pending request is stale — it no longer holds the line, so an upgrade would
grant write permission over data it does not have. Correct behaviour is to
re-derive the request at grant time and issue `ReadUnique` instead. The race
requires both caches to be waiting on the bus simultaneously, which cannot be
forced with certainty from the core interfaces; zero-delay stores against a bus
transaction tens of cycles long make the overlap reliable, and repetition across
lines makes it near-certain.

#### Composite

**`regression_test`** — three to six of the above sequences, chosen at random and
run back to back in a single simulation without an intervening reset.

Every other test begins from reset and therefore examines mechanisms in a cache
whose history is known. This one deliberately does not. The region of interest is
the *phase boundary*, where the tag and state arrays left by one access pattern
become the initial condition for a completely different one: a set thrashed to
full occupancy then subjected to read-only sharing, or a line held in **M**
meeting a workload that never touches it again. These are states no
single-pattern test constructs, and they are where residual-state bugs live.

---

Memory latency is randomised per test through `axil_agent_cfg`, so the timing
relationship between line fills and coherence traffic varies seed to seed rather
than being fixed by the testbench. A test that passes only at one memory latency
has not really passed.

`+num_txns=<n>` overrides sequence length on the seven tests whose stimulus is a
length-parameterised core sequence — `smoke`, `random`, `shared_region`,
`false_sharing`, `pingpong`, `eviction`, `read_mostly`. The count is **per
core**, so `+num_txns=30` on a two-core configuration issues sixty accesses.

The other five ignore it, because their length is not a transaction count: the
three directed sequences override `body()` entirely and are sized by rounds or
messages, `store_streak_vseq` is sized by `n_streaks`, and `mixed_vseq`
re-randomises a length per phase.

---

## Bug injection

Five deliberate RTL bugs sit behind `+define+BUG_n`. Every one of these runs
**must fail** — a clean run means the checkers are blind to that bug and the
environment needs work. This is the cheapest possible evidence that the
testbench actually checks something.

**All five are detected.** Results and the per-mechanism breakdown are at the
[end of this section](#all-five-side-by-side).

| Define | Injected bug | Caught by | Status | Evidence |
| --- | --- | --- | --- | --- |
| `BUG_1` | Snooped **M** line goes to **E** instead of **S** on `ReadShared` | `cg_mesi` illegal bin `m_to_e` | **DETECTED** at 1.46 us | [view](docs/screenshots/bug_1.png) |
| `BUG_2` | `CleanUnique` does not invalidate the sharer | `cg_share` illegal bin `ms` | **DETECTED** at 7.68 us | [view](docs/screenshots/bug_2.png) |
| `BUG_3` | Store hit ignores byte enables | Golden-memory load mismatch | **DETECTED** — 11 errors, exit 0 | [view](docs/screenshots/bug_3.png) |
| `BUG_4` | Dirty victim evicted without a writeback | `cg_mesi` illegal bin `dirty_dropped` | **DETECTED** at 3.67 us | [view](docs/screenshots/bug_4.png) |
| `BUG_5` | `ReadShared` always installs **E** | `cg_share` illegal bin `se` | **DETECTED** at 1.80 us | [view](docs/screenshots/bug_5.png) |

Put the define in **Compile Options** on Playground and run `eviction_test`:

| Compile Options | Run Options |
|---|---|
| `+define+BUG_2` | `+UVM_TESTNAME=eviction_test +num_txns=30` |

`eviction_test` is used for all five because it is the only test that produces
writebacks, without which `BUG_2` and `BUG_4` cannot manifest at all.

### Detection is a property of the bug *and* the stimulus

A bug-injection run that passes has two possible meanings, and they are not
equally interesting:

1. the checkers cannot see this class of defect — a real hole
2. the stimulus never created the conditions the defect needs — a test-selection
   mistake

`BUG_4` makes the distinction concrete. It disables writeback of dirty victims,
so it can only manifest when a **M** line is evicted for capacity. Under
`smoke_test` or `pingpong_test` no eviction ever occurs, so the run passes and
proves nothing whatsoever. Only `eviction_test` puts the design in a state where
the mutation has an effect.

This is measurable rather than hypothetical. The clean `smoke_test` run reported
`CleanUnique=0 WriteBack=0`, which means `BUG_2` and `BUG_4` are **provably**
undetectable under it — the mutated lines never execute. And detection latency
tracks how often the mutated path runs: on `eviction_test`, `BUG_1` sits on a
path taken 17 times and was caught at 1.46 us, while `BUG_2` sits on a path taken
twice and was caught at 7.68 us.

Each bug below therefore records the stimulus it requires, not just the checker
that should fire. Predictions are written before the run so that the comparison
afterwards means something.

### `BUG_1` — snooped **M** goes to **E** — **DETECTED**

```systemverilog
BUS_READ_SHARED:  state_q[sn_idx][sn_way] <= MESI_E;   // should be MESI_S
```

*Why it is wrong.* A cache being snooped by `ReadShared` is about to have a
second copy of the line exist. It must therefore drop to **S**. Staying in **E**
claims exclusivity that no longer holds, and if it was in **M** it also silently
discards the dirty marking.

*Required stimulus.* Another cache must issue `ReadShared` for a line this cache
holds. `eviction_test` is 50–90 % stores on a single shared set, so dirty lines
being snooped is the common case rather than a rare one.

*What we wanted to see.* The `cg_mesi` illegal bin `m_to_e`, early, naming the
transition.

*What happened.* Exactly that, at 1.455 us — inside the first 8 % of a run that
takes 18.7 us clean:

```
Error-[FCIBH] Illegal bin hit
  At time 1455000 ps, Illegal bin m_to_e of cross x_trans in covergroup
  cache_uvm_pkg::cache_coverage::cg_mesi got hit with sample values
  cp_old=MESI_M cp_new=MESI_E cp_tagc=0x0
Exit code expected: 0, received: 1
```

*Nuance worth recording.* `m_to_e` only fires when the snooped line was **M**.
Had the snooped line been **E** or **S**, the transition would have been `E→E`
(no state change, so no probe event and no sample at all) or `S→E`, and detection
would have fallen to `cg_share` and the SWMR sweep instead. The same bug is
caught by different checkers depending on the workload — which is an argument for
having both, not a redundancy to trim.

### `BUG_2` — `CleanUnique` does not invalidate the sharer — **DETECTED**

```systemverilog
BUS_CLEAN_UNIQUE: state_q[sn_idx][sn_way] <= state_q[sn_idx][sn_way];  // should be MESI_I
```

*Why it is wrong.* `CleanUnique` is the upgrade path: the requester holds **S**
and wants **M** without refetching data. Every other copy must be invalidated. If
the sharer keeps its **S** copy, the result is **M** and **S** coexisting — a
direct SWMR violation, and the sharer's copy is now stale.

*Required stimulus.* A line held **S** by both caches, then a store from one.

*What we predicted, before running it.* **Not** `cg_mesi`. The snooped cache
undergoes no state change at all, so no probe item is emitted for it and a
transition-based check has nothing to look at. Expect `cg_share`'s `ms` or `sm`
illegal bin to fire when the *requester* transitions `S→M`, aborting with exit 1.

*What happened.* Exactly that:

```
Error-[FCIBH] Illegal bin hit
  At time 7675000 ps, Illegal bin ms of cross x_pair in covergroup
  cache_uvm_pkg::cache_coverage::cg_share got hit with sample values
  cp_c0=MESI_M cp_c1=MESI_S
Exit code expected: 0, received: 1
```

The negative half of the prediction is the interesting half. `cg_mesi` is at
98.95 % on this stimulus and saw nothing, because **there is no transition to
see** — the sharer's state is unchanged and the probe monitor only emits on
change. Detection required reading *both* caches at one instant, which is what
`cg_share` does through `state_of()` at every probe event. A per-cache view of a
coherence protocol is structurally insufficient, and this is the run that shows
it rather than arguing it.

*Detection latency is 5× that of `BUG_1`,* and the reason is worth stating. On
the clean run `eviction_test` produced `ReadShared=17` but `CleanUnique=2`. The
mutated path executes twice in the entire test, so the bug has to wait for one of
those two events. `BUG_1` sits on a path taken seventeen times and was caught at
1.46 us; `BUG_2` sits on a path taken twice and was caught at 7.68 us.

The corollary is a hazard: `smoke_test` reported `CleanUnique=0` on its clean
run, so `BUG_2` is **provably undetectable** under that test. Not a checker
weakness — the stimulus simply never executes the mutated line.

### `BUG_3` — store hit ignores byte enables — **DETECTED**

```systemverilog
data_q[rq_idx][hit_way] <= line_set_word(..., rq_wdata_q, '1);   // should be rq_be_q
```

*Why it is wrong.* A partial-word store overwrites the bytes it was not asked to
write. This is a pure data-path defect.

*Required stimulus.* A store with `be != '1`, followed by an observation of the
clobbered bytes — either a later load of that word, or the line reaching memory
so end-of-test reconciliation sees it.

*What we predicted, before running it.* Every MESI state, transition and
cross-cache pair remains legal, so no illegal bin can fire and no assertion can
fail. Detection must come from the golden memory alone, and the run should look
entirely unlike `BUG_1`: `UVM_ERROR`s from the scoreboard, simulation to
completion, a full coverage table, and **exit code 0**.

*What happened.* All of it, and one thing stronger than predicted.

```
UVM_ERROR [SB_DATA]  load mismatch: c0 LD addr=0x0000022c rdata=0x1d4972af expected=0x9d4972af
UVM_ERROR [SB_FINAL] addr 0x00000024 expected=0xa7671c07 actual=0xa7676b07
...
UVM_ERROR :   11        [SB_DATA] 5     [SB_FINAL] 6
$finish at simulation time  18655000
```

**The coverage table is byte-identical to the clean run.** Same 94.53 % overall,
same figure in all six groups, same `$finish` time, same scoreboard traffic
counters — `loads=28 stores=32`, `ReadShared=17 ReadUnique=19 CleanUnique=2
WriteBack=14`, 68 transitions. The control path is bit-for-bit unchanged; only
the data differs.

That is the most useful result in this set. **A functional coverage score of
100 % would not have found this bug**, because the bug does not change what the
design *does*, only what it *stores*. Coverage closure and correctness are
different claims, and this run is the concrete demonstration rather than the
usual assertion of it.

*Three further details worth reading off the log.*

**The mismatch pattern identifies the bug class.** `0x1d4972af` against
`0x9d4972af` differs in one byte; `0x422cb824` against `0xaed77d24` agrees only
on the low byte. The disagreements are byte-granular and the *agreeing* bytes are
exactly the ones the store had enabled. A control-path bug would have corrupted
whole words or returned the wrong line entirely.

**Both cores observe the same wrong value.** Address `0x328` mismatched on core 1
at 11.46 us and on core 0 at 13.66 us with identical data. Coherence is working
perfectly — it is faithfully propagating corruption. Coherence guarantees that
all cores agree on a line's contents, not that those contents are right.

**End-of-test reconciliation earned its place.** Of the six `SB_FINAL`
mismatches, four are at addresses no load ever touched. Without that check those
four corruptions would have gone unreported, since nothing in the test ever read
them back.

### `BUG_4` — dirty victim evicted without a writeback — **DETECTED**

```systemverilog
assign wb_needed = 1'b0;   // should be (state_q[rq_idx][vic_q] == MESI_M)
```

*Why it is wrong.* The cache skips `ST_WB` entirely and overwrites the victim way
in place, so a modified line is destroyed without its data ever reaching memory.

*Required stimulus.* A capacity eviction of a line in **M**. `eviction_test` is
the only test that reliably produces one — it reported `WriteBack=14` on the
clean run.

*What we predicted.* Two independent detectors, and it was worth knowing which
would win. The victim way goes from **M** straight to the new line's tag and
state, so the probe emits an event with `old_state = MESI_M` and
`tag_changed = 1`. That should trip `cg_alloc`'s `illegal_bins dirty` and
`cg_mesi`'s `dirty_dropped`. Failing both, end-of-test reconciliation should
report the lost line.

*What happened.* `cg_mesi` fired at 3.665 us:

```
Error-[FCIBH] Illegal bin hit
  At time 3665000 ps, Illegal bin dirty_dropped of cross x_trans in covergroup
  cache_uvm_pkg::cache_coverage::cg_mesi got hit with sample values
  cp_old=MESI_M cp_new=MESI_M cp_tagc=0x1
Exit code expected: 0, received: 1
```

`cp_old=M`, `cp_new=M`, `cp_tagc=1` reads as: this way held a modified line, now
holds a *different* modified line, and no writeback occurred in between. Note
that `dirty_dropped` is defined on `cp_old` and `cp_tagc` only, deliberately
ignoring the new state — a dirty victim is lost regardless of what replaces it.

*Which detector won, and why it is not a meaningful ranking.* `cg_mesi` beat
`cg_alloc` purely because of statement order inside `write_probe`:

```systemverilog
cg_mesi.sample(...);                       // sampled first, aborts here
if (it.new_state != MESI_I && (...))
  cg_alloc.sample(...);                    // never reached
```

Both covergroups are sampled from the same analysis write, on the same probe
item, so they would both have caught this on the same event. The illegal bin
simply terminates the simulation at the first one evaluated. The end-of-test
reconciliation — the third candidate — never ran at all.

That is worth stating plainly rather than claiming three independent detections:
**one detector fired, and two more were demonstrably reachable but unproven on
this run.** Confirming the other two would mean removing `cg_mesi`'s bin and
re-running, which is a reasonable experiment but not one that changes the
verdict.

### `BUG_5` — `ReadShared` always installs **E** — **DETECTED**

```systemverilog
BUS_READ_SHARED: fill_state = MESI_E;   // should be bus.rsp_shared ? MESI_S : MESI_E
```

*Why it is wrong.* `IsShared` in the snoop response exists to tell the requester
whether anyone else holds the line. Ignoring it means claiming exclusivity while
a sharer exists.

*Required stimulus.* A `ReadShared` that another cache actually hits — genuine
sharing rather than a cold miss.

*What we predicted, before running it.* Again **not** `cg_mesi`: `I→E` is a
perfectly legal transition and the bug is invisible to a per-cache transition
check. The `cg_share` illegal bins are the intended detector, since the resulting
pair is **E** alongside **S** or **E** alongside **E**.

*What happened.* Caught at 1.795 us by `cg_share`:

```
Error-[FCIBH] Illegal bin hit
  At time 1795000 ps, Illegal bin se of cross x_pair in covergroup
  cache_uvm_pkg::cache_coverage::cg_share got hit with sample values
  cp_c0=MESI_S cp_c1=MESI_E
Exit code expected: 0, received: 1
```

Core 1 issued `ReadShared` for a line core 0 held, the interconnect correctly
reported `IsShared`, and core 1 installed **E** anyway — leaving core 0 in **S**
beside an exclusive owner.

*Why the bus checks could not have caught it.* This is the sharpest instance of a
theme running through all five bugs. `bus_sva` and `cg_bus` watch the
interconnect, and the interconnect here is **behaving perfectly**: it snooped
correctly, aggregated the hit correctly, and returned `IsShared` correctly. Bus
traffic under `BUG_5` is indistinguishable from a clean run. The defect is
entirely in how the requester *consumes* a correct response, so only a check that
inspects the resulting cache state can observe it.

Together with `BUG_2` this is the argument for `cg_share` stated twice over: two
different mutations, on two different code paths, neither visible to the
transition check or the bus check, both caught by looking at two caches at once.

### An illegal bin hit is fatal, and that is useful

Three properties of the `BUG_1` output generalise.

**It names the defect, not a symptom.** The message is the injected mutation
stated back verbatim — a line went from **M** to **E** with no tag change. There
is no inference step between the failure and the cause.

**It fires early**, because a covergroup samples continuously rather than waiting
for data to be observed. A golden-memory checker cannot complain until the
corrupted value is actually read back, which may be thousands of cycles later or
never in that seed.

**It sets a non-zero exit code**, which is the direct counterpoint to
[O-001](docs/DEBUG_LOG.md): SVA failures never reach the UVM report server, so
grepping `UVM_ERROR` can report a false pass. Of the three reporting mechanisms
in this environment, only an illegal bin aborts and exits 1 — see
[O-005](docs/DEBUG_LOG.md) for the full table.

The cost is that the run **aborts**: no scoreboard summary, no coverage table.
`BUG_1` also violates SWMR, and the scoreboard would have caught it moments
later, but that never happens. The redundancy is real and this run does not
demonstrate it. Showing defence in depth would require temporarily removing the
illegal bins, which is not worth doing to make a point about a bug already caught
precisely and early.

### All five, side by side

| Bug | Detected by | First error | Exit |
|---|---|---|---|
| `BUG_1` | `cg_mesi` illegal bin `m_to_e` | 1.46 us | 1 |
| `BUG_5` | `cg_share` illegal bin `se` | 1.80 us | 1 |
| `BUG_4` | `cg_mesi` illegal bin `dirty_dropped` | 3.67 us | 1 |
| `BUG_3` | golden memory (`SB_DATA`, `SB_FINAL`) | 7.64 us | **0** |
| `BUG_2` | `cg_share` illegal bin `ms` | 7.68 us | 1 |

"First error" is when detection occurred, not when the run ended. The four
illegal-bin rows abort at that instant; `BUG_3` runs on to `$finish` at 18.66 us
and accumulates eleven errors, the last at 13.66 us.

No single mechanism catches more than two. `cg_mesi` is blind to `BUG_2`,
`BUG_3` and `BUG_5`; `cg_share` is blind to `BUG_3`; the golden memory would
eventually have caught most of them but far later and less precisely. The three
checking strategies are complements, not alternatives, and this table is the
evidence for that rather than an assertion of it.

---

## Running it

Step-by-step setup is in [docs/SETUP.md](docs/SETUP.md).

### The loop

Sources are edited in one place and run in two, so the cycle is fixed:

```
edit rtl/ or verif/
   -> Questa: vlog + vopt          catches syntax and structure across 37 files
   -> python sim/bundle_playground.py   flattens the tree into two panes
   -> Playground: paste + Run      VCS + UVM 1.2, the only place it simulates
```

37 files = the 13 listed in `sim/braytcache.f` plus the 24 `` `include ``d into
`cache_uvm_pkg.sv`.

The Questa step is not optional even though it cannot simulate. It is the fast
filter: a missing semicolon or a bad hierarchical reference is found in seconds
against the real filelist, instead of after a manual copy-paste into a browser.

**Which pane to re-paste** after an edit — the bundler rewrites both files every
time, but only one usually changes:

| Changed | Re-paste |
|---|---|
| `rtl/`, `verif/sva/` | **Design** |
| `verif/agents/`, `verif/env/`, `verif/tests/`, `verif/tb/` | **Testbench** |

### Toolchain

Two simulators, because neither alone is sufficient.

| Tool | Used for | Why |
|---|---|---|
| **Questa–Intel/Altera FPGA Starter Edition 2025.2** | compile + elaborate | Free tier. `vlog` and `vopt` work fully, so the whole design can be structurally checked locally. `vsim` refuses to *load* a design containing `randomize`/`covergroup` without an `svverification` licence, which the free tier does not include. |
| **Synopsys VCS on EDA Playground** | simulation | Free with a verified account, full UVM 1.2, no restriction on verification features. |

Running under both is worth more than either alone. Questa caught a `bind` at
compilation-unit scope that would have silently dropped every per-cache
assertion; VCS caught a `#1` before `run_test()` that UVM 1.1d tolerates and UVM
1.2 fatals on. Neither tool would have found the other's bug.

The filelist `sim/braytcache.f` is tool-agnostic — only the driver script is
Questa-specific, because that is the one tool available to script against.

### Local: compile and elaborate

Catches syntax and structural errors across all 37 files without simulating.
Straight into Questa's Transcript:

```tcl
cd {<repo>/braytcache/sim}
vlib work
vlog -sv -mfcu +acc=rn -timescale 1ns/1ps -f braytcache.f
vopt +acc=rn -L mtiUvm tb_top -o tb_opt
```

There is no project file and no build script in this path — those four commands
are the whole flow. `sim/Makefile` wraps them, but none of its targets has ever
run here: Git Bash ships no GNU Make and `vsim` is licence-blocked anyway. It is
kept as the shape the flow would take given a licence, and says so in its header.

### Simulation: EDA Playground

Playground cannot resolve `+incdir`, so the tree is flattened into the two panes
it expects, expanding all 24 `` `include `` directives inline:

```bash
python sim/bundle_playground.py
#  playground/design.sv       RTL + SVA, no UVM dependency, compiles first
#  playground/testbench.sv    UVM package + tb_top
```

At [edaplayground.com](https://edaplayground.com), **signed in** (anonymous
sessions cannot use the commercial simulators):

| Setting | Value |
|---|---|
| Testbench + Design | `SystemVerilog/Verilog` |
| UVM / OVM | `UVM 1.2` |
| Tools & Simulators | `Synopsys VCS` |
| Run Options | `+UVM_TESTNAME=smoke_test +num_txns=5` |

Paste `design.sv` into the **Design** pane, `testbench.sv` into **Testbench**,
Run. No `+define+` needed — the `cache_pkg.sv` defaults are already the
2-way / 16-set / 16-byte-line / 2-core configuration.

What Playground does with those two panes is a single VCS invocation — worth
knowing, because every error message is reported against `design.sv` or
`testbench.sv` line numbers, not against the original files:

```bash
vcs -full64 -sverilog -timescale=1ns/1ns +incdir+$UVM_HOME/src \
    $UVM_HOME/src/uvm.sv $UVM_HOME/src/dpi/uvm_dpi.cc \
    design.sv testbench.sv  &&  ./simv +UVM_TESTNAME=<test>
```

So the UVM library is compiled from source alongside the design on every run,
the two panes are just two files in order, and **Run Options** are `simv`
plusargs while **Compile Options** are `vcs` switches — which is why `+define+`
belongs in the latter and `+UVM_TESTNAME` in the former.

Leave every checkbox off. Two matter later: *Open EPWave after run* together
with `+dump` for waveform debug, and *Use run.bash* to loop several
`+UVM_TESTNAME` values in one session, since Playground has no regression runner
and caps CPU time.

### Tool capability probes

Because the free Questa tier's licence boundary was unknown, the repo carries
two standalone probes that depend on nothing else in the project:

```tcl
vlog -sv tool_check.sv
vsim -c tool_check -do "run -all; quit -f"
```

`tool_check.sv` reports per stage — classes and constraints, then covergroups
with `illegal_bins` in a cross, then concurrent assertions — so a failure names
the exact missing capability rather than burying it in cascading errors.
`tool_check_uvm.sv` separately confirms the UVM library is present and linked.

This is how the `svverification` licence boundary was identified in minutes
instead of through a wall of confusing output.

### Commands

Every result in this README came from the **Run Options** field on Playground,
one test at a time. The full table of test names and options is in
[docs/SETUP.md](docs/SETUP.md#step-4--every-test-with-its-exact-options):

```
+UVM_TESTNAME=eviction_test +num_txns=30
```

Add `+UVM_VERBOSITY=UVM_HIGH` for transaction tracing, or `+dump` with *Open
EPWave after run* for waves.

With GNU Make and a licence that permits simulation, `sim/Makefile` would
collapse this to `make questa TEST=... SEED=...` and add the two things
Playground cannot do — multi-seed regression and coverage merge. Those targets
are written but unexercised; see [Future extensions](#1-a-simulator-without-a-licence-ceiling).

---

## Results

> **Coverage is the best single run** — `regression_test`, 269 accesses, one seed.
> It is a floor, not a closure figure: there is still no way to merge coverage
> across runs (see
> [Future extensions](#1-a-simulator-without-a-licence-ceiling)), and different
> tests close different bins, so the union is certainly higher than any row here.

| Metric | Value | Evidence |
| --- | --- | --- |
| Compiles (Questa 2025.2, UVM 1.1d, 37 files) | **0 errors, 0 warnings** |
| Elaborates (`vopt`) | **0 errors** |
| Compiles + elaborates (VCS X-2025.06, UVM 1.2) | **0 errors** |
| `smoke_test` | **PASS** — 0 UVM errors, 0 assertion failures | [view](docs/screenshots/smoke_test.png) |
| `mesi_walk_test` | **PASS** — all ten MESI transitions walked | [view](docs/screenshots/mesi_walk_test.png) |
| `pingpong_test` (60 accesses, one word) | **PASS** — 71 ownership migrations | [view](docs/screenshots/pingpong_test.png) |
| `eviction_test` (60 accesses, one set) | **PASS** — 14 writebacks, memory reconciled | [view](docs/screenshots/eviction_test.png) |
| `eviction_test` at **4-way / 8-set** | **PASS** — 0 errors, unchanged sources | [view](docs/screenshots/eviction_test_4way_8set.png) |
| `upgrade_race_test` | **PASS** — 6 of 6 rounds hit the degradation path | [view](docs/screenshots/upgrade_race_test.png) |
| `producer_consumer_test` | **PASS** — ordering held across 2 lines | [view](docs/screenshots/producer_consumer_test.png) |
| `false_sharing_test` | **PASS** — all 4 words of one line, 27 ownership transfers | [view](docs/screenshots/false_sharing_test.png) |
| `store_streak_test` | **PASS** — 90 stores, only 5 bus transactions | [view](docs/screenshots/store_streak_test.png) |
| `read_mostly_test` | **PASS** — 60 loads, zero ownership acquired | [view](docs/screenshots/read_mostly_test.png) |
| `shared_region_test` | **PASS** — `cg_share` closed at 100 % | [view](docs/screenshots/shared_region_test.png) |
| `random_test` (130 accesses, 4 KB) | **PASS** — `cg_alloc` closed at 100 %, 95.80 % overall | [view](docs/screenshots/random_test.png) |
| `regression_test` (269 accesses, 3–6 phases) | **PASS** — **98.92 % overall**, best single run | [view](docs/screenshots/regression_test.png) |
| Tests × seeds passing | **12 of 12**, single seed |
| Geometries passing | **2 of 2** — 2-way/16-set and 4-way/8-set |
| `cg_core` | 99.11 % |
| `cg_bus` | 98.61 % |
| `cg_mesi` | 96.84 % |
| `cg_share` | **100.00 %** |
| `cg_alloc` | 98.96 % |
| `cg_axil` | **100.00 %** |
| Overall functional coverage | **98.92 %** |
| Bug-injection runs detected | **5 / 5** |

---

## What the runs revealed

A pass is the least interesting thing a test produces. These are the findings
worth keeping — the cases where a number was derivable in advance and matched, or
where a run contradicted something the project believed.

The project also identified and resolved five issues during bring-up and
verification. They covered tool-flow integration, simulation setup, RTL
protocol behavior, coverage modeling, and checker correctness. The full
investigations are documented in [docs/DEBUG_LOG.md](docs/DEBUG_LOG.md).

Two findings are especially important: **no single checking mechanism catches
more than two of the five injected bugs**, and the `BUG_3` run returned coverage
**byte-identical** to the clean run while eleven data corruptions were present.
These results show why coherence verification requires complementary data,
state, protocol, and coverage checks.

| Run | Finding |
|---|---|
| `smoke_test` | Exposed **D-003**: `snoop_ack` asserted one cycle while unselected. Found on the very first simulation. |
| `mesi_walk_test` | Exposed **D-004**: `cg_alloc` sampled on tag change, so allocation into a free way was invisible whenever the stale tag matched. |
| `pingpong_test` | Coverage **fell** in three groups despite six times the stimulus of the previous run. |
| `eviction_test` | `cg_alloc` 84.38 % decomposes exactly to `cp_set` at 1 of 16 with every other item at 100 %. |
| 4-way / 8-set | `WriteBack` fell 14 → 3. Associativity absorbing conflict misses, measured in the design's own counters. |
| `upgrade_race_test` | 6 of 6 rounds hit the degradation path; 42 transitions = 7 per round × 6, derived by hand before the run. |
| `producer_consumer_test` | Exposed **D-005**: the checker asserted a property the design never promised and would have failed on correct RTL forever. |
| `false_sharing_test` | All four words of one line stayed correct across 27 ownership transfers. |
| `store_streak_test` | 90 stores produced 5 bus transactions — and disproved a claim in this README. |
| `read_mostly_test` | 24 transitions = 8 lines × 3, proving `IsShared` is derived from real snoop hits rather than assumed. |
| `random_test` | Highest coverage of any *single-pattern* run (95.80 %) — and `CleanUnique=0`, so `BUG_2` would be **undetectable** under it. |
| `regression_test` | 98.92 % overall from one seed. Chaining phases without reset beats every single-pattern test on five of six covergroups. |
| `BUG_3` injection | Coverage came back **byte-identical** to the clean run while 11 data corruptions were present. |

### Which test closes which covergroup

No single test closes the model, and the pattern of *which* test closes *what* is
the useful part:

| Covergroup | Best single run | Why that test |
|---|---|---|
| `cg_core` | `regression_test` 99.11 % | Widest variety of op × address × byte-enable |
| `cg_bus` | `regression_test` 98.61 % | Only run producing all four bus ops in quantity |
| `cg_mesi` | `eviction_test` 98.95 % | Capacity pressure forces transitions sharing cannot |
| `cg_share` | **100 %** — `eviction`, `shared_region`, `regression` | Needs both caches on the same line repeatedly |
| `cg_alloc` | **100 %** — `random_test` | Needs allocations spread across all 16 sets |
| `cg_axil` | **100 %** — most runs | Four beats per line, reached quickly |

`cg_alloc` is the clearest case. It sits at 42–50 % in every test that pins one
set, closes completely under wide random traffic, and reaches 98.96 % under the
mixed regression. The number is a property of the *address distribution*, not of
the design.

### Coherence intensity spans a factor of eighteen

Bus transactions per 100 core accesses, across the suite:

| | `store_streak` | `read_mostly` | `false_sharing` | `regression` | `pingpong` | `eviction` | `random` |
|---|---|---|---|---|---|---|---|
| bus ops / 100 accesses | **5.6** | 27 | 45 | 55 | 60 | 87 | **103** |

`store_streak` is nearly bus-silent because runs of **M** hits need no
transaction. `random_test` exceeds 100 because a small cache against a 4 KB
working set misses on almost every access, and 16 of those misses also required a
writeback. That spread is the evidence the suite is not twelve variations of one
workload.

Four of these are written up in full, with reasoning and alternatives rejected,
in [docs/DEBUG_LOG.md](docs/DEBUG_LOG.md). The cross-cutting lessons:

**Coverage percentage is not a correctness claim.** `BUG_3` changed no state, no
transition, no bus operation and no allocation decision, so the coverage model
registered nothing at all while the golden memory reported eleven corruptions.
100 % functional coverage would not have found it. See
[O-006](docs/DEBUG_LOG.md).

**Coverage percentages are not comparable across configurations.** The 4-way
build reports a *lower* `cg_alloc` than the 2-way build, because `cp_way` went
from 2 bins to 4 and `x_victim_way` from 6 to 12 while allocation events became
rarer. More bins to fill, fewer events to fill them with. See
[O-009](docs/DEBUG_LOG.md).

**Detection latency tracks how often the mutated path executes.** Across the four
bugs that abort on an illegal bin, path executions of 17, 17, 14 and 2 map to
detection at 1.46, 1.80, 3.67 and 7.68 us — monotonic, with execution frequency
the only variable. See [O-007](docs/DEBUG_LOG.md).

**The traffic counters catch things no checker can.** `store_streak_test` passed
cleanly, but its `[SB]` line showed `ReadShared=0`, which meant no line was ever
in **E** — so the test could not possibly exercise the `E→M` silent upgrade this
README claimed it covered. A documentation error, found by reading counters on a
green run rather than by any check firing.

**A number that matches a hand derivation is worth more than a pass.** Three runs
produced counts predictable in advance: `upgrade_race_test` at 42 transitions,
`read_mostly_test` at 24, and `BUG_1`/`BUG_5` both landing on the `ReadShared`
path within 1.8 us. Agreement between prediction and measurement means the
mechanism is understood, not merely working.

**The highest-coverage test is not the most thorough one.** `random_test` reports
95.80 % overall, the best of any single run, and closes `cg_alloc` at 100 %
because a wide address spread reaches every set, way and victim state. It also
reports `CleanUnique=0`: across 130 accesses over 4 KB, no store ever hit a line
another cache held in **S**, because collisions on the same line at the same
moment are rare when the address space is large. The upgrade path — and therefore
`BUG_2` — is unreachable in the run with the best coverage number. A single
percentage cannot express that.

---

## Scope decisions and limitations

The *reasoning* is in [Design decisions](#design-decisions). This list is of what is not built, and is related to [Future extensions](#future-extensions).
matters:

- **Atomic bus, so no transient states.** The realistic next step is a
  split-transaction bus, which requires MESI transient states and is where most
  of the genuine protocol difficulty lives.
- **Blocking cache with a single outstanding request** No MSHRs, no hit-under-miss, no
  memory-level parallelism.
- **Two cores, snooping, no directory.** Snooping does not scale past a handful
  of cores; a directory protocol is the scalable alternative. 
  - **`cg_share` assumes exactly two cores** and is not constructed otherwise. Sequential consistency here is a *consequence* of blocking caches plus an
  atomic bus, not something the design works to provide. A weaker, faster design
  would need a real memory-model argument.
- **Data cache only.** No instruction cache, no TLB, no virtual addressing.
- **No cache maintenance operations**, no barriers, no atomics/LR-SC.
- **AXI4-Lite has no bursts**, currently, a line fill is `LINE_WORDS` separate
  single-beat transactions.
- **No mid-test reset.** Reset is asserted once at time zero; the drivers assume
  it stays deasserted.

---

## Future extensions  

### A split-transaction coherence bus and transient MESI states

The most valuable next step would be to support transient MESI states.
The current design deliberately uses an atomic coherence bus, which removes the
need for transient states by holding the bus grant through snooping, any required
memory access, and the final response.

- **Split-transaction coherence bus.** Replace the current atomic bus with
  separate request, snoop, data-transfer, and response phases.

- **Transient MESI states.** The current atomic bus prevents a cache from being
  snooped while it owns the bus, allowing every line to remain in one of the
  stable states **I**, **S**, **E**, or **M**. A split-transaction bus would
  require transient states such as `IM_AD` and `SM_AD` to represent requests
  waiting for ownership, data, or completion.

- **In-flight coherence verification.** Extend the UVM environment to verify
  transient-state snoop responses, competing ownership requests, response
  ordering, data forwarding, invalidation races, and recovery from delayed or
  conflicting transactions.

- **More realistic MESI behavior.** This extension would remove the atomic-bus
  simplification that currently keeps the MESI state machine small. 

### Fully specified protocols

The three interfaces implemented in this design are simplified. Each could be taken to the real standard:

- **Full ACE instead of ACE-inspired.** The current coherent bus borrows ACE's
  vocabulary but not its structure. A real implementation means the actual
  AC/CR/CD snoop channels, the complete transaction set (`ReadOnce`,
  `ReadNotSharedDirty`, `CleanShared`, `WriteBack`/`WriteClean`/`Evict`),
  barriers, and DVM. A commercial ACE VIP could be dropped in as an independent reference model.
- **AXI4 with bursts on the memory side.** The current AXI4-Lite interface
  transfers a cache line as `LINE_WORDS` independent single-beat transactions.
  A full AXI4 implementation could represent each line fill or writeback as one
  incrementing burst, using `ARLEN`/`AWLEN` for the burst length and
  `RLAST`/`WLAST` to mark the final beat. Supporting multiple outstanding
  bursts would introduce transaction IDs, response tracking, and
  potentially out-of-order completion, all enhancements to the memory agent.

### Realistic caches

- **Non-blocking with MSHRs** hit-under-miss, multiple outstanding misses, and
  memory-level parallelism. Currently one outstanding miss, which is what keeps
  the scoreboard's ordering argument simple; removing it means reasoning about
  completion order.
- **More ways and sets.** The tree-PLRU replacement logic is parameterized, but
  only the `2-way / 16-set` and `4-way / 8-set` geometries have been verified.
  Additional configurations would test whether the RTL and verification
  environment generalize beyond the two configurations already exercised.
- **A multi-level hierarchy.** An L2 with an inclusion or exclusion policy to
  introduce back-invalidation and a second coherence boundary.
- **More than two cores.** The snoop bus is parameterised for N, but current `cg_share`
  assumes exactly two and is not constructed otherwise. Past ~four cores
  snooping stops scaling and a **directory protocol** becomes the correct answer.
- **Additional cache optimizations.** Add write buffers, a victim cache, and
  prefetching to improve throughput and reduce the cost of misses and writebacks.

### Deeper coverage

Note: These coverage extensions are technically feasible with the current
architecture, but they require additional instrumentation, cross-stream
correlation, or multi-configuration result management that the present flow (Questa Starter, EDA playground) does
not or minimally provides.

- **Cross bus operation × MESI state × requester.** These are currently covered separately. The interesting question is which coherence operations occur from which states, which only a cross answers.
- **Transition sequences, not just pairs.** `cg_mesi` covers old→new state pairs.
  It does not cover *paths* — that `I→E→M→S→I` occurred as an ordered sequence.
- **Arbiter coverage.** Back-to-back grants to the same core, strictly
  alternating grants, and a starvation window (that round-robin is supposed to
  prevent).
- **Assertion coverage.** Proving each SVA antecedent actually fired, instead of only that 
  nothing failed. A property that never triggers does not prove anything and currently we do not 
  collect evidence that it does. 
- **Latency and timing bins** — memory latency crossed against observed miss
  penalty, to show the randomised `axil_agent_cfg` delays.
- **Geometry crossed with behaviour** — running the full coverage model at 4-way
  and comparing which bins only close at one configuration.

### Verification methodology

- **Mid-test reset.** Reset is currently asserted once at time zero and the
  drivers assume it stays deasserted throughout the test. Handling reset
  during active traffic would require the cache, bus, memory interface, monitors,
  scoreboard, and coverage model to recover cleanly from interrupted
  transactions(though, in my experience, resets
  are more commonly/meaningfully tested in directed tests, and wouldn't be the main target of interest for a 
  constrained random verification environment).
- **Formal property checking on the MESI FSM.** The current atomic-bus design keeps the
  state space small enough for model checking to be tractable, which would let
  SWMR be *proven* rather than sampled.
- **A real memory-consistency litmus suite.** `producer_consumer_vseq` is one
  message-passing test; a proper suite (store buffering, independent reads of
  independent writes, coherence litmus tests) would let the sequential consistency
  claim be verifiable. 
- **X-propagation and power-aware simulation**, neither of which this environment
  currently attempts.

### A simulator without a licence ceiling

Regrettably, there is a tooling constraint rather than a design one. 
Questa Altera FPGA Starter cannot simulate class-based SystemVerilog at all. EDA Playground can,
but it caps CPU time, has no regression runner, and provides no coverage database. 
A full Questa, VCS or Xcelium licence would unlock, in order of value:

- **Merged coverage across runs.** Right now every run reports its own
  instantaneous coverage and there is no way to accumulate. A UCDB/VDB merge
  would make coverage more meaningful and allow us to quantify exactly how effective
  our current environment is at reaching 100% coverage. The current figures materially 
  *understate* what the environment can reach because nothing accumulates.
- **Real regressions.** `sim/Makefile` already carries a `regress` target that
  compiles once and loops tests × seeds. The main issue is that due to tooling constraints,
  It has never been run so it is a sketch of the flow rather than tested infrastructure. 
  With a licence it becomes 12 tests × 50+ seeds in parallel, rather than one test at a time in a
  browser tab.
- **Volume.** `+num_txns` in the thousands instead of tens. Rare corner cases
  (4-way conflict evictions, the `CleanUnique`→`ReadUnique` degradation race,
  three-deep writeback chainsm, etc) need traffic to appear at all. 
- **Code coverage.** Nothing currently measures line, branch, toggle or FSM
  coverage on the RTL. Statement and FSM-arc coverage on `l1_cache` would show
  which state transitions the random stimulus never takes. Code coverage would complement
  the functional coverage model by revealing implementation paths and FSM transitions that the testbench has not executed.
- **Coverage-driven seed ranking**, assertion coverage reporting, and waveform
  debug at a scale EDA Playground cannot sustain.

---

## Repository layout

```
braytcache/
├── rtl/
│   ├── cache_pkg.sv          parameters, MESI/ACE enums, tree-PLRU functions
│   ├── core_if.sv            OBI-style core interface
│   ├── bus_if.sv             ACE-style coherent bus
│   ├── axil_if.sv            AXI4-Lite
│   ├── cache_probe_if.sv     whitebox tap
│   ├── l1_cache.sv           the cache: FSM, arrays, snoop path
│   ├── coherence_bus.sv      arbiter, snoop broadcast, AXI4-Lite master
│   └── cache_top.sv          two caches + interconnect
├── verif/
│   ├── agents/
│   │   ├── core_agent/       item, cfg, driver, monitor, agent, sequences
│   │   ├── axil_agent/       item, cfg, slave driver, monitor, agent, mem_model
│   │   ├── bus_agent/        item, passive monitor
│   │   └── probe_agent/      item, whitebox monitor
│   ├── env/                  cfg, analysis imps, scoreboard, coverage, vsequencer, env
│   │   └── seq_lib/          virtual sequence library
│   ├── tests/                test library
│   ├── sva/
│   │   ├── cache_sva.sv      bound into every cache from tb_top
│   │   ├── bus_sva.sv        interconnect properties
│   │   └── axil_sva.sv       AXI4-Lite protocol
│   ├── tb/tb_top.sv          clock, reset, probe wiring, config_db, SVA bind
│   └── cache_uvm_pkg.sv
├── sim/
│   ├── braytcache.f          filelist
│   ├── Makefile              questa / vcs / xcelium, regress, bugs -- unexercised
│   ├── tool_check.sv         standalone SystemVerilog capability probe
│   ├── tool_check_uvm.sv     standalone UVM capability probe
│   └── bundle_playground.py  flattens the tree for EDA Playground
├── docs/
│   ├── SETUP.md              reproduction guide: every command and option used
│   └── DEBUG_LOG.md          every defect the tools found, and why
└── PROGRESS.md               status, decisions, session log
```