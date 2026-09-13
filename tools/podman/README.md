# Build harness

Releases are built on the build runners with Quartus Prime Lite 25.1std,
inside the private `localhost/pocket-quartus:25.1std` image, through the
orchestrator's `tools/runner-build`. No Quartus runs on GitHub.
`build-core.sh` is what runs in that container, and anyone can run the same
harness to rebuild a release from its tag.

## Reproducing a release

You download Quartus Lite from Altera and accept Altera's terms yourself;
installers are fetched only with `ACCEPT_ALTERA_EULA=1` set.

```sh
git checkout v0.9999.<sha>
ACCEPT_ALTERA_EULA=1 make installers   # 3.4 GB into tools/podman/dl/, once
make image                             # Quartus installed into a local image, once
RELEASE_NAME=v0.9999.<sha> make all    # both cores, stamped as the release
sha256sum build/*/kroy.*.zip           # compare with the release's SHA256SUMS
```

Compare `build/<target>/report.txt` with the release's `report-gbc.txt` and
`report-gb.txt`. The bitstream hash can differ from the release even on the
same source: build-ID timestamps and placement on another machine change it.

## Building

From `pocket-dev`:

```sh
tools/runner-build start sisko pocket-gbc gbc <job> HEAD
tools/runner-build current sisko
tools/runner-build fetch sisko pocket-gbc gbc <job> HEAD
SEED=2 tools/runner-build start sisko2 pocket-gbc gb <job> HEAD   # a reseed
```

`fetch` brings back per target:

| Path | What |
|---|---|
| `build/gbc/kroy.GBC_<version>.zip` | the core package, stamped `0.9999.<sha>` |
| `build/gbc/report.txt` | worst slack per analysis type, utilization, full fit/STA summaries |
| `build/gbc/build.log` | full Quartus output |
| `build/gbc/gbc.rbf_r` | Pocket bitstream (bit-reversed `.rbf`) |

It does not refresh `build/<target>/sd/` or `src/output_files/`; those can be
from an older build.

## Timing gate

Quartus exits 0 on a design that misses timing. Read worst slack from the
`sta.summary` section of the fetched `report.txt`; any negative figure means
the build is not fit to flash. The worst hold path sits inside the PLL's own
output counter and can tip a few picoseconds negative on placement alone; a
reseed is the answer.

## Installing

```sh
make flash-gbc ZIP=build/gbc/kroy.GBC_<version>.zip
```

`tools/flash.sh` gates on the `report.txt` beside the zip, merges onto the
mounted card without deleting anything, syncs, verifies every file, and leaves
the card mounted. `UNMOUNT=1` unmounts.

## Restamping for a release

A release is stamped `0.9999.<sha>` from the tag. On the checkout that holds
the compiled outputs:

```sh
RELEASE_NAME=v0.9999.<sha> make gbc SKIP_COMPILE=1
```

This repackages the existing bitstream without a Quartus run. Check that every
file but `core.json` is byte-identical to the tested zip.

The checked-in `src/` is never modified. `build-core.sh` copies it, flips
`` `define isgbc `` for the GB target, and sets `NUM_PARALLEL_PROCESSORS ALL`.
Untagged builds are stamped `<version>.<sha>[.dirty]` with the build date;
`pkg/` keeps the bare `0.9999`.

## Testing the RTL

```sh
make sim-image    # once, small Icarus Verilog image
make test         # decoder self-test, CODES testbench, parser vs reference, overlay
```

See [../../docs/CHEATS.md](../../docs/CHEATS.md).
