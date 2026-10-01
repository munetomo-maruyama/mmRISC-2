/* link.ld : a C program on the bare machine of SIM_SYS. Everything follows
   everything from 0x8000_0000; tohost is found with nm (+tohost=). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text   : { *(.text.init) *(.text) *(.text.*) }
    .rodata : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }
    .data   : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
    . = ALIGN(64);
    .tohost : { *(.tohost) }
    . = ALIGN(64);
    .bss    : { __bss_start = .; *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
                . = ALIGN(8); __bss_end = .; }
}
