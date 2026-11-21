//! Tipos e lógica pura para vídeo 4K, compartilhamento de tela (Go Live) e
//! controle remoto estilo AnyDesk — sem dependências de SDL nem de rede.
const std = @import("std");

pub const Resolution = enum(u8) {
    p720 = 0,
    p1080 = 1,
    p1440 = 2,
    p2160 = 3,
    p480 = 4,

    pub fn dims(r: Resolution) [2]u32 {
        return switch (r) {
            .p480 => .{ 854, 480 },
            .p720 => .{ 1280, 720 },
            .p1080 => .{ 1920, 1080 },
            .p1440 => .{ 2560, 1440 },
            .p2160 => .{ 3840, 2160 },
        };
    }

    pub fn label(r: Resolution) []const u8 {
        return switch (r) {
            .p480 => "480p",
            .p720 => "720p",
            .p1080 => "1080p",
            .p1440 => "1440p",
            .p2160 => "4K (2160p)",
        };
    }

    pub fn defaultBitrateKbps(r: Resolution, fps: u8) u32 {
        const hi = fps >= 50;
        return switch (r) {
            .p480 => if (hi) 1800 else 1000,
            .p720 => if (hi) 3500 else 2200,
            .p1080 => if (hi) 6500 else 4000,
            .p1440 => if (hi) 8500 else 6000,
            .p2160 => if (hi) 11000 else 8000,
        };
    }

    pub fn fromByte(b: u8) Resolution {
        return std.enums.fromInt(Resolution, b) orelse .p2160;
    }
};

pub const Codec = enum(u8) {
    auto = 0,
    h264 = 1,
    hevc = 2,
    av1 = 3,
    vp8 = 4,
    vp9 = 5,

    pub fn label(c: Codec) []const u8 {
        return switch (c) {
            .auto => "Auto (GPU)",
            .h264 => "H.264",
            .hevc => "HEVC (H.265)",
            .av1 => "AV1",
            .vp8 => "VP8",
            .vp9 => "VP9",
        };
    }

    /// Payload type padrão usado na negociação do Discord (Select Protocol).
    pub fn rtpPayloadType(c: Codec) u7 {
        return switch (c) {
            .auto, .h264 => 101,
            .vp8 => 103,
            .vp9 => 105,
            .hevc => 107,
            .av1 => 109,
        };
    }

    pub fn rtxPayloadType(c: Codec) u7 {
        return c.rtpPayloadType() + 1;
    }

    pub fn name(c: Codec) []const u8 {
        return switch (c) {
            .auto, .h264 => "H264",
            .hevc => "H265",
            .av1 => "AV1",
            .vp8 => "VP8",
            .vp9 => "VP9",
        };
    }

    pub fn fromByte(b: u8) Codec {
        return std.enums.fromInt(Codec, b) orelse .auto;
    }
};

pub const SourceKind = enum(u8) {
    screen = 0,
    window = 1,
    camera = 2,
    demo_4k = 3,
};

pub const TransportMode = enum(u8) {
    discord_sfu = 0,
    p2p_direct = 1,
};

pub const RemotePerm = enum(u8) {
    off = 0,
    mouse_only = 1,
    full = 2,
};

pub const PerfPreset = enum(u8) {
    speed = 0,
    balanced = 1,
    quality = 2,

    pub fn fromByte(b: u8) PerfPreset {
        return std.enums.fromInt(PerfPreset, b) orelse .balanced;
    }

    pub fn qualityVsSpeed(p: PerfPreset) u32 {
        return switch (p) {
            .speed => 15,
            .balanced => 55,
            .quality => 85,
        };
    }
};

pub const CaptureBackend = enum(u8) {
    auto = 0,
    dxgi = 1,
    wgc = 2,

    pub fn fromByte(b: u8) CaptureBackend {
        return std.enums.fromInt(CaptureBackend, b) orelse .auto;
    }
};

pub fn camResolution(idx: u8, stream_res: Resolution) Resolution {
    return switch (idx) {
        0 => .p480,
        1 => .p720,
        2 => .p1080,
        else => stream_res,
    };
}

