/* One hart, so there is nothing to wake: jump straight to the image the
 * BIOS has loaded. a3 holds its address, a0..a2 the arguments the next
 * stage expects (hart id, device tree, ...). */
.section    .text, "ax", @progbits
.global boot_helper

boot_helper:
  jr a3
