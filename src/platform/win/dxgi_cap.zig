//! Captura de monitor por DXGI Desktop Duplication + conversor GPU BGRA->NV12
//! (ID3D11VideoProcessor) com carregamento dinâmico de `d3d11.dll` e `dxgi.dll`.
const std = @import("std");
const c = @import("c");
const com = @import("com.zig");
const media_if = @import("../media_if.zig");
const video_cfg = @import("../../core/video_cfg.zig");

const RECT = com.RECT;
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const UINT = com.UINT;
const DWORD = com.DWORD;
const BOOL = com.BOOL;

const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: UINT,
    DeviceId: UINT,
    SubSysId: UINT,
    Revision: UINT,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: com.LUID,
    Flags: UINT,
};

const DXGI_OUTPUT_DESC = extern struct {
    DeviceName: [32]u16,
    DesktopCoordinates: RECT,
    AttachedToDesktop: BOOL,
    Rotation: UINT,
    Monitor: com.HMONITOR,
};

const DXGI_OUTDUPL_FRAME_INFO = extern struct {
    LastPresentTime: i64,
    LastMouseUpdateTime: i64,
    AccumulatedFrames: UINT,
    RectsCoalesced: BOOL,
    ProtectedContentMaskedOut: BOOL,
    PointerPosX: i32,
    PointerPosY: i32,
    PointerVisible: BOOL,
    TotalMetadataBufferSize: UINT,
    PointerShapeBufferSize: UINT,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT = 0,
    Height: UINT = 0,
    MipLevels: UINT = 1,
    ArraySize: UINT = 1,
    Format: UINT = com.DXGI_FORMAT_B8G8R8A8_UNORM,
    SampleCount: UINT = 1,
    SampleQuality: UINT = 0,
    Usage: UINT = com.D3D11_USAGE_DEFAULT,
    BindFlags: UINT = 0,
    CPUAccessFlags: UINT = 0,
    MiscFlags: UINT = 0,
};

const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: UINT = 0,
    DepthPitch: UINT = 0,
};

const D3D11_VIDEO_PROCESSOR_CONTENT_DESC = extern struct {
    InputFrameFormat: UINT = 0,
    InputFrameRateNum: UINT = 60,
    InputFrameRateDen: UINT = 1,
    InputWidth: UINT = 0,
    InputHeight: UINT = 0,
    OutputFrameRateNum: UINT = 60,
    OutputFrameRateDen: UINT = 1,
    OutputWidth: UINT = 0,
    OutputHeight: UINT = 0,
    Usage: UINT = 0,
};

const D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC = extern struct {
    FourCC: UINT = 0,
    ViewDimension: UINT = 1,
    MipSlice: UINT = 0,
    ArraySlice: UINT = 0,
};

const D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC = extern struct {
    ViewDimension: UINT = 1,
    MipSlice: UINT = 0,
    ArraySlice: UINT = 0,
    ArraySize: UINT = 0,
};

const D3D11_VIDEO_PROCESSOR_STREAM = extern struct {
    Enable: BOOL = 1,
    OutputIndex: UINT = 0,
    InputFrameOrField: UINT = 0,
    PastFrames: UINT = 0,
    FutureFrames: UINT = 0,
    ppPastSurfaces: ?*anyopaque = null,
    pInputSurface: ?*anyopaque = null,
    ppFutureSurfaces: ?*anyopaque = null,
    ppPastSurfacesRight: ?*anyopaque = null,
    pInputSurfaceRight: ?*anyopaque = null,
    ppFutureSurfacesRight: ?*anyopaque = null,
};