pub fn camFpsValue(idx: u8) u8 {
    return switch (idx) {
        0 => 15,
        2 => 60,
        else => 30,
    };
}

pub fn staticRefreshMs(idx: u8) i64 {
    return switch (idx) {
        0 => 500, // 2 fps
        2 => 100, // 10 fps
        else => 250, // 4 fps
    };
}

pub const StreamConfig = struct {
    kind: SourceKind = .screen,
    /// DisplayID, HWND/window handle ou CameraID.
    target_id: u64 = 0,
    resolution: Resolution = .p2160,
    fps: u8 = 60,
    codec: Codec = .auto,
    bitrate_kbps: u32 = 20_000,
    share_audio: bool = true,
    capture_cursor: bool = true,
    preview_self: bool = true,
    remote_perm: RemotePerm = .off,
    transport: TransportMode = .discord_sfu,
    hw_accel: bool = true,
    perf_preset: PerfPreset = .balanced,
    capture_backend: CaptureBackend = .auto,
    static_refresh_ms: i64 = 250,
    keyframe_sec: u8 = 2,
};

pub const StreamMetrics = struct {
    active: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    /// FPS multiplicado por 10 (600 = 60.0 fps).
    fps_x10: u16 = 0,
    bitrate_kbps: u32 = 0,
    decode_us: u32 = 0,
    encode_us: u32 = 0,
    ram_bytes: usize = 0,
    hw_accel: bool = false,
    codec: Codec = .h264,
    rtt_ms: u16 = 0,
    is_p2p: bool = false,
};

/// Bytes exatos de um plano NV12 (Y + UV intercalado, 1.5 bytes/pixel).
/// Nunca usa RGBA (4 bytes/pixel) para economizar 62.5% de RAM em 4K.
pub fn nv12ByteSize(w: u32, h: u32) usize {
    const wy: usize = @as(usize, w) * @as(usize, h);
    const uv_h: usize = (@as(usize, h) + 1) / 2;
    const uv_w: usize = ((@as(usize, w) + 1) / 2) * 2;
    return wy + uv_w * uv_h;
}

/// Converte posição do mouse sobre o retângulo de vídeo (com letterbox) em
/// coordenadas normalizadas `[0..65535]` para injeção precisa no host 4K.
pub fn mapViewportToNormalized(
    mouse_x: f32,
    mouse_y: f32,
    box_x: f32,
    box_y: f32,
    box_w: f32,
    box_h: f32,
    video_w: u32,
    video_h: u32,
) ?[2]u16 {
    if (box_w <= 1 or box_h <= 1 or video_w == 0 or video_h == 0) return null;
    const vw: f32 = @floatFromInt(video_w);
    const vh: f32 = @floatFromInt(video_h);
    const scale = @min(box_w / vw, box_h / vh);
    const draw_w = vw * scale;
    const draw_h = vh * scale;
    const ox = box_x + (box_w - draw_w) * 0.5;
    const oy = box_y + (box_h - draw_h) * 0.5;
    const eps: f32 = 0.01;
    if (mouse_x < ox - eps or mouse_x > ox + draw_w + eps or mouse_y < oy - eps or mouse_y > oy + draw_h + eps) return null;
    const nx = std.math.clamp((mouse_x - ox) / draw_w, 0.0, 1.0);
    const ny = std.math.clamp((mouse_y - oy) / draw_h, 0.0, 1.0);
    return .{
        @intFromFloat(@round(nx * 65535.0)),
        @intFromFloat(@round(ny * 65535.0)),
    };
}

// ---------------------------------------------------------------------------
// Protocolo compacto (16 bytes) para controle remoto estilo AnyDesk
// ---------------------------------------------------------------------------

pub const RemoteInputKind = enum(u8) {
    mouse_move = 1,
    mouse_btn = 2,
    mouse_wheel = 3,
    key = 4,
    release_all = 5,
    ping = 6,
    pong = 7,
};

