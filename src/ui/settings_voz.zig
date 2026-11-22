//! Configurações → Voz: microfone e saída, volumes, medidor, teste do
//! microfone, detecção de voz ou aperte para falar, filtros e os sons de cada
//! evento (desligado, um embutido ou um arquivo da pessoa, com volume e Ouvir).
//! Só desenha e guarda em `Settings`: quem abre o áudio é net/voz_audio.zig,
//! que também mede o microfone enquanto esta página está aberta.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const inbox = @import("inbox.zig");
const S = @import("settings_state.zig");
const voz = @import("../core/voz.zig");
const sons = @import("../core/sons.zig");
const ruido = @import("../core/ruido.zig");
const voz_audio = @import("../net/voz_audio.zig");
const ptt_global = @import("../platform/ptt_global.zig");
const channels_ui = @import("comp_channels.zig");
const dropdown = @import("dropdown.zig");
const live_video = @import("live_video.zig");
const video_cfg = @import("../core/video_cfg.zig");

/// Ids de `d.hit` desta página (longe dos sequenciais de settings.Page).
const base_id: usize = 0x5E000;

var mic_list: voz_audio.DeviceList = .{};
var out_list: voz_audio.DeviceList = .{};
var list_gen: u32 = 0;
var cam_devs: [8]live_video.CamDevice = undefined;
var cam_devs_n: usize = 0;
var cam_probed: bool = false;
var cam_test_on: bool = false;

pub fn stopPreviewIfClosed(open: bool, is_voz_page: bool, in_call_cam: bool) void {
    if (!cam_test_on) return;
    if (in_call_cam) {
        cam_test_on = false;
        return;
    }
    if (!open or !is_voz_page) {
        cam_test_on = false;
        live_video.eng.stopCamera();
    }
}

fn camBitrateToIdx(mbps: u8) u8 {
    return switch (mbps) {
        0 => 0,
        1...2 => 1,
        3...4 => 2,
        5...7 => 3,
        else => 4,
    };
}

fn idxToCamMbps(idx: u8) u8 {
    return switch (idx) {
        0 => 0,
        1 => 2,
        2 => 4,
        3 => 6,
        else => 10,
    };
}

fn kfSecToIdx(sec: u8) u8 {
    return switch (sec) {
        1 => 0,
        4 => 2,
        else => 1,
    };
}

fn idxToKfSec(idx: u8) u8 {
    return switch (idx) {
        0 => 1,
        2 => 4,
        else => 2,
    };
}

fn startConfiguredCamTest(s: *const @import("settings_state.zig").Settings) bool {
    const tr_res = video_cfg.camResolution(s.video_cam_res, video_cfg.Resolution.fromByte(s.video_res));
    const tr_fps = video_cfg.camFpsValue(s.video_cam_fps);
    const cam_kbps: u32 = if (s.video_cam_bitrate_mbps > 0)
        std.math.clamp(@as(u32, s.video_cam_bitrate_mbps) * 1000, 800, 15_000)
    else
        tr_res.defaultBitrateKbps(tr_fps);
    live_video.eng.cam_perf = video_cfg.PerfPreset.fromByte(s.video_perf_preset);
    live_video.eng.cam_kf_sec = s.video_kf_sec;
    live_video.eng.configureCamera(cam_kbps, s.video_hw, true);
    return live_video.eng.startCamera(s.video_cam_idx, tr_res, tr_fps, true);
}

fn bitrateToIdx(mbps: u8) u8 {
    return switch (mbps) {
        0 => 0,
        1...3 => 1,
        4...5 => 2,
        6...7 => 3,
        else => 4,
    };
}

fn idxToMbps(idx: u8) u8 {
    return switch (idx) {
        1 => 3,
        2 => 4,
        3 => 6,
        4 => 8,
        else => 0,
    };
}

pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    // O medidor anda sozinho: redesenha 20 vezes por segundo só nesta página.
    anim.every(50);
    const gen = voz_audio.sh.list_gen.load(.acquire);
    if (gen != list_gen) {
        list_gen = gen;
        voz_audio.copyDevices(&mic_list, &out_list);
    }

    p.title(i18n.tr("Voz", "Voice"));

    // Entrada à esquerda, saída à direita, como no Discord.
    const col = (p.w - 24) / 2;
    const col2 = p.x + col + 24;
    const top = p.y;
    const mic_end = picker(p, p.x, col, top, 1, i18n.tr("Microfone", "Microphone"), "voz-mic", &mic_list, &s.voice_mic, voz_audio.sh.mic_fallback.load(.monotonic));
    const out_end = picker(p, col2, col, top, 2, i18n.tr("Saída", "Output"), "voz-out", &out_list, &s.voice_out, voz_audio.sh.out_fallback.load(.monotonic));
    p.y = @max(mic_end, out_end);
    p.note(i18n.tr("Trocar vale na hora, mesmo no meio de uma call.", "Changes apply right away, even in the middle of a call."));
    const vol_y = p.y;
    volume(p, p.x, col, vol_y, 10, i18n.tr("Volume de entrada", "Input volume"), &s.voice_in_gain);
    volume(p, col2, col, vol_y, 11, i18n.tr("Volume de saída", "Output volume"), &s.voice_out_gain);
    p.y = vol_y + 66;

    p.divider();
    p.heading(i18n.tr("Modo de entrada", "Input mode"));
    mode(p, &s.voice_ptt);
    if (s.voice_ptt) pushToTalk(p, &s.voice_key) else p.toggle(i18n.tr("Sensibilidade automática", "Automatic sensitivity"), i18n.tr("Aprende o ruído de fundo e ajusta o limiar sozinho.", "Learns the background noise and sets the threshold by itself."), &s.voice_auto);

    d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), if (s.voice_ptt) i18n.tr("MICROFONE", "MICROPHONE") else i18n.tr("SENSIBILIDADE", "SENSITIVITY"));
    p.y += 22;
    meter(p, s);
    micTest(p);

    p.divider();
    p.heading(i18n.tr("Filtros", "Filters"));
    denoise(p, &s.voice_denoise);
    p.toggle(i18n.tr("Tirar ronco (passa-altas)", "Remove rumble (high-pass)"), i18n.tr("Corta os graves abaixo de 90 Hz: vento, ventilador, zumbido da tomada.", "Cuts lows below 90 Hz: wind, fans, mains hum."), &s.voice_highpass);
    p.toggle(i18n.tr("Porta de ruído", "Noise gate"), i18n.tr("Abaixa o som quando o microfone só capta o ruído de fundo.", "Lowers the sound while the mic only picks up background noise."), &s.voice_gate);

    p.divider();
    p.heading(i18n.tr("Sons", "Sounds"));
    p.toggle(i18n.tr("Sons da call", "Call sounds"), i18n.tr("Avisos curtos ao entrar, sair, mutar, ensurdecer e quando alguém entra ou sai. O toque de chamada segue a escolha dele, abaixo.", "Short cues when you join, leave, mute, deafen and when someone joins or leaves. The ringtone follows its own choice below."), &s.voice_sounds);
    soundList(p, s);

    p.divider();
    p.heading(i18n.tr("Vídeo e Câmera", "Video & Camera"));
    p.note(i18n.tr(
        "Escolha sua webcam, qualidade da câmera, compartilhamento de tela (Discord 1080p) e perfil de desempenho na aba Vídeo e Câmera.",
        "Pick your webcam, camera quality, screen share (Discord 1080p) and performance profile in Video & Camera.",
    ));
    if (p.buttonSoft(i18n.tr("Abrir Vídeo e Câmera", "Open Video & Camera"))) s.page = .video;
}

