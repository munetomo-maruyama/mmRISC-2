#!/usr/bin/env python3
#---------------------------------------------------------------------------
# gen_t28.py : writes tests/t28_bitmanip.S
#
# Zba and Zbb against a model written here in Python: every instruction
# (and the immediates that matter) with the edges (0, 1, -1, the most
# negative number, the 32 bit edges, a byte pattern) and pseudo random
# operands from xorshift64. The test folds the results into a checksum and
# compares it with the one computed here. riscv-tests (rv64uzba / rv64uzbb)
# covers a handful of values per instruction; this covers many more, and the
# word forms and the immediates with the shift amounts that matter.
#
# The second part checks that the encodings next to the new ones still trap
# as illegal (PACKW of Zbkb, the unary codes that are not defined).
#
#   python3 tools/gen_t28.py            (the test is checked in)
#---------------------------------------------------------------------------
import random, sys

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1

def s64(x):
    x &= M64
    return x - (1 << 64) if x >> 63 else x

def sx32(x):
    x &= M32
    return (x | ~M32) & M64 if x >> 31 else x

def rol(x, n, w):
    m = (1 << w) - 1
    x &= m; n %= w
    return ((x << n) | (x >> (w - n))) & m

def clz(x, w):
    for i in range(w):
        if x >> (w - 1 - i) & 1:
            return i
    return w

def ctz(x, w):
    for i in range(w):
        if x >> i & 1:
            return i
    return w

# name: (kind, function); kind r = rs1, rs2 ; i = rs1, imm ; u = rs1 only
OPS = {
    'add.uw':    ('r', lambda a, b: ((a & M32) + b) & M64),
    'sh1add':    ('r', lambda a, b: ((a << 1) + b) & M64),
    'sh2add':    ('r', lambda a, b: ((a << 2) + b) & M64),
    'sh3add':    ('r', lambda a, b: ((a << 3) + b) & M64),
    'sh1add.uw': ('r', lambda a, b: (((a & M32) << 1) + b) & M64),
    'sh2add.uw': ('r', lambda a, b: (((a & M32) << 2) + b) & M64),
    'sh3add.uw': ('r', lambda a, b: (((a & M32) << 3) + b) & M64),
    'slli.uw':   ('i6', lambda a, n: ((a & M32) << n) & M64),
    'andn':      ('r', lambda a, b: a & ~b & M64),
    'orn':       ('r', lambda a, b: (a | ~b) & M64),
    'xnor':      ('r', lambda a, b: ~(a ^ b) & M64),
    'min':       ('r', lambda a, b: a if s64(a) < s64(b) else b),
    'minu':      ('r', lambda a, b: a if a < b else b),
    'max':       ('r', lambda a, b: b if s64(a) < s64(b) else a),
    'maxu':      ('r', lambda a, b: b if a < b else a),
    'rol':       ('r', lambda a, b: rol(a, b & 63, 64)),
    'ror':       ('r', lambda a, b: rol(a, (64 - (b & 63)) % 64, 64)),
    'rolw':      ('r', lambda a, b: sx32(rol(a, b & 31, 32))),
    'rorw':      ('r', lambda a, b: sx32(rol(a, (32 - (b & 31)) % 32, 32))),
    'rori':      ('i6', lambda a, n: rol(a, (64 - n) % 64, 64)),
    'roriw':     ('i5', lambda a, n: sx32(rol(a, (32 - n) % 32, 32))),
    'clz':       ('u', lambda a: clz(a, 64)),
    'ctz':       ('u', lambda a: ctz(a, 64)),
    'cpop':      ('u', lambda a: bin(a).count('1')),
    'clzw':      ('u', lambda a: clz(a & M32, 32)),
    'ctzw':      ('u', lambda a: ctz(a & M32, 32)),
    'cpopw':     ('u', lambda a: bin(a & M32).count('1')),
    'sext.b':    ('u', lambda a: (a & 0xFF) | (~0xFF & M64 if a & 0x80 else 0)),
    'sext.h':    ('u', lambda a: (a & 0xFFFF) | (~0xFFFF & M64 if a & 0x8000 else 0)),
    'zext.h':    ('u', lambda a: a & 0xFFFF),
    'orc.b':     ('u', lambda a: sum((0xFF << (8 * i)) for i in range(8) if (a >> (8 * i)) & 0xFF)),
    'rev8':      ('u', lambda a: int.from_bytes(a.to_bytes(8, 'little'), 'big')),
}

