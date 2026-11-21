//! Gerenciador opcional do GoodbyeDPI (Windows, WinDivert) para operadoras com DPI
//! rigoroso (como Superonline/Türk Telekom): baixa o release oficial verificado
//! por SHA-256 em `<cache>/larpercord/dpi/`, inicia via UAC padrão do Windows e
//! detecta se já está em execução. Em testes/Linux ou sem clique explícito, nada roda.
const std = @import("std");
const builtin = @import("builtin");

const is_win = builtin.os.tag == .windows;
const c = if (builtin.is_test) struct {} else @import("c");
const sys = if (builtin.is_test) struct {} else @import("../platform/sys.zig");
const updater = if (builtin.is_test) struct {} else @import("updater.zig");
const ffmpeg_get = if (builtin.is_test) struct {} else @import("ffmpeg_get.zig");

const alloc = std.heap.c_allocator;

pub const zip_url = "https://github.com/ValdikSS/GoodbyeDPI/releases/download/0.2.3rc3/goodbyedpi-0.2.3rc3-2.zip";
pub const zip_sha256 = "37f96b32d050dadcc930a639eba68e1ccd57ed5c04a5f77dfca908f01905a4c5";
pub const zip_bytes: usize = 1_084_060;
pub const source = "github.com/ValdikSS/GoodbyeDPI";

const needed = [_][2][]const u8{
    .{ "x86_64/goodbyedpi.exe", "goodbyedpi.exe" },
    .{ "x86_64/WinDivert.dll", "WinDivert.dll" },
    .{ "x86_64/WinDivert64.sys", "WinDivert64.sys" },
};

pub const Phase = enum(u8) { idle, downloading, installing, ready, failed };
pub const Failure = enum(u8) { none, network, hash, disk };

var phase_now: std.atomic.Value(Phase) = .init(.idle);
var failure_now: std.atomic.Value(Failure) = .init(.none);
var got_bytes: std.atomic.Value(usize) = .init(0);
var run_cache_ms: std.atomic.Value(i64) = .init(0);
var run_cache_val: std.atomic.Value(bool) = .init(false);
pub var qa_no_network = false;

/// Presets testados na Turquia (GoodbyeDPI 0.2.3rc3-2):
/// 0: Türkiye Önerilen (-5 + TTL5 + Yandex DNS alt-port 1253)
/// 1: Türkiye Sert / Superonline (-9 + Yandex DNS alt-port 1253)
/// 2: Sadece DPI (-5 --set-ttl 5; DNS uygulaması/DoH üzerinden)
/// 3: Evrensel Uyum (-p -r -s -f 2 -k 2 -n -e 2)
pub fn argsForPreset(preset: u8) []const u8 {
    return switch (preset) {
        1 => "-9 --dns-addr 77.88.8.8 --dns-port 1253 --dnsv6-addr 2a02:6b8::feed:0ff --dnsv6-port 1253",
        2 => "-5 --set-ttl 5",
        3 => "-p -r -s -f 2 -k 2 -n -e 2",
        else => "-5 --set-ttl 5 --dns-addr 77.88.8.8 --dns-port 1253 --dnsv6-addr 2a02:6b8::feed:0ff --dnsv6-port 1253",
    };
}

pub fn supported() bool {
    return is_win;
}

pub fn phase() Phase {
    return phase_now.load(.acquire);
}

pub fn failure() Failure {
    return failure_now.load(.acquire);
}

pub fn percent() u8 {
    return @intCast(@min(got_bytes.load(.monotonic) * 100 / zip_bytes, 100));
}

pub fn installDir(buf: []u8) ?[]const u8 {
    if (builtin.is_test or !is_win) return null;
    var hb: [400]u8 = undefined;
    const base = sys.cacheHome(&hb) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/larpercord/dpi", .{base}) catch null;
}