pub fn drawVideo(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;

    p.title(i18n.tr("Vídeo e Câmera", "Video & Camera"));

    if (!cam_probed and !qa.on()) {
        cam_devs_n = live_video.eng.listCameras(&cam_devs);
        cam_probed = true;
        if (cam_devs_n > 0 and s.video_cam_idx >= cam_devs_n) s.video_cam_idx = 0;
    }

    p.heading(i18n.tr("Câmera e dispositivos", "Camera & devices"));
    if (cam_devs_n > 0) {
        for (0..cam_devs_n) |ci| {
            const cr: d.Rect = .{ .x = p.x, .y = p.y, .w = @min(p.w, 460), .h = 36 };
            const ch = d.hit(ctx, p.id(), cr);
            qa.mark(cr, "cam-dev:{d}", .{ci});
            const sel = s.video_cam_idx == ci;
            const rad = @max(ctx.th.radius, 6);
            d.rect(p.dl, cr, if (sel) ctx.col(.selected) else if (ch.hovered) ctx.col(.hover) else ctx.col(.elevated), rad);
            d.border(p.dl, cr, if (sel) ctx.col(.accent) else ctx.col(.border), rad, if (sel) 1.5 else 1);
            var cb_name: [120]u8 = undefined;
            const clbl = std.fmt.bufPrint(&cb_name, "{d}. {s}", .{ ci + 1, cam_devs[ci].slice() }) catch cam_devs[ci].slice();
            _ = d.textClipped(p.dl, p.font(if (sel) .semibold else .medium), 13.5, cr.x + 12, d.centerY(cr, 13.5), ctx.col(.text), clbl, cr.w - 24);
            if (ch.clicked) {
                s.video_cam_idx = @intCast(ci);
                if (ctx.st.cam_on) {
                    ctx.act(.{ .switch_camera = s.video_cam_idx });
                } else if (cam_test_on) {
                    _ = startConfiguredCamTest(s);
                }
            }
            p.y += 42;
        }
    } else {
        p.note(i18n.tr(
            "Nenhuma webcam física detectada agora (o teste ainda abre uma prévia de demonstração).",
            "No physical webcam detected right now (testing still opens a demo preview).",
        ));
    }
    if (p.buttonSoft(i18n.tr("Atualizar câmeras", "Refresh cameras"))) {
        cam_devs_n = if (qa.on()) 0 else live_video.eng.listCameras(&cam_devs);
        cam_probed = true;
        if (cam_devs_n > 0) {
            if (s.video_cam_idx >= cam_devs_n) s.video_cam_idx = 0;
            const dev = &cam_devs[s.video_cam_idx];
            ctx.st.showToast(ctx.now_ms, false, "câmera #{d}: {s}", "camera #{d}: {s}", .{ s.video_cam_idx + 1, dev.slice() });
        } else {
            ctx.st.showToast(ctx.now_ms, false, "nenhuma webcam física encontrada (modo demo simulado disponível)", "no physical webcam found (demo preview available)", .{});
        }
    }
    if (!ctx.st.cam_on) {
        p.sameLine();
        if (p.button(if (cam_test_on) i18n.tr("Ön izlemeyi durdur", "Stop preview") else i18n.tr("Kamerayı test et", "Test camera"), cam_test_on)) {
            if (cam_test_on) {
                cam_test_on = false;
                live_video.eng.stopCamera();
            } else {
                if (startConfiguredCamTest(s)) {
                    cam_test_on = true;
                } else {
                    ctx.st.showToast(ctx.now_ms, true, "nenhuma câmera aberta (verifique a permissão)", "no camera opened (check permission)", .{});
                }
            }
        }
    }
    if (cam_test_on or ctx.st.cam_on) {
        anim.every(33);
        const pw: f32 = @min(p.w, 360);
        const ph: f32 = @round(pw * 9.0 / 16.0);
        const pr: d.Rect = .{ .x = p.x, .y = p.y, .w = pw, .h = ph };
        const rad = @max(ctx.th.radius, 8);
        d.rect(p.dl, pr, d.Rgba.hex(0x0c0e12), rad);
        d.border(p.dl, pr, ctx.col(.border), rad, 1);
        if (live_video.eng.cam_slot.view(ctx.images.renderer)) |cv| {
            const inner = pr.inset(3, 3);
            const vw: f32 = @floatFromInt(cv.w);
            const vh: f32 = @floatFromInt(cv.h);
            const sc = @min(inner.w / vw, inner.h / vh);
            const dw = vw * sc;
            const dh = vh * sc;
            const vx = inner.x + (inner.w - dw) / 2;
            const vy = inner.y + (inner.h - dh) / 2;
            const mir = s.video_cam_mirror;
            c.ImDrawList_AddImageRounded(
                p.dl,
                cv.ref,
                d.v(vx, vy),
                d.v(vx + dw, vy + dh),
                if (mir) d.v(1, 0) else d.v(0, 0),
                if (mir) d.v(0, 1) else d.v(1, 1),
                d.Rgba.white.u(),
                6,
                0,
            );
        } else {
            const wt = i18n.tr("Kamera başlatılıyor…", "Starting camera…");
            _ = d.textClipped(p.dl, p.font(.regular), 13, pr.x + 14, d.centerY(pr, 13), ctx.col(.muted), wt, pr.w - 28);
        }
        p.y += ph + 12;
    }

    p.heading(i18n.tr("Câmera (Desempenho & RAM)", "Camera (Performance & RAM)"));
    p.segmented(&.{ "480p", "720p", "1080p", i18n.tr("Igual à tela", "Match stream") }, &s.video_cam_res);
    p.segmented(&.{ "15 FPS", "30 FPS", "60 FPS" }, &s.video_cam_fps);
    var cbr_idx = camBitrateToIdx(s.video_cam_bitrate_mbps);
    const prev_cbr_idx = cbr_idx;
    p.segmented(&.{ "Auto", "2 Mbps", "4 Mbps", "6 Mbps", "10 Mbps" }, &cbr_idx);
    if (cbr_idx != prev_cbr_idx) s.video_cam_bitrate_mbps = idxToCamMbps(cbr_idx);
    p.toggle(
        i18n.tr("Kamera ön izlemesini aynala", "Mirror camera self-preview"),
        i18n.tr("Yalnızca kendi ekranındaki kamera ön izlemesini yatay çevirir.", "Horizontally flips your own camera preview locally."),
        &s.video_cam_mirror,
    );

    p.divider();
    p.heading(i18n.tr("Transmissão de Tela (Discord 1080p)", "Screen Share (Discord 1080p)"));
    p.note(i18n.tr(
        "Resolução padrão para Go Live do Discord em NV12 de baixa memória (~3,0 MiB em 1080p).",
        "Default Discord Go Live quality using low-RAM NV12 frames (~3.0 MiB at 1080p).",
    ));
    if (s.video_res > 1) s.video_res = 1;
    p.segmented(&.{ "720p", "1080p" }, &s.video_res);
    p.segmented(&.{ "30 FPS", "60 FPS" }, &s.video_fps);
    var br_idx = bitrateToIdx(s.video_bitrate_mbps);
    const prev_br_idx = br_idx;
    p.segmented(&.{ i18n.tr("Otomatik", "Auto"), "3 Mbps", "4 Mbps", "6 Mbps", "8 Mbps" }, &br_idx);
    if (br_idx != prev_br_idx) s.video_bitrate_mbps = idxToMbps(br_idx);
    p.toggle(
        i18n.tr("Aceleração em GPU (DX11/Media Foundation)", "GPU hardware acceleration (DX11/Media Foundation)"),
        i18n.tr("Mantém os quadros 1080p na VRAM da GPU sem cópias extras na RAM.", "Keeps 1080p frames in GPU VRAM without extra CPU RAM copies."),
        &s.video_hw,
    );
    p.segmented(&.{ i18n.tr("Velocidade", "Speed"), i18n.tr("Equilibrado", "Balanced"), i18n.tr("Qualidade", "Quality") }, &s.video_perf_preset);
    p.segmented(&.{ "Auto", "DXGI", "WGC" }, &s.video_cap_mode);
    var kf_idx = kfSecToIdx(s.video_kf_sec);
    const prev_kf_idx = kf_idx;
    p.segmented(&.{ "Keyframe 1s", "Keyframe 2s", "Keyframe 4s" }, &kf_idx);
    if (kf_idx != prev_kf_idx) s.video_kf_sec = idxToKfSec(kf_idx);
    p.segmented(&.{ "2 FPS (Eco)", "4 FPS", "10 FPS" }, &s.video_static_fps);
    p.note(i18n.tr(
        "No Discord SFU o app negocia H.264 + DAVE + OP 12 em até 1080p para aparecer no cliente oficial do Discord; WGC evita congelamento em tela parada.",
        "On Discord SFU, the app negotiates H.264 + DAVE + OP 12 up to 1080p so streams appear in the official Discord client; WGC prevents static-screen stalls.",
    ));
    p.toggle(
        i18n.tr("Paylaşımda fare imlecini göster", "Show mouse cursor while sharing"),
        i18n.tr("Pencere veya monitör paylaşımında fare imlecini videoya dahil eder.", "Includes mouse cursor when sharing windows or screens."),
        &s.video_cursor,
    );
    p.toggle(
        i18n.tr("Kendi yayınımı sahnede ön izle", "Preview own stream on stage"),
        i18n.tr("Kapalıysa yalnızca karşıya gider, yerel ön izleme kopyası yapılmaz.", "When off, streams to peers without local preview readback."),
        &s.video_self_preview,
    );
    var cfg_b: [160]u8 = undefined;
    const res_enum = video_cfg.Resolution.fromByte(s.video_res);
    const dims = res_enum.dims();
    p.note(i18n.fmt(
        &cfg_b,
        "Buffer NV12 estimado para {d}x{d}: {d:.1} MiB",
        "Estimated NV12 frame size for {d}x{d}: {d:.1} MiB",
        .{ dims[0], dims[1], @as(f64, @floatFromInt(video_cfg.nv12ByteSize(dims[0], dims[1]))) / (1024.0 * 1024.0) },
    ));
    p.heading(i18n.tr("Controle remoto (AnyDesk)", "Remote Control (AnyDesk)"));
    p.note(i18n.tr(
        "Define quem pode pedir controle do seu mouse ou teclado ao assistir sua tela (sempre pede confirmação; F8 encerra na hora).",
        "Default permission when viewers request mouse/keyboard control on your screen share (always asks consent; F8 kills immediately).",
    ));
    p.segmented(&.{
        i18n.tr("Desligado", "Off"),
        i18n.tr("Só mouse", "Mouse only"),
        i18n.tr("Completo", "Full"),
    }, &s.remote_ctrl_allow);
}

