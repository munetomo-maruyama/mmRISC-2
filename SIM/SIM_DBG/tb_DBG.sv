//---------------------------------------------------------------------------
// tb_DBG.sv
//
// Verification of the mmRISC-2 debug logic (RTL/CPU/CPU_DBG) through the FPGA
// top RTL/TOP/TOP.sv (SIM=1: MMCM bypassed, USE_BFM=1: CPU_BFM enabled).
//
//   tb_DBG ── JTAG / cJTAG host BFM ──> TOP (PMOD JA pins)
//          ── clk100 (period changed at run time for the CDC sweep)
//          ── backdoor checks of AXI4_RAM / AXIL_RAM contents
//          ── CPU_BFM commands (concurrent bus traffic)
//
// The JTAG host behaves like OpenOCD: DMI busy responses are handled with
// dmireset and additional Run-Test/Idle cycles.
//
// Test items: see tb_DBG_tests.svh
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_DBG;

    //=================================================================
    // Parameters
    //=================================================================
    localparam logic [31:0] IDCODE      = 32'h26d6d001;
    localparam logic [31:0] AUTH_KEY    = 32'hbeefcafe;
    localparam int          SBA_TIMEOUT = 1 << 17;   // 2.6 ms at 50MHz (> several DMI accesses)
    localparam logic [39:0] MEM_BASE    = 40'h00_8000_0000;
    localparam int          MEM_WORDS   = 8192;
    localparam logic [39:0] PERI_BASE   = 40'h00_1200_0000;
    localparam int          PERI_WORDS  = 512;

    // DM register addresses
    localparam logic [6:0] DM_DATA0        = 7'h04;
    localparam logic [6:0] DM_DATA1        = 7'h05;
    localparam logic [6:0] DM_DATA2        = 7'h06;
    localparam logic [6:0] DM_DATA3        = 7'h07;
    localparam logic [6:0] DM_DATA4        = 7'h08;
    localparam logic [6:0] DM_DMCONTROL    = 7'h10;
    localparam logic [6:0] DM_DMSTATUS     = 7'h11;
    localparam logic [6:0] DM_HARTINFO     = 7'h12;
    localparam logic [6:0] DM_HALTSUM1     = 7'h13;
    localparam logic [6:0] DM_ABSTRACTCS   = 7'h16;
    localparam logic [6:0] DM_COMMAND      = 7'h17;
    localparam logic [6:0] DM_ABSTRACTAUTO = 7'h18;
    localparam logic [6:0] DM_PROGBUF0     = 7'h20;
    localparam logic [6:0] DM_AUTHDATA     = 7'h30;
    localparam logic [6:0] DM_SBCS         = 7'h38;
    localparam logic [6:0] DM_SBADDRESS0   = 7'h39;
    localparam logic [6:0] DM_SBADDRESS1   = 7'h3A;
    localparam logic [6:0] DM_SBDATA0      = 7'h3C;
    localparam logic [6:0] DM_SBDATA1      = 7'h3D;
    localparam logic [6:0] DM_HALTSUM0     = 7'h40;

    //=================================================================
    // Clock and board inputs
    //=================================================================
    real  sys_half = 10.0;        // ns : 50MHz
    logic clk100   = 1'b0;

    always begin
        #(sys_half);
        clk100 = ~clk100;
    end

    logic cpu_resetn = 1'b1;
    logic sw2_auth   = 1'b0;
    logic sw3_cjtag  = 1'b0;
    wire  [7:4] led;

    //=================================================================
    // JTAG pins
    //=================================================================
    logic ja_tck   = 1'b0;
    logic ja_tdi   = 1'b0;
    logic ja_trstn = 1'b1;
    logic ja_srstn = 1'b1;
    wire  ja_tdo;
    wire  ja_tms;

    // TMS / TMSC : host driver, DUT driver (inside TOP) and a bus keeper
    logic host_oe  = 1'b1;
    logic host_tms = 1'b1;
    logic keeper   = 1'b1;
    logic dut_oe;
    logic dut_o;

    assign dut_oe = u_top.jtag_tms_oe;
    assign dut_o  = u_top.jtag_tms_o;

    assign ja_tms = host_oe ? host_tms : 1'bz;
    assign ja_tms = (!host_oe && !dut_oe) ? keeper : 1'bz;

    always @(host_oe or host_tms or dut_oe or dut_o) begin
        if (host_oe)     keeper = host_tms;
        else if (dut_oe) keeper = dut_o;
    end

    int tmsc_contention = 0;
    always @(host_oe or dut_oe) begin
        if (host_oe === 1'b1 && dut_oe === 1'b1) tmsc_contention++;
    end

    //=================================================================
    // DUT
    //=================================================================
    TOP
        #(
            .SIM         (1),
            .USE_BFM     (1),
            .AUTH_KEY    (AUTH_KEY),
            .MEM_WORDS   (MEM_WORDS),
            .PERI_WORDS  (PERI_WORDS),
            .SBA_TIMEOUT (SBA_TIMEOUT),
            .POR_BITS    (5)
        )
    u_top
        (
            .CLK100MHZ  (clk100),
            .CPU_RESETN (cpu_resetn),
            .SW2        (sw2_auth),
            .SW3        (sw3_cjtag),
            .LED        (led),
            .JA_TCK     (ja_tck),
            .JA_TDI     (ja_tdi),
            .JA_TDO     (ja_tdo),
            .JA_TMS     (ja_tms),
            .JA_TRSTN   (ja_trstn),
            .JA_SRSTN   (ja_srstn)
        );

