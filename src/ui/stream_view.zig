//! Palco 4K de visualização de Go Live + HUD NV12/FPS/RAM + fluxo de
//! consentimento e kill switch (F8 / Ctrl+Shift+Esc) para controle remoto AnyDesk.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const live_video = @import("live_video.zig");
const video_cfg = @import("../core/video_cfg.zig");
const remote_ctrl = @import("../net/remote_ctrl.zig");
const w = @import("widgets.zig");

var remote_seq: u32 = 1;
var last_norm: ?[2]u16 = null;
var was_down_l: bool = false;
var was_down_r: bool = false;
var was_down_m: bool = false;
var was_down_x1: bool = false;
var was_down_x2: bool = false;
var wheel_accum: f32 = 0;
var prev_keys: [232]bool = @splat(false);
var last_rc_req_peer: u64 = 0;
var zoom_fill: bool = false;

pub fn draw(ctx: *d.Ctx, r: d.Rect) void {
    drawTarget(ctx, r, ctx.st.watch_owner, false);
}

pub fn drawCam(ctx: *d.Ctx, r: d.Rect, owner: u64) void {
    drawTarget(ctx, r, owner, true);
}

fn drawTarget(ctx: *d.Ctx, r: d.Rect, owner: u64, is_cam: bool) void {
    if (owner == 0 or r.w < 40 or r.h < 40) return;

    const dl = ctx.dl;
    const fam = ctx.ui;
    const rad = @max(ctx.th.radius, 8);
    d.rect(dl, r, d.Rgba.hex(0x0c0e12), rad);
    d.border(dl, r, ctx.col(.border), rad, 1);
    if (is_cam) qa.mark(r, "cam-stage:{d}", .{owner}) else qa.mark(r, "stream-stage:{d}", .{owner});

    const info = if (is_cam) null else ctx.store.streamOf(owner);
    const fps_target: u8 = if (info) |si| si.fps else if (ctx.st.settings.video_fps == 1) 60 else 30;
    anim.every(if (fps_target >= 45) 16 else 33);

    const slot_opt: ?*live_video.FrameSlot = if (is_cam)
        (if (owner == ctx.store.me) &live_video.eng.cam_slot else live_video.eng.peerCamSlot(owner))
    else
        &live_video.eng.watch_slot;
    const view = if (slot_opt) |sp| sp.view(ctx.images.renderer) else null;
    var vid_r = r;
    if (view) |v| {
        const vw: f32 = @floatFromInt(v.w);
        const vh: f32 = @floatFromInt(v.h);
        const inner = r.inset(4, 4);
        const scale = if (zoom_fill) @max(inner.w / vw, inner.h / vh) else @min(inner.w / vw, inner.h / vh);
        const dw = vw * scale;
        const dh = vh * scale;
        vid_r = .{
            .x = inner.x + (inner.w - dw) / 2,
            .y = inner.y + (inner.h - dh) / 2,
            .w = dw,
            .h = dh,
        };
        const mirror = is_cam and owner == ctx.store.me and ctx.st.settings.video_cam_mirror;
        const uv0 = if (mirror) d.v(1, 0) else d.v(0, 0);
        const uv1 = if (mirror) d.v(0, 1) else d.v(1, 1);
        if (zoom_fill) c.ImDrawList_PushClipRect(dl, d.v(inner.x, inner.y), d.v(inner.right(), inner.bottom()), true);
        c.ImDrawList_AddImageRounded(
            dl,
            v.ref,
            d.v(vid_r.x, vid_r.y),
            d.v(vid_r.right(), vid_r.bottom()),
            uv0,
            uv1,
            d.Rgba.white.u(),
            6,
            0,
        );
        if (zoom_fill) c.ImDrawList_PopClipRect(dl);
    } else {
        const wait_txt = if (is_cam)
            i18n.tr("Aguardando vídeo da câmera…", "Waiting for camera video…")
        else if (owner == ctx.store.me)
            i18n.tr("Iniciando captura NV12…", "Starting NV12 capture…")
        else
            i18n.tr("Aguardando vídeo da transmissão… (use Kare İste se demorar)", "Waiting for stream video… (click Keyframe if stuck)");
        const tw = d.width(fam.get(.medium), 14, wait_txt);
        d.text(dl, fam.get(.medium), 14, r.x + (r.w - tw) / 2, d.centerY(r, 14), ctx.col(.muted), wait_txt);
    }

    // HUD superior esquerdo: nome, resolução real, FPS, codec e RAM NV12.
    const name = ctx.store.nameIn(ctx.st.guild, owner) orelse "?";
    var hud_b: [180]u8 = undefined;
    const kind_tag: []const u8 = if (is_cam)
        "CAM"
    else if (owner == ctx.store.me)
        (if (ctx.st.stream_cfg.share_audio) "LIVE + AUDIO" else "LIVE")
    else
        "RX";
    const hud = if (view) |v| blk: {
        const fps_f = @as(f32, @floatFromInt(@max(v.fps_x10, 1))) / 10.0;
        const ram_mb = @as(f64, @floatFromInt(v.ram_bytes)) / (1024.0 * 1024.0);
        const proc_mb = @import("../platform/sys.zig").privateKb() / 1024;
        if (proc_mb > 0) {
            break :blk std.fmt.bufPrint(&hud_b, "{s} [{s}]  •  {d}x{d}  •  {d:.1} fps  •  {s}  •  NV12 {d:.1} MiB  •  RAM {d} MB", .{
                name,
                kind_tag,
                v.w,
                v.h,
                fps_f,
                v.codec.name(),
                ram_mb,
                proc_mb,
            }) catch name;
        }
        break :blk std.fmt.bufPrint(&hud_b, "{s} [{s}]  •  {d}x{d}  •  {d:.1} fps  •  {s}  •  NV12 {d:.1} MiB", .{
            name,
            kind_tag,
            v.w,
            v.h,
            fps_f,
            v.codec.name(),
            ram_mb,
        }) catch name;
    } else name;
    // HUD superior direito: Fechar / Tela cheia / Zoom / Câmeras / Volume ou Configurações / Controle remoto.
    var bx = r.right() - 10;
    const bh: f32 = 28;
    const by = r.y + 10;

    // Botão fechar spotlight.
    bx -= bh;
    const xr: d.Rect = .{ .x = bx, .y = by, .w = bh, .h = bh };
    const xh = d.hit(ctx, 0x9201, xr);
    qa.mark(xr, "stream-close", .{});
    d.rect(dl, xr, (if (xh.hovered) ctx.col(.danger) else d.Rgba.hex(0x14161c).alpha(0.84)), 6);
    d.line(dl, xr.x + 9, xr.y + 9, xr.right() - 9, xr.bottom() - 9, d.Rgba.white, 1.8);
    d.line(dl, xr.right() - 9, xr.y + 9, xr.x + 9, xr.bottom() - 9, d.Rgba.white, 1.8);
    if (xh.clicked) {
        ctx.st.stream_settings_open = false;
        if (is_cam) {
            ctx.st.spotlight_cam = 0;
            ctx.st.spotlight_fullscreen = false;
        } else {
            ctx.act(.{ .watch_stream = 0 });
        }
    }

    // Botão tela cheia.
    bx -= bh + 6;
    const fr: d.Rect = .{ .x = bx, .y = by, .w = bh, .h = bh };
    const fh = d.hit(ctx, 0x9202, fr);
    qa.mark(fr, "stream-fullscreen", .{});
    d.rect(dl, fr, (if (ctx.st.spotlight_fullscreen) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.84)).mix(d.Rgba.white, if (fh.hovered) 0.14 else 0), 6);
    icons.fullscreen(dl, fr.x + fr.w / 2, fr.y + fr.h / 2, d.Rgba.white.u());
    if (fh.clicked) ctx.st.spotlight_fullscreen = !ctx.st.spotlight_fullscreen;

    // Sığdır / Ajustar (Zoom).
    const z_lbl = if (zoom_fill) i18n.tr("Ajustar", "Fit") else i18n.tr("Preencher", "Fill");
    const zw = d.width(fam.get(.semibold), 12, z_lbl) + 18;
    bx -= zw + 6;
    const zr: d.Rect = .{ .x = bx, .y = by, .w = zw, .h = bh };
    const zh = d.hit(ctx, 0x9204, zr);
    d.rect(dl, zr, (if (zoom_fill) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.84)).mix(d.Rgba.white, if (zh.hovered) 0.14 else 0), 6);
    d.text(dl, fam.get(.semibold), 12, zr.x + 9, d.centerY(zr, 12), d.Rgba.white, z_lbl);
    if (zh.clicked) zoom_fill = !zoom_fill;

    var ctrl_hovered = xh.hovered or fh.hovered or zh.hovered;

    if (!is_cam) {
        const cam_n = countActiveCams(ctx);
        var clb: [32]u8 = undefined;
        const c_lbl = if (cam_n > 0)
            (std.fmt.bufPrint(&clb, "{s} ({d})", .{ i18n.tr("Câmeras", "Cameras"), cam_n }) catch i18n.tr("Câmeras", "Cameras"))
        else
            i18n.tr("Câmeras", "Cameras");
        const cw_cam = d.width(fam.get(.semibold), 12, c_lbl) + 18;
        bx -= cw_cam + 6;
        const cmr: d.Rect = .{ .x = bx, .y = by, .w = cw_cam, .h = bh };
        const cmh = d.hit(ctx, 0x9208, cmr);
        ctrl_hovered = ctrl_hovered or cmh.hovered;
        qa.mark(cmr, "stream-cams-btn", .{});
        const cbg = if (ctx.st.stream_show_cams) ctx.col(.accent).alpha(0.92) else d.Rgba.hex(0x14161c).alpha(0.84);
        d.rect(dl, cmr, cbg.mix(d.Rgba.white, if (cmh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, cmr.x + 9, d.centerY(cmr, 12), d.Rgba.white, c_lbl);
        if (cmh.clicked) ctx.act(.toggle_stream_cams);
        if (cmh.hovered) d.tip(ctx, cmr, if (ctx.st.stream_show_cams) i18n.tr("Ocultar câmeras da call", "Hide call cameras") else i18n.tr("Mostrar câmeras junto à transmissão", "Show call cameras alongside stream"), true);
    }

    if (owner != ctx.store.me) {
        const kf_lbl = i18n.tr("Solicitar quadro", "Keyframe");
        const kfw = d.width(fam.get(.semibold), 12, kf_lbl) + 18;
        bx -= kfw + 6;
        const kfr: d.Rect = .{ .x = bx, .y = by, .w = kfw, .h = bh };
        const kfh = d.hit(ctx, 0x9205, kfr);
        ctrl_hovered = ctrl_hovered or kfh.hovered;
        d.rect(dl, kfr, d.Rgba.hex(0x14161c).alpha(0.84).mix(d.Rgba.white, if (kfh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, kfr.x + 9, d.centerY(kfr, 12), d.Rgba.white, kf_lbl);
        if (kfh.clicked) ctx.act(.request_keyframe);

        if (!is_cam and r.w >= 460) {
            const s_muted = ctx.st.settings.stream_muted;
            const s_vol = @as(f32, @floatFromInt(@min(ctx.st.settings.stream_volume, 200))) / 100.0;
            const s_off = s_muted or s_vol <= 0.001;
            const pct_u: u16 = @intFromFloat(@round(std.math.clamp(s_vol, 0, 2) * 100));
            var vpb: [12]u8 = undefined;
            const vpt = std.fmt.bufPrint(&vpb, "{d}%", .{pct_u}) catch "100%";
            const vol_w: f32 = 148;
            bx -= vol_w + 6;
            const vr_box: d.Rect = .{ .x = bx, .y = by, .w = vol_w, .h = bh };
            d.rect(dl, vr_box, d.Rgba.hex(0x14161c).alpha(0.86), 6);

            const vmr: d.Rect = .{ .x = vr_box.x + 2, .y = vr_box.y + 1, .w = 26, .h = bh - 2 };
            const vmh = d.hit(ctx, 0x9209, vmr);
            qa.mark(vmr, "stream-mute-btn", .{});
            if (vmh.hovered) d.rect(dl, vmr, d.Rgba.white.alpha(0.12), 5);
            icons.speaker(dl, vmr.x + 13, vmr.y + 13, (if (s_off) ctx.col(.faint) else d.Rgba.white).u());
            if (s_muted) d.line(dl, vmr.x + 6, vmr.y + 20, vmr.x + 20, vmr.y + 6, ctx.col(.danger), 1.8);
            if (vmh.clicked) ctx.act(.{ .set_stream_mute = !s_muted });
            if (vmh.hovered) d.tip(ctx, vmr, if (s_muted) i18n.tr("Desmutar áudio da transmissão", "Unmute stream audio") else i18n.tr("Silenciar áudio da transmissão", "Mute stream audio"), true);

            const vtr: d.Rect = .{ .x = vmr.right() + 4, .y = vr_box.y + bh / 2 - 2.5, .w = 72, .h = 5 };
            const vhr: d.Rect = .{ .x = vtr.x - 5, .y = vr_box.y, .w = vtr.w + 10, .h = bh };
            const vhh = d.hit(ctx, 0x920A, vhr);
            qa.mark(vhr, "stream-vol-slider", .{});
            if (vhh.held) {
                const raw = std.math.clamp((ctx.mouse.x - vtr.x) / vtr.w, 0, 1);
                ctx.act(.{ .set_stream_volume = @round(raw * 200.0) / 100.0 });
            }
            const sk = std.math.clamp(s_vol / 2.0, 0, 1);
            d.rect(dl, vtr, d.Rgba.white.alpha(0.18), 3);
            d.line(dl, vtr.x + vtr.w / 2, vtr.y - 2, vtr.x + vtr.w / 2, vtr.bottom() + 2, d.Rgba.white.alpha(0.45), 1);
            d.rect(dl, .{ .x = vtr.x, .y = vtr.y, .w = vtr.w * sk, .h = vtr.h }, if (s_off) ctx.col(.faint) else ctx.col(.accent), 3);
            d.rect(dl, .{ .x = vtr.x + vtr.w * sk - 4, .y = vtr.y - 3.5, .w = 8, .h = 12 }, d.Rgba.white, 3);
            d.text(dl, fam.get(.semibold), 11, vtr.right() + 6, d.centerY(vr_box, 11), if (s_off) ctx.col(.faint) else d.Rgba.white, vpt);
            ctrl_hovered = ctrl_hovered or vr_box.contains(ctx.mouse.x, ctx.mouse.y) or vhh.held;
        }
    } else if (!is_cam and ctx.st.stream_on) {
        const stop_lbl = i18n.tr("Parar", "Stop");
        const sw = d.width(fam.get(.semibold), 12, stop_lbl) + 18;
        bx -= sw + 6;
        const sr: d.Rect = .{ .x = bx, .y = by, .w = sw, .h = bh };
        const sh = d.hit(ctx, 0x9207, sr);
        ctrl_hovered = ctrl_hovered or sh.hovered;
        d.rect(dl, sr, ctx.col(.danger).mix(d.Rgba.white, if (sh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, sr.x + 9, d.centerY(sr, 12), d.Rgba.white, stop_lbl);
        if (sh.clicked) ctx.act(.stop_screen_share);

        const chg_lbl = i18n.tr("Trocar tela", "Switch source");
        const cw = d.width(fam.get(.semibold), 12, chg_lbl) + 18;
        bx -= cw + 6;
        const cr: d.Rect = .{ .x = bx, .y = by, .w = cw, .h = bh };
        const ch = d.hit(ctx, 0x9206, cr);
        ctrl_hovered = ctrl_hovered or ch.hovered;
        d.rect(dl, cr, d.Rgba.hex(0x14161c).alpha(0.84).mix(d.Rgba.white, if (ch.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, cr.x + 9, d.centerY(cr, 12), d.Rgba.white, chg_lbl);
        if (ch.clicked) {
            ctx.st.stream_settings_open = false;
            ctx.act(.open_stream_picker);
        }

        const set_lbl = i18n.tr("Configurações", "Stream settings");
        const sgw = d.width(fam.get(.semibold), 12, set_lbl) + 18;
        bx -= sgw + 6;
        const sgr: d.Rect = .{ .x = bx, .y = by, .w = sgw, .h = bh };
        const sgh = d.hit(ctx, 0x920B, sgr);
        ctrl_hovered = ctrl_hovered or sgh.hovered;
        qa.mark(sgr, "stream-settings-btn", .{});
        const sbg = if (ctx.st.stream_settings_open) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.84);
        d.rect(dl, sgr, sbg.mix(d.Rgba.white, if (sgh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, sgr.x + 9, d.centerY(sgr, 12), d.Rgba.white, set_lbl);
        if (sgh.clicked) ctx.st.stream_settings_open = !ctx.st.stream_settings_open;
    }

    // Botão Pedir/Parar Controle Remoto (quando assistindo outra pessoa).
    if (!is_cam and owner != ctx.store.me) {
        const viewer_active = ctx.st.remote_ctrl_status == .active_viewer and ctx.st.remote_ctrl_peer == owner;
        const rc_lbl = if (viewer_active)
            i18n.tr("Parar controle (F8)", "Stop control (F8)")
        else if (ctx.st.remote_ctrl_status == .pending_out)
            i18n.tr("Aguardando host…", "Waiting host…")
        else
            i18n.tr("Pedir controle", "Request control");
        const rc_w = d.width(fam.get(.semibold), 12, rc_lbl) + 32;
        bx -= rc_w + 6;
        const rr: d.Rect = .{ .x = bx, .y = by, .w = rc_w, .h = bh };
        const rh = d.hit(ctx, 0x9203, rr);
        ctrl_hovered = ctrl_hovered or rh.hovered;
        qa.mark(rr, "stream-remote-btn", .{});
        const bg = if (viewer_active) ctx.col(.danger) else d.Rgba.hex(0x14161c).alpha(0.82);
        d.rect(dl, rr, bg.mix(d.Rgba.white, if (rh.hovered) 0.14 else 0), 6);
        icons.remoteMouse(dl, rr.x + 14, rr.y + rr.h / 2, d.Rgba.white.u());
        d.text(dl, fam.get(.semibold), 12, rr.x + 25, d.centerY(rr, 12), d.Rgba.white, rc_lbl);
        if (rh.clicked) {
            if (viewer_active) {
                ctx.act(.stop_remote_ctrl);
            } else {
                ctx.act(.{ .request_remote_ctrl = .{ .peer = owner, .perm = .full } });
            }
        }
    }

    if (!is_cam and ctx.st.remote_ctrl_status == .active_viewer and ctx.st.remote_ctrl_peer == owner) {
        const disp_n = remote_ctrl.mgr.viewer_displays.load(.acquire);
        const disp_cur = remote_ctrl.mgr.viewer_active_disp.load(.acquire);
        if (disp_n > 1) {
            const shown_n = @min(@as(usize, disp_n), 4);
            var di: usize = shown_n;
            while (di > 0) {
                di -= 1;
                var mb: [16]u8 = undefined;
                const mlbl = std.fmt.bufPrint(&mb, "M{d}", .{di + 1}) catch "M";
                const mw = d.width(fam.get(.semibold), 11.5, mlbl) + 14;
                bx -= mw + 4;
                const mr: d.Rect = .{ .x = bx, .y = by, .w = mw, .h = bh };
                const mh = d.hit(ctx, 0x9240 + di, mr);
                ctrl_hovered = ctrl_hovered or mh.hovered;
                const active_d = disp_cur == di;
                const mbg = if (active_d) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.82);
                d.rect(dl, mr, mbg.mix(d.Rgba.white, if (mh.hovered) 0.16 else 0), 6);
                d.text(dl, fam.get(.semibold), 11.5, mr.x + 7, d.centerY(mr, 11.5), d.Rgba.white, mlbl);
                if (mh.clicked) {
                    remote_ctrl.mgr.sendControl(.{ .kind = .switch_display, .code = @intCast(di), .seq = remote_seq });
                    remote_seq +%= 1;
                }
            }
        }
    }

    if (!is_cam and owner == ctx.store.me and ctx.st.stream_on and ctx.st.stream_settings_open) {
        ctrl_hovered = drawStreamSettingsPopover(ctx, r, by + bh + 6) or ctrl_hovered;
    }

    const avail_hud_w = bx - r.x - 18;
    if (avail_hud_w >= 64) {
        const hud_w = @min(d.width(fam.get(.semibold), 12, hud) + 20, avail_hud_w);
        const hr: d.Rect = .{ .x = r.x + 10, .y = r.y + 10, .w = hud_w, .h = 26 };
        d.rect(dl, hr, d.Rgba.hex(0x0a0c10).alpha(0.8), 6);
        _ = d.textClipped(dl, fam.get(.semibold), 12, hr.x + 10, d.centerY(hr, 12), d.Rgba.white, hud, hr.w - 16);
    } else if (r.h >= 120) {
        const hud_w = @min(d.width(fam.get(.semibold), 12, hud) + 20, r.w - 20);
        const hr: d.Rect = .{ .x = r.x + 10, .y = by + bh + 6, .w = hud_w, .h = 26 };
        d.rect(dl, hr, d.Rgba.hex(0x0a0c10).alpha(0.8), 6);
        _ = d.textClipped(dl, fam.get(.semibold), 12, hr.x + 10, d.centerY(hr, 12), d.Rgba.white, hud, hr.w - 16);
    }

    if (!is_cam and ctx.st.stream_show_cams and (!ctx.st.call_view or ctx.st.spotlight_fullscreen or r.h < 280)) {
        ctrl_hovered = drawCamOverlayStrip(ctx, r) or ctrl_hovered;
    }

    // Captura de entrada remota quando o controle estilo AnyDesk estiver ativo no espectador.
    const app_focused = ctx.st.window_focused and !ctx.io.*.AppFocusLost;
    const rc_viewer = !is_cam and ctx.st.remote_ctrl_status == .active_viewer and ctx.st.remote_ctrl_peer == owner;
    const dragging_btn = was_down_l or was_down_r or was_down_m or was_down_x1 or was_down_x2;
    const rc_eligible = rc_viewer and view != null and (dragging_btn or !ctrl_hovered) and ctx.st.popup == .none and !ctx.st.settings.open and !ctx.st.palette.open and app_focused;
    var captured_now = false;

    if (rc_eligible) {
        const v = view.?;
        const in_stage = dragging_btn or r.contains(ctx.mouse.x, ctx.mouse.y);
        const norm_opt = if (in_stage)
            (if (dragging_btn)
                video_cfg.mapViewportToNormalizedClamped(ctx.mouse.x, ctx.mouse.y, vid_r.x, vid_r.y, vid_r.w, vid_r.h, v.w, v.h)
            else
                video_cfg.mapViewportToNormalized(ctx.mouse.x, ctx.mouse.y, vid_r.x, vid_r.y, vid_r.w, vid_r.h, v.w, v.h))
        else
            null;
        if (norm_opt) |norm| {
            captured_now = true;
            const moved = last_norm == null or last_norm.?[0] != norm[0] or last_norm.?[1] != norm[1];
            last_norm = norm;
            if (moved) {
                remote_ctrl.mgr.sendControl(.{
                    .kind = .mouse_move,
                    .x = norm[0],
                    .y = norm[1],
                    .seq = remote_seq,
                });
                remote_seq +%= 1;
            }
            const l_down = c.ImGui_IsMouseDown(0);
            const r_down = c.ImGui_IsMouseDown(1);
            const m_down = c.ImGui_IsMouseDown(2);
            const x1_down = c.ImGui_IsMouseDown(3);
            const x2_down = c.ImGui_IsMouseDown(4);
            if (l_down != was_down_l) {
                was_down_l = l_down;
                remote_ctrl.mgr.sendControl(.{ .kind = .mouse_btn, .code = 1, .pressed = l_down, .x = norm[0], .y = norm[1], .seq = remote_seq });
                remote_seq +%= 1;
            }
            if (r_down != was_down_r) {
                was_down_r = r_down;
                remote_ctrl.mgr.sendControl(.{ .kind = .mouse_btn, .code = 3, .pressed = r_down, .x = norm[0], .y = norm[1], .seq = remote_seq });
                remote_seq +%= 1;
            }
            if (m_down != was_down_m) {
                was_down_m = m_down;
                remote_ctrl.mgr.sendControl(.{ .kind = .mouse_btn, .code = 2, .pressed = m_down, .x = norm[0], .y = norm[1], .seq = remote_seq });
                remote_seq +%= 1;
            }
            if (x1_down != was_down_x1) {
                was_down_x1 = x1_down;
                remote_ctrl.mgr.sendControl(.{ .kind = .mouse_btn, .code = 4, .pressed = x1_down, .x = norm[0], .y = norm[1], .seq = remote_seq });
                remote_seq +%= 1;
            }
            if (x2_down != was_down_x2) {
                was_down_x2 = x2_down;
                remote_ctrl.mgr.sendControl(.{ .kind = .mouse_btn, .code = 5, .pressed = x2_down, .x = norm[0], .y = norm[1], .seq = remote_seq });
                remote_seq +%= 1;
            }
            if (@abs(ctx.io.*.MouseWheel) >= 0.001) {
                wheel_accum += ctx.io.*.MouseWheel;
                if (@abs(wheel_accum) >= 1.0) {
                    const clamped = std.math.clamp(@trunc(wheel_accum), -16.0, 16.0);
                    const wheel_i: i16 = @intFromFloat(clamped);
                    wheel_accum -= clamped;
                    if (wheel_i != 0) {
                        remote_ctrl.mgr.sendControl(.{ .kind = .mouse_wheel, .y = @bitCast(wheel_i), .seq = remote_seq });
                        remote_seq +%= 1;
                    }
                }
            }
            if (ctx.st.remote_ctrl_perm == .full) {
                var num_k: c_int = 0;
                if (c.SDL_GetKeyboardState(&num_k)) |ks| {
                    const max_k: usize = @min(@as(usize, @intCast(@max(num_k, 0))), prev_keys.len);
                    var sc: usize = 4;
                    while (sc < max_k) : (sc += 1) {
                        if (!((sc <= 101) or (sc >= 224 and sc <= 231))) continue;
                        if (sc == 65) continue; // Nunca envia F8 (kill switch local).
                        const now_down = ks[sc];
                        if (now_down != prev_keys[sc]) {
                            prev_keys[sc] = now_down;
                            remote_ctrl.mgr.sendControl(.{ .kind = .key, .code = @intCast(sc), .pressed = now_down, .seq = remote_seq });
                            remote_seq +%= 1;
                        }
                    }
                }
            }
            // Retículo sutil e status P2P confirmando controle ativo e latência real.
            d.border(dl, vid_r, ctx.col(.online), 4, 2);
            var nb: [64]u8 = undefined;
            const rtt = remote_ctrl.mgr.rtt_ms.load(.acquire);
            const peer_conn = remote_ctrl.mgr.peerConnected();
            const ntxt = if (peer_conn and rtt > 0)
                (std.fmt.bufPrint(&nb, "AnyDesk {d}ms  •  {d},{d}  •  F8", .{ rtt, norm[0], norm[1] }) catch "AnyDesk")
            else if (peer_conn)
                (std.fmt.bufPrint(&nb, "AnyDesk P2P  •  {d},{d}  •  F8", .{ norm[0], norm[1] }) catch "AnyDesk")
            else
                (std.fmt.bufPrint(&nb, "AnyDesk P2P…  •  F8", .{}) catch "AnyDesk");
            const nw = d.width(fam.get(.semibold), 11.5, ntxt) + 18;
            const nr: d.Rect = .{ .x = r.x + 10, .y = r.bottom() - 32, .w = nw, .h = 22 };
            d.rect(dl, nr, ctx.col(.online).alpha(0.85), 5);
            d.text(dl, fam.get(.semibold), 11.5, nr.x + 9, d.centerY(nr, 11.5), d.Rgba.white, ntxt);
            if (!dragging_btn and r.contains(ctx.mouse.x, ctx.mouse.y)) {
                c.ImDrawList_AddCircleEx(dl, d.v(ctx.mouse.x, ctx.mouse.y), 4.5, d.Rgba.black.alpha(0.75).u(), 12, 2.0, 0);
                c.ImDrawList_AddCircleEx(dl, d.v(ctx.mouse.x, ctx.mouse.y), 4.5, ctx.col(.online).u(), 12, 1.2, 0);
            }
        }
    }
    if (rc_viewer and !captured_now and hasHeldRemote()) {
        remote_ctrl.mgr.sendControl(.{ .kind = .release_all, .seq = remote_seq });
        remote_seq +%= 1;
        resetRemoteInput();
    }
}

fn hasHeldRemote() bool {
    if (was_down_l or was_down_r or was_down_m or was_down_x1 or was_down_x2) return true;
    for (prev_keys) |k| if (k) return true;
    return false;
}

fn countActiveCams(ctx: *const d.Ctx) usize {
    const vc = ctx.st.voice orelse return if (ctx.st.cam_on) 1 else 0;
    const cs = ctx.store.channel(vc) orelse return if (ctx.st.cam_on) 1 else 0;
    var n: usize = 0;
    for (cs.voice_members.items) |uid| {
        if (uid == ctx.store.me) {
            if (ctx.st.cam_on) n += 1;
        } else if (live_video.eng.peerCamSlot(uid) != null or ctx.store.voiceFlags(uid).self_video) {
            n += 1;
        }
    }
    return n;
}

/// Strip flutuante com as câmeras ativas da call sobre o palco da transmissão (DM, chat ou tela cheia).
fn drawCamOverlayStrip(ctx: *d.Ctx, r: d.Rect) bool {
    if (r.w < 260 or r.h < 220) return false;
    const vc = ctx.st.voice orelse return false;
    const cs = ctx.store.channel(vc) orelse return false;
    var cams: [6]u64 = undefined;
    var n: usize = 0;
    // Prioriza quem já tem quadro decodificado no momento, depois self_video.
    for (cs.voice_members.items) |uid| {
        if (n >= cams.len) break;
        const has_slot = if (uid == ctx.store.me) ctx.st.cam_on else live_video.eng.peerCamSlot(uid) != null;
        if (has_slot) {
            cams[n] = uid;
            n += 1;
        }
    }
    for (cs.voice_members.items) |uid| {
        if (n >= cams.len) break;
        if (uid == ctx.store.me or live_video.eng.peerCamSlot(uid) != null) continue;
        if (ctx.store.voiceFlags(uid).self_video) {
            cams[n] = uid;
            n += 1;
        }
    }
    if (n == 0) return false;

    const dl = ctx.dl;
    const fam = ctx.ui;
    const gap: f32 = 8;
    const max_shown: usize = @min(n, 4);
    const max_w = @max(r.w - 28, 120);
    const tile_w: f32 = std.math.clamp(@floor((max_w - @as(f32, @floatFromInt(max_shown - 1)) * gap) / @as(f32, @floatFromInt(max_shown))), 112, 174);
    const tile_h: f32 = @round(tile_w * 9.0 / 16.0);
    const total_w = tile_w * @as(f32, @floatFromInt(max_shown)) + gap * @as(f32, @floatFromInt(max_shown - 1));
    var tx = r.right() - 12 - total_w;
    const ty = r.bottom() - tile_h - 12;

    var hovered_any = false;
    for (cams[0..max_shown], 0..) |uid, idx| {
        const cr: d.Rect = .{ .x = tx, .y = ty, .w = tile_w, .h = tile_h };
        const hb = d.hit(ctx, 0x9300 + idx, cr);
        hovered_any = hovered_any or hb.hovered;
        const speaking = ctx.store.isSpeaking(uid, ctx.now_ms);
        d.shadow(dl, cr, 8, 10, ctx.col(.shadow).alpha(0.55));
        d.rect(dl, cr, d.Rgba.hex(0x11141c).alpha(0.92), 8);
        const slot_opt: ?*live_video.FrameSlot = if (uid == ctx.store.me) &live_video.eng.cam_slot else live_video.eng.peerCamSlot(uid);
        var drew = false;
        if (slot_opt) |sp| {
            if (sp.view(ctx.images.renderer)) |cv| {
                const mirror = uid == ctx.store.me and ctx.st.settings.video_cam_mirror;
                c.ImDrawList_AddImageRounded(
                    dl,
                    cv.ref,
                    d.v(cr.x + 2, cr.y + 2),
                    d.v(cr.right() - 2, cr.bottom() - 2),
                    if (mirror) d.v(1, 0) else d.v(0, 0),
                    if (mirror) d.v(0, 1) else d.v(1, 1),
                    d.Rgba.white.u(),
                    6,
                    0,
                );
                drew = true;
            }
        }
        if (!drew) {
            w.avatarAt(ctx, dl, cs.info.guild, cr.x + cr.w / 2, cr.y + cr.h * 0.44, 34, uid, .circle, null, 1, .{ .animate = false, .request = 64 });
        }
        d.border(dl, cr, if (speaking) ctx.col(.online) else if (hb.hovered) ctx.col(.accent) else ctx.col(.border), 8, if (speaking) 2.5 else 1);
        const cname = ctx.store.nameIn(cs.info.guild, uid) orelse "?";
        const nbw = @min(d.width(fam.get(.semibold), 10.5, cname) + 12, cr.w - 12);
        const nr: d.Rect = .{ .x = cr.x + 6, .y = cr.bottom() - 22, .w = nbw, .h = 16 };
        d.rect(dl, nr, d.Rgba.hex(0x0a0c10).alpha(0.78), 4);
        _ = d.textClipped(dl, fam.get(.semibold), 10.5, nr.x + 6, d.centerY(nr, 10.5), d.Rgba.white, cname, nbw - 12);
        qa.mark(cr, "stream-cam-pip:{d}", .{uid});
        if (hb.clicked) {
            ctx.st.spotlight_cam = if (ctx.st.spotlight_cam == uid) 0 else uid;
        } else if (hb.right) {
            ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        }
        tx += tile_w + gap;
    }
    return hovered_any;
}

/// Painel rápido ao vivo para alterar resolução (720p/1080p), FPS, bitrate, preset, áudio e cursor sem cair da live.
fn drawStreamSettingsPopover(ctx: *d.Ctx, r: d.Rect, top_y: f32) bool {
    const pw: f32 = @min(312, @max(r.w - 24, 220));
    const ph: f32 = 304;
    const py: f32 = @max(r.y + 8, @min(top_y, r.bottom() - ph - 8));
    const pr: d.Rect = .{ .x = @max(r.x + 8, r.right() - 10 - pw), .y = py, .w = pw, .h = ph };
    const dl = ctx.dl;
    const fam = ctx.ui;
    qa.mark(pr, "stream-settings-popover", .{});
    d.shadow(dl, pr, 10, 18, ctx.col(.shadow).alpha(0.65));
    d.rect(dl, pr, ctx.col(.elevated).alpha(0.97), 10);
    d.border(dl, pr, ctx.col(.border), 10, 1);

    const cfg = ctx.st.stream_cfg;
    var next = cfg;
    var changed = false;

    const pad: f32 = 12;
    const cw = pr.w - pad * 2;
    var yy = pr.y + 10;
    d.text(dl, fam.get(.bold), 13, pr.x + pad, yy, ctx.col(.text), i18n.tr("Configurações da transmissão", "Live Stream Settings"));
    yy += 24;

    // Resolução (Discord: 720p / 1080p)
    d.text(dl, fam.get(.semibold), 11, pr.x + pad, yy, ctx.col(.muted), i18n.tr("Resolução", "Resolution"));
    yy += 16;
    const res_opts = [_]video_cfg.Resolution{ .p720, .p1080 };
    const res_lbls = [_][]const u8{ "720p", "1080p" };
    if (pillRow(ctx, dl, fam, 0x9260, pr.x + pad, yy, cw, &res_lbls, if (cfg.resolution == .p720) 0 else 1)) |picked| {
        next.resolution = res_opts[picked];
        if (ctx.st.settings.video_bitrate_mbps == 0) {
            next.bitrate_kbps = next.resolution.defaultBitrateKbps(next.fps);
        }
        changed = true;
    }
    yy += 30;

    // FPS
    d.text(dl, fam.get(.semibold), 11, pr.x + pad, yy, ctx.col(.muted), i18n.tr("Taxa de quadros", "Frame rate"));
    yy += 16;
    const fps_lbls = [_][]const u8{ "30 FPS", "60 FPS" };
    if (pillRow(ctx, dl, fam, 0x9268, pr.x + pad, yy, cw, &fps_lbls, if (cfg.fps >= 45) 1 else 0)) |picked| {
        next.fps = if (picked == 1) 60 else 30;
        if (ctx.st.settings.video_bitrate_mbps == 0) {
            next.bitrate_kbps = next.resolution.defaultBitrateKbps(next.fps);
        }
        changed = true;
    }
    yy += 30;

    // Bitrate (Discord 1080p: Auto / 3M / 4M / 6M / 8M)
    d.text(dl, fam.get(.semibold), 11, pr.x + pad, yy, ctx.col(.muted), i18n.tr("Taxa de bits (Bitrate)", "Bitrate"));
    yy += 16;
    const auto_br = cfg.resolution.defaultBitrateKbps(cfg.fps);
    const br_cur: usize = if (cfg.bitrate_kbps == auto_br and ctx.st.settings.video_bitrate_mbps == 0)
        0
    else if (cfg.bitrate_kbps <= 3500)
        1
    else if (cfg.bitrate_kbps <= 5000)
        2
    else if (cfg.bitrate_kbps <= 7000)
        3
    else
        4;
    const br_lbls = [_][]const u8{ i18n.tr("Auto", "Auto"), "3M", "4M", "6M", "8M" };
    if (pillRow(ctx, dl, fam, 0x9270, pr.x + pad, yy, cw, &br_lbls, br_cur)) |picked| {
        next.bitrate_kbps = switch (picked) {
            1 => 3000,
            2 => 4000,
            3 => 6000,
            4 => 8000,
            else => next.resolution.defaultBitrateKbps(next.fps),
        };
        ctx.st.settings.video_bitrate_mbps = switch (picked) {
            1 => 3,
            2 => 4,
            3 => 6,
            4 => 8,
            else => 0,
        };
        changed = true;
    }
    yy += 30;

    // Preset de desempenho
    d.text(dl, fam.get(.semibold), 11, pr.x + pad, yy, ctx.col(.muted), i18n.tr("Desempenho", "Performance"));
    yy += 16;
    const pf_lbls = [_][]const u8{ i18n.tr("Velocidade", "Speed"), i18n.tr("Equilibrado", "Balanced"), i18n.tr("Qualidade", "Quality") };
    if (pillRow(ctx, dl, fam, 0x9278, pr.x + pad, yy, cw, &pf_lbls, @intFromEnum(cfg.perf_preset))) |picked| {
        next.perf_preset = video_cfg.PerfPreset.fromByte(@intCast(picked));
        ctx.st.settings.video_perf_preset = @intCast(picked);
        changed = true;
    }
    yy += 30;

    // Toggles rápidos
    if (miniToggle(ctx, dl, fam, 0x9280, .{ .x = pr.x + pad, .y = yy, .w = cw, .h = 22 }, i18n.tr("Áudio do sistema", "System audio"), cfg.share_audio)) {
        next.share_audio = !cfg.share_audio;
        changed = true;
    }
    yy += 24;
    if (miniToggle(ctx, dl, fam, 0x9281, .{ .x = pr.x + pad, .y = yy, .w = cw, .h = 22 }, i18n.tr("Capturar cursor do mouse", "Capture mouse cursor"), cfg.capture_cursor)) {
        next.capture_cursor = !cfg.capture_cursor;
        changed = true;
    }
    yy += 24;
    if (miniToggle(ctx, dl, fam, 0x9282, .{ .x = pr.x + pad, .y = yy, .w = cw, .h = 22 }, i18n.tr("Pré-visualizar aqui", "Preview own stream"), cfg.preview_self)) {
        next.preview_self = !cfg.preview_self;
        changed = true;
    }
    yy += 26;

    const sw_r: d.Rect = .{ .x = pr.x + pad, .y = yy, .w = cw, .h = 24 };
    const swh = d.hit(ctx, 0x9283, sw_r);
    d.rect(dl, sw_r, ctx.col(.hover).mix(ctx.col(.accent), if (swh.hovered) 0.3 else 0), 6);
    const sw_lbl = i18n.tr("Trocar janela ou monitor…", "Switch window or display…");
    d.text(dl, fam.get(.semibold), 11.5, sw_r.x + (sw_r.w - d.width(fam.get(.semibold), 11.5, sw_lbl)) / 2, d.centerY(sw_r, 11.5), ctx.col(.text), sw_lbl);
    if (swh.clicked) {
        ctx.st.stream_settings_open = false;
        ctx.act(.open_stream_picker);
    }

    if (changed) ctx.act(.{ .update_stream_cfg = next });
    return pr.contains(ctx.mouse.x, ctx.mouse.y);
}

fn pillRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, id_base: usize, x: f32, y: f32, w_tot: f32, labels: []const []const u8, cur: usize) ?usize {
    const gap: f32 = 4;
    const bw = (w_tot - gap * @as(f32, @floatFromInt(labels.len - 1))) / @as(f32, @floatFromInt(labels.len));
    var out: ?usize = null;
    for (labels, 0..) |lbl, i| {
        const br: d.Rect = .{ .x = x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = y, .w = bw, .h = 22 };
        const hb = d.hit(ctx, id_base + i, br);
        const sel = i == cur;
        d.rect(dl, br, if (sel) ctx.col(.accent) else ctx.col(.surface).mix(ctx.col(.hover), if (hb.hovered) 1 else 0), 5);
        _ = d.textClipped(dl, fam.get(.semibold), 11, br.x + 4, d.centerY(br, 11), if (sel) ctx.col(.accent_text) else ctx.col(.text), lbl, br.w - 8);
        if (hb.clicked) out = i;
    }
    return out;
}

fn miniToggle(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, id: usize, r: d.Rect, lbl: []const u8, on: bool) bool {
    const hb = d.hit(ctx, id, r);
    if (hb.hovered) d.rect(dl, r, ctx.col(.hover).alpha(0.6), 5);
    _ = d.textClipped(dl, fam.get(.medium), 11.5, r.x + 4, d.centerY(r, 11.5), ctx.col(.text), lbl, r.w - 44);
    const sw: d.Rect = .{ .x = r.right() - 34, .y = r.y + (r.h - 16) / 2, .w = 30, .h = 16 };
    d.rect(dl, sw, if (on) ctx.col(.online) else ctx.col(.faint).alpha(0.55), 8);
    d.circle(dl, if (on) sw.right() - 8 else sw.x + 8, sw.y + 8, 6, d.Rgba.white);
    return hb.clicked;
}

/// Libera todo o estado local de mouse/teclado remoto ao encerrar.
pub fn resetRemoteInput() void {
    last_norm = null;
    was_down_l = false;
    was_down_r = false;
    was_down_m = false;
    was_down_x1 = false;
    was_down_x2 = false;
    wheel_accum = 0;
    @memset(&prev_keys, false);
}

/// Visualizador spotlight modal em DM (fora da tela full do call_grid).
/// Abre janela própria antes dos popups/menus para capturar cliques nos botões
/// mesmo em tela cheia sobre o painel lateral ou lista de mensagens.
pub fn modalStage(ctx: *d.Ctx) void {
    const st = ctx.st;
    if ((st.watch_owner == 0 and st.spotlight_cam == 0) or st.call_view or st.voice == null) return;

    const margin: f32 = if (st.spotlight_fullscreen) 8 else 48;
    const wr: d.Rect = .{
        .x = ctx.win.x + margin,
        .y = ctx.win.y + margin,
        .w = @max(ctx.win.w - margin * 2, 200),
        .h = @max(ctx.win.h - margin * 2, 160),
    };
    const modal_above = st.popup != .none or st.settings.open or st.palette.open or st.viewer != null or
        st.remote_ctrl_req != null or @import("search.zig").open or @import("interact.zig").anyOpen() or @import("chamada.zig").ring_channel != 0;

    c.ImGui_SetNextWindowPos(d.v(wr.x, wr.y), 0);
    c.ImGui_SetNextWindowSize(d.v(wr.w, wr.h), 0);
    _ = c.ImGui_Begin("##stream_overlay", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse |
        c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoNav | c.ImGuiWindowFlags_NoFocusOnAppearing);
    defer c.ImGui_End();
    if (!modal_above) d.windowToFront();

    // Captura cliques e rolagem na área do spotlight sem roubar cursor nem cliques dos botões do HUD.
    c.ImGui_SetCursorScreenPos(d.v(wr.x, wr.y));
    c.ImGui_SetNextItemAllowOverlap();
    _ = c.ImGui_InvisibleButton("##stream_stage_catch", d.v(@max(wr.w, 1), @max(wr.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight | c.ImGuiButtonFlags_MouseButtonMiddle);

    const prev = ctx.dl;
    ctx.dl = c.ImGui_GetWindowDrawList();
    defer ctx.dl = prev;
    if (st.watch_owner != 0 and st.spotlight_cam != 0 and wr.w >= 420) {
        const gap: f32 = 8;
        const lw = @round((wr.w - gap) * 0.66);
        draw(ctx, .{ .x = wr.x, .y = wr.y, .w = lw, .h = wr.h });
        drawCam(ctx, .{ .x = wr.x + lw + gap, .y = wr.y, .w = @max(wr.w - lw - gap, 80), .h = wr.h }, st.spotlight_cam);
    } else if (st.spotlight_cam != 0) {
        drawCam(ctx, wr, st.spotlight_cam);
    } else {
        draw(ctx, wr);
    }

    if (!modal_above and !@import("dropdown.zig").ownsEsc() and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        if (st.stream_settings_open) {
            ctx.st.stream_settings_open = false;
        } else if (st.spotlight_cam != 0) {
            ctx.st.spotlight_cam = 0;
            ctx.st.spotlight_fullscreen = false;
        } else {
            ctx.act(.{ .watch_stream = 0 });
        }
    }
}

/// Overlay global: Kill switch F8 / Ctrl+Shift+Esc e banner de consentimento do host.
pub fn overlay(ctx: *d.Ctx) void {
    const st = ctx.st;
    const rc_active = st.remote_ctrl_status == .active_host or st.remote_ctrl_status == .active_viewer or st.remote_ctrl_status == .pending_out;
    if (rc_active or st.remote_ctrl_req != null) {
        const kill_f8 = c.ImGui_IsKeyPressed(c.ImGuiKey_F8);
        const kill_cse = ctx.io.*.KeyCtrl and ctx.io.*.KeyShift and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape);
        if (kill_f8 or kill_cse) {
            resetRemoteInput();
            ctx.act(.stop_remote_ctrl);
        }
    }

    // Banner de consentimento explícito no host para pedidos de controle remoto.
    if (st.remote_ctrl_req) |req| {
        const bw: f32 = @min(540, ctx.win.w - 24);
        const bh: f32 = 72;
        const br: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - bw) / 2, .y = ctx.win.y + 18, .w = bw, .h = bh };
        const fresh_req = last_rc_req_peer != req.peer;
        last_rc_req_peer = req.peer;
        c.ImGui_SetNextWindowPos(d.v(br.x - 16, br.y - 16), 0);
        c.ImGui_SetNextWindowSize(d.v(br.w + 32, br.h + 32), 0);
        if (fresh_req) c.ImGui_SetNextWindowFocus();
        _ = c.ImGui_Begin("##remote_consent", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse |
            c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer c.ImGui_End();
        d.windowToFront();
        const dl = c.ImGui_GetWindowDrawList();

        // Captura hover/cliques no cartão inteiro antes dos botões (permite sobreposição dos botões).
        c.ImGui_SetCursorScreenPos(d.v(br.x, br.y));
        c.ImGui_SetNextItemAllowOverlap();
        _ = c.ImGui_InvisibleButton("##rc_catch", d.v(br.w, br.h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);

        d.shadow(dl, br, 10, 12, ctx.col(.shadow));
        d.rect(dl, br, ctx.col(.overlay), 10);
        d.border(dl, br, ctx.col(.accent), 10, 1.5);
        qa.markTop(br, "remote-consent", .{});

        const who = ctx.store.nameIn(st.guild, req.peer) orelse "?";
        var tb: [120]u8 = undefined;
        const title = i18n.fmt(&tb, "{s} pediu controle remoto", "{s} requested remote control", .{who});
        _ = d.textClipped(dl, ctx.ui.get(.semibold), 13.5, br.x + 14, br.y + 10, ctx.col(.text), title, bw - 28);

        const prev = ctx.dl;
        ctx.dl = dl;
        defer ctx.dl = prev;
        const y2 = br.y + 36;
        var bx = br.right() - 12;
        const deny_lbl = i18n.tr("Recusar", "Deny");
        const full_lbl = i18n.tr("Aceitar (Tudo)", "Accept (Full)");
        const mouse_lbl = i18n.tr("Só mouse", "Mouse only");

        for ([_]struct { lbl: []const u8, perm: video_cfg.RemotePerm, col: d.Rgba, id: usize, mark: []const u8 }{
            .{ .lbl = deny_lbl, .perm = .off, .col = ctx.col(.danger), .id = 0x9220, .mark = "remote-consent-deny" },
            .{ .lbl = full_lbl, .perm = .full, .col = ctx.col(.online), .id = 0x9221, .mark = "remote-consent-full" },
            .{ .lbl = mouse_lbl, .perm = .mouse_only, .col = ctx.col(.accent), .id = 0x9222, .mark = "remote-consent-mouse" },
        }) |btn| {
            const w2 = d.width(ctx.ui.get(.semibold), 12, btn.lbl) + 22;
            bx -= w2 + 8;
            const cr: d.Rect = .{ .x = bx, .y = y2, .w = w2, .h = 26 };
            const ch = d.hit(ctx, btn.id, cr);
            qa.markTop(cr, "{s}", .{btn.mark});
            d.rect(dl, cr, btn.col.mix(d.Rgba.white, if (ch.hovered) 0.16 else 0), 6);
            d.text(dl, ctx.ui.get(.semibold), 12, cr.x + 11, d.centerY(cr, 12), d.Rgba.white, btn.lbl);
            if (ch.clicked) ctx.act(.{ .respond_remote_ctrl = .{ .peer = req.peer, .perm = btn.perm } });
        }
    } else {
        last_rc_req_peer = 0;
    }
    if (st.remote_ctrl_req == null and st.remote_ctrl_status == .active_host) {
        const who = ctx.store.nameIn(st.guild, st.remote_ctrl_peer) orelse "?";
        var kb: [120]u8 = undefined;
        const ktxt = i18n.fmt(&kb, "{s} controlando • F8 para encerrar", "{s} controlling • F8 to stop", .{who});
        const kw = d.width(ctx.ui.get(.semibold), 12.5, ktxt) + 32;
        const kr: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - kw) / 2, .y = ctx.win.y + 12, .w = kw, .h = 30 };
        c.ImGui_SetNextWindowPos(d.v(kr.x - 4, kr.y - 4), 0);
        c.ImGui_SetNextWindowSize(d.v(kr.w + 8, kr.h + 8), 0);
        _ = c.ImGui_Begin("##remote_kill", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse |
            c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoNav | c.ImGuiWindowFlags_NoFocusOnAppearing);
        defer c.ImGui_End();
        d.windowToFront();
        const dl = c.ImGui_GetWindowDrawList();
        const kh = d.hit(ctx, 0x9225, kr);
        qa.markTop(kr, "remote-kill-pill", .{});
        d.rect(dl, kr, ctx.col(.danger).mix(d.Rgba.black, if (kh.hovered) 0.15 else 0), 15);
        d.text(dl, ctx.ui.get(.semibold), 12.5, kr.x + 16, d.centerY(kr, 12.5), d.Rgba.white, ktxt);
        if (kh.clicked) ctx.act(.stop_remote_ctrl);
    }
}
