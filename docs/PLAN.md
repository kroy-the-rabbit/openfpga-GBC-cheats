# Plan: Cheat code support (GameShark + Game Genie) for `budude2/openfpga-GBC`

Target repo: https://github.com/budude2/openfpga-GBC (Pocket port of `MiSTer-devel/Gameboy_MiSTer`)
Goal: working cheats, easy code import, per-game on/off state that survives a reboot, and support while playing a **physical cartridge**.

---

## 1. Findings from the repo

**The cheat engine was stripped during the Pocket port.** `grep -riE "cheat|genie"` over the whole repo returns nothing. Upstream MiSTer still has it, so most of this work is a re-port, not a from-scratch design.

| Thing | Upstream MiSTer | This repo |
|---|---|---|
| Cheat module | `rtl/cheatcodes.sv` — `module CODES` | absent |
| CPU hook | `rtl/gb.v:425` → `.DI (genie_ovr ? genie_data : cpu_di)` | `src/gb/gb.v:352` → `.DI (cpu_di)` — hook removed |
| `gb` ports | `gg_reset`, `gg_en`, `gg_code[128:0]`, `gg_available` (`rtl/gb.v:86-89`) | absent |
| Code loading | `Gameboy.sv:921-951`, HPS `ioctl` with `filetype == &1` | absent |

### 1a. Why it was removed (from this repo's own history)

Not a space problem. The cheat engine was present and fully wired from the initial commit (2023-12-28) until 2024-08-21, when it was removed in two commits that day:

- `18695bd` "Removed unused cheat stuff" — stripped `gg_reset/gg_en/gg_code/gg_available` from `gb.v`, removed the `CODES` instance, and reverted `.DI` to plain `cpu_di`.
- `a21f1c6` "Remove unused files" — deleted `src/gb/cheatcodes.sv` and its `ap_core.qsf` entry, alongside an unrelated dead `sram_128k_x1_x16.sv`.

Before removal, `core_top.sv` instantiated `gb` with the cheat ports **tied to constants**: `.gg_reset(0), .gg_en(0), .gg_code(0)` — carrying over MiSTer's comment about palette downloads clobbering cheats, which is an HPS-specific issue that doesn't apply on Pocket. Nothing ever drove `gg_code`, because Pocket has no HPS to decode cheat text and no data slot was wired for it. It was cut as dead code.

**Practical consequences:**

- `git show 18695bd^:src/gb/cheatcodes.sv` recovers the exact file that belonged to this tree — use it instead of copying from MiSTer.
- `git revert a21f1c6 18695bd` is a legitimate starting point for P1, though the `sram_128k_x1_x16.sv` deletion should stay reverted-out.
- No build of this core with cheats enabled has ever existed, so there is no prior art on whether it fits or meets timing here. Measure in P0.

**How `CODES` works (upstream):** a 129-bit shift-in register `{clock_bit, flags, addr[31:0], compare[31:0], replace[31:0]}`, bit 128 latches one code into a 32-entry array. Instantiated with `ADDR_WIDTH=16, DATA_WIDTH=8, MAX_CODES=32`. It is purely a **CPU-read override** — combinational compare of `cpu_addr` against every stored code, forcing `genie_data` onto the CPU data input. That is Game Genie semantics (ROM patch + optional compare byte). **It does not implement GameShark**, which is a RAM poke repeated every frame. See §3.

**Relevant hook points in this repo:**

