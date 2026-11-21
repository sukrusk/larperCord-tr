//! Modal para iniciar compartilhamento de tela/janela/demo em até 4K 60fps
//! usando buffers NV12, captura DXGI/WGC e permissão explícita de controle remoto.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const inbox = @import("inbox.zig");
const video_cfg = @import("../core/video_cfg.zig");
const media_if = @import("../platform/media_if.zig");
const capture_backend = @import("../platform/capture_backend.zig");

const Draft = struct {
    kind_idx: u8 = 0, // 0=tela, 1=janela, 2=demo 4K
    res_idx: u8 = 3, // 0=720p, 1=1080p, 2=1440p, 3=4K
    fps_idx: u8 = 1, // 0=30, 1=60
    codec_idx: u8 = 0, // 0=Auto, 1=H264, 2=HEVC, 3=AV1
    bitrate_idx: u8 = 0, // 0=Auto, 1=4M, 2=8M, 3=15M, 4=25M
    transport_idx: u8 = 0, // 0=Discord SFU, 1=P2P Direct
    remote_idx: u8 = 0, // 0=Off, 1=Mouse, 2=Full
    share_audio: bool = true,
    hw_accel: bool = true,
    capture_cursor: bool = true,
    preview_self: bool = true,
    display_idx: u8 = 0,
    window_idx: u8 = 0,
};

fn bitrateToIdx(mbps: u8) u8 {
    return switch (mbps) {
        0 => 0,
        1...5 => 1,
        6...11 => 2,
        12...20 => 3,
        else => 4,
    };
}

fn idxToMbps(idx: u8) u8 {
    return switch (idx) {
        1 => 4,
        2 => 8,
        3 => 15,
        4 => 25,
        else => 0,
    };
}

fn refreshTargets() void {
    if (!qa.on()) {
        display_count = capture_backend.enumerateDisplays(&displays);
        window_count = capture_backend.enumerateWindows(&windows);
        hw_caps = capture_backend.probeCapabilities();
    } else {
        display_count = 0;
        window_count = 0;
        hw_caps = .{};
    }
    win_scroll = 0;
    if (display_count > 0 and draft.display_idx >= display_count) draft.display_idx = 0;
    if (window_count > 0 and draft.window_idx >= window_count) draft.window_idx = 0;
}

var draft: Draft = .{};
var displays: [8]media_if.DisplayTarget = undefined;
var display_count: usize = 0;
var windows: [48]media_if.WindowTarget = undefined;
var window_count: usize = 0;
var win_scroll: usize = 0;
var hw_caps: media_if.HwCapability = .{};
var force_kind_once: ?u8 = null;

pub fn presetKind(kind_idx: u8) void {
    force_kind_once = kind_idx;
}