# the edges, every pair of them, then RANDOM pairs from xorshift64; the
# results go into a checksum (rotate left by 5, xor) that the test compares
EDGES = [0, 1, M64, 1 << 63, (1 << 63) - 1, M32, 1 << 31,
         0x00FF_00FF_8000_7F80]
RANDOM = 32
SEED = 0x2545_F491_4F6C_DD1D

def xs(x):
    x ^= (x << 13) & M64
    x ^= x >> 7
    x ^= (x << 17) & M64
    return x & M64

# Rotate and xor alone is linear: XNOR for XOR flips every result, and an
# even number of flips cancels (it did, the first version missed M276).
# The multiply by an odd constant makes it non linear.
MIXK = 0x9E37_79B9_7F4A_7C15

def mix(acc, r):
    return (((((acc << 5) | (acc >> 59)) & M64) ^ (r & M64)) * MIXK) & M64

def checksum(f, kind, imm):
    def call(a, b):
        if kind == 'r':
            return f(a, b)
        if kind in ('i5', 'i6'):
            return f(a, imm)
        return f(a)
    acc = 0
    for a in EDGES:
        for b in (EDGES if kind == 'r' else EDGES[:1]):
            acc = mix(acc, call(a, b))
    x = SEED
    for k in range(RANDOM):
        x = xs(x); a = x
        x = xs(x); b = x
        if k & 1:
            a >>= (a & 63)              # smaller values as well
        acc = mix(acc, call(a, b))
    return acc

