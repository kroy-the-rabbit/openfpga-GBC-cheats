**Download `kroy.GBC_<version>.zip` or `kroy.GB_<version>.zip` below**, not the
"Source code" archives. Those are the repository, and the bitstream is built by
CI rather than committed, so a core installed from one is listed by the Pocket
but cannot start: *error in framework, can't find bitstream*.

## Installing

Unzip and merge `Assets`, `Cores` and `Platforms` into the root of the SD card.
This installs as `Cores/kroy.GBC` and `Cores/kroy.GB`, beside any `budude2.*`
install rather than replacing it.

On macOS, Finder **replaces** a folder instead of merging it, which deletes the
ROMs and BIOS already in `Assets`. Copy the folders inside `Assets`, `Cores` and
`Platforms` rather than dragging the three top-level ones.

No BIOS is included and the core will not start without one:

| File | Goes in |
|---|---|
| `gbc_bios.bin` | `/Assets/gbc/common` |
| `gb_bios.bin` | `/Assets/gb/common` |
| `sgb_boot.bin` | `/Assets/gb/common` |

## Checking a download

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Cheats are documented in [docs/CHEATS.md](https://github.com/kroy-the-rabbit/openfpga-GBC-cheats/blob/cheats/docs/CHEATS.md), and the README has
the rest.
