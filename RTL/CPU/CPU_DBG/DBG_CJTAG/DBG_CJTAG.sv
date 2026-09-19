//---------------------------------------------------------------------------
// DBG_CJTAG.sv
//
// cJTAG (IEEE 1149.7) OScan1 receiver / JTAG pass-through
//
//   cjtag_en = 0 : 4-wire JTAG. TCK/TMS/TDI/TDO are passed through.
//   cjtag_en = 1 : 2-wire cJTAG (OScan1) on TCKC (= TCK pin) and
//                  TMSC (= TMS pin, bidirectional).
//
// Design rules
//   - TCK is never gated. The TAP in DBG_DTM is clocked directly by the
//     TCKC pin and advanced with a clock enable (tap_ce) only in the third
//     OScan1 phase. No system clock is used, so the TCKC frequency is
//     independent of the system clock.
//
//   - Escape sequences (TMSC toggles while TCKC is high) are counted by a
//     Gray-code counter clocked by TMSC rising edges; it increments only when
//     TCKC is high. Snapshots of the counter are taken at the TCKC rising and
//     falling edges, and the number of TMSC rising edges r during the last
//     TCKC high period is evaluated at the next TCKC rising edge:
//         r >= 4 : reset escape      -> offline, TAP reset
//         r == 3 : selection escape  -> wait for activation code
//         r == 2 : deselection       -> offline
//         r <= 1 : ignored
//     Because only one Gray-code bit changes per count, a TMSC edge coincident
//     with a TCKC edge can only cause a +/-1 error, which cannot turn an
//     ordinary data bit into an escape.
//
//   - Activation: the 12 TCKC rising edges starting with the one that
//     evaluates the selection escape carry OAC, EC, CP (LSB first). Code
//     0x08C (OAC=1100, EC=1000, CP=0000) enters OScan1; anything else goes
//     offline. This matches riscv-openocd cjtag_reset_online_activate().
//
//   - OScan1 bit frame (all sampled at TCKC rising edges):
//         phase 0 : TMSC = ~TDI
//         phase 1 : TMSC = TMS
//         phase 2 : target drives TDO on TMSC while TCKC is low;
//                   the TAP advances at the TCKC rising edge
//
//   - While not in OScan1 (cJTAG mode), the TAP is held in Test-Logic-Reset.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_CJTAG
    (
        input  logic por_n,          // debug power-on reset (asynchronous)
        input  logic cjtag_en,       // mode strap (asynchronous)

        // pins
        input  logic tck,            // TCK / TCKC
        input  logic tms_i,          // TMS / TMSC input
        output logic tms_o,          // TMSC output
        output logic tms_oe,         // TMSC output enable
        input  logic tdi,            // TDI (JTAG only)
        output logic tdo,            // TDO (JTAG only)
        output logic tdo_oe,

        // to/from DBG_DTM (TCK domain)
        input  logic t_rst_n,        // debug POR synchronized to TCK
        output logic tap_ce,         // TAP clock enable
        output logic tap_tms,
        output logic tap_tdi,
        output logic tap_hold,       // hold TAP in Test-Logic-Reset
        input  logic dtm_tdo,        // updated at TCK falling edge
        input  logic dtm_tdo_oe,

        // status
        output logic online          // OScan1 active
    );

    //-----------------------------------------------------------------
    // Mode strap synchronization
    //-----------------------------------------------------------------
    logic mode_c;   // 1: cJTAG

    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync_mode
        (.clk(tck), .rst_n(t_rst_n), .d(cjtag_en), .q(mode_c));

    //-----------------------------------------------------------------
    // Escape counter (clocked by TMSC rising edges)
    //-----------------------------------------------------------------
    localparam int EW = 5;

    // Gray <-> binary conversion (written without functions: Verilator 5.020
    // fails to inline a looping function in this hierarchy)
    `define DBG_G2B(g) {^g[4:4], ^g[4:3], ^g[4:2], ^g[4:1], ^g[4:0]}

    // initial value = power-up register INIT (only differences of the count are used)
    (* ASYNC_REG = "TRUE" *) logic [EW-1:0] esc_gray = '0;
    logic [EW-1:0] esc_gray_inc;
    logic [EW-1:0] esc_bin;

    assign esc_bin      = `DBG_G2B(esc_gray);
    assign esc_gray_inc = (esc_bin + 1'b1) ^ ((esc_bin + 1'b1) >> 1);

    always_ff @(posedge tms_i or negedge por_n) begin
        if (!por_n)
            esc_gray <= '0;
        else if (tck)
            esc_gray <= esc_gray_inc;
    end

    // snapshots
    (* ASYNC_REG = "TRUE" *) logic [EW-1:0] snap_rise;
    (* ASYNC_REG = "TRUE" *) logic [EW-1:0] snap_fall;

    always_ff @(negedge tck or negedge t_rst_n) begin
        if (!t_rst_n) snap_fall <= '0;
        else          snap_fall <= esc_gray;
    end

    logic [EW-1:0] snap_fall_bin, snap_rise_bin, esc_r;
    assign snap_fall_bin = `DBG_G2B(snap_fall);
    assign snap_rise_bin = `DBG_G2B(snap_rise);
    assign esc_r         = snap_fall_bin - snap_rise_bin;

    logic esc_reset, esc_select, esc_deselect, esc_any;
    assign esc_reset    = (esc_r >= 4);
    assign esc_select   = (esc_r == 3);
    assign esc_deselect = (esc_r == 2);
    assign esc_any      = esc_reset | esc_select | esc_deselect;

    //-----------------------------------------------------------------
    // cJTAG state (TCKC rising edge)
    //-----------------------------------------------------------------
    localparam logic [11:0] ACT_CODE = 12'h08C;   // {CP, EC, OAC}, LSB first

    typedef enum logic [1:0] {C_OFFLINE, C_ACTIV, C_OSCAN1} c_state_t;
    c_state_t   c_state;
    logic [3:0] act_cnt;
    logic [1:0] phase;
    logic       tdi_c;
    logic       tms_c;

    always_ff @(posedge tck or negedge t_rst_n) begin
        if (!t_rst_n) begin
            snap_rise <= '0;
            c_state   <= C_OFFLINE;
            act_cnt   <= '0;
            phase     <= '0;
            tdi_c     <= 1'b0;
            tms_c     <= 1'b1;
        end else begin
            snap_rise <= esc_gray;
            if (!mode_c) begin
                c_state <= C_OFFLINE;
                phase   <= '0;
            end else if (esc_reset | esc_deselect) begin
                c_state <= C_OFFLINE;
                phase   <= '0;
            end else if (esc_select) begin
                // this edge already carries OAC bit 0
                phase <= '0;
                if (tms_i == ACT_CODE[0]) begin
                    c_state <= C_ACTIV;
                    act_cnt <= 4'd1;
                end else begin
                    c_state <= C_OFFLINE;
                end
            end else begin
                case (c_state)
                    C_ACTIV: begin
                        if (tms_i != ACT_CODE[act_cnt])
                            c_state <= C_OFFLINE;
                        else if (act_cnt == 4'd11) begin
                            c_state <= C_OSCAN1;
                            phase   <= '0;
                        end else
                            act_cnt <= act_cnt + 4'd1;
                    end
                    C_OSCAN1: begin
                        case (phase)
                            2'd0:    begin tdi_c <= ~tms_i; phase <= 2'd1; end
                            2'd1:    begin tms_c <=  tms_i; phase <= 2'd2; end
                            default: begin                  phase <= 2'd0; end
                        endcase
                    end
                    default: ;
                endcase
            end
        end
    end

    //-----------------------------------------------------------------
    // Outputs
    //-----------------------------------------------------------------
    logic oscan1;
    assign oscan1 = mode_c & (c_state == C_OSCAN1);
    assign online = oscan1;

    // TAP control
    assign tap_ce   = mode_c ? (oscan1 & (phase == 2'd2) & ~esc_any) : 1'b1;
    assign tap_tms  = mode_c ? tms_c : tms_i;
    assign tap_tdi  = mode_c ? tdi_c : tdi;
    assign tap_hold = mode_c & ~oscan1;

    // JTAG TDO pin
    assign tdo    = dtm_tdo;
    assign tdo_oe = mode_c ? 1'b0 : dtm_tdo_oe;

    // TMSC drive: phase 2 while TCKC is low, released at TCKC rise
    assign tms_o  = dtm_tdo;
    assign tms_oe = oscan1 & (phase == 2'd2) & ~tck;

`undef DBG_G2B

endmodule : DBG_CJTAG
