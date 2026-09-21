//---------------------------------------------------------------------------
// MMU_PTW.sv
//
// Sv39 page table walker (CPU_CORE_SPEC.md 6.2).
//
//   One walker serves both TLBs. It reads the table through the data cache,
//   so the page tables are cached and coherent with what the hart writes;
//   the arbitration for that port is done by CORE_MMU, which only lets the
//   walker start while the load store unit has nothing in flight and then
//   holds the port until the walk is over.
//
//   Sv39 has three levels. The walk starts at level 2 and either finds a
//   leaf (R or X set) or descends. A leaf at level 2 or 1 is a superpage
//   and its page number has to be aligned to the size of that page.
//
//   The walker does not look at the permissions and does not update the
//   accessed and dirty bits (6.2): it only decides whether the entry is
//   structurally valid. Everything else is checked at lookup time, so that
//   a change of privilege or of SUM or MXR takes effect without anything
//   being invalidated.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module MMU_PTW
    (
        input  logic        clk,
        input  logic        rst_n,

        // a walk is wanted for this page
        input  logic        req,
        input  logic [26:0] vpn,
        input  logic [63:0] satp,
        input  logic        kill,          // give up (a trap emptied the pipe)

        output logic        busy,
        output logic        done,          // one cycle; the outputs below hold
        output logic [1:0]  fault,         // 0 none, 1 access fault, 2 page fault
        output logic [43:0] ppn,
        output logic [1:0]  level,
        output logic [7:0]  perm,

        // the address of the entry that is being read, for the protection
        // check; the answer is expected in the same cycle
        output logic [63:0] pmp_addr,
        input  logic        pmp_fail,

        // data cache port (arbitrated by CORE_MMU)
        output logic        m_req_valid,
        input  logic        m_req_ready,
        output logic [63:0] m_req_addr,
        input  logic        m_resp_valid,
        input  logic [63:0] m_resp_data,
        input  logic        m_resp_error
    );

    localparam logic [1:0] FAULT_NONE = 2'd0;
    localparam logic [1:0] FAULT_ACC  = 2'd1;
    localparam logic [1:0] FAULT_PAGE = 2'd2;

    localparam logic [2:0] S_IDLE = 3'd0;
    localparam logic [2:0] S_REQ  = 3'd1;
    localparam logic [2:0] S_WAIT = 3'd2;
    localparam logic [2:0] S_DONE = 3'd3;

    logic [2:0]  state;
    logic [43:0] table_ppn;        // page number of the table being read
    logic [1:0]  lvl;
    logic [26:0] vpn_r;

    // the index into the table at this level
    logic [8:0] vpn_sel;
    always @(*) begin
        case (lvl)
            2'd2:    vpn_sel = vpn_r[26:18];
            2'd1:    vpn_sel = vpn_r[17:9];
            default: vpn_sel = vpn_r[8:0];
        endcase
    end

    assign m_req_addr  = {8'd0, table_ppn, 12'd0} | {52'd0, vpn_sel, 3'd0};
    assign pmp_addr    = m_req_addr;
    assign m_req_valid = (state == S_REQ) & ~pmp_fail;
    assign busy        = (state != S_IDLE);
    assign done        = (state == S_DONE);

    // the entry that came back
    logic [63:0] pte;
    logic [43:0] pte_ppn;
    logic        pte_v, pte_r, pte_w, pte_x, pte_leaf, pte_bad;

    assign pte      = m_resp_data;
    assign pte_ppn  = pte[53:10];
    assign pte_v    = pte[0];
    assign pte_r    = pte[1];
    assign pte_w    = pte[2];
    assign pte_x    = pte[3];
    assign pte_leaf = pte_r | pte_x;
    // W without R is reserved, and so is everything above bit 53 as long as
    // neither Svnapot nor Svpbmt is implemented
    assign pte_bad  = ~pte_v | (pte_w & ~pte_r) | (|pte[63:54]);

    // a superpage has to be aligned to its own size
    logic misaligned;
    always @(*) begin
        case (lvl)
            2'd2:    misaligned = |pte_ppn[17:0];
            2'd1:    misaligned = |pte_ppn[8:0];
            default: misaligned = 1'b0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            table_ppn <= 44'd0;
            lvl       <= 2'd0;
            vpn_r     <= 27'd0;
            fault     <= FAULT_NONE;
            ppn       <= 44'd0;
            level     <= 2'd0;
            perm      <= 8'd0;
        end else if (kill && (state != S_IDLE)) begin
            // The walk is thrown away. Nothing has been written anywhere, so
            // there is nothing to undo; the answer of a read that is still in
            // the cache is dropped by the state being S_IDLE.
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req) begin
                        table_ppn <= satp[43:0];
                        lvl       <= 2'd2;
                        vpn_r     <= vpn;
                        fault     <= FAULT_NONE;
                        state     <= S_REQ;
                    end
                end

                S_REQ: begin
                    if (pmp_fail) begin
                        fault <= FAULT_ACC;
                        state <= S_DONE;
                    end else if (m_req_ready) begin
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (m_resp_valid) begin
                        if (m_resp_error) begin
                            fault <= FAULT_ACC;
                            state <= S_DONE;
                        end else if (pte_bad) begin
                            fault <= FAULT_PAGE;
                            state <= S_DONE;
                        end else if (pte_leaf) begin
                            if (misaligned) begin
                                fault <= FAULT_PAGE;
                            end else begin
                                fault <= FAULT_NONE;
                                ppn   <= pte_ppn;
                                level <= lvl;
                                perm  <= pte[7:0];
                            end
                            state <= S_DONE;
                        end else if (lvl == 2'd0) begin
                            fault <= FAULT_PAGE;     // no leaf at the bottom
                            state <= S_DONE;
                        end else begin
                            table_ppn <= pte_ppn;
                            lvl       <= lvl - 2'd1;
                            state     <= S_REQ;
                        end
                    end
                end

                default: state <= S_IDLE;            // S_DONE lasts one cycle
            endcase
        end
    end

endmodule : MMU_PTW
