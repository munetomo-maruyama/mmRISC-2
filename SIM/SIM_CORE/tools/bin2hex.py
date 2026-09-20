#!/usr/bin/env python3
"""bin2hex.py : raw binary -> one 64 bit little endian word per line.

   python3 bin2hex.py <in.bin> <out.hex>

   The image starts at the load address of the program, which the test bench
   maps to the start of its memory.
"""
import sys

with open(sys.argv[1], "rb") as f:
    data = f.read()
data += b"\x00" * ((-len(data)) % 8)

with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 8):
        f.write("%016x\n" % int.from_bytes(data[i:i+8], "little"))
