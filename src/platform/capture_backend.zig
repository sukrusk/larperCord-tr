//! Fachada multiplataforma de captura de tela/janela, hardware codec e loopback de áudio.
const builtin = @import("builtin");
const std = @import("std");
const media_if = @import("media_if.zig");
const video_cfg = @import("../core/video_cfg.zig");

const is_win = builtin.os.tag == .windows;
const c = if (is_win) @import("c") else struct {};
const sys = @import("sys.zig");
const win_dxgi = if (is_win) @import("win/dxgi_cap.zig") else @import("linux/video_stub.zig");
const win_wgc = if (is_win) @import("win/wgc_cap.zig") else @import("linux/video_stub.zig");
const win_mf = if (is_win) @import("win/mf_codec.zig") else @import("linux/video_stub.zig");
pub const Loopback = if (is_win) @import("win/wasapi_loopback.zig").Loopback else @import("linux/video_stub.zig").Loopback;
pub const HwEncoder = win_mf.HwEncoder;
pub const HwDecoder = win_mf.HwDecoder;

pub fn enumerateDisplays(out: []media_if.DisplayTarget) usize {
    return win_dxgi.enumerateDisplays(out);
}

pub fn enumerateWindows(out: []media_if.WindowTarget) usize {
    return win_wgc.enumerateWindows(out);
}

pub fn windowProcessId(hwnd_id: u64) u32 {
    return if (comptime is_win) win_wgc.windowProcessId(hwnd_id) else 0;
}

pub fn probeCapabilities() media_if.HwCapability {
    return win_mf.probeCapabilities();
}

pub const ScreenSource = union(enum) {
    dxgi: win_dxgi.Duplicator,
    wgc: if (is_win) win_wgc.Capturer else void,

    pub fn openDisplay(display_id: u64, res: video_cfg.Resolution) !ScreenSource {
        return .{ .dxgi = try win_dxgi.Duplicator.open(display_id, res) };
    }

    pub fn openMonitorWgc(hmonitor: u64, res: video_cfg.Resolution) !ScreenSource {
        if (comptime !is_win) return error.NotImplementedOnLinuxYet;
        return .{ .wgc = try win_wgc.Capturer.openMonitor(hmonitor, res) };
    }

    pub fn openWindow(hwnd_id: u64, res: video_cfg.Resolution) !ScreenSource {
        if (comptime !is_win) return error.NotImplementedOnLinuxYet;
        return .{ .wgc = try win_wgc.Capturer.open(hwnd_id, res) };
    }

    pub fn acquireNv12(self: *ScreenSource, timeout_ms: u32, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        return switch (self.*) {
            .dxgi => |*d| if (comptime is_win) try d.acquireNv12(timeout_ms, want_cpu_copy, pts_us) else try d.acquireNv12(timeout_ms),
            .wgc => |*w| if (comptime is_win) try w.tryAcquireNv12(want_cpu_copy, pts_us) else null,
        };
    }

    pub fn repeatNv12(self: *ScreenSource, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        return switch (self.*) {
            .dxgi => |*d| try d.repeatNv12(want_cpu_copy, pts_us),
            .wgc => |*w| if (comptime is_win) try w.repeatNv12(want_cpu_copy, pts_us) else null,
        };
    }

    pub fn setCursorCapture(self: *ScreenSource, enabled: bool) void {
        if (comptime !is_win) {
            _ = .{ self, enabled };
            return;
        }
        switch (self.*) {
            .dxgi => |*d| d.setCursorCapture(enabled),
            .wgc => |*w| w.setCursorCapture(enabled),
        }
    }

    pub fn d3d11Device(self: *const ScreenSource) ?*anyopaque {
        if (comptime !is_win) return null;
        return switch (self.*) {
            .dxgi => |d| d.gpu.device,
            .wgc => |w| w.gpu.device,
        };
    }

    pub fn deinit(self: *ScreenSource) void {
        switch (self.*) {
            .dxgi => |*d| d.deinit(),
            .wgc => |*w| if (comptime is_win) w.deinit(),
        }
    }
};