- `src/core/core_top.sv:468-495` — bridge address decode. `0xF0000000` reset, `0xF1000000` boot settings (triggers reset on write), `0xF2000000` runtime settings. `0xF3000000` is free.
- `src/core/core_top.sv:676-715` — `ioctl_download` + slot-ID routing. RTL already handles slot IDs 1,2,3,4,5,6; `pkg/gbc/.../data.json` only declares 1 (Cartridge), 18 (Save), 4 (GBC BIOS). **Slot 7 is free for cheats.**
- `src/core/core_top.sv:545-560` — `data_loader` instance producing `ioctl_wr / ioctl_addr / ioctl_dout`; reuse verbatim.
- `src/core/core_top.sv:779` — `assign cart_do = cart_physical_mode ? cart_tran_bank1 : cart_do_backend;` — **the physical/backend cart mux is upstream of `gb.v`.** This is the key fact for §4.
- `src/gb/gb.v:843-855` — WRAM is a `dpram #(15)`; **port B is used only by savestates** (`Savestate_RAMAddr`, `Savestate_RAMRWrEn[0]`).
- `src/gb/gb.v:808-813` — HRAM is a `dpram #(7)`, port B likewise savestate-only.
- `src/gb/gb.v:544, 574` — `vblank_irq` available as the GameShark injection trigger.
- `src/ap_core.qsf:791-818` — every source file is listed explicitly; new files must be added here.
- `src/core/core_top.sv:3` — `` `define isgbc 1 `` selects GB vs GBC build from one tree, so all work lands in both packages.
- `pkg/gbc/Cores/budude2.GBC/core.json` — `"cartridge_adapter": "0x01000000"` = bit 24 set = **"Play Cartridge" is already enabled**.

**APF facts that shape the design** (from Analogue's data.json / interact.json docs):

- `parameters` bitmap: bit 0 user-reloadable, bit 1 core-specific file, bit 2 nonvolatile filename cloned from slot 0, bit 3 read-only, bit 9 persist browsed filename.
- Interact menu: max 16 UI entries; per-asset menus override `interact.json` from `/Presets/budude2.GBC/Interact/<slot0 path>.json` and persist to `/Settings/budude2.GBC/Interact/<slot0 path>.json`.
- **Interact values are read back from the core each frame, then written back.** So the core can *seed* menu state at boot — this is what makes saved cheat state possible.
- In "Play Cartridge" mode, slot 0 is not loaded, so **anything named from slot 0 (bit 2) will not load or save**. Hence the cart-mode fallback in §4.

---

## 2. Easy code import

Design decision: **parse plain text on the FPGA.** No PC-side converter as a hard dependency — the user drops a `.cht` next to the ROM and it works.

Rationale: on MiSTer, HPS decodes cheat text and ships the core pre-decoded binary. Pocket has no equivalent, so the choice is (a) a PC-side Python tool producing a binary blob, (b) a Chip32 VM parser, or (c) an RTL parser. (c) wins: hex-ASCII tokenizing is a trivial state machine, far simpler than Chip32 assembly, and it means codes copy-pasted straight off gamehacking.org / a libretro `.cht` work untouched.

**Parser spec (`src/gb/cheat_loader.sv`):**

- Consume the byte stream from `data_loader`, tokenize on any non-`[0-9A-Fa-f-]` character.
- **Ignore any token that isn't a valid code.** Descriptive text, `cheat0_desc = "Infinite HP"`, comments, blank lines all fall through harmlessly. This is what makes arbitrary downloaded files work.
- Recognize two token shapes:
  - **GameShark** — 8 hex digits `TTVVAAAA`: `TT` type (`01` = normal write; `00`/`80`/`90` variants — treat unknown types as `01` for v1), `VV` value, `AAAA` address **little-endian, so byte-swap it**.
  - **Game Genie** — `XXX-YYY-ZZZ` or 9 raw hex digits: `XXX` = new data, `YYY`+first digit of `ZZZ` = address with the nibble-scramble unwound, remaining `ZZZ` digits = compare value, itself XOR/rotate-encoded. Get the exact descrambling from a known-good reference implementation (SameBoy / libretro `gb_cheat.c`) rather than deriving it.
- Emit one 129-bit `gg_code` per recognized code into the existing `CODES` shift-in protocol, plus a parallel index counter so cheat *N* maps to mask bit *N*.
- Cap at `MAX_CODES` (start at 32; drop to 16 if timing or LEs get tight).
- Optionally capture the description string preceding each code — only needed if you later want names in the menu.

Data slot to add in **both** `pkg/gbc/Cores/budude2.GBC/data.json` and `pkg/gb/Cores/budude2.GB/data.json`:

```json
{
  "name": "Cheats",
  "id": 7,
  "required": false,
  "parameters": "0x205",
  "extensions": ["cht", "txt"],
  "address": "0x40000000",
  "size_maximum": "0x4000"
}
```

`0x205` = bit 0 (user-reloadable, so cheats can be swapped mid-game from the core menu) + bit 2 (filename cloned from slot 0, i.e. `Pokemon.gbc` → `Pokemon.cht` picked up automatically) + bit 9 (persist browsed filename, which covers cartridge mode). Verify this combination on hardware — bit 2 and bit 9 interacting is the one part of this that the docs don't spell out; if they conflict, drop bit 2 and rely on the browser + bit 9.

Then in `core_top.sv`, extend the `case (dataslot_requestwrite_id)` block at line ~703 with `7: cheat_download = 1'b1;`.

---

## 3. Making GameShark actually work

`CODES` alone gives Game Genie. GameShark writes a value into RAM every frame, and read-override is not equivalent — it breaks on read-modify-write, DMA copies, and anything that reads the location through a different path. Implement a real injector.

**`src/gb/cheat_poker.sv`** — on the rising edge of `vblank_irq`, walk the enabled GameShark-type codes and perform one write each:

