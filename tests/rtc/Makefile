# Henry SoC ds1386 RTC read test. Builds a bare-metal MIPS ELF (reusing the r9999
# bare-metal runtime) and runs it on henry_tb, which has the full SoC (core + hpc3).
R9999    := /home/dsheffie/code/r9999
HELLO    := $(R9999)/hello
CSMITH   := $(R9999)/tests/csmith
HENRY_TB := ../../sim/obj_dir/henry_tb

CC := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := rtc_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

rtc_test.elf: $(SRCS) $(HELLO)/baremetal.ld
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    rtc_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

# Build henry_tb (picks up hpc3.sv changes) then run the test.
run: rtc_test.elf
	$(MAKE) -C ../../sim
	$(HENRY_TB) --kernel $< --maxcyc 2000000 2>&1

clean:
	rm -f rtc_test.elf
