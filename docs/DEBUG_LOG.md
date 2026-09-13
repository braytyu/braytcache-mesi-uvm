# Debug log

Working notes from bringing braytcache up on Questa and VCS. This is intentionally closer to a lab notebook than a design document: what failed, what I checked, what changed, and what I verified afterward.

The main README describes the final design. This file keeps the intermediate failures because several of them explain why a checker, command-line option, or test exists.

## Index

### Defects fixed

- [D-001 — assertion `bind` could disappear during elaboration](#d-001--assertion-bind-could-disappear-during-elaboration)
- [D-002 — `#1` before `run_test()` fails under UVM 1.2](#d-002--1-before-run_test-fails-under-uvm-12)
- [D-003 — `snoop_ack` remained high after snoop selection ended](#d-003--snoop_ack-remained-high-after-snoop-selection-ended)
- [D-004 — `cg_alloc` missed free-way allocations](#d-004--cg_alloc-missed-free-way-allocations)
- [D-005 — producer-consumer checker required exact equality](#d-005--producer-consumer-checker-required-exact-equality)

### Observations and open items

- [O-001 — `UVM_ERROR : 0` is not enough to call a pass](#o-001--uvm_error--0-is-not-enough-to-call-a-pass)
- [O-002 — the local Questa license stops at simulation load](#o-002--the-local-questa-license-stops-at-simulation-load)
- [O-003 — manual copies can leave a stale run tree](#o-003--manual-copies-can-leave-a-stale-run-tree)
- [O-004 — Git for Windows does not provide GNU Make](#o-004--git-for-windows-does-not-provide-gnu-make)
- [O-005 — failure reporting is split across three systems](#o-005--failure-reporting-is-split-across-three-systems)
- [O-006 — `BUG_3` leaves functional coverage unchanged](#o-006--bug_3-leaves-functional-coverage-unchanged)
- [O-007 — mutation detection depends on path activation](#o-007--mutation-detection-depends-on-path-activation)
- [O-008 — an illegal bin hides later detectors](#o-008--an-illegal-bin-hides-later-detectors)
- [O-009 — percentages change meaning across geometries](#o-009--percentages-change-meaning-across-geometries)
- [O-010 — traffic counters caught an incorrect README claim](#o-010--traffic-counters-caught-an-incorrect-readme-claim)
- [O-011 — `default` byte-enable bin is absent from the cross](#o-011--default-byte-enable-bin-is-absent-from-the-cross)
- [O-012 — the bundler duplicates the file list](#o-012--the-bundler-duplicates-the-file-list)

---

## D-001 — assertion `bind` could disappear during elaboration

**Date:** 2026-08-21  
**Tool:** Questa `vlog`/`vopt`, first complete file-list build  
**Files:** `verif/tb/tb_top.sv`; deleted `verif/sva/sva_bind.sv`  
**Status:** Fixed

### What I saw

```text
** Warning: (vlog-2650) 'bind' found in compilation unit scope.
   Please use -mfcu -cuname to ensure that 'bind' gets elaborated.
```

The compile still ended with zero errors. That made this easy to ignore, but the warning concerned a checker rather than synthesizable logic. If the bind disappeared, the design could still compile and run while all 13 per-cache assertions were missing.

### Notes while tracing it

The original bind lived by itself at compilation-unit scope:

```systemverilog
// old verif/sva/sva_bind.sv
bind l1_cache cache_sva u_cache_sva (...);
```

With `-mfcu`, compilation-unit declarations live in an implicit `$unit` scope. Questa warned that this scope might not be elaborated unless it was named and passed to `vopt` with tool-specific options.

Adding `-cuname` would have removed the warning on one command line, but it would also make assertion presence depend on remembering that option. It would not help the separate Design/Testbench compilation used on EDA Playground.

### Change

Moved the bind into `tb_top` at module scope and removed `sva_bind.sv` from the file list and Playground bundler.

### Check after the change

`vopt` reported:

```text
-- Loading module cache_sva
-- Optimizing module cache_sva(fast)
```

That is the useful check. `vlog` can compile a bind without proving that the bound module is present in the elaborated design.

### Note to self

Treat warnings about verification logic as functional failures until proven otherwise. D-003 was later found by the assertions attached here; leaving this warning unresolved would have hidden the next RTL defect.

---

## D-002 — `#1` before `run_test()` fails under UVM 1.2

**Date:** 2026-08-21  
**Tool:** VCS X-2025.06 on EDA Playground, UVM 1.2  
**File:** `verif/tb/tb_top.sv`  
**Status:** Fixed

### What I saw

```text
UVM_FATAL [RUNPHSTIME] The run phase must start at time 0, current time is 1000.
No non-zero delays are allowed before run_test().
```

The simulation stopped before the first clock edge.

### Why the delay was there

The virtual interfaces for each core are published from generate-scoped `initial` blocks. The call to `run_test()` is in a separate `initial` block, and SystemVerilog does not define an execution order between those blocks.

The old code used `#1` to let the configuration writes happen first:

```systemverilog
initial begin
  uvm_config_db #(virtual bus_if)::set(null, "*", "bus_vif", bus_i);
  uvm_config_db #(virtual axil_if)::set(null, "*", "mem_vif", mem_i);
  #1;
  run_test();
end
```

Deleting the delay entirely was not a safe fix. `build_phase` could start before one of the generate-block configuration writes, producing a simulator-order-dependent missing-interface failure.

### Change

```systemverilog
#0;
run_test();
```

`#0` yields to the inactive region without advancing `$time`. The other time-zero `initial` blocks can complete, and UVM 1.2 still sees `run_test()` begin at time zero.

### Check after the change

VCS passed the run-phase time check and all virtual interfaces were present during `build_phase`.

### Note to self

The local Questa installation used UVM 1.1d and did not expose this. Keep the time-zero requirement in mind when changing `tb_top` scheduling.

---

## D-003 — `snoop_ack` remained high after snoop selection ended

**Date:** 2026-08-21  
**Found by:** SVA during the first end-to-end `smoke_test`  
**File:** `rtl/l1_cache.sv`  
**Status:** Fixed

### What I saw

Two assertions failed on each bus transaction, alternating between caches:

```text
tb_top.u_bus_sva.a_ack_qualified
  Offending '((ack_v & (~sel_v)) == '0)'

tb_top.dut.g_cache[0].u_cache.u_cache_sva.a_snoop_ack_qualified
  Offending '(snoop_valid && snoop_sel)'
```

The scoreboard reported no data errors. The problem was protocol qualification: a cache asserted its snoop acknowledgement for one cycle after it was no longer selected.

### What caused it

`sn_ack_q` is registered, while `snoop_valid` and `snoop_sel` change combinationally with the interconnect state. The register was cleared only on the next clock edge:

```systemverilog
if (!sn_active)      sn_ack_q <= 1'b0;
else if (sn_take)    sn_ack_q <= 1'b1;
```

When the interconnect left its snoop state, `sn_active` fell immediately but `sn_ack_q` remained high until the following edge.

I checked whether the stale acknowledgement could be interpreted as a response to a new snoop. The shortest return to the snoop state still included enough registered state changes for `sn_ack_q` to clear first. The defect was benign for current data behavior, but it violated the interface rule and made the signal misleading.

### Change

```systemverilog
assign bus.snoop_ack[CORE_ID] = sn_ack_q && sn_active;
```

I considered weakening the assertion to allow a one-cycle tail, but rejected that because the interface does not need or specify the tail. Gating the output keeps the assertion and signal definition simple.

### Check after the change

The same `smoke_test` completed without assertion output. Load/store counts, transition counts, and coverage were unchanged from the failing run.

### Note to self

This was invisible to the golden-memory checker because every returned value was correct. It is a concrete example of why protocol assertions are not redundant with transaction-level checking.

---

## D-004 — `cg_alloc` missed free-way allocations

**Date:** 2026-08-21  
**Found by:** First `mesi_walk_test` run  
**File:** `verif/env/cache_coverage.sv`  
**Status:** Fixed

### What I saw

The test completed its ten directed accesses, but `cg_alloc` stayed at exactly 0.00%:

```text
cg_core     56.73 %
cg_bus      82.87 %
cg_mesi     80.53 %
cg_alloc     0.00 %
cg_axil    100.00 %
cg_share    87.50 %
```

That did not match the workload. Starting from reset and loading three lines necessarily allocates into free ways.

### What caused it

The sampling gate treated a tag change as proof that allocation occurred:

```systemverilog
if (tag_changed)
  cg_alloc.sample(...);
```

The cache and probe shadow both initialize tags to zero. `mesi_walk_vseq` uses `0x00`, `0x10`, and `0x20`; with the default geometry, those addresses have tag zero and different set indexes. Each allocation changed state from `I` but left the stale tag at zero, so `tag_changed` was false.

The `free` bin was therefore sampled only when an invalid way happened to contain a different stale tag. The checker was looking at a proxy for allocation, not the allocation event itself.

### Change

```systemverilog
if (it.new_state != MESI_I &&
    (tag_changed || it.old_state == MESI_I))
  cg_alloc.sample(it.old_state, it.way_idx,
                  index_t'(it.set_idx), it.core_id);
```

This samples both cases:

- `old_state == MESI_I`: installation into a free way
- `tag_changed` with a valid old state: replacement of another clean line

### Check after the change

| Measurement | Before | After |
|---|---:|---:|
| `cg_alloc` | 0.00% | 44.79% |
| Overall | 67.94% | 75.40% |

All other covergroups, scoreboard counts, and completion time remained unchanged. `pingpong_test` provided a second check because it repeatedly uses one tag; it reached 42.71% in `cg_alloc` through the free-way path.

### Note to self

When a covergroup reads 0%, first ask whether it sampled. Zero samples and many samples that miss every bin are reported similarly but mean different things.

---

## D-005 — producer-consumer checker required exact equality

**Date:** 2026-08-21  
**Found by:** First `producer_consumer_test` run  
**File:** `verif/env/seq_lib/cache_vseq_lib.sv`  
**Status:** Fixed

### What I saw

The sequence reported seven ordering errors, but the golden-memory scoreboard reported none. Most failures looked like:

```text
flag=2  payload=0xc0de0003  expected=0xc0de0002
flag=3  payload=0xc0de0004  expected=0xc0de0003
```

The payload was newer than the observed flag, not older. That is not a message-ordering failure.

The first error was different:

```text
flag=2652150544  payload=0xc0de0001
```

That value came from `mem_model::backing_value()` for an unwritten address.

### What caused it

There were two issues.

1. The consumer required `payload == payload_of(seen_flag)`. Producer and consumer run concurrently, so the producer can publish another payload after the consumer reads the flag but before it reads the payload. A newer payload is legal; only an older payload violates the ordering property.
2. The flag was never initialized. Unwritten memory intentionally returns a deterministic address hash rather than zero, so the consumer's first polling condition could succeed before the producer had published a message.

The disagreement between the sequence and golden-memory checker was useful. Both observed the same loads; the sequence was making the stronger claim, and that claim did not match the concurrent schedule.

### Change

Initialize the flag before starting producer and consumer:

```systemverilog
// Before fork
op    == CORE_STORE;
addr  == flag_addr;
wdata == '0;
```

Then accept the observed payload if it has the expected prefix and its message index is not older than the flag:

```systemverilog
if (s.observed_rdata[31:16] !== 16'hc0de ||
    s.observed_rdata[15:0]   <  seen_flag[15:0])
  `uvm_error(...)
```

### Check after the change

```text
[SB] loads=25 stores=17 touched_words=2
     ReadShared=14 ReadUnique=2 CleanUnique=12 WriteBack=0
     state transitions=54 invariant sweeps=54
UVM_ERROR : 0
```

The store count increased from 16 to 17, matching the one added initialization store. The test still touched only the payload and flag words.

### Note to self

For concurrent tests, write the required ordering relation explicitly. Exact equality often sneaks in an unstated assumption that the producer has stopped.

---

# Observations and open items

## O-001 — `UVM_ERROR : 0` is not enough to call a pass

D-003 produced assertion failures on every bus transaction while the UVM summary still printed:

```text
UVM_ERROR : 0
UVM_FATAL : 0
```

SVA failures are emitted by the simulator assertion engine and do not enter `uvm_report_server`. Any regression parser that checks only UVM totals will miss them.

For a clean result, check UVM totals, assertion output, illegal-bin output, and whether the run reached its expected end.

## O-002 — the local Questa license stops at simulation load

Observed on Questa–Intel FPGA Starter Edition 2025.2:

```text
** Error: Failure to checkout svverification license feature.
** Error: (vsim-1) Unable to checkout verification license - required for
   testbench features (randomize, randcase, randsequence, covergroup).
```

`vlog` and `vopt` still work on the complete project. That made the local installation useful for syntax and elaboration checks even though the actual runs moved to VCS on EDA Playground.

The standalone `sim/tool_check.sv` and `sim/tool_check_uvm.sv` files are faster for diagnosing this boundary than using the full testbench.

## O-003 — manual copies can leave a stale run tree

One `vlog -f braytcache.f` failure came from a run-machine copy that predated a file rename. Copying new files over an old tree is risky because deleted or renamed files remain in place and can still be referenced.

For the two-machine flow, replace the destination project directory as a unit or use a version-controlled checkout. Do not edit both copies.

## O-004 — Git for Windows does not provide GNU Make

The default Git for Windows installation provided Bash and common Unix utilities but not `make`. The direct `vlib`, `vlog`, `vopt`, and simulator commands remain the documented interface.

Use MSYS2, WSL, Linux, or another GNU Make installation before trying `sim/Makefile`.

## O-005 — failure reporting is split across three systems

The recorded flow produced three different failure behaviors:

| Mechanism | UVM summary | Aborts run | Exit code |
|---|---|---|---:|
| Scoreboard `uvm_error` | Included | No | 0 |
| SVA assertion | Not included | No | 0 |
| Illegal coverage bin | Not included | Yes | 1 |

`BUG_1` hit `cg_mesi.m_to_e`, aborted at 1.455 µs, and exited 1 before the final summaries. `BUG_3` reported eleven scoreboard errors, ran to `$finish`, printed coverage, and exited 0.

So neither exit status nor the UVM summary is sufficient on its own. A future CI parser needs to combine:

- process status
- UVM error/fatal totals
- simulator assertion failures
- illegal-bin messages
- normal end-of-run marker

## O-006 — `BUG_3` leaves functional coverage unchanged

The clean and `BUG_3` runs reported the same coverage:

```text
cg_core 86.61 | cg_bus 97.22 | cg_mesi 98.95
cg_alloc 84.38 | cg_axil 100.00 | cg_share 100.00
OVERALL 94.53%
```

They also had the same completion time and traffic counts:

```text
loads=28 stores=32
ReadShared=17 ReadUnique=19 CleanUnique=2 WriteBack=14
state transitions=68
```

The mutation changes the byte merge on a store hit. It does not change control flow, state, bus operations, or allocation decisions, so the covergroups have nothing different to sample. The golden-memory checker reported eleven corruptions.

Six errors were found during final reconciliation; four of those addresses had not been loaded again. Without the final check, those four corruptions would have remained hidden.

## O-007 — mutation detection depends on path activation

All five mutations were run with `eviction_test +num_txns=30`:

| Bug | Relevant activity in the clean run | First detection |
|---|---:|---:|
| `BUG_1` | 17 `ReadShared` operations | 1.46 µs |
| `BUG_5` | 17 `ReadShared` operations | 1.80 µs |
| `BUG_4` | 14 writebacks | 3.67 µs |
| `BUG_2` | 2 `CleanUnique` operations | 7.68 µs |
| `BUG_3` | 32 stores | 7.64 µs |

The frequently exercised `ReadShared` mutations appeared early. The `CleanUnique` mutation waited for a rarer operation. This is a useful correlation, not a timing law: the exact detection point also depends on when the first qualifying state and observation occur.

`BUG_3` is different because a store can execute the faulty line long before a later load or final reconciliation observes the damaged bytes.

The main practical point is simpler: a mutation run is only meaningful if the test activates the path. The recorded smoke run had `CleanUnique=0` and `WriteBack=0`, so it could not demonstrate detection of `BUG_2` or `BUG_4`.

## O-008 — an illegal bin hides later detectors

`BUG_4` has three possible observation points:

1. `cg_mesi.dirty_dropped`
2. `cg_alloc`'s illegal `dirty` bin
3. end-of-test memory reconciliation

Only the first was demonstrated. The coverage subscriber samples `cg_mesi` before `cg_alloc`:

```systemverilog
cg_mesi.sample(...);      // illegal bin aborts here
if (...)
  cg_alloc.sample(...);   // not reached
```

The run also ended before final reconciliation. It would be inaccurate to report three independent detections from this result. One checker fired; two other mechanisms appear capable of detecting the same defect but were not exercised after the fail-fast abort.

## O-009 — percentages change meaning across geometries

Recorded `eviction_test` results:

| Coverage | 2-way / 16-set | 4-way / 8-set |
|---|---:|---:|
| `cg_alloc` | 84.38% | 72.92% |
| `cg_mesi` | 98.95% | 94.74% |
| Overall | 94.53% | 92.06% |

The lower 4-way percentage does not imply worse stimulus. The bin model changed:

- `cp_way` increased from two to four bins.
- `x_victim_way` increased from six to twelve combinations.
- `cp_set` decreased from sixteen to eight bins.
- Writebacks fell from 14 to 3, so there were fewer replacement events available to fill the added way bins.

Coverage thresholds should be defined per configuration. Always record the `[CFG]` line with a reported percentage.

## O-010 — traffic counters caught an incorrect README claim

The recorded `store_streak_test` result was clean:

```text
loads=0 stores=90 touched_words=5
ReadShared=0 ReadUnique=5 CleanUnique=0 WriteBack=0
```

An earlier README draft said this test exercised both silent `E→M` and repeated `M` hits. The counters show that `E→M` was unreachable:

- Entering `E` requires a `ReadShared` that finds no sharer.
- The sequence issues no loads, so it never issues `ReadShared`.
- Each new line is acquired by `ReadUnique` directly into `M`.

The test correctly covers bus-silent stores while already in `M`. `mesi_walk_test` covers `E→M`.

Nothing failed because the design and test were both working; the documentation was wrong. This is why the scoreboard prints traffic counts on successful runs.

## O-011 — `default` byte-enable bin is absent from the cross

**Status:** Open; changing it requires new recorded coverage numbers.

Current `cg_core` code:

```systemverilog
cp_be : coverpoint be {
  bins full      = {(1 << STRB_W) - 1};
  bins single[]  = {1, 2, 4, 8};
  bins partial   = default;
}

x_op_be : cross cp_op, cp_be { ... }
```

Under SystemVerilog cross-coverage rules, a `default` bin is not included in crosses. `cp_be.partial` records masks such as `4'b0011`, but `x_op_be` does not cross those masks with the operation.

The displayed `cg_core` percentage therefore does not measure partial-byte-enable operation crosses as the source may suggest. The fix is to replace the default bin with explicit partial-mask bins, then rerun every result whose coverage is quoted. I did not change it after the recorded runs because doing so would make the checked-in numbers stale.

Until the rerun is done, describe `cg_core` as covering byte-enable categories at the coverpoint level, with full-word and single-byte masks participating in `x_op_be`.

## O-012 — the bundler duplicates the file list

**Status:** Open build-maintenance issue.

The source order exists in two places:

- `sim/braytcache.f`
- `DESIGN` and `TESTBENCH` in `sim/bundle_playground.py`

Nothing compares them. Adding a file only to `braytcache.f` can produce a clean local compile but omit the file from the Playground bundle. The browser error then refers to a flattened line number and does not directly identify the missing source-list entry.

For now, update both lists whenever files are added, removed, or reordered. The better fix is to make the bundler parse `braytcache.f` and derive the Design/Testbench split from one authoritative list. That is a build change and should be followed by a complete clean rerun.