// --- Sons de cada evento --------------------------------------------------------

/// O evento esperando o arquivo do seletor do sistema.
var picking: ?sons.Event = null;
/// O seletor foi cancelado (o aviso vem da thread do diálogo).
var pick_cancelled = std.atomic.Value(bool).init(false);

fn eventLabel(e: sons.Event) []const u8 {
    return switch (e) {
        .join => i18n.tr("Você entrou na call", "You joined a call"),
        .leave => i18n.tr("Você saiu da call", "You left a call"),
        .user_join => i18n.tr("Alguém entrou na sua call", "Someone joined your call"),
        .user_leave => i18n.tr("Alguém saiu da sua call", "Someone left your call"),
        .mute => i18n.tr("Mutar", "Mute"),
        .unmute => i18n.tr("Desmutar", "Unmute"),
        .deafen => i18n.tr("Ensurdecer", "Deafen"),
        .undeafen => i18n.tr("Desensurdecer", "Undeafen"),
        .ring => i18n.tr("Chamada recebida (toque)", "Incoming call (ringtone)"),
        .message => i18n.tr("Mensagem nova (DM ou menção)", "New message (DM or mention)"),
    };
}

fn variantLabel(v: sons.Variant) []const u8 {
    return switch (v) {
        .off => i18n.tr("Desligado", "Off"),
        .classic => i18n.tr("Clássico", "Classic"),
        .soft => i18n.tr("Suave", "Soft"),
        .glass => i18n.tr("Cristal", "Crystal"),
        .retro => i18n.tr("Retrô", "Retro"),
        .custom => i18n.tr("Seu arquivo", "Your file"),
    };
}

