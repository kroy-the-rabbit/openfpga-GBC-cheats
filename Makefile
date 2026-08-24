# Containerized Quartus build for the Pocket GB/GBC core. See tools/podman/README.md.
#
#   make installers   download Quartus Lite installers (3.4 GB, once)
#   make image        build the container image (~20 min, once)
#   make gbc | gb     build a target -> build/<target>/{*.rbf_r,sd/,*.zip,report.txt}
#   make all          both targets
#   make gbc SKIP_COMPILE=1   repackage existing outputs (no Quartus run)
#   make gb SEED=2            re-run the fitter with a different seed
#   make report       regenerate build/<target>/report.txt from existing outputs
#   make flash-gbc    copy build/gbc/sd/ onto the mounted Pocket card and unmount it
#   make shell        interactive shell in the container with the repo at /work
#   make clean        remove build/

PODMAN ?= podman
IMAGE  ?= localhost/pocket-quartus:25.1std
HARNESS := tools/podman
DL      := $(HARNESS)/dl
GIT_SHA   := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit)
GIT_DIRTY := $(shell git status --porcelain 2>/dev/null | grep -q . && echo 1)

RUN = $(PODMAN) run --rm $(PODMAN_TTY) \
	--userns=keep-id --security-opt label=disable \
	-v "$(CURDIR):/work" -w /work -e HOME=/tmp \
	-e GIT_SHA=$(GIT_SHA) -e GIT_DIRTY=$(GIT_DIRTY) -e SKIP_COMPILE=$(SKIP_COMPILE) \
	-e SEED=$(SEED) -e RELEASE_NAME=$(RELEASE_NAME) \
	$(IMAGE)

.PHONY: installers image gbc gb all report flash-gbc flash-gb shell clean

installers:
	$(HARNESS)/fetch-installers.sh

image: installers
	$(PODMAN) build --security-opt label=disable \
		-v "$(CURDIR)/$(DL):/dl:ro" \
		-t $(IMAGE) -f $(HARNESS)/Containerfile $(HARNESS)

gbc gb:
	$(RUN) $(HARNESS)/build-core.sh $@

all: gbc gb

report:
	@for t in gbc gb; do [ -d build/$$t/src/output_files ] && GIT_SHA=$(GIT_SHA) GIT_DIRTY=$(GIT_DIRTY) $(HARNESS)/report.sh $$t; done; true

flash-gbc flash-gb:
	tools/flash.sh $(@:flash-%=%) $(SD)

shell: PODMAN_TTY = -it
shell:
	$(RUN) bash

clean:
	rm -rf build

SIMIMAGE ?= localhost/pocket-sim:1
# CHT_DB=/path/to/cht mounts a corpus of .cht files for the cross-check; with
# it unset run.py looks in external/, which is git-ignored.
CHTDB = $(if $(CHT_DB),-v "$(abspath $(CHT_DB)):/cht:ro" -e CHT_DB=/cht,)
SIMRUN = $(PODMAN) run --rm --userns=keep-id --security-opt label=disable \
	-v "$(CURDIR):/work" -w /work -e HOME=/tmp $(CHTDB) $(SIMIMAGE)

.PHONY: sim-image test

sim-image:
	$(PODMAN) build --security-opt label=disable -t $(SIMIMAGE) \
		-f $(HARNESS)/Containerfile.sim $(HARNESS)

# Simulation suite. The 2456-file cross-check needs a corpus of .cht files,
# which this repo does not carry: set CHT_DB to a directory of them (see
# docs/CHEATS.md) or that one step is skipped. ARGS passes through to it,
# e.g. `make test ARGS="-n 100"`.
test:
	$(SIMRUN) python3 tools/cheats/genmenu.py --check
	$(SIMRUN) python3 tools/cheats/genfont.py --check
	$(SIMRUN) python3 tools/cheats/ggdecode.py --test
	$(SIMRUN) sh -c 'mkdir -p build/sim && iverilog -g2012 -o build/sim/tb_codes tools/sim/tb_codes.sv src/gb/cheatcodes.sv 2>/dev/null && vvp build/sim/tb_codes'
	$(SIMRUN) sh -c 'mkdir -p build/sim && iverilog -g2012 -o build/sim/tb_fast tools/sim/tb_cheat_loader_fast.sv src/gb/cheat_loader.sv && vvp build/sim/tb_fast'
	$(SIMRUN) python3 tools/sim/run.py $(ARGS)
	$(SIMRUN) python3 tools/sim/run_fixtures.py
	$(SIMRUN) python3 tools/sim/run_e2e.py
	$(SIMRUN) python3 tools/sim/run_osd.py
