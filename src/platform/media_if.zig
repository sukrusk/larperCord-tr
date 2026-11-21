//! Interface comum de captura de tela/janela, codec GPU e loopback de áudio
//! entre Windows (`src/platform/win/`) e Linux (`src/platform/linux/`).
const std = @import("std");
const video_cfg = @import("../core/video_cfg.zig");

pub const DisplayTarget = struct {
    adapter_idx: u16 = 0,
    output_idx: u16 = 0,
    id: u64 = 0,
    hmonitor: u64 = 0,
    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    refresh_hz: u16 = 60,
    primary: bool = false,

    pub fn nameSlice(self: *const DisplayTarget) []const u8 {
        return self.name_buf[0..@min(self.name_len, self.name_buf.len)];
    }
};

pub const WindowTarget = struct {
    handle: u64 = 0,
    pid: u32 = 0,
    exe_buf: [32]u8 = @splat(0),
    exe_len: u8 = 0,
    title_buf: [128]u8 = @splat(0),
    title_len: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn titleSlice(self: *const WindowTarget) []const u8 {
        return self.title_buf[0..@min(self.title_len, self.title_buf.len)];
    }

    pub fn exeSlice(self: *const WindowTarget) []const u8 {
        return self.exe_buf[0..@min(self.exe_len, self.exe_buf.len)];
    }
};

pub const CaptureFrame = struct {
    width: u16 = 0,
    height: u16 = 0,
    /// Textura NV12 em VRAM (`*ID3D11Texture2D` no Windows) para zero-copy no encoder.
    gpu_tex: ?*anyopaque = null,
    /// Plano NV12 contíguo em CPU quando a captura cai em modo staging.
    nv12_y: []const u8 = &.{},
    nv12_uv: []const u8 = &.{},
    y_pitch: u32 = 0,
    uv_pitch: u32 = 0,
    pts_us: i64 = 0,
};

pub const EncodedPacket = struct {
    data: []const u8,
    pts_us: i64,
    is_keyframe: bool,
    codec: video_cfg.Codec,
};

pub const HwCapability = struct {
    h264_enc: bool = false,
    hevc_enc: bool = false,
    av1_enc: bool = false,
    h264_dec: bool = false,
    hevc_dec: bool = false,
    av1_dec: bool = false,
    vp8_dec: bool = false,
    vp9_dec: bool = false,
    zero_copy_d3d11: bool = false,
};