`ifdef DUMP_VCD
    // +vcd=<file> selects the dump file name (default tb_DBG.vcd)
    initial begin
        string vcd_name;
        if (!$value$plusargs("vcd=%s", vcd_name)) vcd_name = "tb_DBG.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_DBG);
    end
`endif

    //=================================================================
    // Result bookkeeping
    //=================================================================
    int n_check = 0;
    int n_error = 0;
    int n_busy  = 0;       // DMI busy responses seen (retried)

    task automatic check(input string name, input bit cond);

        n_check++;
        if (!cond) begin
            n_error++;
            $display("[%0t] [FAIL] %s", $time, name);
        end
    endtask

    task automatic check32(input string name, input logic [31:0] exp, input logic [31:0] act);

        n_check++;
        if (act !== exp) begin
            n_error++;
            $display("[%0t] [FAIL] %s : expected=0x%08h actual=0x%08h", $time, name, exp, act);
        end
    endtask

    task automatic check64(input string name, input logic [63:0] exp, input logic [63:0] act);

        n_check++;
        if (act !== exp) begin
            n_error++;
            $display("[%0t] [FAIL] %s : expected=0x%016h actual=0x%016h", $time, name, exp, act);
        end
    endtask

    task automatic section(input string name);

        $display("");
        $display("--- %s ---", name);
    endtask

    task automatic ok(input string name);

        $display("[%0t] [ OK ] %s", $time, name);
    endtask

    //=================================================================
    // JTAG / cJTAG host BFM
    //=================================================================
    real tck_half     = 50.0;     // ns
    real tck_jitter   = 0.0;      // +/- fraction of tck_half
    bit  cjtag        = 1'b0;     // 0: 4-wire JTAG, 1: cJTAG OScan1
    bit  align_worst  = 1'b0;     // cJTAG: change TMSC at the TCKC falling edge
    int  idle_cycles  = 1;        // Run-Test/Idle cycles after a DMI scan
    int  idle_max     = 0;

    task automatic half_wait();

        real d;
        d = tck_half;
        if (tck_jitter != 0.0)
            d = tck_half * (1.0 + tck_jitter * (real'($urandom_range(0, 2000)) - 1000.0) / 1000.0);
        #(d);
    endtask

    // One TAP cycle. Returns TDO sampled before the TCK rising edge.
    // (engine body, see tap_cycle below)
    task automatic e_tap_cycle(input bit tms, input bit tdi, output bit tdo);
        if (!cjtag) begin
            host_oe  = 1'b1;
            host_tms = tms;
            ja_tdi   = tdi;
            half_wait();
            tdo = ja_tdo;
            ja_tck = 1'b1;
            half_wait();
            ja_tck = 1'b0;
        end else begin
            // phase 0 : TMSC = ~TDI
            if (align_worst) begin
                // TMSC changes in the same time step as the TCKC falling edge
                host_tms = ~tdi;
            end else begin
                #(tck_half / 2.0);
                host_tms = ~tdi;
            end
            half_wait();
            ja_tck = 1'b1;
            half_wait();
            // phase 1 : TMSC = TMS
            // worst case: TMSC rises while TCKC is still high (same time step
            // as the falling edge), so it is counted by the escape detector
            if (align_worst) host_tms = tms;
            ja_tck = 1'b0;
            if (!align_worst) begin
                #(tck_half / 2.0);
                host_tms = tms;
            end
            half_wait();
            ja_tck = 1'b1;
            half_wait();
            // phase 2 : release TMSC, the target drives TDO while TCKC is low
            host_oe = 1'b0;
            ja_tck  = 1'b0;
            half_wait();
            tdo = ja_tms;
            ja_tck = 1'b1;
            half_wait();
            ja_tck = 1'b0;
            host_tms = keeper;
            host_oe  = 1'b1;
        end
    endtask

    //-----------------------------------------------------------------
    // Engines
    //   The Verilator build inlines every call of a timed task. To keep the
    //   generated model small, the TAP bit cycle and the DMI access run in
    //   dedicated processes; the tasks called by the tests only pass the
    //   arguments with a zero-time handshake.
    //-----------------------------------------------------------------
    logic be_req = 1'b0, be_ack = 1'b0;
    bit   be_tms, be_tdi, be_tdo;

    initial forever begin
        wait (be_req === 1'b1);
        e_tap_cycle(be_tms, be_tdi, be_tdo);
        be_ack = 1'b1;
        wait (be_req === 1'b0);
        be_ack = 1'b0;
    end

    task automatic tap_cycle(input bit tms, input bit tdi, output bit tdo);
        be_tms = tms;
        be_tdi = tdi;
        be_req = 1'b1;
        wait (be_ack === 1'b1);
        tdo    = be_tdo;
        be_req = 1'b0;
        wait (be_ack === 1'b0);
    endtask

    task automatic tap_idle(input int n);

        bit tdo;
        for (int i = 0; i < n; i++) tap_cycle(1'b0, 1'b0, tdo);
    endtask

    logic [4:0] cur_ir = 5'h01;

    // Test-Logic-Reset -> Run-Test/Idle
    task automatic tap_reset();
        bit tdo;
        for (int i = 0; i < 6; i++) tap_cycle(1'b1, 1'b0, tdo);
        tap_cycle(1'b0, 1'b0, tdo);
        cur_ir = 5'h01;
    endtask

    // IR scan from / to Run-Test/Idle
    task automatic scan_ir(input logic [4:0] ir, output logic [4:0] cap);
        bit tdo;
        tap_cycle(1'b1, 1'b0, tdo);   // Select-DR
        tap_cycle(1'b1, 1'b0, tdo);   // Select-IR
        tap_cycle(1'b0, 1'b0, tdo);   // Capture-IR
        tap_cycle(1'b0, 1'b0, tdo);   // Shift-IR
        for (int i = 0; i < 5; i++) begin
            tap_cycle((i == 4), ir[i], tdo);
            cap[i] = tdo;
        end
        tap_cycle(1'b1, 1'b0, tdo);   // Update-IR
        tap_cycle(1'b0, 1'b0, tdo);   // Run-Test/Idle
        cur_ir = ir;
    endtask

    task automatic set_ir(input logic [4:0] ir);

        logic [4:0] cap;
        if (cur_ir != ir) scan_ir(ir, cap);
    endtask

    // DR scan from / to Run-Test/Idle
    task automatic scan_dr(input int len, input logic [63:0] din, output logic [63:0] dout,
                           input int idle);
        bit tdo;
        dout = '0;
        tap_cycle(1'b1, 1'b0, tdo);   // Select-DR
        tap_cycle(1'b0, 1'b0, tdo);   // Capture-DR
        tap_cycle(1'b0, 1'b0, tdo);   // Shift-DR
        for (int i = 0; i < len; i++) begin
            tap_cycle((i == len-1), din[i], tdo);
            dout[i] = tdo;
        end
        tap_cycle(1'b1, 1'b0, tdo);   // Update-DR
        tap_cycle(1'b0, 1'b0, tdo);   // Run-Test/Idle
        if (idle > 0) tap_idle(idle);
    endtask

    //-----------------------------------------------------------------
    // DTM registers
    //-----------------------------------------------------------------
    task automatic dtmcs_scan(input logic [31:0] w, output logic [31:0] r);
        logic [63:0] o;
        set_ir(5'h10);
        scan_dr(32, {32'd0, w}, o, 0);
        r = o[31:0];
    endtask

    task automatic dmireset();

        logic [31:0] r;
        dtmcs_scan(32'h0001_0000, r);
    endtask

    // raw dmi scan : returns the captured {addr, data, op}
    task automatic dmi_scan(input logic [1:0] op, input logic [6:0] addr, input logic [31:0] data,
                            output logic [1:0] rop, output logic [31:0] rdata, input int idle);
        logic [63:0] o;
        set_ir(5'h11);
        scan_dr(41, {23'd0, addr, data, op}, o, idle);
        rop   = o[1:0];
        rdata = o[33:2];
    endtask

    // DMI access with OpenOCD-like busy handling
    //   request scan busy : the request was dropped -> dmireset, more idle, resend
    //   result  scan busy : the request is in progress -> dmireset, wait, read again
    task automatic dmi_retry(input string name, inout int guard);
        n_busy++;
        dmireset();
        idle_cycles++;
        if (idle_cycles > idle_max) idle_max = idle_cycles;
        guard++;
        if (guard > 1000) begin
            check({name, " retry limit"}, 1'b0);
            $finish;
        end
    endtask

    task automatic e_dmi_access(input bit wr, input logic [6:0] addr, input logic [31:0] wdata,
                              output logic [31:0] rdata);

        logic [1:0]  rop;
        logic [31:0] d;
        int          guard;
        guard = 0;
        // request
        rop = 2'd3;
        while (rop != 2'd0) begin
            dmi_scan(wr ? 2'd2 : 2'd1, addr, wdata, rop, d, idle_cycles);
            if (rop != 2'd0) begin
                check("DMI request status is success or busy", rop == 2'd3);
                dmi_retry("DMI request", guard);
            end
        end
        // result (nop)
        rop = 2'd3;
        while (rop != 2'd0) begin
            dmi_scan(2'd0, 7'd0, 32'd0, rop, d, 0);
            if (rop != 2'd0) begin
                check("DMI result status is success or busy", rop == 2'd3);
                dmi_retry("DMI result", guard);
                tap_idle(idle_cycles);
            end
        end
        rdata = d;
    endtask

    logic        de_req = 1'b0, de_ack = 1'b0;
    bit          de_wr;
    logic [6:0]  de_addr;
    logic [31:0] de_wdata, de_rdata;

    initial forever begin
        wait (de_req === 1'b1);
        e_dmi_access(de_wr, de_addr, de_wdata, de_rdata);
        de_ack = 1'b1;
        wait (de_req === 1'b0);
        de_ack = 1'b0;
    end

    task automatic dmi_access(input bit wr, input logic [6:0] addr, input logic [31:0] wdata,
                              output logic [31:0] rdata);
        de_wr    = wr;
        de_addr  = addr;
        de_wdata = wdata;
        de_req   = 1'b1;
        wait (de_ack === 1'b1);
        rdata    = de_rdata;
        de_req   = 1'b0;
        wait (de_ack === 1'b0);
    endtask

    task automatic dm_write(input logic [6:0] addr, input logic [31:0] data);

        logic [31:0] r;
        dmi_access(1'b1, addr, data, r);
    endtask

    task automatic dm_read(input logic [6:0] addr, output logic [31:0] data);

        dmi_access(1'b0, addr, 32'd0, data);
    endtask

    //=================================================================
    // Debug module helpers
    //=================================================================
    task automatic dm_activate();
        logic [31:0] r;
        dm_write(DM_DMCONTROL, 32'h0000_0000);
        dm_write(DM_DMCONTROL, 32'h0000_0001);
        dm_read(DM_DMCONTROL, r);
        check32("dmcontrol.dmactive=1", 32'h1, r & 32'h1);
    endtask

    // wait until (dmstatus & mask) == value
    task automatic wait_dmstatus(input string name, input logic [31:0] mask, input logic [31:0] value);
        logic [31:0] r;
        int i;
        r = ~value & mask;
        for (i = 0; i < 200 && (r & mask) != value; i++) begin
            dm_read(DM_DMSTATUS, r);
        end
        check32(name, value, r & mask);
    endtask

    // run an abstract command and return cmderr (cmderr is cleared)
    task automatic abs_cmd(input logic [31:0] cmd, output logic [2:0] cmderr);
        logic [31:0] r;
        dm_write(DM_COMMAND, cmd);
        r = 32'h0000_1000;
        for (int i = 0; i < 100000 && r[12]; i++) begin
            dm_read(DM_ABSTRACTCS, r);
        end
        check("abstractcs.busy clears", r[12] == 1'b0);
        cmderr = r[10:8];
        if (cmderr != 0) dm_write(DM_ABSTRACTCS, 32'h0000_0700);
    endtask

    localparam logic [31:0] AR_TRANSFER = 32'h0002_0000;
    localparam logic [31:0] AR_WRITE    = 32'h0001_0000;

    task automatic reg_write(input logic [15:0] regno, input logic [63:0] val, input bit size64,
                             output logic [2:0] cmderr);

        dm_write(DM_DATA0, val[31:0]);
        if (size64) dm_write(DM_DATA1, val[63:32]);
        abs_cmd({8'd0, 1'b0, size64 ? 3'd3 : 3'd2, 4'b0011, regno}, cmderr);
    endtask

    task automatic reg_read(input logic [15:0] regno, input bit size64,
                            output logic [63:0] val, output logic [2:0] cmderr);

        logic [31:0] lo, hi;
        abs_cmd({8'd0, 1'b0, size64 ? 3'd3 : 3'd2, 4'b0010, regno}, cmderr);
        dm_read(DM_DATA0, lo);
        hi = 32'd0;
        if (size64) dm_read(DM_DATA1, hi);
        val = {hi, lo};
    endtask

    // Access Memory (size 0..3)
    task automatic amem_write(input logic [63:0] addr, input logic [2:0] size, input logic [63:0] val,
                              output logic [2:0] cmderr);
        dm_write(DM_DATA0, val[31:0]);
        dm_write(DM_DATA1, val[63:32]);
        dm_write(DM_DATA2, addr[31:0]);
        dm_write(DM_DATA3, addr[63:32]);
        abs_cmd({8'd2, 1'b0, size, 4'b0001, 16'd0}, cmderr);
    endtask

    task automatic amem_read(input logic [63:0] addr, input logic [2:0] size, output logic [63:0] val,
                             output logic [2:0] cmderr);

        logic [31:0] lo, hi;
        dm_write(DM_DATA2, addr[31:0]);
        dm_write(DM_DATA3, addr[63:32]);
        abs_cmd({8'd2, 1'b0, size, 4'b0000, 16'd0}, cmderr);
        dm_read(DM_DATA0, lo);
        dm_read(DM_DATA1, hi);
        val = {hi, lo};
    endtask

    // System Bus Access
    task automatic sba_wait(output logic [31:0] sbcs);
        sbcs = 32'h0020_0000;
        for (int i = 0; i < 100000 && sbcs[21]; i++) begin
            dm_read(DM_SBCS, sbcs);
        end
    endtask

    task automatic sba_write(input logic [39:0] addr, input logic [2:0] size, input logic [63:0] val,
                             output logic [2:0] sberror);

        logic [31:0] sbcs;
        dm_write(DM_SBCS, 32'h0040_7000 | (32'(size) << 17));
        dm_write(DM_SBADDRESS1, {24'd0, addr[39:32]});
        dm_write(DM_SBADDRESS0, addr[31:0]);
        dm_write(DM_SBDATA1, val[63:32]);
        dm_write(DM_SBDATA0, val[31:0]);
        sba_wait(sbcs);
        sberror = sbcs[14:12];
    endtask

    task automatic sba_read(input logic [39:0] addr, input logic [2:0] size, output logic [63:0] val,
                            output logic [2:0] sberror);

        logic [31:0] sbcs, lo, hi;
        dm_write(DM_SBCS, 32'h0050_7000 | (32'(size) << 17));   // readonaddr
        dm_write(DM_SBADDRESS1, {24'd0, addr[39:32]});
        dm_write(DM_SBADDRESS0, addr[31:0]);
        sba_wait(sbcs);
        sberror = sbcs[14:12];
        dm_read(DM_SBDATA1, hi);
        dm_read(DM_SBDATA0, lo);
        val = {hi, lo};
    endtask

    //=================================================================
    // Backdoor memory access
    //=================================================================
    function automatic logic [63:0] mem_peek(input logic [39:0] addr);
        logic [39:0] off;
        if (addr >= MEM_BASE) begin
            off = addr - MEM_BASE;
            return u_top.u_ram_axi4.mem[off[15:3]];
        end else begin
            off = addr - PERI_BASE;
            return u_top.u_ram_axil.mem[off[11:3]];
        end
    endfunction

    //=================================================================
    // CPU_BFM command (concurrent bus traffic)
    //=================================================================
    task automatic bfm_exec(input bit we, input bit bus, input logic [39:0] addr,
                            input logic [63:0] wdata, output logic [63:0] rdata,
                            output logic [1:0] resp);
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_we    = we;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_bus   = bus;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_addr  = addr;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_len   = 8'd0;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_wdata = wdata;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_size  = 3'd3;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_wstrb = 8'hFF;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_valid = 1'b1;
        wait (u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_done === 1'b1);
        rdata = u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        resp  = u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_valid = 1'b0;
        wait (u_top.u_cpu_top.g_bfm.u_cpu_bfm.cmd_done === 1'b0);
    endtask

    //=================================================================
    // CPU_BFM through the L1 caches (CPU_CACHE inside CPU_TOP)
    //=================================================================
    task automatic bfm_cache_exec(input logic [3:0] cmd, input logic [39:0] addr,
                                  input logic [1:0] size, input logic [63:0] wdata,
                                  output logic [63:0] rdata, output bit err);
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_cmd   = cmd;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_addr  = addr;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_size  = size;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_wdata = wdata;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_valid = 1'b1;
        wait (u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_done === 1'b1);
        rdata = u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_rdata;
        err   = u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_err;
        u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_valid = 1'b0;
        wait (u_top.u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_done === 1'b0);
    endtask

    // whitebox : is the line holding `addr` valid in the data cache?
    // (CPU_TOP defaults: 64 sets x 4 ways x 64 byte)
    localparam int DC_SETS_TB  = 64;
    localparam int DC_WAYS_TB  = 4;
    localparam int DC_BLOCK_TB = 64;
    localparam int DC_OFF_TB   = $clog2(DC_BLOCK_TB);
    localparam int DC_IDX_TB   = $clog2(DC_SETS_TB);
    localparam int DC_TAG_TB   = 40 - DC_IDX_TB - DC_OFF_TB;

    function automatic bit dc_line_present(input logic [39:0] addr);
        int idx;
        logic [DC_TAG_TB-1:0] tag;
        idx = int'(addr[DC_OFF_TB +: DC_IDX_TB]);
        tag = addr[39 -: DC_TAG_TB];
        for (int w = 0; w < DC_WAYS_TB; w++)
            if (u_top.u_cpu_top.u_cpu_cache.u_dcache.u_tag.valid_bit[idx*DC_WAYS_TB + w] &&
                (u_top.u_cpu_top.u_cpu_cache.u_dcache.u_tag.tag_mem[idx*DC_WAYS_TB + w] == tag))
                return 1'b1;
        return 1'b0;
    endfunction

    //=================================================================
    // Bus stall : the RAMs withhold AWREADY / ARREADY (sim_stall)
    //=================================================================
    task automatic bus_stall(input bit on);
        @(negedge clk100);
        u_top.u_ram_axi4.sim_stall = on;
        u_top.u_ram_axil.sim_stall = on;
    endtask

    //=================================================================
    // Tests
    //=================================================================
    `include "tb_DBG_tests.svh"

    //=================================================================
    // Watchdog
    //=================================================================
    initial begin
        #(64'd4_000_000_000_000);   // 4000 s simulated
        $display("[%0t] [FAIL] watchdog timeout", $time);
        $finish;
    end

endmodule : tb_DBG
