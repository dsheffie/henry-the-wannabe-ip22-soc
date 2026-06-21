/*
 * rtc_test.c -- bare-metal ds1386 RTC read test for the Henry SoC.
 *
 * The ds1386 wall-clock lives in the HPC3 bbRAM window @ phys 0x1fbe0000 (uncached
 * kseg1 0xBFBE0000), internal reg i at +i*4, value in the word's high byte (the BE
 * device-read path byte-swaps it into the low byte, same as the IOC2 SYSID). hpc3.sv
 * returns a FIXED valid BCD time (2000-01-01 00:00:00) so IRIX rtodc() converges.
 *
 * Reads the 7 clock registers IRIX uses and checks they equal the expected BCD.
 * Runs in henry_tb (--kernel rtc_test.elf), which has the full SoC (core + hpc3).
 */
#include <stdint.h>
#include "printf.h"

#define RTC_BASE 0xBFBE0000u
#define RTC_REG(off) (*(volatile uint32_t *)(RTC_BASE + (off)))
/* device-read byte-swap puts the ds1386 byte in [7:0]; mask it off the word. */
#define RTC_RD(off)  (RTC_REG(off) & 0xffu)

int main(void)
{
    uint32_t sec   = RTC_RD(0x04);
    uint32_t min   = RTC_RD(0x08);
    uint32_t hour  = RTC_RD(0x10);
    uint32_t dow   = RTC_RD(0x18);
    uint32_t date  = RTC_RD(0x20);
    uint32_t month = RTC_RD(0x24);
    uint32_t year  = RTC_RD(0x28);

    printf_("rtc %02x-%02x-%02x %02x:%02x:%02x dow=%x\n",
            year, month, date, hour, min, sec, dow);

    /* expected fixed BCD: 2000-01-01 00:00:00, day-of-week 1 */
    int ok = (sec == 0x00) && (min == 0x00) && (hour == 0x00) &&
             (dow == 0x01) && (date == 0x01) && (month == 0x01) && (year == 0x00);
    printf_("checksum %d\n", ok ? 1 : 0);   /* expect 1 */
    return 0;
}