pub fn draw(ctx: *d.Ctx) void {
    if (popup.appearing) {
        const s = &ctx.st.settings;
        refreshTargets();
        const def_kind: u8 = if (c.SDL_getenv("LARPER_DEMO") != null or (display_count == 0 and window_count == 0)) 2 else if (display_count == 0 and window_count > 0) 1 else 0;
        const init_kind = force_kind_once orelse def_kind;
        force_kind_once = null;
        draft = .{
            .kind_idx = init_kind,
            .res_idx = @min(s.video_res, 3),
            .fps_idx = @min(s.video_fps, 1),
            .codec_idx = @min(s.video_codec, 3),
            .bitrate_idx = bitrateToIdx(s.video_bitrate_mbps),
            .transport_idx = 0,
            .remote_idx = @min(s.remote_ctrl_allow, 2),
            .share_audio = true,
            .hw_accel = s.video_hw,
            .capture_cursor = s.video_cursor,
            .preview_self = s.video_self_preview,
            .display_idx = 0,
            .window_idx = 0,
        };
    }

    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        popup.close(ctx);
        return;
    }

    const extra_disp_h: f32 = if (draft.kind_idx == 0 and display_count > 3) 36 else 0;
    const base_h: f32 = if (draft.kind_idx == 1 and window_count > 0) 716 else 592 + extra_disp_h;
    const dlg_h: f32 = @min(base_h, @max(ctx.win.h - 24, 480));
    const r = forum.dialogRect(ctx, 560, dlg_h);
    const dl = popup.beginWindow("##stream-picker", r);
    defer c.ImGui_End();
    const prev_dl = ctx.dl;
    defer ctx.dl = prev_dl;
    ctx.dl = dl;

    qa.mark(r, "stream-picker", .{});
    inbox.panelFrame(ctx, dl, r);

    const fam = ctx.ui;
    const pad: f32 = 20;
    const w = r.w - pad * 2;
    icons.screen(dl, r.x + pad + 10, r.y + 27, ctx.col(.accent).u());
    const ref_lbl = i18n.tr("Atualizar", "Refresh");
    const ref_w = d.width(fam.get(.medium), 12, ref_lbl) + 20;
    const ref_r: d.Rect = .{ .x = r.right() - pad - ref_w, .y = r.y + 14, .w = ref_w, .h = 24 };
    const rh = d.hit(ctx, 0x910F, ref_r);
    if (rh.clicked) refreshTargets();
    d.rect(dl, ref_r, ctx.col(.elevated).mix(ctx.col(.hover), if (rh.hovered) 1 else 0), 6);
    d.border(dl, ref_r, ctx.col(.border), 6, 1);
    d.text(dl, fam.get(.medium), 12, ref_r.x + 10, d.centerY(ref_r, 12), ctx.col(.text), ref_lbl);

    _ = d.textClipped(
        dl,
        fam.get(.bold),
        17,
        r.x + pad + 26,
        r.y + 16,
        ctx.col(.text),
        i18n.tr("Compartilhar tela / Go Live 4K", "Share screen / Go Live 4K"),
        @max(w - 38 - ref_w, 60),
    );

    var scr_lb: [48]u8 = undefined;
    var win_lb: [48]u8 = undefined;
    const scr_lbl = std.fmt.bufPrint(&scr_lb, "{s} ({d})", .{ i18n.tr("Tela inteira", "Entire Screen"), display_count }) catch i18n.tr("Tela inteira", "Entire Screen");
    const win_lbl = std.fmt.bufPrint(&win_lb, "{s} ({d})", .{ i18n.tr("Aplicativo / Janela", "Application / Window"), window_count }) catch i18n.tr("Aplicativo / Janela", "Application / Window");

    var y = r.y + 48;
    y = segRow(ctx, dl, fam, 0x9100, r.x + pad, y, w, i18n.tr("Fonte", "Source"), &.{
        scr_lbl,
        win_lbl,
        i18n.tr("Demo 4K NV12", "4K Demo NV12"),
    }, &draft.kind_idx);

    y = drawTargetRow(ctx, dl, fam, r.x + pad, y, w);

    y = segRow(ctx, dl, fam, 0x9110, r.x + pad, y, w, i18n.tr("Resolução", "Resolution"), &.{ "720p", "1080p", "1440p", "4K" }, &draft.res_idx);
    y = segRow(ctx, dl, fam, 0x9120, r.x + pad, y, w, i18n.tr("Quadros / Codec / Taxa de bits", "Frame rate / Codec / Bitrate"), &.{ "30 FPS", "60 FPS" }, &draft.fps_idx);
    y = segRow(ctx, dl, fam, 0x9130, r.x + pad, y - 4, w, null, &.{ "Auto", "H.264", "HEVC", "AV1" }, &draft.codec_idx);
    y = segRow(ctx, dl, fam, 0x9138, r.x + pad, y - 4, w, null, &.{ i18n.tr("Otomatik", "Auto"), "4 Mbps", "8 Mbps", "15 Mbps", "25 Mbps" }, &draft.bitrate_idx);
    y = segRow(ctx, dl, fam, 0x9140, r.x + pad, y, w, i18n.tr("Transporte e Controle Remoto", "Transport & Remote Control"), &.{
        "Discord SFU",
        i18n.tr("P2P Direto (4K)", "P2P Direct (4K)"),
    }, &draft.transport_idx);
    y = segRow(ctx, dl, fam, 0x9150, r.x + pad, y - 4, w, null, &.{
        i18n.tr("Sem controle", "No remote ctrl"),
        i18n.tr("Só mouse", "Mouse only"),
        i18n.tr("Mouse + Teclado", "Mouse + Keys"),
    }, &draft.remote_idx);

    const half_w = (w - 10) / 2;
    const audio_lbl = if (draft.kind_idx == 1)
        i18n.tr("Áudio só deste app (sem eco)", "Only this app's audio (no echo)")
    else
        i18n.tr("Áudio do sistema (sem eco)", "System audio (no Discord echo)");
    drawCheck(ctx, dl, fam, 0x9160, .{ .x = r.x + pad, .y = y, .w = half_w, .h = 26 }, audio_lbl, &draft.share_audio);
    drawCheck(ctx, dl, fam, 0x9161, .{ .x = r.x + pad + half_w + 10, .y = y, .w = half_w, .h = 26 }, i18n.tr("GPU Hardware (NV12)", "GPU Hardware (NV12)"), &draft.hw_accel);
    y += 30;
    drawCheck(ctx, dl, fam, 0x9162, .{ .x = r.x + pad, .y = y, .w = half_w, .h = 26 }, i18n.tr("Fare imlecini yakala", "Capture mouse cursor"), &draft.capture_cursor);
    drawCheck(ctx, dl, fam, 0x9163, .{ .x = r.x + pad + half_w + 10, .y = y, .w = half_w, .h = 26 }, i18n.tr("Kendi yayınımı ön izle", "Preview own stream"), &draft.preview_self);
    y += 32;

    const res = video_cfg.Resolution.fromByte(draft.res_idx);
    const dims = res.dims();
    const nv12_mb = @as(f64, @floatFromInt(video_cfg.nv12ByteSize(dims[0], dims[1]))) / (1024.0 * 1024.0);
    var est_b: [192]u8 = undefined;
    const est = i18n.fmt(
        &est_b,
        "NV12 {d}x{d}: {d:.1} MiB (-62,5% RAM)  •  GPU: {s}{s}{s}",
        "NV12 {d}x{d}: {d:.1} MiB (-62.5% RAM)  •  GPU: {s}{s}{s}",
        .{
            dims[0],
            dims[1],
            nv12_mb,
            if (hw_caps.h264_enc) "H264 " else "",
            if (hw_caps.hevc_enc) "HEVC " else "",
            if (hw_caps.av1_enc) "AV1" else if (!hw_caps.h264_enc and !hw_caps.hevc_enc) "SW" else "",
        },
    );
    _ = d.textClipped(dl, fam.get(.regular), 12, r.x + pad, y, ctx.col(.muted), est, w);

    const cancel_lbl = i18n.tr("Cancelar", "Cancel");
    const go_lbl = if (ctx.st.stream_on) i18n.tr("Kaynağı güncelle", "Update source") else i18n.tr("Iniciar transmissão", "Go Live");
    const go_w = d.width(fam.get(.semibold), 13.5, go_lbl) + 32;
    const cancel_w = d.width(fam.get(.medium), 13.5, cancel_lbl) + 28;
    const by = r.bottom() - 48;

    const go_r: d.Rect = .{ .x = r.right() - pad - go_w, .y = by, .w = go_w, .h = 34 };
    const cr: d.Rect = .{ .x = go_r.x - 10 - cancel_w, .y = by, .w = cancel_w, .h = 34 };
    const ch = d.hit(ctx, 0x9170, cr);
    qa.mark(cr, "picker-cancel", .{});
    d.rect(dl, cr, ctx.col(.elevated).mix(ctx.col(.hover), if (ch.hovered) 1 else 0), @max(ctx.th.radius, 6));
    d.text(dl, fam.get(.medium), 13.5, cr.x + (cr.w - d.width(fam.get(.medium), 13.5, cancel_lbl)) / 2, d.centerY(cr, 13.5), ctx.col(.text), cancel_lbl);
    if (ch.clicked) popup.close(ctx);

    const can_go = draft.kind_idx == 2 or (draft.kind_idx == 0 and display_count > 0) or (draft.kind_idx == 1 and window_count > 0);
    qa.mark(go_r, "picker-golive", .{});
    if (forum.primary(ctx, dl, fam, 0x9171, go_r, go_lbl, can_go)) {
        const fps: u8 = if (draft.fps_idx == 1) 60 else 30;
        const kind: video_cfg.SourceKind = switch (draft.kind_idx) {
            1 => .window,
            2 => .demo_4k,
            else => .screen,
        };
        const target_id: u64 = switch (kind) {
            .screen => if (draft.display_idx < display_count) displays[draft.display_idx].id else 0,
            .window => if (draft.window_idx < window_count) windows[draft.window_idx].handle else 0,
            else => 0,
        };
        const mbps = idxToMbps(draft.bitrate_idx);
        const bitrate_kbps: u32 = if (mbps > 0) @as(u32, mbps) * 1000 else res.defaultBitrateKbps(fps);
        const transport = std.enums.fromInt(video_cfg.TransportMode, draft.transport_idx) orelse .discord_sfu;
        const picked_codec = video_cfg.Codec.fromByte(draft.codec_idx);
        const cfg: video_cfg.StreamConfig = .{
            .kind = kind,
            .target_id = target_id,
            .resolution = res,
            .fps = fps,
            .codec = if (transport == .discord_sfu) .h264 else picked_codec,
            .bitrate_kbps = bitrate_kbps,
            .share_audio = draft.share_audio,
            .capture_cursor = draft.capture_cursor,
            .preview_self = draft.preview_self,
            .remote_perm = std.enums.fromInt(video_cfg.RemotePerm, draft.remote_idx) orelse .off,
            .transport = transport,
            .hw_accel = draft.hw_accel,
            .perf_preset = video_cfg.PerfPreset.fromByte(ctx.st.settings.video_perf_preset),
            .capture_backend = video_cfg.CaptureBackend.fromByte(ctx.st.settings.video_cap_mode),
            .static_refresh_ms = video_cfg.staticRefreshMs(ctx.st.settings.video_static_fps),
            .keyframe_sec = ctx.st.settings.video_kf_sec,
        };
        ctx.st.settings.video_res = draft.res_idx;
        ctx.st.settings.video_fps = draft.fps_idx;
        ctx.st.settings.video_codec = draft.codec_idx;
        ctx.st.settings.video_bitrate_mbps = mbps;
        ctx.st.settings.video_hw = draft.hw_accel;
        ctx.st.settings.video_cursor = draft.capture_cursor;
        ctx.st.settings.video_self_preview = draft.preview_self;
        ctx.st.settings.remote_ctrl_allow = draft.remote_idx;
        popup.close(ctx);
        ctx.act(.{ .start_screen_share = cfg });
        ctx.act(.save_settings);
    }
}