fn soundList(p: anytype, s: *S.Settings) void {
    p.note(i18n.tr("Cada som pode ser desligado, trocado por outro embutido ou por um arquivo seu: WAV (PCM) ou Ogg Opus, até 2 MB e 5 s (o toque, até 15 s). O arquivo é copiado para a pasta do larperCord.", "Each sound can be turned off, swapped for another built-in one or for a file of yours: WAV (PCM) or Ogg Opus, up to 2 MB and 5 s (the ringtone, up to 15 s). The file is copied into larperCord's folder."));
    p.y += 6;
    for (std.enums.values(sons.Event)) |e| if (e != .message) soundRow(p, s, e);
    // Não é da call: a chave dele fica em Notificações (que também mostra esta linha).
    p.note(i18n.tr("O som de mensagem nova liga e desliga em Notificações, à parte dos sons da call.", "The new message sound is turned on and off in Notifications, apart from the call sounds."));
    p.y += 6;
    soundRow(p, s, .message);
}

/// Uma linha por evento: o nome (e o arquivo, se é um), a escolha, o Ouvir e,
/// embaixo, o volume. Também em Notificações, para a mensagem nova.
pub fn soundRow(p: anytype, s: *S.Settings, e: sons.Event) void {
    const ctx = p.ctx;
    const i = @backingInt(e);
    const key = @tagName(e);
    const variant = S.soundVariant(s, e);
    const file = S.soundFile(s, e);
    const has_file = file.len > 0;
    const chosen = sons.Variant.fromByte(variant.*);
    // "Arquivo" sem arquivo (configuração editada à mão) toca o clássico.
    const shown: sons.Variant = if (chosen == .custom and !has_file) .classic else chosen;
    const audible = shown != .off;
    const y0 = p.y;

    const play_r: d.Rect = .{ .x = p.x + p.w - 36, .y = y0, .w = 36, .h = 36 };
    const box_w = @min(@as(f32, 230), p.w * 0.42);
    const box_r: d.Rect = .{ .x = play_r.x - 8 - box_w, .y = y0, .w = box_w, .h = 36 };
    const text_w = @max(box_r.x - p.x - 12, 0);

    // Com o nome do arquivo embaixo, o do evento sobe; sozinho, fica no meio da linha.
    const ly = y0 + (if (shown == .custom) @as(f32, 0) else 9);
    const lw = d.textClipped(p.dl, p.font(.medium), 15, p.x, ly, if (audible) ctx.col(.text) else ctx.col(.muted), eventLabel(e), text_w);
    p.markText(.{ .x = p.x, .y = ly, .w = lw, .h = 18 });
    if (shown == .custom) {
        const bad = voz_audio.sh.custom_bad.load(.monotonic) & (@as(u16, 1) << @intCast(i)) != 0;
        const sub = if (bad) i18n.tr("O arquivo não abriu: tocando o clássico", "The file didn't open: playing the classic one") else sons.displayName(e, file.slice());
        const sr: d.Rect = .{ .x = p.x, .y = y0 + 20, .w = text_w, .h = 16 };
        qa.mark(sr, "som-nome:{s}", .{key});
        _ = d.textClipped(p.dl, p.font(.regular), 13, sr.x, sr.y, if (bad) ctx.col(.danger) else ctx.col(.faint), sub, text_w);
    }

    // A escolha: abre a lista por cima da página.
    const box_key = base_id + 0x100 + i;
    const hb = d.hit(ctx, box_key, box_r);
    qa.mark(box_r, "som-var:{s}", .{key});
    if (hb.clicked) dropdown.toggle(box_key);
    const opened = dropdown.isOpen(box_key);
    d.rect(p.dl, box_r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, box_r, if (hb.hovered or opened) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
    _ = d.textClipped(p.dl, p.font(.medium), 14, box_r.x + 12, d.centerY(box_r, 14), if (audible) ctx.col(.text) else ctx.col(.muted), variantLabel(shown), box_r.w - 40);
    icons.chevron(p.dl, box_r.right() - 18, box_r.y + 18, ctx.col(.muted).u(), if (opened) 0 else 1);

    // Ouvir (mesmo com os sons da call desligados; desligado não tem o que tocar).
    const ph = d.hit(ctx, base_id + 0x140 + i, play_r);
    qa.mark(play_r, "som-play:{s}", .{key});
    const pk = anim.to(anim.id("som-play", i), if (ph.hovered and audible) 1 else 0, 20);
    const pc = if (audible) ctx.col(.accent).mix(d.Rgba.white, 0.1 * pk) else ctx.col(.faint).alpha(0.5);
    d.circle(p.dl, play_r.x + 18, play_r.y + 18, 16, pc);
    const ink = if (audible) ctx.col(.accent_text) else ctx.col(.muted);
    const cx = play_r.x + 18;
    const cy = play_r.y + 18;
    c.ImDrawList_AddTriangleFilled(p.dl, d.v(cx - 4, cy - 7), d.v(cx - 4, cy + 7), d.v(cx + 7, cy), ink.u());
    d.tip(ctx, play_r, if (audible) i18n.tr("Ouvir", "Preview") else i18n.tr("Desligado", "Off"), ph.hovered);
    if (ph.clicked and audible) voz_audio.preview(e);

    soundVolume(p, y0 + 44, i, S.soundVolume(s, e), audible);
    p.y = y0 + 80;
    d.line(p.dl, p.x, p.y - 6, p.x + p.w, p.y - 6, ctx.col(.border), 1);
    p.y += 8;

    // A lista: os embutidos, o arquivo já escolhido (se há) e escolher outro.
    const row_h: f32 = 34;
    const rows: usize = sons.Variant.builtin_count + @intFromBool(has_file) + 1;
    const at = row_h * @as(f32, @floatFromInt(@min(@backingInt(shown), rows - 1)));
    if (dropdown.beginAt(ctx, box_key, box_r, @max(box_w, 220), row_h * @as(f32, @floatFromInt(rows)), at)) |dd_c| {
        var dd = dd_c;
        defer dd.end();
        for (0..sons.Variant.builtin_count + @intFromBool(has_file)) |k| {
            const v: sons.Variant = @fromBackingInt(@intCast(k));
            const sel = v == shown;
            const ro = dd.row(row_h, sel);
            qa.mark(ro.rect, "som-opt:{s}:{d}", .{ key, k });
            if (ro.hit.clicked) {
                variant.* = @intCast(k);
                dropdown.close();
                // Escolheu um som: ouve na hora, como num celular.
                if (v != .off) {
                    voz_audio.apply(s);
                    voz_audio.preview(e);
                }
            }
            var nb: [160]u8 = undefined;
            const name = if (v == .custom) i18n.fmt(&nb, "Arquivo: {s}", "File: {s}", .{sons.displayName(e, file.slice())}) else variantLabel(v);
            _ = d.textClipped(dd.dl, p.font(if (sel) .semibold else .regular), 14, ro.rect.x + 8, d.centerY(ro.rect, 14), if (sel) ctx.col(.text) else ctx.col(.muted), name, ro.rect.w - 16);
        }
        const ro = dd.row(row_h, false);
        qa.mark(ro.rect, "som-arquivo:{s}", .{key});
        if (ro.hit.clicked) {
            dropdown.close();
            picking = e;
            pick_cancelled.store(false, .release);
            ctx.act(.pick_sound);
        }
        _ = d.textClipped(dd.dl, p.font(.regular), 14, ro.rect.x + 8, d.centerY(ro.rect, 14), ctx.col(.accent), if (has_file) i18n.tr("Escolher outro arquivo…", "Choose another file…") else i18n.tr("Escolher arquivo…", "Choose a file…"), ro.rect.w - 16);
    }
}

/// Volume do som (0..200%, 100 no meio = como foi gerado ou gravado).
fn soundVolume(p: anytype, y: f32, i: usize, value: *u8, audible: bool) void {
    const ctx = p.ctx;
    var buf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}%", .{value.*}) catch "";
    const tw = d.width(p.font(.semibold), 13, txt);
    const tr: d.Rect = .{ .x = p.x + 6, .y = y + 10, .w = @max(p.w - 70, 40), .h = 6 };
    const hr: d.Rect = .{ .x = tr.x - 6, .y = tr.y - 10, .w = tr.w + 12, .h = 26 };
    const hb = d.hit(ctx, base_id + 0x180 + i, hr);
    qa.mark(hr, "som-vol:{s}", .{@tagName(@as(sons.Event, @fromBackingInt(@intCast(i))))});
    if (hb.held) value.* = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1) * 200));
    const k = @as(f32, @floatFromInt(@min(value.*, 200))) / 200;
    const fill = if (audible) ctx.col(.accent) else ctx.col(.faint);
    d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 3);
    d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, fill, 3);
    d.line(p.dl, tr.x + tr.w / 2, tr.y - 3, tr.x + tr.w / 2, tr.bottom() + 3, ctx.col(.faint), 1);
    // A sombra e a borda separam a alça do fundo nos temas claros.
    const knob: d.Rect = .{ .x = tr.x + tr.w * k - 5, .y = tr.y - 7, .w = 10, .h = 20 };
    d.shadow(p.dl, knob, 3, 4, ctx.col(.shadow));
    d.rect(p.dl, knob, d.Rgba.white, 3);
    d.border(p.dl, knob, ctx.col(.border), 3, 1);
    d.text(p.dl, p.font(.semibold), 13, p.x + p.w - tw, tr.y - 5, if (audible) ctx.col(.muted) else ctx.col(.faint), txt);
}