- **Phase 2a — WRAM (`$C000-$DFFF`) + HRAM (`$FF80-$FFFE`).** Mux the cheat poker onto **port B of the `dpram`s** at `gb.v:843` and `gb.v:808`, arbitrating against the savestate port (savestate wins; cheat writes are idempotent, so a dropped frame is harmless). This is cheap and covers the large majority of published GameShark codes.
- **Phase 2b — cart SRAM (`$A000-$BFFF`) and universal coverage.** Requires a real bus write. Gate `cpu_clken` (`gb.v:296`) for a few cycles during VBlank and drive `ext_bus_addr` / `cart_di` / `cart_wr` as a bus master. More invasive, and it's also the only path that reaches a **physical** cartridge's save RAM. Defer until 2a is proven.

Keep `CODES` for the Game Genie path — the two engines are independent and both are wanted.

---

## 4. Cartridge support — yes, and mostly for free

**Game Genie / ROM patching works on real cartridges with zero extra work.** The cheat override lands on `.DI` of the CPU inside `gb.v`, which is *downstream* of the physical/backend mux at `core_top.sv:779`. The core cannot tell whether the byte came from SDRAM or from the cart edge connector — it patches either.

**GameShark WRAM/HRAM pokes also work on cartridges,** because WRAM and HRAM live inside the FPGA (`gb.v:843`, `gb.v:808`) regardless of where the ROM is.

**Two real caveats:**

1. **Cart SRAM codes need Phase 2b.** Writes to `$A000-$BFFF` on a physical cart mean driving an actual write cycle out the connector. Treat as stretch; be careful, since a bad write cycle is writing to somebody's real save.
2. **Slot-0-derived filenames don't exist in cart mode.** APF explicitly does not load or save slots named from slot 0 when "Play Cartridge" is chosen. So automatic `<romname>.cht` pickup silently does nothing. Fallbacks, in order of preference:
   - Parameters bit 9 (persist browsed filename): user browses to a `.cht` once, and it reloads on every subsequent launch.
   - Store the enable mask in a **core-specific fixed-name** file (`parameters` bit 1 + nonvolatile) rather than a slot-0-derived one — one shared mask for cart sessions.
   - Stretch: read the 16-byte title from the cart header (`$0134`) and use `target_dataslot_openfile` (already wired at `core_top.sv:415`) to open `<TITLE>.cht` yourself. Nicest UX, most work.

Test matrix must include: SD ROM, physical cart, and cart-with-cheats-then-hot-quit.

---

## 5. Saving on/off state between runs

Two layers, because they solve different halves.

**Layer 1 — the mask register.** Add `0xF3000000` to the bridge decode in `core_top.sv:482-495` as a 32-bit `cheat_mask`, runtime-writable (no reset on write, unlike `0xF1000000`). Modify `CODES` (and the poker) to gate each entry: `codes[x][ENA_F_S] && cheat_mask[x]`. Cheat *N* from the file ↔ bit *N* of the mask.

**Layer 2 — persistence.** Because APF reads interact values back from the core every frame before writing them back, the core can seed the menu at boot. So:

- Add a small nonvolatile data slot (`id: 8`, `parameters` bit 2 + bit 1, extension `chs`, 4 bytes) holding the mask. APF flushes it to SD on quit/sleep automatically.
- At load, the core writes the loaded mask into `cheat_mask`; APF reads it back and the checkboxes come up in the saved state.
- In cart mode, fall back to the fixed-name core-specific variant per §4.

**Menu UI.** Add to `interact.json`: a `"Cheats enabled"` master checkbox with `"persist": true` on a spare bit of `0xF2000000` (mirroring `Enable GBA` etc. at ids 1000-1006), plus per-cheat checkboxes on `0xF3000000`. Note the **16-entry ceiling** — the core already uses 7 entries, so a global `interact.json` has room for ~8 cheat toggles. For more, generate a **per-asset interact JSON** at `/Presets/budude2.GBC/Interact/<rom path>.json` (a small PC-side script alongside the `.cht`), which both gives real cheat *names* in the menu and persists per game to `/Settings/...`. Per-asset menus replace the whole menu, so the generator must re-emit the 7 existing core options.

---

## 6. Phasing

