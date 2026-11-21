//! Gerenciamento de quadros de vídeo ao vivo com foco absoluto em RAM mínima:
//! - 0 bytes alocados em repouso (sem pre-alocar câmera, texturas ou buffers).
//! - Slot único NV12 (1.5 byte/px: ~11.87 MiB em 4K vs ~31.6 MiB por quadro RGBA).
//! - Alocação via `page_allocator` (`VirtualFree` imediato no encerramento).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const fx = @import("fx.zig");
const video_cfg = @import("../core/video_cfg.zig");
const nv12_pattern = @import("../core/nv12_pattern.zig");
const capture_backend = @import("../platform/capture_backend.zig");
const media_if = @import("../platform/media_if.zig");
const sys = @import("../platform/sys.zig");
const video_diag = @import("../platform/video_diag.zig");

pub var eng: Engine = .{};

pub const CamDevice = struct {
    id: c.SDL_CameraID = 0,
    name_buf: [96]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn slice(self: *const CamDevice) []const u8 {
        return self.name_buf[0..@min(self.name_len, self.name_buf.len)];
    }
};

pub const View = struct {
    ref: c.ImTextureRef,
    w: u16,
    h: u16,
    fps_x10: u16,
    ram_bytes: usize,
    source: video_cfg.SourceKind,
    codec: video_cfg.Codec,
    hw_zero_copy: bool = false,
};

pub const FrameSlot = struct {
    mu: ?*c.SDL_Mutex = null,
    active: bool = false,
    w: u16 = 0,
    h: u16 = 0,
    nv12: []u8 = &.{},
    bg_w: u16 = 0,
    bg_h: u16 = 0,
    generation: u64 = 0,
    tex_gen: u64 = 0,
    tex: ?*c.SDL_Texture = null,
    tex_w: u16 = 0,
    tex_h: u16 = 0,
    fps_x10: u16 = 0,
    fps_window_ms: i64 = 0,
    fps_count: u16 = 0,
    source: video_cfg.SourceKind = .screen,
    codec: video_cfg.Codec = .h264,
    // Gancho Phase 2 para texturas NV12 zero-copy via D3D11/Media Foundation.
    hw_nv12_tex: ?*anyopaque = null,

    fn ensureMutex(s: *FrameSlot) void {
        if (s.mu == null) s.mu = c.SDL_CreateMutex();
    }

    pub fn lock(s: *FrameSlot) void {
        s.ensureMutex();
        if (s.mu) |m| _ = c.SDL_LockMutex(m);
    }

    pub fn unlock(s: *FrameSlot) void {
        if (s.mu) |m| _ = c.SDL_UnlockMutex(m);
    }

    pub fn ramBytes(s: *const FrameSlot) usize {
        return s.nv12.len;
    }

    /// Copia um quadro NV12 planar contínuo ou com stride para o slot único.
    pub fn uploadNv12(
        s: *FrameSlot,
        w: u16,
        h: u16,
        y_src: []const u8,
        y_pitch: u32,
        uv_src: []const u8,
        uv_pitch: u32,
        src_kind: video_cfg.SourceKind,
        codec: video_cfg.Codec,
        now_ms: i64,
    ) void {
        if (w < 2 or h < 2 or (w & 1) != 0 or (h & 1) != 0) return;
        s.lock();
        defer s.unlock();

        const need = video_cfg.nv12ByteSize(w, h);
        if (s.nv12.len != need) {
            nv12_pattern.freeNv12(&s.nv12);
            s.nv12 = nv12_pattern.allocNv12(w, h) catch return;
            s.bg_w = 0;
            s.bg_h = 0;
        }
        const wu: usize = w;
        const hu: usize = h;
        const y_len = wu * hu;
        const dst_y = s.nv12[0..y_len];
        const dst_uv = s.nv12[y_len..need];

        if (y_pitch == wu and y_src.len >= y_len) {
            @memcpy(dst_y, y_src[0..y_len]);
        } else {
            var row: usize = 0;
            while (row < hu) : (row += 1) {
                const so = row * y_pitch;
                if (so + wu > y_src.len) break;
                @memcpy(dst_y[row * wu ..][0..wu], y_src[so..][0..wu]);
            }
        }

        const uv_h = hu / 2;
        if (uv_pitch == wu and uv_src.len >= dst_uv.len) {
            @memcpy(dst_uv, uv_src[0..dst_uv.len]);
        } else {
            var row: usize = 0;
            while (row < uv_h) : (row += 1) {
                const so = row * uv_pitch;
                if (so + wu > uv_src.len) break;
                @memcpy(dst_uv[row * wu ..][0..wu], uv_src[so..][0..wu]);
            }
        }

        s.finishFrameLocked(w, h, src_kind, codec, now_ms);
    }

    fn finishFrameLocked(s: *FrameSlot, w: u16, h: u16, src_kind: video_cfg.SourceKind, codec: video_cfg.Codec, now_ms: i64) void {
        s.active = true;
        s.w = w;
        s.h = h;
        s.source = src_kind;
        s.codec = codec;
        s.generation +%= 1;

        if (s.fps_window_ms == 0) s.fps_window_ms = now_ms;
        s.fps_count +|= 1;
        const dt = now_ms - s.fps_window_ms;
        if (dt >= 500) {
            const num: i64 = @as(i64, s.fps_count) * 10_000;
            s.fps_x10 = @intCast(@min(@divFloor(num, @max(dt, 1)), 2400));
            s.fps_count = 0;
            s.fps_window_ms = now_ms;
        }
    }

    pub fn view(s: *FrameSlot, renderer: *c.SDL_Renderer) ?View {
        s.lock();
        defer s.unlock();

        if (!s.active or s.w < 2 or s.h < 2) return null;
        if (s.tex == null or s.tex_w != s.w or s.tex_h != s.h) {
            if (s.tex) |old| c.SDL_DestroyTexture(old);
            s.tex = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_NV12,
                c.SDL_TEXTUREACCESS_STREAMING,
                s.w,
                s.h,
            );
            if (s.tex) |t| _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
            s.tex_w = s.w;
            s.tex_h = s.h;
            s.tex_gen = 0;
        }
        const tex = s.tex orelse return null;
        if (s.tex_gen != s.generation and s.nv12.len >= video_cfg.nv12ByteSize(s.w, s.h)) {
            const wu: usize = s.w;
            const y_len = wu * s.h;
            _ = c.SDL_UpdateNVTexture(
                tex,
                null,
                s.nv12.ptr,
                @intCast(s.w),
                s.nv12[y_len..].ptr,
                @intCast(s.w),
            );
            s.tex_gen = s.generation;
        }
        return .{
            .ref = fx.refOf(tex),
            .w = s.w,
            .h = s.h,
            .fps_x10 = s.fps_x10,
            .ram_bytes = s.nv12.len,
            .source = s.source,
            .codec = s.codec,
            .hw_zero_copy = s.hw_nv12_tex != null,
        };
    }

    /// Libera imediatamente buffers de CPU e textura GPU (0 bytes).
    pub fn clear(s: *FrameSlot) void {
        s.lock();
        s.active = false;
        s.w = 0;
        s.h = 0;
        s.bg_w = 0;
        s.bg_h = 0;
        s.generation = 0;
        s.tex_gen = 0;
        s.fps_x10 = 0;
        s.fps_window_ms = 0;
        s.fps_count = 0;
        s.hw_nv12_tex = null;
        nv12_pattern.freeNv12(&s.nv12);
        const tex = s.tex;
        s.tex = null;
        s.tex_w = 0;
        s.tex_h = 0;
        s.unlock();
        if (tex) |t| c.SDL_DestroyTexture(t);
    }

    pub fn deinit(s: *FrameSlot) void {
        s.clear();
        if (s.mu) |m| {
            c.SDL_DestroyMutex(m);
            s.mu = null;
        }
    }
};

