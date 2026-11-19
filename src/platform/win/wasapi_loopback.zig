//! Captura de áudio do sistema (WASAPI Render Loopback) em 48 kHz estéreo Float32
//! pronta para alimentação direta do Opus (carregamento dinâmico, 0 bytes em repouso).
const std = @import("std");
const c = @import("c");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const UINT = com.UINT;
const ULONG = com.ULONG;
const DWORD = com.DWORD;

const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: DWORD,
    nAvgBytesPerSec: DWORD,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

const AUDCLNT_SHAREMODE_SHARED: UINT = 0;
const AUDCLNT_STREAMFLAGS_LOOPBACK: DWORD = 0x00020000;
const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: DWORD = 0x08000000;
const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: DWORD = 0x80000000;
const AUDCLNT_BUFFERFLAGS_SILENT: DWORD = 0x2;

const AUDCLNT_ACTIVATION_TYPE_PROCESS_LOOPBACK: u32 = 1;
const PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE: u32 = 0;
const PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE: u32 = 1;

const AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS = extern struct {
    TargetProcessId: DWORD,
    ProcessLoopbackMode: u32,
};

const AUDIOCLIENT_ACTIVATION_PARAMS = extern struct {
    ActivationType: u32,
    ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS,
};

const PROPVARIANT_BLOB = extern struct {
    vt: u16 = 65, // VT_BLOB
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    cbSize: ULONG,
    pBlobData: *const AUDIOCLIENT_ACTIVATION_PARAMS,
};

const CoInitializeExFn = *const fn (?*anyopaque, DWORD) callconv(.winapi) HRESULT;
const CoUninitializeFn = *const fn () callconv(.winapi) void;
const CoCreateInstanceFn = *const fn (*const GUID, ?*anyopaque, DWORD, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const CoTaskMemFreeFn = *const fn (?*anyopaque) callconv(.winapi) void;
const ActivateAudioInterfaceAsyncFn = *const fn ([*:0]const u16, *const GUID, ?*const PROPVARIANT_BLOB, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT;
const GetCurrentProcessIdFn = *const fn () callconv(.winapi) DWORD;

const HandlerVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) ULONG,
    ActivateCompleted: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
};

