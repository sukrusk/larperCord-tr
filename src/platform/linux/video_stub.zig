//! Stubs das interfaces de vídeo/áudio do Linux (PipeWire + xdg-desktop-portal + VAAPI)
//! mantendo o limite de plataforma limpo sem depender de headers de sistema no build do Windows.
const media_if = @import("../media_if.zig");
const video_cfg = @import("../../core/video_cfg.zig");

pub fn enumerateDisplays(out: []media_if.DisplayTarget) usize {
    _ = out;
    return 0;
}

pub fn enumerateWindows(out: []media_if.WindowTarget) usize {
    _ = out;
    return 0;
}

pub fn probeCapabilities() media_if.HwCapability {
    return .{};
}

pub const Duplicator = struct {
    pub fn open(display_id: u64, target_res: video_cfg.Resolution) !Duplicator {
        _ = display_id;
        _ = target_res;
        return error.NotImplementedOnLinuxYet;
    }

    pub fn acquireNv12(self: *Duplicator, timeout_ms: u32) !?media_if.CaptureFrame {
        _ = self;
        _ = timeout_ms;
        return null;
    }

    pub fn deinit(self: *Duplicator) void {
        _ = self;
    }
};

pub const Loopback = struct {
    is_process_isolated: bool = false,
    pub fn open() !Loopback {
        return error.NotImplementedOnLinuxYet;
    }

    pub fn openSmart(target_pid: u32, include_only_target: bool) !Loopback {
        _ = .{ target_pid, include_only_target };
        return error.NotImplementedOnLinuxYet;
    }

    pub fn readPcm(self: *Loopback, out_interleaved: []f32) usize {
        _ = self;
        _ = out_interleaved;
        return 0;
    }

    pub fn deinit(self: *Loopback) void {
        _ = self;
    }
};

pub const HwEncoder = struct {
    hw: bool = false,
    force_cpu_buf: bool = true,
    last_hr: u32 = 0,
    pub fn open(codec: video_cfg.Codec, w: u16, h: u16, fps: u8, bitrate_kbps: u32, d3d11_dev: ?*anyopaque) !HwEncoder {
        _ = .{ codec, w, h, fps, bitrate_kbps, d3d11_dev };
        return error.NotImplementedOnLinuxYet;
    }
    pub fn requestKeyframe(self: *HwEncoder) void {
        _ = self;
    }
    pub fn setBitrate(self: *HwEncoder, bitrate_kbps: u32) void {
        _ = .{ self, bitrate_kbps };
    }
    pub fn encode(self: *HwEncoder, frame: media_if.CaptureFrame) !?media_if.EncodedPacket {
        _ = .{ self, frame };
        return null;
    }
    pub fn pollOutput(self: *HwEncoder, pts_us: i64) ?media_if.EncodedPacket {
        _ = .{ self, pts_us };
        return null;
    }
    pub fn deinit(self: *HwEncoder) void {
        _ = self;
    }
};

pub const HwDecoder = struct {
    hw: bool = false,
    last_hr: u32 = 0,
    pub fn open(codec: video_cfg.Codec, w: u16, h: u16, d3d11_dev: ?*anyopaque) !HwDecoder {
        _ = .{ codec, w, h, d3d11_dev };
        return error.NotImplementedOnLinuxYet;
    }
    pub fn decode(self: *HwDecoder, au: []const u8, pts_us: i64) !?media_if.CaptureFrame {
        _ = .{ self, au, pts_us };
        return null;
    }
    pub fn deinit(self: *HwDecoder) void {
        _ = self;
    }
};