pub const TxAuFn = *const fn (ctx: ?*anyopaque, codec: video_cfg.Codec, pts_us: i64, is_keyframe: bool, au: []const u8) void;
pub const KeyReqFn = *const fn (ctx: ?*anyopaque) bool;
pub const StreamAudioFn = *const fn (ctx: ?*anyopaque, pcm_f32: []const f32) void;

pub const PeerCam = struct {
    uid: std.atomic.Value(u64) = .init(0),
    slot: FrameSlot = .{},
};

pub const Engine = struct {
    cam_slot: FrameSlot = .{},
    watch_slot: FrameSlot = .{},
    peer_cams: [4]PeerCam = @splat(.{}),

    cam: ?*c.SDL_Camera = null,
    cam_subsys: bool = false,
    cam_denied: bool = false,
    cam_synthetic: bool = false,
    cam_synthetic_frame: u64 = 0,
    cam_last_ms: i64 = 0,
    cam_res: video_cfg.Resolution = .p720,
    cam_fps: u8 = 30,
    cam_perf: video_cfg.PerfPreset = .balanced,
    cam_kf_sec: u8 = 2,
    cam_dev_idx: u8 = 0,
    cam_bitrate_kbps: std.atomic.Value(u32) = .init(2500),
    cam_hw: std.atomic.Value(bool) = .init(true),
    cam_preview_only: std.atomic.Value(bool) = .init(false),
    cam_tx_active_fn: ?*const fn () bool = null,
    stx_active_fn: ?*const fn () bool = null,

    // Codificador e captura de câmera em threads separadas para nunca travar a UI.
    cam_cap_thread: ?*c.SDL_Thread = null,
    cam_cap_stop: std.atomic.Value(bool) = .init(false),
    cam_conv_buf: []u8 = &.{},
    cam_enc_thread: ?*c.SDL_Thread = null,
    cam_enc_mu: ?*c.SDL_Mutex = null,
    cam_enc_cond: ?*c.SDL_Condition = null,
    cam_enc_stop: std.atomic.Value(bool) = .init(false),
    cam_stage_buf: []u8 = &.{},
    cam_stage_w: u16 = 0,
    cam_stage_h: u16 = 0,
    cam_stage_pts_us: i64 = 0,
    cam_stage_ready: bool = false,

    preview_wanted: std.atomic.Value(bool) = .init(true),
    cursor_wanted: std.atomic.Value(bool) = .init(true),
    frame_dirty: std.atomic.Value(bool) = .init(false),
    wake_cb: ?*const fn () void = null,

    tx_mu: ?*c.SDL_Mutex = null,
    cam_tx_cb: ?TxAuFn = null,
    cam_tx_ctx: ?*anyopaque = null,
    cam_key_cb: ?KeyReqFn = null,
    stream_tx_cb: ?TxAuFn = null,
    stream_tx_ctx: ?*anyopaque = null,
    stream_key_cb: ?KeyReqFn = null,
    stream_audio_cb: ?StreamAudioFn = null,

    demo_thread: ?*c.SDL_Thread = null,
    demo_stop: std.atomic.Value(bool) = .init(false),
    demo_res: video_cfg.Resolution = .p2160,
    demo_fps: u8 = 60,
    demo_source: video_cfg.SourceKind = .demo_4k,
    demo_codec: video_cfg.Codec = .h264,
    native_cfg: video_cfg.StreamConfig = .{},
    native_mode: bool = false,

    /// Lista câmeras conectadas usando SDL3 sob demanda.
    pub fn listCameras(self: *Engine, out: []CamDevice) usize {
        if (!self.ensureCamSubsys()) return 0;
        defer if (self.cam == null) self.quitCamSubsys();

        var count: c_int = 0;
        const ids = c.SDL_GetCameras(&count) orelse return 0;
        defer c.SDL_free(ids);

        const total: usize = @min(@as(usize, @intCast(@max(count, 0))), out.len);
        var n: usize = 0;
        for (ids[0..total]) |id| {
            const raw = c.SDL_GetCameraName(id) orelse continue;
            const span = std.mem.span(raw);
            var dev: CamDevice = .{ .id = id };
            const copy_len: u8 = @intCast(@min(span.len, dev.name_buf.len));
            @memcpy(dev.name_buf[0..copy_len], span[0..copy_len]);
            dev.name_len = copy_len;
            out[n] = dev;
            n += 1;
        }
        return n;
    }

    fn specFps(sp: c.SDL_CameraSpec) i64 {
        const den: i64 = @max(@as(i64, sp.framerate_denominator), 1);
        return @divTrunc(@as(i64, sp.framerate_numerator), den);
    }

    fn fmtRank(fmt: c.SDL_PixelFormat) u8 {
        if (fmt == c.SDL_PIXELFORMAT_NV12) return 4;
        if (fmt == c.SDL_PIXELFORMAT_IYUV or fmt == c.SDL_PIXELFORMAT_YV12 or fmt == c.SDL_PIXELFORMAT_NV21) return 3;
        if (fmt == c.SDL_PIXELFORMAT_YUY2 or fmt == c.SDL_PIXELFORMAT_UYVY) return 2;
        return 1;
    }

    fn isBetterSpec(cand: c.SDL_CameraSpec, best: c.SDL_CameraSpec, req_w: i64, req_h: i64, req_fps: i64) bool {
        const cw: i64 = cand.width;
        const ch: i64 = cand.height;
        const bw: i64 = best.width;
        const bh: i64 = best.height;
        if (cw <= 0 or ch <= 0) return false;
        if (bw <= 0 or bh <= 0) return true;

        const c_fps = specFps(cand);
        const b_fps = specFps(best);
        const c_usable = c_fps >= 15;
        const b_usable = b_fps >= 15;
        if (c_usable != b_usable) return c_usable;

        const c_fits = cw <= req_w and ch <= req_h;
        const b_fits = bw <= req_w and bh <= req_h;
        if (c_fits != b_fits) return c_fits;

        const c_smooth = c_fps >= 24;
        const b_smooth = b_fps >= 24;
        if (c_smooth != b_smooth) return c_smooth;

        const c_area = cw * ch;
        const b_area = bw * bh;
        if (c_area != b_area) {
            return if (c_fits) c_area > b_area else c_area < b_area;
        }

        const c_fps_ok = c_fps <= req_fps;
        const b_fps_ok = b_fps <= req_fps;
        if (c_fps_ok != b_fps_ok) return c_fps_ok;
        if (c_fps != b_fps) {
            return if (c_fps_ok) c_fps > b_fps else c_fps < b_fps;
        }

        return fmtRank(cand.format) > fmtRank(best.format);
    }

    fn pickBestCameraSpec(dev: c.SDL_CameraID, req_w: u32, req_h: u32, req_fps: u8, out: *c.SDL_CameraSpec) bool {
        var nf: c_int = 0;
        const fmts = c.SDL_GetCameraSupportedFormats(dev, &nf) orelse return false;
        defer c.SDL_free(@ptrCast(fmts));
        if (nf <= 0) return false;
        const n: usize = @intCast(nf);
        var best = fmts[0].*;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const cand = fmts[i].*;
            if (isBetterSpec(cand, best, req_w, req_h, req_fps)) best = cand;
        }
        out.* = best;
        return true;
    }

    pub fn configureCamera(self: *Engine, bitrate_kbps: u32, hw_accel: bool, preview_only: bool) void {
        self.cam_bitrate_kbps.store(@max(bitrate_kbps, 1200), .release);
        self.cam_hw.store(hw_accel, .release);
        self.cam_preview_only.store(preview_only, .release);
    }

    pub fn startCamera(self: *Engine, dev_index: u8, res: video_cfg.Resolution, fps: u8, allow_demo_fallback: bool) bool {
        self.stopCamera();
        self.cam_dev_idx = dev_index;
        self.cam_res = res;
        self.cam_fps = if (fps >= 45) 60 else if (fps <= 20) 15 else 30;
        self.cam_denied = false;

        if (self.ensureCamSubsys()) {
            var count: c_int = 0;
            if (c.SDL_GetCameras(&count)) |ids| {
                defer c.SDL_free(ids);
                if (count > 0) {
                    const idx: usize = @min(@as(usize, dev_index), @as(usize, @intCast(count - 1)));
                    const dims = res.dims();
                    // Escolhe formato nativo suportado <= alvo (evita upscaler SW/MF 1080p->4K +254MB RAM).
                    var chosen: c.SDL_CameraSpec = undefined;
                    const spec_ptr: ?*const c.SDL_CameraSpec = if (pickBestCameraSpec(ids[idx], dims[0], dims[1], self.cam_fps, &chosen))
                        &chosen
                    else
                        null;
                    if (c.SDL_OpenCamera(ids[idx], spec_ptr)) |opened| {
                        self.cam = opened;
                        if (spec_ptr) |sp| {
                            self.cam_fps = @intCast(std.math.clamp(specFps(sp.*), 15, 60));
                            self.cam_res = if (sp.width >= 3840) .p2160 else if (sp.width >= 2560) .p1440 else if (sp.width >= 1920) .p1080 else if (sp.width >= 1280) .p720 else .p480;
                        }
                        self.cam_synthetic = false;
                        self.cam_cap_stop.store(false, .release);
                        self.cam_cap_thread = c.SDL_CreateThread(camCapThreadMain, "cam-cap", self);
                        return true;
                    }
                }
            }
        }

        self.quitCamSubsys();
        if (allow_demo_fallback) {
            // Na demo sem webcam física conectada, simula câmera em 1080p/4K NV12.
            self.cam_synthetic = true;
            self.cam_synthetic_frame = 0;
            self.cam_last_ms = 0;
            return true;
        }
        return false;
    }

    pub fn stopCamera(self: *Engine) void {
        self.cam_cap_stop.store(true, .release);
        if (self.cam_cap_thread) |t| {
            c.SDL_WaitThread(t, null);
            self.cam_cap_thread = null;
        }
        if (self.cam) |cam| {
            c.SDL_CloseCamera(cam);
            self.cam = null;
        }
        self.stopCamEncWorker();
        if (self.cam_conv_buf.len > 0) {
            nv12_pattern.freeNv12(&self.cam_conv_buf);
        }
        self.cam_synthetic = false;
        self.cam_denied = false;
        self.cam_slot.clear();
        self.quitCamSubsys();
        self.notifyFrame();
    }

    pub fn setWakeFn(self: *Engine, cb: ?*const fn () void) void {
        self.wake_cb = cb;
    }

    pub fn notifyFrame(self: *Engine) void {
        self.frame_dirty.store(true, .release);
        if (self.wake_cb) |f| f();
    }

    pub fn takeChanged(self: *Engine) bool {
        return self.frame_dirty.swap(false, .acq_rel);
    }

    pub fn setTxTargetProbe(self: *Engine, cam_active: ?*const fn () bool, stream_active: ?*const fn () bool) void {
        self.cam_tx_active_fn = cam_active;
        self.stx_active_fn = stream_active;
    }

    pub fn setCameraTxSink(self: *Engine, ctx: ?*anyopaque, cb: ?TxAuFn, key_cb: ?KeyReqFn) void {
        if (self.tx_mu == null) self.tx_mu = c.SDL_CreateMutex();
        c.SDL_LockMutex(self.tx_mu);
        defer c.SDL_UnlockMutex(self.tx_mu);
        self.cam_tx_ctx = ctx;
        self.cam_tx_cb = cb;
        self.cam_key_cb = key_cb;
    }

    pub fn setStreamTxSink(self: *Engine, ctx: ?*anyopaque, cb: ?TxAuFn, key_cb: ?KeyReqFn, audio_cb: ?StreamAudioFn) void {
        if (self.tx_mu == null) self.tx_mu = c.SDL_CreateMutex();
        c.SDL_LockMutex(self.tx_mu);
        defer c.SDL_UnlockMutex(self.tx_mu);
        self.stream_tx_ctx = ctx;
        self.stream_tx_cb = cb;
        self.stream_key_cb = key_cb;
        self.stream_audio_cb = audio_cb;
    }

    pub fn peerCamSlot(self: *Engine, peer: u64) ?*FrameSlot {
        if (peer == 0) return null;
        for (&self.peer_cams) |*pc| {
            if (pc.uid.load(.acquire) == peer) return &pc.slot;
        }
        return null;
    }

    pub fn onRemoteVideoFrame(
        self: *Engine,
        peer: u64,
        is_stream: bool,
        w: u16,
        h: u16,
        y: []const u8,
        y_pitch: usize,
        uv: []const u8,
        uv_pitch: usize,
        codec: video_cfg.Codec,
        pts_ms: i64,
    ) void {
        if (is_stream) {
            self.watch_slot.uploadNv12(w, h, y, @intCast(y_pitch), uv, @intCast(uv_pitch), .screen, codec, pts_ms);
            video_diag.uiUpload(true);
            self.notifyFrame();
            return;
        }
        if (peer == 0) return;
        var target: ?*PeerCam = null;
        for (&self.peer_cams) |*pc| {
            if (pc.uid.load(.acquire) == peer) {
                target = pc;
                break;
            }
        }
        if (target == null) {
            for (&self.peer_cams) |*pc| {
                if (pc.uid.load(.acquire) == 0) {
                    target = pc;
                    break;
                }
            }
        }
        const slot_pc = target orelse &self.peer_cams[0];
        slot_pc.uid.store(peer, .release);
        slot_pc.slot.uploadNv12(w, h, y, @intCast(y_pitch), uv, @intCast(uv_pitch), .camera, codec, pts_ms);
        video_diag.uiUpload(false);
        self.notifyFrame();
    }

    pub fn clearRemoteVideo(self: *Engine, peer: u64, is_stream: bool) void {
        if (is_stream) {
            if (self.demo_thread == null) {
                self.watch_slot.clear();
                self.notifyFrame();
            }
            return;
        }
        if (peer == 0) {
            self.clearPeerCam();
            return;
        }
        for (&self.peer_cams) |*pc| {
            if (pc.uid.load(.acquire) == peer) {
                pc.uid.store(0, .release);
                pc.slot.clear();
                self.notifyFrame();
            }
        }
    }

    pub fn clearPeerCam(self: *Engine) void {
        for (&self.peer_cams) |*pc| {
            pc.uid.store(0, .release);
            pc.slot.clear();
        }
        self.notifyFrame();
    }

    pub fn startDemoWatch(self: *Engine, cfg: video_cfg.StreamConfig) void {
        self.stopWatch();
        self.native_mode = false;
        self.demo_res = cfg.resolution;
        self.demo_fps = if (cfg.fps >= 45) 60 else 30;
        self.demo_source = cfg.kind;
        self.demo_codec = cfg.codec;
        self.demo_stop.store(false, .release);
        self.demo_thread = c.SDL_CreateThread(demoThreadMain, "live-4k", self);
    }

    /// Inicia captura real de monitor (DXGI) ou janela (Windows.Graphics.Capture) em thread dedicada.
    pub fn startNativeCapture(self: *Engine, cfg: video_cfg.StreamConfig) bool {
        self.stopWatch();
        self.native_cfg = cfg;
        self.native_mode = true;
        self.preview_wanted.store(cfg.preview_self, .release);
        self.cursor_wanted.store(cfg.capture_cursor, .release);
        self.demo_res = cfg.resolution;
        self.demo_fps = if (cfg.fps >= 45) 60 else 30;
        self.demo_source = cfg.kind;
        self.demo_codec = cfg.codec;
        self.demo_stop.store(false, .release);
        self.demo_thread = c.SDL_CreateThread(nativeThreadMain, "cap-4k", self);
        return self.demo_thread != null;
    }

    pub fn stopWatch(self: *Engine) void {
        self.demo_stop.store(true, .release);
        if (self.demo_thread) |t| {
            c.SDL_WaitThread(t, null);
            self.demo_thread = null;
        }
        self.watch_slot.clear();
    }

    pub fn tick(self: *Engine, now_ms: i64) void {
        if (self.cam != null) {
            if (self.cam_cap_thread == null) {
                if (self.cam) |cam| {
                    const perm = c.SDL_GetCameraPermissionState(cam);
                    if (perm == c.SDL_CAMERA_PERMISSION_STATE_DENIED) {
                        self.cam_denied = true;
                        self.stopCamera();
                        return;
                    }
                    if (perm == c.SDL_CAMERA_PERMISSION_STATE_APPROVED) {
                        var latest: ?*c.SDL_Surface = null;
                        var ts: u64 = 0;
                        while (c.SDL_AcquireCameraFrame(cam, &ts)) |surf| {
                            if (latest) |old| c.SDL_ReleaseCameraFrame(cam, old);
                            latest = surf;
                        }
                        if (latest) |surf| {
                            defer c.SDL_ReleaseCameraFrame(cam, surf);
                            self.consumeCameraSurface(surf, now_ms);
                        }
                    }
                }
            } else if (self.cam_denied) {
                self.stopCamera();
            }
        } else if (self.cam_synthetic) {
            const step_ms: i64 = if (self.cam_fps >= 45) 16 else 33;
            if (self.cam_last_ms == 0 or now_ms - self.cam_last_ms >= step_ms) {
                self.cam_last_ms = now_ms;
                const dims = self.cam_res.dims();
                const cw: u16 = @intCast(dims[0]);
                const ch: u16 = @intCast(dims[1]);
                renderDemoIntoSlot(&self.cam_slot, cw, ch, self.cam_synthetic_frame, true, .camera, .h264, now_ms);
                self.cam_synthetic_frame +%= 1;

                self.cam_slot.lock();
                if (self.cam_slot.nv12.len >= video_cfg.nv12ByteSize(cw, ch)) {
                    const y_len = @as(usize, cw) * ch;
                    self.emitCameraEncoded(cw, ch, self.cam_slot.nv12[0..y_len], cw, self.cam_slot.nv12[y_len..], cw, now_ms * 1000);
                }
                self.cam_slot.unlock();
            }
        }
    }

    fn startCamEncWorker(self: *Engine) bool {
        if (self.cam_enc_thread != null) return true;
        if (self.cam_enc_mu == null) self.cam_enc_mu = c.SDL_CreateMutex();
        if (self.cam_enc_cond == null) self.cam_enc_cond = c.SDL_CreateCondition();
        if (self.cam_enc_mu == null or self.cam_enc_cond == null) return false;
        self.cam_enc_stop.store(false, .release);
        self.cam_enc_thread = c.SDL_CreateThread(camEncThreadMain, "cam-tx", self);
        return self.cam_enc_thread != null;
    }

    fn stopCamEncWorker(self: *Engine) void {
        self.cam_enc_stop.store(true, .release);
        if (self.cam_enc_mu) |m| {
            c.SDL_LockMutex(m);
            if (self.cam_enc_cond) |cd| c.SDL_BroadcastCondition(cd);
            c.SDL_UnlockMutex(m);
        }
        if (self.cam_enc_thread) |t| {
            c.SDL_WaitThread(t, null);
            self.cam_enc_thread = null;
        }
        if (self.cam_stage_buf.len > 0) {
            nv12_pattern.freeNv12(&self.cam_stage_buf);
        }
        self.cam_stage_ready = false;
        self.cam_stage_w = 0;
        self.cam_stage_h = 0;
    }

    fn emitCameraEncoded(self: *Engine, w: u16, h: u16, y: []const u8, yp: u32, uv: []const u8, uvp: u32, pts_us: i64) void {
        if (self.cam_preview_only.load(.acquire)) {
            if (self.cam_enc_thread != null) self.stopCamEncWorker();
            return;
        }
        if (self.tx_mu) |m| c.SDL_LockMutex(m);
        const cb = self.cam_tx_cb;
        if (self.tx_mu) |m| c.SDL_UnlockMutex(m);
        const tx_active = if (self.cam_tx_active_fn) |p| p() else true;
        if (cb == null or !tx_active) {
            if (self.cam_enc_thread != null) self.stopCamEncWorker();
            return;
        }
        if (!self.startCamEncWorker()) return;
        const mu = self.cam_enc_mu orelse return;
        const cond = self.cam_enc_cond orelse return;
        // TryLock para o fio da UI nunca travar esperando o encoder MF/NVENC.
        if (!c.SDL_TryLockMutex(mu)) return;
        defer c.SDL_UnlockMutex(mu);

        const need = video_cfg.nv12ByteSize(w, h);
        if (self.cam_stage_buf.len != need) {
            nv12_pattern.freeNv12(&self.cam_stage_buf);
            self.cam_stage_buf = nv12_pattern.allocNv12(w, h) catch return;
        }
        const wu: usize = w;
        const hu: usize = h;
        const y_len = wu * hu;
        if (yp == wu) {
            @memcpy(self.cam_stage_buf[0..y_len], y[0..y_len]);
        } else {
            var r: usize = 0;
            while (r < hu) : (r += 1) @memcpy(self.cam_stage_buf[r * wu ..][0..wu], y[r * yp ..][0..wu]);
        }
        if (uvp == wu) {
            const uv_len = wu * (hu / 2);
            @memcpy(self.cam_stage_buf[y_len .. y_len + uv_len], uv[0..uv_len]);
        } else {
            var r: usize = 0;
            while (r < hu / 2) : (r += 1) @memcpy(self.cam_stage_buf[y_len + r * wu ..][0..wu], uv[r * uvp ..][0..wu]);
        }
        self.cam_stage_w = w;
        self.cam_stage_h = h;
        self.cam_stage_pts_us = pts_us;
        self.cam_stage_ready = true;
        c.SDL_SignalCondition(cond);
    }

    fn ensureCamConvBuf(self: *Engine, w: u16, h: u16) bool {
        const need = video_cfg.nv12ByteSize(w, h);
        if (self.cam_conv_buf.len != need) {
            nv12_pattern.freeNv12(&self.cam_conv_buf);
            self.cam_conv_buf = nv12_pattern.allocNv12(w, h) catch return false;
        }
        return true;
    }

    fn consumeCameraSurface(self: *Engine, surf: *c.SDL_Surface, now_ms: i64) void {
        if (surf.pixels == null or surf.w < 2 or surf.h < 2) return;
        const w: u16 = @intCast(@min(surf.w, 4096) & ~@as(c_int, 1));
        const h: u16 = @intCast(@min(surf.h, 4096) & ~@as(c_int, 1));

        if (surf.format == c.SDL_PIXELFORMAT_NV12) {
            const pitch: u32 = @intCast(@max(surf.pitch, 0));
            const y_len = @as(usize, pitch) * h;
            const total = y_len + @as(usize, pitch) * (h / 2);
            const bytes: [*]const u8 = @ptrCast(surf.pixels.?);
            self.cam_slot.uploadNv12(w, h, bytes[0..y_len], pitch, bytes[y_len..total], pitch, .camera, .h264, now_ms);
            self.notifyFrame();
            self.emitCameraEncoded(w, h, bytes[0..y_len], pitch, bytes[y_len..total], pitch, now_ms * 1000);
            return;
        }

        if (surf.format == c.SDL_PIXELFORMAT_YUY2 or surf.format == c.SDL_PIXELFORMAT_UYVY) {
            if (!self.ensureCamConvBuf(w, h)) return;
            const wu: usize = w;
            const hu: usize = h;
            const y_len = wu * hu;
            const pitch: usize = @intCast(@max(surf.pitch, @as(c_int, w * 2)));
            const src: [*]const u8 = @ptrCast(surf.pixels.?);
            const dst_y = self.cam_conv_buf[0..y_len];
            const dst_uv = self.cam_conv_buf[y_len..];
            const yuy2 = surf.format == c.SDL_PIXELFORMAT_YUY2;
            var r: usize = 0;
            while (r < hu) : (r += 1) {
                const srow = src + r * pitch;
                const yrow = dst_y[r * wu ..][0..wu];
                if ((r & 1) == 0) {
                    const uvrow = dst_uv[(r / 2) * wu ..][0..wu];
                    var cx: usize = 0;
                    while (cx + 1 < wu) : (cx += 2) {
                        const o = cx * 2;
                        if (yuy2) {
                            yrow[cx] = srow[o + 0];
                            yrow[cx + 1] = srow[o + 2];
                            uvrow[cx] = srow[o + 1];
                            uvrow[cx + 1] = srow[o + 3];
                        } else {
                            yrow[cx] = srow[o + 1];
                            yrow[cx + 1] = srow[o + 3];
                            uvrow[cx] = srow[o + 0];
                            uvrow[cx + 1] = srow[o + 2];
                        }
                    }
                } else {
                    var cx: usize = 0;
                    while (cx + 1 < wu) : (cx += 2) {
                        const o = cx * 2;
                        if (yuy2) {
                            yrow[cx] = srow[o + 0];
                            yrow[cx + 1] = srow[o + 2];
                        } else {
                            yrow[cx] = srow[o + 1];
                            yrow[cx + 1] = srow[o + 3];
                        }
                    }
                }
            }
            self.cam_slot.uploadNv12(w, h, dst_y, w, dst_uv, w, .camera, .h264, now_ms);
            self.notifyFrame();
            self.emitCameraEncoded(w, h, dst_y, w, dst_uv, w, now_ms * 1000);
            return;
        }

        if (surf.format == c.SDL_PIXELFORMAT_IYUV or surf.format == c.SDL_PIXELFORMAT_YV12) {
            if (!self.ensureCamConvBuf(w, h)) return;
            const wu: usize = w;
            const hu: usize = h;
            const y_len = wu * hu;
            const pitch: usize = @intCast(@max(surf.pitch, @as(c_int, w)));
            const uv_pitch = pitch / 2;
            const src: [*]const u8 = @ptrCast(surf.pixels.?);
            const dst_y = self.cam_conv_buf[0..y_len];
            const dst_uv = self.cam_conv_buf[y_len..];
            var r: usize = 0;
            while (r < hu) : (r += 1) @memcpy(dst_y[r * wu ..][0..wu], src[r * pitch ..][0..wu]);
            const p1_off = pitch * @as(usize, @intCast(surf.h));
            const p2_off = p1_off + uv_pitch * (@as(usize, @intCast(surf.h)) / 2);
            const u_src = if (surf.format == c.SDL_PIXELFORMAT_IYUV) src + p1_off else src + p2_off;
            const v_src = if (surf.format == c.SDL_PIXELFORMAT_IYUV) src + p2_off else src + p1_off;
            const uvh = hu / 2;
            const uvw = wu / 2;
            r = 0;
            while (r < uvh) : (r += 1) {
                const ur = u_src + r * uv_pitch;
                const vr = v_src + r * uv_pitch;
                const drow = dst_uv[r * wu ..][0..wu];
                var cx: usize = 0;
                while (cx < uvw) : (cx += 1) {
                    drow[cx * 2] = ur[cx];
                    drow[cx * 2 + 1] = vr[cx];
                }
            }
            self.cam_slot.uploadNv12(w, h, dst_y, w, dst_uv, w, .camera, .h264, now_ms);
            self.notifyFrame();
            self.emitCameraEncoded(w, h, dst_y, w, dst_uv, w, now_ms * 1000);
            return;
        }

        const conv = c.SDL_ConvertSurface(surf, c.SDL_PIXELFORMAT_NV12) orelse return;
        defer c.SDL_DestroySurface(conv);
        const cs: *c.SDL_Surface = @ptrCast(conv);
        if (cs.pixels == null or cs.w < 2 or cs.h < 2) return;
        const cw: u16 = @intCast(@min(cs.w, 4096) & ~@as(c_int, 1));
        const ch: u16 = @intCast(@min(cs.h, 4096) & ~@as(c_int, 1));
        const cpitch: u32 = @intCast(@max(cs.pitch, 0));
        const cy_len = @as(usize, cpitch) * ch;
        const ctotal = cy_len + @as(usize, cpitch) * (ch / 2);
        const cbytes: [*]const u8 = @ptrCast(cs.pixels.?);
        self.cam_slot.uploadNv12(cw, ch, cbytes[0..cy_len], cpitch, cbytes[cy_len..ctotal], cpitch, .camera, .h264, now_ms);
        self.notifyFrame();
        self.emitCameraEncoded(cw, ch, cbytes[0..cy_len], cpitch, cbytes[cy_len..ctotal], cpitch, now_ms * 1000);
    }

    pub fn cameraActive(self: *const Engine) bool {
        return self.cam != null or self.cam_synthetic;
    }

    pub fn watchActive(self: *const Engine) bool {
        return self.demo_thread != null or self.watch_slot.active;
    }

    pub fn totalCpuRamBytes(self: *const Engine) usize {
        var sum = self.cam_slot.ramBytes() + self.watch_slot.ramBytes() + self.cam_stage_buf.len;
        for (&self.peer_cams) |*pc| sum += pc.slot.ramBytes();
        return sum;
    }

    pub fn stopAll(self: *Engine) void {
        self.stopWatch();
        self.stopCamera();
        self.clearPeerCam();
    }

    pub fn deinit(self: *Engine) void {
        self.demo_stop.store(true, .release);
        if (self.demo_thread) |t| {
            c.SDL_WaitThread(t, null);
            self.demo_thread = null;
        }
        self.stopCamera();
        self.cam_slot.deinit();
        self.watch_slot.deinit();
        for (&self.peer_cams) |*pc| pc.slot.deinit();
        if (self.cam_enc_cond) |cd| {
            c.SDL_DestroyCondition(cd);
            self.cam_enc_cond = null;
        }
        if (self.cam_enc_mu) |m| {
            c.SDL_DestroyMutex(m);
            self.cam_enc_mu = null;
        }
        if (self.tx_mu) |m| {
            c.SDL_DestroyMutex(m);
            self.tx_mu = null;
        }
    }

    fn ensureCamSubsys(self: *Engine) bool {
        if (self.cam_subsys) return true;
        if (!c.SDL_InitSubSystem(c.SDL_INIT_CAMERA)) return false;
        self.cam_subsys = true;
        return true;
    }

    fn quitCamSubsys(self: *Engine) void {
        if (!self.cam_subsys) return;
        c.SDL_QuitSubSystem(c.SDL_INIT_CAMERA);
        self.cam_subsys = false;
    }
};

