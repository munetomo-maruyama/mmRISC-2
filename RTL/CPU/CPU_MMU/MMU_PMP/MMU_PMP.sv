//---------------------------------------------------------------------------
// MMU_PMP.sv
//
// Physical memory protection (CPU_CORE_SPEC.md 6.4).
//
//   Purely combinational. The physical address of one access goes in, and
//   out comes whether the level that issued it is allowed to do so.
//
//   The entry with the lowest number that matches decides, whether or not it
//   grants the access; the ones behind it are not looked at. An address that
//   no entry matches is open to machine mode and closed to everything else,
//   which is why firmware that ever leaves machine mode has to program at
//   least one entry.
//
//   pmpaddr holds the address shifted right by two, so the finest region is
//   four bytes. An access wider than one byte is checked at its first and at
//   its last byte and the two have to land in the same entry: a region that
//   covers only a part of the access denies all of it.
//
//   Every entry is matched at once, for both ends of the access, and the
//   lowest match is picked out as a one hot vector. Two of those vectors
//   being equal is the same question as two indices being equal, and it is
//   asked without ever building the index: this check is on the address
//   path of the execute stage, so a chain as deep as the table would cost
//   real cycle time.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module MMU_PMP
    #(
        parameter int ENTRIES = 8           // 0 removes the check entirely
    )
    (
        input  logic [8*(ENTRIES > 0 ? ENTRIES : 1)-1:0]  cfg,
        input  logic [64*(ENTRIES > 0 ? ENTRIES : 1)-1:0] addr,

        input  logic [1:0]  priv,           // privilege of the access (MPRV
                                            // already taken into account)
        input  logic [63:0] paddr,          // any byte of the block (see below)
        input  logic [1:0]  size,           // 0 byte, 1 half, 2 word, 3 double
        input  logic        is_read,
        input  logic        is_write,
        input  logic        is_exec,
        output logic        fail
    );

    localparam int         N       = (ENTRIES > 0) ? ENTRIES : 1;
    localparam logic [1:0] PRIV_M  = 2'b11;
    localparam logic [1:0] A_TOR   = 2'd1;
    localparam logic [1:0] A_NA4   = 2'd2;
    localparam logic [1:0] A_NAPOT = 2'd3;

    //-----------------------------------------------------------------
    // the access, as word addresses (the byte address shifted right by two)
    //
    //   What is checked is the naturally aligned block of 2^size bytes that
    //   holds paddr. For every access that is the access itself: the data
    //   side never lets a misaligned one reach here (it traps as misaligned
    //   first) and the walker reads aligned double words. The fetch side is
    //   the one that relies on it, since after a predicted branch its
    //   address can point into the middle of the double word it brings.
    //
    //   A block of one, two or four bytes is one word, a block of eight is
    //   two, and so the two ends differ in bit 0 of the word address at
    //   most. Nothing has to be added to find the last byte, and the bits
    //   above bit 0 are the same for both ends, so every comparison against
    //   them is made once and shared.
    //-----------------------------------------------------------------
    logic [52:0] a_up;              // bits 53:1 of the word address, both ends
    logic        lo0, hi0;          // bit 0 of the word address at each end

    assign a_up = paddr[55:3];
    assign lo0  = paddr[2] & (size != 2'd3);
    assign hi0  = paddr[2] | (size == 2'd3);

    //-----------------------------------------------------------------
    // compare, once per entry
    //
    //   below(x) : x < pmpaddr, for either end. The bits above bit 0 decide
    //              unless they are equal, and then bit 0 does.
    //   TOR      : pmpaddr[i-1] <= x < pmpaddr[i]. The lower bound is the
    //              upper one of the entry before, already worked out.
    //   NA4      : x == pmpaddr.
    //   NAPOT    : the bits above the region agree. The mask comes from
    //              the entry alone: the bits from the lowest zero of
    //              pmpaddr downwards are the ones inside the region, and
    //              an entry of all ones matches the whole address space.
    //              Its bit 0 is always set (the smallest region is eight
    //              bytes), so both ends give the same answer.
    //-----------------------------------------------------------------
    function automatic logic below(input logic up_lt, input logic up_eq,
                                   input logic x0,    input logic t0);
        below = up_lt | (up_eq & ~x0 & t0);
    endfunction

    logic [N-1:0] up_lt, up_eq, napot;
    logic [N-1:0] lt_lo, lt_hi, eq_lo, eq_hi;

    always @(*) begin
        for (int i = 0; i < N; i++) begin
            logic [53:0] this_a, napot_mask;
            this_a     = addr[64*i +: 54];
            napot_mask = this_a ^ (this_a + 54'd1);
            up_lt[i] = (a_up < this_a[53:1]);
            up_eq[i] = (a_up == this_a[53:1]);
            napot[i] = ((a_up & ~napot_mask[53:1]) == (this_a[53:1] & ~napot_mask[53:1]));
            lt_lo[i] = below(up_lt[i], up_eq[i], lo0, this_a[0]);
            lt_hi[i] = below(up_lt[i], up_eq[i], hi0, this_a[0]);
            eq_lo[i] = up_eq[i] & (lo0 == this_a[0]);
            eq_hi[i] = up_eq[i] & (hi0 == this_a[0]);
        end
    end

    logic [N-1:0] m_lo, m_hi;

    always @(*) begin
        m_lo = '0;
        m_hi = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            logic ge_lo, ge_hi;
            ge_lo = (i == 0) ? 1'b1 : ~lt_lo[(i+N-1)%N];
            ge_hi = (i == 0) ? 1'b1 : ~lt_hi[(i+N-1)%N];
            case (cfg[8*i+3 +: 2])
                A_TOR   : begin m_lo[i] = ge_lo & lt_lo[i]; m_hi[i] = ge_hi & lt_hi[i]; end
                A_NA4   : begin m_lo[i] = eq_lo[i];         m_hi[i] = eq_hi[i];         end
                A_NAPOT : begin m_lo[i] = napot[i];         m_hi[i] = napot[i];         end
                default : begin m_lo[i] = 1'b0;             m_hi[i] = 1'b0;             end   // A = 0 : OFF
            endcase
        end
    end

    //-----------------------------------------------------------------
    // the lowest match at each end
    //-----------------------------------------------------------------
    logic [N-1:0] sel_lo, sel_hi;
    logic         hit_lo, hit_hi;
    logic [7:0]   win_cfg;
    logic         perm_ok;

    assign sel_lo = m_lo & (~m_lo + N'(1));
    assign sel_hi = m_hi & (~m_hi + N'(1));
    assign hit_lo = |m_lo;
    assign hit_hi = |m_hi;

    always @(*) begin
        win_cfg = 8'd0;
        for (int i = 0; i < ENTRIES; i++)
            win_cfg |= {8{sel_lo[i]}} & cfg[8*i +: 8];
    end

    always @(*) begin
        // machine mode ignores an entry that is not locked
        perm_ok = ((priv == PRIV_M) && !win_cfg[7])
                || (!(is_read  && !win_cfg[0]) &&
                    !(is_write && !win_cfg[1]) &&
                    !(is_exec  && !win_cfg[2]));

        // one end matching and the other not leaves one select at zero and
        // the other not, so "half in, half out" is the same comparison as
        // "across two regions" and does not need a test of its own
        if (ENTRIES == 0)                  fail = 1'b0;
        else if (!hit_lo && !hit_hi)       fail = (priv != PRIV_M);
        else if (sel_lo != sel_hi)         fail = 1'b1;   // not one region
        else                               fail = ~perm_ok;
    end

endmodule : MMU_PMP
