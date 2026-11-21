//! Codificador e decodificador em hardware via Windows Media Foundation (MFT GPU:
//! NVENC / AMF / QuickSync) em H.264, HEVC e AV1 com suporte a zero-copy D3D11 NV12
//! e fallback em software/CPU quando não houver GPU compatível.
const std = @import("std");
const c = @import("c");
const com = @import("com.zig");
const sys = @import("../sys.zig");
const media_if = @import("../media_if.zig");
const video_cfg = @import("../../core/video_cfg.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const DWORD = com.DWORD;
const UINT = com.UINT;
const BOOL = com.BOOL;

const MFT_REGISTER_TYPE_INFO = extern struct {
    guidMajorType: GUID,
    guidSubtype: GUID,
};

const MFT_OUTPUT_STREAM_INFO = extern struct {
    dwFlags: DWORD = 0,
    cbSize: DWORD = 0,
    cbAlignment: DWORD = 0,
};

const MFT_OUTPUT_DATA_BUFFER = extern struct {
    dwStreamID: DWORD = 0,
    pSample: ?*anyopaque = null,
    dwStatus: DWORD = 0,
    pEvents: ?*anyopaque = null,
};

const MFT_ENUM_FLAG_SYNCMFT: DWORD = 0x00000001;
const MFT_ENUM_FLAG_ASYNCMFT: DWORD = 0x00000002;
const MFT_ENUM_FLAG_HARDWARE: DWORD = 0x00000004;
const MFT_ENUM_FLAG_SORTANDFILTER: DWORD = 0x00000040;
const MFT_MESSAGE_COMMAND_FLUSH: UINT = 0x00000000;
const MFT_MESSAGE_COMMAND_DRAIN: UINT = 0x00000001;
const MFT_MESSAGE_SET_D3D_MANAGER: UINT = 0x00000002;
const MFT_MESSAGE_NOTIFY_BEGIN_STREAMING: UINT = 0x10000000;
const MFT_MESSAGE_NOTIFY_END_OF_STREAM: UINT = 0x10000002;
const MFT_MESSAGE_NOTIFY_START_OF_STREAM: UINT = 0x10000003;
const MFT_OUTPUT_STREAM_PROVIDES_SAMPLES: DWORD = 0x00000100;

const METransformNeedInput: u32 = 601;
const METransformHaveOutput: u32 = 602;
const METransformDrainComplete: u32 = 603;

const AsyncState = struct {
    ev_gen: ?*anyopaque = null,
    need_input: u32 = 0,
    have_output: u32 = 0,
    drain_done: bool = false,

    fn active(self: *const AsyncState) bool {
        return self.ev_gen != null;
    }

    fn pump(self: *AsyncState, wait_ms: u32, wait_input: bool, wait_output: bool) void {
        const gen = self.ev_gen orelse return;
        const get_ev = com.slot(gen, 3, *const fn (*anyopaque, DWORD, *?*anyopaque) callconv(.winapi) HRESULT);
        const t0 = c.SDL_GetTicks();
        while (true) {
            var got_any = false;
            while (true) {
                var ev: ?*anyopaque = null;
                // MF_EVENT_FLAG_NO_WAIT = 1
                const hr = get_ev(gen, 1, &ev);
                if (!com.succeeded(hr) or ev == null) break;
                defer com.release(ev);
                got_any = true;
                const get_type = com.slot(ev.?, 33, *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT);
                var met: u32 = 0;
                if (com.succeeded(get_type(ev.?, &met))) {
                    switch (met) {
                        METransformNeedInput => self.need_input +|= 1,
                        METransformHaveOutput => self.have_output +|= 1,
                        METransformDrainComplete => self.drain_done = true,
                        else => {},
                    }
                }
            }
            if (wait_input and self.need_input > 0) return;
            if (wait_output and (self.have_output > 0 or self.drain_done)) return;
            if (!wait_input and !wait_output) return;
            if (wait_ms == 0) return;
            if (c.SDL_GetTicks() - t0 >= wait_ms) return;
            if (!got_any) c.SDL_Delay(1);
        }
    }

    fn deinit(self: *AsyncState) void {
        com.release(self.ev_gen);
        self.ev_gen = null;
        self.need_input = 0;
        self.have_output = 0;
        self.drain_done = false;
    }
};

const MFStartupFn = *const fn (UINT, DWORD) callconv(.winapi) HRESULT;
const MFShutdownFn = *const fn () callconv(.winapi) HRESULT;
const MFTEnumExFn = *const fn (
    GUID,
    DWORD,
    ?*const MFT_REGISTER_TYPE_INFO,
    ?*const MFT_REGISTER_TYPE_INFO,
    *?[*]*anyopaque,
    *UINT,
) callconv(.winapi) HRESULT;
const MFCreateMediaTypeFn = *const fn (*?*anyopaque) callconv(.winapi) HRESULT;
const MFCreateSampleFn = *const fn (*?*anyopaque) callconv(.winapi) HRESULT;
const MFCreateMemoryBufferFn = *const fn (DWORD, *?*anyopaque) callconv(.winapi) HRESULT;
const MFCreateDXGISurfaceBufferFn = *const fn (*const GUID, *anyopaque, UINT, BOOL, *?*anyopaque) callconv(.winapi) HRESULT;
const MFCreateDXGIDeviceManagerFn = *const fn (*UINT, *?*anyopaque) callconv(.winapi) HRESULT;
const CoTaskMemFreeFn = *const fn (?*anyopaque) callconv(.winapi) void;

const MfApi = struct {
    mfplat: *c.SDL_SharedObject,
    ole32: *c.SDL_SharedObject,
    startup: MFStartupFn,
    shutdown: MFShutdownFn,
    enum_ex: MFTEnumExFn,
    create_mt: MFCreateMediaTypeFn,
    create_sample: MFCreateSampleFn,
    create_mem_buf: MFCreateMemoryBufferFn,
    create_dxgi_buf: ?MFCreateDXGISurfaceBufferFn,
    create_dxgi_mgr: ?MFCreateDXGIDeviceManagerFn,
    co_free: CoTaskMemFreeFn,
    started: bool = false,

    fn open() !MfApi {
        const mfplat = c.SDL_LoadObject("mfplat.dll") orelse return error.MfPlatMissing;
        errdefer c.SDL_UnloadObject(mfplat);
        const ole32 = c.SDL_LoadObject("ole32.dll") orelse return error.Ole32Missing;
        errdefer c.SDL_UnloadObject(ole32);

        const startup: MFStartupFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFStartup") orelse return error.MfFnMissing));
        const shutdown: MFShutdownFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFShutdown") orelse return error.MfFnMissing));
        const enum_ex: MFTEnumExFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFTEnumEx") orelse return error.MfFnMissing));
        const create_mt: MFCreateMediaTypeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFCreateMediaType") orelse return error.MfFnMissing));
        const create_sample: MFCreateSampleFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFCreateSample") orelse return error.MfFnMissing));
        const create_mem_buf: MFCreateMemoryBufferFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFCreateMemoryBuffer") orelse return error.MfFnMissing));
        const co_free: CoTaskMemFreeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoTaskMemFree") orelse return error.OleFnMissing));

        // MF_VERSION = (0x0002 << 16) | 0x0070 = 0x00020070, MFSTARTUP_LITE = 1.
        if (!com.succeeded(startup(0x00020070, 1))) return error.MfStartupFailed;
        return .{
            .mfplat = mfplat,
            .ole32 = ole32,
            .startup = startup,
            .shutdown = shutdown,
            .enum_ex = enum_ex,
            .create_mt = create_mt,
            .create_sample = create_sample,
            .create_mem_buf = create_mem_buf,
            .create_dxgi_buf = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFCreateDXGISurfaceBuffer"))),
            .create_dxgi_mgr = @ptrCast(@alignCast(c.SDL_LoadFunction(mfplat, "MFCreateDXGIDeviceManager"))),
            .co_free = co_free,
            .started = true,
        };
    }

    fn close(self: *MfApi) void {
        if (self.started) {
            _ = self.shutdown();
            self.started = false;
        }
        c.SDL_UnloadObject(self.ole32);
        c.SDL_UnloadObject(self.mfplat);
    }
};

fn subtypeOf(codec: video_cfg.Codec) GUID {
    return switch (codec) {
        .hevc => com.MFVideoFormat_HEVC,
        .av1 => com.MFVideoFormat_AV1,
        else => com.MFVideoFormat_H264,
    };
}

fn hasMft(api: *const MfApi, cat: GUID, in_t: ?*const MFT_REGISTER_TYPE_INFO, out_t: ?*const MFT_REGISTER_TYPE_INFO, hw_only: bool) bool {
    var arr: ?[*]*anyopaque = null;
    var cnt: UINT = 0;
    const flags: DWORD = if (hw_only)
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER
    else
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER;
    if (!com.succeeded(api.enum_ex(cat, flags, in_t, out_t, &arr, &cnt))) return false;
    if (arr) |list| {
        for (list[0..cnt]) |act| com.release(act);
        api.co_free(@ptrCast(list));
    }
    return cnt > 0;
}

/// Detecta capacidades de hardware H.264/HEVC/AV1 sem manter MFTs nem buffers abertos.
pub fn probeCapabilities() media_if.HwCapability {
    var api = MfApi.open() catch return .{};
    defer api.close();

    const nv12_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_NV12 };
    const h264_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_H264 };
    const hevc_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_HEVC };
    const av1_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_AV1 };

    return .{
        .h264_enc = hasMft(&api, com.MFT_CATEGORY_VIDEO_ENCODER, &nv12_info, &h264_info, true),
        .hevc_enc = hasMft(&api, com.MFT_CATEGORY_VIDEO_ENCODER, &nv12_info, &hevc_info, true),
        .av1_enc = hasMft(&api, com.MFT_CATEGORY_VIDEO_ENCODER, &nv12_info, &av1_info, true),
        .h264_dec = hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &h264_info, &nv12_info, true) or hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &h264_info, &nv12_info, false),
        .hevc_dec = hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &hevc_info, &nv12_info, true) or hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &hevc_info, &nv12_info, false),
        .av1_dec = hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &av1_info, &nv12_info, true) or hasMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &av1_info, &nv12_info, false),
        .zero_copy_d3d11 = api.create_dxgi_buf != null and api.create_dxgi_mgr != null,
    };
}

