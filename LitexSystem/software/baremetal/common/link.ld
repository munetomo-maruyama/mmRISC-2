/*---------------------------------------------------------------------------
 * link.ld : bare-metal programs on mmRISC-2, all in DRAM
 *
 *   0x8000_0000  _start (.text.init), code, read-only data, data, .bss
 *   then         the heap (malloc, up to the stack)
 *   0x9000_0000  the top of the stack (256 MB of DRAM), STACK_SIZE below it
 *
 * The LiteX BIOS keeps its own data in the SRAM (0x1100_0000) and runs from
 * the ROM, so the whole DRAM is the program's once the BIOS has set it up.
 *---------------------------------------------------------------------------*/
OUTPUT_ARCH(riscv)
ENTRY(_start)

STACK_SIZE = 64K;

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256M
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(8) {
        *(.data .data.*)
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _end = .;                                   /* the heap starts here */
    __stack_top    = ORIGIN(RAM) + LENGTH(RAM);
    __stack_bottom = __stack_top - STACK_SIZE;  /* the heap ends here */
}
