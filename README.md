# Gameboy/Game Boy Color for Analogue Pocket
Ported from the original core developed at https://github.com/MiSTer-devel/Gameboy_MiSTer

This repository is [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)
with cheat support added. What ships on the card is upstream's apart from the
cheat engine: three new modules in `src/gb/`, the hooks that reach them in
`core_top.sv` and `gb.v`, and a data slot plus two menu entries in `pkg/`. See
[docs/CHEATS.md](docs/CHEATS.md).

Everything outside `src/` and `pkg/` is new here and none of it ships: a
containerised Quartus build, a simulation harness, docs and example cheat files.
Builds here also differ from upstream's in one way that is not the cheats, the
fitter running STANDARD FIT with hold-time optimisation rather than FAST FIT,
for repeatable timing closure; `tools/podman/build-core.sh` says why.

Please report any issues encountered to this repo. Issues will be upstreamed as necessary.

## Installation

Prebuilt cores are on the [Releases](../../releases) page: download the zip for
the core you want and unzip it. Nothing below needs a terminal; building from
source is only for changing something.

This core installs as `Cores/kroy.GBC` and `Cores/kroy.GB`. It does not replace
an upstream `budude2.GBC` install, it sits beside it: APF names a core folder
after the author in its `core.json`, and this one says `kroy` because it is not
budude2's build. Delete the old folders if you do not want both listed, and
their `/Settings/budude2.*` folders with them. Saves are keyed by platform, not
by core, so they carry over untouched.

To install the core, copy the `Assets`, `Cores`, and `Platforms` folders over to the root of your SD card. Please note that Finder on macOS automatically _replaces_ folders, rather than merging them like Windows does, so you have to manually merge the folders.

Place the GBC bios in `/Assets/gbc/common` named "gbc_bios.bin", the GB bios in `/Assets/gb/common` named "gb_bios.bin", and the SGB bios in `/Assets/gb/common` named "sgb_boot.bin". These are not in the zip and the core will not run without them.


## Usage
ROMs should be placed in `/Assets/gbc/common`, and `/Assets/gb/common`

## Features

### Supported
* Cheats (Game Genie + GameShark, libretro `.cht` files) - see [docs/CHEATS.md](docs/CHEATS.md)
* Real-Time Clock
* Fastforward
* Original Gameboy display modes
* Super Gameboy Emulation
* Custom Borders (SGB)
* Custom Palettes (SGB)
* Enhance GBA features
* Save States and Sleep
* External Cartridges

### In Progress
¯\\_(ツ)_/¯

## License

The Game Boy core is GPL-3.0-or-later. The notices are in the source files
themselves, carrying Till Harbaum's 2015 copyright and later contributors';
`src/gb/gb.v` is a good example. The cheat engine added here is under the same
terms and says so with SPDX headers.

`src/apf/` is not GPL. Those files are Analogue's Pocket Framework, supplied
under Analogue's own software licence agreement and the Pocket EULA linked from
their headers, which provide that where the MIT or GNU licences must apply,
those prevail.

Neither this repository nor upstream carries a LICENSE file, so the per-file
notices are the licence. Binary releases here are built from a tagged commit of
this repository, which is the corresponding source for them.
