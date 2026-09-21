//---------------------------------------------------------------------------
// CORE_MMU.sv
//
// Address translation and protection (CPU_CORE_SPEC.md 6).
//
//   One of these sits between the pipeline and the two cache ports. Each
//   side hands it a virtual address and gets back a physical one, or a
//   fault, or "not this cycle" while the page table is being walked.
//
//   The translation is combinational when the entry is in the TLB, so the
//   physical address is ready in the same cycle the request is made. The
//   cache is indexed with the virtual address and tagged with the physical
//   one (CPU_CACHE_SPEC.md 5.6); because the index and the offset together
//   stay inside a page, the two agree on those bits and nothing in the cache
//   has to change.
//
//   This step implements the protection only: `satp` is still ignored and
//   every address translates to itself. The TLB and the page table walker
//   come next and will fit in without the pipeline noticing.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_MMU
    #(
        parameter int PMP_ENTRIES  = 16
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // state of the privilege architecture
        input  logic [1:0]  priv,
        input  logic [63:0] satp,
        input  logic        mstatus_sum,
        input  logic        mstatus_mxr,
        input  logic        mstatus_mprv,
        input  logic [1:0]  mstatus_mpp,

        input  logic [8*(PMP_ENTRIES > 0 ? PMP_ENTRIES : 1)-1:0]  pmpcfg,
        input  logic [64*(PMP_ENTRIES > 0 ? PMP_ENTRIES : 1)-1:0] pmpaddr,

        // instruction side
        input  logic        i_req,          // a fetch would be issued now
        input  logic [63:0] i_vaddr,
        output logic        i_ready,        // the answer below is valid
        output logic [63:0] i_paddr,
        output logic [1:0]  i_fault,        // 0 none, 1 access fault, 2 page fault

        // data side
        input  logic        d_req,
        input  logic [63:0] d_vaddr,
        input  logic [1:0]  d_size,
        input  logic        d_is_load,
        input  logic        d_is_store,
        output logic        d_ready,
        output logic [63:0] d_paddr,
        output logic [1:0]  d_fault,

        // SFENCE.VMA at the commit point
        input  logic        sfence_valid,
        input  logic [63:0] sfence_vaddr,   // 0 : every address
        input  logic [63:0] sfence_asid     // 0 : every ASID
    );

    localparam logic [1:0] PRIV_M    = 2'b11;
    localparam logic [1:0] FAULT_NONE= 2'd0;
    localparam logic [1:0] FAULT_ACC = 2'd1;
    localparam logic [1:0] FAULT_PAGE= 2'd2;

    //-----------------------------------------------------------------
    // the level an access is checked at
    //
    //   MPRV makes the data side behave as if it ran at MPP. It is cleared
    //   whenever a return leaves machine mode, so it can only ever be set
    //   while the hart is in M.
    //-----------------------------------------------------------------
    logic [1:0] d_priv;
    assign d_priv = mstatus_mprv ? mstatus_mpp : priv;

    //-----------------------------------------------------------------
    // translation : nothing to do yet
    //-----------------------------------------------------------------
    assign i_paddr = i_vaddr;
    assign d_paddr = d_vaddr;
    assign i_ready = 1'b1;
    assign d_ready = 1'b1;

    //-----------------------------------------------------------------
    // protection
    //-----------------------------------------------------------------
    logic i_pmp_fail, d_pmp_fail;

    MMU_PMP #(.ENTRIES(PMP_ENTRIES)) u_pmp_i
        (
            .cfg      (pmpcfg),
            .addr     (pmpaddr),
            .priv     (priv),
            .paddr    (i_paddr),
            .size     (2'd3),            // a fetch brings a whole double word
            .is_read  (1'b0),
            .is_write (1'b0),
            .is_exec  (1'b1),
            .fail     (i_pmp_fail)
        );

    MMU_PMP #(.ENTRIES(PMP_ENTRIES)) u_pmp_d
        (
            .cfg      (pmpcfg),
            .addr     (pmpaddr),
            .priv     (d_priv),
            .paddr    (d_paddr),
            .size     (d_size),
            .is_read  (d_is_load),
            .is_write (d_is_store),
            .is_exec  (1'b0),
            .fail     (d_pmp_fail)
        );

    assign i_fault = (i_req & i_pmp_fail) ? FAULT_ACC : FAULT_NONE;
    assign d_fault = (d_req & d_pmp_fail) ? FAULT_ACC : FAULT_NONE;

    // not used until the page table walker arrives
    logic unused;
    assign unused = &{1'b0, clk, rst_n, satp, mstatus_sum, mstatus_mxr,
                      sfence_valid, sfence_vaddr, sfence_asid,
                      FAULT_PAGE, PRIV_M};

endmodule : CORE_MMU
