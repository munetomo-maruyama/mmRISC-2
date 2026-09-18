#!/usr/bin/env python3
#---------------------------------------------------------------------------
# gen_gtkw.py : GTKWave save files for the debug logic waveforms
#
#   SIM_DBG/tb_DBG_jtag.gtkw   <- tb_DBG_jtag.vcd  (make wave-jtag)
#   SIM_DBG/tb_DBG_cjtag.gtkw  <- tb_DBG_cjtag.vcd (make wave-cjtag)
#   SIM_OCD/tb_OCD.gtkw        <- tb_OCD.vcd       (SIM_OCD: make wave)
#
# Every signal is checked against the VCD header (GTKWave silently drops
# unknown names). State encodings are shown by name through translate
# filter files written to <sim dir>/gtkw_filter/.
#
#   python3 gen_gtkw.py            (run after the VCD files have been made)
#---------------------------------------------------------------------------

import os
import sys

HERE    = os.path.dirname(os.path.abspath(__file__))
SIM_DIR = os.path.dirname(HERE)

# GTKWave trace flags
BIT, HEX, DEC = "@28", "@22", "@24"
FILT          = "@2022"             # hex + file translate filter
DIV           = "@200"
GRP_OPEN      = "@800"
GRP_CLOSE     = "@1000"
GRP_OPEN_C    = "@c00200"           # collapsed group
GRP_CLOSE_C   = "@1401200"

