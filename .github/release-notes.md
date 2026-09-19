Two cheat slots under the global switch. Both GB and GBC packages are built
from `0220214`, pass timing and were tested on a Pocket. The release includes
both packages, their timing reports, `BUILD.json`, SHA-256 checksums and
detached signatures.

The core menu now reads Reset core, **Cheat slot 1**, **Cheat slot 2**,
**Cheats enabled**, **Show cheats**, then the usual options.

| Cheats enabled | Slot 1 | Slot 2 | Runs |
|---|---|---|---|
| off | any | any | nothing |
| on | on | on | cheat 1, cheat 2, and every later cheat the file leaves on |
| on | off | on | cheat 2 and the later ones |
| on | on | off | cheat 1 and the later ones |
| on | off | off | the later ones only |

Slot 1 is the first cheat in the `.cht`, slot 2 the second; their menu switch
overrides the file's `enable` key. Every later cheat follows its `enable` key.
All switches are off at every launch and never remembered. **Show cheats**
draws each switch's state and the cheat names over the picture.

[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools) v0.9999.20260918
fills the slots: the two cheats you pick for them go first in the file.

**Download `kroy.GBC_<version>.zip` or `kroy.GB_<version>.zip` below**, not the
"Source code" archives. Those are the repository, and the bitstream is not
committed, so a core installed from one is listed by the Pocket
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
gpg --import RELEASE-KEY.asc
gpg --verify kroy.GBC_<version>.zip.sig kroy.GBC_<version>.zip
```

Cheats are documented in [docs/CHEATS.md](https://github.com/kroy-the-rabbit/openfpga-GBC-cheats/blob/main/docs/CHEATS.md), and the README has
the rest.
