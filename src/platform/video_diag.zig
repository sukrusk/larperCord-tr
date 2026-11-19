//! Per-second non-secret video TX/RX telemetry written to `<cache>/larpercord/video_diag.log`.
//! Records only counters, SSRC/PT numbers, dimensions, hw/sw flags, and HRESULT codes (never keys/tokens/PII).
const builtin = @import("builtin");
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");

const windows = builtin.os.tag == .windows;
const max_log_bytes: u64 = 256 * 1024;

const AtomicU32 = std.atomic.Value(u32);
const AtomicU16 = std.atomic.Value(u16);
const AtomicU8 = std.atomic.Value(u8);
const AtomicI64 = std.atomic.Value(i64);
const AtomicBool = std.atomic.Value(bool);

var rx_op12_ssrc: AtomicU32 = .init(0);
var rx_udp_vid: AtomicU32 = .init(0);
var rx_last_pt: AtomicU8 = .init(0);
var rx_asm_ok: AtomicU32 = .init(0);
var rx_asm_drop: AtomicU32 = .init(0);
var rx_dave_ok: AtomicU32 = .init(0);
var rx_dave_fail: AtomicU32 = .init(0);
var rx_no_uid: AtomicU32 = .init(0);
var rx_dec_in: AtomicU32 = .init(0);
var rx_dec_out: AtomicU32 = .init(0);
var rx_dec_hw: AtomicBool = .init(false);
var rx_dec_hr: AtomicU32 = .init(0);
var rx_w: AtomicU16 = .init(0);
var rx_h: AtomicU16 = .init(0);
var rx_ui_watch: AtomicU32 = .init(0);
var rx_ui_cam: AtomicU32 = .init(0);

var tx_cap: AtomicU32 = .init(0);
var tx_enc: AtomicU32 = .init(0);
var tx_drop: AtomicU32 = .init(0);
var tx_sent: AtomicU32 = .init(0);
var tx_rtp: AtomicU32 = .init(0);
var tx_pli: AtomicU32 = .init(0);
var tx_nack: AtomicU32 = .init(0);
var tx_remb: AtomicU32 = .init(0);
var tx_hw: AtomicBool = .init(false);
var tx_w: AtomicU16 = .init(0);
var tx_h: AtomicU16 = .init(0);

var last_flush_ms: AtomicI64 = .init(0);
var flush_busy: AtomicBool = .init(false);

pub fn setOp12Ssrc(ssrc: u32) void {
    rx_op12_ssrc.store(ssrc, .monotonic);
}

pub fn rxUdpPkt(pt: u7) void {
    rx_last_pt.store(pt, .monotonic);
    _ = rx_udp_vid.fetchAdd(1, .monotonic);
}

pub fn rxAsmFrame() void {
    _ = rx_asm_ok.fetchAdd(1, .monotonic);
}

pub fn rxAsmDrop() void {
    _ = rx_asm_drop.fetchAdd(1, .monotonic);
}

pub fn rxDaveOk() void {
    _ = rx_dave_ok.fetchAdd(1, .monotonic);
}

pub fn rxDaveFail() void {
    _ = rx_dave_fail.fetchAdd(1, .monotonic);
}

pub fn rxNoUid() void {
    _ = rx_no_uid.fetchAdd(1, .monotonic);
}

pub fn rxDecIn() void {
    _ = rx_dec_in.fetchAdd(1, .monotonic);
}

pub fn rxDecOut(hw: bool, hr: i32, w: u16, h: u16) void {
    rx_dec_hw.store(hw, .monotonic);
    rx_dec_hr.store(@bitCast(hr), .monotonic);
    rx_w.store(w, .monotonic);
    rx_h.store(h, .monotonic);
    _ = rx_dec_out.fetchAdd(1, .monotonic);
}

pub fn rxDecErr(hw: bool, hr: i32) void {
    rx_dec_hw.store(hw, .monotonic);
    rx_dec_hr.store(@bitCast(hr), .monotonic);
}

pub fn uiUpload(is_stream_watch: bool) void {
    if (is_stream_watch) {
        _ = rx_ui_watch.fetchAdd(1, .monotonic);
    } else {
        _ = rx_ui_cam.fetchAdd(1, .monotonic);
    }
}

pub fn txCap() void {
    _ = tx_cap.fetchAdd(1, .monotonic);
}

pub fn txEnc(hw: bool, w: u16, h: u16) void {
    tx_hw.store(hw, .monotonic);
    tx_w.store(w, .monotonic);
    tx_h.store(h, .monotonic);
    _ = tx_enc.fetchAdd(1, .monotonic);
}

