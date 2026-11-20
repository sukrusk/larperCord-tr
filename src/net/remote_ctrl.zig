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

/// Descobre IP público via STUN (Google/fallback) + IP LAN local para NAT P2P AnyDesk.
pub fn prepareAutoTicket(timeout_ms: c_int) ?LocalTicket {
    var ip_z: [24]u8 = @splat(0);
    if (sys.resolveHostIp4("stun.l.google.com")) |ip4| {
        if (std.fmt.bufPrint(&ip_z, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] })) |s| {
            ip_z[s.len] = 0;
            const z: [:0]const u8 = ip_z[0..s.len :0];
            return prepareTicket(z.ptr, 19302, timeout_ms);
        } else |_| {}
    }
    return prepareTicket("142.250.82.127", 19302, timeout_ms);
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
    is_host: bool = false,
    video_seq: u16 = 0,
    packets_rx: std.atomic.Value(u64) = .init(0),
    packets_tx: std.atomic.Value(u64) = .init(0),
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

    pub fn consumeKeyReq(self: *Manager) bool {
        return self.pli_pending.swap(false, .acq_rel);
    }

    pub fn setAltEndpoint(self: *Manager, ip4: [4]u8, port: u16) void {
        if (self.mu == null) return;
        _ = c.SDL_LockMutex(self.mu.?);
        defer _ = c.SDL_UnlockMutex(self.mu.?);
        self.alt_addr = ipv4FromBytes(ip4, port);
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
        self.sendSealedType(.ping, &.{});
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
        // Envia ping inicial para abrir NAT hole-punch e confirmar túnel criptografado.
        self.sendControl(.{ .kind = .ping });
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
        defer _ = c.SDL_UnlockMutex(m);
        if (self.session) |*s| s.perm = perm;
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
        const Tx = struct {
            m: *Manager,
            ts: u32,
            fn emit(ctx: *anyopaque, payload: []const u8, marker: bool) void {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                if (payload.len > video_rtp.max_rtp_payload + 32) return;
                const m = st.m.mu orelse return;
                _ = c.SDL_LockMutex(m);
                defer _ = c.SDL_UnlockMutex(m);
                if (!sys.valid(st.m.sock) or st.m.stopping.load(.acquire)) return;
                const sess = if (st.m.session) |*s| s else return;
                var msg_buf: [7 + video_rtp.max_rtp_payload + 32]u8 = undefined;
                std.mem.writeInt(u32, msg_buf[0..4], st.ts, .big);
                std.mem.writeInt(u16, msg_buf[4..6], st.m.video_seq, .big);
                msg_buf[6] = if (marker) 1 else 0;
                st.m.video_seq +%= 1;
                @memcpy(msg_buf[7..][0..payload.len], payload);
                var wire: [1500]u8 = undefined;
                const sealed = sess.seal(.video_chunk, msg_buf[0 .. 7 + payload.len], &wire) catch return;
                if (sys.sendTo(st.m.sock, sealed, &st.m.peer_addr) > 0) {
                    _ = st.m.packets_tx.fetchAdd(1, .monotonic);
                }
            }
        };
        var tx: Tx = .{ .m = self, .ts = rtp_ts };
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
};

