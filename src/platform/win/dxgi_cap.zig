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

const DXGI_OUTDUPL_POINTER_SHAPE_INFO = extern struct {
    Type: UINT = 0, // 1=MONOCHROME, 2=COLOR, 4=MASKED_COLOR
    Width: UINT = 0,
    Height: UINT = 0,
    Pitch: UINT = 0,
    HotSpot: com.POINT = .{},
};

const D3D11_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT = 0,
    right: UINT,
    bottom: UINT,
    back: UINT = 1,
};

const CURSORINFO = extern struct {
    cbSize: DWORD = @sizeOf(CURSORINFO),
    flags: DWORD = 0,
    hCursor: ?*anyopaque = null,
    ptScreenPos: com.POINT = .{},
};

const GetCursorInfoFn = *const fn (*CURSORINFO) callconv(.winapi) BOOL;

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

/// Converte UTF-16LE para UTF-8 truncando no último codepoint inteiro que couber em `out`.
pub fn utf16ToUtf8Truncated(out: []u8, in_u16: []const u16) usize {
    var oi: usize = 0;
    var ii: usize = 0;
    while (ii < in_u16.len) {
        const w0 = in_u16[ii];
        ii += 1;
        var cp: u21 = w0;
        if (w0 >= 0xD800 and w0 <= 0xDBFF and ii < in_u16.len) {
            const w1 = in_u16[ii];
            if (w1 >= 0xDC00 and w1 <= 0xDFFF) {
                ii += 1;
                cp = 0x10000 + ((@as(u21, w0 - 0xD800) << 10) | @as(u21, w1 - 0xDC00));
            } else {
                cp = 0xFFFD;
            }
        } else if (w0 >= 0xDC00 and w0 <= 0xDFFF) {
            cp = 0xFFFD;
        }
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch continue;
        if (oi + n > out.len) break;
        @memcpy(out[oi..][0..n], enc[0..n]);
        oi += n;
    }
    return oi;
}

