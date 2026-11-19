//! Injeção segura de entrada remota no Windows via `user32.dll::SendInput`
//! com mapeamento USB HID (`SDL_Scancode`) -> AT Set-1 Scancode, suporte a
//! área virtual multi-monitor `[0..65535]` e liberação automática de teclas presas.
const std = @import("std");
const c = @import("c");
const com = @import("com.zig");
const video_cfg = @import("../../core/video_cfg.zig");

const MOUSEEVENTF_MOVE: u32 = 0x0001;
const MOUSEEVENTF_LEFTDOWN: u32 = 0x0002;
const MOUSEEVENTF_LEFTUP: u32 = 0x0004;
const MOUSEEVENTF_RIGHTDOWN: u32 = 0x0008;
const MOUSEEVENTF_RIGHTUP: u32 = 0x0010;
const MOUSEEVENTF_MIDDLEDOWN: u32 = 0x0020;
const MOUSEEVENTF_MIDDLEUP: u32 = 0x0040;
const MOUSEEVENTF_XDOWN: u32 = 0x0080;
const MOUSEEVENTF_XUP: u32 = 0x0100;
const MOUSEEVENTF_WHEEL: u32 = 0x0800;
const MOUSEEVENTF_VIRTUALDESK: u32 = 0x4000;
const MOUSEEVENTF_ABSOLUTE: u32 = 0x8000;

const KEYEVENTF_EXTENDEDKEY: u32 = 0x0001;
const KEYEVENTF_KEYUP: u32 = 0x0002;
const KEYEVENTF_SCANCODE: u32 = 0x0008;

const MOUSEINPUT = extern struct {
    dx: i32 = 0,
    dy: i32 = 0,
    mouseData: u32 = 0,
    dwFlags: u32 = 0,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

const KEYBDINPUT = extern struct {
    wVk: u16 = 0,
    wScan: u16 = 0,
    dwFlags: u32 = 0,
    time: u32 = 0,
    dwExtraInfo: usize = 0,
};

const INPUT = extern struct {
    type: u32,
    u: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        pad: [32]u8,
    },
};

comptime {
    if (@sizeOf(INPUT) != 40) @compileError("Win64 SendInput INPUT struct size mismatch");
}

const SendInputFn = *const fn (u32, [*]const INPUT, i32) callconv(.winapi) u32;
const GetWindowRectFn = *const fn (com.HWND, *com.RECT) callconv(.winapi) com.BOOL;
const GetSystemMetricsFn = *const fn (i32) callconv(.winapi) i32;

