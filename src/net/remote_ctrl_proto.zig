//! Camada criptográfica e protocolo P2P para controle remoto estilo AnyDesk e
//! vídeo 4K direto (sem depender dos limites de bitrate do Discord):
//! - Troca de chaves X25519 + HKDF-SHA256 com PIN/nonce da sessão.
//! - Enquadramento AEAD XChaCha20-Poly1305 com proteção anti-replay monotônica.
//! - Construção/decodificação STUN (RFC 5389) para travessia NAT UDP.
const std = @import("std");
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const video_cfg = @import("../core/video_cfg.zig");

pub const proto_magic: [2]u8 = .{ 0x4C, 0x52 }; // "LR"

pub const MsgType = enum(u8) {
    hello = 1,
    input = 2,
    ping = 3,
    pong = 4,
    release_all = 5,
    host_info = 6,
    video_chunk = 0x10,
    video_pli = 0x11,
};

pub const HostInfo = struct {
    display_count: u8 = 1,
    active_display: u8 = 0,
    perm: video_cfg.RemotePerm = .off,
    target_kind: video_cfg.RemoteTargetKind = .virtual_desktop,
    width: u16 = 0,
    height: u16 = 0,

    pub const wire_len = 8;

    pub fn encode(self: HostInfo, out: *[wire_len]u8) void {
        out[0] = self.display_count;
        out[1] = self.active_display;
        out[2] = @intFromEnum(self.perm);
        out[3] = @intFromEnum(self.target_kind);
        std.mem.writeInt(u16, out[4..6], self.width, .little);
        std.mem.writeInt(u16, out[6..8], self.height, .little);
    }

    pub fn decode(raw: []const u8) ?HostInfo {
        if (raw.len < wire_len) return null;
        return .{
            .display_count = raw[0],
            .active_display = raw[1],
            .perm = std.enums.fromInt(video_cfg.RemotePerm, raw[2]) orelse .off,
            .target_kind = std.enums.fromInt(video_cfg.RemoteTargetKind, raw[3]) orelse .virtual_desktop,
            .width = std.mem.readInt(u16, raw[4..6], .little),
            .height = std.mem.readInt(u16, raw[6..8], .little),
        };
    }
};

pub const Role = enum(u8) {
    host = 1,
    viewer = 2,
};

pub const overhead = 1 + 8 + 16; // msg_type + seq(u64) + Poly1305 tag(16)

pub const Session = struct {
    role: Role,
    tx_key: [32]u8,
    rx_key: [32]u8,
    tx_seq: u64 = 1,
    rx_max_seq: u64 = 0,
    perm: video_cfg.RemotePerm = .off,

    pub fn derive(role: Role, my_secret: [32]u8, peer_pub: [32]u8, session_pin: u32) !Session {
        const shared = try X25519.scalarmult(my_secret, peer_pub);
        var salt: [12]u8 = undefined;
        @memcpy(salt[0..8], "LRPC-RC1");
        std.mem.writeInt(u32, salt[8..12], session_pin, .little);

        const prk = Hkdf.extract(&salt, &shared);
        var host_to_viewer: [32]u8 = undefined;
        var viewer_to_host: [32]u8 = undefined;
        Hkdf.expand(&host_to_viewer, "host->viewer", prk);
        Hkdf.expand(&viewer_to_host, "viewer->host", prk);

        return .{
            .role = role,
            .tx_key = if (role == .host) host_to_viewer else viewer_to_host,
            .rx_key = if (role == .host) viewer_to_host else host_to_viewer,
        };
    }

    pub fn makeKeyPair(seed: [32]u8) X25519.KeyPair {
        return X25519.KeyPair.generateDeterministic(seed);
    }

    fn buildNonce(dir_byte: u8, seq: u64) [24]u8 {
        var n: [24]u8 = @splat(0);
        n[0] = dir_byte;
        std.mem.writeInt(u64, n[16..24], seq, .little);
        return n;
    }

    /// Criptografa `payload` com `[magic:2][msg_type:1][seq:8][cipher...][tag:16]`.
    pub fn seal(self: *Session, msg_type: MsgType, payload: []const u8, out: []u8) ![]const u8 {
        const hdr_len = 2 + 1 + 8;
        const need = hdr_len + payload.len + 16;
        if (out.len < need) return error.BufferTooSmall;

        const seq = self.tx_seq;
        self.tx_seq += 1;

        out[0] = proto_magic[0];
        out[1] = proto_magic[1];
        out[2] = @intFromEnum(msg_type);
        std.mem.writeInt(u64, out[3..11], seq, .little);

        const dir_byte: u8 = @intFromEnum(self.role);
        const nonce = buildNonce(dir_byte, seq);
        var tag: [16]u8 = undefined;
        Aead.encrypt(out[hdr_len..][0..payload.len], &tag, payload, out[0..hdr_len], nonce, self.tx_key);
        @memcpy(out[hdr_len + payload.len ..][0..16], &tag);
        return out[0..need];
    }

    pub const Opened = struct {
        msg_type: MsgType,
        seq: u64,
        payload: []const u8,
    };

    /// Verifica tag Poly1305 e anti-replay monotônico antes de retornar plaintext em `out_plain`.
    pub fn open(self: *Session, raw: []const u8, out_plain: []u8) !Opened {
        const hdr_len = 2 + 1 + 8;
        if (raw.len < hdr_len + 16) return error.TruncatedPacket;
        if (raw[0] != proto_magic[0] or raw[1] != proto_magic[1]) return error.BadMagic;

        const msg_type = std.enums.fromInt(MsgType, raw[2]) orelse return error.UnknownMsgType;
        const seq = std.mem.readInt(u64, raw[3..11], .little);
        if (seq == 0 or seq <= self.rx_max_seq) return error.ReplayOrOldSeq;

        const cipher_len = raw.len - hdr_len - 16;
        if (out_plain.len < cipher_len) return error.BufferTooSmall;

        const peer_dir: u8 = if (self.role == .host) @intFromEnum(Role.viewer) else @intFromEnum(Role.host);
        const nonce = buildNonce(peer_dir, seq);
        var tag: [16]u8 = undefined;
        @memcpy(&tag, raw[hdr_len + cipher_len ..][0..16]);

        try Aead.decrypt(out_plain[0..cipher_len], raw[hdr_len..][0..cipher_len], tag, raw[0..hdr_len], nonce, self.rx_key);
        self.rx_max_seq = seq;

        return .{
            .msg_type = msg_type,
            .seq = seq,
            .payload = out_plain[0..cipher_len],
        };
    }

    /// Filtra pacote de controle remoto conforme a permissão explícita atual do host.
    pub fn allowInput(self: *const Session, pkt: video_cfg.RemoteInputPacket) bool {
        if (self.perm == .off) return false;
        return switch (pkt.kind) {
            .mouse_move, .mouse_btn, .mouse_wheel, .release_all, .ping, .pong, .switch_display => true,
            .key => self.perm == .full,
        };
    }

    pub fn wipe(self: *Session) void {
        self.perm = .off;
        std.crypto.secureZero(u8, &self.tx_key);
        std.crypto.secureZero(u8, &self.rx_key);
    }
};