fn renderDemoIntoSlot(
    slot: *FrameSlot,
    w: u16,
    h: u16,
    frame_idx: u64,
    cam_style: bool,
    source: video_cfg.SourceKind,
    codec: video_cfg.Codec,
    now_ms: i64,
) void {
    slot.lock();
    defer slot.unlock();

    const need = video_cfg.nv12ByteSize(w, h);
    if (slot.nv12.len != need) {
        nv12_pattern.freeNv12(&slot.nv12);
        slot.nv12 = nv12_pattern.allocNv12(w, h) catch return;
        slot.bg_w = 0;
        slot.bg_h = 0;
    }
    if (slot.bg_w != w or slot.bg_h != h) {
        nv12_pattern.initDemoBackground(slot.nv12, w, h);
        slot.bg_w = w;
        slot.bg_h = h;
    }
    nv12_pattern.stepDemoOverlay(slot.nv12, w, h, frame_idx, cam_style);
    slot.finishFrameLocked(w, h, source, codec, now_ms);
}

fn demoThreadMain(data: ?*anyopaque) callconv(.c) c_int {
    const engine: *Engine = @ptrCast(@alignCast(data.?));
    const dims = engine.demo_res.dims();
    const w: u16 = @intCast(dims[0]);
    const h: u16 = @intCast(dims[1]);
    const interval_ms: u32 = if (engine.demo_fps >= 45) 16 else 33;
    var frame: u64 = 0;
    while (!engine.demo_stop.load(.acquire)) {
        const t0: i64 = @intCast(c.SDL_GetTicks());
        renderDemoIntoSlot(&engine.watch_slot, w, h, frame, false, engine.demo_source, engine.demo_codec, t0);
        engine.notifyFrame();
        frame +%= 1;
        c.SDL_Delay(interval_ms);
    }
    return 0;
}

