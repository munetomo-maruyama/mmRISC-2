/* Linker script for the core tests: text at the reset vector, tohost at a
   fixed address the test bench knows (0x8000_2000). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text : { *(.text.init) *(.text) *(.text.*) }

    . = 0x80001000;
    .data : { *(.data) *(.data.*) *(.sdata) *(.sdata.*)
              *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }

    . = 0x80002000;
    .tohost : { *(.tohost) }

    . = 0x80003000;
    .bss : { __bss_start = .; *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
             . = ALIGN(8); __bss_end = .; }
}
