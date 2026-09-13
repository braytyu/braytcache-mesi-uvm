# Setup and reproduction

This guide documents the tool configuration and commands used for the recorded braytcache runs. Follow it to rebuild the project, run the twelve tests, exercise the five injected bugs, and test the alternate cache geometry.

The commands reproduce the **flow and configurations** used by the project. Exact randomized traffic, timing, counters, and coverage percentages may differ unless the simulator version and random seed also match the recorded run.

## Contents

- [Tested flow](#tested-flow)
- [Requirements](#requirements)
- [1. Check the local Questa installation](#1-check-the-local-questa-installation)
- [2. Compile and elaborate locally](#2-compile-and-elaborate-locally)
- [3. Generate the EDA Playground files](#3-generate-the-eda-playground-files)
- [4. Configure EDA Playground](#4-configure-eda-playground)
- [5. Run the functional tests](#5-run-the-functional-tests)
- [6. Run the injected bugs](#6-run-the-injected-bugs)
- [7. Run the alternate geometry](#7-run-the-alternate-geometry)
- [Reading a result](#reading-a-result)
- [Troubleshooting](#troubleshooting)
- [Using a fully licensed simulator](#using-a-fully-licensed-simulator)
- [Optional two-machine workflow](#optional-two-machine-workflow)

## Tested flow

The recorded project flow uses two simulators because of the limits of the available local license:

| Tool | Version or configuration | Role |
|---|---|---|
| Questa–Intel FPGA Starter Edition | 2025.2 | Local SystemVerilog compilation and elaboration |
| Synopsys VCS on EDA Playground | UVM 1.2 | Simulation, assertions, functional coverage, and bug injection |

Questa Starter successfully runs `vlog` and `vopt` on the complete source tree. On the machine used for this project, `vsim` could not check out the `svverification` feature required to load a testbench containing constrained randomization and covergroups. VCS on EDA Playground was used for every recorded simulation.

This is the tested flow, not a general compatibility statement about every simulator or license tier.

## Requirements

| Requirement | Purpose | Notes |
|---|---|---|
| Questa–Intel FPGA Starter Edition 2025.2 | Local compile and elaboration | Set up the Intel/Altera license before launching Questa |
| Python 3.8 or newer | Generate the Playground bundles | The bundler uses only the Python standard library |
| EDA Playground account | Run VCS | Commercial simulators are available only while signed in |
| Web browser | Access EDA Playground | No local VCS installation is required for this flow |

The commands below use `<REPO>` for the directory containing the cloned project. If a path contains spaces, wrap it in braces in the Questa Tcl transcript and in quotes in a shell.

## 1. Check the local Questa installation

The repository includes two small capability checks under [`sim/`](../sim/):

- [`tool_check.sv`](../sim/tool_check.sv) exercises SystemVerilog classes, constraints, covergroups, illegal cross bins, and concurrent assertions.
- [`tool_check_uvm.sv`](../sim/tool_check_uvm.sv) confirms that the bundled UVM library can be compiled and linked.

From the Questa transcript:

```tcl
cd {<REPO>/sim}
vlib work
vlog -sv -timescale 1ns/1ps tool_check.sv
vsim -c tool_check -do "run -all; quit -f"
```

On the Starter license used for this project, compilation succeeds and simulation stops with a license error for `svverification`. That result confirms that Questa can still be used for the next step even though the UVM simulations must run elsewhere.

To check the bundled UVM library separately:

```tcl
vlog -sv -timescale 1ns/1ps tool_check_uvm.sv
vsim -c tool_check_uvm -L mtiUvm -do "run -all; quit -f"
```

If your license can load and run both checks, you may be able to use the local flow described in [Using a fully licensed simulator](#using-a-fully-licensed-simulator).

## 2. Compile and elaborate locally

Run these commands from the Questa transcript:

```tcl
cd {<REPO>/sim}
vlib work
vlog -sv -mfcu +acc=rn -timescale 1ns/1ps -f braytcache.f
vopt +acc=rn -L mtiUvm tb_top -o tb_opt
```

Expected result:

- `vlog`: 0 errors and 0 warnings
- `vopt`: 0 errors
- The elaboration log includes `Loading module cache_sva`, confirming that the per-cache assertion bind was elaborated

Important options:

| Option | Reason |
|---|---|
| `-sv` | Enables SystemVerilog |
| `-mfcu` | Compiles the source as one compilation unit |
| `+acc=rn` | Preserves register and net visibility for the white-box probes and waveform debug |
| `-timescale 1ns/1ps` | Applies the project simulation timescale |
| `-f braytcache.f` | Uses the checked-in compilation order |
| `-L mtiUvm` | Links Questa's bundled UVM library during elaboration |

Run the commands from `sim/` because paths in [`braytcache.f`](../sim/braytcache.f) are relative to that directory. A Questa project file is not required.

## 3. Generate the EDA Playground files

EDA Playground provides one Design pane and one Testbench pane. The repository bundler flattens the source tree into those two files.

From the repository root:

```bash
python sim/bundle_playground.py
```

The script writes:

| Generated file | Contents | Playground pane |
|---|---|---|
| `playground/design.sv` | Eight RTL files and three SVA modules | **Design** |
| `playground/testbench.sv` | UVM package, its included classes, and `tb_top` | **Testbench** |

The UVM package contains 24 project-local `` `include `` directives. The bundler expands those files inline and leaves the two `uvm_macros.svh` includes for the simulator-provided UVM installation.

Do not edit the generated files. Make changes under `rtl/` or `verif/`, then rerun the bundler.

| Changed source | Pane to replace |
|---|---|
| `rtl/` or `verif/sva/` | **Design** |
| `verif/agents/`, `verif/env/`, `verif/tests/`, or `verif/tb/` | **Testbench** |

The script rewrites both generated files each time, but only the affected pane normally changes.

### When adding or removing a source file

The project currently maintains the source order in two places:

1. [`sim/braytcache.f`](../sim/braytcache.f), used by the local simulator flow
2. The `DESIGN` and `TESTBENCH` lists in [`sim/bundle_playground.py`](../sim/bundle_playground.py)

These lists are not compared automatically. Update both when the source tree changes, then compile locally and regenerate both Playground panes. This limitation is recorded in [`DEBUG_LOG.md`](DEBUG_LOG.md#o-012--the-bundler-duplicates-the-file-list).

## 4. Configure EDA Playground

1. Open [EDA Playground](https://edaplayground.com) and sign in. VCS is not available to anonymous sessions.
2. Configure the left panel:

   | Setting | Value |
   |---|---|
   | Testbench + Design | `SystemVerilog/Verilog` |
   | UVM / OVM | `UVM 1.2` |
   | Tools & Simulators | `Synopsys VCS` |
   | Compile Options | Leave empty for the default build |
   | Run Options | `+UVM_TESTNAME=smoke_test +num_txns=5` |

3. Paste `playground/design.sv` into **Design**.
4. Paste `playground/testbench.sv` into **Testbench**.
5. Leave the optional checkboxes disabled for the initial run.
6. Select **Run**.

EDA Playground compiles the two panes as generated files. Compiler messages therefore refer to `design.sv` or `testbench.sv` line numbers, not the original source paths. Search for the surrounding code in the repository to map a bundled line back to its source file.

### Compile Options versus Run Options

| Field | Passed to | Use it for | Example |
|---|---|---|---|
| Compile Options | `vcs` | Preprocessor definitions and compiler switches | `+define+BUG_2` |
| Run Options | `simv` | Test selection and runtime plusargs | `+UVM_TESTNAME=eviction_test +num_txns=30` |

Geometry and bug-injection defines belong in **Compile Options**. `+UVM_TESTNAME`, `+num_txns`, verbosity, and waveform controls belong in **Run Options**.

## 5. Run the functional tests

Use an empty **Compile Options** field for the default 2-core, 2-way, 16-set, 16-byte-line configuration.

| Test | Run Options |
|---|---|
| `smoke_test` | `+UVM_TESTNAME=smoke_test +num_txns=5` |
| `random_test` | `+UVM_TESTNAME=random_test` |
| `shared_region_test` | `+UVM_TESTNAME=shared_region_test +num_txns=30` |
| `false_sharing_test` | `+UVM_TESTNAME=false_sharing_test +num_txns=30` |
| `pingpong_test` | `+UVM_TESTNAME=pingpong_test +num_txns=30` |
| `eviction_test` | `+UVM_TESTNAME=eviction_test +num_txns=30` |
| `read_mostly_test` | `+UVM_TESTNAME=read_mostly_test +num_txns=30` |
| `store_streak_test` | `+UVM_TESTNAME=store_streak_test` |
| `producer_consumer_test` | `+UVM_TESTNAME=producer_consumer_test` |
| `mesi_walk_test` | `+UVM_TESTNAME=mesi_walk_test` |
| `upgrade_race_test` | `+UVM_TESTNAME=upgrade_race_test` |
| `regression_test` | `+UVM_TESTNAME=regression_test` |

The order above matches the test class order in [`cache_tests.sv`](../verif/tests/cache_tests.sv).

### Transaction-count override

`+num_txns=<n>` sets the number of accesses **per core** for these seven tests:

- `smoke_test`
- `random_test`
- `shared_region_test`
- `false_sharing_test`
- `pingpong_test`
- `eviction_test`
- `read_mostly_test`

For example, `+num_txns=30` produces 60 accesses in a two-core build.

The remaining tests determine their own length:

- `store_streak_test`: two to four streaks per core
- `producer_consumer_test`: four to twelve messages
- `mesi_walk_test`: ten directed accesses
- `upgrade_race_test`: four to eight rounds
- `regression_test`: three to six phases, with 15 to 35 transactions randomized per phase

### Debug options

| Run option | Effect |
|---|---|
| `+UVM_VERBOSITY=UVM_HIGH` | Enables detailed transaction logging |
| `+dump` | Writes `dump.vcd` |

When using `+dump`, also enable **Open EPWave after run**.

## 6. Run the injected bugs

Each bug is enabled separately through **Compile Options**. Use the same `eviction_test` run for the recorded comparison:

| Compile Options | Run Options | Recorded failure |
|---|---|---|
| `+define+BUG_1` | `+UVM_TESTNAME=eviction_test +num_txns=30` | `cg_mesi.m_to_e`, approximately 1.5 µs, exit 1 |
| `+define+BUG_2` | `+UVM_TESTNAME=eviction_test +num_txns=30` | `cg_share.ms`, approximately 7.7 µs, exit 1 |
| `+define+BUG_3` | `+UVM_TESTNAME=eviction_test +num_txns=30` | Eleven scoreboard errors, run completes, exit 0 |
| `+define+BUG_4` | `+UVM_TESTNAME=eviction_test +num_txns=30` | `cg_mesi.dirty_dropped`, approximately 3.7 µs, exit 1 |
| `+define+BUG_5` | `+UVM_TESTNAME=eviction_test +num_txns=30` | `cg_share.se`, approximately 1.8 µs, exit 1 |

The exact times depend on the seed. The required result is detection by the expected checker, not an identical timestamp.

`eviction_test` is used because the recorded workload reaches all five mutated paths. In particular:

- `BUG_2` requires two shared copies followed by `CleanUnique`.
- `BUG_4` requires capacity eviction of a line in `M`.

`BUG_2` does **not** depend on writeback. A different test can detect it if that test produces the required shared-to-modified upgrade.

Clear **Compile Options** before returning to a clean run. Playground retains the field between runs.

## 7. Run the alternate geometry

Use:

| Field | Value |
|---|---|
| Compile Options | `+define+CFG_NUM_WAYS=4 +define+CFG_NUM_SETS=8` |
| Run Options | `+UVM_TESTNAME=eviction_test +num_txns=30` |

Confirm the configuration near the beginning of the log:

```text
[CFG] cores=2 sets=8 ways=4 line=16B
```

Available compile-time geometry controls are defined in [`rtl/cache_pkg.sv`](../rtl/cache_pkg.sv):

| Define | Default | Current assumption |
|---|---:|---|
| `CFG_NUM_CORES` | 2 | `cg_share` is instantiated only for two cores |
| `CFG_NUM_SETS` | 16 | Power of two |
| `CFG_NUM_WAYS` | 2 | Power of two for tree-PLRU indexing |
| `CFG_LINE_BYTES` | 16 | Power of two and at least two 32-bit words |

Clear the geometry defines after the run. Always check the `[CFG]` line before interpreting a result.

## Reading a result

A normal completed run prints:

1. `[CFG]` — active geometry and randomized memory-delay range
2. `[SB]` — load/store, coherence-operation, transition, and invariant-sweep counts
3. `[COV]` — six covergroup results and the overall per-run coverage
4. The UVM report summary

The three failure mechanisms do not report in the same way:

| Mechanism | Appears in UVM summary | Aborts immediately | Observed process exit |
|---|---|---|---|
| Scoreboard `uvm_error` | Yes | No | 0 in the recorded flow |
| SVA assertion failure | No | No | 0 in the recorded flow |
| Covergroup illegal-bin hit | No | Yes | 1 in the recorded flow |

Do not determine pass/fail from only the process exit code or only `UVM_ERROR : 0`. Check:

- `UVM_ERROR` and `UVM_FATAL` totals
- Simulator assertion-failure messages
- Illegal-bin messages
- Whether the run reached its expected end
- `[SB]` counters, to confirm that the intended path was actually exercised

The differences are demonstrated in [`DEBUG_LOG.md`](DEBUG_LOG.md#o-005--failure-reporting-is-split-across-three-systems).

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| VCS is missing from the simulator list | The Playground session is not signed in | Sign in and reload the page |
| A clean test unexpectedly behaves like a mutation or alternate geometry | Compile Options still contains an old define | Clear Compile Options and verify `[CFG]` |
| A source edit has no effect | The bundles were not regenerated or the wrong pane was updated | Run the bundler again and replace the affected pane |
| Error lines do not match the repository file | The message refers to a flattened bundle | Search the original tree for nearby code |
| Questa reports a missing file that exists | A path contains spaces or the transcript is in the wrong directory | Use `{...}` around Tcl paths and run from `sim/` |
| Assertions do not appear during elaboration | The `bind` was not elaborated | Confirm `cache_sva` appears in the `vopt` log |
| `UVM_FATAL [RUNPHSTIME]` occurs at time zero | Simulation time elapsed before `run_test()` | Keep the existing `#0`; do not change it to `#1` |
| Local compilation uses an old file name | A copied repository is stale | Replace the copied tree instead of merging directories |

## Using a fully licensed simulator

[`sim/Makefile`](../sim/Makefile) contains targets for Questa, VCS, and Xcelium:

```bash
cd sim
make questa TEST=regression_test SEED=3
make vcs TEST=eviction_test SEED=3 PLUS=+num_txns=30
make xcelium TEST=smoke_test SEED=1
make regress SIM=questa SEEDS="1 2 3 4 5"
make bugs SIM=questa
```

The Makefile also accepts `WAYS`, `SETS`, `LINE`, `CORES`, `BUG`, `VERB`, and `PLUS`.

These targets were not used to produce the checked-in results and have not been validated with a full simulator license. Treat them as a starting point. Review the pass/fail logic before using it in CI: the current `regress` target checks UVM totals but does not independently fail on every simulator assertion message.

GNU Make is not included with a default Git for Windows installation. Use an environment that provides it, such as MSYS2, WSL, or Linux.

## Optional two-machine workflow

The original project was edited on one machine and run on another. That arrangement is not required; one machine can perform both roles if it has the necessary tools.

If you do use separate machines:

1. Treat the authoring copy as the source of truth.
2. Replace the run-machine repository copy instead of merging an older directory into it.
3. Run the local compile and elaboration step on the run machine.
4. Generate the Playground bundles from the same source revision that was compiled.
5. Bring only logs and failure details back to the authoring machine.

Do not copy or commit generated simulator products:

```text
sim/work/
sim/logs/
sim/transcript
*.wlf
*.vcd
modelsim.ini
playground/design.sv
playground/testbench.sv
```

The repository `.gitignore` already excludes these paths.