/// Lista todos os monitores conectados sem alocar memória permanente, com o principal primeiro.
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
                .left = desc.DesktopCoordinates.left,
                .top = desc.DesktopCoordinates.top,
                .width = @intCast(@max(desc.DesktopCoordinates.right - desc.DesktopCoordinates.left, 0)),
                .height = @intCast(@max(desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top, 0)),
                .primary = desc.DesktopCoordinates.left == 0 and desc.DesktopCoordinates.top == 0,
            };
            const wlen = std.mem.indexOfScalar(u16, &desc.DeviceName, 0) orelse desc.DeviceName.len;
            const n = utf16ToUtf8Truncated(&tgt.name_buf, desc.DeviceName[0..wlen]);
            tgt.name_len = @intCast(n);
            out[count] = tgt;
            count += 1;
        }
    }
    if (count > 1) {
        const Less = struct {
            fn lt(_: void, a: media_if.DisplayTarget, b: media_if.DisplayTarget) bool {
                if (a.primary != b.primary) return a.primary;
                if (a.left != b.left) return a.left < b.left;
                return a.top < b.top;
            }
        };
        std.sort.insertion(media_if.DisplayTarget, out[0..count], {}, Less.lt);
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

    pub fn repeatFrame(self: *Nv12GpuCtx, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        const nv12_tex = self.nv12_gpu orelse return null;
        if (self.out_w < 2 or self.out_h < 2) return null;
        var frame: media_if.CaptureFrame = .{
            .width = self.out_w,
            .height = self.out_h,
            .gpu_tex = nv12_tex,
            .pts_us = pts_us,
        };
        if (want_cpu_copy) {
            const total = video_cfg.nv12ByteSize(self.out_w, self.out_h);
            const y_len = @as(usize, self.out_w) * @as(usize, self.out_h);
            if (self.cpu_scratch.len == total) {
                frame.nv12_y = self.cpu_scratch[0..y_len];
                frame.nv12_uv = self.cpu_scratch[y_len..total];
                frame.y_pitch = self.out_w;
                frame.uv_pitch = self.out_w;
            } else {
                try self.ensureStaging();
                try self.readbackNv12(&frame);
            }
        }
        return frame;
    }

    fn ensureStaging(self: *Nv12GpuCtx) !void {
        if (self.nv12_staging != null) return;
        const dev = self.device orelse return error.NoDevice;
        var sdesc: D3D11_TEXTURE2D_DESC = .{
            .Width = self.out_w,
            .Height = self.out_h,
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
    user32_dll: ?*c.SDL_SharedObject = null,
    get_cursor_info: ?GetCursorInfoFn = null,
    src_w: u16 = 0,
    src_h: u16 = 0,
    desktop_left: i32 = 0,
    desktop_top: i32 = 0,
    cursor_enabled: bool = true,
    cursor_visible: bool = false,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_has_shape: bool = false,
    cursor_info: DXGI_OUTDUPL_POINTER_SHAPE_INFO = .{},
    cursor_shape: []u8 = &.{},
    has_desktop: bool = false,
    clean_bgra: ?*anyopaque = null,
    comp_bgra: ?*anyopaque = null,
    patch_staging: ?*anyopaque = null,
    patch_cap_w: u16 = 0,
    patch_cap_h: u16 = 0,
    patch_scratch: []u8 = &.{},

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

        const u32_dll = c.SDL_LoadObject("user32.dll");
        const gci: ?GetCursorInfoFn = if (u32_dll) |u|
            if (c.SDL_LoadFunction(u, "GetCursorInfo")) |fp| @ptrCast(@alignCast(fp)) else null
        else
            null;

        return .{
            .gpu = gpu,
            .dupl = dupl,
            .user32_dll = u32_dll,
            .get_cursor_info = gci,
            .src_w = w,
            .src_h = h,
            .desktop_left = desc.DesktopCoordinates.left,
            .desktop_top = desc.DesktopCoordinates.top,
        };
    }

    pub fn setCursorCapture(self: *Duplicator, enabled: bool) void {
        self.cursor_enabled = enabled;
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

        if (info.LastMouseUpdateTime != 0) {
            self.cursor_visible = info.PointerVisible != 0;
            self.cursor_x = info.PointerPosX;
            self.cursor_y = info.PointerPosY;
        } else if (!self.cursor_has_shape) {
            self.pollOsCursorFallback();
        }

        if (info.PointerShapeBufferSize > 0) {
            self.capturePointerShape(dupl, info.PointerShapeBufferSize);
        }

        const tex = com.queryInterface(res.?, anyopaque, &com.IID_ID3D11Texture2D) orelse return null;
        defer com.release(tex);

        var tdesc: D3D11_TEXTURE2D_DESC = undefined;
        const get_tex_desc = com.slot(tex, 10, *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(.winapi) void);
        get_tex_desc(tex, &tdesc);
        const is_bgra8 = tdesc.Format == com.DXGI_FORMAT_B8G8R8A8_UNORM;

        const d3d_ctx = self.gpu.ctx orelse return error.NoContext;
        const desktop_dirty = info.LastPresentTime != 0 or info.AccumulatedFrames > 0 or !self.has_desktop;
        var base_tex: *anyopaque = tex;

        // Mantém cópia limpa da tela para repintar apenas o ponteiro em atualizações só do mouse.
        if (is_bgra8 and (self.cursor_enabled or self.has_desktop)) {
            if (self.ensureCursorSurfaces()) {
                const copy_res = com.slot(d3d_ctx, 47, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
                if (desktop_dirty) {
                    copy_res(d3d_ctx, self.clean_bgra.?, tex);
                    self.has_desktop = true;
                }
                base_tex = self.clean_bgra.?;
            }
        }

        if (is_bgra8 and self.cursor_enabled and self.cursor_visible) {
            if (self.compositeCursorOnGpu(base_tex)) |comp| {
                return try self.gpu.convertBgraToNv12(comp, self.src_w, self.src_h, want_cpu_copy, pts_us);
            }
        }

        return try self.gpu.convertBgraToNv12(base_tex, self.src_w, self.src_h, want_cpu_copy, pts_us);
    }

    fn pollOsCursorFallback(self: *Duplicator) void {
        const gci = self.get_cursor_info orelse return;
        var ci: CURSORINFO = .{};
        if (gci(&ci) == 0 or (ci.flags & 1) == 0) return;
        const rx = ci.ptScreenPos.x - self.desktop_left;
        const ry = ci.ptScreenPos.y - self.desktop_top;
        if (rx >= 0 and rx < @as(i32, self.src_w) and ry >= 0 and ry < @as(i32, self.src_h)) {
            self.cursor_visible = true;
            self.cursor_x = rx;
            self.cursor_y = ry;
        }
    }

    fn capturePointerShape(self: *Duplicator, dupl: *anyopaque, need_bytes: UINT) void {
        const capped = @min(@as(usize, need_bytes), 256 * 1024);
        if (capped == 0) return;
        if (self.cursor_shape.len < capped) {
            if (self.cursor_shape.len > 0) std.heap.page_allocator.free(self.cursor_shape);
            self.cursor_shape = std.heap.page_allocator.alloc(u8, capped) catch {
                self.cursor_shape = &.{};
                return;
            };
        }
        const get_shape = com.slot(dupl, 11, *const fn (*anyopaque, UINT, *anyopaque, *UINT, *DXGI_OUTDUPL_POINTER_SHAPE_INFO) callconv(.winapi) HRESULT);
        var req: UINT = 0;
        var sinfo: DXGI_OUTDUPL_POINTER_SHAPE_INFO = .{};
        if (com.succeeded(get_shape(dupl, @intCast(self.cursor_shape.len), self.cursor_shape.ptr, &req, &sinfo))) {
            if (sinfo.Width > 0 and sinfo.Height > 0 and sinfo.Pitch > 0) {
                self.cursor_info = sinfo;
                self.cursor_has_shape = true;
            }
        }
    }

    fn ensureCursorSurfaces(self: *Duplicator) bool {
        const dev = self.gpu.device orelse return false;
        const create_tex = com.slot(dev, 5, *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        if (self.clean_bgra == null) {
            const desc: D3D11_TEXTURE2D_DESC = .{
                .Width = self.src_w,
                .Height = self.src_h,
                .Format = com.DXGI_FORMAT_B8G8R8A8_UNORM,
                .Usage = com.D3D11_USAGE_DEFAULT,
                .BindFlags = com.D3D11_BIND_SHADER_RESOURCE,
            };
            if (!com.succeeded(create_tex(dev, &desc, null, &self.clean_bgra)) or self.clean_bgra == null) return false;
        }
        if (self.comp_bgra == null) {
            const desc: D3D11_TEXTURE2D_DESC = .{
                .Width = self.src_w,
                .Height = self.src_h,
                .Format = com.DXGI_FORMAT_B8G8R8A8_UNORM,
                .Usage = com.D3D11_USAGE_DEFAULT,
                .BindFlags = com.D3D11_BIND_SHADER_RESOURCE,
            };
            if (!com.succeeded(create_tex(dev, &desc, null, &self.comp_bgra)) or self.comp_bgra == null) return false;
        }
        return true;
    }

    fn ensurePatchStaging(self: *Duplicator, need_w: u16, need_h: u16) bool {
        if (self.patch_staging != null and self.patch_cap_w >= need_w and self.patch_cap_h >= need_h) return true;
        const dev = self.gpu.device orelse return false;
        const cw: u16 = @max(@as(u16, 64), need_w);
        const ch: u16 = @max(@as(u16, 64), need_h);
        com.release(self.patch_staging);
        self.patch_staging = null;
        const sdesc: D3D11_TEXTURE2D_DESC = .{
            .Width = cw,
            .Height = ch,
            .Format = com.DXGI_FORMAT_B8G8R8A8_UNORM,
            .Usage = com.D3D11_USAGE_STAGING,
            .BindFlags = 0,
            .CPUAccessFlags = com.D3D11_CPU_ACCESS_READ,
        };
        const create_tex = com.slot(dev, 5, *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(create_tex(dev, &sdesc, null, &self.patch_staging)) or self.patch_staging == null) return false;
        self.patch_cap_w = cw;
        self.patch_cap_h = ch;

        const need_bytes = @as(usize, cw) * @as(usize, ch) * 4;
        if (self.patch_scratch.len < need_bytes) {
            if (self.patch_scratch.len > 0) std.heap.page_allocator.free(self.patch_scratch);
            self.patch_scratch = std.heap.page_allocator.alloc(u8, need_bytes) catch {
                self.patch_scratch = &.{};
                return false;
            };
        }
        return true;
    }

    fn compositeCursorOnGpu(self: *Duplicator, base_tex: *anyopaque) ?*anyopaque {
        const comp = self.comp_bgra orelse return null;
        const d3d_ctx = self.gpu.ctx orelse return null;

        const sw_raw: u32 = if (self.cursor_has_shape) self.cursor_info.Width else 14;
        const sh_raw: u32 = if (self.cursor_has_shape)
            (if (self.cursor_info.Type == 1) self.cursor_info.Height / 2 else self.cursor_info.Height)
        else
            20;
        if (sw_raw == 0 or sh_raw == 0 or sw_raw > 256 or sh_raw > 256) return null;

        const x0 = @max(self.cursor_x, 0);
        const y0 = @max(self.cursor_y, 0);
        const x1 = @min(self.cursor_x + @as(i32, @intCast(sw_raw)), @as(i32, self.src_w));
        const y1 = @min(self.cursor_y + @as(i32, @intCast(sh_raw)), @as(i32, self.src_h));
        if (x1 <= x0 or y1 <= y0) return null;

        const bw: u16 = @intCast(x1 - x0);
        const bh: u16 = @intCast(y1 - y0);
        if (!self.ensurePatchStaging(bw, bh)) return null;
        const staging = self.patch_staging orelse return null;

        const copy_res = com.slot(d3d_ctx, 47, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
        copy_res(d3d_ctx, comp, base_tex);

        const box: D3D11_BOX = .{
            .left = @intCast(x0),
            .top = @intCast(y0),
            .right = @intCast(x1),
            .bottom = @intCast(y1),
        };
        const copy_sub = com.slot(d3d_ctx, 46, *const fn (*anyopaque, *anyopaque, UINT, UINT, UINT, UINT, *anyopaque, UINT, ?*const D3D11_BOX) callconv(.winapi) void);
        copy_sub(d3d_ctx, staging, 0, 0, 0, 0, base_tex, 0, &box);

        const map_fn = com.slot(d3d_ctx, 14, *const fn (*anyopaque, *anyopaque, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT);
        const unmap_fn = com.slot(d3d_ctx, 15, *const fn (*anyopaque, *anyopaque, UINT) callconv(.winapi) void);
        var mapped: D3D11_MAPPED_SUBRESOURCE = .{};
        if (!com.succeeded(map_fn(d3d_ctx, staging, 0, 1, 0, &mapped)) or mapped.pData == null) return null;

        const src_ptr: [*]const u8 = @ptrCast(mapped.pData.?);
        const row_bytes = @as(usize, bw) * 4;
        var r: usize = 0;
        while (r < bh) : (r += 1) {
            @memcpy(self.patch_scratch[r * row_bytes ..][0..row_bytes], src_ptr[r * mapped.RowPitch ..][0..row_bytes]);
        }
        unmap_fn(d3d_ctx, staging, 0);

        self.blendCursorIntoPatch(self.patch_scratch[0 .. @as(usize, bh) * row_bytes], x0 - self.cursor_x, y0 - self.cursor_y, bw, bh, row_bytes);

        const upd_sub = com.slot(d3d_ctx, 48, *const fn (*anyopaque, *anyopaque, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(.winapi) void);
        upd_sub(d3d_ctx, comp, 0, &box, self.patch_scratch.ptr, @intCast(row_bytes), 0);
        return comp;
    }

    fn blendCursorIntoPatch(self: *const Duplicator, patch: []u8, clip_x: i32, clip_y: i32, bw: u16, bh: u16, dst_pitch: usize) void {
        if (!self.cursor_has_shape) {
            drawFallbackArrow(patch, clip_x, clip_y, bw, bh, dst_pitch);
            return;
        }
        const pitch = self.cursor_info.Pitch;
        const sh_mono_h = self.cursor_info.Height / 2;
        var dy: usize = 0;
        while (dy < bh) : (dy += 1) {
            const sy: usize = @intCast(clip_y + @as(i32, @intCast(dy)));
            var dx: usize = 0;
            while (dx < bw) : (dx += 1) {
                const sx: usize = @intCast(clip_x + @as(i32, @intCast(dx)));
                const doff = dy * dst_pitch + dx * 4;
                switch (self.cursor_info.Type) {
                    1 => {
                        if (sy >= sh_mono_h) continue;
                        const and_off = sy * pitch + (sx >> 3);
                        const xor_off = (sy + sh_mono_h) * pitch + (sx >> 3);
                        if (xor_off >= self.cursor_shape.len) continue;
                        const bit_mask: u8 = @as(u8, 0x80) >> @as(u3, @intCast(sx & 7));
                        const and_bit = (self.cursor_shape[and_off] & bit_mask) != 0;
                        const xor_bit = (self.cursor_shape[xor_off] & bit_mask) != 0;
                        if (!and_bit and !xor_bit) {
                            patch[doff] = 0;
                            patch[doff + 1] = 0;
                            patch[doff + 2] = 0;
                            patch[doff + 3] = 255;
                        } else if (!and_bit and xor_bit) {
                            patch[doff] = 255;
                            patch[doff + 1] = 255;
                            patch[doff + 2] = 255;
                            patch[doff + 3] = 255;
                        } else if (and_bit and xor_bit) {
                            patch[doff] ^= 0xFF;
                            patch[doff + 1] ^= 0xFF;
                            patch[doff + 2] ^= 0xFF;
                            patch[doff + 3] = 255;
                        }
                    },
                    2 => {
                        const soff = sy * pitch + sx * 4;
                        if (soff + 3 >= self.cursor_shape.len) continue;
                        const fg_b = self.cursor_shape[soff];
                        const fg_g = self.cursor_shape[soff + 1];
                        const fg_r = self.cursor_shape[soff + 2];
                        const fg_a = self.cursor_shape[soff + 3];
                        if (fg_a == 0) continue;
                        if (fg_a == 255) {
                            patch[doff] = fg_b;
                            patch[doff + 1] = fg_g;
                            patch[doff + 2] = fg_r;
                            patch[doff + 3] = 255;
                        } else {
                            const inv: u16 = 255 - fg_a;
                            patch[doff] = @min(@as(u16, 255), @as(u16, fg_b) + (@as(u16, patch[doff]) * inv + 127) / 255);
                            patch[doff + 1] = @min(@as(u16, 255), @as(u16, fg_g) + (@as(u16, patch[doff + 1]) * inv + 127) / 255);
                            patch[doff + 2] = @min(@as(u16, 255), @as(u16, fg_r) + (@as(u16, patch[doff + 2]) * inv + 127) / 255);
                            patch[doff + 3] = 255;
                        }
                    },
                    4 => {
                        const soff = sy * pitch + sx * 4;
                        if (soff + 3 >= self.cursor_shape.len) continue;
                        const fg_b = self.cursor_shape[soff];
                        const fg_g = self.cursor_shape[soff + 1];
                        const fg_r = self.cursor_shape[soff + 2];
                        const mask = self.cursor_shape[soff + 3];
                        if (mask == 0) {
                            patch[doff] = fg_b;
                            patch[doff + 1] = fg_g;
                            patch[doff + 2] = fg_r;
                            patch[doff + 3] = 255;
                        } else {
                            patch[doff] ^= fg_b;
                            patch[doff + 1] ^= fg_g;
                            patch[doff + 2] ^= fg_r;
                            patch[doff + 3] = 255;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    pub fn repeatNv12(self: *Duplicator, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        if (self.dupl == null) return null;
        return try self.gpu.repeatFrame(want_cpu_copy, pts_us);
    }

    pub fn deinit(self: *Duplicator) void {
        if (self.patch_scratch.len > 0) {
            std.heap.page_allocator.free(self.patch_scratch);
            self.patch_scratch = &.{};
        }
        if (self.cursor_shape.len > 0) {
            std.heap.page_allocator.free(self.cursor_shape);
            self.cursor_shape = &.{};
        }
        com.release(self.patch_staging);
        com.release(self.comp_bgra);
        com.release(self.clean_bgra);
        self.patch_staging = null;
        self.comp_bgra = null;
        self.clean_bgra = null;
        if (self.user32_dll) |u| {
            c.SDL_UnloadObject(u);
            self.user32_dll = null;
        }
        self.get_cursor_info = null;
        com.release(self.dupl);
        self.dupl = null;
        self.gpu.deinit();
    }
};

// Ponteiro padrão nítido (0=transparente, 1=borda preta, 2=preenchimento branco) usado apenas antes da 1a leitura DXGI.
const fallback_arrow: [20][]const u8 = .{
    "1.............",
    "11............",
    "121...........",
    "1221..........",
    "12221.........",
    "122221........",
    "1222221.......",
    "12222221......",
    "122222221.....",
    "1222222221....",
    "12222222221...",
    "122222111111..",
    "1221221.......",
    "121.1221......",
    "11..1221......",
    "1....1221.....",
    ".....1221.....",
    "......1221....",
    "......111.....",
    "..............",
};

fn drawFallbackArrow(patch: []u8, clip_x: i32, clip_y: i32, bw: u16, bh: u16, dst_pitch: usize) void {
    var dy: usize = 0;
    while (dy < bh) : (dy += 1) {
        const sy: usize = @intCast(clip_y + @as(i32, @intCast(dy)));
        if (sy >= fallback_arrow.len) continue;
        var dx: usize = 0;
        while (dx < bw) : (dx += 1) {
            const sx: usize = @intCast(clip_x + @as(i32, @intCast(dx)));
            if (sx >= fallback_arrow[sy].len) continue;
            const ch = fallback_arrow[sy][sx];
            const doff = dy * dst_pitch + dx * 4;
            if (ch == '1') {
                patch[doff] = 0;
                patch[doff + 1] = 0;
                patch[doff + 2] = 0;
                patch[doff + 3] = 255;
            } else if (ch == '2') {
                patch[doff] = 255;
                patch[doff + 1] = 255;
                patch[doff + 2] = 255;
                patch[doff + 3] = 255;
            }
        }
    }
}
