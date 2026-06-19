/*
 * pit_test.c -- bare-metal 8254 PIT Timer0 interrupt test for the Henry SoC.
 *
 * Programs the IOC2 8254 counter0 as a periodic down-counter; its terminal count
 * drives INT3 Timer0 (Level 2) -> CPU IP4. Enables SR.IM[4]+IE, then waits for N
 * periodic interrupts -- the exception handler (baremetal_support.c, g_pit_mode)
 * acks each one via the INT3 Timer Clear register so the timer can re-fire. Checks
 * the fired IP bits == 0x10 (IP4). Runs in henry_tb (--kernel pit_test.elf), which
 * has the full SoC (core + ioc + int3).
 */
#include <stdint.h>
#include "printf.h"

extern volatile int      g_ext_irq_count;
extern volatile uint32_t g_ext_irq_ip;
extern volatile int      g_pit_mode;

/* IOC2 8254 registers, uncached kseg1. Within line 0xb0: tcnt0=byte3 (0xb3),
 * control word=byte15 (0xbf). */
#define PIT_TCWORD ((volatile uint8_t *)0xBFBD98BFu)
#define PIT_TCNT0  ((volatile uint8_t *)0xBFBD98B3u)

int main(void)
{
    g_pit_mode = 1;                       /* ISR acks INT3 timers via Timer Clear */

    /* Program counter0: SC1:SC0=00 (counter0), RW1:RW0=11 (lo then hi byte),
     * M2:M1:M0=010 (mode 2, rate generator), BCD=0  ->  0x34.
     * Small load so it fires fast: 20 PIT ticks @ 1 MHz = 20 us (~2000 core cyc). */
    *PIT_TCWORD = 0x34;
    *PIT_TCNT0  = 20u & 0xffu;            /* low byte  */
    *PIT_TCNT0  = (20u >> 8) & 0xffu;     /* high byte -> load + start counting */

    /* Enable IP4: SR.IM[4] (bit 12) + IE (bit 0); clear ERL (bit 2, set at reset
     * -- irq_pending in the RTL requires ~ERL). */
    uint32_t sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 2);
    sr |= (1u << 12) | 1u;
    __asm__ volatile("mtc0 %0, $12" : : "r"(sr) : "memory");

    /* Wait for 5 periodic Timer0 interrupts (ISR acks via Timer Clear each time). */
    while (g_ext_irq_count < 5) { }

    printf_("pit timer0 irqs: %d  ip-bits: 0x%x\n", g_ext_irq_count, g_ext_irq_ip);
    printf_("checksum %d\n", (int)g_ext_irq_ip);   /* expect 0x10 (IP4) */
    return 0;
}