pub const Injector = struct {
    user32: ?*c.SDL_SharedObject = null,
    send_input: ?SendInputFn = null,
    get_rect: ?GetWindowRectFn = null,
    get_metrics: ?GetSystemMetricsFn = null,
    target_hwnd: com.HWND = null,
    btn_mask: u8 = 0,
    held_scans: [16]struct { scan: u16 = 0, ext: bool = false } = @splat(.{}),
    held_count: u8 = 0,

    pub fn init(target_hwnd_int: u64) !Injector {
        const lib = c.SDL_LoadObject("user32.dll") orelse return error.User32Missing;
        errdefer c.SDL_UnloadObject(lib);
        return .{
            .user32 = lib,
            .send_input = @ptrCast(@alignCast(c.SDL_LoadFunction(lib, "SendInput") orelse return error.SendInputMissing)),
            .get_rect = @ptrCast(@alignCast(c.SDL_LoadFunction(lib, "GetWindowRect"))),
            .get_metrics = @ptrCast(@alignCast(c.SDL_LoadFunction(lib, "GetSystemMetrics"))),
            .target_hwnd = if (target_hwnd_int != 0) @ptrFromInt(@as(usize, @intCast(target_hwnd_int))) else null,
        };
    }

    /// Injeta movimento, clique, scroll ou tecla respeitando escopo de janela/desktop.
    pub fn apply(self: *Injector, pkt: video_cfg.RemoteInputPacket, perm: video_cfg.RemotePerm) void {
        if (perm == .off) return;
        const send = self.send_input orelse return;
        switch (pkt.kind) {
            .mouse_move => {
                const abs = self.toVirtualDesktop(pkt.x, pkt.y);
                self.sendMouse(send, abs[0], abs[1], 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK);
            },
            .mouse_btn => {
                const abs = self.toVirtualDesktop(pkt.x, pkt.y);
                self.sendMouse(send, abs[0], abs[1], 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK);
                var flag: u32 = 0;
                var mdata: u32 = 0;
                var bit: u8 = 0;
                switch (pkt.code) {
                    1 => {
                        flag = if (pkt.pressed) MOUSEEVENTF_LEFTDOWN else MOUSEEVENTF_LEFTUP;
                        bit = 1;
                    },
                    2 => {
                        flag = if (pkt.pressed) MOUSEEVENTF_MIDDLEDOWN else MOUSEEVENTF_MIDDLEUP;
                        bit = 2;
                    },
                    3 => {
                        flag = if (pkt.pressed) MOUSEEVENTF_RIGHTDOWN else MOUSEEVENTF_RIGHTUP;
                        bit = 4;
                    },
                    4 => {
                        flag = if (pkt.pressed) MOUSEEVENTF_XDOWN else MOUSEEVENTF_XUP;
                        mdata = 1;
                        bit = 8;
                    },
                    5 => {
                        flag = if (pkt.pressed) MOUSEEVENTF_XDOWN else MOUSEEVENTF_XUP;
                        mdata = 2;
                        bit = 16;
                    },
                    else => return,
                }
                if (pkt.pressed) self.btn_mask |= bit else self.btn_mask &= ~bit;
                self.sendMouse(send, abs[0], abs[1], mdata, flag | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK);
            },
            .mouse_wheel => {
                const delta_i16: i16 = @bitCast(pkt.y);
                const wheel: i32 = @as(i32, delta_i16) * 120;
                self.sendMouse(send, 0, 0, @bitCast(wheel), MOUSEEVENTF_WHEEL);
            },
            .key => {
                if (perm != .full) return;
                const mapped = sdlScancodeToWinSet1(pkt.code) orelse return;
                if (pkt.pressed) {
                    self.trackHeld(mapped.scan, mapped.ext, true);
                } else {
                    self.trackHeld(mapped.scan, mapped.ext, false);
                }
                self.sendKey(send, mapped.scan, mapped.ext, pkt.pressed);
            },
            .release_all => self.releaseAll(),
            .ping, .pong => {},
        }
    }

    /// Libera imediatamente qualquer tecla ou botão do mouse ainda pressionado.
    pub fn releaseAll(self: *Injector) void {
        const send = self.send_input orelse return;
        if ((self.btn_mask & 1) != 0) self.sendMouse(send, 0, 0, 0, MOUSEEVENTF_LEFTUP);
        if ((self.btn_mask & 2) != 0) self.sendMouse(send, 0, 0, 0, MOUSEEVENTF_MIDDLEUP);
        if ((self.btn_mask & 4) != 0) self.sendMouse(send, 0, 0, 0, MOUSEEVENTF_RIGHTUP);
        if ((self.btn_mask & 8) != 0) self.sendMouse(send, 0, 0, 1, MOUSEEVENTF_XUP);
        if ((self.btn_mask & 16) != 0) self.sendMouse(send, 0, 0, 2, MOUSEEVENTF_XUP);
        self.btn_mask = 0;

        while (self.held_count > 0) {
            self.held_count -= 1;
            const hk = self.held_scans[self.held_count];
            self.sendKey(send, hk.scan, hk.ext, false);
        }
    }

    pub fn deinit(self: *Injector) void {
        self.releaseAll();
        if (self.user32) |lib| {
            c.SDL_UnloadObject(lib);
            self.user32 = null;
        }
        self.send_input = null;
    }

    fn sendMouse(self: *const Injector, send: SendInputFn, dx: i32, dy: i32, mdata: u32, flags: u32) void {
        _ = self;
        const inp = [1]INPUT{.{
            .type = 0,
            .u = .{ .mi = .{ .dx = dx, .dy = dy, .mouseData = mdata, .dwFlags = flags } },
        }};
        _ = send(1, &inp, @sizeOf(INPUT));
    }

    fn sendKey(self: *const Injector, send: SendInputFn, scan: u16, ext: bool, down: bool) void {
        _ = self;
        var flags: u32 = KEYEVENTF_SCANCODE;
        if (ext) flags |= KEYEVENTF_EXTENDEDKEY;
        if (!down) flags |= KEYEVENTF_KEYUP;
        const inp = [1]INPUT{.{
            .type = 1,
            .u = .{ .ki = .{ .wVk = 0, .wScan = scan, .dwFlags = flags } },
        }};
        _ = send(1, &inp, @sizeOf(INPUT));
    }

    fn trackHeld(self: *Injector, scan: u16, ext: bool, down: bool) void {
        var i: u8 = 0;
        while (i < self.held_count) : (i += 1) {
            if (self.held_scans[i].scan == scan and self.held_scans[i].ext == ext) {
                if (!down) {
                    self.held_count -= 1;
                    self.held_scans[i] = self.held_scans[self.held_count];
                }
                return;
            }
        }
        if (down and self.held_count < self.held_scans.len) {
            self.held_scans[self.held_count] = .{ .scan = scan, .ext = ext };
            self.held_count += 1;
        }
    }

    fn toVirtualDesktop(self: *const Injector, nx: u16, ny: u16) [2]i32 {
        if (self.get_metrics) |gm| {
            // SM_XVIRTUALSCREEN=76, Y=77, CXVIRTUALSCREEN=78, CY=79, CXSCREEN=0, CYSCREEN=1.
            const vx = gm(76);
            const vy = gm(77);
            const vw = @max(gm(78), 1);
            const vh = @max(gm(79), 1);
            var rc: com.RECT = .{
                .left = 0,
                .top = 0,
                .right = @max(gm(0), vw),
                .bottom = @max(gm(1), vh),
            };
            if (self.target_hwnd != null and self.get_rect != null) {
                var wrc: com.RECT = .{};
                if (self.get_rect.?(self.target_hwnd, &wrc) != 0 and wrc.right > wrc.left and wrc.bottom > wrc.top) {
                    rc = wrc;
                }
            }
            const px = @as(f64, @floatFromInt(rc.left)) + (@as(f64, @floatFromInt(rc.right - rc.left)) * (@as(f64, @floatFromInt(nx)) / 65535.0));
            const py = @as(f64, @floatFromInt(rc.top)) + (@as(f64, @floatFromInt(rc.bottom - rc.top)) * (@as(f64, @floatFromInt(ny)) / 65535.0));
            const ax = std.math.clamp(((px - @as(f64, @floatFromInt(vx))) * 65535.0) / @as(f64, @floatFromInt(vw)), 0.0, 65535.0);
            const ay = std.math.clamp(((py - @as(f64, @floatFromInt(vy))) * 65535.0) / @as(f64, @floatFromInt(vh)), 0.0, 65535.0);
            return .{ @intFromFloat(@round(ax)), @intFromFloat(@round(ay)) };
        }
        return .{ nx, ny };
    }
};