fn camEncThreadMain(data: ?*anyopaque) callconv(.c) c_int {
    const engine: *Engine = @ptrCast(@alignCast(data.?));
    var enc_opt: ?capture_backend.HwEncoder = null;
    defer if (enc_opt) |*e| e.deinit();
    var local_buf: []u8 = &.{};
    defer if (local_buf.len > 0) nv12_pattern.freeNv12(&local_buf);
    var enc_w: u16 = 0;
    var enc_h: u16 = 0;
    var last_br: u32 = @max(engine.cam_bitrate_kbps.load(.acquire), 800);
    var cam_sticky_kf: bool = true;
    var last_hw: bool = engine.cam_hw.load(.acquire);

    const mu = engine.cam_enc_mu orelse return 0;
    const cond = engine.cam_enc_cond orelse return 0;

    while (!engine.cam_enc_stop.load(.acquire)) {
        c.SDL_LockMutex(mu);
        while (!engine.cam_stage_ready and !engine.cam_enc_stop.load(.acquire)) {
            c.SDL_WaitCondition(cond, mu);
        }
        if (engine.cam_enc_stop.load(.acquire)) {
            c.SDL_UnlockMutex(mu);
            break;
        }
        const w = engine.cam_stage_w;
        const h = engine.cam_stage_h;
        const pts_us = engine.cam_stage_pts_us;
        const need = video_cfg.nv12ByteSize(w, h);
        var copied = false;
        if (need > 0 and engine.cam_stage_buf.len >= need) {
            // Troca de ponteiros sob o mutex: elimina cópia NV12 completa e reduz 1 buffer.
            const tmp = local_buf;
            local_buf = engine.cam_stage_buf;
            engine.cam_stage_buf = tmp;
            copied = true;
        }
        engine.cam_stage_ready = false;
        c.SDL_UnlockMutex(mu);

        if (!copied) continue;
        const cur_hw = engine.cam_hw.load(.acquire);
        const cur_br = @max(engine.cam_bitrate_kbps.load(.acquire), 800);
        if (enc_opt != null and (enc_w != w or enc_h != h or last_hw != cur_hw)) {
            enc_opt.?.deinit();
            enc_opt = null;
        }
        if (enc_opt == null) {
            enc_opt = capture_backend.HwEncoder.openConfigured(.h264, w, h, @max(engine.cam_fps, 15), cur_br, null, cur_hw, engine.cam_perf, engine.cam_kf_sec) catch null;
            enc_w = w;
            enc_h = h;
            last_br = cur_br;
            last_hw = cur_hw;
            if (enc_opt) |*e| e.requestKeyframe();
        } else if (cur_br != last_br) {
            last_br = cur_br;
            enc_opt.?.setBitrate(cur_br);
        }
        if (engine.tx_mu) |tm| c.SDL_LockMutex(tm);
        const cb = engine.cam_tx_cb;
        const ctx = engine.cam_tx_ctx;
        const kcb = engine.cam_key_cb;
        if (engine.tx_mu) |tm| c.SDL_UnlockMutex(tm);

        if (cb) |tx_fn| {
            if (enc_opt) |*e| {
                if (kcb) |kf| if (kf(ctx)) {
                    cam_sticky_kf = true;
                };
                if (cam_sticky_kf) e.requestKeyframe();
                const y_len = @as(usize, w) * h;
                const fr: media_if.CaptureFrame = .{
                    .width = w,
                    .height = h,
                    .nv12_y = local_buf[0..y_len],
                    .nv12_uv = local_buf[y_len..need],
                    .y_pitch = w,
                    .uv_pitch = w,
                    .pts_us = pts_us,
                };
                if (e.encode(fr) catch null) |pkt| {
                    if (pkt.is_keyframe) cam_sticky_kf = false;
                    video_diag.txEnc(e.hw, w, h);
                    tx_fn(ctx, pkt.codec, pts_us, pkt.is_keyframe, pkt.data);
                }
                while (e.pollOutput(pts_us)) |epkt| {
                    if (epkt.is_keyframe) cam_sticky_kf = false;
                    video_diag.txEnc(e.hw, w, h);
                    tx_fn(ctx, epkt.codec, pts_us, epkt.is_keyframe, epkt.data);
                }
            }
        }
    }
    return 0;
}