/// O seletor do sistema devolveu um arquivo: é o som esperado? Confere,
/// copia e escolhe; recusado, diz o porquê. true = o arquivo era daqui.
pub fn takePicked(st: anytype, now_ms: i64, path: [:0]const u8) bool {
    const e = picking orelse return false;
    picking = null;
    const s = &st.settings;
    var name: S.Text = .{};
    voz_audio.importSound(e, path, S.soundFile(s, e).slice(), &name) catch |err| {
        const max_s = e.maxMs() / 1000;
        switch (err) {
            error.TooBig => st.showToast(now_ms, true, "o arquivo passa de 2 MB", "the file is over 2 MB", .{}),
            error.TooLong => st.showToast(now_ms, true, "o som passa de {d} s", "the sound is longer than {d} s", .{max_s}),
            error.Unsupported => st.showToast(now_ms, true, "use WAV (PCM) ou Ogg Opus", "use WAV (PCM) or Ogg Opus", .{}),
            error.Corrupt => st.showToast(now_ms, true, "o arquivo está estragado ou incompleto", "the file is damaged or incomplete", .{}),
            error.Empty => st.showToast(now_ms, true, "o arquivo não tem som", "the file has no sound", .{}),
            error.Read => st.showToast(now_ms, true, "não consegui ler o arquivo", "couldn't read the file", .{}),
            error.Write => st.showToast(now_ms, true, "não consegui copiar o arquivo para a pasta do larperCord", "couldn't copy the file into larperCord's folder", .{}),
            error.OutOfMemory => st.showToast(now_ms, true, "sem memória para abrir o som", "out of memory opening the sound", .{}),
        }
        return true;
    };
    S.soundFile(s, e).* = name;
    S.soundVariant(s, e).* = @backingInt(sons.Variant.custom);
    st.showToast(now_ms, false, "som trocado: {s}", "sound changed: {s}", .{sons.displayName(e, name.slice())});
    return true;
}

