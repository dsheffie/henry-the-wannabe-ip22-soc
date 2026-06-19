/*
 * scc_rx_test.c -- bare-metal SCC serial-Rx interrupt test for the Henry SoC.
 *
 * Exercises the first real mappable INT3 source: a serial Rx byte. The TB
 * (henry_tb --rx "...") pushes a byte into the IOC2 SCC chanA Rx FIFO; that
 * raises rx_avail -> INT3 map_src[5] (Serial DUART) -> MAP_INT0 -> istat0[7]
 * (LIO2) -> CPU IP2. The test routes + enables that path, waits for IP2, then
 * reads the byte back from the SCC data register and checks it. Runs in henry_tb.
 *
 * INT3 / SCC registers are 8-bit on the low byte lane (slot+3), uncached kseg1.
 */
#include <stdint.h>
#include "printf.h"

extern volatile int      g_ext_irq_count;
extern volatile uint32_t g_ext_irq_ip;

#define CMEIMASK0 ((volatile uint8_t *)0xBFBD9897u)  /* Map Mask0  @0x97: route mappable -> MAP_INT0 */
#define IMASK0    ((volatile uint8_t *)0xBFBD9887u)  /* Local0 Mask @0x87: enable MAP_INT0 (b7 / LIO2) */
#define SCC_DATA  ((volatile uint8_t *)0xBFBD9837u)  /* SCC chanA data @0x37: Rx byte (read pops FIFO) */

int main(void)
{
    /* Route the serial mappable (bit5) into MAP_INT0, enable MAP_INT0 in Local0. */
    *CMEIMASK0 = 0x20;                 /* mappable bit5 = Serial DUART -> MAP_INT0 */
    *IMASK0    = 0x80;                 /* MAP_INT0 = istat0[7] (LIO2) enabled */

    /* Enable IP2: SR.IM[2] (bit 10) + IE (bit 0); clear ERL (bit 2, set at reset). */
    uint32_t sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 2);
    sr |= (1u << 10) | 1u;
    __asm__ volatile("mtc0 %0, $12" : : "r"(sr) : "memory");

    /* Wait for the TB-injected serial byte to raise IP2. (The handler masks IM[2]
     * and records the fired IP bits; the byte stays in the FIFO until we read it.) */
    while (g_ext_irq_count < 1) { }

    /* Read the received byte from the SCC chanA data register (pops the Rx FIFO). */
    uint8_t c = *SCC_DATA;

    printf_("scc rx irq: ip-bits=0x%x byte=0x%x\n", g_ext_irq_ip, c);
    printf_("checksum %d\n", (int)c);  /* expect the injected byte (TB --rx "A" -> 0x41 = 65) */
    return 0;
}
