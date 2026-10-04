/* pmu_sbi: where OpenSBI's fw_jump jumps to (the kernel's address) */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;
    .text : { *(.text.start) *(.text) *(.text.*) }
    .rodata : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }
    .data : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
    . = ALIGN(8);
    __bss_start = .;
    .bss : { *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON) }
    . = ALIGN(8);
    __bss_end = .;
}
