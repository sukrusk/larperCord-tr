//! Túnel UDP via SOCKS5 `UDP ASSOCIATE` (RFC 1928 + auth RFC 1929).
//! Mantém o socket TCP de controle vivo durante a sessão de voz/vídeo e encapsula
//! datagramas RTP/RTCP/IP Discovery através do relay UDP retornado pelo proxy.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const proxy = @import("proxy.zig");
const c = @import("c");

pub const OpenError = error{
    NotSocks5,
    BadProxyUrl,
    HostResolveFailed,
    ConnectFailed,
    HandshakeFailed,
    AuthFailed,
    UdpAssociateRejected,
    UnsupportedRelayAddr,
};

pub const Tunnel = struct {
    tcp: sys.Socket = sys.no_socket,
    relay: sys.SockAddrIn = std.mem.zeroes(sys.SockAddrIn),
    active: bool = false,

    pub fn close(t: *Tunnel) void {
        if (sys.valid(t.tcp)) sys.closeSocket(t.tcp);
        t.* = .{};
    }
};

/// Abre associação UDP num proxy SOCKS5/SOCKS5H (`socks5://[u[:p]@]host[:porta]`).
pub fn open(proxy_url: []const u8) OpenError!Tunnel {
    var form: proxy.Form = .{};
    if (!form.fill(proxy_url)) {
        form.load(proxy_url);
        if (form.empty()) return error.BadProxyUrl;
    }
    const kind = form.kindOf();
    if (kind != .socks5 and kind != .socks5h) return error.NotSocks5;

    const host_s = std.mem.trim(u8, std.mem.sliceTo(&form.host, 0), " \t[]");
    if (host_s.len == 0 or host_s.len > 253) return error.BadProxyUrl;
    var host_z: [256:0]u8 = @splat(0);
    @memcpy(host_z[0..host_s.len], host_s);
    const port_s = std.mem.trim(u8, std.mem.sliceTo(&form.port, 0), " \t");
    const port: u16 = if (port_s.len > 0) (std.fmt.parseInt(u16, port_s, 10) catch return error.BadProxyUrl) else kind.defaultPort();
    if (port == 0) return error.BadProxyUrl;

    const proxy_ip = sys.resolveHostIp4(&host_z) orelse return error.HostResolveFailed;
    const tcp = sys.tcpConnectIp4(proxy_ip, port, 2500) orelse return error.ConnectFailed;
    errdefer sys.closeSocket(tcp);

    const user = std.mem.sliceTo(&form.user, 0);
    const pass = std.mem.sliceTo(&form.pass, 0);
    const has_auth = user.len > 0 or pass.len > 0;

    // 1. Saudação SOCKS5 (sem auth, ou no-auth + user/pass RFC 1929).
    var greet = [4]u8{ 0x05, if (has_auth) 2 else 1, 0x00, 0x02 };
    const greet_len: usize = if (has_auth) 4 else 3;
    if (!sys.tcpSendAll(tcp, greet[0..greet_len], 2000)) return error.HandshakeFailed;

    var choice: [2]u8 = undefined;
    if (!sys.tcpRecvExact(tcp, &choice, 2500) or choice[0] != 0x05) return error.HandshakeFailed;
    if (choice[1] == 0xFF) return error.AuthFailed;
    if (choice[1] == 0x02) {
        if (!has_auth or user.len > 255 or pass.len > 255) return error.AuthFailed;
        var abuf: [515]u8 = undefined;
        abuf[0] = 0x01;
        abuf[1] = @intCast(user.len);
        @memcpy(abuf[2..][0..user.len], user);
        const p_off = 2 + user.len;
        abuf[p_off] = @intCast(pass.len);
        @memcpy(abuf[p_off + 1 ..][0..pass.len], pass);
        if (!sys.tcpSendAll(tcp, abuf[0 .. p_off + 1 + pass.len], 2000)) return error.AuthFailed;
        var arsp: [2]u8 = undefined;
        if (!sys.tcpRecvExact(tcp, &arsp, 2500) or arsp[1] != 0x00) return error.AuthFailed;
    } else if (choice[1] != 0x00) {
        return error.HandshakeFailed;
    }

    // 2. CMD=0x03 (UDP ASSOCIATE) para 0.0.0.0:0.
    const req = [_]u8{ 0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
    if (!sys.tcpSendAll(tcp, &req, 2000)) return error.HandshakeFailed;

    var hdr: [4]u8 = undefined;
    if (!sys.tcpRecvExact(tcp, &hdr, 2500) or hdr[0] != 0x05) return error.HandshakeFailed;
    if (hdr[1] != 0x00) return error.UdpAssociateRejected;

    var bnd_ip: [4]u8 = proxy_ip;
    switch (hdr[3]) {
        0x01 => {
            var addr4: [4]u8 = undefined;
            if (!sys.tcpRecvExact(tcp, &addr4, 2000)) return error.HandshakeFailed;
            if (!(addr4[0] == 0 and addr4[1] == 0 and addr4[2] == 0 and addr4[3] == 0)) bnd_ip = addr4;
        },
        0x03 => {
            var dlen: [1]u8 = undefined;
            if (!sys.tcpRecvExact(tcp, &dlen, 2000)) return error.HandshakeFailed;
            var dom: [256:0]u8 = @splat(0);
            if (!sys.tcpRecvExact(tcp, dom[0..dlen[0]], 2000)) return error.HandshakeFailed;
            bnd_ip = sys.resolveHostIp4(&dom) orelse proxy_ip;
        },
        else => return error.UnsupportedRelayAddr,
    }
    var pbytes: [2]u8 = undefined;
    if (!sys.tcpRecvExact(tcp, &pbytes, 2000)) return error.HandshakeFailed;
    const bnd_port = std.mem.readInt(u16, &pbytes, .big);
    if (bnd_port == 0) return error.UdpAssociateRejected;

    var relay = std.mem.zeroes(sys.SockAddrIn);
    relay.sin_family = c.AF_INET;
    relay.sin_port = std.mem.nativeToBig(u16, bnd_port);
    @memcpy(@as(*[4]u8, @ptrCast(&relay.sin_addr)), &bnd_ip);

    return .{ .tcp = tcp, .relay = relay, .active = true };
}

/// Encapsula payload UDP num datagrama SOCKS5 IPv4 (header de 10 bytes + payload).
pub fn wrapPacket(dst_ip: [4]u8, dst_port: u16, payload: []const u8, out: []u8) ?[]const u8 {
    if (out.len < 10 + payload.len) return null;
    out[0] = 0x00;
    out[1] = 0x00;
    out[2] = 0x00; // FRAG=0
    out[3] = 0x01; // ATYP=IPv4
    @memcpy(out[4..8], &dst_ip);
    std.mem.writeInt(u16, out[8..10], dst_port, .big);
    @memcpy(out[10..][0..payload.len], payload);
    return out[0 .. 10 + payload.len];
}

/// Remove cabeçalho SOCKS5 UDP e devolve somente os bytes do payload RTP/RTCP.
/// Pacotes fragmentados (`FRAG != 0`) ou truncados retornam `null`.
pub fn unwrapPacket(raw: []const u8) ?[]const u8 {
    if (raw.len < 4) return null;
    if (raw[2] != 0x00) return null; // Fragmentado não é aceito.
    const hdr_len: usize = switch (raw[3]) {
        0x01 => 4 + 4 + 2,
        0x03 => blk: {
            if (raw.len < 5) return null;
            break :blk 4 + 1 + @as(usize, raw[4]) + 2;
        },
        0x04 => 4 + 16 + 2,
        else => return null,
    };
    if (raw.len <= hdr_len) return null;
    return raw[hdr_len..];
}

/// Endereço IPv4 + porta de `SockAddrIn` para usar em `wrapPacket`.
pub fn addrParts(sa: *const sys.SockAddrIn) struct { ip: [4]u8, port: u16 } {
    return .{
        .ip = @as(*const [4]u8, @ptrCast(&sa.sin_addr)).*,
        .port = std.mem.bigToNative(u16, sa.sin_port),
    };
}

test "socks5 udp encapsula e desencapsula IPv4, domínio e IPv6" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const pkt = wrapPacket(.{ 66, 22, 196, 10 }, 50001, "hello-rtp", &buf).?;
    try t.expectEqual(@as(usize, 19), pkt.len);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 66, 22, 196, 10, 0xC3, 0x51 }, pkt[0..10]);
    try t.expectEqualStrings("hello-rtp", unwrapPacket(pkt).?);

    // ATYP=3 (domínio "a.b" + porta + payload "ok")
    const dom_pkt = [_]u8{ 0, 0, 0, 3, 3, 'a', '.', 'b', 0x13, 0x88, 'o', 'k' };
    try t.expectEqualStrings("ok", unwrapPacket(&dom_pkt).?);

    // ATYP=4 (IPv6 16 bytes + porta + "v6")
    var v6_pkt: [24]u8 = @splat(0);
    v6_pkt[3] = 4;
    v6_pkt[21] = 80;
    v6_pkt[22] = 'v';
    v6_pkt[23] = '6';
    try t.expectEqualStrings("v6", unwrapPacket(&v6_pkt).?);

    // Fragmentado -> rejeita
    var frag: [12]u8 = @splat(0);
    @memcpy(&frag, pkt[0..12]);
    frag[2] = 1;
    try t.expect(unwrapPacket(&frag) == null);
    try t.expect(unwrapPacket(pkt[0..10]) == null);
}