fn activateFirstMft(api: *const MfApi, cat: GUID, in_t: *const MFT_REGISTER_TYPE_INFO, out_t: *const MFT_REGISTER_TYPE_INFO, hw_preferred: bool) ?struct { mft: *anyopaque, hw: bool } {
    const passes: [2]struct { flags: DWORD, hw: bool } = if (hw_preferred) .{
        .{ .flags = MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, .hw = true },
        .{ .flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, .hw = false },
    } else .{
        .{ .flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, .hw = false },
        .{ .flags = MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, .hw = true },
    };

    for (passes) |pass| {
        var arr: ?[*]*anyopaque = null;
        var cnt: UINT = 0;
        if (!com.succeeded(api.enum_ex(cat, pass.flags, in_t, out_t, &arr, &cnt)) or arr == null or cnt == 0) continue;
        defer {
            for (arr.?[0..cnt]) |act| com.release(act);
            api.co_free(@ptrCast(arr.?));
        }

        for (arr.?[0..cnt]) |act| {
            const activate = com.slot(act, 33, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT);
            var mft: ?*anyopaque = null;
            if (com.succeeded(activate(act, &com.IID_IMFTransform, &mft)) and mft != null) {
                return .{ .mft = mft.?, .hw = pass.hw };
            }
        }
    }
    return null;
}

fn packU32Pair(hi: u32, lo: u32) u64 {
    return (@as(u64, hi) << 32) | lo;
}

fn buildVideoMediaType(api: *const MfApi, subtype: GUID, w: u16, h: u16, fps: u8, bitrate_bps: ?u32, h264_profile: ?UINT) !*anyopaque {
    var mt: ?*anyopaque = null;
    if (!com.succeeded(api.create_mt(&mt)) or mt == null) return error.CreateMediaTypeFailed;
    errdefer com.release(mt);

    const set_guid = com.slot(mt.?, 24, *const fn (*anyopaque, *const GUID, *const GUID) callconv(.winapi) HRESULT);
    const set_u64 = com.slot(mt.?, 22, *const fn (*anyopaque, *const GUID, u64) callconv(.winapi) HRESULT);
    const set_u32 = com.slot(mt.?, 21, *const fn (*anyopaque, *const GUID, UINT) callconv(.winapi) HRESULT);

    if (!com.succeeded(set_guid(mt.?, &com.MF_MT_MAJOR_TYPE, &com.MFMediaType_Video))) return error.SetMtFailed;
    if (!com.succeeded(set_guid(mt.?, &com.MF_MT_SUBTYPE, &subtype))) return error.SetMtFailed;
    if (!com.succeeded(set_u64(mt.?, &com.MF_MT_FRAME_SIZE, packU32Pair(w, h)))) return error.SetMtFailed;
    if (!com.succeeded(set_u64(mt.?, &com.MF_MT_FRAME_RATE, packU32Pair(@max(fps, 1), 1)))) return error.SetMtFailed;
    // MFVideoInterlace_Progressive = 2.
    _ = set_u32(mt.?, &com.MF_MT_INTERLACE_MODE, 2);
    if (bitrate_bps) |bps| _ = set_u32(mt.?, &com.MF_MT_AVG_BITRATE, bps);
    if (h264_profile) |prof| _ = set_u32(mt.?, &com.MF_MT_MPEG2_PROFILE, prof);
    return mt.?;
}

