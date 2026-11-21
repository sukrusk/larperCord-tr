//! Transporte UDP P2P criptografado (X25519 + XChaCha20-Poly1305) e STUN
//! para controle remoto AnyDesk e transmissão 4K direta, com 0 bytes em repouso.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const sys = @import("../platform/sys.zig");
const proto = @import("remote_ctrl_proto.zig");
const video_cfg = @import("../core/video_cfg.zig");
const video_rtp = @import("../core/video_rtp.zig");
const capture_backend = @import("../platform/capture_backend.zig");

const is_win = builtin.os.tag == .windows;
const win_inject = if (is_win) @import("../platform/win/input_inject.zig") else struct {
    pub const Injector = struct {
        pub fn init(_: u64) !Injector {
            return error.NotImplementedOnLinuxYet;
        }
        pub fn initTarget(_: video_cfg.RemoteTarget) !Injector {
            return error.NotImplementedOnLinuxYet;
        }
        pub fn setTarget(_: *Injector, _: video_cfg.RemoteTarget) void {}
        pub fn apply(_: *Injector, _: video_cfg.RemoteInputPacket, _: video_cfg.RemotePerm) void {}
        pub fn releaseAll(_: *Injector) void {}
        pub fn deinit(_: *Injector) void {}
    };
};

pub var mgr: Manager = .{};

pub const LocalTicket = struct {
    sock: sys.Socket = sys.no_socket,
    local_port: u16 = 0,
    lan_ip4: [4]u8 = .{ 0, 0, 0, 0 },
    pub_ip4: [4]u8 = .{ 0, 0, 0, 0 },
    pub_port: u16 = 0,
    pin: u32 = 0,
    secret_key: [32]u8 = @splat(0),
    public_key: [32]u8 = @splat(0),
};

extern fn RAND_bytes(buf: [*]u8, num: c_int) c_int;

pub fn randomBytes(out: []u8) void {
    // OpenSSL RAND_bytes já é linkado (crypto.dll) e usa CSPRNG do SO.
    if (RAND_bytes(out.ptr, @intCast(out.len)) == 1) return;
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @intCast(c.SDL_GetTicksNS()))));
    prng.random().bytes(out);
}

/// Abre socket UDP efêmero e descobre endereço público IPv4:porta via STUN (opcional).
pub fn prepareTicket(stun_ip: [*:0]const u8, stun_port: u16, timeout_ms: c_int) ?LocalTicket {
    const s = sys.udpSocket() orelse return null;
    if (!sys.bindAny(s)) {
        sys.closeSocket(s);
        return null;
    }

    var sa = std.mem.zeroes(sys.SockAddrIn);
    var slen: c.socklen_t = @sizeOf(sys.SockAddrIn);
    _ = c.getsockname(s, @ptrCast(&sa), &slen);
    const local_port = std.mem.bigToNative(u16, sa.sin_port);

    var seed: [32]u8 = undefined;
    randomBytes(&seed);
    const kp = proto.Session.makeKeyPair(seed);
    std.crypto.secureZero(u8, &seed);

    var pin_raw: [4]u8 = undefined;
    randomBytes(&pin_raw);
    const pin = (std.mem.readInt(u32, &pin_raw, .little) % 900_000) + 100_000;

    const lan = sys.discoverLanIp4();
    var ticket: LocalTicket = .{
        .sock = s,
        .local_port = local_port,
        .lan_ip4 = lan,
        .pub_ip4 = lan,
        .pub_port = local_port,
        .pin = pin,
        .secret_key = kp.secret_key,
        .public_key = kp.public_key,
    };

    if (timeout_ms > 0) if (sys.ipv4(stun_ip, stun_port)) |stun_addr| {
        var txn: [12]u8 = undefined;
        randomBytes(&txn);
        var req: [20]u8 = undefined;
        proto.buildStunBindingRequest(&req, txn);
        _ = sys.sendTo(s, &req, &stun_addr);

        var pfd = [1]sys.PollFd{.{ .fd = s, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&pfd, 1, timeout_ms);
        if ((pfd[0].revents & c.POLLIN) != 0) {
            var resp: [256]u8 = undefined;
            const n = sys.recvNow(s, &resp);
            if (n > 0) {
                if (proto.parseStunBindingResponse(resp[0..@intCast(n)], txn)) |pub_ep| {
                    ticket.pub_ip4 = pub_ep.ip4;
                    ticket.pub_port = pub_ep.port;
                }
            }
        }
    };
    return ticket;
}

/// Descobre IP público via STUN (Google/Cloudflare fallback) + IP LAN local para NAT P2P AnyDesk.
pub fn prepareAutoTicket(timeout_ms: c_int) ?LocalTicket {
    const stun_hosts = [_][2]struct { host: [*:0]const u8, port: u16 }{
        .{ .{ .host = "stun.l.google.com", .port = 19302 }, .{ .host = "142.250.82.127", .port = 19302 } },
        .{ .{ .host = "stun.cloudflare.com", .port = 3478 }, .{ .host = "162.159.207.0", .port = 3478 } },
    };
    const t0 = prepareAutoFromHost(stun_hosts[0][0].host, stun_hosts[0][0].port, @divTrunc(timeout_ms, 2));
    if (t0) |tk| {
        if (!std.mem.eql(u8, &tk.pub_ip4, &tk.lan_ip4) or tk.pub_port != tk.local_port) return tk;
        // Se STUN Google não respondeu, tenta Cloudflare reutilizando o mesmo socket/porta se quiser; ou mantém fallback rápido.
        if (probeStunIntoTicket(tk.sock, stun_hosts[1][0].host, stun_hosts[1][0].port, @divTrunc(timeout_ms, 2))) |ep| {
            var mut = tk;
            mut.pub_ip4 = ep.ip4;
            mut.pub_port = ep.port;
            return mut;
        }
        return tk;
    }
    return prepareTicket(stun_hosts[0][1].host, stun_hosts[0][1].port, timeout_ms);
}

fn prepareAutoFromHost(host: [*:0]const u8, port: u16, timeout_ms: c_int) ?LocalTicket {
    var ip_z: [24]u8 = @splat(0);
    if (sys.resolveHostIp4(host)) |ip4| {
        if (std.fmt.bufPrint(&ip_z, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] })) |s| {
            ip_z[s.len] = 0;
            const z: [:0]const u8 = ip_z[0..s.len :0];
            return prepareTicket(z.ptr, port, timeout_ms);
        } else |_| {}
    }
    return null;
}

