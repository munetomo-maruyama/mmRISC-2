//---------------------------------------------------------------------------
// sf_dpi.c
//
// Reference model of the FPU for SIM_FPU: Berkeley SoftFloat with the RISCV
// specialisation, reached from the test bench through DPI. SoftFloat is the
// package the RISC-V specification itself points at, so the canonical NaN,
// the propagation rules and "tininess after rounding" are the ones we have
// to match, not an approximation of them.
//
// Every entry point takes the raw bits of the operands and returns the raw
// bits of the result; the flags are handed back separately in the RISC-V
// order (NV OF DZ UF NX as bits 4..0).
//---------------------------------------------------------------------------

// Verilator compiles this with the C++ compiler, and the SoftFloat header
// has no extern "C" of its own, so both the library and the entry point the
// test bench calls have to be named without C++ mangling.
#include <stdint.h>
#include <string.h>
#ifdef __cplusplus
extern "C" {
#endif
#include "softfloat.h"
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
#define DPI_C extern "C"
#else
#define DPI_C
#endif

// rounding modes of RISC-V -> SoftFloat
static uint_fast8_t rm_of(int rm)
{
    switch (rm) {
    case 0:  return softfloat_round_near_even;
    case 1:  return softfloat_round_minMag;
    case 2:  return softfloat_round_min;
    case 3:  return softfloat_round_max;
    case 4:  return softfloat_round_near_maxMag;
    default: return softfloat_round_near_even;
    }
}

static int flags_of(void)
{
    int f = 0;
    uint_fast8_t e = softfloat_exceptionFlags;
    if (e & softfloat_flag_inexact)   f |= 1 << 0;
    if (e & softfloat_flag_underflow) f |= 1 << 1;
    if (e & softfloat_flag_overflow)  f |= 1 << 2;
    if (e & softfloat_flag_infinite)  f |= 1 << 3;   // divide by zero
    if (e & softfloat_flag_invalid)   f |= 1 << 4;
    return f;
}

static void begin(int rm)
{
    softfloat_roundingMode   = rm_of(rm);
    softfloat_exceptionFlags = 0;
    softfloat_detectTininess = softfloat_tininess_afterRounding;
}

// NaN boxing : an unboxed single reads as the canonical NaN
static float32_t unbox(uint64_t v)
{
    float32_t r;
    r.v = ((v >> 32) == 0xFFFFFFFFu) ? (uint32_t)v : 0x7FC00000u;
    return r;
}
static uint64_t box(uint32_t v) { return 0xFFFFFFFF00000000ull | v; }

//---------------------------------------------------------------------------
// op numbers, the same ones CORE_FPU uses
//---------------------------------------------------------------------------
enum {
    FOP_ADD = 0, FOP_SUB, FOP_MUL, FOP_DIV, FOP_SQRT,
    FOP_MADD, FOP_MSUB, FOP_NMSUB, FOP_NMADD,
    FOP_SGNJ, FOP_SGNJN, FOP_SGNJX, FOP_MIN, FOP_MAX,
    FOP_EQ, FOP_LT, FOP_LE, FOP_CLASS, FOP_MV_X_F, FOP_MV_F_X,
    FOP_CVT_S_D, FOP_CVT_D_S, FOP_CVT_F_I, FOP_CVT_I_F
};

static int is_nan32(uint32_t v) { return ((v & 0x7F800000u) == 0x7F800000u) && (v & 0x007FFFFFu); }
static int is_nan64(uint64_t v) { return ((v & 0x7FF0000000000000ull) == 0x7FF0000000000000ull) && (v & 0x000FFFFFFFFFFFFFull); }
static int is_snan32(uint32_t v) { return is_nan32(v) && !(v & 0x00400000u); }
static int is_snan64(uint64_t v) { return is_nan64(v) && !(v & 0x0008000000000000ull); }

static uint64_t classify64(uint64_t v)
{
    int sign = (v >> 63) & 1;
    uint64_t ex = (v >> 52) & 0x7FF, fr = v & 0x000FFFFFFFFFFFFFull;
    if (ex == 0x7FF) {
        if (fr == 0) return sign ? (1u << 0) : (1u << 7);
        return is_snan64(v) ? (1u << 8) : (1u << 9);
    }
    if (ex == 0) return fr ? (sign ? (1u << 2) : (1u << 5))
                           : (sign ? (1u << 3) : (1u << 4));
    return sign ? (1u << 1) : (1u << 6);
}

static uint64_t classify32(uint32_t v)
{
    int sign = (v >> 31) & 1;
    uint32_t ex = (v >> 23) & 0xFF, fr = v & 0x007FFFFFu;
    if (ex == 0xFF) {
        if (fr == 0) return sign ? (1u << 0) : (1u << 7);
        return is_snan32(v) ? (1u << 8) : (1u << 9);
    }
    if (ex == 0) return fr ? (sign ? (1u << 2) : (1u << 5))
                           : (sign ? (1u << 3) : (1u << 4));
    return sign ? (1u << 1) : (1u << 6);
}

//---------------------------------------------------------------------------
// the one entry point the test bench calls
//   returns the result bits; *flags gets the RISC-V flags, *is_int says the
//   answer goes into an integer register
//---------------------------------------------------------------------------
DPI_C uint64_t sf_op(int op, int fmt, int rm, int int_signed, int int_w,
                     uint64_t a, uint64_t b, uint64_t c, int *flags, int *is_int)
{
    uint64_t res = 0;
    *is_int = 0;
    begin(rm);

    if (fmt == 0) {   /* single */
        float32_t fa = unbox(a), fb = unbox(b), fc = unbox(c), fr;
        uint32_t ua = fa.v, ub = fb.v;
        switch (op) {
        case FOP_ADD:  fr = f32_add(fa, fb); res = box(fr.v); break;
        case FOP_SUB:  fr = f32_sub(fa, fb); res = box(fr.v); break;
        case FOP_MUL:  fr = f32_mul(fa, fb); res = box(fr.v); break;
        case FOP_DIV:  fr = f32_div(fa, fb); res = box(fr.v); break;
        case FOP_SQRT: fr = f32_sqrt(fa);    res = box(fr.v); break;
        case FOP_MADD: fr = f32_mulAdd(fa, fb, fc); res = box(fr.v); break;
        case FOP_MSUB: { float32_t n = fc; n.v ^= 0x80000000u;
                         fr = f32_mulAdd(fa, fb, n); res = box(fr.v); } break;
        case FOP_NMSUB:{ float32_t n = fa; n.v ^= 0x80000000u;
                         fr = f32_mulAdd(n, fb, fc); res = box(fr.v); } break;
        case FOP_NMADD:{ float32_t na = fa, nc = fc;
                         na.v ^= 0x80000000u; nc.v ^= 0x80000000u;
                         fr = f32_mulAdd(na, fb, nc); res = box(fr.v); } break;
        case FOP_SGNJ:  res = box((ua & 0x7FFFFFFFu) | (ub & 0x80000000u)); break;
        case FOP_SGNJN: res = box((ua & 0x7FFFFFFFu) | (~ub & 0x80000000u)); break;
        case FOP_SGNJX: res = box(ua ^ (ub & 0x80000000u)); break;
        case FOP_MIN: case FOP_MAX: {
            int an = is_nan32(ua), bn = is_nan32(ub);
            if (is_snan32(ua) || is_snan32(ub)) softfloat_exceptionFlags |= softfloat_flag_invalid;
            if (an && bn)      res = box(0x7FC00000u);
            else if (an)       res = box(ub);
            else if (bn)       res = box(ua);
            else {
                int lt;
                if ((ua & 0x7FFFFFFFu) == 0 && (ub & 0x7FFFFFFFu) == 0)
                    lt = (ua >> 31) & 1;                     /* -0 < +0 */
                else lt = f32_lt(fa, fb);
                res = box((op == FOP_MIN) ? (lt ? ua : ub) : (lt ? ub : ua));
            }
            break;
        }
        case FOP_EQ: res = f32_eq(fa, fb); *is_int = 1; break;
        case FOP_LT: res = f32_lt(fa, fb); *is_int = 1; break;
        case FOP_LE: res = f32_le(fa, fb); *is_int = 1; break;
        case FOP_CLASS: res = classify32(ua); *is_int = 1; break;
        case FOP_MV_X_F: res = (uint64_t)(int64_t)(int32_t)(uint32_t)a; *is_int = 1; break;
        case FOP_MV_F_X: res = box((uint32_t)a); break;
        /* fmt is the format of the source, so FCVT.D.S is on the single side */
        case FOP_CVT_D_S: { float64_t t = f32_to_f64(fa); res = t.v; } break;
        case FOP_CVT_F_I:
            if (int_w) res = box(int_signed ? i64_to_f32((int64_t)a).v : ui64_to_f32(a).v);
            else       res = box(int_signed ? i32_to_f32((int32_t)a).v : ui32_to_f32((uint32_t)a).v);
            break;
        case FOP_CVT_I_F:
            *is_int = 1;
            if (int_w) res = int_signed ? (uint64_t)f32_to_i64(fa, rm_of(rm), true)
                                        : f32_to_ui64(fa, rm_of(rm), true);
            else {
                uint64_t t = int_signed ? (uint64_t)(int64_t)f32_to_i32(fa, rm_of(rm), true)
                                        : (uint64_t)(int32_t)(uint32_t)f32_to_ui32(fa, rm_of(rm), true);
                res = t;
            }
            break;
        default: res = 0; break;
        }
    } else {          /* double */
        float64_t fa, fb, fc, fr;
        fa.v = a; fb.v = b; fc.v = c;
        switch (op) {
        case FOP_ADD:  fr = f64_add(fa, fb); res = fr.v; break;
        case FOP_SUB:  fr = f64_sub(fa, fb); res = fr.v; break;
        case FOP_MUL:  fr = f64_mul(fa, fb); res = fr.v; break;
        case FOP_DIV:  fr = f64_div(fa, fb); res = fr.v; break;
        case FOP_SQRT: fr = f64_sqrt(fa);    res = fr.v; break;
        case FOP_MADD: fr = f64_mulAdd(fa, fb, fc); res = fr.v; break;
        case FOP_MSUB: { float64_t n = fc; n.v ^= 0x8000000000000000ull;
                         fr = f64_mulAdd(fa, fb, n); res = fr.v; } break;
        case FOP_NMSUB:{ float64_t n = fa; n.v ^= 0x8000000000000000ull;
                         fr = f64_mulAdd(n, fb, fc); res = fr.v; } break;
        case FOP_NMADD:{ float64_t na = fa, nc = fc;
                         na.v ^= 0x8000000000000000ull; nc.v ^= 0x8000000000000000ull;
                         fr = f64_mulAdd(na, fb, nc); res = fr.v; } break;
        case FOP_SGNJ:  res = (a & ~0x8000000000000000ull) | (b & 0x8000000000000000ull); break;
        case FOP_SGNJN: res = (a & ~0x8000000000000000ull) | (~b & 0x8000000000000000ull); break;
        case FOP_SGNJX: res = a ^ (b & 0x8000000000000000ull); break;
        case FOP_MIN: case FOP_MAX: {
            int an = is_nan64(a), bn = is_nan64(b);
            if (is_snan64(a) || is_snan64(b)) softfloat_exceptionFlags |= softfloat_flag_invalid;
            if (an && bn)      res = 0x7FF8000000000000ull;
            else if (an)       res = b;
            else if (bn)       res = a;
            else {
                int lt;
                if ((a & ~0x8000000000000000ull) == 0 && (b & ~0x8000000000000000ull) == 0)
                    lt = (a >> 63) & 1;
                else lt = f64_lt(fa, fb);
                res = (op == FOP_MIN) ? (lt ? a : b) : (lt ? b : a);
            }
            break;
        }
        case FOP_EQ: res = f64_eq(fa, fb); *is_int = 1; break;
        case FOP_LT: res = f64_lt(fa, fb); *is_int = 1; break;
        case FOP_LE: res = f64_le(fa, fb); *is_int = 1; break;
        case FOP_CLASS: res = classify64(a); *is_int = 1; break;
        case FOP_MV_X_F: res = a; *is_int = 1; break;
        case FOP_MV_F_X: res = a; break;
        case FOP_CVT_S_D: { float32_t t = f64_to_f32(fa); res = box(t.v); } break;
        case FOP_CVT_F_I:
            if (int_w) res = int_signed ? i64_to_f64((int64_t)a).v : ui64_to_f64(a).v;
            else       res = int_signed ? i32_to_f64((int32_t)a).v : ui32_to_f64((uint32_t)a).v;
            break;
        case FOP_CVT_I_F:
            *is_int = 1;
            if (int_w) res = int_signed ? (uint64_t)f64_to_i64(fa, rm_of(rm), true)
                                        : f64_to_ui64(fa, rm_of(rm), true);
            else       res = int_signed ? (uint64_t)(int64_t)f64_to_i32(fa, rm_of(rm), true)
                                        : (uint64_t)(int32_t)(uint32_t)f64_to_ui32(fa, rm_of(rm), true);
            break;
        default: res = 0; break;
        }
    }

    *flags = flags_of();
    return res;
}
