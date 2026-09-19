#!/usr/bin/env python3
#---------------------------------------------------------------------------
# gen_gtkw.py : GTKWave save files for the L1 cache throughput waveforms
#
#   tb_CACHE_ihit.gtkw   <- tb_CACHE_ihit.vcd    (I$ hit burst)
#   tb_CACHE_imiss.gtkw  <- tb_CACHE_imiss.vcd   (I$ miss burst)
#   tb_CACHE_dhit.gtkw   <- tb_CACHE_dhit.vcd    (D$ hit burst)
#   tb_CACHE_dmiss.gtkw  <- tb_CACHE_dmiss.vcd   (D$ miss burst)
#
# The VCD files come from "make wave-perf". Every signal is checked against
# the VCD header (GTKWave silently drops unknown names), state encodings are
# shown by name through filter files in gtkw_filter/, and the phase times
# written by the test bench (tb_CACHE_*.marks) become the markers.
#
#   python3 gen_gtkw.py          (or: make gtkw)
#---------------------------------------------------------------------------

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = "TOP.tb_CACHE"

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
FILTERS = {
    "ic_state":  (2, ["S_IDLE", "S_FILL", "S_UNC"]),
    "f_state":   (3, ["F_IDLE", "F_WB_READ", "F_WB_WAIT", "F_WB_PUSH", "F_AR", "F_DATA"]),
    "w_state":   (2, ["W_IDLE", "W_ADDR", "W_DATA", "W_RESP"]),
    "u_state":   (3, ["U_IDLE", "U_AR", "U_R", "U_AW", "U_B"]),
    "fl_state":  (3, ["FL_IDLE", "FL_TAG", "FL_LOOK", "FL_READ", "FL_WAIT", "FL_PUSH",
                      "FL_INV", "FL_DRAIN"]),
    "cmd":       (4, ["LOAD", "STORE", "LR", "SC", "AMOSWAP", "AMOADD", "AMOXOR", "AMOAND",
                      "AMOOR", "AMOMIN", "AMOMAX", "AMOMINU", "AMOMAXU", "FENCE", "FLUSH",
                      "RSVD15"]),
    "size":      (2, ["1byte", "2byte", "4byte", "8byte"]),
    "axsize":    (3, ["1byte", "2byte", "4byte", "8byte"]),
    "axburst":   (2, ["FIXED", "INCR", "WRAP", "RSVD"]),
    "axi_resp":  (2, ["OKAY", "EXOKAY", "SLVERR", "DECERR"]),
    "axi_id":    (4, {2: "I$ fill", 3: "D$ fill", 4: "D$ writeback"}),
    "ram_r":     (2, ["R_IDLE", "R_ADDR", "R_DATA"]),
    "ram_w":     (2, ["W_IDLE", "W_DATA", "W_RESP"]),
}

