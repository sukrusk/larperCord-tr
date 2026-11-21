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

var remote_seq: u32 = 1;
var last_norm: ?[2]u16 = null;
var was_down_l: bool = false;
var was_down_r: bool = false;
var was_down_m: bool = false;
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
            i18n.tr("Aguardando quadro 4K NV12… (use Kare İste se demorar)", "Waiting for 4K NV12 frame… (click Keyframe if stuck)");
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
    const hud_w = @min(d.width(fam.get(.semibold), 12, hud) + 20, r.w * 0.56);
    const hr: d.Rect = .{ .x = r.x + 10, .y = r.y + 10, .w = hud_w, .h = 26 };
    d.rect(dl, hr, d.Rgba.hex(0x0a0c10).alpha(0.8), 6);
    _ = d.textClipped(dl, fam.get(.semibold), 12, hr.x + 10, d.centerY(hr, 12), d.Rgba.white, hud, hr.w - 16);

    // HUD superior direito: Fechar / Tela cheia / Zoom / Keyframe / Fonte / Controle remoto.
    var bx = r.right() - 10;
    const bh: f32 = 28;
    const by = r.y + 10;

    // Botão fechar spotlight.
    bx -= bh;
    const xr: d.Rect = .{ .x = bx, .y = by, .w = bh, .h = bh };
    const xh = d.hit(ctx, 0x9201, xr);
    qa.mark(xr, "stream-close", .{});
    d.rect(dl, xr, (if (xh.hovered) ctx.col(.danger) else d.Rgba.hex(0x14161c).alpha(0.82)), 6);
    d.line(dl, xr.x + 9, xr.y + 9, xr.right() - 9, xr.bottom() - 9, d.Rgba.white, 1.8);
    d.line(dl, xr.right() - 9, xr.y + 9, xr.x + 9, xr.bottom() - 9, d.Rgba.white, 1.8);
    if (xh.clicked) {
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
    d.rect(dl, fr, (if (ctx.st.spotlight_fullscreen) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.82)).mix(d.Rgba.white, if (fh.hovered) 0.14 else 0), 6);
    icons.fullscreen(dl, fr.x + fr.w / 2, fr.y + fr.h / 2, d.Rgba.white.u());
    if (fh.clicked) ctx.st.spotlight_fullscreen = !ctx.st.spotlight_fullscreen;

    // Sığdır / Doldur (Zoom).
    const z_lbl = if (zoom_fill) i18n.tr("Sığdır", "Fit") else i18n.tr("Doldur", "Fill");
    const zw = d.width(fam.get(.semibold), 12, z_lbl) + 18;
    bx -= zw + 6;
    const zr: d.Rect = .{ .x = bx, .y = by, .w = zw, .h = bh };
    const zh = d.hit(ctx, 0x9204, zr);
    d.rect(dl, zr, (if (zoom_fill) ctx.col(.accent) else d.Rgba.hex(0x14161c).alpha(0.82)).mix(d.Rgba.white, if (zh.hovered) 0.14 else 0), 6);
    d.text(dl, fam.get(.semibold), 12, zr.x + 9, d.centerY(zr, 12), d.Rgba.white, z_lbl);
    if (zh.clicked) zoom_fill = !zoom_fill;

    var ctrl_hovered = xh.hovered or fh.hovered or zh.hovered;
    if (owner != ctx.store.me) {
        const kf_lbl = i18n.tr("Kare İste", "Keyframe");
        const kfw = d.width(fam.get(.semibold), 12, kf_lbl) + 18;
        bx -= kfw + 6;
        const kfr: d.Rect = .{ .x = bx, .y = by, .w = kfw, .h = bh };
        const kfh = d.hit(ctx, 0x9205, kfr);
        ctrl_hovered = ctrl_hovered or kfh.hovered;
        d.rect(dl, kfr, d.Rgba.hex(0x14161c).alpha(0.82).mix(d.Rgba.white, if (kfh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, kfr.x + 9, d.centerY(kfr, 12), d.Rgba.white, kf_lbl);
        if (kfh.clicked) ctx.act(.request_keyframe);
    } else if (!is_cam and ctx.st.stream_on) {
        const stop_lbl = i18n.tr("Durdur", "Stop");
        const sw = d.width(fam.get(.semibold), 12, stop_lbl) + 18;
        bx -= sw + 6;
        const sr: d.Rect = .{ .x = bx, .y = by, .w = sw, .h = bh };
        const sh = d.hit(ctx, 0x9207, sr);
        ctrl_hovered = ctrl_hovered or sh.hovered;
        d.rect(dl, sr, ctx.col(.danger).mix(d.Rgba.white, if (sh.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, sr.x + 9, d.centerY(sr, 12), d.Rgba.white, stop_lbl);
        if (sh.clicked) ctx.act(.stop_screen_share);

        const chg_lbl = i18n.tr("Kaynak Değiştir", "Switch source");
        const cw = d.width(fam.get(.semibold), 12, chg_lbl) + 18;
        bx -= cw + 6;
        const cr: d.Rect = .{ .x = bx, .y = by, .w = cw, .h = bh };
        const ch = d.hit(ctx, 0x9206, cr);
        ctrl_hovered = ctrl_hovered or ch.hovered;
        d.rect(dl, cr, d.Rgba.hex(0x14161c).alpha(0.82).mix(d.Rgba.white, if (ch.hovered) 0.14 else 0), 6);
        d.text(dl, fam.get(.semibold), 12, cr.x + 9, d.centerY(cr, 12), d.Rgba.white, chg_lbl);
        if (ch.clicked) ctx.act(.open_stream_picker);
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

    // Captura de entrada remota quando o controle estilo AnyDesk estiver ativo no espectador.
    if (!is_cam and ctx.st.remote_ctrl_status == .active_viewer and ctx.st.remote_ctrl_peer == owner and view != null and !ctrl_hovered and ctx.st.popup == .none) {
        const v = view.?;
        if (video_cfg.mapViewportToNormalized(ctx.mouse.x, ctx.mouse.y, vid_r.x, vid_r.y, vid_r.w, vid_r.h, v.w, v.h)) |norm| {
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
            if (@abs(ctx.io.*.MouseWheel) >= 0.01) {
                const wheel_i: i16 = @intFromFloat(std.math.clamp(ctx.io.*.MouseWheel, -16, 16));
                if (wheel_i != 0) {
                    remote_ctrl.mgr.sendControl(.{ .kind = .mouse_wheel, .y = @bitCast(wheel_i), .seq = remote_seq });
                    remote_seq +%= 1;
                }
            }
            if (ctx.st.remote_ctrl_perm == .full) {
                var num_k: c_int = 0;
                if (c.SDL_GetKeyboardState(&num_k)) |ks| {
                    const max_k: usize = @min(@as(usize, @intCast(@max(num_k, 0))), prev_keys.len);
                    var sc: usize = 4;
                    while (sc < max_k) : (sc += 1) {
                        if (!((sc <= 82) or (sc >= 224 and sc <= 230))) continue;
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
            // Retículo sutil confirmando coordenadas exatas 0..65535 sobre o frame 4K.
            d.border(dl, vid_r, ctx.col(.online), 4, 2);
            var nb: [64]u8 = undefined;
            const ntxt = std.fmt.bufPrint(&nb, "AnyDesk {d},{d}  •  F8", .{ norm[0], norm[1] }) catch "AnyDesk";
            const nw = d.width(fam.get(.semibold), 11.5, ntxt) + 18;
            const nr: d.Rect = .{ .x = r.x + 10, .y = r.bottom() - 32, .w = nw, .h = 22 };
            d.rect(dl, nr, ctx.col(.online).alpha(0.85), 5);
            d.text(dl, fam.get(.semibold), 11.5, nr.x + 9, d.centerY(nr, 11.5), d.Rgba.white, ntxt);
        }
    }
}

/// Libera todo o estado local de mouse/teclado remoto ao encerrar.
pub fn resetRemoteInput() void {
    last_norm = null;
    was_down_l = false;
    was_down_r = false;
    was_down_m = false;
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
    if (st.spotlight_cam != 0) drawCam(ctx, wr, st.spotlight_cam) else draw(ctx, wr);

    if (!modal_above and !@import("dropdown.zig").ownsEsc() and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        if (st.spotlight_cam != 0) {
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
