//---------------------------------------------------------------------------
// MMU_TLB.sv
//
// Translation lookaside buffer (CPU_CORE_SPEC.md 6.2).
//
//   Fully associative and looked up combinationally, so a hit produces the
//   physical address in the same cycle the address is presented. One of
//   these sits on each side; they are not shared, because the two look up
//   different addresses in the same cycle.
//
//   The permission bits of the page table entry are kept as they were read
//   and are checked by the caller on every lookup, not when the entry is
//   filled: SUM, MXR and the privilege level change without anything being
//   invalidated, so a decision made at fill time would go stale.
//
//   A superpage is held as one entry with its level; the comparison then
//   only looks at the part of the virtual page number above that level.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module MMU_TLB
    #(
        parameter int ENTRIES = 16
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // lookup
        input  logic [26:0] vpn,
        input  logic [15:0] asid,
        output logic        hit,
        output logic [43:0] ppn,       // of the page, not of the address
        output logic [1:0]  level,     // 0 : 4K, 1 : 2M, 2 : 1G
        output logic [7:0]  perm,      // the low byte of the entry, V included

        // fill
        input  logic        fill_en,
        input  logic [26:0] fill_vpn,
        input  logic [15:0] fill_asid,
        input  logic [43:0] fill_ppn,
        input  logic [1:0]  fill_level,
        input  logic [7:0]  fill_perm,

        // SFENCE.VMA
        input  logic        inv_en,
        input  logic        inv_all_addr,  // rs1 was x0 : every address
        input  logic        inv_all_asid,  // rs2 was x0 : every ASID
        input  logic [26:0] inv_vpn,
        input  logic [15:0] inv_asid
    );

    localparam int IDX_BITS = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

    logic               e_valid [0:ENTRIES-1];
    logic [26:0]        e_vpn   [0:ENTRIES-1];
    logic [15:0]        e_asid  [0:ENTRIES-1];
    logic [43:0]        e_ppn   [0:ENTRIES-1];
    logic [1:0]         e_level [0:ENTRIES-1];
    logic [7:0]         e_perm  [0:ENTRIES-1];

    logic [IDX_BITS-1:0] victim;

    //-----------------------------------------------------------------
    // does this entry cover that virtual page number
    //-----------------------------------------------------------------
    function automatic logic vpn_match(input logic [26:0] a,
                                       input logic [26:0] b,
                                       input logic [1:0]  lv);
        begin
            case (lv)
                2'd2:    vpn_match = (a[26:18] == b[26:18]);   // 1G
                2'd1:    vpn_match = (a[26:9]  == b[26:9]);    // 2M
                default: vpn_match = (a == b);                 // 4K
            endcase
        end
    endfunction

    //-----------------------------------------------------------------
    // lookup
    //
    //   A global entry belongs to every address space, so its ASID is not
    //   compared. Counted downwards so that the lowest numbered match wins,
    //   which only matters if software left two entries for one page.
    //-----------------------------------------------------------------
    always @(*) begin
        hit   = 1'b0;
        ppn   = 44'd0;
        level = 2'd0;
        perm  = 8'd0;
        for (int i = ENTRIES-1; i >= 0; i--) begin
            if (e_valid[i] && vpn_match(e_vpn[i], vpn, e_level[i]) &&
                (e_perm[i][5] || (e_asid[i] == asid))) begin
                hit   = 1'b1;
                ppn   = e_ppn[i];
                level = e_level[i];
                perm  = e_perm[i];
            end
        end
    end

    //-----------------------------------------------------------------
    // fill and invalidate
    //-----------------------------------------------------------------
    logic inv_hit [0:ENTRIES-1];

    always @(*) begin
        for (int i = 0; i < ENTRIES; i++) begin
            // rs1 picks the address, rs2 the address space, and a global
            // entry is never picked by an address space
            inv_hit[i] = (inv_all_addr ||
                          vpn_match(e_vpn[i], inv_vpn, e_level[i]))
                      && (inv_all_asid ||
                          (!e_perm[i][5] && (e_asid[i] == inv_asid)));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            victim <= '0;
            for (int i = 0; i < ENTRIES; i++) begin
                e_valid[i] <= 1'b0;
                e_vpn[i]   <= 27'd0;
                e_asid[i]  <= 16'd0;
                e_ppn[i]   <= 44'd0;
                e_level[i] <= 2'd0;
                e_perm[i]  <= 8'd0;
            end
        end else begin
            if (inv_en) begin
                for (int i = 0; i < ENTRIES; i++)
                    if (inv_hit[i]) e_valid[i] <= 1'b0;
            end
            // An invalidate and a fill can arrive together: SFENCE.VMA
            // commits while a walk of the instruction side is still going
            // on. The invalidate wins, which is the safe way round -- the
            // entry that walk found may already be the old mapping.
            else if (fill_en) begin
                e_valid[victim] <= 1'b1;
                e_vpn  [victim] <= fill_vpn;
                e_asid [victim] <= fill_asid;
                e_ppn  [victim] <= fill_ppn;
                e_level[victim] <= fill_level;
                e_perm [victim] <= fill_perm;
                victim          <= victim + IDX_BITS'(1);
            end
        end
    end

endmodule : MMU_TLB