pub fn txDrop() void {
    _ = tx_drop.fetchAdd(1, .monotonic);
}

pub fn txSent() void {
    _ = tx_sent.fetchAdd(1, .monotonic);
}

pub fn txRtp() void {
    _ = tx_rtp.fetchAdd(1, .monotonic);
}

pub fn txPli() void {
    _ = tx_pli.fetchAdd(1, .monotonic);
}

pub fn txNack() void {
    _ = tx_nack.fetchAdd(1, .monotonic);
}

pub fn txRemb() void {
    _ = tx_remb.fetchAdd(1, .monotonic);
}

pub fn maybeFlush(now_ms: i64) void {
    if (comptime builtin.is_test or builtin.cpu.arch == .wasm32) return;
    const prev = last_flush_ms.load(.monotonic);
    if (now_ms - prev < 1000) return;
    if (flush_busy.swap(true, .acquire)) return;
    defer flush_busy.store(false, .release);

    const cur_prev = last_flush_ms.load(.monotonic);
    if (now_ms - cur_prev < 1000) return;
    last_flush_ms.store(now_ms, .monotonic);

    const udp = rx_udp_vid.swap(0, .monotonic);
    const asm_ok = rx_asm_ok.swap(0, .monotonic);
    const asm_drop = rx_asm_drop.swap(0, .monotonic);
    const dave_ok = rx_dave_ok.swap(0, .monotonic);
    const dave_fail = rx_dave_fail.swap(0, .monotonic);
    const no_uid = rx_no_uid.swap(0, .monotonic);
    const dec_in = rx_dec_in.swap(0, .monotonic);
    const dec_out = rx_dec_out.swap(0, .monotonic);
    const ui_w = rx_ui_watch.swap(0, .monotonic);
    const ui_c = rx_ui_cam.swap(0, .monotonic);

    const tcap = tx_cap.swap(0, .monotonic);
    const tenc = tx_enc.swap(0, .monotonic);
    const tdrop = tx_drop.swap(0, .monotonic);
    const tsent = tx_sent.swap(0, .monotonic);
    const trtp = tx_rtp.swap(0, .monotonic);
    const tpli = tx_pli.swap(0, .monotonic);
    const tnack = tx_nack.swap(0, .monotonic);
    const tremb = tx_remb.swap(0, .monotonic);

    const active = udp + asm_ok + asm_drop + dec_in + dec_out + tcap + tenc + tsent + trtp + ui_w + ui_c;
    if (active == 0) return;

    var ch_buf: [512]u8 = undefined;
    const base = sys.cacheHome(&ch_buf) orelse return;
    var dir_buf: [600]u8 = undefined;
    const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}/larpercord", .{base}, 0) catch return;
    sys.mkdirPrivate(dir_z.ptr);
    var path_buf: [640]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}/larpercord/video_diag.log", .{base}, 0) catch return;

    const reset = if (sys.fileSize(path_z.ptr)) |sz| sz >= max_log_bytes else false;
    const base_flags = c.O_WRONLY | c.O_CREAT | (if (reset) c.O_TRUNC else c.O_APPEND);
    const flags = if (windows) base_flags | c.O_BINARY else base_flags | c.O_CLOEXEC;
    const fd = c.open(path_z.ptr, flags, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);

    var line_buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "t={d} rx[op12={d} udp={d} pt={d} asm={d}/{d} dave={d}/{d} uid0={d} dec={d}/{d}(hw={d} hr=0x{x:0>8} {d}x{d}) ui={d}/{d}] tx[cap={d} enc={d}(hw={d} {d}x{d}) drop={d} sent={d} rtp={d} rtcp={d}/{d}/{d}]\n",
        .{
            now_ms,
            rx_op12_ssrc.load(.monotonic),
            udp,
            rx_last_pt.load(.monotonic),
            asm_ok,
            asm_drop,
            dave_ok,
            dave_fail,
            no_uid,
            dec_in,
            dec_out,
            @intFromBool(rx_dec_hw.load(.monotonic)),
            rx_dec_hr.load(.monotonic),
            rx_w.load(.monotonic),
            rx_h.load(.monotonic),
            ui_w,
            ui_c,
            tcap,
            tenc,
            @intFromBool(tx_hw.load(.monotonic)),
            tx_w.load(.monotonic),
            tx_h.load(.monotonic),
            tdrop,
            tsent,
            trtp,
            tpli,
            tnack,
            tremb,
        },
    ) catch return;
    _ = c.write(fd, line.ptr, @intCast(line.len));
}