#---------------------------------------------------------------------------
# Translate filters : value (hex, as displayed) -> name
#---------------------------------------------------------------------------
def hexkeys(v, width):
    digits = max(1, (width + 3) // 4)
    return sorted({f"{v:X}", f"{v:0{digits}X}"})

FILTERS = {
    "tap_state": (4, ["TLR", "RTI", "SEL_DR", "CAP_DR", "SHIFT_DR", "EXIT1_DR", "PAUSE_DR",
                      "EXIT2_DR", "UPDATE_DR", "SEL_IR", "CAP_IR", "SHIFT_IR", "EXIT1_IR",
                      "PAUSE_IR", "EXIT2_IR", "UPDATE_IR"]),
    "jtag_ir":   (5, {0x01: "IDCODE", 0x10: "DTMCS", 0x11: "DMI", 0x1F: "BYPASS", 0x00: "BYPASS(00)"}),
    "dmi_op":    (2, {0: "SUCCESS", 1: "RSVD", 2: "FAILED", 3: "BUSY"}),
    "dmi_addr":  (7, {0x04: "data0", 0x05: "data1", 0x06: "data2", 0x07: "data3",
                      0x10: "dmcontrol", 0x11: "dmstatus", 0x12: "hartinfo", 0x13: "haltsum1",
                      0x16: "abstractcs", 0x17: "command", 0x18: "abstractauto",
                      0x30: "authdata", 0x38: "sbcs", 0x39: "sbaddress0", 0x3A: "sbaddress1",
                      0x3C: "sbdata0", 0x3D: "sbdata1", 0x40: "haltsum0"}),
    "cdc_state": (2, ["S_IDLE", "S_WAIT", "S_ACK"]),
    "cj_state":  (2, ["OFFLINE", "ACTIVATION", "OSCAN1"]),
    "cj_phase":  (2, ["PH0:nTDI", "PH1:TMS", "PH2:TDO"]),
    "ab_state":  (3, ["AB_IDLE", "AB_DECODE", "AB_REG_ISSUE", "AB_REG_WAIT", "AB_MEM_PEND", "AB_MEM_WAIT"]),
    "cmderr":    (3, ["NONE", "BUSY", "NOT_SUPPORTED", "EXCEPTION", "HALT_RESUME", "BUS", "RSVD6", "OTHER"]),
    "sberror":   (3, ["NONE", "TIMEOUT", "BAD_ADDRESS", "ALIGNMENT", "BAD_SIZE", "RSVD5", "RSVD6", "OTHER"]),
    "sbaccess":  (3, ["8bit", "16bit", "32bit", "64bit", "128bit"]),
    "bm_state":  (3, ["B_IDLE", "B_W_AW_W", "B_W_B", "B_R_AR", "B_R_R"]),
    "hart_state":(2, ["H_RESET", "H_RUN", "H_HALT", "H_STEP"]),
    "axi_resp":  (2, ["OKAY", "EXOKAY", "SLVERR", "DECERR"]),
    "axsize":    (3, ["1byte", "2byte", "4byte", "8byte"]),
    "nar_w":     (3, ["W_IDLE", "W_PASS_DATA", "W_PASS_RESP", "W_ERR_DATA", "W_ERR_RESP", "W_PASS_AW"]),
    "nar_r":     (2, ["R_IDLE", "R_PASS", "R_ERR"]),
    "ram_w":     (2, ["W_IDLE", "W_DATA", "W_RESP"]),
    "ram_r":     (2, ["R_IDLE", "R_ADDR", "R_DATA"]),
}

def write_filters(fdir):
    os.makedirs(fdir, exist_ok=True)
    for name, (width, table) in FILTERS.items():
        items = enumerate(table) if isinstance(table, list) else table.items()
        with open(os.path.join(fdir, name + ".txt"), "w") as f:
            for v, text in items:
                for k in hexkeys(v, width):
                    f.write(f"{k} {text}\n")

#---------------------------------------------------------------------------
# VCD header
#---------------------------------------------------------------------------
def read_header(vcd):
    names = {}
    scope = []
    with open(vcd) as f:
        for line in f:
            s = line.split()
            if not s:
                continue
            if s[0] == "$scope":
                scope.append(s[2])
            elif s[0] == "$upscope":
                scope.pop()
            elif s[0] == "$var":
                rng = s[5] if s[5] != "$end" else ""
                names[".".join(scope + [s[4]])] = rng
            elif s[0] == "$enddefinitions":
                break
    return names

#---------------------------------------------------------------------------
# Save file builder
#---------------------------------------------------------------------------
class Gtkw:
    def __init__(self, vcd, fdir):
        self.hdr   = read_header(vcd)
        self.fdir  = fdir
        self.lines = []
        self.flag  = None
        self.missing = []

    def _emit_flag(self, flag, filt=None):
        key = (flag, filt)
        if self.flag != key:
            self.lines.append(flag)
            if filt:
                self.lines.append(f"^1 {os.path.join(self.fdir, filt + '.txt')}")
            self.flag = key

    def sig(self, name, fmt=None, filt=None):
        if name not in self.hdr:
            self.missing.append(name)
            return
        rng = self.hdr[name]
        if filt:
            self._emit_flag(FILT, filt)
        else:
            if fmt is None:
                fmt = HEX if rng else BIT
            self._emit_flag(fmt)
        self.lines.append(name + rng)

    def sigs(self, prefix, names, fmt=None):
        for n in names:
            self.sig(f"{prefix}.{n}", fmt)

    def div(self, text):
        self.lines += [DIV, "-" + text]
        self.flag = None

    def group(self, title, body, collapsed=False):
        self.lines += [GRP_OPEN_C if collapsed else GRP_OPEN, "-" + title]
        self.flag = None
        body()
        self.lines += [GRP_CLOSE_C if collapsed else GRP_CLOSE, "-" + title]
        self.flag = None

    def write(self, path, vcd, comment, timestart, zoom, markers, treeopen):
        if self.missing:
            print("ERROR: signals not found in", vcd)
            for m in self.missing:
                print("   ", m)
            sys.exit(1)
        named = ["-1"] * 26
        for i, t in enumerate(markers[1:]):
            named[i] = str(t)
        with open(path, "w") as f:
            f.write("[*] GTKWave Analyzer save file\n")
            for c in comment:
                f.write(f"[*] {c}\n")
            f.write(f'[dumpfile] "{vcd}"\n')
            f.write(f'[savefile] "{path}"\n')
            f.write(f"[timestart] {timestart}\n")
            f.write("[size] 1600 900\n[pos] -1 -1\n")
            f.write(f"*{zoom:.6f} {markers[0]} {' '.join(named)}\n")
            for t in treeopen:
                f.write(f"[treeopen] {t}.\n")
            f.write("[sst_width] 300\n[signals_width] 360\n[sst_expanded] 1\n[sst_vpaned_height] 300\n")
            f.write("\n".join(self.lines) + "\n")
        print("wrote", path, f"({sum(1 for l in self.lines if not l.startswith(('@', '-', '^')))} traces)")

#---------------------------------------------------------------------------
# Signal groups
#---------------------------------------------------------------------------
def g_clock(w, R, extra_tb):
    T, D = f"{R}.u_top", f"{R}.u_top.u_cpu_top.u_cpu_dbg"
    def body():
        w.sig(f"{R}.clk100")
        w.sig(f"{T}.sys_clk")
        w.div("debug power-on reset (TCK / clk domains)")
        w.sig(f"{T}.rst_dbg_n")
        w.sig(f"{D}.t_por_n")
        w.sig(f"{D}.tap_rst_n")
        w.sig(f"{D}.s_por_n")
        w.div("system reset")
        w.sig(f"{T}.rst_n")
        w.sig(f"{T}.ndmreset")
        w.sig(f"{T}.rst_bus_n")
        w.sig(f"{D}.hart_rst")
    return body

def g_pins(w, R, tb):
    def body():
        w.sig(f"{R}.ja_tck")
        w.sig(f"{R}.ja_tms")
        w.sig(f"{R}.ja_tdi")
        w.sig(f"{R}.ja_tdo")
        w.sig(f"{R}.ja_trstn")
        w.sig(f"{R}.ja_srstn")
        w.div("board")
        if tb == "DBG":
            w.sig(f"{R}.sw3_cjtag")
            w.sig(f"{R}.sw2_auth")
        else:
            w.sig(f"{R}.sw2")
        w.sig(f"{R}.led", BIT)
    return body

def g_cjtag_pin(w, R):
    C = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_cjtag"
    def body():
        w.sig(f"{R}.ja_tck")
        w.sig(f"{R}.ja_tms")
        w.div("TMSC drivers (host / target / keeper)")
        w.sig(f"{R}.host_oe")
        w.sig(f"{R}.host_tms")
        w.sig(f"{R}.dut_oe")
        w.sig(f"{R}.dut_o")
        w.sig(f"{R}.keeper")
        w.sig(f"{R}.tmsc_contention", DEC)
        w.div("mode / status")
        w.sig(f"{R}.sw3_cjtag")
        w.sig(f"{C}.mode_c")
        w.sig(f"{C}.online")
    return body

def g_cjtag_esc(w, R):
    C = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_cjtag"
    def body():
        w.div("Gray counter clocked by TMSC rise (counts while TCKC=1)")
        w.sig(f"{C}.esc_gray")
        w.sig(f"{C}.esc_bin", DEC)
        w.div("snapshots at TCKC rise / fall")
        w.sig(f"{C}.snap_rise")
        w.sig(f"{C}.snap_fall")
        w.sig(f"{C}.snap_rise_bin", DEC)
        w.sig(f"{C}.snap_fall_bin", DEC)
        w.div("rises during last TCKC high : >=4 reset, 3 select, 2 deselect")
        w.sig(f"{C}.esc_r", DEC)
        w.sig(f"{C}.esc_reset")
        w.sig(f"{C}.esc_select")
        w.sig(f"{C}.esc_deselect")
        w.sig(f"{C}.esc_any")
    return body

def g_cjtag_act(w, R):
    C = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_cjtag"
    def body():
        w.sig(f"{C}.c_state", filt="cj_state")
        w.sig(f"{C}.act_cnt", DEC)
        w.sig(f"{R}.ja_tms")
        w.div("OScan1 3-phase frame")
        w.sig(f"{C}.phase", filt="cj_phase")
        w.sig(f"{C}.tdi_c")
        w.sig(f"{C}.tms_c")
        w.div("TAP control (to DTM)")
        w.sig(f"{C}.tap_ce")
        w.sig(f"{C}.tap_tms")
        w.sig(f"{C}.tap_tdi")
        w.sig(f"{C}.tap_hold")
        w.sig(f"{C}.dtm_tdo")
        w.sig(f"{C}.tms_oe")
    return body

def g_dtm(w, R):
    M = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_dtm"
    def body():
        w.sig(f"{M}.tck")
        w.sig(f"{M}.tap_ce")
        w.sig(f"{M}.tap_tms")
        w.sig(f"{M}.tap_tdi")
        w.sig(f"{M}.state", filt="tap_state")
        w.sig(f"{M}.ir", filt="jtag_ir")
        w.sig(f"{M}.ir_sr")
        w.sig(f"{M}.dr_sr")
        w.sig(f"{M}.tdo")
        w.sig(f"{M}.tdo_oe")
        w.div("dtmcs / dmi status")
        w.sig(f"{M}.sticky", filt="dmi_op")
        w.sig(f"{M}.errinfo", DEC)
        w.sig(f"{M}.last_addr", filt="dmi_addr")
        w.div("DMI request (Update-DR)")
        w.sig(f"{M}.dmi_start")
        w.sig(f"{M}.dmi_addr", filt="dmi_addr")
        w.sig(f"{M}.dmi_wr")
        w.sig(f"{M}.dmi_wdata")
        w.sig(f"{M}.dmi_abort")
        w.sig(f"{M}.dmi_busy")
        w.sig(f"{M}.dmi_rdata")
    return body

def g_cdc(w, R):
    C = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_cdc"
    def body():
        w.div("TCK domain")
        w.sig(f"{C}.tck")
        w.sig(f"{C}.pend")
        w.sig(f"{C}.req")
        w.sig(f"{C}.ack_s")
        w.sig(f"{C}.t_complete")
        w.sig(f"{C}.q_addr", filt="dmi_addr")
        w.sig(f"{C}.q_wr")
        w.sig(f"{C}.q_wdata")
        w.sig(f"{C}.r_rdata")
        w.div("system clock domain")
        w.sig(f"{C}.clk")
        w.sig(f"{C}.req_s")
        w.sig(f"{C}.s_state", filt="cdc_state")
        w.sig(f"{C}.dmi_req")
        w.sig(f"{C}.dmi_addr", filt="dmi_addr")
        w.sig(f"{C}.dmi_wr")
        w.sig(f"{C}.dmi_wdata")
        w.sig(f"{C}.dmi_ack")
        w.sig(f"{C}.dmi_rdata")
        w.sig(f"{C}.ack")
    return body

def g_dm(w, R, auth=False):
    M = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_dm"
    def body():
        w.sig(f"{M}.dmactive")
        if auth:
            w.sig(f"{M}.auth_en")
            w.sig(f"{M}.auth_ok")
        w.sig(f"{M}.authenticated")
        w.sig(f"{M}.hartsel_r")
        w.sig(f"{M}.haltreq_r")
        w.sig(f"{M}.hart_resumereq")
        w.sig(f"{M}.resumeack_r")
        w.sig(f"{M}.havereset_r")
        w.sig(f"{M}.resethaltreq_r")
        w.sig(f"{M}.hartreset_r")
        w.sig(f"{M}.ndmreset_r")
        w.div("abstract command")
        w.sig(f"{M}.command_r")
        w.sig(f"{M}.ab_state", filt="ab_state")
        w.sig(f"{M}.cmderr_r", filt="cmderr")
        w.sig(f"{M}.autoexec_r")
        for i in range(4):
            w.sig(f"{M}.data_r[{i}]")
        w.sig(f"{M}.reg_busy")
        w.div("system bus access")
        w.sig(f"{M}.sbaddress_r")
        w.sig(f"{M}.sbdata1_r")
        w.sig(f"{M}.sbdata0_r")
        w.sig(f"{M}.sbaccess_r", filt="sbaccess")
        w.sig(f"{M}.sbautoincrement_r")
        w.sig(f"{M}.sbreadonaddr_r")
        w.sig(f"{M}.sbreadondata_r")
        w.sig(f"{M}.sb_pend")
        w.sig(f"{M}.sb_wait")
        w.sig(f"{M}.sberror_r", filt="sberror")
        w.sig(f"{M}.sbbusyerror_r")
        w.div("bus master scheduling")
        w.sig(f"{M}.bm_busy")
        w.sig(f"{M}.bm_owner_sba")
        w.sig(f"{M}.bus_in_reset")
    return body

def g_hart(w, R):
    H = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_hart"
    def body():
        w.sig(f"{H}.hart_rst")
        w.sig(f"{H}.h_state", filt="hart_state")
        w.sig(f"{H}.haltreq")
        w.sig(f"{H}.resumereq")
        w.sig(f"{H}.resethaltreq")
        w.sig(f"{H}.resumed")
        w.sig(f"{H}.halted")
        w.sig(f"{H}.running")
        w.sig(f"{H}.dcsr")
        w.sig(f"{H}.dpc")
        w.div("register access")
        w.sig(f"{H}.reg_req")
        w.sig(f"{H}.reg_wr")
        w.sig(f"{H}.reg_regno")
        w.sig(f"{H}.reg_size64")
        w.sig(f"{H}.reg_wdata")
        w.sig(f"{H}.reg_ack")
        w.sig(f"{H}.reg_rdata")
        w.sig(f"{H}.reg_err")
    return body

def g_busmst(w, R):
    B = f"{R}.u_top.u_cpu_top.u_cpu_dbg.u_busmst"
    def body():
        w.sig(f"{B}.bm_req")
        w.sig(f"{B}.bm_wr")
        w.sig(f"{B}.bm_addr")
        w.sig(f"{B}.bm_size", filt="axsize")
        w.sig(f"{B}.bm_wdata")
        w.sig(f"{B}.bm_ack")
        w.sig(f"{B}.bm_rdata")
        w.sig(f"{B}.bm_err", filt="sberror")
        w.div("transaction")
        w.sig(f"{B}.b_state", filt="bm_state")
        w.sig(f"{B}.t_mem")
        w.sig(f"{B}.t_addr")
        w.sig(f"{B}.t_wstrb")
        w.sig(f"{B}.t_wdata")
        w.sig(f"{B}.draining")
        w.sig(f"{B}.tmo_cnt", DEC)
    return body

def g_arb(w, R):
    A = f"{R}.u_top.u_cpu_top.u_bus_arb"
    def body():
        w.div("AXI4 write / read grant (g1=1: CPU, 0: debug)")
        for n in ("x4w_act", "x4w_g1", "x4r_act", "x4r_g1"):
            w.sig(f"{A}.{n}")
        w.div("AXI4-Lite write / read grant")
        for n in ("xlw_act", "xlw_g1", "xlr_act", "xlr_g1"):
            w.sig(f"{A}.{n}")
    return body

def g_axi4(w, R, pfx, narrow=None, ram=None):
    T = f"{R}.u_top"
    def body():
        w.div("write address")
        w.sig(f"{T}.{pfx}_awvalid"); w.sig(f"{T}.{pfx}_awready")
        w.sig(f"{T}.{pfx}_awid"); w.sig(f"{T}.{pfx}_awaddr")
        w.sig(f"{T}.{pfx}_awlen", DEC); w.sig(f"{T}.{pfx}_awsize", filt="axsize")
        w.div("write data")
        w.sig(f"{T}.{pfx}_wvalid"); w.sig(f"{T}.{pfx}_wready")
        w.sig(f"{T}.{pfx}_wdata"); w.sig(f"{T}.{pfx}_wstrb"); w.sig(f"{T}.{pfx}_wlast")
        w.div("write response")
        w.sig(f"{T}.{pfx}_bvalid"); w.sig(f"{T}.{pfx}_bready")
        w.sig(f"{T}.{pfx}_bid"); w.sig(f"{T}.{pfx}_bresp", filt="axi_resp")
        w.div("read address")
        w.sig(f"{T}.{pfx}_arvalid"); w.sig(f"{T}.{pfx}_arready")
        w.sig(f"{T}.{pfx}_arid"); w.sig(f"{T}.{pfx}_araddr")
        w.sig(f"{T}.{pfx}_arlen", DEC); w.sig(f"{T}.{pfx}_arsize", filt="axsize")
        w.div("read data")
        w.sig(f"{T}.{pfx}_rvalid"); w.sig(f"{T}.{pfx}_rready")
        w.sig(f"{T}.{pfx}_rid"); w.sig(f"{T}.{pfx}_rdata")
        w.sig(f"{T}.{pfx}_rresp", filt="axi_resp"); w.sig(f"{T}.{pfx}_rlast")
        if narrow:
            w.div("AXI4_ADDR_NARROW (40->32bit, DECERR)")
            w.sig(f"{T}.{narrow}.wstate", filt="nar_w")
            w.sig(f"{T}.{narrow}.rstate", filt="nar_r")
        if ram:
            w.div("AXI4_RAM")
            w.sig(f"{T}.{ram}.w_state", filt="ram_w")
            w.sig(f"{T}.{ram}.w_addr")
            w.sig(f"{T}.{ram}.r_state", filt="ram_r")
            w.sig(f"{T}.{ram}.r_addr")
    return body

def g_axil(w, R, pfx, narrow=None, ram=False):
    T = f"{R}.u_top"
    def body():
        w.div("write address / data / response")
        w.sig(f"{T}.{pfx}_awvalid"); w.sig(f"{T}.{pfx}_awready"); w.sig(f"{T}.{pfx}_awaddr")
        w.sig(f"{T}.{pfx}_wvalid"); w.sig(f"{T}.{pfx}_wready")
        w.sig(f"{T}.{pfx}_wdata"); w.sig(f"{T}.{pfx}_wstrb")
        w.sig(f"{T}.{pfx}_bvalid"); w.sig(f"{T}.{pfx}_bready"); w.sig(f"{T}.{pfx}_bresp", filt="axi_resp")
        w.div("read address / data")
        w.sig(f"{T}.{pfx}_arvalid"); w.sig(f"{T}.{pfx}_arready"); w.sig(f"{T}.{pfx}_araddr")
        w.sig(f"{T}.{pfx}_rvalid"); w.sig(f"{T}.{pfx}_rready")
        w.sig(f"{T}.{pfx}_rdata"); w.sig(f"{T}.{pfx}_rresp", filt="axi_resp")
        if narrow:
            w.div("AXIL_ADDR_NARROW (40->32bit, DECERR)")
            w.sig(f"{T}.{narrow}.wstate", filt="nar_w")
            w.sig(f"{T}.{narrow}.rstate", filt="nar_r")
    return body

def g_tb(w, R):
    def body():
        w.sig(f"{R}.n_error", DEC)
        w.sig(f"{R}.n_busy", DEC)
        w.sig(f"{R}.idle_cycles", DEC)
        w.sig(f"{R}.cjtag")
        w.sig(f"{R}.align_worst")
        w.sig(f"{R}.tmsc_contention", DEC)
    return body

#---------------------------------------------------------------------------
# Files
#---------------------------------------------------------------------------
def bus_groups(w, R, collapse_axil=False):
    w.group("BUS ARBITER (debug / CPU_BFM)", g_arb(w, R), collapsed=True)
    w.group("MEMORY BUS  AXI4 40bit (CPU_TOP port)", g_axi4(w, R, "cpu_axi4"))
    w.group("MEMORY RAM  AXI4 32bit @0x8000_0000 64KiB",
            g_axi4(w, R, "ram_axi4", "u_narrow_axi4", "u_ram_axi4"), collapsed=True)
    w.group("PERIPHERAL BUS  AXI4-Lite 40bit (CPU_TOP port)", g_axil(w, R, "cpu_axil"), collapsed=collapse_axil)
    w.group("PERIPHERAL RAM  AXI4-Lite 32bit @0x1200_0000 4KiB",
            g_axil(w, R, "ram_axil", "u_narrow_axil"), collapsed=True)

def make_jtag():
    d    = os.path.join(SIM_DIR, "SIM_DBG")
    vcd  = os.path.join(d, "tb_DBG_jtag.vcd")
    R    = "TOP.tb_DBG"
    w    = Gtkw(vcd, os.path.join(d, "gtkw_filter"))
    w.group("1. CLOCK / RESET", g_clock(w, R, None), collapsed=True)
    w.group("2. JTAG PINS (PMOD JA)", g_pins(w, R, "DBG"))
    w.group("3. DTM : TAP / IR / DR / dmi (TCK domain)", g_dtm(w, R))
    w.group("4. CDC : DMI request / response handshake", g_cdc(w, R))
    w.group("5. DEBUG MODULE", g_dm(w, R))
    w.group("6. DEBUG BUS MASTER (SBA / Access Memory)", g_busmst(w, R))
    bus_groups(w, R)
    w.group("HART STUB", g_hart(w, R), collapsed=True)
    w.group("TESTBENCH", g_tb(w, R), collapsed=True)
    # markers: primary = first Access Memory command, A = its AXI4 AW,
    #          B = first AXI4-Lite write, C = first SBA request
    w.write(os.path.join(d, "tb_DBG_jtag.gtkw"), vcd,
            ["mmRISC-2 debug logic : JTAG memory access (tb_DBG sections 9-10)",
             "marker   : first Access Memory command decoded (72.07ms)",
             "A        : AXI4 AW of that command, B : first AXI4-Lite write, C : first SBA request"],
            60_000_000, ZOOM_JTAG, [72_070_000, 72_150_000, 1_857_750_000, 4_257_070_000],
            [R, f"{R}.u_top", f"{R}.u_top.u_cpu_top", f"{R}.u_top.u_cpu_top.u_cpu_dbg"])
    return w

def make_cjtag():
    d    = os.path.join(SIM_DIR, "SIM_DBG")
    vcd  = os.path.join(d, "tb_DBG_cjtag.vcd")
    R    = "TOP.tb_DBG"
    w    = Gtkw(vcd, os.path.join(d, "gtkw_filter"))
    w.group("1. CLOCK / RESET", g_clock(w, R, None), collapsed=True)
    w.group("2. cJTAG PINS : TCKC / TMSC", g_cjtag_pin(w, R))
    w.group("3. cJTAG ESCAPE DETECTION (online / offline)", g_cjtag_esc(w, R))
    w.group("4. cJTAG ACTIVATION (OAC/EC/CP) / OScan1", g_cjtag_act(w, R))
    w.group("5. DTM : TAP / IR / DR / dmi", g_dtm(w, R))
    w.group("6. CDC : DMI handshake", g_cdc(w, R), collapsed=True)
    w.group("7. DEBUG MODULE", g_dm(w, R), collapsed=True)
    w.group("8. DEBUG BUS MASTER (SBA)", g_busmst(w, R), collapsed=True)
    bus_groups(w, R, collapse_axil=True)
    w.group("TESTBENCH", g_tb(w, R))
    # markers: primary = cJTAG online, A = SW3 up, B = selection escape detected,
    #          C = first SBA request in cJTAG mode, D = deselection escape test
    w.write(os.path.join(d, "tb_DBG_cjtag.gtkw"), vcd,
            ["mmRISC-2 debug logic : cJTAG online / activation and access (tb_DBG section 14)",
             "marker : OScan1 online (32.9ms)   A : SW3 up (30.35ms)",
             "B : selection escape detected -> ACTIVATION (31.8ms)",
             "C : first SBA request over cJTAG   D : escape / re-activation tests"],
            30_200_000, ZOOM_CJTAG, [32_900_000, 30_350_000, 31_800_000, CJTAG_SBA, 11_189_655_000],
            [R, f"{R}.u_top", f"{R}.u_top.u_cpu_top", f"{R}.u_top.u_cpu_top.u_cpu_dbg"])
    return w

def make_ocd():
    d    = os.path.join(SIM_DIR, "SIM_OCD")
    vcd  = os.path.join(d, "tb_OCD.vcd")
    R    = "TOP.tb_OCD"
    w    = Gtkw(vcd, os.path.join(d, "gtkw_filter"))
    w.group("1. CLOCK / RESET", g_clock(w, R, None), collapsed=True)
    w.group("2. JTAG PINS (remote_bitbang from OpenOCD)", g_pins(w, R, "OCD"))
    w.group("3. DTM : TAP / IR / DR / dmi", g_dtm(w, R))
    w.group("4. CDC : DMI handshake", g_cdc(w, R), collapsed=True)
    w.group("5. DEBUG MODULE", g_dm(w, R, auth=True))
    w.group("6. HART STUB (halt / resume / step / register)", g_hart(w, R))
    w.group("7. DEBUG BUS MASTER (SBA / Access Memory)", g_busmst(w, R))
    bus_groups(w, R)
    w.write(os.path.join(d, "tb_OCD.gtkw"), vcd,
            ["mmRISC-2 debug logic : OpenOCD (remote_bitbang) co-simulation, JTAG",
             "marker : hart halted by OpenOCD (65.43ms)",
             "A : first memory bus write (mww)   B : first peripheral bus write"],
            60_000_000, ZOOM_OCD, [65_430_000, 253_990_000, 1_078_050_000],
            [R, f"{R}.u_top", f"{R}.u_top.u_cpu_top", f"{R}.u_top.u_cpu_top.u_cpu_dbg"])
    return w

# initial zoom (GTKWave zoom exponent) and marker for the first cJTAG SBA
ZOOM_JTAG  = -21.7
ZOOM_CJTAG = -20.0
ZOOM_OCD   = -22.0
CJTAG_SBA  = 9_657_670_000

if __name__ == "__main__":
    for k, v in (a.split("=", 1) for a in sys.argv[1:]):
        globals()[k] = float(v) if k.startswith("ZOOM") else int(v)
    write_filters(os.path.join(SIM_DIR, "SIM_DBG", "gtkw_filter"))
    write_filters(os.path.join(SIM_DIR, "SIM_OCD", "gtkw_filter"))
    make_jtag()
    make_cjtag()
    make_ocd()
