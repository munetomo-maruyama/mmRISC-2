//---------------------------------------------------------------------------
// DBG_DTM.sv
//
// RISC-V JTAG Debug Transport Module (Debug Spec 1.0, section 6.1)
//
//   IR length 5, reset value IDCODE
//     0x01 IDCODE (32)   0x10 dtmcs (32)   0x11 dmi (ABITS+34)
//     0x00, 0x1f and all others : BYPASS (1)
//
//   All logic runs on TCK (or TCKC in cJTAG mode). The TAP advances only when
//   tap_ce=1 (always 1 in 4-wire JTAG mode). TDO is updated at the TCK
//   falling edge. DMI requests are passed to DBG_CDC.
//
//   dmi op (sticky) : 0 success, 2 failed, 3 busy
//     Update-DR : op=1/2 starts a request if no sticky error and not busy;
//                 if busy the request is dropped and op becomes 3 (sticky).
//     Capture-DR: if the request is still outstanding op becomes 3 (sticky),
//                 otherwise the response data is captured.
//   dtmcs.dmireset     : clears the sticky op and errinfo
//   dtmcs.dtmhardreset : clears the sticky op and errinfo and cancels a
//                        request that has not reached the DM yet. A request
//                        already raised completes (see DBG_CDC).
//   Test-Logic-Reset / TRST act as dtmhardreset.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_DTM
    #(
        parameter logic [31:0] IDCODE = 32'h26d6d001,
        parameter int          ABITS  = 7,
        parameter logic [2:0]  IDLE   = 3'd1
    )
    (
        input  logic             tck,
        input  logic             tap_rst_n,   // TRST & POR (async assert)

        input  logic             tap_ce,
        input  logic             tap_tms,
        input  logic             tap_tdi,
        input  logic             tap_hold,    // synchronous hold in TLR
        output logic             tdo,
        output logic             tdo_oe,

        // DMI (to DBG_CDC, TCK domain)
        output logic             dmi_start,
        output logic [ABITS-1:0] dmi_addr,
        output logic             dmi_wr,
        output logic [31:0]      dmi_wdata,
        output logic             dmi_abort,
        input  logic             dmi_busy,
        input  logic [31:0]      dmi_rdata,
        input  logic             dmi_err
    );

    //-----------------------------------------------------------------
    // TAP controller
    //-----------------------------------------------------------------
    // (localparams rather than an enum: Icarus Verilog requires casts on
    //  enum ternaries)
    localparam logic [3:0] TLR       = 4'h0;
    localparam logic [3:0] RTI       = 4'h1;
    localparam logic [3:0] SEL_DR    = 4'h2;
    localparam logic [3:0] CAP_DR    = 4'h3;
    localparam logic [3:0] SHIFT_DR  = 4'h4;
    localparam logic [3:0] EXIT1_DR  = 4'h5;
    localparam logic [3:0] PAUSE_DR  = 4'h6;
    localparam logic [3:0] EXIT2_DR  = 4'h7;
    localparam logic [3:0] UPDATE_DR = 4'h8;
    localparam logic [3:0] SEL_IR    = 4'h9;
    localparam logic [3:0] CAP_IR    = 4'hA;
    localparam logic [3:0] SHIFT_IR  = 4'hB;
    localparam logic [3:0] EXIT1_IR  = 4'hC;
    localparam logic [3:0] PAUSE_IR  = 4'hD;
    localparam logic [3:0] EXIT2_IR  = 4'hE;
    localparam logic [3:0] UPDATE_IR = 4'hF;

    logic [3:0] state, state_nx;

    always_comb begin
        case (state)
            TLR:       state_nx = tap_tms ? TLR       : RTI;
            RTI:       state_nx = tap_tms ? SEL_DR    : RTI;
            SEL_DR:    state_nx = tap_tms ? SEL_IR    : CAP_DR;
            CAP_DR:    state_nx = tap_tms ? EXIT1_DR  : SHIFT_DR;
            SHIFT_DR:  state_nx = tap_tms ? EXIT1_DR  : SHIFT_DR;
            EXIT1_DR:  state_nx = tap_tms ? UPDATE_DR : PAUSE_DR;
            PAUSE_DR:  state_nx = tap_tms ? EXIT2_DR  : PAUSE_DR;
            EXIT2_DR:  state_nx = tap_tms ? UPDATE_DR : SHIFT_DR;
            UPDATE_DR: state_nx = tap_tms ? SEL_DR    : RTI;
            SEL_IR:    state_nx = tap_tms ? TLR       : CAP_IR;
            CAP_IR:    state_nx = tap_tms ? EXIT1_IR  : SHIFT_IR;
            SHIFT_IR:  state_nx = tap_tms ? EXIT1_IR  : SHIFT_IR;
            EXIT1_IR:  state_nx = tap_tms ? UPDATE_IR : PAUSE_IR;
            PAUSE_IR:  state_nx = tap_tms ? EXIT2_IR  : PAUSE_IR;
            EXIT2_IR:  state_nx = tap_tms ? UPDATE_IR : SHIFT_IR;
            UPDATE_IR: state_nx = tap_tms ? SEL_DR    : RTI;
            default:   state_nx = TLR;
        endcase
    end

    //-----------------------------------------------------------------
    // Registers
    //-----------------------------------------------------------------
    localparam logic [4:0] IR_IDCODE = 5'h01;
    localparam logic [4:0] IR_DTMCS  = 5'h10;
    localparam logic [4:0] IR_DMI    = 5'h11;

    localparam int DMI_LEN = ABITS + 34;
    localparam int SR_LEN  = DMI_LEN;          // longest DR

    logic [4:0]        ir;
    logic [4:0]        ir_sr;
    logic [SR_LEN-1:0] dr_sr;
    logic [1:0]        sticky;     // dmi op status
    logic [2:0]        errinfo;
    logic [ABITS-1:0]  last_addr;

    // DR length for the current instruction
    int unsigned dr_len;
    always_comb begin
        case (ir)
            IR_IDCODE: dr_len = 32;
            IR_DTMCS:  dr_len = 32;
            IR_DMI:    dr_len = DMI_LEN;
            default:   dr_len = 1;
        endcase
    end

    // shifted DR value
    logic [SR_LEN-1:0] dr_shift;
    always_comb begin
        dr_shift = dr_sr >> 1;
        dr_shift[dr_len-1] = tap_tdi;
    end

    // TLR (entered by TMS or held) acts like dtmhardreset
    logic upd_dtmcs, upd_dmi;
    assign upd_dtmcs = tap_ce & ~tap_hold & (state == UPDATE_DR) & (ir == IR_DTMCS);
    assign upd_dmi   = tap_ce & ~tap_hold & (state == UPDATE_DR) & (ir == IR_DMI);

    logic [1:0] upd_op;
    assign upd_op = dr_sr[1:0];

    // DMI request (valid at the Update-DR edge)
    assign dmi_start = upd_dmi & (sticky == 2'd0) & ((upd_op == 2'd1) | (upd_op == 2'd2));
    assign dmi_addr  = dr_sr[DMI_LEN-1:34];
    assign dmi_wdata = dr_sr[33:2];
    assign dmi_wr    = (upd_op == 2'd2);
    assign dmi_abort = tap_hold | (tap_ce & (state == TLR)) | (upd_dtmcs & dr_sr[17]);

    always_ff @(posedge tck or negedge tap_rst_n) begin
        if (!tap_rst_n) begin
            state     <= TLR;
            ir        <= IR_IDCODE;
            ir_sr     <= '0;
            dr_sr     <= '0;
            sticky    <= 2'd0;
            errinfo   <= 3'd4;
            last_addr <= '0;
        end else if (tap_hold) begin
            // cJTAG offline: hold in Test-Logic-Reset (independent of tap_ce)
            state   <= TLR;
            ir      <= IR_IDCODE;
            sticky  <= 2'd0;
            errinfo <= 3'd4;
        end else if (tap_ce) begin
            begin
                state <= state_nx;
                case (state)
                    TLR: begin
                        ir      <= IR_IDCODE;
                        sticky  <= 2'd0;
                        errinfo <= 3'd4;
                    end
                    CAP_IR:    ir_sr <= 5'b00001;
                    SHIFT_IR:  ir_sr <= {tap_tdi, ir_sr[4:1]};
                    UPDATE_IR: ir    <= ir_sr;
                    CAP_DR: begin
                        dr_sr <= '0;
                        case (ir)
                            IR_IDCODE: dr_sr[31:0] <= IDCODE;
                            IR_DTMCS:  dr_sr[31:0] <= {11'd0, errinfo, 1'b0, 1'b0, 1'b0,
                                                       IDLE, sticky, 6'(ABITS), 4'd1};
                            IR_DMI: begin
                                if (sticky != 2'd0) begin
                                    dr_sr <= {last_addr, 32'd0, sticky};
                                end else if (dmi_busy) begin
                                    sticky <= 2'd3;
                                    dr_sr  <= {last_addr, 32'd0, 2'd3};
                                end else if (dmi_err) begin
                                    sticky  <= 2'd2;
                                    errinfo <= 3'd3;
                                    dr_sr   <= {last_addr, 32'd0, 2'd2};
                                end else begin
                                    dr_sr <= {last_addr, dmi_rdata, 2'd0};
                                end
                            end
                            default: ;
                        endcase
                    end
                    SHIFT_DR: dr_sr <= dr_shift;
                    UPDATE_DR: begin
                        if (ir == IR_DTMCS) begin
                            if (dr_sr[17] | dr_sr[16]) begin   // dtmhardreset / dmireset
                                sticky  <= 2'd0;
                                errinfo <= 3'd4;
                            end
                        end else if (ir == IR_DMI) begin
                            if ((sticky == 2'd0) & ((upd_op == 2'd1) | (upd_op == 2'd2))) begin
                                if (dmi_busy)
                                    sticky <= 2'd3;
                                else
                                    last_addr <= dmi_addr;
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    //-----------------------------------------------------------------
    // TDO (TCK falling edge)
    //-----------------------------------------------------------------
    always_ff @(negedge tck or negedge tap_rst_n) begin
        if (!tap_rst_n) begin
            tdo    <= 1'b0;
            tdo_oe <= 1'b0;
        end else begin
            tdo    <= (state == SHIFT_IR) ? ir_sr[0] : dr_sr[0];
            tdo_oe <= (state == SHIFT_IR) | (state == SHIFT_DR);
        end
    end

endmodule : DBG_DTM
