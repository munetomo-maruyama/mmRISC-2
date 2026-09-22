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
        input  logic [63:0] paddr,
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
    // the first and the last byte of the access, shifted right by two
    //-----------------------------------------------------------------
    logic [63:0] last_byte;
    logic [53:0] a_lo, a_hi;

    always @(*) begin
        case (size)
            2'd0:    last_byte = paddr;
            2'd1:    last_byte = paddr + 64'd1;
            2'd2:    last_byte = paddr + 64'd3;
            default: last_byte = paddr + 64'd7;
        endcase
    end

    assign a_lo = paddr[55:2];
    assign a_hi = last_byte[55:2];

    //-----------------------------------------------------------------
    // match, both ends against every entry
    //
    //   The NAPOT mask comes from the entry alone, so it is built once per
    //   entry and handed to both ends : the bits from the lowest zero of
    //   pmpaddr downwards are the ones inside the region, and an entry of
    //   all ones matches the whole address space.
    //-----------------------------------------------------------------
    function automatic logic match_one(input logic [53:0] a,
                                       input logic [53:0] this_a,
                                       input logic [53:0] prev_a,
                                       input logic [53:0] napot_mask,
                                       input logic [1:0]  mode);
        begin
            case (mode)
                A_TOR   : match_one = (a >= prev_a) && (a < this_a);
                A_NA4   : match_one = (a == this_a);
                A_NAPOT : match_one = ((a & ~napot_mask) == (this_a & ~napot_mask));
                default : match_one = 1'b0;      // A = 0 : OFF
            endcase
        end
    endfunction

    logic [N-1:0] m_lo, m_hi;

    always @(*) begin
        m_lo = '0;
        m_hi = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            logic [53:0] this_a, prev_a, napot_mask;
            logic [1:0]  mode;
            this_a = addr[64*i +: 54];
            prev_a = (i == 0) ? 54'd0 : addr[64*(i-1) +: 54];
            mode   = cfg[8*i+3 +: 2];
            napot_mask = this_a ^ (this_a + 54'd1);
            m_lo[i] = match_one(a_lo, this_a, prev_a, napot_mask, mode);
            m_hi[i] = match_one(a_hi, this_a, prev_a, napot_mask, mode);
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