fn probeStunIntoTicket(sock: sys.Socket, host: [*:0]const u8, port: u16, timeout_ms: c_int) ?proto.StunAddr {
    if (timeout_ms <= 0) return null;
    const ip4 = sys.resolveHostIp4(host) orelse return null;
    const stun_addr = ipv4FromBytes(ip4, port) orelse return null;
    var txn: [12]u8 = undefined;
    randomBytes(&txn);
    var req: [20]u8 = undefined;
    proto.buildStunBindingRequest(&req, txn);
    _ = sys.sendTo(sock, &req, &stun_addr);

    var pfd = [1]sys.PollFd{.{ .fd = sock, .events = c.POLLIN, .revents = 0 }};
    sys.poll(&pfd, 1, timeout_ms);
    if ((pfd[0].revents & c.POLLIN) != 0) {
        var resp: [256]u8 = undefined;
        const n = sys.recvNow(sock, &resp);
        if (n > 0) return proto.parseStunBindingResponse(resp[0..@intCast(n)], txn);
    }
    return null;
}

pub fn ipv4FromBytes(ip: [4]u8, port: u16) ?sys.SockAddrIn {
    if (port == 0 or (ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0)) return null;
    var buf: [24]u8 = @splat(0);
    const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return null;
    buf[s.len] = 0;
    const z: [:0]const u8 = buf[0..s.len :0];
    return sys.ipv4(z.ptr, port);
}