const Set1 = struct { scan: u16, ext: bool = false };

fn sdlScancodeToWinSet1(sc: u16) ?Set1 {
    return switch (sc) {
        // Letras A..Z (SDL_SCANCODE_A=4 .. Z=29)
        4 => .{ .scan = 0x1E },
        5 => .{ .scan = 0x30 },
        6 => .{ .scan = 0x2E },
        7 => .{ .scan = 0x20 },
        8 => .{ .scan = 0x12 },
        9 => .{ .scan = 0x21 },
        10 => .{ .scan = 0x22 },
        11 => .{ .scan = 0x23 },
        12 => .{ .scan = 0x17 },
        13 => .{ .scan = 0x24 },
        14 => .{ .scan = 0x25 },
        15 => .{ .scan = 0x26 },
        16 => .{ .scan = 0x32 },
        17 => .{ .scan = 0x31 },
        18 => .{ .scan = 0x18 },
        19 => .{ .scan = 0x19 },
        20 => .{ .scan = 0x10 },
        21 => .{ .scan = 0x13 },
        22 => .{ .scan = 0x1F },
        23 => .{ .scan = 0x14 },
        24 => .{ .scan = 0x16 },
        25 => .{ .scan = 0x2F },
        26 => .{ .scan = 0x11 },
        27 => .{ .scan = 0x2D },
        28 => .{ .scan = 0x15 },
        29 => .{ .scan = 0x2C },
        // Dígitos 1..0 (SDL 30..39)
        30 => .{ .scan = 0x02 },
        31 => .{ .scan = 0x03 },
        32 => .{ .scan = 0x04 },
        33 => .{ .scan = 0x05 },
        34 => .{ .scan = 0x06 },
        35 => .{ .scan = 0x07 },
        36 => .{ .scan = 0x08 },
        37 => .{ .scan = 0x09 },
        38 => .{ .scan = 0x0A },
        39 => .{ .scan = 0x0B },
        // Controle / Navegação
        40 => .{ .scan = 0x1C }, // Return
        41 => .{ .scan = 0x01 }, // Escape
        42 => .{ .scan = 0x0E }, // Backspace
        43 => .{ .scan = 0x0F }, // Tab
        44 => .{ .scan = 0x39 }, // Space
        45 => .{ .scan = 0x0C }, // -
        46 => .{ .scan = 0x0D }, // =
        47 => .{ .scan = 0x1A }, // [
        48 => .{ .scan = 0x1B }, // ]
        49 => .{ .scan = 0x2B }, // \
        51 => .{ .scan = 0x27 }, // ;
        52 => .{ .scan = 0x28 }, // '
        53 => .{ .scan = 0x29 }, // `
        54 => .{ .scan = 0x33 }, // ,
        55 => .{ .scan = 0x34 }, // .
        56 => .{ .scan = 0x35 }, // /
        57 => .{ .scan = 0x3A }, // CapsLock
        // F1..F12 (58..69)
        58 => .{ .scan = 0x3B },
        59 => .{ .scan = 0x3C },
        60 => .{ .scan = 0x3D },
        61 => .{ .scan = 0x3E },
        62 => .{ .scan = 0x3F },
        63 => .{ .scan = 0x40 },
        64 => .{ .scan = 0x41 },
        65 => .{ .scan = 0x42 },
        66 => .{ .scan = 0x43 },
        67 => .{ .scan = 0x44 },
        68 => .{ .scan = 0x57 },
        69 => .{ .scan = 0x58 },
        73 => .{ .scan = 0x52, .ext = true }, // Insert
        74 => .{ .scan = 0x47, .ext = true }, // Home
        75 => .{ .scan = 0x49, .ext = true }, // PageUp
        76 => .{ .scan = 0x53, .ext = true }, // Delete
        77 => .{ .scan = 0x4F, .ext = true }, // End
        78 => .{ .scan = 0x51, .ext = true }, // PageDown
        79 => .{ .scan = 0x4D, .ext = true }, // Right
        80 => .{ .scan = 0x4B, .ext = true }, // Left
        81 => .{ .scan = 0x50, .ext = true }, // Down
        82 => .{ .scan = 0x48, .ext = true }, // Up
        // Modificadores (224..231)
        224 => .{ .scan = 0x1D }, // LCtrl
        225 => .{ .scan = 0x2A }, // LShift
        226 => .{ .scan = 0x38 }, // LAlt
        227 => .{ .scan = 0x5B, .ext = true }, // LGui
        228 => .{ .scan = 0x1D, .ext = true }, // RCtrl
        229 => .{ .scan = 0x36 }, // RShift
        230 => .{ .scan = 0x38, .ext = true }, // RAlt
        else => null,
    };
}