/// O seletor fechou sem arquivo (chamado da thread do diálogo).
pub fn cancelPick() void {
    pick_cancelled.store(true, .release);
}

/// A cada volta do laço: o seletor cancelado não deixa o próximo arquivo
/// (um anexo) virar som.
pub fn pollCancel() void {
    if (pick_cancelled.swap(false, .acq_rel)) picking = null;
}

// --- Dispositivos -----------------------------------------------------------

/// Caixa com o dispositivo atual; clicar abre a lista por cima da página, sem
/// empurrar nada. Devolve onde a coluna terminou.
fn picker(p: anytype, x: f32, wd: f32, y0: f32, which: u8, label: []const u8, comptime tag: []const u8, list: *const voz_audio.DeviceList, value: *S.Text, fallback: bool) f32 {
    const ctx = p.ctx;
    var y = y0;
    d.text(p.dl, p.font(.bold), 12, x, y, ctx.col(.muted), label);
    y += 20;
    const default_label = i18n.tr("Padrão do sistema", "System default");
    const saved = value.slice();
    const r: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 42 };
    const key = base_id + which;
    const hb = d.hit(ctx, key, r);
    qa.mark(r, tag, .{});
    if (hb.clicked) dropdown.toggle(key);
    const opened = dropdown.isOpen(key);
    d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, r, if (hb.hovered or opened) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
    _ = d.textClipped(p.dl, p.font(.medium), 15, r.x + 12, d.centerY(r, 15), ctx.col(.text), if (saved.len > 0) saved else default_label, r.w - 44);
    icons.chevron(p.dl, r.right() - 20, r.y + 21, ctx.col(.muted).u(), if (opened) 0 else 1);
    y += 46;
    // O escolhido não está ligado agora: o nome fica guardado para quando voltar.
    if (fallback and saved.len > 0) {
        qa.mark(.{ .x = x, .y = y, .w = wd, .h = 22 }, tag ++ "-sumiu", .{});
        y += inbox.wrapFlow(p.dl, p.font(.regular), 13, x, y, wd, i18n.tr("Não encontrado: usando o padrão até ele voltar.", "Not found: using the default until it comes back."), ctx.col(.idle), 22);
    }
    y += 6;
    const row_h: f32 = 34;
    const rows = 1 + @as(usize, list.n);
    var at: f32 = 0;
    for (0..rows) |i| if (i > 0 and std.mem.eql(u8, saved, list.slice(i - 1))) {
        at = row_h * @as(f32, @floatFromInt(i));
    };
    if (dropdown.beginAt(ctx, key, r, wd, row_h * @as(f32, @floatFromInt(rows)), at)) |dd_c| {
        var dd = dd_c;
        defer dd.end();
        for (0..rows) |i| {
            const name = if (i == 0) default_label else list.slice(i - 1);
            const sel = if (i == 0) saved.len == 0 else std.mem.eql(u8, saved, name);
            const ro = dd.row(row_h, sel);
            qa.mark(ro.rect, tag ++ "-opt:{d}", .{i});
            if (ro.hit.clicked) {
                if (i == 0) value.* = .{} else value.set(name);
                dropdown.close();
            }
            _ = d.textClipped(dd.dl, p.font(if (sel) .semibold else .regular), 14, ro.rect.x + 8, d.centerY(ro.rect, 14), if (sel) ctx.col(.text) else ctx.col(.muted), name, ro.rect.w - 16);
        }
    }
    return y;
}

/// Lista de mentira para o QA ver a rolagem e a virada para cima (o driver mudo
/// só tem um dispositivo).
var qa_mic_saved: voz_audio.DeviceList = .{};
pub fn qaManyDevices(n: u8) void {
    if (!qa.compiled) return;
    if (n == 0) {
        mic_list = qa_mic_saved;
        return;
    }
    qa_mic_saved = mic_list;
    mic_list.n = @min(n, mic_list.names.len);
    for (0..mic_list.n) |i| {
        var b: [32]u8 = undefined;
        mic_list.names[i].set(std.fmt.bufPrint(&b, "Microfone de teste {d}", .{i + 1}) catch "");
    }
}

