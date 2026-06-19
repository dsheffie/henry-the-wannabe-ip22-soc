# Henry SoC SCC serial-Rx -> INT3 (map_src[5]) -> CPU IP2 interrupt test.
# Builds a bare-metal MIPS ELF (reusing the r9999 bare-metal runtime) and runs it
# on henry_tb with a TB-injected serial byte (--rx).
R9999    := /home/dsheffie/code/r9999
HELLO    := $(R9999)/hello
CSMITH   := $(R9999)/tests/csmith
HENRY_TB := ../../sim/obj_dir/henry_tb

CC := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := scc_rx_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

scc_rx_test.elf: $(SRCS) $(HELLO)/baremetal.ld
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    scc_rx_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

# Build henry_tb (picks up ioc.sv/int3.sv/henry_soc.sv changes) then run with a byte.
run: scc_rx_test.elf
	$(MAKE) -C ../../sim
	$(HENRY_TB) --kernel $< --rx "A" --maxcyc 2000000 2>&1

clean:
	rm -f scc_rx_test.elf
