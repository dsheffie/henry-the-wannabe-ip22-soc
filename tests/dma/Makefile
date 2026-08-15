# Directed DMA tests for the henry SoC.
#   dma_memcpy    -- engine isolation (all uncached)
#   dma_coherence -- DMA vs a CACHED copy; the stale-detector positive control
#   rmw_snoop     -- RMW under snoop pressure, self-describing data
CC    := mips-linux-gnu-gcc
FLAGS := -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -nostdlib -nostartfiles \
         -Wl,-Ttext=0x80010000 -Wl,-e,_start -x assembler-with-cpp

all: dma_memcpy.elf dma_coherence.elf rmw_snoop.elf

%.elf: %.S
	$(CC) $(FLAGS) $< -o $@

clean:
	rm -f *.elf