| Phase | Deliverable | Done when |
|---|---|---|
| **P0** | Baseline build in Quartus Prime Lite 25.1std (the version the qsf was last saved with, commit `7044e75`) via the Podman harness (`make gbc`), unmodified. Record LE/RAM utilization and worst-case slack. | `gbc.rbf_r` boots a ROM on hardware. |
| **P1** | Port `cheatcodes.sv`; add `gg_*` ports to `gb.v`; restore `.DI (genie_ovr ? genie_data : cpu_di)`; hardcode one known Game Genie code as a constant. Add both files to `ap_core.qsf`. | A hardcoded code visibly takes effect. Proves the hook before any file I/O exists. |
| **P2** | Data slot 7 + `cheat_loader.sv` ASCII parser + `cheat_download` routing. | A `.cht` next to the ROM applies Game Genie codes. Built; parser verified against all 2456 libretro GB/GBC files in simulation (`make test`). Slot address is `0x50000000`, not `0x40000000`: `0x4xxxxxxx` is already taken by savestate bridge reads. |
| **P3** | `0xF3000000` mask + master enable + per-cheat interact checkboxes. | **Scope changed.** Per-cheat menu checkboxes were built (windowed mask + "Cheat page" dropdown, and per-asset presets with real names) and then removed: APF menu labels are fixed in JSON and the core cannot rename them, so generic checkboxes read "Cheat 1", "Cheat 2" and are close to useless, while per-asset presets do not apply to cartridges. Which cheats are on now comes from the `cheatN_enable` key in the file itself, and the menu keeps only a global switch plus the parsed-count readout. |
| **P4** | `cheat_poker.sv`, WRAM + HRAM (2a). | **Done, verified on hardware 2026-08-22.** GameShark codes are written into RAM at vblank through port B of the WRAM/HRAM dprams, arbitrated against the savestate engine via `savestate_busy`. Game Genie codes stay on the read override, as do GameShark codes aimed outside the poker's reach, so nothing regressed. A read override only satisfies reads the core can see, so a DMA copy, a cached value or a read-modify-write diverges from what the codes were written against. |
| **P5** | ~~Nonvolatile `.chs` mask slot + core seeding.~~ | **Dropped.** State lives in the cheat file, which is already persistent, so there is nothing to save separately. |
| **P6** | Cartridge validation + bit-9 browsed-filename fallback. | Cheats work on a real cart; codes persist across launches. |
| **P7 (stretch)** | Bus-master injector (2b) for cart SRAM; per-asset interact generator script; `<TITLE>.cht` via `target_dataslot_openfile`. | — |
| **P8** | README features section, sample `.cht`, upstream the fixes that belong upstream. | — |

Each phase after P0 should be one PR-sized commit with a hardware smoke test, since **there is no simulation harness in this repo** and Quartus builds are slow. Builds run in the containerized harness under `tools/podman/` (`make gbc`, `make gb`); each produces an SD-ready tree and a `report.txt` with utilization and slack.

---

## 7. Risks

- **Timing (hit, and fixed).** The first P2 build missed setup by **-3.374 ns**, and Quartus still exited 0, so the build harness now checks worst slack itself. Cause: `cpu_di` fed the 32-way comparator *and* the mux select, putting the whole comparator chain plus priority mux on the late-arriving read data. Splitting the lookup so the 32-way search runs off `cpu_addr` (a register output, stable early) and `cpu_di` only feeds one 8-bit compare recovered 5.6 ns, to **+2.194 ns**. The two forms are equivalent because `CODES` keeps at most one entry per address. P1 did not show the problem because hardcoded codes let Quartus constant-fold most of the comparator.
- **Timing (original note).** `CODES` is a 32-way combinational comparator sitting directly on the CPU data-in path. Upstream tolerates it on MiSTer's Cyclone V, but this repo's fitter results may differ. Mitigation: drop `MAX_CODES` to 16, or register the compare and accept one cycle of latency (needs care — the CPU expects `DI` in the same cycle).
- **Fit.** Lower risk than assumed. The cheat engine was *not* cut for space — see §1a. It was removed as dead code because nothing fed it. No build with cheats enabled has ever been attempted, so P0 utilization numbers are still required, but there is no evidence of a fit problem.
- **Game Genie descrambling.** Easy to get subtly wrong. Copy from a reference implementation and unit-test the decoder in a standalone C/Python harness against published code/address pairs *before* writing the RTL.
- **Savestates.** Codes should not be captured in save state; a state loaded with different cheats active must not corrupt. Verify `gg_reset` fires on cart load, palette load, and state restore.
- **Cart writes (P7).** A malformed write cycle can corrupt a real save. Guard behind an explicit opt-in toggle.

---

## 8. Open questions

1. Does `parameters` bit 2 + bit 9 coexist cleanly, or does the persisted browsed filename fight the slot-0-derived name? Note bit 2 *appends* the slot extension to the slot-0 filename, so the file is `<rom>.gbc.cht`, not `<rom>.cht`.
2. Which GameShark type bytes beyond `01` are worth supporting (`80`, `90`, bank-switched variants)? The parser currently ignores the type byte and treats every 8-digit code as an address/value override, which is what made the P1 rupee test work.
3. Should the GB package (`pkg/gb`) ship cheats too, or GBC first? (RTL is shared, so it's a packaging decision only.)
4. Upstream `CODES` disables a code when the same address is loaded twice — does that interact badly with a mask-based enable scheme? Answered: it keeps at most one entry per address, which is what makes the split address/data lookup in §7 equivalent to the original.
