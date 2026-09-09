# Henry SoC Verilator sim.  Builds henry_soc (rtl/) + the r9999 core (submodule
# or a live tree) + the testbench, then boots a kernel toward the IRIX banner.
#
#   make                              # build
#   make run                          # boot /unix with the ARCS blob
#   make run KERNEL=foo.elf ARCS=...  # boot something else
#
# R9999 points at the core sources (default: the live tree; the in-repo submodule
# is the intended source once updated to a current main).

# Derived from THIS Makefile's location so a sim always compiles the r9999 submodule
# of the tree it lives in.  Hardcoding the live tree meant a build in any OTHER
# checkout silently verilated MAIN's RTL (trees sit at different commits).
MKFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
R9999     ?= $(MKFILE_DIR)../r9999
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

VFLAGS = -cc --exe -O3 --savable \
         -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
         -Wno-UNUSED -Wno-BLKANDNBLK -Wno-PINMISSING \
         -y $(RTL) -y $(R9999) +incdir+$(R9999) +define+ENABLE_STORE_CHECK +define+INSN_PACED_COUNT +define+ENABLE_DEBUG_WATCHPOINT $(if $(TIMER_RARE),+define+TIMER_RARE=$(TIMER_RARE),) --top-module $(TOP) -Mdir obj_dir \
         -CFLAGS "-I$(R9999) -DFAITHFUL_SCSI -DSTORE_CHECK" \
         -o henry_tb
# `make BIG_L2=1` -> 1MB sim-only L2 (LG_L2_NUM_SETS=16) to shake out bugs the tiny
# 16KB direct-mapped L2 was masking; leaves the FPGA build at 16KB.
# `make THREADS=8` -> Verilator multithreaded model.  The box has 24 cores and the
# baseline single-threaded model runs ~16K insn/s, which makes a cold-boot co-sim
# ~74h; anything that multiplies throughput is worth having even though checkpoint
# resume is the real lever.  --threads-dpi=all so the golden-ISS DPI calls stay legal.
ifdef THREADS
VFLAGS += --threads $(THREADS) --threads-dpi all
endif
# Escape hatch for one-off build knobs, e.g. cache geometry:
#   make VFLAGS_EXTRA="+define+LG_L2_NUM_SETS=18"
# (VFLAGS is a plain `=` assignment, so `make VFLAGS+=...` on the command line
#  would REPLACE it wholesale -- hence a dedicated append variable.)
VFLAGS += $(VFLAGS_EXTRA)

ifdef BIG_L2
VFLAGS += +define+BIG_SIM_L2
endif
# `make TRACE_ALL_PC=1` -> dram_trace captures ALL retires (kernel+user) so the codec
# can be validated on boot code (env TRACE_VALIDATE=1) without booting to userspace.
ifdef TRACE_ALL_PC
VFLAGS += +define+TRACE_ALL_PC -CFLAGS -DTRACE_ALL_PC
endif
# `make UNCACHED=1` -> force ALL D-side data traffic uncached (coherence litmus test)
ifdef UNCACHED
VFLAGS += +define+FORCE_UNCACHED
endif

# obj_dir/.verilated is defined first below, so pin the default goal to the binary.
.DEFAULT_GOAL := obj_dir/henry_tb