// --- Volume -----------------------------------------------------------------

fn volume(p: anytype, x: f32, wd: f32, y: f32, id: usize, label: []const u8, value: *u8) void {
    const ctx = p.ctx;
    d.text(p.dl, p.font(.medium), 15, x, y, ctx.col(.text), label);
    var buf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}%", .{value.*}) catch "";
    d.text(p.dl, p.font(.semibold), 14, x + wd - d.width(p.font(.semibold), 14, txt), y + 1, ctx.col(.muted), txt);
    const tr: d.Rect = .{ .x = x + 6, .y = y + 34, .w = wd - 12, .h = 8 };
    const hr: d.Rect = .{ .x = tr.x - 8, .y = tr.y - 10, .w = tr.w + 16, .h = 28 };
    const hb = d.hit(ctx, base_id + id, hr);
    qa.mark(hr, "voz-vol:{d}", .{id});
    if (hb.held) value.* = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1) * 200));
    const k = @as(f32, @floatFromInt(@min(value.*, 200))) / 200;
    d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
    d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, ctx.col(.accent), 4);
    // 100% = sem mudança.
    d.line(p.dl, tr.x + tr.w / 2, tr.y - 3, tr.x + tr.w / 2, tr.bottom() + 3, ctx.col(.faint), 1);
    const kx = tr.x + tr.w * k;
    d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 8, .w = 12, .h = 24 }, d.Rgba.white, 3);
}

// --- Modo de entrada --------------------------------------------------------

fn mode(p: anytype, ptt: *bool) void {
    const labels = [_][]const u8{ i18n.tr("Detecção de voz", "Voice activity"), i18n.tr("Aperte para falar", "Push to talk") };
    if (segments(p, &labels, "voz-modo", 20, @intFromBool(ptt.*))) |i| ptt.* = i == 1;
}

/// Supressão de ruído: uma escolha entre motores, na ordem de `ruido.Mode`.
fn denoise(p: anytype, value: *u8) void {
    const ctx = p.ctx;
    d.text(p.dl, p.font(.medium), 16, p.x, p.y, ctx.col(.text), i18n.tr("Supressão de ruído", "Noise suppression"));
    p.y += 28;
    const labels = [_][]const u8{ i18n.tr("Desligada", "Off"), "RNNoise" };
    if (segments(p, &labels, "voz-ruido", 30, @intFromEnum(ruido.Mode.fromByte(value.*)))) |i| value.* = @intCast(i);
    p.y -= 8;
    p.note(i18n.tr("Rede neural pequena que roda neste computador, sem internet. Ouça o efeito em Testar microfone.", "A small neural network that runs on this computer, no internet. Hear it with Test microphone."));
    p.note(i18n.tr("Reduz ruído constante: ventilador, chiado, ar-condicionado. Atrasa o microfone em 20 ms.", "Reduces steady noise: fans, hiss, air conditioning. Delays your mic by 20 ms."));
    p.note(i18n.tr("Teclado e pancadas podem passar, outras vozes ficam e a sua pode abafar um pouco.", "Typing and bangs may get through, other voices stay and yours may get a bit muffled."));
    p.y += 4;
}

/// Botões lado a lado, um escolhido. Devolve o que foi clicado.
fn segments(p: anytype, labels: []const []const u8, comptime tag: []const u8, id: usize, selected: usize) ?usize {
    const ctx = p.ctx;
    const gap: f32 = 8;
    const count: f32 = @floatFromInt(labels.len);
    const bw = (p.w - gap * (count - 1)) / count;
    var clicked: ?usize = null;
    for (labels, 0..) |lb, i| {
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y, .w = bw, .h = 42 };
        const hb = d.hit(ctx, base_id + id + i, r);
        qa.mark(r, tag ++ ":{d}", .{i});
        if (hb.clicked) clicked = i;
        const sel = selected == i;
        d.rect(p.dl, r, if (sel) ctx.col(.accent).alpha(0.22) else if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.6), ctx.th.radius + 2);
        d.border(p.dl, r, if (sel) ctx.col(.accent) else ctx.col(.border), ctx.th.radius + 2, if (sel) 2 else 1);
        const tw = d.width(p.font(.semibold), 15, lb);
        d.text(p.dl, p.font(.semibold), 15, r.x + (r.w - tw) / 2, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), lb);
    }
    p.y += 56;
    return clicked;
}

