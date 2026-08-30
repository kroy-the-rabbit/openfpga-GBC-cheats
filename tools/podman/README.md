# Containerized build harness

Builds the core with Quartus Prime Lite 25.1std inside a rootless Podman
container so nothing Quartus-related touches the host. The repo is bind-mounted
at `/work`; all outputs land in `build/<target>/` owned by your user.

## One-time setup

```sh
make installers   # ~3.4 GB from Altera's CDN into tools/podman/dl/ (gitignored)
make image        # unattended Quartus install into the image, ~10 min, 10.6 GB
```

## Building

```sh
make gbc          # or: make gb, make all      (~12 min each on 14 cores)
make report       # regenerate report.txt from existing outputs, no recompile
make flash-gbc    # merge build/gbc/sd/ onto the mounted card, verify, unmount
```

Per target you get:

| Path | What |
|---|---|
| `build/gbc/gbc.rbf_r` | Pocket bitstream (bit-reversed `.rbf`) |
| `build/gbc/sd/` | SD-card tree: `pkg/gbc/` plus the bitstream in `Cores/kroy.GBC/` |
| `build/gbc/kroy.GBC_<ver>.zip` | the same, zipped |
| `build/gbc/report.txt` | worst slack per analysis type, utilization, full fit/STA summaries |
| `build/gbc/build.log` | full Quartus output |
| `build/gbc/src/` | the compiled source copy (incremental `db/` kept between runs) |

To flash: copy the contents of `build/gbc/sd/` onto the SD card root (merge
folders; macOS Finder replaces them).

The checked-in `src/` is never modified. `build-core.sh` copies it, flips
`` `define isgbc `` for the GB target, and makes sure `NUM_PARALLEL_PROCESSORS ALL` is set.
The Makefile passes the host's git SHA (and a dirty flag) into the container.
The packaged `core.json` is stamped `version = <base>-cheats.<sha>[.dirty]`
and `date_release = <build date>`, so the Pocket's core menu identifies the
exact commit; `pkg/` in the repo keeps the upstream base version.

## Testing the RTL

```sh
make sim-image    # once, small Icarus Verilog image
make test         # decoder self-test, CODES testbench, parser vs reference
```

See [../../docs/CHEATS.md](../../docs/CHEATS.md).

## Poking around

```sh
make shell        # bash in the container, Quartus on PATH, repo at /work
```

## Notes

- Installer URLs and byte sizes are pinned in `fetch-installers.sh`
  (`QVER=25.1std.0`, `QBUILD=1129`). Bump both to move versions.
- The `.run` is executed straight from the bind-mounted `dl/` during
  `podman build`, so the installers never enter an image layer.
- Lite edition: no license, no login.