fn camCapThreadMain(data: ?*anyopaque) callconv(.c) c_int {
    const engine: *Engine = @ptrCast(@alignCast(data.?));
    sys.beginHiResTimer();
    defer sys.endHiResTimer();
    while (!engine.cam_cap_stop.load(.acquire)) {
        const cam = engine.cam orelse break;
        const perm = c.SDL_GetCameraPermissionState(cam);
        if (perm == c.SDL_CAMERA_PERMISSION_STATE_DENIED) {
            engine.cam_denied = true;
            engine.notifyFrame();
            break;
        }
        var got_any = false;
        if (perm == c.SDL_CAMERA_PERMISSION_STATE_APPROVED) {
            var latest: ?*c.SDL_Surface = null;
            var ts: u64 = 0;
            while (c.SDL_AcquireCameraFrame(cam, &ts)) |surf| {
                if (latest) |old| c.SDL_ReleaseCameraFrame(cam, old);
                latest = surf;
            }
            if (latest) |surf| {
                defer c.SDL_ReleaseCameraFrame(cam, surf);
                engine.consumeCameraSurface(surf, @intCast(c.SDL_GetTicks()));
                got_any = true;
            }
        }
        c.SDL_Delay(if (got_any) 1 else 4);
    }
    return 0;
}

pub var stream_target_bitrate_fn: ?*const fn () u32 = null;