const CreateDXGIFactory1Fn = *const fn (*const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const D3D11CreateDeviceFn = *const fn (
    ?*anyopaque,
    UINT,
    ?*anyopaque,
    UINT,
    ?[*]const UINT,
    UINT,
    UINT,
    *?*anyopaque,
    *UINT,
    *?*anyopaque,
) callconv(.winapi) HRESULT;

pub fn loadDxgi() ?*c.SDL_SharedObject {
    return c.SDL_LoadObject("dxgi.dll");
}

pub fn loadD3d11() ?*c.SDL_SharedObject {
    return c.SDL_LoadObject("d3d11.dll");
}

/// Lista todos os monitores conectados sem alocar memória permanente.
pub fn enumerateDisplays(out: []media_if.DisplayTarget) usize {
    const dxgi = loadDxgi() orelse return 0;
    defer c.SDL_UnloadObject(dxgi);

    const create_fn: CreateDXGIFactory1Fn = @ptrCast(@alignCast(c.SDL_LoadFunction(dxgi, "CreateDXGIFactory1") orelse return 0));
    var factory: ?*anyopaque = null;
    if (!com.succeeded(create_fn(&com.IID_IDXGIFactory1, &factory))) return 0;
    const fac = factory orelse return 0;
    defer com.release(fac);

    const enum_adapters1 = com.slot(fac, 12, *const fn (*anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
    var count: usize = 0;
    var ai: UINT = 0;
    while (count < out.len) : (ai += 1) {
        var adapter: ?*anyopaque = null;
        if (!com.succeeded(enum_adapters1(fac, ai, &adapter))) break;
        const adp = adapter orelse break;
        defer com.release(adp);

        const enum_outputs = com.slot(adp, 7, *const fn (*anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
        var oi: UINT = 0;
        while (count < out.len) : (oi += 1) {
            var output: ?*anyopaque = null;
            if (!com.succeeded(enum_outputs(adp, oi, &output))) break;
            const op = output orelse break;
            defer com.release(op);

            const get_desc = com.slot(op, 7, *const fn (*anyopaque, *DXGI_OUTPUT_DESC) callconv(.winapi) HRESULT);
            var desc: DXGI_OUTPUT_DESC = undefined;
            if (!com.succeeded(get_desc(op, &desc)) or desc.AttachedToDesktop == 0) continue;

            var tgt: media_if.DisplayTarget = .{
                .adapter_idx = @intCast(ai),
                .output_idx = @intCast(oi),
                .id = (@as(u64, ai) << 16) | oi,
                .hmonitor = if (desc.Monitor) |hm| @intFromPtr(hm) else 0,
                .width = @intCast(@max(desc.DesktopCoordinates.right - desc.DesktopCoordinates.left, 0)),
                .height = @intCast(@max(desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top, 0)),
                .primary = desc.DesktopCoordinates.left == 0 and desc.DesktopCoordinates.top == 0,
            };
            const wlen = std.mem.indexOfScalar(u16, &desc.DeviceName, 0) orelse desc.DeviceName.len;
            const n = std.unicode.utf16LeToUtf8(&tgt.name_buf, desc.DeviceName[0..wlen]) catch 0;
            tgt.name_len = @intCast(n);
            out[count] = tgt;
            count += 1;
        }
    }
    return count;
}

/// Conversor compartilhado BGRA->NV12 em GPU via ID3D11VideoProcessor (também usado por `wgc_cap.zig`).
pub const Nv12GpuCtx = struct {
    dxgi_dll: ?*c.SDL_SharedObject = null,
    d3d11_dll: ?*c.SDL_SharedObject = null,
    device: ?*anyopaque = null,
    ctx: ?*anyopaque = null,
    vdev: ?*anyopaque = null,
    vctx: ?*anyopaque = null,
    v_enum: ?*anyopaque = null,
    v_proc: ?*anyopaque = null,
    nv12_gpu: ?*anyopaque = null,
    nv12_out_view: ?*anyopaque = null,
    nv12_staging: ?*anyopaque = null,
    cpu_scratch: []u8 = &.{},
    in_w: u16 = 0,
    in_h: u16 = 0,
    out_w: u16 = 0,
    out_h: u16 = 0,
    target_res: video_cfg.Resolution = .p2160,

    pub fn init(adapter_idx: u16, target_res: video_cfg.Resolution) !Nv12GpuCtx {
        var self: Nv12GpuCtx = .{ .target_res = target_res };
        errdefer self.deinit();

        self.dxgi_dll = loadDxgi() orelse return error.DxgiMissing;
        self.d3d11_dll = loadD3d11() orelse return error.D3d11Missing;

        var chosen_adapter: ?*anyopaque = null;
        defer com.release(chosen_adapter);
        if (com.succeeded(openAdapter(self.dxgi_dll.?, adapter_idx, &chosen_adapter))) {}

        const create_dev: D3D11CreateDeviceFn = @ptrCast(@alignCast(c.SDL_LoadFunction(self.d3d11_dll.?, "D3D11CreateDevice") orelse return error.D3d11FnMissing));
        const flags: UINT = com.D3D11_CREATE_DEVICE_BGRA_SUPPORT | com.D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
        const drv_type: UINT = if (chosen_adapter != null) 0 else 1; // UNKNOWN with adapter, HARDWARE otherwise
        const levels = [_]UINT{ 0xB100, 0xB000, 0xA100 }; // 11.1, 11.0, 10.1
        var fl: UINT = 0;

        var hr = create_dev(chosen_adapter, drv_type, null, flags, &levels, levels.len, 7, &self.device, &fl, &self.ctx);
        if (!com.succeeded(hr)) {
            hr = create_dev(chosen_adapter, drv_type, null, com.D3D11_CREATE_DEVICE_BGRA_SUPPORT, &levels, levels.len, 7, &self.device, &fl, &self.ctx);
        }
        if (!com.succeeded(hr) or self.device == null or self.ctx == null) return error.D3d11CreateFailed;

        // Habilita proteção multithread para compartilhamento seguro com Media Foundation.
        if (com.queryInterface(self.device.?, com.IUnknown, &com.IID_ID3D11Multithread)) |mt| {
            defer com.release(mt);
            const set_mt = com.slot(mt, 5, *const fn (*anyopaque, BOOL) callconv(.winapi) BOOL);
            _ = set_mt(mt, 1);
        }

        self.vdev = com.queryInterface(self.device.?, anyopaque, &com.IID_ID3D11VideoDevice);
        self.vctx = com.queryInterface(self.ctx.?, anyopaque, &com.IID_ID3D11VideoContext);
        return self;
    }

    pub fn convertBgraToNv12(
        self: *Nv12GpuCtx,
        src_tex: *anyopaque,
        src_w: u16,
        src_h: u16,
        want_cpu_copy: bool,
        pts_us: i64,
    ) !media_if.CaptureFrame {
        const cap = self.target_res.dims();
        const dst_sizes = fitEven(src_w, src_h, @intCast(cap[0]), @intCast(cap[1]));
        try self.ensurePipeline(src_w, src_h, dst_sizes[0], dst_sizes[1], want_cpu_copy);

        const vdev = self.vdev orelse return error.NoVideoDevice;
        const vctx = self.vctx orelse return error.NoVideoContext;
        const v_enum = self.v_enum orelse return error.NoVideoEnum;
        const v_proc = self.v_proc orelse return error.NoVideoProc;
        const out_view = self.nv12_out_view orelse return error.NoOutView;
        const nv12_tex = self.nv12_gpu orelse return error.NoOutTex;

        // Cria InputView efêmera para a textura BGRA atual (O(1) no driver, sem cópia de memória).
        const create_iv = com.slot(vdev, 8, *const fn (*anyopaque, *anyopaque, *anyopaque, *const D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, *?*anyopaque) callconv(.winapi) HRESULT);
        var iv_desc: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC = .{};
        var in_view: ?*anyopaque = null;
        if (!com.succeeded(create_iv(vdev, src_tex, v_enum, &iv_desc, &in_view)) or in_view == null) {
            return error.CreateInputViewFailed;
        }
        defer com.release(in_view);

        var stream: D3D11_VIDEO_PROCESSOR_STREAM = .{
            .Enable = 1,
            .pInputSurface = in_view,
        };
        const blt = com.slot(vctx, 53, *const fn (*anyopaque, *anyopaque, *anyopaque, UINT, UINT, [*]const D3D11_VIDEO_PROCESSOR_STREAM) callconv(.winapi) HRESULT);
        if (!com.succeeded(blt(vctx, v_proc, out_view, 0, 1, @ptrCast(&stream)))) {
            return error.VideoProcessorBltFailed;
        }

        var frame: media_if.CaptureFrame = .{
            .width = self.out_w,
            .height = self.out_h,
            .gpu_tex = nv12_tex,
            .pts_us = pts_us,
        };

        if (want_cpu_copy) {
            try self.readbackNv12(&frame);
        }
        return frame;
    }

    fn readbackNv12(self: *Nv12GpuCtx, frame: *media_if.CaptureFrame) !void {
        const d3d_ctx = self.ctx orelse return error.NoContext;
        const staging = self.nv12_staging orelse return error.NoStaging;
        const gpu = self.nv12_gpu orelse return error.NoOutTex;

        const copy_res = com.slot(d3d_ctx, 47, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
        copy_res(d3d_ctx, staging, gpu);

        const map_fn = com.slot(d3d_ctx, 14, *const fn (*anyopaque, *anyopaque, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT);
        const unmap_fn = com.slot(d3d_ctx, 15, *const fn (*anyopaque, *anyopaque, UINT) callconv(.winapi) void);
        var mapped: D3D11_MAPPED_SUBRESOURCE = .{};
        if (!com.succeeded(map_fn(d3d_ctx, staging, 0, 1, 0, &mapped)) or mapped.pData == null) {
            return error.MapFailed;
        }
        defer unmap_fn(d3d_ctx, staging, 0);

        const total = video_cfg.nv12ByteSize(self.out_w, self.out_h);
        if (self.cpu_scratch.len != total) {
            if (self.cpu_scratch.len > 0) std.heap.page_allocator.free(self.cpu_scratch);
            self.cpu_scratch = try std.heap.page_allocator.alloc(u8, total);
        }

        const wu: usize = self.out_w;
        const hu: usize = self.out_h;
        const pitch: usize = mapped.RowPitch;
        const src: [*]const u8 = @ptrCast(mapped.pData.?);
        const y_len = wu * hu;

        var row: usize = 0;
        while (row < hu) : (row += 1) {
            @memcpy(self.cpu_scratch[row * wu ..][0..wu], src[row * pitch ..][0..wu]);
        }
        const uv_h = hu / 2;
        const src_uv = src + hu * pitch;
        row = 0;
        while (row < uv_h) : (row += 1) {
            @memcpy(self.cpu_scratch[y_len + row * wu ..][0..wu], src_uv[row * pitch ..][0..wu]);
        }

        frame.nv12_y = self.cpu_scratch[0..y_len];
        frame.nv12_uv = self.cpu_scratch[y_len..total];
        frame.y_pitch = self.out_w;
        frame.uv_pitch = self.out_w;
    }

    fn ensurePipeline(self: *Nv12GpuCtx, in_w: u16, in_h: u16, out_w: u16, out_h: u16, want_staging: bool) !void {
        const need_rebuild = self.v_proc == null or self.in_w != in_w or self.in_h != in_h or self.out_w != out_w or self.out_h != out_h;
        const dev = self.device orelse return error.NoDevice;
        const vdev = self.vdev orelse return error.NoVideoDevice;

        if (need_rebuild) {
            com.release(self.nv12_out_view);
            self.nv12_out_view = null;
            com.release(self.nv12_gpu);
            self.nv12_gpu = null;
            com.release(self.nv12_staging);
            self.nv12_staging = null;
            com.release(self.v_proc);
            self.v_proc = null;
            com.release(self.v_enum);
            self.v_enum = null;

            var cdesc: D3D11_VIDEO_PROCESSOR_CONTENT_DESC = .{
                .InputWidth = in_w,
                .InputHeight = in_h,
                .OutputWidth = out_w,
                .OutputHeight = out_h,
            };
            const create_enum = com.slot(vdev, 10, *const fn (*anyopaque, *const D3D11_VIDEO_PROCESSOR_CONTENT_DESC, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(create_enum(vdev, &cdesc, &self.v_enum)) or self.v_enum == null) return error.VideoEnumFailed;

            const create_proc = com.slot(vdev, 4, *const fn (*anyopaque, *anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(create_proc(vdev, self.v_enum.?, 0, &self.v_proc)) or self.v_proc == null) return error.VideoProcFailed;

            var tdesc: D3D11_TEXTURE2D_DESC = .{
                .Width = out_w,
                .Height = out_h,
                .Format = com.DXGI_FORMAT_NV12,
                .Usage = com.D3D11_USAGE_DEFAULT,
                .BindFlags = com.D3D11_BIND_RENDER_TARGET | com.D3D11_BIND_SHADER_RESOURCE | com.D3D11_BIND_VIDEO_ENCODER,
            };
            const create_tex = com.slot(dev, 5, *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(create_tex(dev, &tdesc, null, &self.nv12_gpu)) or self.nv12_gpu == null) {
                tdesc.BindFlags = com.D3D11_BIND_RENDER_TARGET | com.D3D11_BIND_SHADER_RESOURCE;
                if (!com.succeeded(create_tex(dev, &tdesc, null, &self.nv12_gpu)) or self.nv12_gpu == null) return error.CreateNv12TexFailed;
            }

            var ov_desc: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC = .{};
            const create_ov = com.slot(vdev, 9, *const fn (*anyopaque, *anyopaque, *anyopaque, *const D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(create_ov(vdev, self.nv12_gpu.?, self.v_enum.?, &ov_desc, &self.nv12_out_view)) or self.nv12_out_view == null) {
                return error.CreateOutViewFailed;
            }

            self.in_w = in_w;
            self.in_h = in_h;
            self.out_w = out_w;
            self.out_h = out_h;
        }

        if (want_cpu_copy_needed(want_staging, self.nv12_staging)) {
            var sdesc: D3D11_TEXTURE2D_DESC = .{
                .Width = out_w,
                .Height = out_h,
                .Format = com.DXGI_FORMAT_NV12,
                .Usage = com.D3D11_USAGE_STAGING,
                .BindFlags = 0,
                .CPUAccessFlags = com.D3D11_CPU_ACCESS_READ,
            };
            const create_tex = com.slot(dev, 5, *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
            if (!com.succeeded(create_tex(dev, &sdesc, null, &self.nv12_staging)) or self.nv12_staging == null) {
                return error.CreateStagingFailed;
            }
        }
    }

    pub fn deinit(self: *Nv12GpuCtx) void {
        if (self.cpu_scratch.len > 0) {
            std.heap.page_allocator.free(self.cpu_scratch);
            self.cpu_scratch = &.{};
        }
        com.release(self.nv12_staging);
        com.release(self.nv12_out_view);
        com.release(self.nv12_gpu);
        com.release(self.v_proc);
        com.release(self.v_enum);
        com.release(self.vctx);
        com.release(self.vdev);
        com.release(self.ctx);
        com.release(self.device);
        self.nv12_staging = null;
        self.nv12_out_view = null;
        self.nv12_gpu = null;
        self.v_proc = null;
        self.v_enum = null;
        self.vctx = null;
        self.vdev = null;
        self.ctx = null;
        self.device = null;
        if (self.d3d11_dll) |d| c.SDL_UnloadObject(d);
        if (self.dxgi_dll) |x| c.SDL_UnloadObject(x);
        self.d3d11_dll = null;
        self.dxgi_dll = null;
    }
};

fn want_cpu_copy_needed(want: bool, existing: ?*anyopaque) bool {
    return want and existing == null;
}

pub fn fitEven(src_w: u16, src_h: u16, max_w: u16, max_h: u16) [2]u16 {
    if (src_w <= max_w and src_h <= max_h) {
        return .{ @max(src_w & ~@as(u16, 1), 2), @max(src_h & ~@as(u16, 1), 2) };
    }
    const sx = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(@max(src_w, 1)));
    const sy = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(@max(src_h, 1)));
    const s = @min(sx, sy);
    const ow: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * s));
    const oh: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * s));
    return .{ @max(ow & ~@as(u16, 1), 2), @max(oh & ~@as(u16, 1), 2) };
}

fn openAdapter(dxgi: *c.SDL_SharedObject, idx: u16, out_adapter: *?*anyopaque) HRESULT {
    const create_fn: CreateDXGIFactory1Fn = @ptrCast(@alignCast(c.SDL_LoadFunction(dxgi, "CreateDXGIFactory1") orelse return -1));
    var factory: ?*anyopaque = null;
    const hr = create_fn(&com.IID_IDXGIFactory1, &factory);
    if (!com.succeeded(hr) or factory == null) return hr;
    defer com.release(factory);
    const enum_adapters1 = com.slot(factory.?, 12, *const fn (*anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
    return enum_adapters1(factory.?, idx, out_adapter);
}

pub const Duplicator = struct {
    gpu: Nv12GpuCtx,
    dupl: ?*anyopaque = null,
    src_w: u16 = 0,
    src_h: u16 = 0,

    pub fn open(display_id: u64, target_res: video_cfg.Resolution) !Duplicator {
        const adapter_idx: u16 = @intCast((display_id >> 16) & 0xFFFF);
        const output_idx: u16 = @intCast(display_id & 0xFFFF);
        var gpu = try Nv12GpuCtx.init(adapter_idx, target_res);
        errdefer gpu.deinit();

        const dxgi_dev = com.queryInterface(gpu.device.?, anyopaque, &com.IID_IDXGIDevice) orelse return error.DxgiDeviceMissing;
        defer com.release(dxgi_dev);
        const get_adapter = com.slot(dxgi_dev, 7, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var adapter: ?*anyopaque = null;
        if (!com.succeeded(get_adapter(dxgi_dev, &adapter)) or adapter == null) return error.AdapterMissing;
        defer com.release(adapter);

        const enum_outputs = com.slot(adapter.?, 7, *const fn (*anyopaque, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
        var output: ?*anyopaque = null;
        if (!com.succeeded(enum_outputs(adapter.?, output_idx, &output)) or output == null) return error.OutputNotFound;
        defer com.release(output);

        const get_desc = com.slot(output.?, 7, *const fn (*anyopaque, *DXGI_OUTPUT_DESC) callconv(.winapi) HRESULT);
        var desc: DXGI_OUTPUT_DESC = undefined;
        if (!com.succeeded(get_desc(output.?, &desc))) return error.OutputDescFailed;
        const w: u16 = @intCast(@max(desc.DesktopCoordinates.right - desc.DesktopCoordinates.left, 2));
        const h: u16 = @intCast(@max(desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top, 2));

        const out1 = com.queryInterface(output.?, anyopaque, &com.IID_IDXGIOutput1) orelse return error.DxgiOutput1Missing;
        defer com.release(out1);
        const dup_out = com.slot(out1, 22, *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var dupl: ?*anyopaque = null;
        const dup_hr = dup_out(out1, gpu.device.?, &dupl);
        if (!com.succeeded(dup_hr) or dupl == null) {
            std.log.warn("dxgi: DuplicateOutput falhou hr=0x{x:0>8}", .{@as(u32, @bitCast(dup_hr))});
            return error.DuplicateOutputFailed;
        }

        return .{ .gpu = gpu, .dupl = dupl, .src_w = w, .src_h = h };
    }

    pub fn acquireNv12(self: *Duplicator, timeout_ms: u32, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        const dupl = self.dupl orelse return error.NotOpen;
        const acq = com.slot(dupl, 8, *const fn (*anyopaque, UINT, *DXGI_OUTDUPL_FRAME_INFO, *?*anyopaque) callconv(.winapi) HRESULT);
        const rel = com.slot(dupl, 14, *const fn (*anyopaque) callconv(.winapi) HRESULT);

        var info: DXGI_OUTDUPL_FRAME_INFO = std.mem.zeroes(DXGI_OUTDUPL_FRAME_INFO);
        var res: ?*anyopaque = null;
        const hr = acq(dupl, timeout_ms, &info, &res);
        if (hr == com.DXGI_ERROR_WAIT_TIMEOUT) return null;
        if (hr == com.DXGI_ERROR_ACCESS_LOST) return error.AccessLost;
        if (!com.succeeded(hr) or res == null) return error.AcquireFailed;
        defer _ = rel(dupl);
        defer com.release(res);

        const tex = com.queryInterface(res.?, anyopaque, &com.IID_ID3D11Texture2D) orelse return null;
        defer com.release(tex);

        return try self.gpu.convertBgraToNv12(tex, self.src_w, self.src_h, want_cpu_copy, pts_us);
    }

    pub fn deinit(self: *Duplicator) void {
        com.release(self.dupl);
        self.dupl = null;
        self.gpu.deinit();
    }
};