pub const Manager = struct {
    life_lock: std.atomic.Value(bool) = .init(false),
    mu: ?*c.SDL_Mutex = null,
    sock: sys.Socket = sys.no_socket,
    peer_addr: sys.SockAddrIn = std.mem.zeroes(sys.SockAddrIn),
    alt_addr: ?sys.SockAddrIn = null,
    peer_locked: std.atomic.Value(bool) = .init(false),
    pli_pending: std.atomic.Value(bool) = .init(false),
    active_flag: std.atomic.Value(bool) = .init(false),
    host_flag: std.atomic.Value(bool) = .init(false),
    session: ?proto.Session = null,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,
    target_hwnd: u64 = 0,
    cap_target: video_cfg.RemoteTarget = .{},
    target_dirty: std.atomic.Value(bool) = .init(false),
    host_meta: proto.HostInfo = .{},
    host_meta_dirty: std.atomic.Value(bool) = .init(false),
    pending_switch_disp: std.atomic.Value(i32) = .init(-1),
    rtt_ms: std.atomic.Value(u16) = .init(0),
    viewer_displays: std.atomic.Value(u8) = .init(0),
    viewer_active_disp: std.atomic.Value(u8) = .init(0),
    viewer_target_kind: std.atomic.Value(u8) = .init(0),
    is_host: bool = false,
    video_seq: u16 = 0,
    packets_rx: std.atomic.Value(u64) = .init(0),
    packets_tx: std.atomic.Value(u64) = .init(0),
    dec_mu: ?*c.SDL_Mutex = null,
    dec_cond: ?*c.SDL_Condition = null,
    dec_thread: ?*c.SDL_Thread = null,
    dec_stop: std.atomic.Value(bool) = .init(false),
    dec_ring: [12]DecJob = @splat(.{}),
    dec_head: u8 = 0,
    dec_tail: u8 = 0,
    dec_count: u8 = 0,
    dec_wait_key: bool = false,
    on_video_chunk: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    on_video_ctx: ?*anyopaque = null,
    on_video_frame: ?*const fn (
        ctx: ?*anyopaque,
        w: u16,
        h: u16,
        y: []const u8,
        yp: usize,
        uv: []const u8,
        uvp: usize,
        codec: video_cfg.Codec,
        pts_ms: i64,
    ) void = null,
    on_frame_ctx: ?*anyopaque = null,

    fn acquireLife(self: *Manager) void {
        while (self.life_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn releaseLife(self: *Manager) void {
        self.life_lock.store(false, .release);
    }

    fn ensureMu(self: *Manager) void {
        if (self.mu == null) self.mu = c.SDL_CreateMutex();
    }

    pub fn active(self: *const Manager) bool {
        return self.active_flag.load(.acquire);
    }

    pub fn activeHost(self: *const Manager) bool {
        return self.active_flag.load(.acquire) and self.host_flag.load(.acquire);
    }

    pub fn activeViewer(self: *const Manager) bool {
        return self.active_flag.load(.acquire) and !self.host_flag.load(.acquire);
    }

    pub fn consumeKeyReq(self: *Manager) bool {
        return self.pli_pending.swap(false, .acq_rel);
    }

    pub fn consumeSwitchDisplay(self: *Manager) ?u16 {
        const v = self.pending_switch_disp.swap(-1, .acq_rel);
        return if (v >= 0) @intCast(v) else null;
    }

    pub fn peerConnected(self: *const Manager) bool {
        return self.peer_locked.load(.acquire);
    }

    pub fn setCaptureTarget(self: *Manager, target: video_cfg.RemoteTarget, disp_count: u8, active_disp: u8, w: u16, h: u16) void {
        self.ensureMu();
        _ = c.SDL_LockMutex(self.mu.?);
        self.cap_target = target;
        self.host_meta.display_count = disp_count;
        self.host_meta.active_display = active_disp;
        self.host_meta.target_kind = target.kind;
        self.host_meta.width = w;
        self.host_meta.height = h;
        if (self.session) |s| self.host_meta.perm = s.perm;
        _ = c.SDL_UnlockMutex(self.mu.?);
        self.target_dirty.store(true, .release);
        self.host_meta_dirty.store(true, .release);
    }

    pub fn updateTargetDims(self: *Manager, w: u16, h: u16) void {
        const m = self.mu orelse return;
        _ = c.SDL_LockMutex(m);
        const changed = self.host_meta.width != w or self.host_meta.height != h;
        if (changed) {
            self.host_meta.width = w;
            self.host_meta.height = h;
        }
        _ = c.SDL_UnlockMutex(m);
        if (changed) self.host_meta_dirty.store(true, .release);
    }

    fn getCaptureTarget(self: *Manager) video_cfg.RemoteTarget {
        if (self.mu == null) return self.cap_target;
        _ = c.SDL_LockMutex(self.mu.?);
        defer _ = c.SDL_UnlockMutex(self.mu.?);
        return self.cap_target;
    }

    pub fn setAltEndpoint(self: *Manager, ip4: [4]u8, port: u16) void {
        if (self.mu == null) return;
        _ = c.SDL_LockMutex(self.mu.?);
        self.alt_addr = ipv4FromBytes(ip4, port);
        _ = c.SDL_UnlockMutex(self.mu.?);
        self.sendSealedPingNow();
    }

    fn sendSealedPingNow(self: *Manager) void {
        var ts: [8]u8 = undefined;
        std.mem.writeInt(u64, &ts, @intCast(c.SDL_GetTicks()), .little);
        self.sendSealedType(.ping, &ts);
    }

    pub fn startHost(
        self: *Manager,
        sock: sys.Socket,
        my_secret: [32]u8,
        peer_pub: [32]u8,
        pin: u32,
        peer_ip: [*:0]const u8,
        peer_port: u16,
        perm: video_cfg.RemotePerm,
        target_hwnd: u64,
    ) !void {
        self.acquireLife();
        defer self.releaseLife();
        self.stopLocked();
        self.ensureMu();
        const addr = sys.ipv4(peer_ip, peer_port) orelse return error.InvalidPeerIp;
        var sess = try proto.Session.derive(.host, my_secret, peer_pub, pin);
        sess.perm = perm;

        self.sock = sock;
        sys.bumpUdpBufs(sock, 4 * 1024 * 1024);
        self.peer_addr = addr;
        self.alt_addr = null;
        self.peer_locked.store(false, .release);
        self.pli_pending.store(true, .release);
        self.session = sess;
        self.target_hwnd = target_hwnd;
        self.is_host = true;
        self.host_flag.store(true, .release);
        self.stopping.store(false, .release);
        self.packets_rx.store(0, .release);
        self.packets_tx.store(0, .release);
        self.rtt_ms.store(0, .release);
        self.pending_switch_disp.store(-1, .release);
        self.target_dirty.store(true, .release);
        self.host_meta_dirty.store(true, .release);
        self.sendSealedPingNow();
        self.thread = c.SDL_CreateThread(hostLoop, "rc-host", self) orelse {
            self.stopLocked();
            return error.ThreadFailed;
        };
        self.active_flag.store(true, .release);
    }

    pub fn startViewer(
        self: *Manager,
        sock: sys.Socket,
        my_secret: [32]u8,
        peer_pub: [32]u8,
        pin: u32,
        peer_ip: [*:0]const u8,
        peer_port: u16,
    ) !void {
        self.acquireLife();
        defer self.releaseLife();
        self.stopLocked();
        self.ensureMu();
        const addr = sys.ipv4(peer_ip, peer_port) orelse return error.InvalidPeerIp;
        var sess = try proto.Session.derive(.viewer, my_secret, peer_pub, pin);
        sess.perm = .full;

        self.sock = sock;
        sys.bumpUdpBufs(sock, 4 * 1024 * 1024);
        self.peer_addr = addr;
        self.alt_addr = null;
        self.peer_locked.store(false, .release);
        self.pli_pending.store(false, .release);
        self.session = sess;
        self.is_host = false;
        self.host_flag.store(false, .release);
        self.stopping.store(false, .release);
        self.packets_rx.store(0, .release);
        self.packets_tx.store(0, .release);
        self.rtt_ms.store(0, .release);
        self.viewer_displays.store(0, .release);
        self.viewer_active_disp.store(0, .release);
        self.viewer_target_kind.store(0, .release);
        // Envia ping inicial para abrir NAT hole-punch e confirmar túnel criptografado.
        self.sendSealedPingNow();
        self.startDecWorker();
        self.thread = c.SDL_CreateThread(viewerLoop, "rc-view", self) orelse {
            self.stopLocked();
            return error.ThreadFailed;
        };
        self.active_flag.store(true, .release);
    }

    fn sendSealedType(self: *Manager, msg_type: proto.MsgType, payload: []const u8) void {
        const m = self.mu orelse return;
        _ = c.SDL_LockMutex(m);
        defer _ = c.SDL_UnlockMutex(m);
        if (!sys.valid(self.sock)) return;
        const sess = if (self.session) |*s| s else return;
        var wire: [256]u8 = undefined;
        const sealed = sess.seal(msg_type, payload, &wire) catch return;
        _ = sys.sendTo(self.sock, sealed, &self.peer_addr);
        if (!self.peer_locked.load(.acquire)) if (self.alt_addr) |*alt| {
            _ = sys.sendTo(self.sock, sealed, alt);
        };
    }

    pub fn sendControl(self: *Manager, pkt: video_cfg.RemoteInputPacket) void {
        const m = self.mu orelse return;
        if (self.host_flag.load(.acquire) or self.stopping.load(.acquire)) return;
        _ = c.SDL_LockMutex(m);
        defer _ = c.SDL_UnlockMutex(m);

        if (!sys.valid(self.sock)) return;
        const sess = if (self.session) |*s| s else return;
        var raw_in: [video_cfg.RemoteInputPacket.wire_len]u8 = undefined;
        pkt.encode(&raw_in);
        var wire: [128]u8 = undefined;
        const sealed = sess.seal(.input, &raw_in, &wire) catch return;
        if (sys.sendTo(self.sock, sealed, &self.peer_addr) > 0) {
            _ = self.packets_tx.fetchAdd(1, .monotonic);
        }
        if (!self.peer_locked.load(.acquire)) if (self.alt_addr) |*alt| {
            _ = sys.sendTo(self.sock, sealed, alt);
        };
    }

    pub fn setPermission(self: *Manager, perm: video_cfg.RemotePerm) void {
        const m = self.mu orelse return;
        _ = c.SDL_LockMutex(m);
        if (self.session) |*s| s.perm = perm;
        self.host_meta.perm = perm;
        _ = c.SDL_UnlockMutex(m);
        self.host_meta_dirty.store(true, .release);
    }

    pub fn setRemoteVideoSink(
        self: *Manager,
        ctx: ?*anyopaque,
        cb: ?*const fn (?*anyopaque, u16, u16, []const u8, usize, []const u8, usize, video_cfg.Codec, i64) void,
    ) void {
        self.acquireLife();
        defer self.releaseLife();
        self.ensureMu();
        _ = c.SDL_LockMutex(self.mu.?);
        defer _ = c.SDL_UnlockMutex(self.mu.?);
        self.on_frame_ctx = ctx;
        self.on_video_frame = cb;
    }

    pub fn sendVideoAu(self: *Manager, codec: video_cfg.Codec, pts_us: i64, is_keyframe: bool, au: []const u8) void {
        _ = .{ codec, is_keyframe };
        if (self.mu == null or !self.activeHost() or self.stopping.load(.acquire) or au.len == 0) return;
        const rtp_ts: u32 = @truncate((@as(u64, @intCast(@max(pts_us, @as(i64, 0)))) * 90) / 1000);
        const m = self.mu orelse return;
        _ = c.SDL_LockMutex(m);
        defer _ = c.SDL_UnlockMutex(m);
        if (!sys.valid(self.sock) or self.stopping.load(.acquire)) return;
        const sess = if (self.session) |*s| s else return;
        const Tx = struct {
            m: *Manager,
            sess: *proto.Session,
            ts: u32,
            fn emit(ctx: *anyopaque, payload: []const u8, marker: bool) void {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                if (payload.len > video_rtp.max_rtp_payload + 32) return;
                var msg_buf: [7 + video_rtp.max_rtp_payload + 32]u8 = undefined;
                std.mem.writeInt(u32, msg_buf[0..4], st.ts, .big);
                std.mem.writeInt(u16, msg_buf[4..6], st.m.video_seq, .big);
                msg_buf[6] = if (marker) 1 else 0;
                st.m.video_seq +%= 1;
                @memcpy(msg_buf[7..][0..payload.len], payload);
                var wire: [1500]u8 = undefined;
                const sealed = st.sess.seal(.video_chunk, msg_buf[0 .. 7 + payload.len], &wire) catch return;
                if (sys.sendTo(st.m.sock, sealed, &st.m.peer_addr) > 0) {
                    _ = st.m.packets_tx.fetchAdd(1, .monotonic);
                }
            }
        };
        var tx: Tx = .{ .m = self, .sess = sess, .ts = rtp_ts };
        video_rtp.packetizeH264AnnexB(au, video_rtp.max_rtp_payload, .{ .ctx = &tx, .emit = Tx.emit });
    }

    fn stopLocked(self: *Manager) void {
        const was_viewer = self.active_flag.load(.acquire) and !self.host_flag.load(.acquire);
        if (was_viewer) {
            self.sendControl(.{ .kind = .release_all });
        }
        self.active_flag.store(false, .release);
        self.host_flag.store(false, .release);
        self.stopping.store(true, .release);
        if (self.thread) |t| {
            self.thread = null;
            c.SDL_WaitThread(t, null);
        }
        self.stopDecWorker();
        if (self.mu) |m| _ = c.SDL_LockMutex(m);
        if (self.session) |*s| {
            s.wipe();
            self.session = null;
        }
        if (sys.valid(self.sock)) {
            sys.closeSocket(self.sock);
            self.sock = sys.no_socket;
        }
        self.is_host = false;
        if (self.mu) |m| _ = c.SDL_UnlockMutex(m);
    }

    pub fn stop(self: *Manager) void {
        self.acquireLife();
        defer self.releaseLife();
        self.stopLocked();
    }

    pub fn deinit(self: *Manager) void {
        self.acquireLife();
        defer self.releaseLife();
        self.stopLocked();
        if (self.mu) |m| {
            c.SDL_DestroyMutex(m);
            self.mu = null;
        }
    }

    fn startDecWorker(self: *Manager) void {
        if (self.dec_thread != null) return;
        if (self.dec_mu == null) self.dec_mu = c.SDL_CreateMutex();
        if (self.dec_cond == null) self.dec_cond = c.SDL_CreateCondition();
        if (self.dec_mu == null or self.dec_cond == null) return;
        self.dec_stop.store(false, .release);
        self.dec_head = 0;
        self.dec_tail = 0;
        self.dec_count = 0;
        self.dec_wait_key = false;
        self.dec_thread = c.SDL_CreateThread(viewerDecMain, "rc-dec", self);
    }

    fn stopDecWorker(self: *Manager) void {
        self.dec_stop.store(true, .release);
        if (self.dec_mu) |m| {
            _ = c.SDL_LockMutex(m);
            if (self.dec_cond) |cd| c.SDL_BroadcastCondition(cd);
            _ = c.SDL_UnlockMutex(m);
        }
        if (self.dec_thread) |t| {
            c.SDL_WaitThread(t, null);
            self.dec_thread = null;
        }
        for (&self.dec_ring) |*job| {
            if (job.buf.len > 0) std.heap.page_allocator.free(job.buf);
            job.* = .{};
        }
        self.dec_head = 0;
        self.dec_tail = 0;
        self.dec_count = 0;
        self.dec_wait_key = false;
        if (self.dec_cond) |cd| {
            c.SDL_DestroyCondition(cd);
            self.dec_cond = null;
        }
        if (self.dec_mu) |m| {
            c.SDL_DestroyMutex(m);
            self.dec_mu = null;
        }
    }

    fn resetDecQueueWaitKey(self: *Manager) void {
        const m = self.dec_mu orelse return;
        _ = c.SDL_LockMutex(m);
        self.dec_head = 0;
        self.dec_tail = 0;
        self.dec_count = 0;
        self.dec_wait_key = true;
        _ = c.SDL_UnlockMutex(m);
    }

    fn enqueueDecode(self: *Manager, pts_us: i64, is_key: bool, au: []const u8) bool {
        if (au.len == 0) return false;
        const m = self.dec_mu orelse return false;
        const cd = self.dec_cond orelse return false;
        _ = c.SDL_LockMutex(m);
        defer _ = c.SDL_UnlockMutex(m);
        if (self.dec_wait_key and !is_key) return false;
        if (self.dec_count == self.dec_ring.len) {
            if (is_key) {
                self.dec_head = 0;
                self.dec_tail = 0;
                self.dec_count = 0;
            } else {
                self.dec_wait_key = true;
                return false;
            }
        }
        if (is_key) self.dec_wait_key = false;
        const job = &self.dec_ring[self.dec_tail];
        if (job.buf.len < au.len) {
            const next = std.heap.page_allocator.alloc(u8, @max(au.len, 256 * 1024)) catch return false;
            if (job.buf.len > 0) std.heap.page_allocator.free(job.buf);
            job.buf = next;
        }
        @memcpy(job.buf[0..au.len], au);
        job.len = au.len;
        job.pts_us = pts_us;
        self.dec_tail = (self.dec_tail + 1) % @as(u8, @intCast(self.dec_ring.len));
        self.dec_count += 1;
        c.SDL_SignalCondition(cd);
        return true;
    }
};

const DecJob = struct {
    pts_us: i64 = 0,
    len: usize = 0,
    buf: []u8 = &.{},
};

fn isNewerSeq(seq: u32, prev: u32) bool {
    const d: i32 = @bitCast(seq -% prev);
    return d > 0 or d < -64;
}

fn hostLoop(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    const init_target = if (self.target_hwnd != 0)
        video_cfg.RemoteTarget.fromWindow(self.target_hwnd)
    else
        self.getCaptureTarget();
    var inj: ?win_inject.Injector = win_inject.Injector.initTarget(init_target) catch null;
    defer if (inj) |*i| i.deinit();

    var wire: [2048]u8 = undefined;
    var plain: [2048]u8 = undefined;
    var last_probe_ms: u64 = 0;
    var last_meta_ms: u64 = 0;
    var has_mouse_seq = false;
    var last_mouse_seq: u32 = 0;

    while (!self.stopping.load(.acquire)) {
        if (self.target_dirty.swap(false, .acq_rel)) {
            const nt = if (self.target_hwnd != 0) video_cfg.RemoteTarget.fromWindow(self.target_hwnd) else self.getCaptureTarget();
            if (inj) |*i| i.setTarget(nt);
        }

        const now_ms = c.SDL_GetTicks();
        if (!self.peer_locked.load(.acquire)) {
            if (now_ms - last_probe_ms >= 150) {
                last_probe_ms = now_ms;
                self.sendSealedPingNow();
            }
        } else if (self.host_meta_dirty.swap(false, .acq_rel) or now_ms - last_meta_ms >= 1200) {
            last_meta_ms = now_ms;
            sendHostMetaLocked(self);
        }

        var pfd = [1]sys.PollFd{.{ .fd = self.sock, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&pfd, 1, 8);
        if ((pfd[0].revents & c.POLLIN) == 0) continue;

        // Drena toda a fila UDP de uma só vez e coalesce `mouse_move` mantendo apenas o último ponto.
        var pending_move: ?video_cfg.RemoteInputPacket = null;
        var batch: [32]video_cfg.RemoteInputPacket = undefined;
        var batch_n: usize = 0;
        var do_release_all = false;
        var pong_wire: [64]u8 = undefined;
        var pong_len: usize = 0;
        var pong_peer: sys.SockAddrIn = undefined;
        var unlocked_now = false;

        _ = c.SDL_LockMutex(self.mu.?);
        var rx_count: usize = 0;
        while (rx_count < 256) : (rx_count += 1) {
            var from: sys.SockAddrIn = undefined;
            const n = sys.recvFrom(self.sock, &wire, &from);
            if (n <= 0) break;

            const sess = if (self.session) |*s| s else break;
            const opened = sess.open(wire[0..@intCast(n)], &plain) catch continue;
            if (!self.peer_locked.swap(true, .release)) unlocked_now = true;
            self.peer_addr = from;
            const allow_fn = sess.*;

            switch (opened.msg_type) {
                .input => {
                    if (video_cfg.RemoteInputPacket.decode(opened.payload)) |pkt| {
                        if (pkt.kind == .ping) {
                            var pong_raw: [video_cfg.RemoteInputPacket.wire_len]u8 = undefined;
                            (@as(video_cfg.RemoteInputPacket, .{ .kind = .pong, .seq = pkt.seq })).encode(&pong_raw);
                            if (sess.seal(.pong, &pong_raw, &pong_wire)) |sw| {
                                pong_len = sw.len;
                                pong_peer = from;
                            } else |_| {}
                        } else if (pkt.kind == .switch_display) {
                            if (allow_fn.allowInput(pkt)) {
                                self.pending_switch_disp.store(@intCast(pkt.code), .release);
                            }
                        } else if (allow_fn.allowInput(pkt)) {
                            if (pkt.kind == .mouse_move) {
                                if (!has_mouse_seq or isNewerSeq(pkt.seq, last_mouse_seq)) {
                                    has_mouse_seq = true;
                                    last_mouse_seq = pkt.seq;
                                    pending_move = pkt;
                                }
                            } else {
                                if (pending_move) |mv| {
                                    if (batch_n < batch.len) {
                                        batch[batch_n] = mv;
                                        batch_n += 1;
                                    }
                                    pending_move = null;
                                }
                                if (batch_n < batch.len) {
                                    batch[batch_n] = pkt;
                                    batch_n += 1;
                                }
                            }
                        }
                        _ = self.packets_rx.fetchAdd(1, .monotonic);
                    }
                },
                .release_all => {
                    do_release_all = true;
                    pending_move = null;
                    batch_n = 0;
                },
                .video_pli => self.pli_pending.store(true, .release),
                .ping => {
                    if (sess.seal(.pong, opened.payload, &pong_wire)) |sw| {
                        pong_len = sw.len;
                        pong_peer = from;
                    } else |_| {}
                    _ = self.packets_rx.fetchAdd(1, .monotonic);
                },
                .pong => {
                    if (opened.payload.len >= 8) {
                        const tx_ms = std.mem.readInt(u64, opened.payload[0..8], .little);
                        const now64: u64 = @intCast(c.SDL_GetTicks());
                        if (now64 >= tx_ms) self.rtt_ms.store(@intCast(@min(now64 - tx_ms, 9999)), .release);
                    }
                    _ = self.packets_rx.fetchAdd(1, .monotonic);
                },
                else => {},
            }
        }
        const cur_perm = if (self.session) |s| s.perm else video_cfg.RemotePerm.off;
        _ = c.SDL_UnlockMutex(self.mu.?);

        if (pending_move) |mv| {
            if (batch_n < batch.len) {
                batch[batch_n] = mv;
                batch_n += 1;
            }
        }
        if (pong_len > 0) _ = sys.sendTo(self.sock, pong_wire[0..pong_len], &pong_peer);
        if (do_release_all) {
            if (inj) |*i| i.releaseAll();
        } else if (inj) |*i| {
            for (batch[0..batch_n]) |pkt| i.apply(pkt, cur_perm);
        }
        if (unlocked_now) self.host_meta_dirty.store(true, .release);
    }
    return 0;
}

fn sendHostMetaLocked(self: *Manager) void {
    const m = self.mu orelse return;
    _ = c.SDL_LockMutex(m);
    const meta = self.host_meta;
    _ = c.SDL_UnlockMutex(m);
    var raw: [proto.HostInfo.wire_len]u8 = undefined;
    meta.encode(&raw);
    self.sendSealedType(.host_info, &raw);
}

fn viewerDecMain(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    const m = self.dec_mu orelse return 0;
    const cd = self.dec_cond orelse return 0;

    var dec_opt: ?capture_backend.HwDecoder = null;
    defer if (dec_opt) |*d| d.deinit();

    var local_au: []u8 = &.{};
    defer if (local_au.len > 0) std.heap.page_allocator.free(local_au);

    while (!self.dec_stop.load(.acquire)) {
        _ = c.SDL_LockMutex(m);
        while (self.dec_count == 0 and !self.dec_stop.load(.acquire)) {
            _ = c.SDL_WaitCondition(cd, m);
        }
        if (self.dec_stop.load(.acquire)) {
            _ = c.SDL_UnlockMutex(m);
            break;
        }
        const job = &self.dec_ring[self.dec_head];
        const j_len = job.len;
        const j_pts = job.pts_us;
        if (local_au.len < j_len) {
            const next = std.heap.page_allocator.alloc(u8, @max(j_len, 256 * 1024)) catch {
                self.dec_head = (self.dec_head + 1) % @as(u8, @intCast(self.dec_ring.len));
                self.dec_count -= 1;
                _ = c.SDL_UnlockMutex(m);
                continue;
            };
            if (local_au.len > 0) std.heap.page_allocator.free(local_au);
            local_au = next;
        }
        @memcpy(local_au[0..j_len], job.buf[0..j_len]);
        self.dec_head = (self.dec_head + 1) % @as(u8, @intCast(self.dec_ring.len));
        self.dec_count -= 1;
        _ = c.SDL_UnlockMutex(m);

        if (dec_opt == null) {
            dec_opt = capture_backend.HwDecoder.open(.h264, 1920, 1080, null) catch null;
        }
        if (dec_opt) |*dc| {
            if (dc.decode(local_au[0..j_len], j_pts) catch null) |df| {
                _ = c.SDL_LockMutex(self.mu.?);
                const fcb = self.on_video_frame;
                const fctx = self.on_frame_ctx;
                _ = c.SDL_UnlockMutex(self.mu.?);
                if (fcb) |f| {
                    f(fctx, df.width, df.height, df.nv12_y, df.y_pitch, df.nv12_uv, df.uv_pitch, .h264, @intCast(c.SDL_GetTicks()));
                }
            }
        }
    }
    return 0;
}

fn viewerLoop(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    var wire: [65536]u8 = undefined;
    var plain: [65536]u8 = undefined;
    var assembler = video_rtp.FrameAssembler.init(std.heap.page_allocator);
    defer assembler.deinit();
    var last_probe_ms: u64 = 0;
    var last_pli_ms: u64 = 0;
    var got_keyframe = false;

    while (!self.stopping.load(.acquire)) {
        const now_ms = c.SDL_GetTicks();
        const probe_interval: u64 = if (self.peer_locked.load(.acquire)) 1000 else 150;
        if (now_ms - last_probe_ms >= probe_interval) {
            last_probe_ms = now_ms;
            self.sendSealedPingNow();
        }
        var pfd = [1]sys.PollFd{.{ .fd = self.sock, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&pfd, 1, 8);
        if ((pfd[0].revents & c.POLLIN) == 0) continue;

        var rx_count: usize = 0;
        while (rx_count < 512 and !self.stopping.load(.acquire)) : (rx_count += 1) {
            var from: sys.SockAddrIn = undefined;
            const n = sys.recvFrom(self.sock, &wire, &from);
            if (n <= 0) break;

            _ = c.SDL_LockMutex(self.mu.?);
            const sess = if (self.session) |*s| s else {
                _ = c.SDL_UnlockMutex(self.mu.?);
                return 0;
            };
            const opened = sess.open(wire[0..@intCast(n)], &plain) catch {
                _ = c.SDL_UnlockMutex(self.mu.?);
                continue;
            };
            self.peer_addr = from;
            self.peer_locked.store(true, .release);
            const cb = self.on_video_chunk;
            const cb_ctx = self.on_video_ctx;
            const has_fcb = self.on_video_frame != null;
            _ = c.SDL_UnlockMutex(self.mu.?);

            _ = self.packets_rx.fetchAdd(1, .monotonic);
            switch (opened.msg_type) {
                .ping => {
                    var pong_buf: [64]u8 = undefined;
                    if (self.mu) |m| {
                        _ = c.SDL_LockMutex(m);
                        const plen: usize = if (self.session) |*s| (if (s.seal(.pong, opened.payload, &pong_buf)) |sw| sw.len else |_| 0) else 0;
                        const peer = self.peer_addr;
                        _ = c.SDL_UnlockMutex(m);
                        if (plen > 0) _ = sys.sendTo(self.sock, pong_buf[0..plen], &peer);
                    }
                },
                .pong => {
                    if (opened.payload.len >= 8) {
                        const tx_ms = std.mem.readInt(u64, opened.payload[0..8], .little);
                        const cur_ms: u64 = @intCast(c.SDL_GetTicks());
                        if (cur_ms >= tx_ms) self.rtt_ms.store(@intCast(@min(cur_ms - tx_ms, 9999)), .release);
                    }
                },
                .host_info => {
                    if (proto.HostInfo.decode(opened.payload)) |hi| {
                        self.viewer_displays.store(hi.display_count, .release);
                        self.viewer_active_disp.store(hi.active_display, .release);
                        self.viewer_target_kind.store(@intFromEnum(hi.target_kind), .release);
                    }
                },
                .video_chunk => {
                    if (has_fcb and opened.payload.len > 7) {
                        const rtp_ts = std.mem.readInt(u32, opened.payload[0..4], .big);
                        const seq = std.mem.readInt(u16, opened.payload[4..6], .big);
                        const marker = (opened.payload[6] & 1) != 0;
                        const rtp_pay = opened.payload[7..];
                        switch (assembler.pushH264(seq, rtp_ts, marker, rtp_pay)) {
                            .dropped => |dr| {
                                got_keyframe = false;
                                self.resetDecQueueWaitKey();
                                const tnow = c.SDL_GetTicks();
                                if (dr.need_pli and tnow - last_pli_ms >= 150) {
                                    last_pli_ms = tnow;
                                    self.sendSealedType(.video_pli, &.{});
                                }
                            },
                            .frame => |au| {
                                const is_key = hasH264Keyframe(au);
                                if (assembler.takeAbandoned() and !is_key) {
                                    got_keyframe = false;
                                    self.resetDecQueueWaitKey();
                                }
                                if (!got_keyframe) {
                                    if (is_key) {
                                        got_keyframe = true;
                                    } else {
                                        const tnow = c.SDL_GetTicks();
                                        if (tnow - last_pli_ms >= 150) {
                                            last_pli_ms = tnow;
                                            self.sendSealedType(.video_pli, &.{});
                                        }
                                        continue;
                                    }
                                }
                                const pts_us: i64 = @divTrunc(@as(i64, rtp_ts) * 1000, 90);
                                if (!self.enqueueDecode(pts_us, is_key, au)) {
                                    got_keyframe = false;
                                    const tnow = c.SDL_GetTicks();
                                    if (tnow - last_pli_ms >= 150) {
                                        last_pli_ms = tnow;
                                        self.sendSealedType(.video_pli, &.{});
                                    }
                                }
                            },
                            else => {},
                        }
                    } else if (cb) |f| {
                        f(cb_ctx, opened.payload);
                    }
                },
                else => {},
            }
        }
    }
    return 0;
}

fn hasH264Keyframe(au: []const u8) bool {
    var nals: [32][]const u8 = undefined;
    const count = video_rtp.splitAnnexBNals(au, &nals);
    for (nals[0..count]) |nal| {
        if (nal.len == 0) continue;
        const nt = nal[0] & 0x1F;
        if (nt == 5 or nt == 7) return true;
    }
    return false;
}

/// Auto-teste real de túnel UDP P2P loopback (127.0.0.1) X25519 + XChaCha20-Poly1305
/// validando troca bidirecional de entrada AnyDesk, pong e fragmentos de vídeo.
pub fn runLoopbackSelfTest() !bool {
    var t_host = prepareTicket("127.0.0.1", 19302, 0) orelse return error.HostTicketFailed;
    errdefer sys.closeSocket(t_host.sock);
    var t_view = prepareTicket("127.0.0.1", 19302, 0) orelse return error.ViewTicketFailed;
    errdefer sys.closeSocket(t_view.sock);

    var host: Manager = .{};
    defer host.deinit();
    var view: Manager = .{};
    defer view.deinit();

    try host.startHost(t_host.sock, t_host.secret_key, t_view.public_key, t_host.pin, "127.0.0.1", t_view.local_port, .full, 0);
    try view.startViewer(t_view.sock, t_view.secret_key, t_host.public_key, t_host.pin, "127.0.0.1", t_host.local_port);

    view.sendControl(.{ .kind = .mouse_move, .x = 32768, .y = 32768, .seq = 1 });
    view.sendControl(.{ .kind = .key, .code = 0, .pressed = false, .seq = 2 }); // código inválido: seguro, zero input no SO real!

    var got_chunk = false;
    const Probe = struct {
        hit: *bool,
        fn onChunk(ctx: ?*anyopaque, data: []const u8) void {
            const h: *bool = @ptrCast(@alignCast(ctx.?));
            if (data.len >= 7) h.* = true;
        }
    };
    view.on_video_ctx = &got_chunk;
    view.on_video_chunk = Probe.onChunk;

    const fake_idr = [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21, 0xA0 };
    host.sendVideoAu(.h264, 16667, true, &fake_idr);

    var tries: usize = 0;
    while (tries < 30 and (host.packets_rx.load(.acquire) < 2 or view.packets_rx.load(.acquire) < 2)) : (tries += 1) {
        c.SDL_Delay(5);
    }

    const ok = host.packets_rx.load(.acquire) >= 2 and view.packets_rx.load(.acquire) >= 2 and got_chunk;
    host.stop();
    view.stop();
    std.crypto.secureZero(u8, &t_host.secret_key);
    std.crypto.secureZero(u8, &t_view.secret_key);
    return ok;
}

test "Manager.stop concurrent calls are thread-safe" {
    if (is_win) {
        var wsa: c.WSADATA = undefined;
        _ = c.WSAStartup(0x0202, &wsa);
    }
    var m: Manager = .{};
    defer m.deinit();

    const Worker = struct {
        mgr: *Manager,
        fn run(self: *@This()) void {
            self.mgr.stop();
        }
    };

    for (0..8) |_| {
        var tk = prepareTicket("127.0.0.1", 19302, 0) orelse return error.SkipZigTest;
        const kp2 = proto.Session.makeKeyPair(@splat(0x42));
        try m.startHost(tk.sock, tk.secret_key, kp2.public_key, tk.pin, "127.0.0.1", tk.local_port, .full, 0);
        std.crypto.secureZero(u8, &tk.secret_key);

        var ctx: Worker = .{ .mgr = &m };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
        for (threads) |th| th.join();

        try std.testing.expect(!m.active());
        try std.testing.expect(m.thread == null);
        try std.testing.expect(!sys.valid(m.sock));
    }
}