fn openScreenMonitorWgc(target_id: u64, res: video_cfg.Resolution) ?capture_backend.ScreenSource {
    var disps: [8]media_if.DisplayTarget = undefined;
    const nd = capture_backend.enumerateDisplays(&disps);
    for (disps[0..nd]) |dp| {
        if (dp.id == target_id and dp.hmonitor != 0) {
            return capture_backend.ScreenSource.openMonitorWgc(dp.hmonitor, res) catch null;
        }
    }
    if (nd > 0 and disps[0].hmonitor != 0) {
        return capture_backend.ScreenSource.openMonitorWgc(disps[0].hmonitor, res) catch null;
    }
    return null;
}

fn nativeThreadMain(data: ?*anyopaque) callconv(.c) c_int {
    const engine: *Engine = @ptrCast(@alignCast(data.?));
    sys.beginHiResTimer();
    defer sys.endHiResTimer();
    const cfg = engine.native_cfg;
    const interval_ms: u32 = if (engine.demo_fps >= 45) 16 else 33;
    const interval_ns: u64 = if (engine.demo_fps >= 45) 16_666_667 else 33_333_333;

    // Loopback (CoInitializeEx/CoUninitialize) deve ser aberto primeiro para que o defer rode POR ÚLTIMO,
    // após enc_opt.deinit() (MF COM) e src_opt.deinit() (WGC WinRT/D3D11).
    const target_pid: u32 = if (cfg.kind == .window and cfg.target_id != 0) capture_backend.windowProcessId(cfg.target_id) else 0;
    var lb_opt: ?capture_backend.Loopback = if (cfg.share_audio) (capture_backend.Loopback.openSmart(target_pid, cfg.kind == .window) catch null) else null;
    defer if (lb_opt) |*lb| lb.deinit();

    var src_opt: ?capture_backend.ScreenSource = null;
    defer if (src_opt) |*s| s.deinit();

    var enc_opt: ?capture_backend.HwEncoder = null;
    defer if (enc_opt) |*e| e.deinit();
    var pcm_buf: [1920]f32 = undefined;
    var last_preview_ms: i64 = 0;
    var last_br_check_ms: i64 = 0;
    var last_frame_ms: i64 = 0;
    var has_sent_frame: bool = false;
    var sticky_kf: bool = false;
    var open_ms: i64 = @intCast(c.SDL_GetTicks());
    var used_dxgi_auto: bool = false;
    var last_cursor: bool = engine.cursor_wanted.load(.acquire);
    var last_br_kbps: u32 = cfg.bitrate_kbps;
    var next_tick_ns: u64 = c.SDL_GetTicksNS();

    while (!engine.demo_stop.load(.acquire)) {
        if (src_opt == null) {
            if (cfg.kind == .window) {
                src_opt = capture_backend.ScreenSource.openWindow(cfg.target_id, cfg.resolution) catch null;
                used_dxgi_auto = false;
            } else {
                src_opt = switch (cfg.capture_backend) {
                    .dxgi => capture_backend.ScreenSource.openDisplay(cfg.target_id, cfg.resolution) catch null,
                    .wgc => openScreenMonitorWgc(cfg.target_id, cfg.resolution),
                    .auto => capture_backend.ScreenSource.openDisplay(cfg.target_id, cfg.resolution) catch openScreenMonitorWgc(cfg.target_id, cfg.resolution),
                };
                used_dxgi_auto = cfg.capture_backend == .auto and src_opt != null and src_opt.? == .dxgi;
            }
            open_ms = @intCast(c.SDL_GetTicks());
            if (src_opt == null) {
                c.SDL_Delay(200);
                continue;
            }
            last_cursor = engine.cursor_wanted.load(.acquire);
            src_opt.?.setCursorCapture(last_cursor);
            has_sent_frame = false;
            last_frame_ms = 0;
            next_tick_ns = c.SDL_GetTicksNS();
        }

        const cur_cursor = engine.cursor_wanted.load(.acquire);
        if (cur_cursor != last_cursor) {
            last_cursor = cur_cursor;
            src_opt.?.setCursorCapture(cur_cursor);
        }

        if (engine.tx_mu) |m| c.SDL_LockMutex(m);
        const stx_cb = engine.stream_tx_cb;
        const stx_ctx = engine.stream_tx_ctx;
        const skey_cb = engine.stream_key_cb;
        const saudio_cb = engine.stream_audio_cb;
        if (engine.tx_mu) |m| c.SDL_UnlockMutex(m);

        if (lb_opt) |*lb| {
            const n_samp = lb.readPcm(&pcm_buf);
            if (n_samp > 0) if (saudio_cb) |acb| acb(stx_ctx, pcm_buf[0..n_samp]);
        }

        const t0_ns: u64 = c.SDL_GetTicksNS();
        const t0: i64 = @intCast(t0_ns / 1_000_000);
        const pts_us: i64 = @intCast(t0_ns / 1000);
        const preview_due = engine.preview_wanted.load(.acquire) and (t0 - last_preview_ms >= 40);
        const cpu_needed_tx = (src_opt.?.d3d11Device() == null) or (if (enc_opt) |*e| e.force_cpu_buf else false);
        const want_cpu = preview_due or cpu_needed_tx;

        const got = src_opt.?.acquireNv12(interval_ms, want_cpu, pts_us) catch |err| {
            if (err == error.AccessLost) {
                if (enc_opt) |*e| {
                    e.deinit();
                    enc_opt = null;
                }
                src_opt.?.deinit();
                src_opt = null;
            }
            c.SDL_Delay(20);
            continue;
        };

        const stx_active = if (engine.stx_active_fn) |p| p() else true;
        const tx_fn_opt = if (stx_active) stx_cb else null;
        if (tx_fn_opt != null) {
            if (skey_cb) |kf| if (kf(stx_ctx)) {
                sticky_kf = true;
            };
        }
        const req_kf = sticky_kf;

        var active_frame: ?media_if.CaptureFrame = got;
        var is_fresh = false;
        if (got != null) {
            is_fresh = true;
            has_sent_frame = true;
            used_dxgi_auto = false;
            video_diag.txCap();
        } else if (!has_sent_frame and used_dxgi_auto and cfg.kind == .screen and t0 - open_ms >= 350) {
            // Tela 100% parada ao iniciar DXGI não entrega quadro #0; migra para WGC automaticamente.
            used_dxgi_auto = false;
            if (openScreenMonitorWgc(cfg.target_id, cfg.resolution)) |wgc_src| {
                if (enc_opt) |*old_e| old_e.deinit();
                enc_opt = null;
                if (src_opt) |*old_s| old_s.deinit();
                src_opt = wgc_src;
                src_opt.?.setCursorCapture(last_cursor);
                open_ms = t0;
                continue;
            }
        } else if (has_sent_frame and tx_fn_opt != null and (req_kf or t0 - last_frame_ms >= cfg.static_refresh_ms)) {
            active_frame = src_opt.?.repeatNv12(cpu_needed_tx, pts_us) catch null;
        }

        if (active_frame) |f| {
            last_frame_ms = t0;
            if (is_fresh and preview_due and f.nv12_y.len > 0) {
                last_preview_ms = t0;
                engine.watch_slot.uploadNv12(
                    f.width,
                    f.height,
                    f.nv12_y,
                    f.y_pitch,
                    f.nv12_uv,
                    f.uv_pitch,
                    cfg.kind,
                    cfg.codec,
                    t0,
                );
                engine.notifyFrame();
            }
            if (tx_fn_opt) |tx_fn| {
                const eff_codec: video_cfg.Codec = if (cfg.transport == .discord_sfu) .h264 else if (cfg.codec == .auto) .h264 else cfg.codec;
                if (enc_opt == null) {
                    const enc_codec: video_cfg.Codec = if (cfg.transport == .discord_sfu) .h264 else eff_codec;
                    enc_opt = capture_backend.HwEncoder.openConfigured(enc_codec, f.width, f.height, cfg.fps, cfg.bitrate_kbps, src_opt.?.d3d11Device(), cfg.hw_accel, cfg.perf_preset, cfg.keyframe_sec) catch null;
                    if (enc_opt) |*e| e.requestKeyframe();
                }
                if (enc_opt) |*e| {
                    if (req_kf) e.requestKeyframe();
                    if (t0 - last_br_check_ms >= 500) {
                        last_br_check_ms = t0;
                        if (stream_target_bitrate_fn) |bfn| {
                            const tgt_kbps = bfn();
                            if (tgt_kbps >= 600 and @abs(@as(i64, tgt_kbps) - @as(i64, last_br_kbps)) >= @max(@as(i64, last_br_kbps / 6), 350)) {
                                last_br_kbps = @min(tgt_kbps, cfg.bitrate_kbps);
                                e.setBitrate(last_br_kbps);
                            }
                        }
                    }
                    if (e.encode(f) catch null) |pkt| {
                        if (pkt.is_keyframe) sticky_kf = false;
                        video_diag.txEnc(e.hw, f.width, f.height);
                        tx_fn(stx_ctx, pkt.codec, pts_us, pkt.is_keyframe, pkt.data);
                    }
                    while (e.pollOutput(pts_us)) |epkt| {
                        if (epkt.is_keyframe) sticky_kf = false;
                        video_diag.txEnc(e.hw, f.width, f.height);
                        tx_fn(stx_ctx, epkt.codec, pts_us, epkt.is_keyframe, epkt.data);
                    }
                }
            } else if (enc_opt != null) {
                enc_opt.?.deinit();
                enc_opt = null;
            }
            if (is_fresh) {
                next_tick_ns += interval_ns;
                const now_after_ns = c.SDL_GetTicksNS();
                if (now_after_ns > next_tick_ns + interval_ns * 2) next_tick_ns = now_after_ns;
                if (next_tick_ns > now_after_ns) {
                    const rem_ms: u32 = @intCast(@min((next_tick_ns - now_after_ns) / 1_000_000, interval_ms));
                    if (rem_ms > 0) c.SDL_Delay(rem_ms);
                }
            } else {
                c.SDL_Delay(2);
            }
        } else {
            // WGC returns immediately when no new desktop frame is ready; poll shortly (2ms) instead of sleeping a full frame.
            const elapsed_ns = c.SDL_GetTicksNS() - t0_ns;
            if (elapsed_ns < 2_500_000) c.SDL_Delay(2);
        }
    }
    return 0;
}

