//---------------------------------------------------------------------------
// CORE_LSU.sv
//
// Load / store unit : drives the data cache port and aligns the data
// (CPU_CORE_SPEC.md 5).
//
//   An access normally goes to the cache from EX, as soon as its address is
//   added up and before anything is known about it: the cache takes the
//   index from the virtual address and wants the physical tag one cycle
//   later, which is the cycle the instruction is in MR. MR then says whether
//   the request may go (e_go): the translation, the PMP, an exception, a
//   flush, and for a store or anything with a side effect, whether the
//   instruction in front of it can still trap. If not, the request is taken
//   back (d_req_cancel) and leaves no trace in the cache. A hit then answers
//   in the cycle the instruction reaches MA, so MA does not wait.
//
//   An access that did not go from EX (taken back, or the port was busy, or
//   the translation was not there yet) goes from MA, where nothing in front
//   of it can trap any more, and MA waits for it (m_*). That path also takes
//   fence.i, which flushes the data cache.
//
//   The cache answers in order. Up to three accesses are in flight: the one
//   MA waits for, the one of MR, and the one EX issued in the last cycle
//   whose fate is decided now. An answer always belongs to the instruction
//   in MA (an instruction in MR cannot be answered before the one in front
//   of it has been). A flush throws away MR, so the answers still to come
//   for it are dropped when they arrive.
//
//   The command comes from the decoder, so LR, SC and the atomic operations
//   of the A extension go through the same path as a load or a store; the
//   cache does the read modify write and the reservation.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_LSU
    #(
        parameter int PADDR_WIDTH = 40
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // from EX : the address has just been added up
        input  logic                    e_valid,
        input  logic [3:0]              e_cmd,         // command of the cache port
        input  logic [63:0]             e_addr,
        input  logic [1:0]              e_size,        // 0:byte 1:half 2:word 3:double
        input  logic [63:0]             e_wdata,
        output logic                    e_accept,      // taken by the cache this cycle
        // in the cycle after e_accept: let it go, with this physical address
        // (the translation EX made, held by MR), or take it back
        input  logic                    e_go,
        input  logic [63:0]             e_paddr,

        // from MA : an access that has not gone yet (takes precedence)
        input  logic                    m_valid,
        input  logic [3:0]              m_cmd,
        input  logic [63:0]             m_addr,
        input  logic [63:0]             m_paddr,
        input  logic [1:0]              m_size,
        input  logic [63:0]             m_wdata,
        output logic                    m_accept,

        // the answer, for the instruction in MA, aligned by its size
        input  logic [1:0]              r_size,
        input  logic                    r_signed,
        output logic                    resp_valid,
        output logic [63:0]             resp_data,
        output logic                    resp_error,

        // MA flushes the pipeline: what is still in flight belongs to the
        // instructions behind it
        input  logic                    flush,

        // nothing of this unit is in the cache or on its way there : the
        // page table walker may borrow the port
        output logic                    idle,

        // data cache port
        output logic                    d_req_valid,
        input  logic                    d_req_ready,
        output logic [PADDR_WIDTH-1:0]  d_req_addr,
        output logic [PADDR_WIDTH-1:0]  d_req_paddr,
        output logic [1:0]              d_req_size,
        output logic [3:0]              d_req_cmd,
        output logic [63:0]             d_req_wdata,
        output logic                    d_req_cancel,
        input  logic                    d_resp_valid,
        input  logic [63:0]             d_resp_data,
        input  logic                    d_resp_error
    );

    logic                   e_acc_q;     // EX's request was taken last cycle
    logic [PADDR_WIDTH-1:0] m_paddr_q;   // paddr of MA's request of last cycle
    logic [1:0]             os;          // in flight and let go, not answered
    logic [1:0]             drop;        // of those, the ones to throw away
    logic [1:0]             os_next;

    //-----------------------------------------------------------------
    // request: MA first, it is older and waits for it
    //-----------------------------------------------------------------
    assign d_req_valid = m_valid | e_valid;
    assign d_req_addr  = m_valid ? m_addr[PADDR_WIDTH-1:0]  : e_addr[PADDR_WIDTH-1:0];
    assign d_req_size  = m_valid ? m_size  : e_size;
    assign d_req_cmd   = m_valid ? m_cmd   : e_cmd;
    // the data of a store is placed in its lane by the cache
    assign d_req_wdata = m_valid ? m_wdata : e_wdata;

    assign m_accept = m_valid & d_req_ready;
    assign e_accept = e_valid & ~m_valid & d_req_ready;

    // the cache wants the tag in the cycle after the request was taken
    // (CPU_CACHE_SPEC.md 5.6), and a take back in the same cycle
    assign d_req_paddr  = e_acc_q ? e_paddr[PADDR_WIDTH-1:0] : m_paddr_q;
    assign d_req_cancel = e_acc_q & ~e_go;

    //-----------------------------------------------------------------
    // what is in flight
    //-----------------------------------------------------------------
    assign os_next = os + ((e_acc_q & e_go) ? 2'd1 : 2'd0)
                        + (m_accept ? 2'd1 : 2'd0)
                        - (d_resp_valid ? 2'd1 : 2'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_acc_q   <= 1'b0;
            m_paddr_q <= '0;
            os        <= 2'd0;
            drop      <= 2'd0;
        end else begin
            e_acc_q <= e_accept;
            if (m_accept) m_paddr_q <= m_paddr[PADDR_WIDTH-1:0];
            os <= os_next;
            // the answer of this cycle, if any, was MA's (a flush waits for
            // it), so everything still in flight after it is the flushed MR's
            if (flush)                            drop <= os_next;
            else if (d_resp_valid && drop != 0)   drop <= drop - 2'd1;
        end
    end

    assign idle = (os == 2'd0) & ~e_acc_q & ~d_req_valid;

    //-----------------------------------------------------------------
    // answer : right aligned by the cache already, only the sign extension
    // of the smaller sizes is left
    //-----------------------------------------------------------------
    logic [63:0] ext;

    always @(*) begin
        case (r_size)
            2'd0:    ext = r_signed ? {{56{d_resp_data[7]}},  d_resp_data[7:0]}
                                    : {56'd0, d_resp_data[7:0]};
            2'd1:    ext = r_signed ? {{48{d_resp_data[15]}}, d_resp_data[15:0]}
                                    : {48'd0, d_resp_data[15:0]};
            2'd2:    ext = r_signed ? {{32{d_resp_data[31]}}, d_resp_data[31:0]}
                                    : {32'd0, d_resp_data[31:0]};
            default: ext = d_resp_data;
        endcase
    end

    assign resp_valid = d_resp_valid & (drop == 2'd0);
    assign resp_data  = ext;
    assign resp_error = d_resp_error;

endmodule : CORE_LSU