pub fn findExe(exe_buf: []u8, dir_buf: []u8) ?struct { exe: []const u8, dir: []const u8 } {
    if (builtin.is_test or !is_win) return null;
    // 1. Önce kullanıcının yanına koyduğu goodbyedpi.exe varsa onu tanı.
    var sb: [1024]u8 = undefined;
    if (sys.selfExe(&sb)) |self_p| {
        if (std.fs.path.dirname(self_p)) |self_dir| {
            var p1b: [1100]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&p1b, "{s}\\goodbyedpi.exe", .{self_dir}, 0)) |pz| {
                if (sys.exists(pz.ptr)) {
                    if (pz.len <= exe_buf.len and self_dir.len <= dir_buf.len) {
                        @memcpy(exe_buf[0..pz.len], pz);
                        @memcpy(dir_buf[0..self_dir.len], self_dir);
                        return .{ .exe = exe_buf[0..pz.len], .dir = dir_buf[0..self_dir.len] };
                    }
                }
            } else |_| {}
        }
    }
    // 2. Uygulamanın önbellek/dpi klasöründe indirili mi?
    var db: [512]u8 = undefined;
    const dir = installDir(&db) orelse return null;
    var exb: [600]u8 = undefined;
    const ez = std.fmt.bufPrintSentinel(&exb, "{s}\\goodbyedpi.exe", .{dir}, 0) catch return null;
    if (!sys.exists(ez.ptr)) return null;
    var dvb: [600]u8 = undefined;
    const dz = std.fmt.bufPrintSentinel(&dvb, "{s}\\WinDivert64.sys", .{dir}, 0) catch return null;
    if (!sys.exists(dz.ptr)) return null;
    if (ez.len > exe_buf.len or dir.len > dir_buf.len) return null;
    @memcpy(exe_buf[0..ez.len], ez);
    @memcpy(dir_buf[0..dir.len], dir);
    return .{ .exe = exe_buf[0..ez.len], .dir = dir_buf[0..dir.len] };
}

pub fn isInstalled() bool {
    if (builtin.is_test or !is_win) return false;
    var eb: [1100]u8 = undefined;
    var db: [1024]u8 = undefined;
    return findExe(&eb, &db) != null;
}

pub fn startDownload() void {
    if (builtin.is_test or !is_win) return;
    switch (phase()) {
        .downloading, .installing => return,
        else => {},
    }
    got_bytes.store(0, .monotonic);
    failure_now.store(.none, .release);
    phase_now.store(.downloading, .release);
    if (qa_no_network) {
        finish(.ready);
        return;
    }
    if (c.SDL_CreateThread(runDownload, "gdpi-get", null)) |thr| {
        c.SDL_DetachThread(thr);
    } else {
        failure_now.store(.disk, .release);
        phase_now.store(.failed, .release);
    }
}

fn finish(p: Phase) void {
    phase_now.store(p, .release);
    if (!builtin.is_test) updater.wakeUi();
}

fn runDownload(_: ?*anyopaque) callconv(.c) c_int {
    install() catch |e| {
        failure_now.store(switch (e) {
            error.Network, error.NoRelease => .network,
            error.BadHash, error.BadZip => .hash,
            else => .disk,
        }, .release);
        finish(.failed);
        return 0;
    };
    finish(.ready);
    return 0;
}

fn install() !void {
    if (builtin.is_test) return;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    try data.ensureTotalCapacity(alloc, zip_bytes);
    try updater.fetch(zip_url, &data, zip_bytes + 4096, &got_bytes);

    var want: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, zip_sha256) catch unreachable;
    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.items, &got, .{});
    if (!std.mem.eql(u8, &got, &want)) return error.BadHash;

    phase_now.store(.installing, .release);
    updater.wakeUi();

    var db: [512]u8 = undefined;
    const dir = installDir(&db) orelse return error.Disk;
    var dz: [520]u8 = undefined;
    if (!c.SDL_CreateDirectory((std.fmt.bufPrintSentinel(&dz, "{s}", .{dir}, 0) catch return error.Disk).ptr)) return error.Disk;

    var pb: [600]u8 = undefined;
    var fb: [600]u8 = undefined;
    for (needed) |item| {
        const body = try ffmpeg_get.unzipPath(alloc, data.items, item[0]);
        defer alloc.free(body);
        const part = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.part", .{ dir, item[1] }, 0) catch return error.Disk;
        if (!c.SDL_SaveFile(part.ptr, body.ptr, body.len)) return error.Disk;
    }
    for (needed) |item| {
        const part = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.part", .{ dir, item[1] }, 0) catch return error.Disk;
        const final = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ dir, item[1] }, 0) catch return error.Disk;
        if (!c.SDL_RenamePath(part.ptr, final.ptr)) return error.Disk;
    }
}

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};

pub fn isRunning(now_ms: i64) bool {
    if (builtin.is_test or !is_win) return false;
    const prev = run_cache_ms.load(.acquire);
    if (now_ms > 0 and now_ms - prev < 800) return run_cache_val.load(.acquire);
    run_cache_ms.store(now_ms, .release);
    const alive = checkProcessRunning();
    run_cache_val.store(alive, .release);
    return alive;
}