// ---------------------------------------------------------------------------
// STUN Binding Request / Response (RFC 5389) — NAT Traversal IPv4 leve
// ---------------------------------------------------------------------------

pub const stun_magic_cookie: u32 = 0x2112A442;

pub fn buildStunBindingRequest(out: *[20]u8, txn_id: [12]u8) void {
    std.mem.writeInt(u16, out[0..2], 0x0001, .big); // Binding Request
    std.mem.writeInt(u16, out[2..4], 0, .big); // length = 0
    std.mem.writeInt(u32, out[4..8], stun_magic_cookie, .big);
    @memcpy(out[8..20], &txn_id);
}

pub const StunAddr = struct {
    ip4: [4]u8,
    port: u16,
};

pub fn parseStunBindingResponse(raw: []const u8, expected_txn: [12]u8) ?StunAddr {
    if (raw.len < 20) return null;
    const msg_type = std.mem.readInt(u16, raw[0..2], .big);
    if (msg_type != 0x0101) return null; // Binding Success Response
    const msg_len = std.mem.readInt(u16, raw[2..4], .big);
    if (raw.len < 20 + msg_len) return null;
    if (std.mem.readInt(u32, raw[4..8], .big) != stun_magic_cookie) return null;
    if (!std.mem.eql(u8, raw[8..20], &expected_txn)) return null;

    var off: usize = 20;
    const end = 20 + msg_len;
    while (off + 4 <= end) {
        const attr_t = std.mem.readInt(u16, raw[off..][0..2], .big);
        const attr_l = std.mem.readInt(u16, raw[off + 2 ..][0..2], .big);
        off += 4;
        if (off + attr_l > end) break;
        const val = raw[off..][0..attr_l];
        if ((attr_t == 0x0020 or attr_t == 0x0001) and attr_l >= 8 and val[1] == 0x01) {
            const raw_port = std.mem.readInt(u16, val[2..4], .big);
            const raw_ip = std.mem.readInt(u32, val[4..8], .big);
            const port: u16 = if (attr_t == 0x0020) raw_port ^ @as(u16, @truncate(stun_magic_cookie >> 16)) else raw_port;
            const ip_u32: u32 = if (attr_t == 0x0020) raw_ip ^ stun_magic_cookie else raw_ip;
            var ip4: [4]u8 = undefined;
            std.mem.writeInt(u32, &ip4, ip_u32, .big);
            return .{ .ip4 = ip4, .port = port };
        }
        // Atributos STUN têm padding de 4 bytes.
        off += (attr_l + 3) & ~@as(usize, 3);
    }
    return null;
}