test "Engine.isBetterSpec avoids upscaling 1080p webcam to 4K and prefers NV12 >=15fps" {
    const nv12_1080: c.SDL_CameraSpec = .{ .format = c.SDL_PIXELFORMAT_NV12, .colorspace = c.SDL_COLORSPACE_BT709_LIMITED, .width = 1920, .height = 1080, .framerate_numerator = 30, .framerate_denominator = 1 };
    const mjpg_1080: c.SDL_CameraSpec = .{ .format = c.SDL_PIXELFORMAT_MJPG, .colorspace = c.SDL_COLORSPACE_BT709_LIMITED, .width = 1920, .height = 1080, .framerate_numerator = 30, .framerate_denominator = 1 };
    const yuy2_slow: c.SDL_CameraSpec = .{ .format = c.SDL_PIXELFORMAT_YUY2, .colorspace = c.SDL_COLORSPACE_BT709_LIMITED, .width = 1920, .height = 1080, .framerate_numerator = 5, .framerate_denominator = 1 };
    const nv12_720: c.SDL_CameraSpec = .{ .format = c.SDL_PIXELFORMAT_NV12, .colorspace = c.SDL_COLORSPACE_BT709_LIMITED, .width = 1280, .height = 720, .framerate_numerator = 30, .framerate_denominator = 1 };

    // When 4K@60 requested on a 1080p cam, pick 1080p NV12 30fps over MJPEG, 5fps YUY2, or 720p.
    try std.testing.expect(Engine.isBetterSpec(nv12_1080, mjpg_1080, 3840, 2160, 60));
    try std.testing.expect(Engine.isBetterSpec(nv12_1080, yuy2_slow, 3840, 2160, 60));
    try std.testing.expect(!Engine.isBetterSpec(yuy2_slow, nv12_1080, 3840, 2160, 60));
    // Usable 720p@30 MUST beat 5fps 1080p YUY2 even if 1080p has larger pixel area.
    try std.testing.expect(Engine.isBetterSpec(nv12_720, yuy2_slow, 3840, 2160, 60));
    try std.testing.expect(!Engine.isBetterSpec(yuy2_slow, nv12_720, 3840, 2160, 60));
    try std.testing.expect(Engine.isBetterSpec(nv12_1080, nv12_720, 3840, 2160, 60));

    // When 720p requested, prefer native 720p over larger 1080p.
    try std.testing.expect(Engine.isBetterSpec(nv12_720, nv12_1080, 1280, 720, 30));
}