extern "kernel32" fn CreateEventW(?*anyopaque, c_int, c_int, ?*const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(*anyopaque, DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) c_int;

const CompletionHandler = struct {
    lpVtbl: *const HandlerVtbl = &vtbl,
    refs: std.atomic.Value(u32) = .init(1),
    ev: ?*anyopaque = null,

    const vtbl: HandlerVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .ActivateCompleted = activateCompleted,
    };

    fn fromPtr(p: *anyopaque) *CompletionHandler {
        return @ptrCast(@alignCast(p));
    }

    fn guidEq(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }

    fn queryInterface(this: *anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEq(riid, &com.IID_IUnknown) or guidEq(riid, &com.IID_IAgileObject) or guidEq(riid, &com.IID_IActivateAudioInterfaceCompletionHandler)) {
            ppv.* = this;
            _ = addRef(this);
            return com.S_OK;
        }
        ppv.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(this: *anyopaque) callconv(.winapi) ULONG {
        const self = fromPtr(this);
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(this: *anyopaque) callconv(.winapi) ULONG {
        const self = fromPtr(this);
        const prev = self.refs.fetchSub(1, .acq_rel);
        if (prev == 1) {
            if (self.ev) |h| _ = CloseHandle(h);
            std.heap.c_allocator.destroy(self);
        }
        return prev - 1;
    }

    fn activateCompleted(this: *anyopaque, _: *anyopaque) callconv(.winapi) HRESULT {
        const self = fromPtr(this);
        if (self.ev) |h| _ = SetEvent(h);
        return com.S_OK;
    }
};

fn currentPid() DWORD {
    const k32 = c.SDL_LoadObject("kernel32.dll") orelse return 0;
    defer c.SDL_UnloadObject(k32);
    const get_pid: GetCurrentProcessIdFn = @ptrCast(@alignCast(c.SDL_LoadFunction(k32, "GetCurrentProcessId") orelse return 0));
    return get_pid();
}

pub const Loopback = struct {
    ole32: *c.SDL_SharedObject,
    co_uninit: CoUninitializeFn,
    co_init_ok: bool = false,
    client: ?*anyopaque = null,
    capture: ?*anyopaque = null,
    channels: u16 = 2,
    sample_rate: u32 = 48000,
    is_process_isolated: bool = false,

    pub fn open() !Loopback {
        return openDeviceLoopback();
    }

    /// Abre captura isolada de processo (`include_only_target`: somente `target_pid`; caso contrário exclui o próprio processo Discord).
    /// Faz fallback automático para exclusão do próprio processo e, por fim, loopback global.
    pub fn openSmart(target_pid: u32, include_only_target: bool) !Loopback {
        if (include_only_target and target_pid != 0) {
            if (openForProcess(target_pid, true)) |lb| return lb else |_| {}
        }
        const self_pid = currentPid();
        if (self_pid != 0) {
            if (openForProcess(self_pid, false)) |lb| return lb else |_| {}
        }
        return openDeviceLoopback();
    }

    pub fn openForProcess(target_pid: u32, include_tree: bool) !Loopback {
        if (target_pid == 0) return error.InvalidProcessId;
        const ole32 = c.SDL_LoadObject("ole32.dll") orelse return error.Ole32Missing;
        errdefer c.SDL_UnloadObject(ole32);
        const mmdev = c.SDL_LoadObject("mmdevapi.dll") orelse return error.MmdevMissing;
        defer c.SDL_UnloadObject(mmdev);

        const co_init: CoInitializeExFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoInitializeEx") orelse return error.OleFnMissing));
        const co_uninit: CoUninitializeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoUninitialize") orelse return error.OleFnMissing));
        const act_async: ActivateAudioInterfaceAsyncFn = @ptrCast(@alignCast(c.SDL_LoadFunction(mmdev, "ActivateAudioInterfaceAsync") orelse return error.ProcessLoopbackUnsupported));

        var self: Loopback = .{
            .ole32 = ole32,
            .co_uninit = co_uninit,
            .is_process_isolated = true,
        };
        const hr_init = co_init(null, 0);
        self.co_init_ok = com.succeeded(hr_init);
        errdefer self.deinit();

        const ev = CreateEventW(null, 1, 0, null) orelse return error.EventCreateFailed;
        const handler = std.heap.c_allocator.create(CompletionHandler) catch |err| {
            _ = CloseHandle(ev);
            return err;
        };
        handler.* = .{ .ev = ev };
        defer _ = CompletionHandler.release(handler);

        const act_params: AUDIOCLIENT_ACTIVATION_PARAMS = .{
            .ActivationType = AUDCLNT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
            .ProcessLoopbackParams = .{
                .TargetProcessId = target_pid,
                .ProcessLoopbackMode = if (include_tree) PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE else PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE,
            },
        };
        const prop: PROPVARIANT_BLOB = .{
            .cbSize = @sizeOf(AUDIOCLIENT_ACTIVATION_PARAMS),
            .pBlobData = &act_params,
        };
        const vad_path = std.unicode.utf8ToUtf16LeStringLiteral("VAD\\Process_Loopback");
        var op: ?*anyopaque = null;
        if (!com.succeeded(act_async(vad_path.ptr, &com.IID_IAudioClient, &prop, handler, &op)) or op == null) {
            return error.ActivateAudioAsyncFailed;
        }
        defer com.release(op);

        if (WaitForSingleObject(ev, 1500) != 0) return error.ActivateTimeout;
        var act_hr: HRESULT = -1;
        var client: ?*anyopaque = null;
        const get_res = com.slot(op.?, 3, *const fn (*anyopaque, *HRESULT, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(get_res(op.?, &act_hr, &client)) or !com.succeeded(act_hr) or client == null) {
            com.release(client);
            return error.ProcessLoopbackInitFailed;
        }
        self.client = client;
        try self.finishStart(false);
        return self;
    }

    fn openDeviceLoopback() !Loopback {
        const ole32 = c.SDL_LoadObject("ole32.dll") orelse return error.Ole32Missing;
        errdefer c.SDL_UnloadObject(ole32);

        const co_init: CoInitializeExFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoInitializeEx") orelse return error.OleFnMissing));
        const co_uninit: CoUninitializeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoUninitialize") orelse return error.OleFnMissing));
        const co_create: CoCreateInstanceFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoCreateInstance") orelse return error.OleFnMissing));
        const co_free: CoTaskMemFreeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(ole32, "CoTaskMemFree") orelse return error.OleFnMissing));
        _ = co_free;

        var self: Loopback = .{
            .ole32 = ole32,
            .co_uninit = co_uninit,
        };
        // COINIT_MULTITHREADED = 0.
        const hr_init = co_init(null, 0);
        self.co_init_ok = com.succeeded(hr_init);
        errdefer self.deinit();

        var enumerator: ?*anyopaque = null;
        // CLSCTX_ALL = 0x17.
        if (!com.succeeded(co_create(&com.CLSID_MMDeviceEnumerator, null, 0x17, &com.IID_IMMDeviceEnumerator, &enumerator)) or enumerator == null) {
            return error.MmEnumeratorFailed;
        }
        defer com.release(enumerator);

        // eRender = 0, eConsole = 0.
        const get_def = com.slot(enumerator.?, 4, *const fn (*anyopaque, UINT, UINT, *?*anyopaque) callconv(.winapi) HRESULT);
        var device: ?*anyopaque = null;
        if (!com.succeeded(get_def(enumerator.?, 0, 0, &device)) or device == null) return error.NoRenderDevice;
        defer com.release(device);

        const activate = com.slot(device.?, 3, *const fn (*anyopaque, *const GUID, DWORD, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(activate(device.?, &com.IID_IAudioClient, 0x17, null, &self.client)) or self.client == null) {
            return error.AudioClientActivateFailed;
        }
        try self.finishStart(true);
        return self;
    }

    fn finishStart(self: *Loopback, use_autoconvert: bool) !void {
        // Solicita 48 kHz estéreo Float32 com resampleamento automático pelo WASAPI.
        const want_fmt: WAVEFORMATEX = .{
            .wFormatTag = 3, // WAVE_FORMAT_IEEE_FLOAT
            .nChannels = 2,
            .nSamplesPerSec = 48000,
            .nAvgBytesPerSec = 48000 * 8,
            .nBlockAlign = 8,
            .wBitsPerSample = 32,
            .cbSize = 0,
        };
        const init_fn = com.slot(self.client.?, 3, *const fn (*anyopaque, UINT, DWORD, i64, i64, *const WAVEFORMATEX, ?*const GUID) callconv(.winapi) HRESULT);
        const flags_conv = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        const primary_flags = if (use_autoconvert) flags_conv else AUDCLNT_STREAMFLAGS_LOOPBACK;
        var hr = init_fn(self.client.?, AUDCLNT_SHAREMODE_SHARED, primary_flags, 500_000, 0, &want_fmt, null);
        if (!com.succeeded(hr) and !use_autoconvert) {
            hr = init_fn(self.client.?, AUDCLNT_SHAREMODE_SHARED, flags_conv, 500_000, 0, &want_fmt, null);
        }
        if (!com.succeeded(hr)) return error.AudioClientInitFailed;

        const get_svc = com.slot(self.client.?, 14, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(get_svc(self.client.?, &com.IID_IAudioCaptureClient, &self.capture)) or self.capture == null) {
            return error.CaptureServiceFailed;
        }

        const start_fn = com.slot(self.client.?, 10, *const fn (*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(start_fn(self.client.?))) return error.LoopbackStartFailed;
    }

    /// Lê quadros disponíveis (estéreo 48 kHz f32) sem bloquear; devolve floats escritos em `out_interleaved`.
    pub fn readPcm(self: *Loopback, out_interleaved: []f32) usize {
        const cap = self.capture orelse return 0;
        const get_next = com.slot(cap, 5, *const fn (*anyopaque, *UINT) callconv(.winapi) HRESULT);
        const get_buf = com.slot(cap, 3, *const fn (*anyopaque, *?[*]const f32, *UINT, *DWORD, ?*u64, ?*u64) callconv(.winapi) HRESULT);
        const rel_buf = com.slot(cap, 4, *const fn (*anyopaque, UINT) callconv(.winapi) HRESULT);

        var written: usize = 0;
        while (written + self.channels <= out_interleaved.len) {
            var pkt_frames: UINT = 0;
            if (!com.succeeded(get_next(cap, &pkt_frames)) or pkt_frames == 0) break;

            var ptr: ?[*]const f32 = null;
            var n_frames: UINT = 0;
            var flags: DWORD = 0;
            if (!com.succeeded(get_buf(cap, &ptr, &n_frames, &flags, null, null))) break;
            defer _ = rel_buf(cap, n_frames);

            const samples_avail = @as(usize, n_frames) * self.channels;
            const room = out_interleaved.len - written;
            const take = @min(samples_avail, room);
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 or ptr == null) {
                @memset(out_interleaved[written..][0..take], 0);
            } else {
                @memcpy(out_interleaved[written..][0..take], ptr.?[0..take]);
            }
            written += take;
        }
        return written;
    }

    pub fn deinit(self: *Loopback) void {
        if (self.client) |cl| {
            const stop_fn = com.slot(cl, 11, *const fn (*anyopaque) callconv(.winapi) HRESULT);
            _ = stop_fn(cl);
        }
        com.release(self.capture);
        com.release(self.client);
        self.capture = null;
        self.client = null;
        if (self.co_init_ok) {
            self.co_uninit();
            self.co_init_ok = false;
        }
        c.SDL_UnloadObject(self.ole32);
    }
};