fn hostLoop(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    var inj: ?win_inject.Injector = win_inject.Injector.init(self.target_hwnd) catch null;
    defer if (inj) |*i| i.deinit();

    var wire: [2048]u8 = undefined;
    var plain: [2048]u8 = undefined;
    var last_probe_ms: u64 = 0;
    while (!self.stopping.load(.acquire)) {
        if (!self.peer_locked.load(.acquire)) {
            const now_ms = c.SDL_GetTicks();
            if (now_ms - last_probe_ms >= 150) {
                last_probe_ms = now_ms;
                self.sendSealedType(.ping, &.{});
            }
        }
        var pfd = [1]sys.PollFd{.{ .fd = self.sock, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&pfd, 1, 25);
        if ((pfd[0].revents & c.POLLIN) == 0) continue;

        var from: sys.SockAddrIn = undefined;
        const n = sys.recvFrom(self.sock, &wire, &from);
        if (n <= 0) continue;

        _ = c.SDL_LockMutex(self.mu.?);
        const sess = if (self.session) |*s| s else {
            _ = c.SDL_UnlockMutex(self.mu.?);
            break;
        };
        const opened = sess.open(wire[0..@intCast(n)], &plain) catch {
            _ = c.SDL_UnlockMutex(self.mu.?);
            continue;
        };
        self.peer_addr = from;
        self.peer_locked.store(true, .release);
        const perm = sess.perm;
        const allow_fn = sess;
        var pong_wire: [64]u8 = undefined;
        var pong_len: usize = 0;

        switch (opened.msg_type) {
            .input => {
                if (video_cfg.RemoteInputPacket.decode(opened.payload)) |pkt| {
                    if (pkt.kind == .ping) {
                        var pong_raw: [video_cfg.RemoteInputPacket.wire_len]u8 = undefined;
                        (@as(video_cfg.RemoteInputPacket, .{ .kind = .pong, .seq = pkt.seq })).encode(&pong_raw);
                        if (allow_fn.seal(.pong, &pong_raw, &pong_wire)) |sw| pong_len = sw.len else |_| {}
                    } else if (allow_fn.allowInput(pkt)) {
                        if (inj) |*i| i.apply(pkt, perm);
                    }
                    _ = self.packets_rx.fetchAdd(1, .monotonic);
                }
            },
            .release_all => if (inj) |*i| i.releaseAll(),
            .video_pli => self.pli_pending.store(true, .release),
            .ping => {
                if (allow_fn.seal(.pong, opened.payload, &pong_wire)) |sw| pong_len = sw.len else |_| {}
            },
            else => {},
        }
        _ = c.SDL_UnlockMutex(self.mu.?);
        if (pong_len > 0) _ = sys.sendTo(self.sock, pong_wire[0..pong_len], &self.peer_addr);
    }
    return 0;
}

fn viewerLoop(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    var wire: [65536]u8 = undefined;
    var plain: [65536]u8 = undefined;
    var assembler = video_rtp.FrameAssembler.init(std.heap.page_allocator);
    defer assembler.deinit();
    var dec_opt: ?capture_backend.HwDecoder = null;
    defer if (dec_opt) |*d| d.deinit();
    var last_probe_ms: u64 = 0;
    var last_pli_ms: u64 = 0;
    var got_keyframe = false;

    while (!self.stopping.load(.acquire)) {
        if (!self.peer_locked.load(.acquire)) {
            const now_ms = c.SDL_GetTicks();
            if (now_ms - last_probe_ms >= 150) {
                last_probe_ms = now_ms;
                self.sendSealedType(.ping, &.{});
            }
        }
        var pfd = [1]sys.PollFd{.{ .fd = self.sock, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&pfd, 1, 25);
        if ((pfd[0].revents & c.POLLIN) == 0) continue;

        var from: sys.SockAddrIn = undefined;
        const n = sys.recvFrom(self.sock, &wire, &from);
        if (n <= 0) continue;

        _ = c.SDL_LockMutex(self.mu.?);
        const sess = if (self.session) |*s| s else {
            _ = c.SDL_UnlockMutex(self.mu.?);
            break;
        };
        const opened = sess.open(wire[0..@intCast(n)], &plain) catch {
            _ = c.SDL_UnlockMutex(self.mu.?);
            continue;
        };
        self.peer_addr = from;
        self.peer_locked.store(true, .release);
        const cb = self.on_video_chunk;
        const cb_ctx = self.on_video_ctx;
        const fcb = self.on_video_frame;
        const fctx = self.on_frame_ctx;
        _ = c.SDL_UnlockMutex(self.mu.?);

        _ = self.packets_rx.fetchAdd(1, .monotonic);
        if (opened.msg_type == .video_chunk) {
            if (fcb != null and opened.payload.len > 7) {
                const rtp_ts = std.mem.readInt(u32, opened.payload[0..4], .big);
                const seq = std.mem.readInt(u16, opened.payload[4..6], .big);
                const marker = (opened.payload[6] & 1) != 0;
                const rtp_pay = opened.payload[7..];
                switch (assembler.pushH264(seq, rtp_ts, marker, rtp_pay)) {
                    .dropped => |dr| {
                        const now_ms = c.SDL_GetTicks();
                        if (dr.need_pli and now_ms - last_pli_ms >= 800) {
                            last_pli_ms = now_ms;
                            self.sendSealedType(.video_pli, &.{});
                        }
                    },
                    .frame => |au| {
                        if (!got_keyframe) {
                            if (hasH264Keyframe(au)) {
                                got_keyframe = true;
                            } else {
                                const now_ms = c.SDL_GetTicks();
                                if (now_ms - last_pli_ms >= 800) {
                                    last_pli_ms = now_ms;
                                    self.sendSealedType(.video_pli, &.{});
                                }
                                continue;
                            }
                        }
                        if (dec_opt == null) {
                            dec_opt = capture_backend.HwDecoder.open(.h264, 1920, 1080, null) catch null;
                        }
                        if (dec_opt) |*dc| {
                            const pts_us: i64 = @divTrunc(@as(i64, rtp_ts) * 1000, 90);
                            if (dc.decode(au, pts_us) catch null) |df| {
                                fcb.?(fctx, df.width, df.height, df.nv12_y, df.y_pitch, df.nv12_uv, df.uv_pitch, .h264, @intCast(c.SDL_GetTicks()));
                            }
                        }
                    },
                    else => {},
                }
            } else if (cb) |f| {
                f(cb_ctx, opened.payload);
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