fn checkProcessRunning() bool {
    if (builtin.is_test or !is_win) return false;
    const k32 = c.SDL_LoadObject("kernel32.dll") orelse return false;
    defer c.SDL_UnloadObject(k32);
    const SnapFn = *const fn (u32, u32) callconv(.winapi) ?*anyopaque;
    const NextFn = *const fn (*anyopaque, *PROCESSENTRY32W) callconv(.winapi) c_int;
    const CloseFn = *const fn (*anyopaque) callconv(.winapi) c_int;
    const snap_fn: SnapFn = @ptrCast(@alignCast(c.SDL_LoadFunction(k32, "CreateToolhelp32Snapshot") orelse return false));
    const first_fn: NextFn = @ptrCast(@alignCast(c.SDL_LoadFunction(k32, "Process32FirstW") orelse return false));
    const next_fn: NextFn = @ptrCast(@alignCast(c.SDL_LoadFunction(k32, "Process32NextW") orelse return false));
    const close_fn: CloseFn = @ptrCast(@alignCast(c.SDL_LoadFunction(k32, "CloseHandle") orelse return false));

    const TH32CS_SNAPPROCESS: u32 = 0x00000002;
    const h = snap_fn(TH32CS_SNAPPROCESS, 0) orelse return false;
    if (@intFromPtr(h) == std.math.maxInt(usize)) return false;
    defer _ = close_fn(h);

    var pe = std.mem.zeroes(PROCESSENTRY32W);
    pe.dwSize = @sizeOf(PROCESSENTRY32W);
    if (first_fn(h, &pe) == 0) return false;
    while (true) {
        const wlen = std.mem.indexOfScalar(u16, &pe.szExeFile, 0) orelse pe.szExeFile.len;
        var nb: [260]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&nb, pe.szExeFile[0..wlen]) catch 0;
        if (std.ascii.eqlIgnoreCase(nb[0..n], "goodbyedpi.exe")) return true;
        if (next_fn(h, &pe) == 0) break;
    }
    return false;
}

fn toWideZ(utf8: []const u8, out: []u16) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], utf8) catch return null;
    out[n] = 0;
    return out[0..n :0];
}

/// Standart Windows UAC onayıyla goodbyedpi.exe başlatır (sessiz yetki yükseltme yapmaz).
pub fn startProcess(preset: u8) bool {
    if (builtin.is_test or !is_win or qa_no_network) return false;
    var eb: [1100]u8 = undefined;
    var db: [1024]u8 = undefined;
    const found = findExe(&eb, &db) orelse return false;

    var w_exe: [1100]u16 = undefined;
    var w_args: [256]u16 = undefined;
    var w_dir: [1024]u16 = undefined;
    const exe_w = toWideZ(found.exe, &w_exe) orelse return false;
    const args_w = toWideZ(argsForPreset(preset), &w_args) orelse return false;
    const dir_w = toWideZ(found.dir, &w_dir) orelse return false;
    const runas_w = std.unicode.utf8ToUtf16LeStringLiteral("runas");

    const ret = c.ShellExecuteW(null, runas_w.ptr, exe_w.ptr, args_w.ptr, dir_w.ptr, 7); // SW_SHOWMINNOACTIVE
    run_cache_ms.store(0, .release);
    return @intFromPtr(ret) > 32;
}

pub fn stopProcess() bool {
    if (builtin.is_test or !is_win or qa_no_network) return false;
    const runas_w = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    const tk_w = std.unicode.utf8ToUtf16LeStringLiteral("taskkill.exe");
    const arg_w = std.unicode.utf8ToUtf16LeStringLiteral("/F /IM goodbyedpi.exe");
    const ret = c.ShellExecuteW(null, runas_w.ptr, tk_w.ptr, arg_w.ptr, null, 0); // SW_HIDE
    run_cache_ms.store(0, .release);
    return @intFromPtr(ret) > 32;
}

// --- Birim testleri ---

const t = std.testing;

test "argsForPreset retorna parâmetros oficiais de Türkiye DPI" {
    try t.expect(std.mem.indexOf(u8, argsForPreset(0), "--set-ttl 5") != null);
    try t.expect(std.mem.indexOf(u8, argsForPreset(0), "77.88.8.8") != null);
    try t.expect(std.mem.indexOf(u8, argsForPreset(1), "-9") != null);
    try t.expectEqualStrings("-5 --set-ttl 5", argsForPreset(2));
    try t.expectEqualStrings("-p -r -s -f 2 -k 2 -n -e 2", argsForPreset(3));
}