# Two-phase build so a golden-ISS .cc/.hh edit rebuilds WITHOUT re-verilating:
#  1. obj_dir/.verilated -- re-run Verilator only when the RTL/testbench STRUCTURE
#     changes (RTL *.sv, the r9999 *.sv/*.vh, or this Makefile).  Verilator emits
#     obj_dir/V$(TOP).mk, whose compiles carry -MMD (-> per-.o .d dependency files).
#  2. obj_dir/henry_tb -- ALSO depends on the golden-ISS sources (henry_tb.cpp +
#     INTERP_CC + r9999 *.hh), so an interpret.cc / sparse_mem.hh edit FIRES the rule;
#     the sub-make's -MMD deps then recompile exactly the changed .o and relink.
#     (Previously those files were not prerequisites, so `make` silently ran a stale
#     binary -- a core .cc/.hh edit never landed without a `make clean`.)
obj_dir/.verilated: $(RTL)/henry_soc.sv $(RTL)/mc.sv $(RTL)/hpc3.sv $(RTL)/ioc.sv $(RTL)/int3.sv $(RTL)/scsi_shim.sv $(RTL)/enet_shim.sv $(RTL)/dram_trace.sv $(RTL)/mem_arbiter.sv $(wildcard $(R9999)/*.sv $(R9999)/*.vh) Makefile
	# Pass the golden-ISS .cc to Verilator's --exe so it compiles them (RTL-agnostic)
	# alongside henry_tb.cpp into obj_dir/*.o.
	$(VERILATOR) $(VFLAGS) $(RTL)/henry_soc.sv henry_tb.cpp $(INTERP_CC)
	@touch $@

obj_dir/henry_tb: obj_dir/.verilated henry_tb.cpp $(INTERP_CC) $(wildcard $(R9999)/*.hh)
	# LTO dropped from the COMPILES (per dsheffie) -- the clang-14/16 mismatch +
	# ar-archive relink was the whole build headache; clang-16 is forced end-to-end
	# so a core-only edit reliably lands via a plain `make`.  The LINK, however,
	# keeps -flto: the r9999 INTERP .o ($(R9999)/disassemble.o &c) are LLVM bitcode
	# whenever ooo_core has been built there, and Verilator's --exe reuses those
	# in-place objects.  An -flto link consumes bitcode AND regular .o transparently;
	# a plain link fails "file format not recognized".
	# STALE-OBJECT TRAP (cost a whole investigation -- do not remove).  Verilator's
	# generated mk does `VPATH += $(VM_USER_DIR)`, and VM_USER_DIR contains $(R9999).
	# GNU make therefore resolves the target `interpret.o` THROUGH VPATH to a prebuilt
	# $(R9999)/interpret.o left behind by the core repo's own Makefile, decides it is
	# up to date, and never runs the local compile rule -- so this build's -CFLAGS
	# (notably -DSTORE_CHECK) are silently dropped.  The ISS half of the store-check
	# then compiles to nothing, g_iss_stores stays empty, drain_store_check never pairs
	# a single store, and the co-sim store comparison reports "no divergence" forever
	# because it is not running at all.  The core repo must NOT build these with
	# -DSTORE_CHECK (ooo_core provides no g_iss_stores definition -> link error), so
	# the objects genuinely cannot be shared: force them to be compiled HERE.
	# Only interpret.o is STORE_CHECK-sensitive; the other INTERP objects are left as
	# prebuilt (a locally-compiled disassemble.o additionally wants -lcapstone, which
	# this link does not carry).
	rm -f $(R9999)/interpret.o
	$(MAKE) CXX="clang++-16" LINK="clang++-16 -flto" \
	        OPT_FAST="$(if $(OPTFAST),$(OPTFAST),-O2)" OPT_GLOBAL="-O2" OPT_SLOW="-O1" \
	        LDLIBS="-lboost_serialization -lzstd -lcapstone" \
	        -C obj_dir -f V$(TOP).mk henry_tb
	# CANARY: fail loudly if the store-check did not actually get compiled in, rather
	# than shipping a binary whose checker is a no-op.
	@nm obj_dir/interpret.o | grep -q g_iss_stores || \
	  { echo "*** BUILD ERROR: obj_dir/interpret.o lacks g_iss_stores -- STORE_CHECK was"; \
	    echo "*** not compiled in; the co-sim store check would be silently DEAD."; \
	    exit 1; }

.PHONY: build run clean
build: obj_dir/henry_tb

run: obj_dir/henry_tb
	./obj_dir/henry_tb --kernel $(KERNEL) --arcs $(ARCS) --start-pc $(START_PC)

clean:
	rm -rf obj_dir

# mipsmon: ncurses TCP monitor/console client for the mips-axi mon.cc server
# (default localhost:2323).  Deploy the source to the board's ~/axilite-mips
# and `make mipsmon` there too.
mipsmon: mipsmon.cc
	$(CXX) -O2 -Wall mipsmon.cc -o mipsmon -lncurses
