ENTRY(_start)
SECTIONS
{
  . = 0xbfc00000;
  .text : { KEEP(*(.boot.reset)) *(.text .text.*) }
  /DISCARD/ : {
    *(.MIPS.abiflags) *(.reginfo) *(.gnu.attributes)
    *(.comment) *(.note .note.*) *(.pdr)
  }
}
