//---------------------------------------------------------------------------
// tb_OCD.sv : OpenOCD co-simulation of RTL/TOP/TOP.sv (Verilator only)
//
// OpenOCD (adapter driver remote_bitbang) connects to the DPI-C server in
// jtag_rbb.c and drives the PMOD JA pins of TOP. Each remote_bitbang pin
// update is applied every TCK_STEP ns while the system clock runs
// independently, so the CDC of the DTM is exercised with a real debugger.
//
//   +port=<n>     TCP port (default 44853)
//   +auth=1       SW2 up : authentication enabled
//   +sysmhz=<n>   system clock frequency in MHz (default 50)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_OCD;

    import "DPI-C" function int rbb_init(input int port);
    import "DPI-C" function int rbb_tick(inout int tck, inout int tms, inout int tdi,
                                         inout int trst_n, inout int srst_n, input int tdo);

    localparam real TCK_STEP = 7.0;     // ns per remote_bitbang command

    real  sys_half = 10.0;
    logic clk100   = 1'b0;
    always begin
        #(sys_half);
        clk100 = ~clk100;
    end

    logic sw2 = 1'b0;
    wire  [7:4] led;
    logic ja_tck   = 1'b0;
    logic ja_tms_d = 1'b1;
    logic ja_tdi   = 1'b0;
    logic ja_trstn = 1'b1;
    logic ja_srstn = 1'b1;
    wire  ja_tdo;
    wire  ja_tms;

    assign ja_tms = ja_tms_d;           // 4-wire JTAG : host always drives TMS

    TOP
        #(
            .SIM         (1),
            .USE_BFM     (0),
            .SBA_TIMEOUT (1 << 20),
            .POR_BITS    (8)
        )
    u_top
        (
            .CLK100MHZ  (clk100),
            .CPU_RESETN (1'b1),
            .SW2        (sw2),
            .SW3        (1'b0),
            .LED        (led),
            .JA_TCK     (ja_tck),
            .JA_TDI     (ja_tdi),
            .JA_TDO     (ja_tdo),
            .JA_TMS     (ja_tms),
            .JA_TRSTN   (ja_trstn),
            .JA_SRSTN   (ja_srstn)
        );

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_OCD.vcd");
        $dumpvars(0, tb_OCD);
    end
`endif

    initial begin
        int port, auth, mhz, st;
        int tck, tms, tdi, trst_n, srst_n;
        if (!$value$plusargs("port=%d", port)) port = 44853;
        if (!$value$plusargs("auth=%d", auth)) auth = 0;
        if (!$value$plusargs("sysmhz=%d", mhz)) mhz = 50;
        sw2      = (auth != 0);
        sys_half = 500.0 / mhz;
        $display("[tb_OCD] system clock %0d MHz, authentication %s", mhz, auth ? "on" : "off");
        wait (u_top.rst_dbg_n === 1'b1 && u_top.rst_n === 1'b1);   // power-on reset done
        #1000;
        if (rbb_init(port) != 0) $finish;
        tck = 0; tms = 1; tdi = 0; trst_n = 1; srst_n = 1;
        forever begin
            st = rbb_tick(tck, tms, tdi, trst_n, srst_n, (ja_tdo === 1'b1) ? 1 : 0);
            if (st == 2) begin
                $display("[tb_OCD] OpenOCD disconnected at %0t", $time);
                $finish;
            end
            ja_tck   = tck[0];
            ja_tms_d = tms[0];
            ja_tdi   = tdi[0];
            ja_trstn = trst_n[0];
            ja_srstn = srst_n[0];
            #(TCK_STEP);
        end
    end

endmodule : tb_OCD
