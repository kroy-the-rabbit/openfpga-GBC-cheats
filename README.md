# Gameboy/Game Boy Color for Analogue Pocket
Ported from the original core developed at https://github.com/MiSTer-devel/Gameboy_MiSTer

This repository is [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)
with cheat support added, and nothing else changed. See
[docs/CHEATS.md](docs/CHEATS.md).

Please report any issues encountered to this repo. Issues will be upstreamed as necessary.

## Installation
To install the core, copy the `Assets`, `Cores`, and `Platform` folders over to the root of your SD card. Please note that Finder on macOS automatically _replaces_ folders, rather than merging them like Windows does, so you have to manually merge the folders.

Place the GBC bios in `/Assets/gbc/common` named "gbc_bios.bin", the GB bios in `/Assets/gb/common` named "gb_bios.bin", and the SGB bios in `/Assets/gb/common` named "sgb_boot.bin".


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