pub fn runSelfProbe() void {
    var displays: [8]media_if.DisplayTarget = undefined;
    const nd = enumerateDisplays(&displays);
    std.debug.print("hw-probe: displays={d}\n", .{nd});
    for (displays[0..nd], 0..) |dp, i| {
        std.debug.print("  display[{d}]: id={d} pos=({d},{d}) {d}x{d} primary={any} name={s}\n", .{ i, dp.id, dp.left, dp.top, dp.width, dp.height, dp.primary, dp.nameSlice() });
    }

    var wins: [8]media_if.WindowTarget = undefined;
    const nw = enumerateWindows(&wins);
    std.debug.print("hw-probe: visible windows={d} (first 8)\n", .{nw});
    for (wins[0..nw], 0..) |wn, i| {
        std.debug.print("  win[{d}]: pid={d} exe={s} {d}x{d} title={s}\n", .{ i, wn.pid, wn.exeSlice(), wn.width, wn.height, wn.titleSlice() });
    }

    const caps = probeCapabilities();
    std.debug.print(
        "hw-probe: MF caps h264_enc={any} hevc_enc={any} av1_enc={any} h264_dec={any} hevc_dec={any} av1_dec={any} zero_copy={any}\n",
        .{ caps.h264_enc, caps.hevc_enc, caps.av1_enc, caps.h264_dec, caps.hevc_dec, caps.av1_dec, caps.zero_copy_d3d11 },
    );

    if (comptime is_win) {
        if (Loopback.openSmart(0, false)) |lb_in| {
            var lb = lb_in;
            var pcm: [960 * 2]f32 = undefined;
            const n = lb.readPcm(&pcm);
            std.debug.print("hw-probe: WASAPI loopback ok (48kHz 2ch, process_isolated={any}, initial_samples={d})\n", .{ lb.is_process_isolated, n });
            lb.deinit();
        } else |err| {
            std.debug.print("hw-probe: WASAPI loopback err={s}\n", .{@errorName(err)});
        }

        if (nd > 0) {
            if (ScreenSource.openDisplay(displays[0].id, .p2160)) |src_in| {
                var src = src_in;
                defer src.deinit();
                var got_frame: ?media_if.CaptureFrame = null;
                var tries: usize = 0;
                while (tries < 5 and got_frame == null) : (tries += 1) {
                    got_frame = src.acquireNv12(50, true, @intCast(tries * 16667)) catch null;
                }
                if (got_frame) |f| {
                    std.debug.print("hw-probe: DXGI->D3D11 NV12 ok ({d}x{d}, y={d}B)\n", .{ f.width, f.height, f.nv12_y.len });
                    if (win_mf.HwEncoder.open(.h264, f.width, f.height, 60, 18_000, src.d3d11Device())) |enc_in| {
                        var enc = enc_in;
                        defer enc.deinit();
                        enc.requestKeyframe();
                        var dec = win_mf.HwDecoder.open(.h264, f.width, f.height, src.d3d11Device()) catch null;
                        defer if (dec) |*d| d.deinit();
                        var encoded_ok: bool = false;
                        var decoded_ok: bool = false;
                        var frame_idx: usize = 0;
                        while (frame_idx < 8 and !decoded_ok) : (frame_idx += 1) {
                            const fr = (src.acquireNv12(30, false, @intCast((frame_idx + 1) * 16667)) catch null) orelse f;
                            if (enc.encode(fr) catch null) |pkt| {
                                encoded_ok = true;
                                if (dec) |*dc| {
                                    if (dc.decode(pkt.data, pkt.pts_us) catch null) |df| {
                                        decoded_ok = true;
                                        std.debug.print("hw-probe: MF HW roundtrip ok ({s}, hw_enc={any}, enc_bytes={d}, dec={d}x{d})\n", .{
                                            pkt.codec.name(), enc.hw, pkt.data.len, df.width, df.height,
                                        });
                                    }
                                }
                            }
                        }
                        if (!encoded_ok or !decoded_ok) {
                            std.debug.print("hw-probe: MF HW enc_ok={any} dec_ok={any} hw_enc={any}\n", .{ encoded_ok, decoded_ok, enc.hw });
                        }
                    } else |err| {
                        std.debug.print("hw-probe: HwEncoder err={s}\n", .{@errorName(err)});
                    }
                } else {
                    std.debug.print("hw-probe: DXGI open ok, waiting desktop update timed out (idle desktop)\n", .{});
                }
            } else |err| {
                std.debug.print("hw-probe: DXGI open err={s}\n", .{@errorName(err)});
                if (displays[0].hmonitor != 0) {
                    if (ScreenSource.openMonitorWgc(displays[0].hmonitor, .p1080)) |ws_in| {
                        var ws = ws_in;
                        defer ws.deinit();
                        var wf: ?media_if.CaptureFrame = null;
                        var wt: usize = 0;
                        while (wt < 20 and wf == null) : (wt += 1) {
                            wf = ws.acquireNv12(16, true, @intCast((wt + 1) * 16667)) catch null;
                            if (wf == null) @import("c").SDL_Delay(10);
                        }
                        if (wf) |f| {
                            var enc_bytes: usize = 0;
                            var used_cpu = false;
                            if (win_mf.HwEncoder.open(.h264, f.width, f.height, 60, 8000, ws.d3d11Device())) |enc_in| {
                                var enc = enc_in;
                                defer enc.deinit();
                                enc.requestKeyframe();
                                var ei: usize = 0;
                                while (ei < 6 and enc_bytes == 0) : (ei += 1) {
                                    var fr = (ws.acquireNv12(16, true, @intCast((ei + 2) * 16667)) catch null) orelse f;
                                    fr.pts_us = @intCast((ei + 2) * 16667);
                                    if (enc.encode(fr) catch null) |pkt| enc_bytes = pkt.data.len;
                                }
                                used_cpu = enc.force_cpu_buf;
                            } else |_| {}
                            std.debug.print("hw-probe: WGC monitor fallback opened ok! frame={d}x{d} enc_bytes={d} cpu_fb={any}\n", .{ f.width, f.height, enc_bytes, used_cpu });
                        } else {
                            std.debug.print("hw-probe: WGC monitor fallback opened ok! (no desktop frame in 200ms)\n", .{});
                        }
                    } else |werr| {
                        std.debug.print("hw-probe: WGC monitor err={s}\n", .{@errorName(werr)});
                    }
                }
            }
        }

        // Mede alocação pura 4K NV12 (VirtualAlloc/VirtualFree) antes de abrir drivers de GPU,
        // depois executa roundtrip hardware NVENC/DXVA em 4K (3840x2160).
        const nv12_pat = @import("../core/nv12_pattern.zig");
        const kb_idle = @import("sys.zig").privateKb();
        if (nv12_pat.allocNv12(3840, 2160) catch null) |tmp4k| {
            var tmp = tmp4k;
            nv12_pat.initDemoBackground(tmp, 3840, 2160);
            const kb_4k_buf = @import("sys.zig").privateKb();
            nv12_pat.freeNv12(&tmp);
            const kb_4k_freed = @import("sys.zig").privateKb();
            std.debug.print("hw-probe: 4K NV12 RAM delta (idle={d}KB, +4K={d}KB, after_free={d}KB)\n", .{
                kb_idle, kb_4k_buf, kb_4k_freed,
            });
        }
        if (nv12_pat.allocNv12(3840, 2160) catch null) |pat4k_in| {
            var pat4k = pat4k_in;
            nv12_pat.initDemoBackground(pat4k, 3840, 2160);
            const f4k: media_if.CaptureFrame = .{
                .width = 3840,
                .height = 2160,
                .nv12_y = pat4k[0 .. 3840 * 2160],
                .nv12_uv = pat4k[3840 * 2160 ..],
                .y_pitch = 3840,
                .uv_pitch = 3840,
                .pts_us = 16667,
            };
            var enc4k_bytes: usize = 0;
            var dec4k_ok = false;
            if (win_mf.HwEncoder.open(.h264, 3840, 2160, 60, 24_000, null)) |enc4_in| {
                var enc4 = enc4_in;
                defer enc4.deinit();
                enc4.requestKeyframe();
                var dec4 = win_mf.HwDecoder.open(.h264, 3840, 2160, null) catch null;
                defer if (dec4) |*d4| d4.deinit();
                var idx4: usize = 0;
                while (idx4 < 6 and !dec4k_ok) : (idx4 += 1) {
                    var fr4 = f4k;
                    fr4.pts_us = @intCast((idx4 + 1) * 16667);
                    if (enc4.encode(fr4) catch null) |pkt4| {
                        if (pkt4.data.len > 0) enc4k_bytes = pkt4.data.len;
                        if (dec4) |*dc4| {
                            if (dc4.decode(pkt4.data, pkt4.pts_us) catch null) |df4| {
                                dec4k_ok = df4.width >= 3840 and df4.height >= 2160;
                            }
                        }
                    }
                }
            } else |_| {}
            nv12_pat.freeNv12(&pat4k);
            const kb_gpu_after = @import("sys.zig").privateKb();
            @import("mem_tune.zig").trim();
            const kb_trim_after = @import("sys.zig").privateKb();
            const ws_trim_after = @import("sys.zig").workingSetKb();
            std.debug.print("hw-probe: 4K NVENC H264 roundtrip enc_bytes={d} dec_ok={any} after_codec_kb={d} after_trim_kb={d} ws_kb={d}\n", .{
                enc4k_bytes, dec4k_ok, kb_gpu_after, kb_trim_after, ws_trim_after,
            });
        }

        // Testa codec RTX H.264/HEVC/AV1 com um quadro NV12 1080p mesmo sem desktop ativo.
        if (nv12_pat.allocNv12(1920, 1080)) |pat_in| {
            var pat = pat_in;
            defer nv12_pat.freeNv12(&pat);
            nv12_pat.initDemoBackground(pat, 1920, 1080);
            const f: media_if.CaptureFrame = .{
                .width = 1920,
                .height = 1080,
                .nv12_y = pat[0 .. 1920 * 1080],
                .nv12_uv = pat[1920 * 1080 ..],
                .y_pitch = 1920,
                .uv_pitch = 1920,
                .pts_us = 16667,
            };
            const SpsScan = struct {
                fn find(data: []const u8) ?[3]u8 {
                    var i: usize = 0;
                    while (i + 7 < data.len) : (i += 1) {
                        const sc: usize = if (i + 4 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1)
                            4
                        else if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1)
                            3
                        else
                            0;
                        if (sc > 0 and i + sc + 3 < data.len and (data[i + sc] & 0x1F) == 7) {
                            return data[i + sc + 1 ..][0..3].*;
                        }
                    }
                    return null;
                }
            };
            inline for ([_]video_cfg.Codec{ .h264, .hevc, .av1 }) |cc| {
                if (win_mf.HwEncoder.open(cc, 1920, 1080, 60, 8000, null)) |enc_in| {
                    var enc = enc_in;
                    defer enc.deinit();
                    enc.requestKeyframe();
                    var dec_err_name: []const u8 = "none";
                    var dec = win_mf.HwDecoder.open(cc, 1920, 1080, null) catch |derr| blk: {
                        dec_err_name = @errorName(derr);
                        break :blk null;
                    };
                    defer if (dec) |*d| d.deinit();
                    var enc_bytes: usize = 0;
                    var sps_hdr: ?[3]u8 = null;
                    var dec_ok = false;
                    var k: usize = 0;
                    while (k < 10 and !dec_ok) : (k += 1) {
                        var fr = f;
                        fr.pts_us = @intCast((k + 1) * 16667);
                        if (enc.encode(fr) catch null) |pkt| {
                            if (pkt.data.len > 0) enc_bytes = pkt.data.len;
                            if (cc == .h264 and sps_hdr == null) sps_hdr = SpsScan.find(pkt.data);
                            if (dec) |*dc| {
                                if (dc.decode(pkt.data, pkt.pts_us) catch null) |df| {
                                    dec_ok = df.width >= 1920 and df.height >= 1080;
                                }
                            }
                        }
                    }
                    if (!dec_ok) {
                        var d_tries: usize = 0;
                        while (d_tries < 4 and !dec_ok) : (d_tries += 1) {
                            if (enc.drain(d_tries == 0)) |pkt| {
                                if (pkt.data.len > 0) enc_bytes = pkt.data.len;
                                if (cc == .h264 and sps_hdr == null) sps_hdr = SpsScan.find(pkt.data);
                                if (dec) |*dc| {
                                    if (dc.decode(pkt.data, pkt.pts_us) catch null) |df| {
                                        dec_ok = df.width >= 1920 and df.height >= 1080;
                                    }
                                }
                            }
                        }
                    }
                    if (!dec_ok) if (dec) |*dc| {
                        var dd: usize = 0;
                        while (dd < 4 and !dec_ok) : (dd += 1) {
                            if (dc.drain(dd == 0) catch null) |df| {
                                dec_ok = df.width >= 1920 and df.height >= 1080;
                            }
                        }
                    };
                    const dec_hr: u32 = if (dec) |d| @bitCast(d.last_hr) else 0;
                    if (cc == .h264) if (sps_hdr) |sh| {
                        std.debug.print("hw-probe: MF h264 SPS profile_idc={d} (0x{x:0>2}) constraints=0x{x:0>2} level={d}\n", .{ sh[0], sh[0], sh[1], sh[2] });
                    };
                    std.debug.print("hw-probe: MF {s} -> hw_enc={any} enc_bytes={d} enc_hr=0x{x:0>8} dec_ok={any} dec_err={s} dec_hr=0x{x:0>8}\n", .{
                        cc.name(), enc.hw, enc_bytes, @as(u32, @bitCast(enc.last_hr)), dec_ok, dec_err_name, dec_hr,
                    });
                } else |cerr| {
                    std.debug.print("hw-probe: MF {s} open err={s}\n", .{ cc.name(), @errorName(cerr) });
                }
            }
        } else |_| {}

        sys.beginHiResTimer();
        defer sys.endHiResTimer();

        var wgc_src_opt: ?ScreenSource = if (nd > 0 and displays[0].hmonitor != 0)
            ScreenSource.openMonitorWgc(displays[0].hmonitor, .p1080) catch null
        else
            null;
        defer if (wgc_src_opt) |*ws| ws.deinit();

        // Probe (a): H.264 encode->decode WITHOUT drain across resolutions (720p/1080p/4K) and modes (auto_hw vs sw_fb)
        inline for ([_]struct { w: u16, h: u16, n: usize }{
            .{ .w = 1280, .h = 720, .n = 15 },
            .{ .w = 1920, .h = 1080, .n = 15 },
            .{ .w = 3840, .h = 2160, .n = 10 },
        }) |case| {
            const frame_sz = @as(usize, case.w) * case.h * 3 / 2;
            if (std.heap.page_allocator.alloc(u8, frame_sz)) |pat_res| {
                defer std.heap.page_allocator.free(pat_res);
                @memset(pat_res[0 .. @as(usize, case.w) * case.h], 32);
                @memset(pat_res[@as(usize, case.w) * case.h ..], 128);

                const Modes = enum { sw_default, d3d11_dxva };
                const ext_dev: ?*anyopaque = if (wgc_src_opt) |*ws| ws.d3d11Device() else null;
                inline for ([_]Modes{ .sw_default, .d3d11_dxva }) |mode| {
                    if (mode == .sw_default or ext_dev != null) {
                        if (win_mf.HwEncoder.open(.h264, case.w, case.h, 60, 8000, null)) |e0| {
                            var enc = e0;
                            defer enc.deinit();
                            enc.requestKeyframe();
                            var dec_opt = switch (mode) {
                                .sw_default => win_mf.HwDecoder.open(.h264, case.w, case.h, null) catch null,
                                .d3d11_dxva => win_mf.HwDecoder.open(.h264, case.w, case.h, ext_dev) catch null,
                            };
                            defer if (dec_opt) |*dc| dc.deinit();
                            var in_pkts: usize = 0;
                            var out_frames: usize = 0;
                            var first_out: i32 = -1;
                            var enc_ns: u64 = 0;
                            var dec_ns: u64 = 0;
                            var k: usize = 0;
                            while (k < case.n) : (k += 1) {
                                const band = (k % 10) * (case.h / 12);
                                const y_off = band * @as(usize, case.w);
                                @memset(pat_res[y_off .. y_off + 16 * @as(usize, case.w)], @intCast(40 + (k * 12) % 180));
                                const fr: media_if.CaptureFrame = .{
                                    .width = case.w,
                                    .height = case.h,
                                    .nv12_y = pat_res[0 .. @as(usize, case.w) * case.h],
                                    .nv12_uv = pat_res[@as(usize, case.w) * case.h ..],
                                    .y_pitch = case.w,
                                    .uv_pitch = case.w,
                                    .pts_us = @intCast((k + 1) * 16667),
                                };
                                const et0 = c.SDL_GetTicksNS();
                                const pkt_opt = enc.encode(fr) catch null;
                                enc_ns += c.SDL_GetTicksNS() - et0;
                                if (pkt_opt) |pkt| {
                                    if (pkt.data.len > 0) {
                                        in_pkts += 1;
                                        if (dec_opt) |*dc| {
                                            const dt0 = c.SDL_GetTicksNS();
                                            const df_opt = dc.decode(pkt.data, pkt.pts_us) catch null;
                                            dec_ns += c.SDL_GetTicksNS() - dt0;
                                            if (df_opt != null) {
                                                if (first_out < 0) first_out = @intCast(k);
                                                out_frames += 1;
                                            }
                                        }
                                    }
                                }
                            }
                            const dec_hr: u32 = if (dec_opt) |dc| @bitCast(dc.last_hr) else 0;
                            std.debug.print(
                                "hw-probe: h264 {d}x{d} {d}f mode={s} in={d} out={d} first={d} enc_ms={d} dec_ms={d} hr=0x{x:0>8}\n",
                                .{ case.w, case.h, case.n, @tagName(mode), in_pkts, out_frames, first_out, enc_ns / 1_000_000, dec_ns / 1_000_000, dec_hr },
                            );
                        } else |cerr| {
                            std.debug.print("hw-probe: h264 {d}x{d} enc err={s}\n", .{ case.w, case.h, @errorName(cerr) });
                        }
                    }
                }
            } else |_| {}
        }

        // Probe (b): 30-frame WGC + HwEncoder sustained capture+encode timing
        if (wgc_src_opt) |*ws| {
            var warm_frame: ?media_if.CaptureFrame = null;
            const warm_start = c.SDL_GetTicksNS();
            while ((c.SDL_GetTicksNS() - warm_start) < 600 * 1_000_000) {
                if (ws.acquireNv12(0, false, @intCast(c.SDL_GetTicksNS() / 1000)) catch null) |wf| {
                    warm_frame = wf;
                    break;
                }
                c.SDL_Delay(2);
            }
            if (warm_frame) |wf| {
                if (win_mf.HwEncoder.open(.h264, wf.width, wf.height, 60, 6000, ws.d3d11Device())) |e1| {
                    var enc = e1;
                    defer enc.deinit();
                    enc.requestKeyframe();
                    var got_frames: usize = 0;
                    var enc_pkts: usize = 0;
                    var polls: usize = 0;
                    var enc_ns: u64 = 0;
                    var total_bytes: usize = 0;
                    const start_ns = c.SDL_GetTicksNS();
                    while (got_frames < 30 and (c.SDL_GetTicksNS() - start_ns) < 1500 * 1_000_000) {
                        polls += 1;
                        const now_ns = c.SDL_GetTicksNS();
                        if (ws.acquireNv12(0, false, @intCast(now_ns / 1000)) catch null) |cf| {
                            got_frames += 1;
                            const et0 = c.SDL_GetTicksNS();
                            if (enc.encode(cf) catch null) |pkt| {
                                if (pkt.data.len > 0) {
                                    enc_pkts += 1;
                                    total_bytes += pkt.data.len;
                                }
                            }
                            while (enc.pollOutput(@intCast(now_ns / 1000))) |epkt| {
                                if (epkt.data.len > 0) {
                                    enc_pkts += 1;
                                    total_bytes += epkt.data.len;
                                }
                            }
                            enc_ns += c.SDL_GetTicksNS() - et0;
                        } else {
                            c.SDL_Delay(1);
                        }
                    }
                    const elapsed_ms = @max(@as(u64, 1), (c.SDL_GetTicksNS() - start_ns) / 1_000_000);
                    const avg_enc_us: u64 = if (got_frames > 0) (enc_ns / got_frames) / 1000 else 0;
                    const avg_bytes: usize = if (enc_pkts > 0) total_bytes / enc_pkts else 0;
                    std.debug.print(
                        "hw-probe: WGC+NVENC {d}x{d} frames={d} polls={d} elapsed_ms={d} pkts={d} avg_enc_us={d} avg_bytes={d} enc_hw={any}\n",
                        .{ wf.width, wf.height, got_frames, polls, elapsed_ms, enc_pkts, avg_enc_us, avg_bytes, enc.hw },
                    );
                } else |cerr| {
                    std.debug.print("hw-probe: WGC+NVENC open err={s}\n", .{@errorName(cerr)});
                }
            } else {
                std.debug.print("hw-probe: WGC+NVENC no initial frame within 600ms\n", .{});
            }
        }
    }
}