def hexkeys(v, width):
    digits = max(1, (width + 3) // 4)
    return sorted({f"{v:X}", f"{v:0{digits}X}"})

def write_filters(fdir):
    os.makedirs(fdir, exist_ok=True)
    for name, (width, table) in FILTERS.items():
        items = enumerate(table) if isinstance(table, list) else table.items()
        with open(os.path.join(fdir, name + ".txt"), "w") as f:
            for v, text in items:
                for k in hexkeys(v, width):
                    f.write(f"{k} {text}\n")

#---------------------------------------------------------------------------
# VCD header / marks file
#---------------------------------------------------------------------------
def read_header(vcd):
    names, scope = {}, []
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

def read_marks(path):
    marks = []
    if os.path.exists(path):
        for line in open(path):
            s = line.split(None, 1)
            if len(s) == 2:
                marks.append((int(s[0]), s[1].strip()))
    return marks

#---------------------------------------------------------------------------
# Save file builder
#---------------------------------------------------------------------------
class Gtkw:
    def __init__(self, vcd, fdir):
        self.hdr     = read_header(vcd)
        self.fdir    = fdir
        self.lines   = []
        self.flag    = None
        self.missing = []

    def _emit_flag(self, flag, filt=None):
        key = (flag, filt)
        if self.flag != key:
            self.lines.append(flag)
            if filt:
                self.lines.append(f"^1 {os.path.join(self.fdir, filt + '.txt')}")
            self.flag = key

    def sig(self, name, fmt=None, filt=None, optional=False):
        if name not in self.hdr:
            if not optional:
                self.missing.append(name)
            return
        rng = self.hdr[name]
        if filt:
            self._emit_flag(FILT, filt)
        else:
            self._emit_flag(fmt if fmt else (HEX if rng else BIT))
        self.lines.append(name + rng)

    def sigs(self, prefix, names, fmt=None):
        for n in names:
            self.sig(f"{prefix}.{n}", fmt)

    # indexed signals of a queue / array, as many as the VCD holds
    def array(self, prefix, name, count=16, fmt=None):
        for i in range(count):
            self.sig(f"{prefix}.{name}[{i}]", fmt, optional=True)

    def div(self, text):
        self.lines += [DIV, "-" + text]
        self.flag = None

    def group(self, title, body, collapsed=False):
        self.lines += [GRP_OPEN_C if collapsed else GRP_OPEN, "-" + title]
        self.flag = None
        body()
        self.lines += [GRP_CLOSE_C if collapsed else GRP_CLOSE, "-" + title]
        self.flag = None

    def write(self, path, vcd, comment, marks):
        if self.missing:
            print("ERROR: signals not found in", vcd)
            for m in self.missing:
                print("   ", m)
            sys.exit(1)
        # window : from the first phase to the end mark, with a small margin
        if marks:
            t0, t1 = marks[0][0], marks[-1][0]
            span   = max(t1 - t0, 1000)
            start  = max(0, t0 - span // 20)
            zoom   = math.log2(1500.0 / (span * 1.1))
        else:
            start, zoom = 0, -12.0
        named = ["-1"] * 26
        for i, (t, _) in enumerate(marks[1:27]):
            named[i] = str(t)
        primary = marks[0][0] if marks else -1
        with open(path, "w") as f:
            f.write("[*] GTKWave Analyzer save file\n")
            for c in comment:
                f.write(f"[*] {c}\n")
            for i, (t, lbl) in enumerate(marks):
                f.write(f"[*] {'marker' if i == 0 else chr(ord('A') + i - 1)} "
                        f": {lbl} ({t/1e6:.2f} us)\n")
            f.write(f'[dumpfile] "{vcd}"\n')
            f.write(f'[savefile] "{path}"\n')
            f.write(f"[timestart] {start}\n")
            f.write("[size] 1600 900\n[pos] -1 -1\n")
            f.write(f"*{zoom:.6f} {primary} {' '.join(named)}\n")
            for t in (ROOT, f"{ROOT}.u_cache", f"{ROOT}.u_cache.u_icache",
                      f"{ROOT}.u_cache.u_dcache"):
                f.write(f"[treeopen] {t}.\n")
            f.write("[sst_width] 300\n[signals_width] 400\n[sst_expanded] 1\n"
                    "[sst_vpaned_height] 300\n")
            f.write("\n".join(self.lines) + "\n")
        n = sum(1 for l in self.lines if not l.startswith(("@", "-", "^")))
        print(f"wrote {os.path.basename(path)} ({n} traces, {len(marks)} markers)")

#---------------------------------------------------------------------------
# Signal groups
#---------------------------------------------------------------------------
def g_clock(w):
    def body():
        w.sig(f"{ROOT}.clk")
        w.sig(f"{ROOT}.rst_n")
        w.sig(f"{ROOT}.cyc", DEC)
    return body

def g_icpu(w):
    def body():
        w.sig(f"{ROOT}.i_req_valid")
        w.sig(f"{ROOT}.i_req_ready")
        w.sig(f"{ROOT}.i_req_addr")
        w.div("response")
        w.sig(f"{ROOT}.i_resp_valid")
        w.sig(f"{ROOT}.i_resp_data")
        w.sig(f"{ROOT}.i_resp_error")
        w.div("fence.i")
        w.sig(f"{ROOT}.i_flush_valid")
        w.sig(f"{ROOT}.i_flush_done")
        w.sig(f"{ROOT}.i_kill")
    return body

def g_icache(w):
    I = f"{ROOT}.u_cache.u_icache"
    def body():
        w.sig(f"{I}.state", filt="ic_state")
        w.div("stage 1 lookup")
        w.sig(f"{I}.s1_valid")
        w.sig(f"{I}.s1_addr")
        w.sig(f"{I}.s1_cacheable")
        w.sig(f"{I}.hit")
        w.sig(f"{I}.hit_way_oh")
        w.sig(f"{I}.hit_way", DEC)
        w.sig(f"{I}.hit_data")
        w.div("tag array")
        w.sig(f"{I}.tag_rd_en")
        w.sig(f"{I}.tag_rd_index")
        w.sig(f"{I}.tag_rd_valid")
        w.sig(f"{I}.tag_rd_tag")
        w.sig(f"{I}.tag_wr_en")
        w.sig(f"{I}.tag_wr_index")
        w.sig(f"{I}.tag_wr_way", DEC)
        w.sig(f"{I}.tag_wr_tag")
        w.div("data array")
        w.sig(f"{I}.dat_rd_en")
        w.sig(f"{I}.dat_rd_addr")
        w.sig(f"{I}.dat_wr_en")
        w.sig(f"{I}.dat_wr_way", DEC)
        w.sig(f"{I}.dat_wr_addr")
        w.sig(f"{I}.dat_wr_data")
        w.div("line fill")
        w.sig(f"{I}.fill_addr")
        w.sig(f"{I}.fill_way", DEC)
        w.sig(f"{I}.fill_beat", DEC)
        w.sig(f"{I}.fill_err")
        w.sig(f"{I}.fill_kill")
        w.sig(f"{I}.fill_flushed")
        w.sig(f"{I}.fill_hold_valid")
        w.sig(f"{I}.rr_way")
    return body

def g_iaxi(w):
    I = f"{ROOT}.u_cache.u_icache"
    def body():
        w.sig(f"{I}.m_axi4_arvalid")
        w.sig(f"{I}.m_axi4_arready")
        w.sig(f"{I}.m_axi4_araddr")
        w.sig(f"{I}.m_axi4_arlen", DEC)
        w.sig(f"{I}.m_axi4_arsize", filt="axsize")
        w.sig(f"{I}.m_axi4_arburst", filt="axburst")
        w.sig(f"{I}.m_axi4_arid", filt="axi_id")
        w.div("read data")
        w.sig(f"{I}.m_axi4_rvalid")
        w.sig(f"{I}.m_axi4_rready")
        w.sig(f"{I}.m_axi4_rdata")
        w.sig(f"{I}.m_axi4_rlast")
        w.sig(f"{I}.m_axi4_rresp", filt="axi_resp")
    return body

def g_dcpu(w):
    def body():
        w.sig(f"{ROOT}.d_req_valid")
        w.sig(f"{ROOT}.d_req_ready")
        w.sig(f"{ROOT}.d_req_addr")
        w.sig(f"{ROOT}.d_req_cmd", filt="cmd")
        w.sig(f"{ROOT}.d_req_size", filt="size")
        w.sig(f"{ROOT}.d_req_wdata")
        w.div("response")
        w.sig(f"{ROOT}.d_resp_valid")
        w.sig(f"{ROOT}.d_resp_data")
        w.sig(f"{ROOT}.d_resp_error")
    return body

def g_ds1(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.s1_valid")
        w.sig(f"{D}.s1_addr")
        w.sig(f"{D}.s1_cmd", filt="cmd")
        w.sig(f"{D}.s1_size", filt="size")
        w.sig(f"{D}.s1_wdata")
        w.sig(f"{D}.s1_rob", DEC)
        w.div("lookup")
        w.sig(f"{D}.s1_data_ok")
        w.sig(f"{D}.hit")
        w.sig(f"{D}.hit_oh")
        w.sig(f"{D}.hit_way", DEC)
        w.sig(f"{D}.hit_busy")
        w.sig(f"{D}.hit_word")
        w.div("retire / stall")
        w.sig(f"{D}.s1_can_retire")
        w.sig(f"{D}.s1_busy")
        w.sig(f"{D}.s1_store_hit")
        w.sig(f"{D}.s1_reread")
        w.sig(f"{D}.s1_wait_fill")
        w.sig(f"{D}.array_rd_busy")
        w.div("victim")
        w.sig(f"{D}.victim_way", DEC)
        w.sig(f"{D}.victim_valid")
        w.sig(f"{D}.victim_dirty")
        w.sig(f"{D}.victim_tag")
        w.sig(f"{D}.busy_way")
    return body

def g_darray(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.tag_rd_en")
        w.sig(f"{D}.tag_rd_index")
        w.sig(f"{D}.tag_rd_valid")
        w.sig(f"{D}.tag_rd_dirty")
        w.sig(f"{D}.tag_rd_tag")
        w.sig(f"{D}.tag_wr_en")
        w.sig(f"{D}.tag_wr_index")
        w.sig(f"{D}.tag_wr_way", DEC)
        w.sig(f"{D}.tag_wr_tag")
        w.sig(f"{D}.tag_wr_valid")
        w.sig(f"{D}.tag_wr_dirty")
        w.div("data array")
        w.sig(f"{D}.dat_rd_en")
        w.sig(f"{D}.dat_rd_addr")
        w.sig(f"{D}.dat_wr_en")
        w.sig(f"{D}.dat_wr_way", DEC)
        w.sig(f"{D}.dat_wr_addr")
        w.sig(f"{D}.dat_wr_data")
        w.sig(f"{D}.dat_wr_strb")
        w.div("forwarding (write in the cycle of the read)")
        w.sig(f"{D}.fwd_valid")
        w.sig(f"{D}.fwd_addr")
        w.sig(f"{D}.fwd_way", DEC)
        w.sig(f"{D}.fwd_strb")
        w.sig(f"{D}.tfwd_en")
        w.sig(f"{D}.tfwd_index")
        w.sig(f"{D}.tfwd_way", DEC)
        w.sig(f"{D}.tfwd_valid")
        w.sig(f"{D}.tfwd_dirty")
    return body

def g_dmshr(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.f_state", filt="f_state")
        w.sig(f"{D}.f_beat", DEC)
        w.sig(f"{D}.f_err")
        w.sig(f"{D}.fill_wr_en")
        w.sig(f"{D}.fill_beat_now")
        w.sig(f"{D}.f_wb_word", DEC)
        w.sig(f"{D}.f_wb_way", DEC)
        w.div("MSHR")
        w.sig(f"{D}.ms_valid")
        w.sig(f"{D}.ms_count", DEC)
        w.sig(f"{D}.ms_head", DEC)
        w.sig(f"{D}.ms_tail", DEC)
        w.sig(f"{D}.ms_full")
        w.sig(f"{D}.ms_locked")
        w.sig(f"{D}.ms_wb_needed")
        w.sig(f"{D}.ms_st_pending")
        w.array(D, "ms_line")
        w.array(D, "ms_way", fmt=DEC)
        w.div("attach / match")
        w.sig(f"{D}.ms_match")
        w.sig(f"{D}.ms_match_id", DEC)
        w.sig(f"{D}.ms_attach_ok")
    return body

def g_dwb(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.w_state", filt="w_state")
        w.sig(f"{D}.w_beat", DEC)
        w.sig(f"{D}.wb_valid")
        w.sig(f"{D}.wb_count", DEC)
        w.sig(f"{D}.wb_head", DEC)
        w.sig(f"{D}.wb_tail", DEC)
        w.sig(f"{D}.wb_full")
        w.sig(f"{D}.wb_empty")
        w.array(D, "wb_line")
    return body

def g_drob(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.rob_valid")
        w.sig(f"{D}.rob_done")
        w.sig(f"{D}.rob_wait")
        w.sig(f"{D}.rob_st")
        w.sig(f"{D}.rob_err")
        w.sig(f"{D}.rob_count", DEC)
        w.sig(f"{D}.rob_head", DEC)
        w.sig(f"{D}.rob_tail", DEC)
        w.sig(f"{D}.rob_full")
    return body

def g_dmisc(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.fl_state", filt="fl_state")
        w.sig(f"{D}.fl_index")
        w.sig(f"{D}.fl_way", DEC)
        w.sig(f"{D}.fl_busy")
        w.div("uncached (peripheral bus)")
        w.sig(f"{D}.u_state", filt="u_state")
        w.div("LR / SC reservation")
        w.sig(f"{D}.res_valid")
        w.sig(f"{D}.res_line")
        w.div("idle")
        w.sig(f"{D}.all_idle")
    return body

def g_daxi(w):
    D = f"{ROOT}.u_cache.u_dcache"
    def body():
        w.sig(f"{D}.m_axi4_arvalid")
        w.sig(f"{D}.m_axi4_arready")
        w.sig(f"{D}.m_axi4_araddr")
        w.sig(f"{D}.m_axi4_arlen", DEC)
        w.sig(f"{D}.m_axi4_arid", filt="axi_id")
        w.sig(f"{D}.m_axi4_rvalid")
        w.sig(f"{D}.m_axi4_rready")
        w.sig(f"{D}.m_axi4_rdata")
        w.sig(f"{D}.m_axi4_rlast")
        w.sig(f"{D}.m_axi4_rresp", filt="axi_resp")
        w.div("write (line writeback)")
        w.sig(f"{D}.m_axi4_awvalid")
        w.sig(f"{D}.m_axi4_awready")
        w.sig(f"{D}.m_axi4_awaddr")
        w.sig(f"{D}.m_axi4_awlen", DEC)
        w.sig(f"{D}.m_axi4_awid", filt="axi_id")
        w.sig(f"{D}.m_axi4_wvalid")
        w.sig(f"{D}.m_axi4_wready")
        w.sig(f"{D}.m_axi4_wdata")
        w.sig(f"{D}.m_axi4_wstrb")
        w.sig(f"{D}.m_axi4_wlast")
        w.sig(f"{D}.m_axi4_bvalid")
        w.sig(f"{D}.m_axi4_bready")
        w.sig(f"{D}.m_axi4_bresp", filt="axi_resp")
    return body

def g_arb(w):
    A = f"{ROOT}.u_cache.u_arb"
    def body():
        w.sig(f"{A}.x4r_act")
        w.sig(f"{A}.x4r_g1")
        w.sig(f"{A}.x4w_act")
        w.sig(f"{A}.x4w_g1")
        w.div("memory bus out of CPU_CACHE")
        w.sig(f"{ROOT}.m_axi4_arvalid")
        w.sig(f"{ROOT}.m_axi4_arready")
        w.sig(f"{ROOT}.m_axi4_araddr")
        w.sig(f"{ROOT}.m_axi4_arlen", DEC)
        w.sig(f"{ROOT}.m_axi4_arid", filt="axi_id")
        w.sig(f"{ROOT}.m_axi4_rvalid")
        w.sig(f"{ROOT}.m_axi4_rready")
        w.sig(f"{ROOT}.m_axi4_rdata")
        w.sig(f"{ROOT}.m_axi4_rlast")
        w.sig(f"{ROOT}.m_axi4_rid", filt="axi_id")
        w.sig(f"{ROOT}.m_axi4_awvalid")
        w.sig(f"{ROOT}.m_axi4_awready")
        w.sig(f"{ROOT}.m_axi4_awaddr")
        w.sig(f"{ROOT}.m_axi4_wvalid")
        w.sig(f"{ROOT}.m_axi4_wready")
        w.sig(f"{ROOT}.m_axi4_wlast")
        w.sig(f"{ROOT}.m_axi4_bvalid")
        w.sig(f"{ROOT}.m_axi4_bresp", filt="axi_resp")
    return body

def g_mem(w):
    M = f"{ROOT}.u_mem"
    def body():
        w.sig(f"{M}.rstate", filt="ram_r")
        w.sig(f"{M}.rbeat", DEC)
        w.sig(f"{M}.raddr_r")
        w.sig(f"{M}.wstate", filt="ram_w")
        w.sig(f"{M}.wbeat", DEC)
        w.sig(f"{M}.waddr_r")
        w.sig(f"{M}.stall_en")
    return body

def g_axil(w):
    def body():
        w.sig(f"{ROOT}.m_axil_arvalid")
        w.sig(f"{ROOT}.m_axil_arready")
        w.sig(f"{ROOT}.m_axil_araddr")
        w.sig(f"{ROOT}.m_axil_rvalid")
        w.sig(f"{ROOT}.m_axil_rdata")
        w.sig(f"{ROOT}.m_axil_awvalid")
        w.sig(f"{ROOT}.m_axil_awaddr")
        w.sig(f"{ROOT}.m_axil_wvalid")
        w.sig(f"{ROOT}.m_axil_wdata")
        w.sig(f"{ROOT}.m_axil_bvalid")
    return body

#---------------------------------------------------------------------------
# One save file per pattern
#---------------------------------------------------------------------------
def make(name, comment, icache_first):
    vcd   = os.path.join(HERE, f"tb_CACHE_{name}.vcd")
    marks = read_marks(os.path.join(HERE, f"tb_CACHE_{name}.marks"))
    if not os.path.exists(vcd):
        print("skip", os.path.basename(vcd), "(not built, run: make wave-perf)")
        return
    w = Gtkw(vcd, os.path.join(HERE, "gtkw_filter"))
    w.group("1. CLOCK / CYCLE", g_clock(w))
    if icache_first:
        w.group("2. CPU SIDE : INSTRUCTION FETCH", g_icpu(w))
        w.group("3. I$ : LOOKUP / ARRAYS / FILL", g_icache(w))
        w.group("4. I$ : AXI4 LINE FILL", g_iaxi(w))
        w.group("5. CPU SIDE : LOAD / STORE", g_dcpu(w), collapsed=True)
        w.group("6. D$ : STAGE 1", g_ds1(w), collapsed=True)
        w.group("7. D$ : ARRAYS", g_darray(w), collapsed=True)
        w.group("8. D$ : MSHR / FILL", g_dmshr(w), collapsed=True)
        w.group("9. D$ : WRITEBACK", g_dwb(w), collapsed=True)
        w.group("10. D$ : RESPONSE ORDER (ROB)", g_drob(w), collapsed=True)
        w.group("11. D$ : FLUSH / UNCACHED / LR-SC", g_dmisc(w), collapsed=True)
        w.group("12. D$ : AXI4", g_daxi(w), collapsed=True)
    else:
        w.group("2. CPU SIDE : LOAD / STORE", g_dcpu(w))
        w.group("3. D$ : STAGE 1 (hit / miss decision)", g_ds1(w))
        w.group("4. D$ : ARRAYS (tag / data / forwarding)", g_darray(w))
        w.group("5. D$ : MSHR / LINE FILL", g_dmshr(w))
        w.group("6. D$ : WRITEBACK", g_dwb(w))
        w.group("7. D$ : RESPONSE ORDER (ROB)", g_drob(w))
        w.group("8. D$ : AXI4", g_daxi(w))
        w.group("9. D$ : FLUSH / UNCACHED / LR-SC", g_dmisc(w), collapsed=True)
        w.group("10. CPU SIDE : INSTRUCTION FETCH", g_icpu(w), collapsed=True)
        w.group("11. I$ : LOOKUP / ARRAYS / FILL", g_icache(w), collapsed=True)
        w.group("12. I$ : AXI4 LINE FILL", g_iaxi(w), collapsed=True)
    w.group("13. BUS_ARB / MEMORY BUS", g_arb(w))
    w.group("14. AXI4 MEMORY MODEL", g_mem(w), collapsed=True)
    w.group("15. PERIPHERAL BUS (AXI4-Lite)", g_axil(w), collapsed=True)
    w.write(os.path.join(HERE, f"tb_CACHE_{name}.gtkw"), vcd, comment, marks)

if __name__ == "__main__":
    write_filters(os.path.join(HERE, "gtkw_filter"))
    make("ihit",  ["mmRISC-2 L1 I$ : hit burst (make wave-perf, +perf=1)",
                   "every fetch hits, one fetch per cycle"], True)
    make("imiss", ["mmRISC-2 L1 I$ : miss burst (make wave-perf, +perf=2)",
                   "every fetch misses: AR, 8 beats, early restart, tag write"], True)
    make("dhit",  ["mmRISC-2 L1 D$ : hit burst (make wave-perf, +perf=3)",
                   "load burst and store burst, one access per cycle"], False)
    make("dmiss", ["mmRISC-2 L1 D$ : miss burst (make wave-perf, +perf=4)",
                   "fill, write allocate and dirty eviction (writeback + fill)"], False)