fn configureMftCommon(
    api: *const MfApi,
    mft: *anyopaque,
    d3d11_dev: ?*anyopaque,
    out_dxgi_mgr: *?*anyopaque,
    in_id: *DWORD,
    out_id: *DWORD,
    async_out: *AsyncState,
) void {
    const get_attrs = com.slot(mft, 8, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    var attrs: ?*anyopaque = null;
    if (com.succeeded(get_attrs(mft, &attrs)) and attrs != null) {
        defer com.release(attrs);
        const get_u32 = com.slot(attrs.?, 7, *const fn (*anyopaque, *const GUID, *UINT) callconv(.winapi) HRESULT);
        const set_u32 = com.slot(attrs.?, 21, *const fn (*anyopaque, *const GUID, UINT) callconv(.winapi) HRESULT);
        var is_async: UINT = 0;
        if (com.succeeded(get_u32(attrs.?, &com.MF_TRANSFORM_ASYNC, &is_async)) and is_async != 0) {
            _ = set_u32(attrs.?, &com.MF_TRANSFORM_ASYNC_UNLOCK, 1);
            async_out.ev_gen = com.queryInterface(mft, anyopaque, &com.IID_IMFMediaEventGenerator);
        } else {
            // Ainda tenta destravar MFTs que só aceitam UNLOCK explícito antes de SetOutputType.
            _ = set_u32(attrs.?, &com.MF_TRANSFORM_ASYNC_UNLOCK, 1);
        }
        _ = set_u32(attrs.?, &com.MF_LOW_LATENCY, 1);
    }

    if (d3d11_dev) |dev| if (api.create_dxgi_mgr) |mk_mgr| {
        var token: UINT = 0;
        if (com.succeeded(mk_mgr(&token, out_dxgi_mgr)) and out_dxgi_mgr.* != null) {
            const reset_dev = com.slot(out_dxgi_mgr.*.?, 7, *const fn (*anyopaque, *anyopaque, UINT) callconv(.winapi) HRESULT);
            if (com.succeeded(reset_dev(out_dxgi_mgr.*.?, dev, token))) {
                const proc_msg = com.slot(mft, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
                _ = proc_msg(mft, MFT_MESSAGE_SET_D3D_MANAGER, @intFromPtr(out_dxgi_mgr.*.?));
            }
        }
    };

    const get_ids = com.slot(mft, 5, *const fn (*anyopaque, DWORD, *DWORD, DWORD, *DWORD) callconv(.winapi) HRESULT);
    _ = get_ids(mft, 1, in_id, 1, out_id);
}

pub const HwEncoder = struct {
    api: MfApi,
    mft: ?*anyopaque = null,
    codec_api: ?*anyopaque = null,
    dxgi_mgr: ?*anyopaque = null,
    out_sample: ?*anyopaque = null,
    out_buf: []u8 = &.{},
    async: AsyncState = .{},
    codec: video_cfg.Codec = .h264,
    w: u16 = 0,
    h: u16 = 0,
    fps: u8 = 60,
    bitrate_kbps: u32 = 8000,
    hw: bool = false,
    provides_samples: bool = false,
    force_cpu_buf: bool = false,
    timer_on: bool = false,
    in_id: DWORD = 0,
    out_id: DWORD = 0,
    last_hr: HRESULT = 0,
    sps_buf: [256]u8 = undefined,
    sps_len: usize = 0,
    pps_buf: [256]u8 = undefined,
    pps_len: usize = 0,

    pub fn open(codec: video_cfg.Codec, w: u16, h: u16, fps: u8, bitrate_kbps: u32, d3d11_dev: ?*anyopaque) !HwEncoder {
        return openPref(codec, w, h, fps, bitrate_kbps, d3d11_dev, true);
    }

    pub fn openPref(codec: video_cfg.Codec, w: u16, h: u16, fps: u8, bitrate_kbps: u32, d3d11_dev: ?*anyopaque, hw_preferred: bool) !HwEncoder {
        return openConfigured(codec, w, h, fps, bitrate_kbps, d3d11_dev, hw_preferred, .balanced, 2);
    }

    pub fn openConfigured(
        codec: video_cfg.Codec,
        w: u16,
        h: u16,
        fps: u8,
        bitrate_kbps: u32,
        d3d11_dev: ?*anyopaque,
        hw_preferred: bool,
        perf: video_cfg.PerfPreset,
        keyframe_sec: u8,
    ) !HwEncoder {
        if (!hw_preferred) {
            if (openImpl(codec, w, h, fps, bitrate_kbps, null, false, perf, keyframe_sec)) |sw_enc| {
                return sw_enc;
            } else |_| {}
        }
        if (openImpl(codec, w, h, fps, bitrate_kbps, d3d11_dev, true, perf, keyframe_sec)) |hw_enc| {
            return hw_enc;
        } else |err| {
            // Se o encoder hardware falhar (ou com D3D11), cai para MFT em software CPU/NV12.
            return openImpl(codec, w, h, fps, bitrate_kbps, null, false, perf, keyframe_sec) catch return err;
        }
    }

    fn openImpl(
        codec: video_cfg.Codec,
        w: u16,
        h: u16,
        fps: u8,
        bitrate_kbps: u32,
        d3d11_dev: ?*anyopaque,
        hw_only: bool,
        perf: video_cfg.PerfPreset,
        keyframe_sec: u8,
    ) !HwEncoder {
        const eff_codec: video_cfg.Codec = if (codec == .auto) .h264 else codec;
        var api = try MfApi.open();
        errdefer api.close();

        const sub = subtypeOf(eff_codec);
        const in_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_NV12 };
        const out_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = sub };

        // Prioriza MFT de hardware (NVENC / AMF / QSV); se hw_only=false aceita encoder SW do sistema.
        const picked = activateFirstMft(&api, com.MFT_CATEGORY_VIDEO_ENCODER, &in_info, &out_info, hw_only) orelse return error.NoEncoderMft;
        var self: HwEncoder = .{
            .api = api,
            .mft = picked.mft,
            .codec = eff_codec,
            .w = w,
            .h = h,
            .fps = fps,
            .bitrate_kbps = @max(bitrate_kbps, 500),
            .hw = picked.hw,
        };
        errdefer self.deinit();

        configureMftCommon(&api, self.mft.?, d3d11_dev, &self.dxgi_mgr, &self.in_id, &self.out_id, &self.async);
        if (com.queryInterface(self.mft.?, anyopaque, &com.IID_ICodecAPI)) |capi| {
            defer com.release(capi);
            const set_val = com.slot(capi, 9, *const fn (*anyopaque, *const GUID, *const com.VARIANT) callconv(.winapi) HRESULT);
            const ll = com.VARIANT.fromBool(true);
            _ = set_val(capi, &com.CODECAPI_AVLowLatencyMode, &ll);
        }

        const set_out = com.slot(self.mft.?, 16, *const fn (*anyopaque, DWORD, ?*anyopaque, DWORD) callconv(.winapi) HRESULT);
        const h264_profiles: [3]?UINT = if (eff_codec == .h264)
            // Discord WebRTC/OpenH264 negocia profile-level-id=42e01f (Constrained Baseline = 256, fallback Base = 66).
            .{ 256, 66, null }
        else
            .{ null, null, null };
        var out_ok = false;
        for (h264_profiles) |prof| {
            const out_mt = try buildVideoMediaType(&api, sub, w, h, fps, self.bitrate_kbps * 1000, prof);
            defer com.release(out_mt);
            if (com.succeeded(set_out(self.mft.?, self.out_id, out_mt, 0))) {
                out_ok = true;
                break;
            }
            if (eff_codec != .h264) break;
        }
        if (!out_ok) return error.SetOutputTypeFailed;

        const in_mt = try buildVideoMediaType(&api, com.MFVideoFormat_NV12, w, h, fps, null, null);
        defer com.release(in_mt);
        const set_in = com.slot(self.mft.?, 15, *const fn (*anyopaque, DWORD, ?*anyopaque, DWORD) callconv(.winapi) HRESULT);
        if (!com.succeeded(set_in(self.mft.?, self.in_id, in_mt, 0))) return error.SetInputTypeFailed;

        self.codec_api = com.queryInterface(self.mft.?, anyopaque, &com.IID_ICodecAPI);
        if (self.codec_api) |capi| {
            const set_val = com.slot(capi, 9, *const fn (*anyopaque, *const GUID, *const com.VARIANT) callconv(.winapi) HRESULT);
            const ll = com.VARIANT.fromBool(true);
            _ = set_val(capi, &com.CODECAPI_AVLowLatencyMode, &ll);
            // CBR (0) dá banda previsível no WebRTC; Quality usa PeakConstrainedVBR (1) para nitidez em texto.
            const rc_mode: UINT = if (perf == .quality) 1 else 0;
            const cbr = com.VARIANT.fromU32(rc_mode);
            _ = set_val(capi, &com.CODECAPI_AVEncCommonRateControlMode, &cbr);
            const br = com.VARIANT.fromU32(self.bitrate_kbps * 1000);
            _ = set_val(capi, &com.CODECAPI_AVEncCommonMeanBitRate, &br);
            const max_mult: u32 = if (perf == .quality) 1500 else 1250;
            const max_br = com.VARIANT.fromU32(self.bitrate_kbps * max_mult);
            _ = set_val(capi, &com.CODECAPI_AVEncCommonMaxBitRate, &max_br);
            const qvs = com.VARIANT.fromU32(perf.qualityVsSpeed());
            _ = set_val(capi, &com.CODECAPI_AVEncCommonQualityVsSpeed, &qvs);
            // WebRTC / Discord exige GOP curto (1s..4s) sem B-frames para recuperar perdas sem travar.
            const zero_b = com.VARIANT.fromU32(0);
            _ = set_val(capi, &com.CODECAPI_AVEncMPVDefaultBPictureCount, &zero_b);
            const kf_s: UINT = @intCast(std.math.clamp(keyframe_sec, 1, 4));
            const gop = com.VARIANT.fromU32(@as(UINT, @max(fps, 1)) * kf_s);
            _ = set_val(capi, &com.CODECAPI_AVEncMPVGOPSize, &gop);
        }

        var os_info: MFT_OUTPUT_STREAM_INFO = .{};
        const get_out_info = com.slot(self.mft.?, 7, *const fn (*anyopaque, DWORD, *MFT_OUTPUT_STREAM_INFO) callconv(.winapi) HRESULT);
        _ = get_out_info(self.mft.?, self.out_id, &os_info);
        self.provides_samples = (os_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

        if (!self.provides_samples) {
            const cap_sz = @max(os_info.cbSize, @as(DWORD, 512 * 1024));
            var os: ?*anyopaque = null;
            var ob: ?*anyopaque = null;
            if (!com.succeeded(api.create_sample(&os)) or os == null) return error.OutSampleFailed;
            if (!com.succeeded(api.create_mem_buf(cap_sz, &ob)) or ob == null) {
                com.release(os);
                return error.OutBufFailed;
            }
            const add_buf = com.slot(os.?, 42, *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT);
            _ = add_buf(os.?, ob.?);
            com.release(ob);
            self.out_sample = os;
        }

        const pixels = @as(u32, self.w) * @as(u32, self.h);
        const out_cap: usize = if (pixels <= 1280 * 720) 512 * 1024 else if (pixels <= 1920 * 1080) 1024 * 1024 else 2 * 1024 * 1024;
        self.out_buf = try std.heap.page_allocator.alloc(u8, out_cap);

        const proc_msg = com.slot(self.mft.?, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
        _ = proc_msg(self.mft.?, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        _ = proc_msg(self.mft.?, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        sys.beginHiResTimer();
        self.timer_on = true;
        return self;
    }

    pub fn requestKeyframe(self: *HwEncoder) void {
        const capi = self.codec_api orelse return;
        const set_val = com.slot(capi, 9, *const fn (*anyopaque, *const GUID, *const com.VARIANT) callconv(.winapi) HRESULT);
        const force = com.VARIANT.fromU32(1);
        _ = set_val(capi, &com.CODECAPI_AVEncVideoForceKeyFrame, &force);
    }

    pub fn setBitrate(self: *HwEncoder, bitrate_kbps: u32) void {
        const clamped = @max(bitrate_kbps, 500);
        if (clamped == self.bitrate_kbps) return;
        self.bitrate_kbps = clamped;
        const capi = self.codec_api orelse return;
        const set_val = com.slot(capi, 9, *const fn (*anyopaque, *const GUID, *const com.VARIANT) callconv(.winapi) HRESULT);
        const br = com.VARIANT.fromU32(clamped * 1000);
        _ = set_val(capi, &com.CODECAPI_AVEncCommonMeanBitRate, &br);
        const max_br = com.VARIANT.fromU32(clamped * 1250);
        _ = set_val(capi, &com.CODECAPI_AVEncCommonMaxBitRate, &max_br);
    }

    fn createInputSample(self: *HwEncoder, frame: media_if.CaptureFrame, use_gpu: bool) !?*anyopaque {
        var sample: ?*anyopaque = null;
        if (!com.succeeded(self.api.create_sample(&sample)) or sample == null) return error.SampleFailed;
        errdefer com.release(sample);

        var buf: ?*anyopaque = null;
        if (use_gpu and frame.gpu_tex != null and self.api.create_dxgi_buf != null and self.dxgi_mgr != null) {
            const fn_dxgi = self.api.create_dxgi_buf.?;
            if (!com.succeeded(fn_dxgi(&com.IID_ID3D11Texture2D, frame.gpu_tex.?, 0, 0, &buf))) buf = null;
        }
        if (buf == null) {
            if (frame.nv12_y.len == 0) return null;
            const total: DWORD = @intCast(video_cfg.nv12ByteSize(self.w, self.h));
            if (!com.succeeded(self.api.create_mem_buf(total, &buf)) or buf == null) return error.MemBufFailed;
            const lock_fn = com.slot(buf.?, 3, *const fn (*anyopaque, *[*]u8, ?*DWORD, ?*DWORD) callconv(.winapi) HRESULT);
            const unlock_fn = com.slot(buf.?, 4, *const fn (*anyopaque) callconv(.winapi) HRESULT);
            const set_len = com.slot(buf.?, 6, *const fn (*anyopaque, DWORD) callconv(.winapi) HRESULT);
            var dst: [*]u8 = undefined;
            if (com.succeeded(lock_fn(buf.?, &dst, null, null))) {
                const wu: usize = self.w;
                const hu: usize = self.h;
                var row: usize = 0;
                while (row < hu) : (row += 1) {
                    @memcpy(dst[row * wu ..][0..wu], frame.nv12_y[row * frame.y_pitch ..][0..wu]);
                }
                const uv_off = wu * hu;
                const uv_h = hu / 2;
                row = 0;
                while (row < uv_h) : (row += 1) {
                    @memcpy(dst[uv_off + row * wu ..][0..wu], frame.nv12_uv[row * frame.uv_pitch ..][0..wu]);
                }
                _ = unlock_fn(buf.?);
                _ = set_len(buf.?, total);
            }
        }
        defer com.release(buf);

        const add_buf = com.slot(sample.?, 42, *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT);
        _ = add_buf(sample.?, buf.?);

        const set_time = com.slot(sample.?, 36, *const fn (*anyopaque, i64) callconv(.winapi) HRESULT);
        const set_dur = com.slot(sample.?, 38, *const fn (*anyopaque, i64) callconv(.winapi) HRESULT);
        // Media Foundation trabalha em unidades de 100 ns.
        _ = set_time(sample.?, frame.pts_us * 10);
        _ = set_dur(sample.?, @divFloor(10_000_000, @as(i64, @max(self.fps, 1))));
        return sample;
    }

    /// Codifica um quadro direto da GPU (`frame.gpu_tex`) ou do plano NV12 CPU com fallback automático.
    pub fn encode(self: *HwEncoder, frame: media_if.CaptureFrame) !?media_if.EncodedPacket {
        const mft = self.mft orelse return error.NotOpen;
        const proc_in = com.slot(mft, 24, *const fn (*anyopaque, DWORD, *anyopaque, DWORD) callconv(.winapi) HRESULT);
        if (self.async.active()) {
            self.async.pump(0, false, false);
            if (self.async.need_input == 0) {
                self.async.pump(6, true, false);
                if (self.async.need_input == 0) {
                    return self.readOutput(frame.pts_us, 2);
                }
            }
        }

        const try_gpu = !self.force_cpu_buf and frame.gpu_tex != null and self.api.create_dxgi_buf != null and self.dxgi_mgr != null;
        var sample = (try self.createInputSample(frame, try_gpu)) orelse return null;
        var hr_in = proc_in(mft, self.in_id, sample, 0);
        com.release(sample);
        if (!com.succeeded(hr_in) and try_gpu and frame.nv12_y.len > 0) {
            self.force_cpu_buf = true;
            sample = (try self.createInputSample(frame, false)) orelse return null;
            hr_in = proc_in(mft, self.in_id, sample, 0);
            com.release(sample);
        }
        if (!com.succeeded(hr_in)) {
            self.last_hr = hr_in;
            return error.ProcessInputFailed;
        }
        if (self.async.active()) self.async.need_input -|= 1;

        return self.readOutput(frame.pts_us, 8);
    }

    pub fn pollOutput(self: *HwEncoder, pts_us: i64) ?media_if.EncodedPacket {
        if (!self.async.active()) return null;
        return self.readOutput(pts_us, 0);
    }

    pub fn drain(self: *HwEncoder, send_cmd: bool) ?media_if.EncodedPacket {
        const mft = self.mft orelse return null;
        if (send_cmd) {
            const proc_msg = com.slot(mft, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
            _ = proc_msg(mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
        }
        return self.readOutput(0, 60);
    }

    fn readOutput(self: *HwEncoder, pts_us: i64, wait_ms: u32) ?media_if.EncodedPacket {
        const mft = self.mft orelse return null;
        if (self.async.active()) {
            self.async.pump(wait_ms, false, true);
            if (self.async.have_output == 0) return null;
            self.async.have_output -|= 1;
        }

        const proc_out = com.slot(mft, 25, *const fn (*anyopaque, DWORD, DWORD, [*]MFT_OUTPUT_DATA_BUFFER, *DWORD) callconv(.winapi) HRESULT);
        var odb: MFT_OUTPUT_DATA_BUFFER = .{
            .dwStreamID = self.out_id,
            .pSample = if (self.provides_samples) null else self.out_sample,
        };
        var status: DWORD = 0;
        const hr = proc_out(mft, 0, 1, @ptrCast(&odb), &status);
        defer if (self.provides_samples and odb.pSample != null) com.release(odb.pSample);
        defer com.release(odb.pEvents);

        self.last_hr = hr;
        if (hr == com.MF_E_TRANSFORM_NEED_MORE_INPUT) return null;
        if (!com.succeeded(hr)) return null;
        const os = odb.pSample orelse return null;

        var contig: ?*anyopaque = null;
        const to_contig = com.slot(os, 41, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(to_contig(os, &contig)) or contig == null) return null;
        defer com.release(contig);

        const lock_out = com.slot(contig.?, 3, *const fn (*anyopaque, *[*]const u8, ?*DWORD, *DWORD) callconv(.winapi) HRESULT);
        const unlock_out = com.slot(contig.?, 4, *const fn (*anyopaque) callconv(.winapi) HRESULT);
        var ptr: [*]const u8 = undefined;
        var cur_len: DWORD = 0;
        if (!com.succeeded(lock_out(contig.?, &ptr, null, &cur_len)) or cur_len == 0) return null;
        defer _ = unlock_out(contig.?);

        const copy_len = @min(@as(usize, cur_len), self.out_buf.len);
        @memcpy(self.out_buf[0..copy_len], ptr[0..copy_len]);

        // MFSampleExtension_CleanPoint verifica se é IDR/keyframe.
        const key_guid = GUID.init(0x9CDF01D8, 0xA0F0, 0x43BA, .{ 0xB0, 0x77, 0xEA, 0xA0, 0x6C, 0xBD, 0x72, 0x8A });
        const get_u32 = com.slot(os, 7, *const fn (*anyopaque, *const GUID, *UINT) callconv(.winapi) HRESULT);
        var clean_pt: UINT = 0;
        var is_key = com.succeeded(get_u32(os, &key_guid, &clean_pt)) and clean_pt != 0;
        var final_len = copy_len;
        if (self.codec == .h264) {
            final_len = self.ensureH264SpsPps(copy_len, &is_key);
        }

        return .{
            .data = self.out_buf[0..final_len],
            .pts_us = pts_us,
            .is_keyframe = is_key,
            .codec = self.codec,
        };
    }

    fn ensureH264SpsPps(self: *HwEncoder, raw_len: usize, is_key: *bool) usize {
        var has_sps = false;
        var has_pps = false;
        var has_idr = is_key.*;
        const data = self.out_buf[0..raw_len];
        var i: usize = 0;
        var nal_start: ?usize = null;
        while (i + 2 < data.len) {
            const sc3 = data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1;
            const sc4 = i + 3 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1;
            if (sc3 or sc4) {
                const sc_len: usize = if (sc4) 4 else 3;
                if (nal_start) |s| self.scanH264Nal(data[s..i], &has_sps, &has_pps, &has_idr);
                i += sc_len;
                nal_start = i;
                continue;
            }
            i += 1;
        }
        if (nal_start) |s| self.scanH264Nal(data[s..], &has_sps, &has_pps, &has_idr);
        is_key.* = has_idr;
        if (!has_idr or (has_sps and has_pps)) return raw_len;

        const add_sps: usize = if (!has_sps and self.sps_len > 0) self.sps_len else 0;
        const add_pps: usize = if (!has_pps and self.pps_len > 0) self.pps_len else 0;
        const pre = add_sps + add_pps;
        if (pre == 0 or pre + raw_len > self.out_buf.len) return raw_len;

        std.mem.copyBackwards(u8, self.out_buf[pre..][0..raw_len], self.out_buf[0..raw_len]);
        var pos: usize = 0;
        if (add_sps > 0) {
            @memcpy(self.out_buf[pos..][0..add_sps], self.sps_buf[0..add_sps]);
            pos += add_sps;
        }
        if (add_pps > 0) {
            @memcpy(self.out_buf[pos..][0..add_pps], self.pps_buf[0..add_pps]);
        }
        return pre + raw_len;
    }

    fn scanH264Nal(self: *HwEncoder, nal: []const u8, has_sps: *bool, has_pps: *bool, has_idr: *bool) void {
        if (nal.len == 0) return;
        const ntype = nal[0] & 0x1F;
        if (ntype == 5) has_idr.* = true;
        const sc4 = [_]u8{ 0, 0, 0, 1 };
        if (ntype == 7) {
            has_sps.* = true;
            if (4 + nal.len <= self.sps_buf.len) {
                @memcpy(self.sps_buf[0..4], &sc4);
                @memcpy(self.sps_buf[4..][0..nal.len], nal);
                self.sps_len = 4 + nal.len;
            }
        } else if (ntype == 8) {
            has_pps.* = true;
            if (4 + nal.len <= self.pps_buf.len) {
                @memcpy(self.pps_buf[0..4], &sc4);
                @memcpy(self.pps_buf[4..][0..nal.len], nal);
                self.pps_len = 4 + nal.len;
            }
        }
    }

    pub fn deinit(self: *HwEncoder) void {
        if (self.mft) |mft| {
            const proc_msg = com.slot(mft, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
            _ = proc_msg(mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            _ = proc_msg(mft, MFT_MESSAGE_COMMAND_FLUSH, 0);
        }
        self.async.deinit();
        if (self.out_buf.len > 0) {
            std.heap.page_allocator.free(self.out_buf);
            self.out_buf = &.{};
        }
        com.release(self.out_sample);
        com.release(self.dxgi_mgr);
        com.release(self.codec_api);
        com.release(self.mft);
        self.out_sample = null;
        self.dxgi_mgr = null;
        self.codec_api = null;
        self.mft = null;
        self.api.close();
        if (self.timer_on) {
            self.timer_on = false;
            sys.endHiResTimer();
        }
    }
};

const D3D11CreateDeviceFn = *const fn (?*anyopaque, UINT, ?*anyopaque, UINT, ?[*]const UINT, UINT, UINT, *?*anyopaque, *UINT, *?*anyopaque) callconv(.winapi) HRESULT;

const DecoderD3d11 = struct {
    dll: *c.SDL_SharedObject,
    dev: *anyopaque,
    ctx: *anyopaque,

    fn create() ?DecoderD3d11 {
        const dll = c.SDL_LoadObject("d3d11.dll") orelse return null;
        const create_fn: D3D11CreateDeviceFn = @ptrCast(@alignCast(c.SDL_LoadFunction(dll, "D3D11CreateDevice") orelse {
            c.SDL_UnloadObject(dll);
            return null;
        }));
        const levels = [_]UINT{ 0xB100, 0xB000, 0xA100 };
        var fl: UINT = 0;
        var dev: ?*anyopaque = null;
        var ctx: ?*anyopaque = null;
        const flags = com.D3D11_CREATE_DEVICE_BGRA_SUPPORT | com.D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
        var hr = create_fn(null, 1, null, flags, &levels, levels.len, 7, &dev, &fl, &ctx);
        if (!com.succeeded(hr)) {
            com.release(dev);
            com.release(ctx);
            dev = null;
            ctx = null;
            hr = create_fn(null, 1, null, com.D3D11_CREATE_DEVICE_BGRA_SUPPORT, &levels, levels.len, 7, &dev, &fl, &ctx);
        }
        if (!com.succeeded(hr) or dev == null or ctx == null) {
            com.release(ctx);
            com.release(dev);
            c.SDL_UnloadObject(dll);
            return null;
        }
        if (com.queryInterface(dev.?, com.IUnknown, &com.IID_ID3D11Multithread)) |mt| {
            defer com.release(mt);
            const set_mt = com.slot(mt, 5, *const fn (*anyopaque, BOOL) callconv(.winapi) BOOL);
            _ = set_mt(mt, 1);
        }
        return .{ .dll = dll, .dev = dev.?, .ctx = ctx.? };
    }

    fn close(self: *DecoderD3d11) void {
        com.release(self.ctx);
        com.release(self.dev);
        c.SDL_UnloadObject(self.dll);
    }
};

/// Decodificador em hardware (Media Foundation MFT) de H.264 / HEVC / AV1 -> NV12.
pub const HwDecoder = struct {
    api: MfApi,
    mft: ?*anyopaque = null,
    dxgi_mgr: ?*anyopaque = null,
    out_sample: ?*anyopaque = null,
    nv12_buf: []u8 = &.{},
    async: AsyncState = .{},
    owned_d3d11_dll: ?*c.SDL_SharedObject = null,
    owned_d3d11_dev: ?*anyopaque = null,
    owned_d3d11_ctx: ?*anyopaque = null,
    codec: video_cfg.Codec = .h264,
    w: u16 = 0,
    h: u16 = 0,
    stride: u32 = 0,
    hw: bool = false,
    provides_samples: bool = false,
    timer_on: bool = false,
    in_id: DWORD = 0,
    out_id: DWORD = 0,
    last_hr: HRESULT = 0,
    sps_buf: [256]u8 = undefined,
    sps_len: usize = 0,
    pps_buf: [256]u8 = undefined,
    pps_len: usize = 0,

    pub fn open(codec: video_cfg.Codec, w_hint: u16, h_hint: u16, d3d11_dev: ?*anyopaque) !HwDecoder {
        return openPref(codec, w_hint, h_hint, d3d11_dev, true);
    }

    fn openWithOwnD3d11(codec: video_cfg.Codec, w_hint: u16, h_hint: u16) ?HwDecoder {
        var own = DecoderD3d11.create() orelse return null;
        if (openImpl(codec, w_hint, h_hint, own.dev, true)) |self_in| {
            var self = self_in;
            self.owned_d3d11_dll = own.dll;
            self.owned_d3d11_dev = own.dev;
            self.owned_d3d11_ctx = own.ctx;
            return self;
        } else |_| {
            own.close();
            return null;
        }
    }

    pub fn openPref(codec: video_cfg.Codec, w_hint: u16, h_hint: u16, d3d11_dev: ?*anyopaque, hw_preferred: bool) !HwDecoder {
        if (d3d11_dev) |dev| {
            return openImpl(codec, w_hint, h_hint, dev, hw_preferred);
        }
        // Em 720p/1080p H.264 sem textura D3D11 zero-copy o decoder CPU é ~10x mais rápido (0.8-1.8ms/quadro vs readback DXVA);
        // para HEVC/AV1/4K com hw_preferred, tenta DXVA primeiro.
        const eff: video_cfg.Codec = if (codec == .auto) .h264 else codec;
        const try_dxva_first = hw_preferred and (eff != .h264 or w_hint > 1920 or h_hint > 1080);
        if (try_dxva_first) if (openWithOwnD3d11(codec, w_hint, h_hint)) |hw_dec| return hw_dec;
        return openImpl(codec, w_hint, h_hint, null, false) catch |err| {
            if (hw_preferred and !try_dxva_first) if (openWithOwnD3d11(codec, w_hint, h_hint)) |hw_dec| return hw_dec;
            return err;
        };
    }

    fn openImpl(codec: video_cfg.Codec, w_hint: u16, h_hint: u16, d3d11_dev: ?*anyopaque, hw_preferred: bool) !HwDecoder {
        const eff_codec: video_cfg.Codec = if (codec == .auto) .h264 else codec;
        var api = try MfApi.open();
        errdefer api.close();

        const sub = subtypeOf(eff_codec);
        const in_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = sub };
        const out_info: MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = com.MFMediaType_Video, .guidSubtype = com.MFVideoFormat_NV12 };

        const picked = activateFirstMft(&api, com.MFT_CATEGORY_VIDEO_DECODER, &in_info, &out_info, hw_preferred) orelse return error.NoDecoderMft;
        var self: HwDecoder = .{
            .api = api,
            .mft = picked.mft,
            .codec = eff_codec,
            .w = @max(w_hint, 2),
            .h = @max(h_hint, 2),
            .hw = picked.hw,
        };
        errdefer self.deinit();

        configureMftCommon(&api, self.mft.?, d3d11_dev, &self.dxgi_mgr, &self.in_id, &self.out_id, &self.async);
        if (com.queryInterface(self.mft.?, anyopaque, &com.IID_ICodecAPI)) |capi| {
            defer com.release(capi);
            const set_val = com.slot(capi, 9, *const fn (*anyopaque, *const GUID, *const com.VARIANT) callconv(.winapi) HRESULT);
            const ll = com.VARIANT.fromBool(true);
            _ = set_val(capi, &com.CODECAPI_AVLowLatencyMode, &ll);
        }

        const in_mt = try buildVideoMediaType(&api, sub, self.w, self.h, 60, null, null);
        defer com.release(in_mt);
        const set_in = com.slot(self.mft.?, 15, *const fn (*anyopaque, DWORD, ?*anyopaque, DWORD) callconv(.winapi) HRESULT);
        if (!com.succeeded(set_in(self.mft.?, self.in_id, in_mt, 0))) return error.SetDecoderInputFailed;

        try self.negotiateOutputNv12();

        const proc_msg = com.slot(self.mft.?, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
        _ = proc_msg(self.mft.?, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        _ = proc_msg(self.mft.?, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        sys.beginHiResTimer();
        self.timer_on = true;
        return self;
    }

    fn negotiateOutputNv12(self: *HwDecoder) !void {
        const mft = self.mft orelse return error.NotOpen;
        const get_avail = com.slot(mft, 14, *const fn (*anyopaque, DWORD, DWORD, *?*anyopaque) callconv(.winapi) HRESULT);
        const set_out = com.slot(mft, 16, *const fn (*anyopaque, DWORD, ?*anyopaque, DWORD) callconv(.winapi) HRESULT);

        var idx: DWORD = 0;
        var chosen: ?*anyopaque = null;
        while (idx < 24) : (idx += 1) {
            var mt: ?*anyopaque = null;
            if (!com.succeeded(get_avail(mft, self.out_id, idx, &mt)) or mt == null) break;
            const get_guid = com.slot(mt.?, 10, *const fn (*anyopaque, *const GUID, *GUID) callconv(.winapi) HRESULT);
            var sub_g: GUID = undefined;
            if (com.succeeded(get_guid(mt.?, &com.MF_MT_SUBTYPE, &sub_g)) and std.mem.eql(u8, std.mem.asBytes(&sub_g), std.mem.asBytes(&com.MFVideoFormat_NV12))) {
                chosen = mt;
                break;
            }
            com.release(mt);
        }
        const out_mt = chosen orelse return error.DecoderNv12Unavailable;
        defer com.release(out_mt);

        const get_u64 = com.slot(out_mt, 8, *const fn (*anyopaque, *const GUID, *u64) callconv(.winapi) HRESULT);
        const get_u32 = com.slot(out_mt, 7, *const fn (*anyopaque, *const GUID, *UINT) callconv(.winapi) HRESULT);
        var fsz: u64 = 0;
        if (com.succeeded(get_u64(out_mt, &com.MF_MT_FRAME_SIZE, &fsz))) {
            const nw: u16 = @intCast(@min(@max(fsz >> 32, 2), 4096));
            const nh: u16 = @intCast(@min(@max(fsz & 0xFFFF_FFFF, 2), 4096));
            self.w = nw;
            self.h = nh;
        }
        var st_u: UINT = 0;
        self.stride = if (com.succeeded(get_u32(out_mt, &com.MF_MT_DEFAULT_STRIDE, &st_u)) and st_u >= self.w and st_u <= 16384)
            @intCast(st_u)
        else
            self.w;
        if (!com.succeeded(set_out(mft, self.out_id, out_mt, 0))) return error.SetDecoderOutputFailed;

        var os_info: MFT_OUTPUT_STREAM_INFO = .{};
        const get_out_info = com.slot(mft, 7, *const fn (*anyopaque, DWORD, *MFT_OUTPUT_STREAM_INFO) callconv(.winapi) HRESULT);
        _ = get_out_info(mft, self.out_id, &os_info);
        self.provides_samples = (os_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

        com.release(self.out_sample);
        self.out_sample = null;
        if (!self.provides_samples) {
            const need: DWORD = @max(os_info.cbSize, @as(DWORD, @intCast(video_cfg.nv12ByteSize(self.w, self.h))));
            var os: ?*anyopaque = null;
            var ob: ?*anyopaque = null;
            if (!com.succeeded(self.api.create_sample(&os)) or os == null) return error.OutSampleFailed;
            if (!com.succeeded(self.api.create_mem_buf(need, &ob)) or ob == null) {
                com.release(os);
                return error.OutBufFailed;
            }
            const add_buf = com.slot(os.?, 42, *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT);
            _ = add_buf(os.?, ob.?);
            com.release(ob);
            self.out_sample = os;
        }
    }

    pub fn decode(self: *HwDecoder, au_bytes: []const u8, pts_us: i64) !?media_if.CaptureFrame {
        if (au_bytes.len == 0) return null;
        const mft = self.mft orelse return error.NotOpen;

        var sample: ?*anyopaque = null;
        var in_buf: ?*anyopaque = null;
        if (!com.succeeded(self.api.create_sample(&sample)) or sample == null) return error.SampleFailed;
        defer com.release(sample);
        if (!com.succeeded(self.api.create_mem_buf(@intCast(au_bytes.len), &in_buf)) or in_buf == null) return error.MemBufFailed;
        defer com.release(in_buf);

        const lock_in = com.slot(in_buf.?, 3, *const fn (*anyopaque, *[*]u8, ?*DWORD, ?*DWORD) callconv(.winapi) HRESULT);
        const unlock_in = com.slot(in_buf.?, 4, *const fn (*anyopaque) callconv(.winapi) HRESULT);
        const set_len = com.slot(in_buf.?, 6, *const fn (*anyopaque, DWORD) callconv(.winapi) HRESULT);
        var dst: [*]u8 = undefined;
        if (com.succeeded(lock_in(in_buf.?, &dst, null, null))) {
            @memcpy(dst[0..au_bytes.len], au_bytes);
            _ = unlock_in(in_buf.?);
            _ = set_len(in_buf.?, @intCast(au_bytes.len));
        }
        const add_buf = com.slot(sample.?, 42, *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT);
        _ = add_buf(sample.?, in_buf.?);
        const set_time = com.slot(sample.?, 36, *const fn (*anyopaque, i64) callconv(.winapi) HRESULT);
        _ = set_time(sample.?, pts_us * 10);

        const proc_in = com.slot(mft, 24, *const fn (*anyopaque, DWORD, *anyopaque, DWORD) callconv(.winapi) HRESULT);
        var pre_frame: ?media_if.CaptureFrame = null;
        if (self.async.active()) {
            self.async.pump(0, false, false);
            if (self.async.have_output > 0) {
                pre_frame = self.pullDecoded(pts_us, 0) catch null;
            }
            if (self.async.need_input == 0) {
                self.async.pump(4, true, false);
            }
        }
        const hr_in = proc_in(mft, self.in_id, sample.?, 0);
        if (com.succeeded(hr_in)) {
            if (self.async.active()) self.async.need_input -|= 1;
        } else {
            self.last_hr = hr_in;
            if (pre_frame == null) pre_frame = self.pullDecoded(pts_us, 2) catch null;
            if (self.async.active() and self.async.need_input == 0) {
                self.async.pump(4, true, false);
            }
            if (com.succeeded(proc_in(mft, self.in_id, sample.?, 0))) {
                if (self.async.active()) self.async.need_input -|= 1;
            }
        }

        const post = try self.pullDecoded(pts_us, 6);
        return post orelse pre_frame;
    }

    pub fn drain(self: *HwDecoder, send_cmd: bool) !?media_if.CaptureFrame {
        const mft = self.mft orelse return null;
        if (send_cmd) {
            const proc_msg = com.slot(mft, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
            _ = proc_msg(mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
        }
        return try self.pullDecoded(0, 40);
    }

    fn pullDecoded(self: *HwDecoder, pts_us: i64, wait_ms: u32) !?media_if.CaptureFrame {
        const mft = self.mft orelse return null;
        const proc_out = com.slot(mft, 25, *const fn (*anyopaque, DWORD, DWORD, [*]MFT_OUTPUT_DATA_BUFFER, *DWORD) callconv(.winapi) HRESULT);
        var attempt: u8 = 0;
        var skip_wait = false;
        var cur_wait = wait_ms;
        var latest: ?media_if.CaptureFrame = null;
        while (attempt < 6) : (attempt += 1) {
            if (self.async.active() and !skip_wait) {
                self.async.pump(cur_wait, false, cur_wait > 0);
                if (self.async.have_output == 0) break;
                self.async.have_output -|= 1;
            }
            cur_wait = 0;
            skip_wait = false;
            if (!self.provides_samples) if (self.out_sample) |os| {
                var reset_buf: ?*anyopaque = null;
                const to_c = com.slot(os, 41, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
                if (com.succeeded(to_c(os, &reset_buf)) and reset_buf != null) {
                    const reset_len = com.slot(reset_buf.?, 6, *const fn (*anyopaque, DWORD) callconv(.winapi) HRESULT);
                    _ = reset_len(reset_buf.?, 0);
                    com.release(reset_buf);
                }
            };
            var odb: MFT_OUTPUT_DATA_BUFFER = .{
                .dwStreamID = self.out_id,
                .pSample = if (self.provides_samples) null else self.out_sample,
            };
            var status: DWORD = 0;
            const hr = proc_out(mft, 0, 1, @ptrCast(&odb), &status);
            defer com.release(odb.pEvents);
            if (hr == com.MF_E_TRANSFORM_STREAM_CHANGE) {
                if (self.provides_samples and odb.pSample != null) com.release(odb.pSample);
                try self.negotiateOutputNv12();
                skip_wait = true;
                continue;
            }
            defer if (self.provides_samples and odb.pSample != null) com.release(odb.pSample);
            self.last_hr = hr;
            if (hr == com.MF_E_TRANSFORM_NEED_MORE_INPUT or !com.succeeded(hr)) break;
            const os = odb.pSample orelse break;

            var contig: ?*anyopaque = null;
            const to_contig = com.slot(os, 41, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(to_contig(os, &contig)) or contig == null) break;
            defer com.release(contig);

            const lock_out = com.slot(contig.?, 3, *const fn (*anyopaque, *[*]const u8, ?*DWORD, *DWORD) callconv(.winapi) HRESULT);
            const unlock_out = com.slot(contig.?, 4, *const fn (*anyopaque) callconv(.winapi) HRESULT);
            var ptr: [*]const u8 = undefined;
            var cur_len: DWORD = 0;
            if (!com.succeeded(lock_out(contig.?, &ptr, null, &cur_len)) or cur_len == 0) break;
            defer _ = unlock_out(contig.?);

            const wu: usize = self.w;
            const hu: usize = self.h;
            const eff_stride: usize = @max(@as(usize, self.stride), wu);
            const need = video_cfg.nv12ByteSize(self.w, self.h);
            if (cur_len < need) break;
            if (self.nv12_buf.len != need) {
                if (self.nv12_buf.len > 0) std.heap.page_allocator.free(self.nv12_buf);
                self.nv12_buf = try std.heap.page_allocator.alloc(u8, need);
            }
            const y_len = wu * hu;
            if (eff_stride == wu and cur_len == need) {
                @memcpy(self.nv12_buf, ptr[0..need]);
            } else {
                const aligned_h = (hu + 15) & ~@as(usize, 15);
                const coded_h: usize = if ((hu & 15) != 0 and cur_len >= eff_stride * (aligned_h + hu / 2))
                    aligned_h
                else
                    hu;
                if (cur_len < eff_stride * (coded_h + hu / 2)) break;
                var row: usize = 0;
                while (row < hu) : (row += 1) {
                    @memcpy(self.nv12_buf[row * wu ..][0..wu], ptr[row * eff_stride ..][0..wu]);
                }
                const uv_src = eff_stride * coded_h;
                row = 0;
                while (row < hu / 2) : (row += 1) {
                    @memcpy(self.nv12_buf[y_len + row * wu ..][0..wu], ptr[uv_src + row * eff_stride ..][0..wu]);
                }
            }
            latest = .{
                .width = self.w,
                .height = self.h,
                .nv12_y = self.nv12_buf[0..y_len],
                .nv12_uv = self.nv12_buf[y_len..need],
                .y_pitch = self.w,
                .uv_pitch = self.w,
                .pts_us = pts_us,
            };
            if (!self.async.active()) break;
        }
        return latest;
    }

    pub fn deinit(self: *HwDecoder) void {
        if (self.mft) |mft| {
            const proc_msg = com.slot(mft, 23, *const fn (*anyopaque, UINT, usize) callconv(.winapi) HRESULT);
            _ = proc_msg(mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            _ = proc_msg(mft, MFT_MESSAGE_COMMAND_FLUSH, 0);
        }
        self.async.deinit();
        if (self.nv12_buf.len > 0) {
            std.heap.page_allocator.free(self.nv12_buf);
            self.nv12_buf = &.{};
        }
        com.release(self.out_sample);
        com.release(self.dxgi_mgr);
        com.release(self.mft);
        self.out_sample = null;
        self.dxgi_mgr = null;
        self.mft = null;
        self.api.close();
        if (self.owned_d3d11_ctx) |ctx| {
            com.release(ctx);
            self.owned_d3d11_ctx = null;
        }
        if (self.owned_d3d11_dev) |dev| {
            com.release(dev);
            self.owned_d3d11_dev = null;
        }
        if (self.owned_d3d11_dll) |dll| {
            c.SDL_UnloadObject(dll);
            self.owned_d3d11_dll = null;
        }
        if (self.timer_on) {
            self.timer_on = false;
            sys.endHiResTimer();
        }
    }
};

/// Embrulha uma textura NV12 `ID3D11Texture2D` direto como `SDL_Texture*` quando o
/// backend SDL3 for `direct3d11` (zero-copy absoluto GPU->Tela).
pub fn wrapD3d11TextureForSdl(renderer: *c.SDL_Renderer, d3d11_nv12_tex: *anyopaque, w: u16, h: u16) ?*c.SDL_Texture {
    const rname = c.SDL_GetRendererName(renderer) orelse return null;
    if (!std.mem.eql(u8, std.mem.span(rname), "direct3d11")) return null;

    const props = c.SDL_CreateProperties();
    if (props == 0) return null;
    defer c.SDL_DestroyProperties(props);

    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER, c.SDL_PIXELFORMAT_NV12);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER, c.SDL_TEXTUREACCESS_STREAMING);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, w);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, h);
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_TEXTURE_CREATE_D3D11_TEXTURE_POINTER, d3d11_nv12_tex);
    return c.SDL_CreateTextureWithProperties(renderer, props);
}
