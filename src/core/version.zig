//! A versão do app e o que dá para decidir sem rede sobre uma atualização:
//! comparar versões, ler o SHA256SUMS e conferir a assinatura dele.
const std = @import("std");

pub const number = "0.6.9";

/// Opção de chave pública Ed25519 para lançamentos assinados; vazio usa
/// verificação SHA-256 sobre HTTPS a partir dos lançamentos oficiais no GitHub.
pub const release_key_hex = "";

const Triple = struct { major: u32, minor: u32, patch: u32 };

fn parse(tag_in: []const u8) ?Triple {
    const tag = if (tag_in.len > 0 and tag_in[0] == 'v') tag_in[1..] else tag_in;
    var it = std.mem.splitScalar(u8, tag, '.');
    const a = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const p = it.next() orelse "0";
    const c = std.fmt.parseInt(u32, p, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .major = a, .minor = b, .patch = c };
}

/// `tag` é mais nova que `current`? Versão que não dá para ler nunca é.
pub fn newer(tag: []const u8, current: []const u8) bool {
    const t = parse(tag) orelse return false;
    const n = parse(current) orelse return false;
    if (t.major != n.major) return t.major > n.major;
    if (t.minor != n.minor) return t.minor > n.minor;
    return t.patch > n.patch;
}

/// O hash de `name` num arquivo no formato do `sha256sum`.
pub fn sumFor(sums: []const u8, name: []const u8) ?[32]u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " *");
        const hex = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (!std.mem.eql(u8, file, name)) continue;
        return parseSha256Hex(hex);
    }
    return null;
}

/// Faz o parse de 64 hexadecimais (com ou sem prefixo "sha256:").
pub fn parseSha256Hex(raw: []const u8) ?[32]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    const hex = if (std.mem.startsWith(u8, s, "sha256:")) s["sha256:".len..] else s;
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// `sig_hex`: a assinatura Ed25519 de `sums`, em hexadecimal.
pub fn signatureOk(sums: []const u8, sig_hex: []const u8, key_hex: []const u8) bool {
    const Ed = std.crypto.sign.Ed25519;
    var key: [Ed.PublicKey.encoded_length]u8 = undefined;
    var sig: [Ed.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, std.mem.trim(u8, key_hex, " \r\n")) catch return false;
    _ = std.fmt.hexToBytes(&sig, std.mem.trim(u8, sig_hex, " \r\n")) catch return false;
    const pk = Ed.PublicKey.fromBytes(key) catch return false;
    Ed.Signature.fromBytes(sig).verify(sums, pk) catch return false;
    return true;
}

test "comparar versões" {
    const t = std.testing;
    try t.expect(newer("v0.5.1", "0.5.0"));
    try t.expect(newer("0.6", "0.5.9"));
    try t.expect(newer("v1.0.0", "0.99.99"));
    try t.expect(!newer("v0.5.0", "0.5.0"));
    try t.expect(!newer("v0.4.9", "0.5.0"));
    try t.expect(!newer("nightly", "0.5.0"));
    try t.expect(!newer("v0.5.0-rc1", "0.4.0"));
    try t.expect(!newer("v1.2.3.4", "0.1.0"));
}

test "SHA256SUMS" {
    const t = std.testing;
    const sums = "abababababababababababababababababababababababababababababababab  larpercord-linux-x86_64\r\n" ++ "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd *SDL3.dll\n";
    try t.expectEqual(@as(u8, 0xab), sumFor(sums, "larpercord-linux-x86_64").?[0]);
    try t.expectEqual(@as(u8, 0xcd), sumFor(sums, "SDL3.dll").?[31]);
    try t.expect(sumFor(sums, "outro") == null);
    try t.expect(sumFor("curto  a\n", "a") == null);
    try t.expectEqual(@as(u8, 0xab), parseSha256Hex("sha256:abababababababababababababababababababababababababababababababab").?[0]);
    try t.expect(parseSha256Hex("sha256:short") == null);
}

test "assinatura: só a chave certa e o texto certo" {
    const t = std.testing;
    const Ed = std.crypto.sign.Ed25519;
    const kp = try Ed.KeyPair.generateDeterministic(@splat(7));
    const msg = "abc  larpercord\n";
    const sig = try kp.sign(msg, null);
    var sb: [128]u8 = undefined;
    var kb: [64]u8 = undefined;
    const sig_hex = std.fmt.bufPrint(&sb, "{x}", .{&sig.toBytes()}) catch unreachable;
    const key_hex = std.fmt.bufPrint(&kb, "{x}", .{&kp.public_key.toBytes()}) catch unreachable;
    try t.expect(signatureOk(msg, sig_hex, key_hex));
    try t.expect(!signatureOk("abd  larpercord\n", sig_hex, key_hex));
    const other = try Ed.KeyPair.generateDeterministic(@splat(9));
    var ob: [64]u8 = undefined;
    const other_hex = std.fmt.bufPrint(&ob, "{x}", .{&other.public_key.toBytes()}) catch unreachable;
    try t.expect(!signatureOk(msg, sig_hex, other_hex));
    try t.expect(!signatureOk(msg, "zz", key_hex));
}
