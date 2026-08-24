# P0 baseline: unmodified core, Quartus Prime Lite 25.1std (Build 1129)

Built from upstream `864253c` (fork branch `cheats` at `cf5575f`, RTL untouched)
with `make gbc` / `make gb` from the Podman harness. Device `5CEBA4F23C8`.
Numbers come from `build/<target>/report.txt`.

## GBC (`isgbc 1`)

| Resource | Used | Available | |
|---|---|---|---|
| Logic (ALMs) | 9,296 | 18,480 | 50 % |
| Registers | 11,973 | | |
| Block memory bits | 2,226,180 | 3,153,920 | 71 % |
| PLLs | 2 | 4 | |

Worst slack across all corners (all positive, timing met). The hold figure is a
Quartus-managed path inside a PLL output counter, not a design path; it sits
between 0.048 and 0.122 ns in every build including this baseline.

| Analysis | Slack | Corner / clock |
|---|---|---|
| Setup | 2.374 ns | Slow 1100mV 85C, `clk_74a` |
| Hold | 0.048 ns | Fast 1100mV 0C, `mf_pllbase` output counter 1 |
| Recovery | 11.030 ns | Slow 1100mV 85C, `clk_74a` |
| Removal | 0.281 ns | Fast 1100mV 0C, `clk_74a` |
| Min pulse width | 0.827 ns | Slow 1100mV 85C, `mf_pllbase` VCO |

Full compile: 696 s on 14 cores, `NUM_PARALLEL_PROCESSORS ALL`.

## GB (`isgbc 0`)

| Resource | Used | Available | |
|---|---|---|---|
| Logic (ALMs) | 8,900 | 18,480 | 48 % |
| Registers | 13,108 | | |
| Block memory bits | 2,250,388 | 3,153,920 | 71 % |
| PLLs | 2 | 4 | |

| Analysis | Slack | Corner / clock |
|---|---|---|
| Setup | 2.472 ns | Slow 1100mV 85C, `clk_74a` |
| Hold | 0.122 ns | Fast 1100mV 0C, `mf_pllbase` output counter 1 |
| Recovery | 11.095 ns | Slow 1100mV 85C, `clk_74a` |
| Removal | 0.312 ns | Fast 1100mV 0C, `mf_pllbase` output counter 1 |
| Min pulse width | 0.827 ns | Slow 1100mV 85C, `mf_pllbase` VCO |

Full compile: 668 s.

## Hardware smoke test

Passed 2026-08-21: `build/gbc/sd/` copied onto the card, core listed as
1.4.0 under OpenFPGA > Handheld > Game Boy Color, physical cartridge boots
and plays. P0 complete.

## What this means for the cheat work

- **Fit is not a concern.** Half the ALMs are free; the 32-entry `CODES`
  comparator and a GameShark poker are a few hundred ALMs at most. Block RAM
  is at 71 %, so the parser/poker should keep their tables in registers or
  small MLABs rather than adding M10K blocks.
- **Timing headroom is healthy but the hook is on the CPU data-in path.**
  2.4 ns of setup slack on the 74 MHz domain is a comfortable margin for the
  `genie_ovr ? genie_data : cpu_di` mux, but the 32-way address compare that
  feeds `genie_ovr` must be re-checked after P1. The `Setup` row of the report
  is the number to watch; if it drops under ~0.5 ns, drop `MAX_CODES` to 16
  before trying anything cleverer.
- Hold slack of 0.048 ns on a PLL output counter is a Quartus-managed internal
  path, not a design path, and was present before any change.

## Phase log

| Phase | Commit | ALMs | Setup slack | Hardware |
|---|---|---|---|---|
| P0 baseline | `864253c` | 9,296 | 2.374 ns | cart boots |
| P1 hook + hardcoded override | `b8051c2` | 9,440 | 1.985 ns | Oracle of Ages (CGB-AZ8E-USA) shows 999 rupees on a real cart. Passed 2026-08-21. |
| P2 first attempt | (not committed) | 10,608 | **-3.374 ns** | Rejected: missed timing. Quartus still exited 0, which is why the harness now checks slack itself. |
| P2 timing fix | `9d9c725` | 10,465 | +2.194 ns | Split the CODES lookup so `cpu_di` feeds only one 8-bit compare. |
| P2+P3 .cht loader + paged menu | `9d9c725` | 10,494 | +1.992 ns | Flashed 2026-08-22, superseded before testing. |
| P3 rework: file-driven enables (GBC) | `4ee3637` | 10,394 | +0.807 ns | Per-cheat menu toggles removed; on/off comes from the file. |
| Loader FIFO fix (GBC) | `e9fd400` | 10,394 | +1.461 ns | `WRITE_MEM_CLOCK_DELAY` 20 -> 4; cheat files were being corrupted in transit. |
| Standard Fit (GBC) | `d2e375e` | 10,496 | setup +1.860, hold +0.114 ns | Flashed 2026-08-22, checksum `ca902ed3`. |
| Standard Fit (GB) | `d2e375e` | 10,355 | setup +2.127, hold +0.112 ns | First GB build with cheat support flashed, checksum `86ca24a8`. |
| GameShark poker (GBC) | `11798ea` | 10,873 | setup +1.443, hold +0.115 ns | `cheat_poker.sv` plus the split entry table. Costs 377 ALMs and 0.42 ns of setup margin against the build before it. |
| GameShark poker (GB) | `f1c698a` | 10,612 | setup +1.327, hold +0.117 ns | Same RTL as the GBC build above; `f1c698a` only adds host tooling on top of `11798ea`, so the two cores report different versions for identical logic. |
| Cheat diagnostics (GBC) | `3e878b3` | 10,935 | setup +1.146, hold +0.077 ns | Adds the `CD:` readout. Built and passing, not flashed: it exists to localise a fault that turned out to be a wrong cheat value rather than the core. |

Fast Fit vs Standard Fit on the same GB tree: hold went from **-0.001 ns**
(rejected by the gate) to **+0.112 ns**, and setup from +1.653 to +2.127 ns, for
two extra minutes of compile time. Worth keeping.

## Timing closure

Slack used to move by more than a nanosecond between fitter runs of nearly
identical designs (one GBC build came in at +0.807 ns where its immediate
predecessor, with *more* logic, made +1.992 ns), and a GB build eventually
failed hold by 0.001 ns.

The cause was not the design. `src/ap_core.qsf` sets
`FITTER_EFFORT "FAST FIT"`, which trades placement quality for compile time, and
`OPTIMIZE_HOLD_TIMING` was unset so the fitter was not obliged to fix internal
hold violations. The failing path was `clk_74a` to `clk_74a` inside the `dcfifo`
in `sync_fifo:RTC_FIFO` - untouched upstream code that measured +0.048 ns on the
P0 baseline, so it has always been marginal.

`tools/podman/build-core.sh` now applies `STANDARD FIT` and
`OPTIMIZE_HOLD_TIMING "ALL PATHS"` to the build copy. These are build-environment
choices rather than part of the cheat feature, so the checked-in project file is
left as upstream wrote it and the `cheats-core` branch stays focused. Builds take
longer in exchange for repeatable closure.

`make gb SEED=2` re-runs the fitter with a different seed, which is the quick
workaround if a marginal path ever reappears.