pub const RemoteInputPacket = struct {
    kind: RemoteInputKind,
    /// `mouse_btn`: 1=left, 2=middle, 3=right, 4=x1, 5=x2.
    /// `key`: SDL_Scancode (ou Win32 scancode flags).
    code: u16 = 0,
    /// `mouse_btn` / `key`: 1 = down, 0 = up.
    pressed: bool = false,
    /// Coordenadas normalizadas `[0..65535]` ou delta do scroll (i16 bitcast).
    x: u16 = 0,
    y: u16 = 0,
    seq: u32 = 0,

    pub const wire_len = 12;

    pub fn encode(p: RemoteInputPacket, out: *[wire_len]u8) void {
        out[0] = @intFromEnum(p.kind);
        out[1] = @intFromBool(p.pressed);
        std.mem.writeInt(u16, out[2..4], p.code, .little);
        std.mem.writeInt(u16, out[4..6], p.x, .little);
        std.mem.writeInt(u16, out[6..8], p.y, .little);
        std.mem.writeInt(u32, out[8..12], p.seq, .little);
    }

    pub fn decode(raw: []const u8) ?RemoteInputPacket {
        if (raw.len < wire_len) return null;
        const kind = std.enums.fromInt(RemoteInputKind, raw[0]) orelse return null;
        return .{
            .kind = kind,
            .pressed = raw[1] != 0,
            .code = std.mem.readInt(u16, raw[2..4], .little),
            .x = std.mem.readInt(u16, raw[4..6], .little),
            .y = std.mem.readInt(u16, raw[6..8], .little),
            .seq = std.mem.readInt(u32, raw[8..12], .little),
        };
    }
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const t = std.testing;

test "NV12 4K usa ~11.87 MiB (62.5% menor que RGBA)" {
    const dims = Resolution.p2160.dims();
    try t.expectEqual(@as(u32, 3840), dims[0]);
    try t.expectEqual(@as(u32, 2160), dims[1]);
    const nv12 = nv12ByteSize(dims[0], dims[1]);
    const rgba: usize = @as(usize, dims[0]) * dims[1] * 4;
    try t.expectEqual(@as(usize, 12_441_600), nv12);
    try t.expect(nv12 * 2 < rgba);
}

test "mapeamento normalizado respeita letterbox e limites" {
    // Vídeo 16:9 (3840x2160) dentro de caixa quadrada 1000x1000 -> draw_w=1000, draw_h=562.5, oy=218.75.
    try t.expect(mapViewportToNormalized(500, 100, 0, 0, 1000, 1000, 3840, 2160) == null);
    const center = mapViewportToNormalized(500, 500, 0, 0, 1000, 1000, 3840, 2160).?;
    try t.expectApproxEqAbs(@as(f32, 32767.5), @as(f32, @floatFromInt(center[0])), 1.0);
    try t.expectApproxEqAbs(@as(f32, 32767.5), @as(f32, @floatFromInt(center[1])), 1.0);
    const top_left = mapViewportToNormalized(0, 218.75, 0, 0, 1000, 1000, 3840, 2160).?;
    try t.expectEqual(@as(u16, 0), top_left[0]);
    try t.expectEqual(@as(u16, 0), top_left[1]);
}

test "pacote de controle remoto vai e volta sem perda" {
    const p: RemoteInputPacket = .{
        .kind = .mouse_btn,
        .code = 1,
        .pressed = true,
        .x = 42123,
        .y = 61000,
        .seq = 987654,
    };
    var buf: [RemoteInputPacket.wire_len]u8 = undefined;
    p.encode(&buf);
    const out = RemoteInputPacket.decode(&buf).?;
    try t.expectEqual(p.kind, out.kind);
    try t.expectEqual(p.code, out.code);
    try t.expectEqual(p.pressed, out.pressed);
    try t.expectEqual(p.x, out.x);
    try t.expectEqual(p.y, out.y);
    try t.expectEqual(p.seq, out.seq);
    try t.expect(RemoteInputPacket.decode(buf[0..5]) == null);
}
