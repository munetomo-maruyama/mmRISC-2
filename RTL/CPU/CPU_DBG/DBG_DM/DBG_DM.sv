//---------------------------------------------------------------------------
// DBG_DM.sv
//
// RISC-V Debug Module (Debug Spec 1.0, chapter 3)
//
//   - 1 hart (hartsel 1 bit implemented, hartsel=1 is nonexistent), hasel=0
//   - Abstract commands: Access Register (cmdtype 0), Access Memory (cmdtype 2)
//     datacount=4, progbufsize=0, abstractauto.autoexecdata[3:0]
//   - System Bus Access: sbversion 1, sbasize 40, 8/16/32/64-bit
//   - Authentication (authdata compared with auth_key when auth_en=1)
//   - hasresethaltreq, hartreset, ndmreset/ndmresetpending
//
// Reset: rst_n (debug power-on reset) and dmactive=0 only. System resets do
// not reset the DM.
//
// Requests to the hart register interface and to the bus master are tracked
// by "in-flight" flags that are not cleared by dmactive=0, so that a request
// in progress is always matched with its own response. If the hart or the
// system bus is reset while a request is in flight, the request fails
// (cmderr=4 / cmderr=5 / sberror=1).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_DM
    #(
        parameter int ADDR_WIDTH = 40
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,          // debug POR (synchronized)

        // DMI
        input  logic                  dmi_req,        // pulse
        input  logic                  dmi_wr,
        input  logic [6:0]            dmi_addr,
        input  logic [31:0]           dmi_wdata,
        output logic                  dmi_ack,        // pulse
        output logic [31:0]           dmi_rdata,
        output logic                  dmi_err,

        // authentication (synchronized)
        input  logic                  auth_en,
        input  logic [31:0]           auth_key,

        // hart run control
        output logic                  hart_haltreq,
        output logic                  hart_resumereq, // pulse
        output logic                  hart_resethaltreq,
        output logic                  hart_hartreset,
        input  logic                  hart_halted,
        input  logic                  hart_running,
        input  logic                  hart_resumed,   // pulse
        input  logic                  hart_in_reset,

        // hart register access
        output logic                  reg_req,        // pulse
        output logic                  reg_wr,
        output logic [15:0]           reg_regno,
        output logic                  reg_size64,
        output logic [63:0]           reg_wdata,
        input  logic                  reg_ack,        // pulse
        input  logic [63:0]           reg_rdata,
        input  logic                  reg_err,

        // bus master
        output logic                  bm_req,         // pulse
        output logic                  bm_wr,
        output logic [ADDR_WIDTH-1:0] bm_addr,
        output logic [1:0]            bm_size,
        output logic [63:0]           bm_wdata,
        input  logic                  bm_ack,         // pulse
        input  logic [63:0]           bm_rdata,
        input  logic [2:0]            bm_err,
        input  logic                  bus_in_reset,   // synchronized

        // system reset
        output logic                  ndmreset,
        input  logic                  sys_in_reset,   // synchronized

        // status
        output logic                  dmactive_o,
        output logic                  authenticated_o
    );

    //-----------------------------------------------------------------
    // DMI addresses
    //-----------------------------------------------------------------
    localparam logic [6:0] A_DATA0        = 7'h04;
    localparam logic [6:0] A_DATA3        = 7'h07;
    localparam logic [6:0] A_DMCONTROL    = 7'h10;
    localparam logic [6:0] A_DMSTATUS     = 7'h11;
    localparam logic [6:0] A_HARTINFO     = 7'h12;
    localparam logic [6:0] A_HALTSUM1     = 7'h13;
    localparam logic [6:0] A_ABSTRACTCS   = 7'h16;
    localparam logic [6:0] A_COMMAND      = 7'h17;
    localparam logic [6:0] A_ABSTRACTAUTO = 7'h18;
    localparam logic [6:0] A_AUTHDATA     = 7'h30;
    localparam logic [6:0] A_SBCS         = 7'h38;
    localparam logic [6:0] A_SBADDRESS0   = 7'h39;
    localparam logic [6:0] A_SBADDRESS1   = 7'h3A;
    localparam logic [6:0] A_SBDATA0      = 7'h3C;
    localparam logic [6:0] A_SBDATA1      = 7'h3D;
    localparam logic [6:0] A_HALTSUM0     = 7'h40;

    localparam logic [2:0] CMDERR_NONE    = 3'd0;
    localparam logic [2:0] CMDERR_BUSY    = 3'd1;
    localparam logic [2:0] CMDERR_NOTSUP  = 3'd2;
    localparam logic [2:0] CMDERR_EXCEPT  = 3'd3;
    localparam logic [2:0] CMDERR_HALTRES = 3'd4;
    localparam logic [2:0] CMDERR_BUS     = 3'd5;

    //-----------------------------------------------------------------
    // State
    //-----------------------------------------------------------------
    logic        dmactive;
    logic        auth_ok;
    logic        authenticated;

    // dmcontrol
    logic        haltreq_r;
    logic        hartreset_r;
    logic        hartsel_r;          // hartsello[0]
    logic        ndmreset_r;
    logic        resethaltreq_r;

    // hart status
    logic        havereset_r;
    logic        resumeack_r;

    // abstract commands
    logic [31:0] data_r [0:3];
    logic [31:0] command_r;
    logic [3:0]  autoexec_r;
    logic [2:0]  cmderr_r;

    typedef enum logic [2:0] {
        AB_IDLE, AB_DECODE, AB_REG_ISSUE, AB_REG_WAIT, AB_MEM_PEND, AB_MEM_WAIT
    } ab_state_t;
    ab_state_t   ab_state;
    logic        ab_busy;

    // system bus access
    logic        sbbusyerror_r;
    logic        sbreadonaddr_r;
    logic [2:0]  sbaccess_r;
    logic        sbautoincrement_r;
    logic        sbreadondata_r;
    logic [2:0]  sberror_r;
    logic [ADDR_WIDTH-1:0] sbaddress_r;
    logic [31:0] sbdata0_r, sbdata1_r;
    logic        sb_pend;           // waiting for the bus master
    logic        sb_wait;           // issued to the bus master
    logic        sb_wr;
    logic        sbbusy;

    // in-flight trackers (not cleared by dmactive)
    logic        reg_busy;
    logic        bm_busy;
    logic        bm_owner_sba;

    assign authenticated   = ~auth_en | auth_ok;
    assign ab_busy         = (ab_state != AB_IDLE);
    assign sbbusy          = sb_pend | sb_wait;
    assign dmactive_o      = dmactive;
    assign authenticated_o = authenticated;

    assign hart_haltreq      = haltreq_r;
    assign hart_resethaltreq = resethaltreq_r;
    assign hart_hartreset    = hartreset_r;
    assign ndmreset          = ndmreset_r;

    //-----------------------------------------------------------------
    // Helpers
    //-----------------------------------------------------------------
    function automatic logic [3:0] size_bytes(input logic [2:0] s);
        case (s)
            3'd0:    return 4'd1;
            3'd1:    return 4'd2;
            3'd2:    return 4'd4;
            default: return 4'd8;
        endcase
    endfunction

    function automatic logic aligned(input logic [2:0] a, input logic [2:0] s);
        case (s)
            3'd0:    return 1'b1;
            3'd1:    return (a[0]   == 1'b0);
            3'd2:    return (a[1:0] == 2'b00);
            default: return (a[2:0] == 3'b000);
        endcase
    endfunction

    // selected hart status
    logic sel_exist;
    logic st_halted, st_running, st_unavail, st_havereset, st_resumeack;
    assign sel_exist    = (hartsel_r == 1'b0);
    assign st_unavail   = sel_exist &  hart_in_reset;
    assign st_halted    = sel_exist & ~hart_in_reset & hart_halted;
    assign st_running   = sel_exist & ~hart_in_reset & hart_running;
    assign st_havereset = sel_exist & havereset_r;
    assign st_resumeack = sel_exist & resumeack_r;

    logic [1:0] data_idx;
    assign data_idx = 2'(dmi_addr - A_DATA0);

    //-----------------------------------------------------------------
    // Read multiplexer
    //-----------------------------------------------------------------
    logic [31:0] rd;
    always_comb begin
        rd = 32'd0;
        if (!authenticated) begin
            case (dmi_addr)
                A_DMCONTROL: rd = {31'd0, dmactive};
                A_DMSTATUS:  rd = {24'd0, 1'b0, 1'b0, 1'b0, 1'b0, 4'd3};  // version only
                default:     rd = 32'd0;
            endcase
        end else begin
            case (dmi_addr)
                A_DMCONTROL:
                    rd = {1'b0, 1'b0, hartreset_r, 1'b0, 1'b0, 1'b0,
                          9'd0, hartsel_r, 10'd0,
                          1'b0, 1'b0, 1'b0, 1'b0, ndmreset_r, dmactive};
                A_DMSTATUS:
                    rd = {7'd0,
                          ndmreset_r | sys_in_reset,          // 24 ndmresetpending
                          1'b0,                               // 23 stickyunavail
                          1'b0,                               // 22 impebreak
                          2'b00,
                          st_havereset, st_havereset,         // 19 all/any havereset
                          st_resumeack, st_resumeack,         // 17 all/any resumeack
                          ~sel_exist,   ~sel_exist,           // 15 all/any nonexistent
                          st_unavail,   st_unavail,           // 13 all/any unavail
                          st_running,   st_running,           // 11 all/any running
                          st_halted,    st_halted,            //  9 all/any halted
                          1'b1,                               //  7 authenticated
                          1'b0,                               //  6 authbusy
                          1'b1,                               //  5 hasresethaltreq
                          1'b0,                               //  4 confstrptrvalid
                          4'd3};                              //  version 1.0
                A_HARTINFO:     rd = 32'd0;
                A_HALTSUM1:     rd = {31'd0, hart_halted & ~hart_in_reset};
                A_HALTSUM0:     rd = {31'd0, hart_halted & ~hart_in_reset};
                A_ABSTRACTCS:   rd = {3'd0, 5'd0, 11'd0, ab_busy, 1'b0, cmderr_r, 4'd0, 4'd4};
                A_ABSTRACTAUTO: rd = {16'd0, 4'd0, 8'd0, autoexec_r};
                A_SBCS:         rd = {3'd1, 6'd0, sbbusyerror_r, sbbusy, sbreadonaddr_r,
                                      sbaccess_r, sbautoincrement_r, sbreadondata_r,
                                      sberror_r, 7'(ADDR_WIDTH), 5'b01111};
                A_SBADDRESS0:   rd = sbaddress_r[31:0];
                A_SBADDRESS1:   rd = 32'(sbaddress_r[ADDR_WIDTH-1:32]);
                A_SBDATA0:      rd = sbdata0_r;
                A_SBDATA1:      rd = sbdata1_r;
                default: begin
                    if (dmi_addr >= A_DATA0 && dmi_addr <= A_DATA3)
                        rd = data_r[data_idx];
                    else
                        rd = 32'd0;
                end
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Access decode for the current DMI request
    //-----------------------------------------------------------------
    logic acc;          // authenticated and active
    assign acc = dmi_req & authenticated & dmactive;


    logic is_data;
    assign is_data = (dmi_addr >= A_DATA0) && (dmi_addr <= A_DATA3);

    // abstract command field aliases
    logic [7:0]  c_type;
    logic [2:0]  c_size;
    logic        c_postinc;
    logic        c_postexec;
    logic        c_transfer;
    logic        c_write;
    logic [15:0] c_regno;
    logic        c_bit23;
    assign c_type     = command_r[31:24];
    assign c_bit23    = command_r[23];
    assign c_size     = command_r[22:20];
    assign c_postinc  = command_r[19];
    assign c_postexec = command_r[18];
    assign c_transfer = command_r[17];
    assign c_write    = command_r[16];
    assign c_regno    = command_r[15:0];

    logic [63:0] arg0, arg1;
    assign arg0 = {data_r[1], data_r[0]};
    assign arg1 = {data_r[3], data_r[2]};

    //-----------------------------------------------------------------
    // Main sequential logic
    //-----------------------------------------------------------------
    // Request flags evaluated within the current clock cycle (blocking
    // assignments inside the sequential process, never used as registers)
    logic        start_cmd;     // start abstract command
    logic        start_sba_rd;
    logic        start_sba_wr;

    /* verilator lint_off BLKSEQ */

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmi_ack           <= 1'b0;
            dmi_rdata         <= 32'd0;
            dmi_err           <= 1'b0;
            dmactive          <= 1'b0;
            auth_ok           <= 1'b0;
            haltreq_r         <= 1'b0;
            hartreset_r       <= 1'b0;
            hartsel_r         <= 1'b0;
            ndmreset_r        <= 1'b0;
            resethaltreq_r    <= 1'b0;
            havereset_r       <= 1'b1;
            resumeack_r       <= 1'b0;
            hart_resumereq    <= 1'b0;
            for (int i = 0; i < 4; i++) data_r[i] <= 32'd0;
            command_r         <= 32'd0;
            autoexec_r        <= 4'd0;
            cmderr_r          <= 3'd0;
            ab_state          <= AB_IDLE;
            sbbusyerror_r     <= 1'b0;
            sbreadonaddr_r    <= 1'b0;
            sbaccess_r        <= 3'd2;
            sbautoincrement_r <= 1'b0;
            sbreadondata_r    <= 1'b0;
            sberror_r         <= 3'd0;
            sbaddress_r       <= '0;
            sbdata0_r         <= 32'd0;
            sbdata1_r         <= 32'd0;
            sb_pend           <= 1'b0;
            sb_wait           <= 1'b0;
            sb_wr             <= 1'b0;
            reg_busy          <= 1'b0;
            reg_req           <= 1'b0;
            reg_wr            <= 1'b0;
            reg_regno         <= 16'd0;
            reg_size64        <= 1'b0;
            reg_wdata         <= 64'd0;
            bm_busy           <= 1'b0;
            bm_owner_sba      <= 1'b0;
            bm_req            <= 1'b0;
            bm_wr             <= 1'b0;
            bm_addr           <= '0;
            bm_size           <= 2'd0;
            bm_wdata          <= 64'd0;
        end else begin
            dmi_ack        <= 1'b0;
            hart_resumereq <= 1'b0;
            reg_req        <= 1'b0;
            bm_req         <= 1'b0;

            start_cmd    = 1'b0;
            start_sba_rd = 1'b0;
            start_sba_wr = 1'b0;

            //---------------------------------------------------------
            // hart status tracking (independent of dmactive)
            //---------------------------------------------------------
            if (hart_in_reset) havereset_r <= 1'b1;
            if (hart_resumed)  resumeack_r <= 1'b1;

            //---------------------------------------------------------
            // DMI access
            //---------------------------------------------------------
            if (dmi_req) begin
                dmi_ack   <= 1'b1;
                dmi_rdata <= rd;
                dmi_err   <= 1'b0;

                // dmcontrol.dmactive is always writable
                if (dmi_wr && dmi_addr == A_DMCONTROL && (!dmactive || !authenticated || !dmi_wdata[0]))
                    dmactive <= dmi_wdata[0];

                // authdata is accessible without authentication
                if (dmi_wr && dmi_addr == A_AUTHDATA && dmactive)
                    auth_ok <= (dmi_wdata == auth_key);
            end

            if (acc) begin
                if (is_data) begin
                    //-------------------------------------------------
                    // data0-3
                    //-------------------------------------------------
                    if (ab_busy) begin
                        if (cmderr_r == CMDERR_NONE) cmderr_r <= CMDERR_BUSY;
                    end else begin
                        if (dmi_wr) data_r[data_idx] <= dmi_wdata;
                        if (autoexec_r[data_idx] && cmderr_r == CMDERR_NONE)
                            start_cmd = 1'b1;
                    end
                end else begin
                    case (dmi_addr)
                        //---------------------------------------------
                        A_DMCONTROL: if (dmi_wr && dmi_wdata[0]) begin
                            hartsel_r  <= dmi_wdata[16];
                            ndmreset_r <= dmi_wdata[1];
                            if (dmi_wdata[25:16] == 10'd0 && dmi_wdata[15:6] == 10'd0) begin
                                haltreq_r   <= dmi_wdata[31];
                                hartreset_r <= dmi_wdata[29];
                                if (dmi_wdata[30] && !dmi_wdata[31] && st_halted) begin
                                    hart_resumereq <= 1'b1;
                                    resumeack_r    <= 1'b0;
                                end
                                if (dmi_wdata[28] && !hart_in_reset)
                                    havereset_r <= 1'b0;
                                if (dmi_wdata[3])
                                    resethaltreq_r <= 1'b1;
                                else if (dmi_wdata[2])
                                    resethaltreq_r <= 1'b0;
                            end
                        end
                        //---------------------------------------------
                        A_ABSTRACTCS: if (dmi_wr) begin
                            if (ab_busy) begin
                                if (cmderr_r == CMDERR_NONE) cmderr_r <= CMDERR_BUSY;
                            end else begin
                                cmderr_r <= cmderr_r & ~dmi_wdata[10:8];
                            end
                        end
                        //---------------------------------------------
                        A_COMMAND: if (dmi_wr) begin
                            if (ab_busy) begin
                                if (cmderr_r == CMDERR_NONE) cmderr_r <= CMDERR_BUSY;
                            end else if (cmderr_r == CMDERR_NONE) begin
                                command_r <= dmi_wdata;
                                start_cmd = 1'b1;
                            end
                        end
                        //---------------------------------------------
                        A_ABSTRACTAUTO: if (dmi_wr) begin
                            if (ab_busy) begin
                                if (cmderr_r == CMDERR_NONE) cmderr_r <= CMDERR_BUSY;
                            end else begin
                                autoexec_r <= dmi_wdata[3:0];
                            end
                        end
                        //---------------------------------------------
                        A_SBCS: if (dmi_wr) begin
                            if (dmi_wdata[22]) sbbusyerror_r <= 1'b0;
                            sbreadonaddr_r    <= dmi_wdata[20];
                            sbaccess_r        <= dmi_wdata[19:17];
                            sbautoincrement_r <= dmi_wdata[16];
                            sbreadondata_r    <= dmi_wdata[15];
                            sberror_r         <= sberror_r & ~dmi_wdata[14:12];
                        end
                        //---------------------------------------------
                        A_SBADDRESS0: if (dmi_wr) begin
                            if (sbbusy) begin
                                sbbusyerror_r <= 1'b1;
                            end else begin
                                sbaddress_r[31:0] <= dmi_wdata;
                                if (sbreadonaddr_r && sberror_r == 3'd0 && !sbbusyerror_r)
                                    start_sba_rd = 1'b1;
                            end
                        end
                        //---------------------------------------------
                        A_SBADDRESS1: if (dmi_wr) begin
                            if (sbbusy)
                                sbbusyerror_r <= 1'b1;
                            else
                                sbaddress_r[ADDR_WIDTH-1:32] <= dmi_wdata[ADDR_WIDTH-33:0];
                        end
                        //---------------------------------------------
                        A_SBDATA0: begin
                            if (sbbusy) begin
                                sbbusyerror_r <= 1'b1;
                            end else if (dmi_wr) begin
                                sbdata0_r <= dmi_wdata;
                                if (sberror_r == 3'd0 && !sbbusyerror_r)
                                    start_sba_wr = 1'b1;
                            end else begin
                                if (sbreadondata_r && sberror_r == 3'd0 && !sbbusyerror_r)
                                    start_sba_rd = 1'b1;
                            end
                        end
                        //---------------------------------------------
                        A_SBDATA1: if (dmi_wr) begin
                            if (sbbusy)
                                sbbusyerror_r <= 1'b1;
                            else
                                sbdata1_r <= dmi_wdata;
                        end
                        default: ;
                    endcase
                end
            end

            //---------------------------------------------------------
            // System bus access start
            //---------------------------------------------------------
            if (start_sba_rd || start_sba_wr) begin
                if (sbaccess_r > 3'd3) begin
                    sberror_r <= 3'd4;
                end else if (!aligned(start_sba_wr ? sbaddress_r[2:0]
                                                   : (dmi_addr == A_SBADDRESS0 ? dmi_wdata[2:0]
                                                                               : sbaddress_r[2:0]),
                                      sbaccess_r)) begin
                    sberror_r <= 3'd3;
                end else begin
                    sb_pend <= 1'b1;
                    sb_wr   <= start_sba_wr;
                end
            end

            //---------------------------------------------------------
            // Abstract command
            //---------------------------------------------------------
            if (start_cmd)
                ab_state <= AB_DECODE;

            case (ab_state)
                AB_DECODE: begin
                    ab_state <= AB_IDLE;
                    if (c_type == 8'd0) begin
                        // Access Register
                        if (c_bit23 || c_postexec ||
                            (c_transfer && (c_size != 3'd2) && (c_size != 3'd3)))
                            cmderr_r <= CMDERR_NOTSUP;
                        else if (!st_halted)
                            cmderr_r <= CMDERR_HALTRES;
                        else if (!c_transfer) begin
                            if (c_postinc) command_r[15:0] <= c_regno + 16'd1;
                        end else
                            ab_state <= AB_REG_ISSUE;
                    end else if (c_type == 8'd2) begin
                        // Access Memory
                        if (c_bit23 || c_size > 3'd3 || command_r[18:17] != 2'b00)
                            cmderr_r <= CMDERR_NOTSUP;
                        else if (arg1[63:ADDR_WIDTH] != '0 || !aligned(arg1[2:0], c_size))
                            cmderr_r <= CMDERR_BUS;
                        else
                            ab_state <= AB_MEM_PEND;
                    end else begin
                        cmderr_r <= CMDERR_NOTSUP;
                    end
                end
                AB_REG_ISSUE: begin
                    if (hart_in_reset || !hart_halted) begin
                        cmderr_r <= CMDERR_HALTRES;
                        ab_state <= AB_IDLE;
                    end else if (!reg_busy) begin
                        reg_req    <= 1'b1;
                        reg_busy   <= 1'b1;
                        reg_wr     <= c_write;
                        reg_regno  <= c_regno;
                        reg_size64 <= (c_size == 3'd3);
                        reg_wdata  <= (c_size == 3'd3) ? arg0 : {32'd0, data_r[0]};
                        ab_state   <= AB_REG_WAIT;
                    end
                end
                default: ;
            endcase

            //---------------------------------------------------------
            // Hart register response
            //---------------------------------------------------------
            if (reg_busy && !reg_req) begin
                if (reg_ack || hart_in_reset) begin
                    reg_busy <= 1'b0;
                    if (ab_state == AB_REG_WAIT) begin
                        ab_state <= AB_IDLE;
                        if (!reg_ack)
                            cmderr_r <= CMDERR_HALTRES;
                        else if (reg_err)
                            cmderr_r <= CMDERR_EXCEPT;
                        else begin
                            if (!c_write) begin
                                data_r[0] <= reg_rdata[31:0];
                                if (c_size == 3'd3) data_r[1] <= reg_rdata[63:32];
                            end
                            if (c_postinc) command_r[15:0] <= c_regno + 16'd1;
                        end
                    end
                end
            end

            //---------------------------------------------------------
            // Bus master scheduling
            //---------------------------------------------------------
            if (!bm_busy) begin
                if (sb_pend) begin
                    sb_pend <= 1'b0;
                    if (bus_in_reset) begin
                        sberror_r <= 3'd1;
                    end else begin
                        sb_wait      <= 1'b1;
                        bm_busy      <= 1'b1;
                        bm_owner_sba <= 1'b1;
                        bm_req       <= 1'b1;
                        bm_wr        <= sb_wr;
                        bm_addr      <= sbaddress_r;
                        bm_size      <= sbaccess_r[1:0];
                        bm_wdata     <= {sbdata1_r, sbdata0_r};
                    end
                end else if (ab_state == AB_MEM_PEND) begin
                    if (bus_in_reset) begin
                        cmderr_r <= CMDERR_BUS;
                        ab_state <= AB_IDLE;
                    end else begin
                        ab_state     <= AB_MEM_WAIT;
                        bm_busy      <= 1'b1;
                        bm_owner_sba <= 1'b0;
                        bm_req       <= 1'b1;
                        bm_wr        <= c_write;
                        bm_addr      <= arg1[ADDR_WIDTH-1:0];
                        bm_size      <= c_size[1:0];
                        bm_wdata     <= arg0;
                    end
                end
            end else if (!bm_req && (bm_ack || bus_in_reset)) begin
                bm_busy <= 1'b0;
                if (bm_owner_sba && sb_wait) begin
                    sb_wait <= 1'b0;
                    if (!bm_ack)
                        sberror_r <= 3'd1;
                    else if (bm_err != 3'd0)
                        sberror_r <= bm_err;
                    else begin
                        if (!bm_wr) begin
                            sbdata0_r <= bm_rdata[31:0];
                            sbdata1_r <= bm_rdata[63:32];
                        end
                        if (sbautoincrement_r)
                            sbaddress_r <= sbaddress_r + ADDR_WIDTH'(size_bytes(sbaccess_r));
                    end
                end
                if (!bm_owner_sba && ab_state == AB_MEM_WAIT) begin
                    ab_state <= AB_IDLE;
                    if (!bm_ack || bm_err != 3'd0)
                        cmderr_r <= CMDERR_BUS;
                    else begin
                        if (!c_write) begin
                            data_r[0] <= bm_rdata[31:0];
                            data_r[1] <= bm_rdata[63:32];
                        end
                        if (c_postinc)
                            {data_r[3], data_r[2]} <= arg1 + 64'(size_bytes(c_size));
                    end
                end
            end

            //---------------------------------------------------------
            // dmactive = 0 : reset the DM (in-flight trackers are kept)
            //---------------------------------------------------------
            if (!dmactive) begin
                auth_ok           <= 1'b0;
                haltreq_r         <= 1'b0;
                hartreset_r       <= 1'b0;
                hartsel_r         <= 1'b0;
                ndmreset_r        <= 1'b0;
                resethaltreq_r    <= 1'b0;
                hart_resumereq    <= 1'b0;
                for (int i = 0; i < 4; i++) data_r[i] <= 32'd0;
                command_r         <= 32'd0;
                autoexec_r        <= 4'd0;
                cmderr_r          <= 3'd0;
                ab_state          <= AB_IDLE;
                sbbusyerror_r     <= 1'b0;
                sbreadonaddr_r    <= 1'b0;
                sbaccess_r        <= 3'd2;
                sbautoincrement_r <= 1'b0;
                sbreadondata_r    <= 1'b0;
                sberror_r         <= 3'd0;
                sbaddress_r       <= '0;
                sbdata0_r         <= 32'd0;
                sbdata1_r         <= 32'd0;
                sb_pend           <= 1'b0;
                sb_wait           <= 1'b0;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

endmodule : DBG_DM