def main():
    rng = random.Random(28)
    out = []
    w = out.append
    entries = []                         # (label, comment, expected)
    subs = []
    for name, (kind, f) in OPS.items():
        if kind in ('i5', 'i6'):
            top = 31 if kind == 'i5' else 63
            imms = [0, 1, top, top - 1, (top + 1) // 2, rng.randrange(2, top - 1)]
        else:
            imms = [None]
        for imm in imms:
            lab = 'op%d' % len(entries)
            if kind == 'r':
                ins = '%-9s x12, x10, x11' % name
            elif imm is not None:
                ins = '%-9s x12, x10, %d' % (name, imm)
            else:
                ins = '%-9s x12, x10' % name
            subs.append((lab, ins))
            entries.append((lab, ins.strip(), checksum(f, kind, imm),
                            8 * (len(EDGES) if kind == 'r' else 1)))

    w('// t28_bitmanip : Zba and Zbb against a model (generated by')
    w('// tools/gen_t28.py; do not edit, run the script again)')
    w('//')
    w('//   1 every instruction (and the immediates that matter) over the %d edge' % len(EDGES))
    w('//     values (every pair of them for two operands) and %d pairs from' % RANDOM)
    w('//     xorshift64; the results go into')
    w('//     a checksum (rotate left by 5, xor, multiply; no Zba / Zbb) that is')
    w('//     compared with the one the script computed. Check n is entry n - 2')
    w('//     of the table, which names the instruction.')
    w('//   2 the encodings next to the new ones still trap as illegal')
    w('#include "test.h"')
    w('')
    w('// x23 = (rotl(x23, 5) ^ x12) * x30 (x30 = an odd constant)')
    w('#define MIX slli x29, x23, 5; srli x23, x23, 59; or x23, x23, x29; xor x23, x23, x12; mul x23, x23, x30')
    w('')
    w('    .section .text.init')
    w('    .globl _start')
    w('_start:')
    w('    TEST_INIT')
    w('    la   x20, table')
    w('    li   x30, 0x%016x' % MIXK)
    w('    la   x27, edges')
    w('    li   gp, 2')
    w('next_op:')
    w('    ld   x21, 0(x20)                  // the subroutine, 0 at the end')
    w('    beqz x21, part2')
    w('    ld   x22, 8(x20)                  // the expected checksum')
    w('    ld   x28, 16(x20)                 // how many second operands * 8')
    w('    li   x23, 0')
    w('    li   x25, 0                       // a: edge index * 8')
    w('1:  li   x26, 0                       // b')
    w('2:  add  x29, x27, x25')
    w('    ld   x10, 0(x29)')
    w('    add  x29, x27, x26')
    w('    ld   x11, 0(x29)')
    w('    jalr ra, 0(x21)')
    w('    MIX')
    w('    addi x26, x26, 8')
    w('    bne  x26, x28, 2b')
    w('    addi x25, x25, 8')
    w('    li   x29, %d' % (8 * len(EDGES)))
    w('    bne  x25, x29, 1b')
    w('    li   x24, 0x%016x' % SEED)
    w('    li   x25, 0                       // k')
    w('3:  call xs')
    w('    mv   x10, x24')
    w('    call xs')
    w('    mv   x11, x24')
    w('    andi x29, x25, 1')
    w('    beqz x29, 4f')
    w('    andi x29, x10, 63')
    w('    srl  x10, x10, x29')
    w('4:  jalr ra, 0(x21)')
    w('    MIX')
    w('    addi x25, x25, 1')
    w('    li   x29, %d' % RANDOM)
    w('    bne  x25, x29, 3b')
    w('    bne  x23, x22, fail')
    w('    addi x20, x20, 24')
    w('    addi gp, gp, 1')
    w('    j    next_op')
    w('')
    w('    // x24 = xorshift64(x24)')
    w('xs:')
    w('    slli x29, x24, 13')
    w('    xor  x24, x24, x29')
    w('    srli x29, x24, 7')
    w('    xor  x24, x24, x29')
    w('    slli x29, x24, 17')
    w('    xor  x24, x24, x29')
    w('    ret')
    w('')
    w('    // the instructions under test')
    for lab, ins in subs:
        w('%s: %s' % (lab, ins))
        w('    ret')
    w('')
    w('    //--------------------------------------------------------------')
    w('    // 2 the neighbours of the new encodings are still illegal')
    w('    //--------------------------------------------------------------')
    w('part2:')
    w('    la   t0, h_ill')
    w('    csrw mtvec, t0')
    w('    li   x28, 0')
    illegal = [
        (0x0805c53b | (1 << 20), 'packw (zext.h with rs2 = 1, Zbkb)'),
        (0x60359513, 'clz family, rs2 field 3 (not defined)'),
        (0x60659513, 'clz family, rs2 field 6 (not defined)'),
        (0x6035951b, 'clzw family, rs2 field 3'),
        (0x6045951b, 'sext.b in OP-IMM-32 (not defined)'),
        (0x2885d513, 'orc.b with a different rs2 field'),
        (0x6b95d513, 'rev8 with a different rs2 field'),
        (0x4805d513, 'OP-IMM 101 with funct6 010010 (bexti of Zbs)'),
        (0x48c59533, 'OP 001 funct7 0100100 (bclr of Zbs)'),
    ]
    for word, what in illegal:
        w('    .word 0x%08x                  // %s' % (word, what))
    w('    li   gp, 90')
    w('    li   t6, %d' % len(illegal))
    w('    bne  x28, t6, fail')
    w('    TEST_DONE')
    w('')
    w('    // an illegal instruction: count it, go on behind it')
    w('h_ill:')
    w('    csrr t0, mcause')
    w('    li   t6, 2')
    w('    li   gp, 91')
    w('    bne  t0, t6, fail')
    w('    addi x28, x28, 1')
    w('    csrr t0, mepc')
    w('    addi t0, t0, 4')
    w('    csrw mepc, t0')
    w('    mret')
    w('')
    w('    TEST_FAIL_HANDLER')
    w('')
    w('    .section .data')
    w('    .align 3')
    w('edges:')
    for e in EDGES:
        w('    .dword 0x%016x' % e)
    w('table:                  // subroutine, checksum, second operands * 8')
    for i, (lab, ins, e, nb) in enumerate(entries):
        w('    .dword %s, 0x%016x, %2d    // %d: %s' % (lab, e, nb, i + 2, ins))
    w('    .dword 0, 0, 0')
    w('')
    w('    TOHOST_SECTION')
    open('tests/t28_bitmanip.S', 'w').write('\n'.join(out) + '\n')
    print('tests/t28_bitmanip.S: %d instructions / immediates' % len(entries))

main()
