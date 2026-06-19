# Henry SoC Verilator sim.  Builds henry_soc (rtl/) + the r9999 core (submodule
# or a live tree) + the testbench, then boots a kernel toward the IRIX banner.
#
#   make                              # build
#   make run                          # boot /unix with the ARCS blob
#   make run KERNEL=foo.elf ARCS=...  # boot something else
#
# R9999 points at the core sources (default: the live tree; the in-repo submodule
# is the intended source once updated to a current main).

R9999     ?= /home/dsheffie/code/r9999
RTL        = ../rtl
VERILATOR ?= /home/dsheffie/local/bin/verilator
TOP        = henry_soc

KERNEL    ?= /home/dsheffie/code/chd-dumper/extracted/unix
ARCS      ?= $(R9999)/arcs/arcs_irix.bin

VFLAGS = -cc --exe -O3 \
         -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
         -Wno-UNUSED -Wno-BLKANDNBLK -Wno-PINMISSING \
         -y $(RTL) -y $(R9999) +incdir+$(R9999) --top-module $(TOP) -Mdir obj_dir \
         -o henry_tb

# Depend on the r9999 core sources too (via -y $(R9999)), so a core-only change
# (e.g. a CP0/exec.sv edit) triggers a rebuild instead of silently running a
# stale binary.
obj_dir/henry_tb: $(RTL)/henry_soc.sv $(RTL)/mc.sv $(RTL)/hpc3.sv $(RTL)/ioc.sv $(RTL)/int3.sv henry_tb.cpp $(wildcard $(R9999)/*.sv $(R9999)/*.vh)
	$(VERILATOR) $(VFLAGS) $(RTL)/henry_soc.sv henry_tb.cpp
	$(MAKE) OPT_FAST="-O2" OPT_GLOBAL="-O2" -C obj_dir -f V$(TOP).mk

.PHONY: build run clean
build: obj_dir/henry_tb

run: obj_dir/henry_tb
	./obj_dir/henry_tb --kernel $(KERNEL) --arcs $(ARCS)

clean:
	rm -rf obj_dir