const t = std.testing;

test "túnel AnyDesk X25519 + XChaCha20-Poly1305 protege e rejeita replay" {
    const h_kp = Session.makeKeyPair(@splat(1));
    const v_kp = Session.makeKeyPair(@splat(2));

    var host = try Session.derive(.host, h_kp.secret_key, v_kp.public_key, 482910);
    defer host.wipe();
    var viewer = try Session.derive(.viewer, v_kp.secret_key, h_kp.public_key, 482910);
    defer viewer.wipe();

    host.perm = .mouse_only;

    var pkt_bytes: [video_cfg.RemoteInputPacket.wire_len]u8 = undefined;
    const mv: video_cfg.RemoteInputPacket = .{ .kind = .mouse_move, .x = 32768, .y = 16384, .seq = 1 };
    mv.encode(&pkt_bytes);

    var wire: [128]u8 = undefined;
    const sealed = try viewer.seal(.input, &pkt_bytes, &wire);

    var plain: [128]u8 = undefined;
    const opened = try host.open(sealed, &plain);
    try t.expectEqual(MsgType.input, opened.msg_type);
    const dec = video_cfg.RemoteInputPacket.decode(opened.payload).?;
    try t.expectEqual(@as(u16, 32768), dec.x);
    try t.expect(host.allowInput(dec));

    // Replay do mesmo pacote deve falhar.
    try t.expectError(error.ReplayOrOldSeq, host.open(sealed, &plain));

    // Em modo mouse_only, tecla de teclado é bloqueada mesmo autenticada.
    const k_pkt: video_cfg.RemoteInputPacket = .{ .kind = .key, .code = 4, .pressed = true, .seq = 2 };
    try t.expect(!host.allowInput(k_pkt));
    host.perm = .full;
    try t.expect(host.allowInput(k_pkt));
}

test "STUN Binding Request e XOR-MAPPED-ADDRESS IPv4" {
    var req: [20]u8 = undefined;
    const txn = [12]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    buildStunBindingRequest(&req, txn);
    try t.expectEqual(@as(u16, 0x0001), std.mem.readInt(u16, req[0..2], .big));

    // Resposta simulada com XOR-MAPPED-ADDRESS 203.0.113.45:51820.
    var resp: [32]u8 = undefined;
    std.mem.writeInt(u16, resp[0..2], 0x0101, .big);
    std.mem.writeInt(u16, resp[2..4], 12, .big);
    std.mem.writeInt(u32, resp[4..8], stun_magic_cookie, .big);
    @memcpy(resp[8..20], &txn);
    std.mem.writeInt(u16, resp[20..22], 0x0020, .big);
    std.mem.writeInt(u16, resp[22..24], 8, .big);
    resp[24] = 0;
    resp[25] = 0x01; // IPv4
    std.mem.writeInt(u16, resp[26..28], 51820 ^ @as(u16, @truncate(stun_magic_cookie >> 16)), .big);
    const ip_u32 = std.mem.readInt(u32, &.{ 203, 0, 113, 45 }, .big);
    std.mem.writeInt(u32, resp[28..32], ip_u32 ^ stun_magic_cookie, .big);

    const parsed = parseStunBindingResponse(&resp, txn).?;
    try t.expectEqual(@as(u16, 51820), parsed.port);
    try t.expectEqualSlices(u8, &.{ 203, 0, 113, 45 }, &parsed.ip4);
}

test "HostInfo encode/decode and switch_display permission check" {
    const hi: HostInfo = .{
        .display_count = 3,
        .active_display = 1,
        .perm = .full,
        .target_kind = .monitor,
        .width = 2560,
        .height = 1440,
    };
    var buf: [HostInfo.wire_len]u8 = undefined;
    hi.encode(&buf);
    const dec = HostInfo.decode(&buf).?;
    try t.expectEqual(@as(u8, 3), dec.display_count);
    try t.expectEqual(@as(u8, 1), dec.active_display);
    try t.expectEqual(video_cfg.RemotePerm.full, dec.perm);
    try t.expectEqual(video_cfg.RemoteTargetKind.monitor, dec.target_kind);
    try t.expectEqual(@as(u16, 2560), dec.width);
    try t.expectEqual(@as(u16, 1440), dec.height);

    const h_kp = Session.makeKeyPair(@splat(3));
    const v_kp = Session.makeKeyPair(@splat(4));
    var sess = try Session.derive(.host, h_kp.secret_key, v_kp.public_key, 123456);
    defer sess.wipe();
    sess.perm = .mouse_only;
    try t.expect(sess.allowInput(.{ .kind = .switch_display, .code = 2 }));
    sess.perm = .off;
    try t.expect(!sess.allowInput(.{ .kind = .switch_display, .code = 2 }));
}