fn drawTargetRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, x: f32, y: f32, w: f32) f32 {
    if (draft.kind_idx == 2) {
        const txt = i18n.tr("Gerador sintético 3840x2160 NV12 local", "Local 3840x2160 NV12 synthetic generator");
        d.rect(dl, .{ .x = x, .y = y, .w = w, .h = 30 }, ctx.col(.elevated), @max(ctx.th.radius, 6));
        _ = d.textClipped(dl, fam.get(.regular), 12.5, x + 10, y + 8, ctx.col(.muted), txt, w - 20);
        return y + 40;
    }

    if (draft.kind_idx == 0) {
        if (display_count == 0) {
            const msg = i18n.tr("Nenhum monitor DXGI encontrado neste ambiente.", "No DXGI displays found in this environment.");
            _ = d.textClipped(dl, fam.get(.regular), 12.5, x, y + 6, ctx.col(.muted), msg, w);
            return y + 38;
        }
        const shown = @min(display_count, displays.len);
        const cols: usize = @min(shown, 3);
        const rows_n = (shown + 2) / 3;
        const gap: f32 = 8;
        const bw = (w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        var lb: [64]u8 = undefined;
        for (0..shown) |i| {
            const disp = &displays[i];
            const row = i / 3;
            const col = i % 3;
            const side: []const u8 = if (disp.primary)
                i18n.tr("Principal", "Main")
            else if (disp.left < 0)
                i18n.tr("Esq", "Left")
            else if (disp.left > 0)
                i18n.tr("Dir", "Right")
            else if (disp.top < 0)
                i18n.tr("Cima", "Top")
            else
                "Ext";
            const lbl = if (display_count > 1)
                std.fmt.bufPrint(&lb, "Mon {d} ({s}): {d}x{d}", .{ i + 1, side, disp.width, disp.height }) catch "Monitor"
            else
                std.fmt.bufPrint(&lb, "Mon {d}: {d}x{d}", .{ i + 1, disp.width, disp.height }) catch "Monitor";
            const br: d.Rect = .{
                .x = x + @as(f32, @floatFromInt(col)) * (bw + gap),
                .y = y + @as(f32, @floatFromInt(row)) * 34,
                .w = bw,
                .h = 30,
            };
            const hb = d.hit(ctx, 0x9180 + i, br);
            if (hb.clicked) draft.display_idx = @intCast(i);
            const sel = draft.display_idx == i;
            d.rect(dl, br, ctx.col(.elevated).mix(ctx.col(.accent).alpha(0.24), if (sel) 1 else 0), @max(ctx.th.radius, 6));
            d.border(dl, br, if (sel) ctx.col(.accent) else ctx.col(.border), @max(ctx.th.radius, 6), if (sel) 1.6 else 1);
            _ = d.textClipped(dl, fam.get(.medium), 12, br.x + 8, d.centerY(br, 12), if (sel) ctx.col(.text) else ctx.col(.muted), lbl, br.w - 16);
        }
        return y + @as(f32, @floatFromInt(rows_n)) * 34 + 6;
    }

    if (window_count == 0) {
        const msg = i18n.tr("Nenhuma janela visível encontrada (janelas minimizadas não aparecem).", "No visible windows found (minimized windows stay hidden).");
        _ = d.textClipped(dl, fam.get(.regular), 12.0, x, y + 6, ctx.col(.muted), msg, w);
        return y + 38;
    }
    const vis_rows: usize = 6;
    const row_h: f32 = 26;
    const list_h: f32 = @floatFromInt(vis_rows);
    const box_h = list_h * row_h + 6;
    const box_r: d.Rect = .{ .x = x, .y = y, .w = w, .h = box_h };
    d.rect(dl, box_r, ctx.col(.elevated).alpha(0.55), @max(ctx.th.radius, 6));
    d.border(dl, box_r, ctx.col(.border), @max(ctx.th.radius, 6), 1);

    if (box_r.contains(ctx.mouse.x, ctx.mouse.y) and window_count > vis_rows) {
        const wheel = ctx.io.*.MouseWheel;
        if (wheel > 0.1 and win_scroll > 0) win_scroll -= 1;
        if (wheel < -0.1 and win_scroll + vis_rows < window_count) win_scroll += 1;
    }
    const max_off = if (window_count > vis_rows) window_count - vis_rows else 0;
    if (win_scroll > max_off) win_scroll = max_off;

    const end_idx = @min(win_scroll + vis_rows, window_count);
    for (win_scroll..end_idx, 0..) |wi, row_i| {
        const wt = &windows[wi];
        const rr: d.Rect = .{
            .x = x + 3,
            .y = y + 3 + @as(f32, @floatFromInt(row_i)) * row_h,
            .w = w - 6,
            .h = row_h - 2,
        };
        const hb = d.hit(ctx, 0x9190 + wi, rr);
        if (hb.clicked) draft.window_idx = @intCast(wi);
        const sel = draft.window_idx == wi;
        if (sel or hb.hovered) d.rect(dl, rr, if (sel) ctx.col(.accent).alpha(0.24) else ctx.col(.hover), 5);
        if (sel) d.border(dl, rr, ctx.col(.accent), 5, 1.2);
        var wb: [160]u8 = undefined;
        const exe = wt.exeSlice();
        const wtxt = if (exe.len > 0)
            std.fmt.bufPrint(&wb, "[{s}] {s} ({d}x{d})", .{ exe, wt.titleSlice(), wt.width, wt.height }) catch wt.titleSlice()
        else
            std.fmt.bufPrint(&wb, "{s} ({d}x{d})", .{ wt.titleSlice(), wt.width, wt.height }) catch wt.titleSlice();
        _ = d.textClipped(dl, fam.get(if (sel) .semibold else .medium), 12, rr.x + 8, d.centerY(rr, 12), if (sel) ctx.col(.text) else ctx.col(.muted), wtxt, rr.w - 16);
    }
    if (window_count > vis_rows) {
        const track_r: d.Rect = .{ .x = x + w - 7, .y = y + 4, .w = 4, .h = box_h - 8 };
        d.rect(dl, track_r, ctx.col(.border).alpha(0.4), 2);
        const frac_h = (@as(f32, @floatFromInt(vis_rows)) / @as(f32, @floatFromInt(window_count))) * track_r.h;
        const th = @max(frac_h, 14);
        const tpos = if (max_off > 0) @as(f32, @floatFromInt(win_scroll)) / @as(f32, @floatFromInt(max_off)) else 0;
        d.rect(dl, .{ .x = track_r.x, .y = track_r.y + (track_r.h - th) * tpos, .w = 4, .h = th }, ctx.col(.accent).alpha(0.8), 2);

        var sb: [32]u8 = undefined;
        const sc_hint = std.fmt.bufPrint(&sb, "{d}-{d}/{d}", .{ win_scroll + 1, end_idx, window_count }) catch "";
        _ = d.textClipped(dl, fam.get(.regular), 10.5, x + w - d.width(fam.get(.regular), 10.5, sc_hint) - 6, y + box_h + 2, ctx.col(.faint), sc_hint, 80);
    }
    return y + box_h + 12;
}

fn segRow(
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    fam: *d.Family,
    id_base: usize,
    x: f32,
    y_in: f32,
    w: f32,
    label: ?[]const u8,
    opts: []const []const u8,
    val: *u8,
) f32 {
    var y = y_in;
    if (label) |lbl| {
        d.text(dl, fam.get(.semibold), 12.5, x, y, ctx.col(.muted), lbl);
        y += 18;
    }
    const gap: f32 = 8;
    const bw = (w - gap * @as(f32, @floatFromInt(opts.len - 1))) / @as(f32, @floatFromInt(opts.len));
    const rad = @max(ctx.th.radius, 6);
    for (opts, 0..) |opt, i| {
        const br: d.Rect = .{ .x = x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = y, .w = bw, .h = 30 };
        const hb = d.hit(ctx, id_base + i, br);
        if (hb.clicked) val.* = @intCast(i);
        const sel = val.* == i;
        const k = anim.to(anim.id("spick", (@as(u64, id_base) << 4) | i), if (sel) 1 else if (hb.hovered) 0.4 else 0, 20);
        d.rect(dl, br, ctx.col(.elevated).mix(ctx.col(.accent).alpha(0.24), k), rad);
        d.border(dl, br, if (sel) ctx.col(.accent) else ctx.col(.border), rad, if (sel) 1.6 else 1);
        const tw = d.width(fam.get(.medium), 12.5, opt);
        _ = d.textClipped(dl, fam.get(.medium), 12.5, br.x + @max(4, (br.w - tw) / 2), d.centerY(br, 12.5), if (sel) ctx.col(.text) else ctx.col(.muted), opt, br.w - 8);
    }
    return y + 38;
}

fn drawCheck(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, id: usize, r: d.Rect, lbl: []const u8, val: *bool) void {
    const hb = d.hit(ctx, id, r);
    if (hb.clicked) val.* = !val.*;
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.hover), if (hb.hovered) 1 else 0), @max(ctx.th.radius, 6));
    const box: d.Rect = .{ .x = r.x + 8, .y = r.y + (r.h - 14) / 2, .w = 14, .h = 14 };
    d.rect(dl, box, if (val.*) ctx.col(.accent) else ctx.col(.surface), 3);
    d.border(dl, box, if (val.*) ctx.col(.accent) else ctx.col(.border), 3, 1);
    _ = d.textClipped(dl, fam.get(.medium), 12.5, box.right() + 8, d.centerY(r, 12.5), ctx.col(.text), lbl, r.w - 30);
}