fn pushToTalk(p: anytype, key: *S.Text) void {
    const ctx = p.ctx;
    if (voz_audio.takeCaptured()) |b| {
        var buf: [16]u8 = undefined;
        key.set(b.format(&buf));
    }
    const capturing = voz_audio.isCapturing();
    const binding = voz.Binding.parse(key.slice());
    d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), i18n.tr("ATALHO", "SHORTCUT"));
    p.y += 20;
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 42 };
    // 30 e 31 são os botões do supressor de ruído, logo abaixo: com o mesmo número, o
    // "Desligado" não respondia enquanto o atalho estava na tela (#35).
    const hb = d.hit(ctx, base_id + 50, r);
    qa.mark(r, "voz-atalho", .{});
    if (hb.clicked) {
        if (capturing) voz_audio.cancelCapture() else voz_audio.startCapture();
    }
    d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, r, if (capturing) ctx.col(.accent) else if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, if (capturing) 2 else 1);
    var nb: [48]u8 = undefined;
    const shown = if (capturing)
        i18n.tr("Aperte uma tecla ou um botão do mouse… (Esc cancela)", "Press a key or a mouse button… (Esc cancels)")
    else if (binding == .none)
        i18n.tr("Nenhum: clique para escolher", "None: click to choose")
    else
        channels_ui.bindingName(&nb, binding);
    d.text(p.dl, p.font(if (binding == .none or capturing) .regular else .semibold), 15, r.x + 12, d.centerY(r, 15), if (capturing) ctx.col(.accent) else if (binding == .none) ctx.col(.muted) else ctx.col(.text), shown);
    if (!capturing and binding != .none) {
        const hint = i18n.tr("clique para trocar", "click to change");
        d.text(p.dl, p.font(.regular), 13, r.right() - 12 - d.width(p.font(.regular), 13, hint), d.centerY(r, 13), ctx.col(.faint), hint);
    }
    p.y += 50;
    if (!ptt_global.supported) {
        p.note(i18n.tr("Só funciona com a janela do larperCord em foco: fora dela o programa não vê a tecla.", "Only works while the larperCord window is focused: outside it the app can't see the key."));
    } else if (binding != .none and !capturing) {
        // No Windows, só as teclas que dá para ler de fora (platform/ptt_global.zig).
        p.note(if (ptt_global.vkOf(binding) != 0)
            i18n.tr("Funciona também com outra janela em foco, e o outro programa continua recebendo a tecla.", "Also works while another window is focused, and that app still gets the key.")
        else
            i18n.tr("Esta tecla só funciona com a janela do larperCord em foco. Para usar com outra janela em foco, escolha outra, como uma letra, F13 a F24 ou um botão lateral do mouse.", "This key only works while the larperCord window is focused. To use it while another window is focused, pick another one, like a letter, F13 to F24 or a side mouse button."));
    }
    p.note(i18n.tr("O envio segue por um instante depois de soltar, para não cortar a última palavra.", "Sending continues for a moment after you release, so the last word isn't cut."));
}

// --- Medidor ----------------------------------------------------------------

/// O nível ao vivo sobre a barra de sensibilidade (como no Discord): à direita
/// do limiar, em verde, é o que abre o microfone.
fn meter(p: anytype, s: *S.Settings) void {
    const ctx = p.ctx;
    const sh = &voz_audio.sh;
    const failed = sh.mic_failed.load(.monotonic);
    const db = sh.level_db.load(.monotonic);
    const uses_threshold = !s.voice_ptt;
    const th_db: f32 = if (s.voice_auto) sh.shown_threshold_db.load(.monotonic) else voz.sensToDb(s.voice_sens);
    const tr: d.Rect = .{ .x = p.x + 6, .y = p.y + 6, .w = p.w - 12, .h = 14 };
    const hr: d.Rect = .{ .x = tr.x - 6, .y = tr.y - 8, .w = tr.w + 12, .h = 30 };
    const hb = d.hit(ctx, base_id + 40, hr);
    qa.mark(hr, "voz-sens", .{});
    if (uses_threshold and !s.voice_auto and hb.held)
        s.voice_sens = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1) * 100));
    d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
    const level_k = voz.dbToPos(db);
    const th_k = voz.dbToPos(th_db);
    if (!failed and level_k > 0) {
        if (uses_threshold) {
            const below = @min(level_k, th_k);
            if (below > 0) d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * below, .h = tr.h }, ctx.col(.idle), 4);
            if (level_k > th_k) d.rect(p.dl, .{ .x = tr.x + tr.w * th_k, .y = tr.y, .w = tr.w * (level_k - th_k), .h = tr.h }, ctx.col(.online), 4);
        } else d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * level_k, .h = tr.h }, ctx.col(.online), 4);
    }
    if (uses_threshold) {
        const kx = tr.x + tr.w * th_k;
        // Automático: o limiar anda sozinho, então a marca é só informação.
        if (s.voice_auto) {
            d.rect(p.dl, .{ .x = kx - 1.5, .y = tr.y - 4, .w = 3, .h = tr.h + 8 }, ctx.col(.text).alpha(0.7), 1);
        } else {
            d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 6, .w = 12, .h = tr.h + 12 }, d.Rgba.white, 3);
        }
    }
    p.y += 32;
    var buf: [120]u8 = undefined;
    const info = if (failed)
        i18n.tr("O microfone não abriu. Confira o dispositivo acima e a permissão do sistema.", "The microphone didn't open. Check the device above and the system permission.")
    else if (db <= voz.db_silence)
        i18n.tr("Sem som no microfone.", "No sound from the microphone.")
    else if (!uses_threshold)
        i18n.fmt(&buf, "Nível: {d:.0} dB", "Level: {d:.0} dB", .{db})
    else if (s.voice_auto)
        i18n.fmt(&buf, "Nível: {d:.0} dB · limiar aprendido: {d:.0} dB", "Level: {d:.0} dB · learned threshold: {d:.0} dB", .{ db, th_db })
    else
        i18n.fmt(&buf, "Nível: {d:.0} dB · limiar: {d:.0} dB (arraste a marca)", "Level: {d:.0} dB · threshold: {d:.0} dB (drag the handle)", .{ db, th_db });
    if (failed) qa.mark(.{ .x = p.x, .y = p.y, .w = p.w, .h = 22 }, "voz-mic-falhou", .{});
    _ = d.textClipped(p.dl, p.font(.regular), 13, p.x, p.y, if (failed) ctx.col(.danger) else ctx.col(.muted), info, p.w);
    p.y += 28;
}

fn micTest(p: anytype) void {
    const ctx = p.ctx;
    const sh = &voz_audio.sh;
    const on = sh.test_on.load(.acquire);
    // O rótulo em português é a marca do QA.
    if (p.button(if (on) i18n.tr("Parar teste", "Stop test") else i18n.tr("Testar microfone", "Test microphone"), on)) sh.test_on.store(!on, .release);
    p.y += 2;
    p.y += inbox.wrapFlow(p.dl, p.font(.regular), 13, p.x, p.y, p.w, i18n.tr("Toca de volta o que você fala, com os filtros. Use fones para não dar microfonia.", "Plays back what you say, with the filters. Use headphones to avoid feedback."), ctx.col(.faint), 26);
}
