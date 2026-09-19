//---------------------------------------------------------------------------
// tb_DBG_tests.svh : test sequence of tb_DBG (included inside module tb_DBG)
//
//   1. TAP / IR / IDCODE / BYPASS / TRST
//   2. dtmcs
//   3. DM basic registers, dmactive
//   4. DMI busy / sticky / dmireset (slow system clock)
//   5. CDC sweep : TCK / system clock period ratio 1/50 .. 50, jitter,
//      random phase, stopped TCK
//   6. Abort robustness : dtmhardreset / TRST / Test-Logic-Reset during a
//      DMI request, system reset does not reset the DM
//   7. Run control : halt / resume / step / hartreset / ndmreset /
//      resethaltreq / hartsel
//   8. Abstract command : Access Register
//   9. Abstract command : Access Memory
//  10. System Bus Access
//  11. Bus error paths : DECERR, alignment, busy, timeout, ndmreset
//  12. Concurrent CPU_BFM and debug bus traffic
//  13. Authentication
//  14. cJTAG : activation, OScan1 access, CDC, escapes, worst-case edge
//      alignment, mode switching
//---------------------------------------------------------------------------

    // shared variables
    logic [31:0] r32, w32;
    logic [63:0] r64, w64;
    logic [4:0]  cap5;
    logic [2:0]  err3;
    logic [1:0]  rop;
    logic [63:0] dout;
    logic [31:0] shadow [0:3];
    int          from_sec;
    int          to_sec;

    //-----------------------------------------------------------------
    // random DMI register traffic with shadow check (data0-3, sbaddress0)
    //-----------------------------------------------------------------
    task automatic dmi_stress(input string name, input int n, input bit gaps);
        logic [31:0] v, r;
        int k;
        int errs;
        errs = n_error;
        for (int i = 0; i < 4; i++) begin
            v = $urandom;
            dm_write(DM_DATA0 + 7'(i), v);
            shadow[i] = v;
        end
        for (int i = 0; i < n; i++) begin
            k = $urandom_range(0, 3);
            if ($urandom_range(0, 1)) begin
                v = $urandom;
                dm_write(DM_DATA0 + 7'(k), v);
                shadow[k] = v;
            end else begin
                dm_read(DM_DATA0 + 7'(k), r);
                check32({name, " data read"}, shadow[k], r);
            end
            if (gaps && $urandom_range(0, 9) == 0) begin
                int unsigned gap;
                gap = $urandom_range(1, 200000);
                #(gap);                              // TCK stopped
            end
        end
        if (n_error == errs) ok({name});
    endtask

    //-----------------------------------------------------------------
    // JTAG basic checks (used in JTAG and cJTAG mode)
    //-----------------------------------------------------------------
    task automatic tap_basic(input string mode);
        logic [63:0] o;
        // IDCODE is the reset instruction
        tap_reset();
        scan_dr(32, 64'd0, o, 0);
        check32({mode, " IDCODE after TLR"}, IDCODE, o[31:0]);
        // IR capture value
        scan_ir(5'h01, cap5);
        check32({mode, " IR capture = 00001"}, 32'h01, {27'd0, cap5});
        scan_dr(32, 64'd0, o, 0);
        check32({mode, " IDCODE (IR=0x01)"}, IDCODE, o[31:0]);
        // BYPASS : 1-bit delay
        for (int j = 0; j < 3; j++) begin
            scan_ir(bypass_irs(j), cap5);
            scan_dr(16, 64'h0000_0000_0000_A5C3, o, 0);
            check32($sformatf("%s BYPASS IR=0x%02h", mode, bypass_irs(j)),
                    32'h0000_4B86, o[15:0] & 16'hFFFF);
        end
        cur_ir = 5'h1f;
    endtask

    function automatic logic [4:0] bypass_irs(input int j);
        case (j) 0: return 5'h1f; 1: return 5'h00; default: return 5'h05; endcase
    endfunction

    //-----------------------------------------------------------------
    // Main sequence
    //-----------------------------------------------------------------
    initial begin : main
        $display("==========================================================");
        $display(" tb_DBG : mmRISC-2 debug logic verification");
        $display("==========================================================");

        // wait for power-on reset
        wait (u_top.rst_dbg_n === 1'b1);
        wait (u_top.rst_n === 1'b1);
        repeat (10) @(posedge clk100);

        //=============================================================
        if (!$value$plusargs("from=%d", from_sec)) from_sec = 1;
        if (!$value$plusargs("to=%d", to_sec)) to_sec = 99;
        if (from_sec > 3) begin
            tap_reset();
            dm_activate();
        end

        section("1. TAP / IR / IDCODE / BYPASS / TRST");
        //=============================================================
        if (from_sec <= 1 && 1 <= to_sec) begin
            int e0;
            e0 = n_error;
            tap_basic("JTAG");
            // TRST
            scan_ir(5'h10, cap5);
            ja_trstn = 1'b0;
            #(200);
            ja_trstn = 1'b1;
            tap_idle(4);     // TRST deassertion is synchronized to TCK
            cur_ir = 5'h01;
            scan_dr(32, 64'd0, dout, 0);
            check32("IDCODE after TRST", IDCODE, dout[31:0]);
            check("TDO is released outside Shift states", ja_tdo === 1'bz);
            if (n_error == e0) ok("TAP state machine, IR, IDCODE, BYPASS, TRST");
        end

        //=============================================================
        section("2. dtmcs");
        //=============================================================
        if (from_sec <= 2 && 2 <= to_sec) begin
            int e0;
            e0 = n_error;
            dtmcs_scan(32'd0, r32);
            check32("dtmcs.version", 32'd1, r32[3:0]);
            check32("dtmcs.abits",   32'd7, r32[9:4]);
            check32("dtmcs.dmistat", 32'd0, r32[11:10]);
            check32("dtmcs.idle",    32'd1, r32[14:12]);
            check32("dtmcs.errinfo", 32'd4, r32[20:18]);
            check32("dtmcs reserved bits", 32'd0, r32 & 32'hFFE0_8000);
            if (n_error == e0) ok("dtmcs fields (version 1, abits 7, idle 1, errinfo 4)");
        end

        //=============================================================
        section("3. DM basic registers");
        //=============================================================
        if (from_sec <= 3 && 3 <= to_sec) begin
            int e0;
            e0 = n_error;
            dm_read(DM_DMCONTROL, r32);
            check32("dmactive=0 after POR", 32'd0, r32);
            dm_write(DM_DATA0, 32'h1234_5678);          // ignored while inactive
            dm_activate();
            dm_read(DM_DATA0, r32);
            check32("data0 write ignored while dmactive=0", 32'd0, r32);
            dm_read(DM_DMSTATUS, r32);
            check32("dmstatus.version=3",        32'd3, r32[3:0]);
            check32("dmstatus.authenticated=1",  32'd1, r32[7]);
            check32("dmstatus.hasresethaltreq=1",32'd1, r32[5]);
            check32("dmstatus.allrunning=1",     32'd1, r32[11]);
            check32("dmstatus.impebreak=0",      32'd0, r32[22]);
            dm_read(DM_HARTINFO, r32);
            check32("hartinfo=0", 32'd0, r32);
            dm_read(DM_ABSTRACTCS, r32);
            check32("abstractcs.datacount=4",   32'd4, r32[3:0]);
            check32("abstractcs.progbufsize=0", 32'd0, r32[28:24]);
            dm_read(DM_SBCS, r32);
            check32("sbcs.sbversion=1", 32'd1, r32[31:29]);
            check32("sbcs.sbasize=40",  32'd40, r32[11:5]);
            check32("sbcs.sbaccess8-64", 32'hF, r32[4:0]);
            check32("sbcs.sbaccess reset=2", 32'd2, r32[19:17]);
            // data0-3 read / write, data4 / progbuf0 not present
            for (int i = 0; i < 4; i++) dm_write(DM_DATA0 + 7'(i), 32'hA5A5_0000 | i);
            for (int i = 0; i < 4; i++) begin
                dm_read(DM_DATA0 + 7'(i), r32);
                check32($sformatf("data%0d", i), 32'hA5A5_0000 | i, r32);
            end
            dm_write(DM_DATA4, 32'hFFFF_FFFF);
            dm_read(DM_DATA4, r32);
            check32("data4 not present", 32'd0, r32);
            dm_write(DM_PROGBUF0, 32'hFFFF_FFFF);
            dm_read(DM_PROGBUF0, r32);
            check32("progbuf0 not present", 32'd0, r32);
            dm_write(DM_ABSTRACTAUTO, 32'hFFFF_FFFF);
            dm_read(DM_ABSTRACTAUTO, r32);
            check32("abstractauto: autoexecdata[3:0] only", 32'h0000_000F, r32);
            dm_write(DM_ABSTRACTAUTO, 32'd0);
            // hartsel length
            dm_write(DM_DMCONTROL, 32'h03FF_FFC1);
            dm_read(DM_DMCONTROL, r32);
            check32("hartsel: HARTSELLEN=1", 32'h0001_0001, r32);
            dm_read(DM_DMSTATUS, r32);
            check32("hartsel=1 : all/anynonexistent", 32'h0000_C000, r32 & 32'h000F_FF00);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            dm_read(DM_DMSTATUS, r32);
            check32("hartsel=0 : exists, running", 32'h0000_0C00, r32 & 32'h0000_FF00);
            // dmactive=0 clears DM state
            dm_write(DM_DATA1, 32'h5555_AAAA);
            dm_write(DM_DMCONTROL, 32'h0000_0000);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            dm_read(DM_DATA1, r32);
            check32("dmactive=0 resets data1", 32'd0, r32);
            if (n_error == e0) ok("DM registers, hartsel, dmactive reset");
        end

        //=============================================================
        section("4. DMI busy / sticky / dmireset");
        //=============================================================
        if (from_sec <= 4 && 4 <= to_sec) begin
            int e0;
            real save;
            e0 = n_error;
            save = sys_half;
            sys_half = 5000.0;            // very slow system clock (100kHz)
            tck_half = 5.0;               // fast TCK (100MHz)
            repeat (2) @(posedge clk100);
            dmi_scan(2'd2, DM_DATA2, 32'hCAFE_0001, rop, r32, 0);   // write request
            check32("request accepted (op=0)", 32'd0, rop);
            dmi_scan(2'd0, 7'd0, 32'd0, rop, r32, 0);               // too early
            check32("result busy (op=3)", 32'd3, rop);
            dmi_scan(2'd1, DM_DATA3, 32'd0, rop, r32, 0);           // ignored (sticky)
            check32("op sticky busy", 32'd3, rop);
            dtmcs_scan(32'd0, r32);
            check32("dtmcs.dmistat=3", 32'd3, r32[11:10]);
            for (int t = 0; t < 40; t++) begin tap_idle(2); #(10000); end   // let it finish
            dmi_scan(2'd0, 7'd0, 32'd0, rop, r32, 0);
            check32("still sticky after completion", 32'd3, rop);
            dmireset();
            dtmcs_scan(32'd0, r32);
            check32("dmireset clears dmistat", 32'd0, r32[11:10]);
            dmi_scan(2'd1, DM_DATA2, 32'd0, rop, r32, 0);
            // the TCK side needs TCK edges to raise a pending request and to
            // synchronize the ack, so keep TCK running while waiting
            for (int t = 0; t < 40; t++) begin tap_idle(2); #(10000); end
            dmi_scan(2'd0, 7'd0, 32'd0, rop, r32, 0);
            check32("op=0 after wait", 32'd0, rop);
            check32("sticky write was executed once", 32'hCAFE_0001, r32);
            // automatic retry
            idle_cycles = 0;
            n_busy = 0;
            dmi_stress("busy retry with slow system clock", 20, 0);
            check("busy responses were observed", n_busy > 0);
            $display("[%0t]        busy responses=%0d, idle cycles grown to %0d", $time, n_busy, idle_cycles);
            sys_half = save;
            tck_half = 50.0;
            idle_cycles = 1;
            if (n_error == e0) ok("DMI busy, sticky op, dmireset, retry");
        end

        //=============================================================
        section("5. CDC sweep (JTAG)");
        //=============================================================
        if (from_sec <= 5 && 5 <= to_sec) begin
            for (int i = 0; i < 12; i++) begin
                sys_half = 10.0;
                tck_half = 10.0 * ratios(i);
                tck_jitter = (i % 3 == 2) ? 0.4 : 0.0;
                idle_cycles = 1;
                begin
                    int unsigned ph;
                    ph = $urandom_range(0, 97);
                    #(ph);                             // random phase
                end
                n_busy = 0;
                dmi_stress($sformatf("TCK/sys period ratio %0.3f%s", ratios(i),
                                     tck_jitter != 0.0 ? " (jitter 40%)" : ""), 40, 1);
                $display("[%0t]        busy=%0d idle=%0d", $time, n_busy, idle_cycles);
            end
            // fast system clock, very slow TCK and vice versa
            sys_half = 1.0;   tck_half = 1000.0; idle_cycles = 1;
            dmi_stress("sys 500MHz / TCK 500kHz (ratio 1000)", 10, 1);
            sys_half = 200.0; tck_half = 0.5;    idle_cycles = 0;
            dmi_stress("sys 2.5MHz / TCK 1GHz (ratio 1/400)", 10, 0);
            sys_half = 10.0;  tck_half = 50.0;   tck_jitter = 0.0; idle_cycles = 1;
        end

        //=============================================================
        section("6. Abort robustness");
        //=============================================================
        if (from_sec <= 6 && 6 <= to_sec) begin
            int e0;
            e0 = n_error;
            for (int mode = 0; mode < 3; mode++) begin
                sys_half = 3000.0;         // slow system clock : request in flight
                tck_half = 5.0;
                dm_write(DM_DATA2, 32'h0000_1111);
                dmi_scan(2'd2, DM_DATA2, 32'h0000_2222, rop, r32, 0);
                case (mode)
                    0: dtmcs_scan(32'h0002_0000, r32);           // dtmhardreset
                    1: begin                                     // TRST
                           ja_trstn = 1'b0; #(20); ja_trstn = 1'b1;
                           tap_idle(3); cur_ir = 5'h01;
                       end
                    default: tap_reset();                        // Test-Logic-Reset
                endcase
                // immediately try again (DM still busy with the old request)
                idle_cycles = 0;
                dm_read(DM_DATA2, r32);
                check(($sformatf("abort mode %0d : old value or new value", mode)),
                      r32 == 32'h0000_1111 || r32 == 32'h0000_2222);
                dm_write(DM_DATA2, 32'h0000_3333);
                dm_read(DM_DATA2, r32);
                check32($sformatf("abort mode %0d : access works afterwards", mode), 32'h0000_3333, r32);
                sys_half = 10.0;
                tck_half = 50.0;
                idle_cycles = 1;
                dmi_stress($sformatf("abort mode %0d : traffic after abort", mode), 20, 0);
            end
            // system reset does not reset the DM
            dm_write(DM_DATA3, 32'h7777_8888);
            cpu_resetn = 1'b0;
            repeat (20) @(posedge clk100);
            cpu_resetn = 1'b1;
            repeat (20) @(posedge clk100);
            dm_read(DM_DATA3, r32);
            check32("system reset keeps DM state", 32'h7777_8888, r32);
            dm_read(DM_DMCONTROL, r32);
            check32("system reset keeps dmactive", 32'd1, r32[0]);
            if (n_error == e0) ok("dtmhardreset / TRST / TLR abort, system reset isolation");
        end

        //=============================================================
        section("7. Run control");
        //=============================================================
        if (from_sec <= 7 && 7 <= to_sec) begin
            int e0;
            e0 = n_error;
            dm_write(DM_DMCONTROL, 32'h1000_0001);     // ackhavereset
            wait_dmstatus("havereset cleared", 32'h000C_0000, 32'h0);
            // halt
            dm_write(DM_DMCONTROL, 32'h8000_0001);
            wait_dmstatus("halt : allhalted/anyhalted", 32'h0000_0F00, 32'h0000_0300);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            dm_read(DM_HALTSUM0, r32);
            check32("haltsum0", 32'd1, r32);
            check("LED halted", led[4] === 1'b1 && led[5] === 1'b0);
            reg_read(16'h07B0, 1'b0, r64, err3);
            check32("dcsr.debugver=4", 32'd4, r64[31:28]);
            check32("dcsr.cause=3 (haltreq)", 32'd3, r64[8:6]);
            check32("dcsr.prv=3", 32'd3, r64[1:0]);
            // resume
            dm_write(DM_DMCONTROL, 32'h4000_0001);
            wait_dmstatus("resume : allresumeack, allrunning", 32'h0003_0F00, 32'h0003_0C00);
            // resumereq ignored while running (resumeack stays)
            // step
            dm_write(DM_DMCONTROL, 32'h8000_0001);
            wait_dmstatus("halt again", 32'h0000_0300, 32'h0000_0300);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            reg_write(16'h07B1, 64'h0000_0000_8000_1000, 1'b1, err3);   // dpc
            reg_write(16'h07B0, 64'h4000_0007, 1'b0, err3);             // step=1 prv=3
            dm_write(DM_DMCONTROL, 32'h4000_0001);
            wait_dmstatus("step : resumeack and halted", 32'h0003_0300, 32'h0003_0300);
            reg_read(16'h07B0, 1'b0, r64, err3);
            check32("dcsr.cause=4 (step)", 32'd4, r64[8:6]);
            reg_read(16'h07B1, 1'b1, r64, err3);
            check64("dpc += 4 after step", 64'h8000_1004, r64);
            reg_write(16'h07B0, 64'h4000_0003, 1'b0, err3);             // step=0
            dm_write(DM_DMCONTROL, 32'h4000_0001);
            wait_dmstatus("running after step cleared", 32'h0000_0C00, 32'h0000_0C00);
            // ndmreset
            dm_write(DM_DMCONTROL, 32'h0000_0003);
            wait_dmstatus("ndmreset : ndmresetpending, unavail, havereset",
                          32'h010C_3000, 32'h010C_3000);
            check("ndmreset output", u_top.ndmreset === 1'b1 && u_top.rst_bus_n === 1'b0);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            wait_dmstatus("ndmreset released : running, havereset kept",
                          32'h010C_3F00, 32'h000C_0C00);
            dm_write(DM_DMCONTROL, 32'h1000_0001);
            wait_dmstatus("ackhavereset", 32'h000C_0000, 32'h0);
            // resethaltreq + ndmreset
            dm_write(DM_DMCONTROL, 32'h0000_0009);                      // setresethaltreq
            dm_write(DM_DMCONTROL, 32'h0000_0003);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            wait_dmstatus("reset halt : halted", 32'h0000_0300, 32'h0000_0300);
            reg_read(16'h07B0, 1'b0, r64, err3);
            check32("dcsr.cause=5 (resethaltreq)", 32'd5, r64[8:6]);
            reg_read(16'h07B1, 1'b1, r64, err3);
            check64("dpc = reset vector", 64'h8000_0000, r64);
            dm_write(DM_DMCONTROL, 32'h0000_0005);                      // clrresethaltreq
            // hartreset
            dm_write(DM_DMCONTROL, 32'h2000_0001);
            wait_dmstatus("hartreset : unavail", 32'h0000_3000, 32'h0000_3000);
            dm_read(DM_DMCONTROL, r32);
            check32("dmcontrol.hartreset readback", 32'h2000_0001, r32);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            wait_dmstatus("hartreset released : running (resethaltreq cleared)",
                          32'h0000_3F00, 32'h0000_0C00);
            dm_write(DM_DMCONTROL, 32'h1000_0001);
            if (n_error == e0) ok("halt, resume, step, ndmreset, resethaltreq, hartreset");
        end

        //=============================================================
        section("8. Access Register");
        //=============================================================
        if (from_sec <= 8 && 8 <= to_sec) begin
            int e0;
            logic [63:0] gv [0:63];
            e0 = n_error;
            // running -> cmderr 4
            reg_read(16'h1001, 1'b1, r64, err3);
            check32("Access Register while running : cmderr=4", 32'd4, err3);
            dm_write(DM_DMCONTROL, 32'h8000_0001);
            wait_dmstatus("halted", 32'h0000_0300, 32'h0000_0300);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            // GPR / FPR 64-bit
            for (int i = 0; i < 64; i++) begin
                gv[i] = {$urandom, $urandom};
                reg_write(16'h1000 + 16'(i), gv[i], 1'b1, err3);
                check32($sformatf("write reg 0x%04h cmderr", 16'h1000 + i), 32'd0, err3);
            end
            for (int i = 0; i < 64; i++) begin
                reg_read(16'h1000 + 16'(i), 1'b1, r64, err3);
                check64($sformatf("read reg 0x%04h", 16'h1000 + i), (i == 0) ? 64'd0 : gv[i], r64);
            end
            // 32-bit access
            reg_write(16'h1005, 64'h0000_0000_1357_9BDF, 1'b0, err3);
            reg_read(16'h1005, 1'b1, r64, err3);
            check64("32-bit write keeps upper half", {gv[5][63:32], 32'h1357_9BDF}, r64);
            reg_read(16'h1005, 1'b0, r64, err3);
            check64("32-bit read", 64'h1357_9BDF, r64);
            // CSRs
            reg_read(16'h0301, 1'b1, r64, err3);  check64("misa", 64'h8000_0000_0014_112d, r64);
            reg_read(16'h0F11, 1'b0, r64, err3);  check64("mvendorid", 64'd0, r64);
            reg_read(16'h0F12, 1'b1, r64, err3);  check64("marchid", 64'h6d6d_3032, r64);
            reg_read(16'h0F13, 1'b1, r64, err3);  check64("mimpl", 64'd1, r64);
            reg_read(16'h0F14, 1'b1, r64, err3);  check64("mhartid", 64'd0, r64);
            reg_write(16'h0F12, 64'd5, 1'b1, err3);
            check32("write read-only marchid : cmderr=3", 32'd3, err3);
            reg_write(16'h0300, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, err3);
            reg_read(16'h0300, 1'b1, r64, err3);
            check64("mstatus WARL", 64'h8000_000A_007E_79AA, r64);
            reg_read(16'h0100, 1'b1, r64, err3);
            check64("sstatus view", 64'h8000_0002_000C_6122, r64);
            for (int j = 0; j < 15; j++) begin
                reg_write(csr_rw(j), 64'h0123_4567_89AB_CDEE, 1'b1, err3);
                check32($sformatf("write CSR 0x%03h cmderr", csr_rw(j)), 32'd0, err3);
                reg_read(csr_rw(j), 1'b1, r64, err3);
                check64($sformatf("read CSR 0x%03h", csr_rw(j)), 64'h0123_4567_89AB_CDEE & csr_mask(j), r64);
            end
            reg_write(16'h0003, 64'hFF, 1'b0, err3);
            reg_read(16'h0001, 1'b0, r64, err3);  check64("fflags from fcsr", 64'h1F, r64);
            reg_read(16'h0002, 1'b0, r64, err3);  check64("frm from fcsr", 64'h7, r64);
            // errors
            reg_read(16'h07A0, 1'b1, r64, err3);
            check32("tselect not present : cmderr=3", 32'd3, err3);
            reg_read(16'h0C00, 1'b1, r64, err3);
            check32("unknown CSR : cmderr=3", 32'd3, err3);
            abs_cmd({8'd0, 1'b0, 3'd4, 4'b0010, 16'h1001}, err3);
            check32("aarsize=4 : cmderr=2", 32'd2, err3);
            abs_cmd({8'd0, 1'b0, 3'd3, 4'b0110, 16'h1001}, err3);
            check32("postexec : cmderr=2", 32'd2, err3);
            abs_cmd({8'd1, 24'd0}, err3);
            check32("Quick Access : cmderr=2", 32'd2, err3);
            abs_cmd({8'd9, 24'd0}, err3);
            check32("unknown cmdtype : cmderr=2", 32'd2, err3);
            // cmderr blocks commands until cleared
            dm_write(DM_COMMAND, {8'd1, 24'd0});
            dm_write(DM_DATA0, 32'h1111_2222);
            dm_write(DM_COMMAND, {8'd0, 1'b0, 3'd2, 4'b0011, 16'h1006});
            dm_read(DM_ABSTRACTCS, r32);
            check32("cmderr remains 2", 32'd2, r32[10:8]);
            dm_write(DM_ABSTRACTCS, 32'h0000_0200);
            dm_read(DM_ABSTRACTCS, r32);
            check32("cmderr W1C", 32'd0, r32[10:8]);
            reg_read(16'h1006, 1'b1, r64, err3);
            check64("command ignored while cmderr!=0", gv[6], r64);
            // postincrement + abstractauto : read x1..x8
            dm_write(DM_ABSTRACTAUTO, 32'h1);
            abs_cmd({8'd0, 1'b0, 3'd3, 4'b1010, 16'h1001}, err3);    // read x1, regno++
            for (int i = 1; i <= 8; i++) begin
                dm_read(DM_DATA1, r32);                                // no autoexec
                dm_read(DM_DATA0, w32);                                // autoexec -> next
                if (i != 5) check64($sformatf("autoexec postincrement x%0d", i), gv[i], {r32, w32});
                r32 = 32'h0000_1000;
                for (int t = 0; t < 10 && r32[12]; t++) begin
                    dm_read(DM_ABSTRACTCS, r32);
                end
            end
            dm_write(DM_ABSTRACTAUTO, 32'h0);
            dm_read(DM_COMMAND, r32);
            check32("command reads 0", 32'd0, r32);
            if (n_error == e0) ok("GPR/FPR/CSR access, WARL, cmderr 2/3/4, postincrement, autoexec");
        end

        //=============================================================
        section("9. Access Memory");
        //=============================================================
        if (from_sec <= 9 && 9 <= to_sec) begin
            int e0;
            logic [39:0] a;
            e0 = n_error;
            for (int b = 0; b < 2; b++) begin
                for (int sz = 0; sz < 4; sz++) begin
                    for (int k = 0; k < 4; k++) begin
                        a = test_bases(b) + 40'(8 * (sz * 4 + k)) + 40'($urandom_range(0, 7) & ~((1 << sz) - 1));
                        w64 = {$urandom, $urandom};
                        r64 = mem_peek(a);
                        amem_write({24'd0, a}, 3'(sz), w64, err3);
                        check32($sformatf("amem write size%0d cmderr", sz), 32'd0, err3);
                        for (int j = 0; j < (1 << sz); j++) begin
                            logic [39:0] aj;
                            aj = a + 40'(j);
                            r64[8*aj[2:0] +: 8] = w64[8*j +: 8];
                        end
                        check64($sformatf("amem write size%0d @0x%010h backdoor", sz, a),
                                r64, mem_peek(a));
                        amem_read({24'd0, a}, 3'(sz), r64, err3);
                        check32($sformatf("amem read size%0d cmderr", sz), 32'd0, err3);
                        check64($sformatf("amem read size%0d @0x%010h", sz, a),
                                w64 & ((sz == 3) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << (8 << sz)) - 1)), r64);
                    end
                end
            end
            // block write with postincrement + autoexec data0 (32-bit)
            dm_write(DM_DATA2, 32'h8000_4000);
            dm_write(DM_DATA3, 32'h0);
            dm_write(DM_DATA0, 32'h0BAD_0000);
            abs_cmd({8'd2, 1'b0, 3'd2, 4'b1001, 16'd0}, err3);
            dm_write(DM_ABSTRACTAUTO, 32'h1);
            for (int i = 1; i < 16; i++) dm_write(DM_DATA0, 32'h0BAD_0000 + i);
            dm_write(DM_ABSTRACTAUTO, 32'h0);
            dm_read(DM_ABSTRACTCS, r32);
            check32("block write cmderr", 32'd0, r32[10:8]);
            for (int i = 0; i < 16; i++)
                check32($sformatf("block write word %0d", i), 32'h0BAD_0000 + i,
                        mem_peek(40'h8000_4000 + 40'(4 * i)) >> ((i % 2) * 32));
            dm_read(DM_DATA2, r32);
            check32("postincrement address", 32'h8000_4040, r32);
            // running hart is allowed
            dm_write(DM_DMCONTROL, 32'h4000_0001);
            wait_dmstatus("running", 32'h0000_0C00, 32'h0000_0C00);
            amem_write(64'h8000_5000, 3'd3, 64'hFEED_FACE_DEAD_BEEF, err3);
            check32("amem while running", 32'd0, err3);
            check64("amem while running backdoor", 64'hFEED_FACE_DEAD_BEEF, mem_peek(40'h00_8000_5000));
            // errors
            amem_read(64'h8000_5001, 3'd2, r64, err3);
            check32("unaligned : cmderr=5", 32'd5, err3);
            amem_read(64'h0000_0001_8000_0000, 3'd3, r64, err3);
            check32("upper address bits (DECERR) : cmderr=5", 32'd5, err3);
            amem_read(64'h0000_0100_0000_0000, 3'd3, r64, err3);
            check32("address beyond 40 bits : cmderr=5", 32'd5, err3);
            amem_read(64'h0000_0000_9000_0000, 3'd3, r64, err3);
            check32("outside RAM (DECERR) : cmderr=5", 32'd5, err3);
            abs_cmd({8'd2, 1'b1, 3'd3, 20'd0}, err3);
            check32("aamvirtual : cmderr=2", 32'd2, err3);
            abs_cmd({8'd2, 1'b0, 3'd4, 20'd0}, err3);
            check32("aamsize=4 : cmderr=2", 32'd2, err3);
            if (n_error == e0) ok("Access Memory 8/16/32/64-bit on both buses, block write, errors");
        end

        //=============================================================
        section("10. System Bus Access");
        //=============================================================
        if (from_sec <= 10 && 10 <= to_sec) begin
            int e0;
            logic [39:0] a;
            e0 = n_error;
            for (int b = 0; b < 2; b++) begin
                for (int sz = 0; sz < 4; sz++) begin
                    for (int k = 0; k < 4; k++) begin
                        a = test_bases(b) + 40'h400 + 40'(8 * (sz * 4 + k)) + 40'($urandom_range(0, 7) & ~((1 << sz) - 1));
                        w64 = {$urandom, $urandom};
                        r64 = mem_peek(a);
                        sba_write(a, 3'(sz), w64, err3);
                        check32($sformatf("sba write size%0d sberror", sz), 32'd0, err3);
                        for (int j = 0; j < (1 << sz); j++) begin
                            logic [39:0] aj;
                            aj = a + 40'(j);
                            r64[8*aj[2:0] +: 8] = w64[8*j +: 8];
                        end
                        check64($sformatf("sba write size%0d @0x%010h backdoor", sz, a), r64, mem_peek(a));
                        sba_read(a, 3'(sz), r64, err3);
                        check32($sformatf("sba read size%0d sberror", sz), 32'd0, err3);
                        check64($sformatf("sba read size%0d @0x%010h", sz, a),
                                w64 & ((sz == 3) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << (8 << sz)) - 1)), r64);
                    end
                end
            end
            // block write with autoincrement, block read with readondata
            dm_write(DM_SBCS, 32'h0045_7000);                 // 32-bit, autoincrement
            dm_write(DM_SBADDRESS1, 32'h0);
            dm_write(DM_SBADDRESS0, 32'h1200_0200);
            for (int i = 0; i < 32; i++) dm_write(DM_SBDATA0, 32'hC0DE_0000 + i);
            dm_read(DM_SBADDRESS0, r32);
            check32("autoincrement address", 32'h1200_0280, r32);
            dm_write(DM_SBCS, 32'h0055_F000);                 // readonaddr readondata autoinc
            dm_write(DM_SBADDRESS0, 32'h1200_0200);
            for (int i = 0; i < 32; i++) begin
                dm_read(DM_SBDATA0, r32);
                check32($sformatf("readondata word %0d", i), 32'hC0DE_0000 + i, r32);
            end
            dm_read(DM_SBCS, r32);
            check32("block access sberror", 32'd0, r32[14:12]);
            if (n_error == e0) ok("SBA 8/16/32/64-bit on both buses, autoincrement, readonaddr/readondata");
        end

        //=============================================================
        section("11. Bus error paths");
        //=============================================================
        if (from_sec <= 11 && 11 <= to_sec) begin
            int e0;
            e0 = n_error;
            sba_read(40'h01_8000_0000, 3'd3, r64, err3);
            check32("SBA upper address bits : sberror=2 (DECERR)", 32'd2, err3);
            dm_write(DM_SBCS, 32'h0040_7000);
            sba_read(40'h00_1200_2000, 3'd3, r64, err3);
            check32("SBA outside peripheral RAM : sberror=2", 32'd2, err3);
            dm_write(DM_SBCS, 32'h0040_7000);
            w64 = mem_peek(40'h00_8000_6100);
            sba_write(40'h01_8000_6100, 3'd3, ~w64, err3);
            check32("SBA write upper address bits : sberror=2", 32'd2, err3);
            check64("DECERR write does not alias into RAM", w64, mem_peek(40'h00_8000_6100));
            dm_write(DM_SBCS, 32'h0040_7000);
            w64 = mem_peek(40'h00_1200_0100);
            sba_write(40'h01_1200_0100, 3'd3, ~w64, err3);
            check32("SBA write upper address bits (peripheral) : sberror=2", 32'd2, err3);
            check64("DECERR write does not alias into peripheral RAM", w64, mem_peek(40'h00_1200_0100));
            dm_write(DM_SBCS, 32'h0040_7000);
            sba_read(40'h00_8000_0002, 3'd2, r64, err3);
            check32("SBA unaligned : sberror=3", 32'd3, err3);
            dm_write(DM_SBCS, 32'h0040_7000);
            sba_write(40'h00_8000_0000, 3'd4, 64'd0, err3);
            check32("SBA sbaccess=128 : sberror=4", 32'd4, err3);
            // sberror blocks access until cleared
            dm_write(DM_SBCS, 32'h0006_0000);                 // 64-bit, sberror not cleared
            dm_write(DM_SBADDRESS0, 32'h8000_6000);
            dm_write(DM_SBDATA0, 32'h1);
            check64("no access while sberror!=0", 64'd0, mem_peek(40'h00_8000_6000));
            dm_write(DM_SBCS, 32'h0046_7000);
            dm_read(DM_SBCS, r32);
            check32("sberror W1C", 32'd0, r32[14:12]);
            // busy : stall the bus
            bus_stall(1);
            dm_write(DM_SBCS, 32'h0046_7000);
            dm_write(DM_SBADDRESS0, 32'h8000_6000);
            dm_write(DM_SBDATA0, 32'hABCD);                   // starts, stalls
            dm_read(DM_SBCS, r32);
            check32("sbbusy while stalled", 32'd1, r32[21]);
            dm_write(DM_SBADDRESS0, 32'h8000_6008);
            dm_read(DM_SBCS, r32);
            check32("sbbusyerror on write while busy", 32'd1, r32[22]);
            // Access Memory while SBA is stalled : busy, cmderr=1 on data write
            dm_write(DM_DATA2, 32'h8000_6010);
            dm_write(DM_DATA3, 32'h0);
            dm_write(DM_COMMAND, {8'd2, 1'b0, 3'd3, 20'd0});
            dm_read(DM_ABSTRACTCS, r32);
            check32("abstract command busy behind stalled SBA", 32'd1, r32[12]);
            dm_write(DM_DATA0, 32'h1);
            dm_read(DM_ABSTRACTCS, r32);
            check32("cmderr=1 on data write while busy", 32'd1, r32[10:8]);
            dm_write(DM_COMMAND, {8'd2, 1'b0, 3'd3, 20'd0});
            // timeout (SBA_TIMEOUT clk cycles)
            repeat (SBA_TIMEOUT + 100) @(posedge clk100);
            dm_read(DM_SBCS, r32);
            check32("SBA timeout : sberror=1", 32'd1, r32[14:12]);
            check32("SBA timeout : sbbusy=0", 32'd0, r32[21]);
            repeat (SBA_TIMEOUT + 100) @(posedge clk100);
            dm_read(DM_ABSTRACTCS, r32);
            check32("Access Memory timeout : cmderr=5", 32'd5, r32[10:8]);
            check32("Access Memory timeout : not busy", 32'd0, r32[12]);
            bus_stall(0);
            repeat (100) @(posedge clk100);
            dm_write(DM_ABSTRACTCS, 32'h0000_0700);
            dm_write(DM_SBCS, 32'h0046_7000);
            sba_write(40'h00_8000_6000, 3'd3, 64'h1122_3344_5566_7788, err3);
            check32("SBA works after timeout", 32'd0, err3);
            check64("SBA after timeout backdoor", 64'h1122_3344_5566_7788, mem_peek(40'h00_8000_6000));
            // ndmreset during a stalled SBA
            bus_stall(1);
            dm_write(DM_SBCS, 32'h0046_7000);
            dm_write(DM_SBDATA0, 32'h9);
            dm_write(DM_DMCONTROL, 32'h0000_0003);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            bus_stall(0);
            sba_wait(r32);
            check32("SBA aborted by ndmreset : sberror=1", 32'd1, r32[14:12]);
            repeat (100) @(posedge clk100);
            sba_write(40'h00_8000_6000, 3'd3, 64'h8877_6655_4433_2211, err3);
            check32("SBA works after ndmreset", 32'd0, err3);
            check64("SBA after ndmreset backdoor", 64'h8877_6655_4433_2211, mem_peek(40'h00_8000_6000));
            dm_write(DM_DMCONTROL, 32'h1000_0001);
            if (n_error == e0) ok("DECERR, alignment, size, sbbusyerror, cmderr=1, timeout, ndmreset abort");
        end

        //=============================================================
        section("12. Concurrent CPU_BFM and debug bus traffic");
        //=============================================================
        if (from_sec <= 12 && 12 <= to_sec) begin
            int e0;
            e0 = n_error;
            fork
                begin : bfm_side
                    logic [63:0] rd, v;
                    logic [1:0]  resp;
                    for (int i = 0; i < 200; i++) begin
                        v = {32'hBF00_0000 | i, 32'h0};
                        bfm_exec(1'b1, i[0], (i[0] ? 40'h00_1200_0800 : 40'h00_8000_8000) + 40'(8 * (i % 16)), v, rd, resp);
                        check32("BFM write resp", 32'd0, resp);
                        bfm_exec(1'b0, i[0], (i[0] ? 40'h00_1200_0800 : 40'h00_8000_8000) + 40'(8 * (i % 16)), 64'd0, rd, resp);
                        check64("BFM read back", v, rd);
                    end
                end
                begin : dbg_side
                    for (int i = 0; i < 20; i++) begin
                        w64 = {$urandom, $urandom};
                        sba_write(i[0] ? 40'h00_1200_0C00 : 40'h00_8000_9000, 3'd3, w64, err3);
                        check32("SBA sberror (concurrent)", 32'd0, err3);
                        sba_read(i[0] ? 40'h00_1200_0C00 : 40'h00_8000_9000, 3'd3, r64, err3);
                        check64("SBA read back (concurrent)", w64, r64);
                        dm_write(DM_SBCS, 32'h0040_7000);
                    end
                end
            join
            if (n_error == e0) ok("BUS_ARB : CPU_BFM and debug bus master interleaved");
        end

        //=============================================================
        section("13. Authentication");
        //=============================================================
        if (from_sec <= 13 && 13 <= to_sec) begin
            int e0;
            e0 = n_error;
            sw2_auth = 1'b1;
            repeat (10) @(posedge clk100);
            dm_write(DM_DMCONTROL, 32'h0000_0000);
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            dm_read(DM_DMSTATUS, r32);
            check32("unauthenticated dmstatus : version only", 32'h0000_0003, r32);
            dm_read(DM_DMCONTROL, r32);
            check32("unauthenticated dmcontrol : dmactive only", 32'h0000_0001, r32);
            dm_write(DM_DATA0, 32'h1234_5678);
            dm_read(DM_DATA0, r32);
            check32("unauthenticated data0 reads 0", 32'd0, r32);
            dm_read(DM_SBCS, r32);
            check32("unauthenticated sbcs reads 0", 32'd0, r32);
            dm_write(DM_DMCONTROL, 32'h8000_0001);           // haltreq ignored
            repeat (50) @(posedge clk100);
            check("unauthenticated haltreq ignored", u_top.dbg_running === 1'b1);
            dm_write(DM_SBADDRESS0, 32'h8000_7000);
            dm_write(DM_SBDATA0, 32'hFFFF_FFFF);
            repeat (50) @(posedge clk100);
            check64("unauthenticated SBA ignored", 64'd0, mem_peek(40'h00_8000_7000));
            dm_write(DM_AUTHDATA, 32'h1234_5678);            // wrong key
            dm_read(DM_DMSTATUS, r32);
            check32("wrong key : not authenticated", 32'd0, r32[7]);
            dm_write(DM_AUTHDATA, AUTH_KEY);
            dm_read(DM_DMSTATUS, r32);
            check32("correct key : authenticated", 32'd1, r32[7]);
            dm_read(DM_AUTHDATA, r32);
            check32("authdata reads 0", 32'd0, r32);
            dm_write(DM_DATA0, 32'h1234_5678);
            dm_read(DM_DATA0, r32);
            check32("authenticated data0", 32'h1234_5678, r32);
            dm_write(DM_DMCONTROL, 32'h0000_0000);           // relock
            dm_write(DM_DMCONTROL, 32'h0000_0001);
            dm_read(DM_DMSTATUS, r32);
            check32("dmactive=0 relocks", 32'd0, r32[7]);
            sw2_auth = 1'b0;
            repeat (10) @(posedge clk100);
            dm_read(DM_DMSTATUS, r32);
            check32("auth disabled : authenticated", 32'd1, r32[7]);
            dm_activate();
            if (n_error == e0) ok("authdata lock / unlock / relock, disable switch");
        end

        //=============================================================
        section("14. cJTAG (OScan1)");
        //=============================================================
        if (from_sec <= 14 && 14 <= to_sec) begin
            int e0;
            e0 = n_error;
            sw3_cjtag = 1'b1;
            tap_cycle(1'b1, 1'b0, rop[0]);       // 4-wire clocks while switching
            tap_cycle(1'b1, 1'b0, rop[0]);
            tap_cycle(1'b1, 1'b0, rop[0]);
            cjtag = 1'b1;
            cjtag_activate();
            check("cJTAG online", u_top.cjtag_online === 1'b1 && led[7] === 1'b1);
            tap_basic("cJTAG");
            dtmcs_scan(32'd0, r32);
            check32("cJTAG dtmcs.version/abits", 32'h71, r32[9:0]);
            dmi_stress("cJTAG DMI traffic", 40, 1);
            for (int i = 0; i < 6; i++) begin
                sys_half = 10.0;
                tck_half = 10.0 * cratios(i);
                tck_jitter = (i % 2) ? 0.3 : 0.0;
                idle_cycles = 1;
                dmi_stress($sformatf("cJTAG TCKC/sys ratio %0.3f%s", cratios(i),
                                     tck_jitter != 0.0 ? " (jitter 30%)" : ""), 20, 1);
            end
            tck_half = 50.0; tck_jitter = 0.0;
            sba_write(40'h00_8000_A000, 3'd3, 64'h0C1A_6000_0000_0001, err3);
            sba_read(40'h00_8000_A000, 3'd3, r64, err3);
            check64("cJTAG SBA", 64'h0C1A_6000_0000_0001, r64);
            // worst-case TMSC / TCKC alignment
            align_worst = 1'b1;
            tap_basic("cJTAG worst-case edge");
            dmi_stress("cJTAG worst-case edge alignment", 40, 0);
            align_worst = 1'b0;
            // deselection escape -> offline
            cjtag_escape(4);
            tck_pulse(1'b0);                      // escape is evaluated at the next TCKC rise
            check("deselection escape : offline", u_top.cjtag_online === 1'b0);
            tap_reset();
            scan_dr(32, 64'd0, dout, 0);
            check("offline : no IDCODE", dout[31:0] != IDCODE);
            cjtag_activate();
            tap_basic("cJTAG re-activated");
            // reset escape in the middle of a DR scan
            set_ir(5'h11);
            begin
                bit tdo;
                tap_cycle(1'b1, 1'b0, tdo);
                tap_cycle(1'b0, 1'b0, tdo);
                tap_cycle(1'b0, 1'b0, tdo);
                for (int i = 0; i < 10; i++) tap_cycle(1'b0, i[0], tdo);
            end
            cjtag_escape(8);
            tck_pulse(1'b0);
            check("reset escape in Shift-DR : offline", u_top.cjtag_online === 1'b0);
            cjtag_activate();
            tap_basic("cJTAG after reset escape");
            dm_read(DM_DMCONTROL, r32);
            check32("DM kept across escapes", 32'd1, r32[0]);
            // wrong activation code
            cjtag_escape(8);
            cjtag_activate_code(12'h08D);
            check("wrong activation code : offline", u_top.cjtag_online === 1'b0);
            cjtag_activate();
            check("cJTAG online again", u_top.cjtag_online === 1'b1);
            check32("no TMSC drive contention", 32'd0, tmsc_contention);
            // back to JTAG
            sw3_cjtag = 1'b0;
            cjtag = 1'b0;
            tap_idle(4);
            tap_basic("JTAG after cJTAG");
            dmi_stress("JTAG after cJTAG", 20, 0);
            if (n_error == e0) ok("cJTAG activation, OScan1, escapes, edge alignment, mode switch");
        end

        //=============================================================
        section("15. Debug access through the data cache");
        //=============================================================
        if (from_sec <= 15 && 15 <= to_sec) begin
            int e0;
            logic [63:0] cv;
            bit          cerr;
            e0 = n_error;

            // the CPU flushes its cache first, so the state is known
            bfm_cache_exec(4'd14, 40'h00_8000_0000, 2'd3, 64'd0, cv, cerr);

            // (a) debug write : write through, memory holds the value and the
            //     line is not allocated
            sba_write(40'h00_8000_A000, 3'd3, 64'hDCDC_0000_0000_0001, err3);
            check32("debug write sberror", 32'd0, err3);
            check64("debug write reached memory", 64'hDCDC_0000_0000_0001,
                    mem_peek(40'h00_8000_A000));
            check("debug write does not allocate a line",
                  dc_line_present(40'h00_8000_A000) == 1'b0);

            // (b) debug read : the first one misses and fills the line,
            //     the second one hits
            sba_read(40'h00_8000_A000, 3'd3, r64, err3);
            check64("debug read (miss)", 64'hDCDC_0000_0000_0001, r64);
            check("debug read allocated the line", dc_line_present(40'h00_8000_A000));
            sba_read(40'h00_8000_A000, 3'd3, r64, err3);
            check64("debug read (hit)", 64'hDCDC_0000_0000_0001, r64);

            // (c) debug write into a line that is in the cache : both the
            //     cache and memory are updated
            sba_write(40'h00_8000_A000, 3'd3, 64'hDCDC_0000_0000_0002, err3);
            check64("second debug write reached memory", 64'hDCDC_0000_0000_0002,
                    mem_peek(40'h00_8000_A000));
            sba_read(40'h00_8000_A000, 3'd3, r64, err3);
            check64("debug read after the write", 64'hDCDC_0000_0000_0002, r64);
            bfm_cache_exec(4'd0, 40'h00_8000_A000, 2'd3, 64'd0, cv, cerr);
            check64("the CPU sees the debug write", 64'hDCDC_0000_0000_0002, cv);

            // (d) the CPU has the line dirty : the debugger must see the new
            //     value even though memory still holds the old one
            bfm_cache_exec(4'd1, 40'h00_8000_A100, 2'd3, 64'hC0FE_0000_0000_0001,
                           cv, cerr);
            check("memory still has the old value",
                  mem_peek(40'h00_8000_A100) !== (64'hC0FE_0000_0000_0001));
            sba_read(40'h00_8000_A100, 3'd3, r64, err3);
            check64("debug read of a line the CPU left dirty",
                    64'hC0FE_0000_0000_0001, r64);

            // (e) after the CPU flushed, memory holds it as well
            bfm_cache_exec(4'd14, 40'h00_8000_0000, 2'd3, 64'd0, cv, cerr);
            check64("memory after the CPU flush", 64'hC0FE_0000_0000_0001,
                    mem_peek(40'h00_8000_A100));

            // (f) byte / half / word sizes through the cache
            for (int sz = 0; sz < 3; sz++) begin
                w64 = {$urandom, $urandom} &
                      ((64'd1 << (8 * (1 << sz))) - 64'd1);
                sba_write(40'h00_8000_A200 + 40'(1 << sz), 3'(sz), w64, err3);
                sba_read (40'h00_8000_A200 + 40'(1 << sz), 3'(sz), r64, err3);
                check64($sformatf("debug size %0d through the cache", sz), w64, r64);
            end

            // (g) peripheral bus : still goes straight to the bus master
            sba_write(40'h00_1200_0A00, 3'd3, 64'hBEEF_0000_0000_0001, err3);
            check64("peripheral write (not cached)", 64'hBEEF_0000_0000_0001,
                    mem_peek(40'h00_1200_0A00));

            if (n_error == e0) ok("debug accesses go through the data cache (miss, hit, coherent)");
        end

        //=============================================================
        $display("");
        $display("==========================================================");
        $display(" RESULT : %s   (%0d checks, %0d errors)",
                 (n_error == 0) ? "PASS" : "FAIL", n_check, n_error);
        $display("==========================================================");
        $finish;
    end

    // (functions instead of array literals for Icarus Verilog)
    function automatic logic [15:0] csr_rw(input int j);
        case (j)
            0: return 16'h0302;  1: return 16'h0303;  2: return 16'h0305;
            3: return 16'h0340;  4: return 16'h0341;  5: return 16'h0342;
            6: return 16'h0343;  7: return 16'h0105;  8: return 16'h0140;
            9: return 16'h0141; 10: return 16'h0142; 11: return 16'h0143;
           12: return 16'h07B1; 13: return 16'h07B2; default: return 16'h07B3;
        endcase
    endfunction
    // WARL masks: medeleg, mideleg, mtvec / stvec mode bit 1
    function automatic logic [63:0] csr_mask(input int j);
        case (j)
            0:       return 64'h0000_0000_0000_B3FF;
            1:       return 64'h0000_0000_0000_0222;
            2, 7:    return 64'hFFFF_FFFF_FFFF_FFFD;
            default: return 64'hFFFF_FFFF_FFFF_FFFF;
        endcase
    endfunction
    function automatic logic [39:0] test_bases(input int j);
        return (j == 0) ? 40'h00_8000_0100 : 40'h00_1200_0100;
    endfunction
    function automatic real cratios(input int j);
        case (j)
            0: return 0.1; 1: return 0.5; 2: return 1.0; 3: return 2.0; 4: return 10.0; default: return 30.0;
        endcase
    endfunction
    function automatic real ratios(input int j);
        case (j)
            0: return 0.02; 1: return 0.05; 2: return 0.13; 3: return 0.5;  4: return 0.97; 5: return 1.0;
            6: return 1.03; 7: return 2.9;  8: return 7.3;  9: return 20.0; 10: return 50.0; default: return 0.333;
        endcase
    endfunction

    //-----------------------------------------------------------------
    // cJTAG escape : TCKC high, n TMSC edges, TCKC low
    //-----------------------------------------------------------------
    task automatic cjtag_escape(input int edges);
        host_oe  = 1'b1;
        host_tms = 1'b0;
        #(tck_half);
        ja_tck = 1'b1;
        #(tck_half);
        for (int i = 0; i < edges; i++) begin
            host_tms = ~host_tms;
            #(tck_half);
        end
        ja_tck = 1'b0;
        #(tck_half);
    endtask

    task automatic tck_pulse(input bit tmsc);

        host_tms = tmsc;
        #(tck_half);
        ja_tck = 1'b1;
        #(tck_half);
        ja_tck = 1'b0;
    endtask

    // OpenOCD cjtag_reset_online_activate() : reset escape, 3 pulses,
    // selection escape, OAC/EC/CP
    task automatic cjtag_activate_code(input logic [11:0] code);
        host_oe  = 1'b1;
        host_tms = 1'b0;
        #(tck_half);
        ja_tck = 1'b1;                                          // reset escape (8 edges)
        for (int i = 0; i < 8; i++) begin #(tck_half); host_tms = ~host_tms; end
        #(tck_half);
        ja_tck = 1'b0;
        for (int i = 0; i < 3; i++) tck_pulse(1'b0);            // padding
        #(tck_half);
        ja_tck = 1'b1;                                          // selection escape (6 edges)
        for (int i = 0; i < 6; i++) begin #(tck_half); host_tms = ~host_tms; end
        #(tck_half);
        ja_tck = 1'b0;
        for (int i = 0; i < 12; i++) tck_pulse(code[i]);        // first pulse = OAC bit 0
        host_tms = 1'b0;
        cur_ir = 5'h01;
    endtask

    task automatic cjtag_activate();

        cjtag_activate_code(12'h08C);
        tap_reset();
    endtask
