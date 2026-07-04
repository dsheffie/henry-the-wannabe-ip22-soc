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

# Lockstep co-sim checker: r9999's embedded interp (RTL-agnostic ISS) linked in
# as the golden model.  These .cc live in the core tree; compiled with the same
# ThinLTO as the model objects and added to the final link.
INTERP     = interpret loadelf disassemble helper saveState sparse_mem sgi_hpc sgi_mc sgi_scc
INTERP_CC  = $(addprefix $(R9999)/,$(addsuffix .cc,$(INTERP)))

KERNEL    ?= /home/dsheffie/code/chd-dumper/extracted/unix
ARCS      ?= $(R9999)/arcs/henry_arcs.bin
START_PC  ?= 0xbfc00000      # FSBL reset vector (henry_arcs); one blob boots Linux + IRIX

VFLAGS = -cc --exe -O3 \
         -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
         -Wno-UNUSED -Wno-BLKANDNBLK -Wno-PINMISSING \
         -y $(RTL) -y $(R9999) +incdir+$(R9999) --top-module $(TOP) -Mdir obj_dir \
         -CFLAGS "-I$(R9999)" \
         -o henry_tb

# Depend on the r9999 core sources too (via -y $(R9999)), so a core-only change
# (e.g. a CP0/exec.sv edit) triggers a rebuild instead of silently running a
# stale binary.
obj_dir/henry_tb: $(RTL)/henry_soc.sv $(RTL)/mc.sv $(RTL)/hpc3.sv $(RTL)/ioc.sv $(RTL)/int3.sv henry_tb.cpp $(wildcard $(R9999)/*.sv $(R9999)/*.vh)
	# Pass the golden-ISS .cc to Verilator's --exe so it compiles them (RTL-agnostic)
	# alongside henry_tb.cpp into obj_dir/*.o.
	$(VERILATOR) $(VFLAGS) $(RTL)/henry_soc.sv henry_tb.cpp $(INTERP_CC)
	$(MAKE) CXX="clang++-16" LINK="clang++-16" \
	        OPT_FAST="-O3 -flto=thin" OPT_GLOBAL="-O2 -flto=thin" OPT_SLOW="-O1 -flto=thin" \
	        LDFLAGS="-flto=thin" -C obj_dir -f V$(TOP).mk
	# ThinLTO doesn't cross a plain ar archive -- re-link the .o directly so the
	# hot model objects get LTO'd (per dsheffie: use the *.o, not the ar).
	cd obj_dir && clang++-16 -flto=thin henry_tb.o verilated.o verilated_dpi.o Vhenry_soc*.o $(addsuffix .o,$(INTERP)) -lm -lpthread -latomic -o henry_tb

.PHONY: build run clean
build: obj_dir/henry_tb

run: obj_dir/henry_tb
	./obj_dir/henry_tb --kernel $(KERNEL) --arcs $(ARCS) --start-pc $(START_PC)

clean:
	rm -rf obj_dir
