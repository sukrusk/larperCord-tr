//! Calls em DM e grupo: o que vai e o que vem do gateway, sem rede (testável).
//! Numa DM não há servidor: o op 4 manda `guild_id` null e o gateway de voz
//! recebe o próprio canal como `server_id`.
const std = @import("std");
const j = @import("jsonx.zig");
const ev = @import("../core/event.zig");
const Id = @import("../core/types.zig").Id;

fn flag(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Op 4 do gateway principal: entra (`channel`) ou sai (null) da call.
/// `guild` 0 = DM ou grupo.
pub fn voiceState(buf: []u8, guild: Id, channel: ?Id, mute: bool, deaf: bool) ?[]const u8 {
    return fmtVoiceState(buf, guild, channel, mute, deaf, null);
}

pub fn voiceStateVideo(buf: []u8, guild: Id, channel: ?Id, mute: bool, deaf: bool, video: bool) ?[]const u8 {
    return fmtVoiceState(buf, guild, channel, mute, deaf, video);
}

fn fmtVoiceState(buf: []u8, guild: Id, channel: ?Id, mute: bool, deaf: bool, video: ?bool) ?[]const u8 {
    var gb: [24]u8 = undefined;
    const g = if (guild != 0) std.fmt.bufPrint(&gb, "\"{d}\"", .{guild}) catch return null else "null";
    var cb: [24]u8 = undefined;
    const ch = if (channel) |cid| std.fmt.bufPrint(&cb, "\"{d}\"", .{cid}) catch return null else "null";
    if (video) |v| {
        return std.fmt.bufPrint(buf, "{{\"op\":4,\"d\":{{\"guild_id\":{s},\"channel_id\":{s},\"self_mute\":{s},\"self_deaf\":{s},\"self_video\":{s}}}}}", .{ g, ch, flag(mute), flag(deaf), flag(v) }) catch null;
    }
    return std.fmt.bufPrint(buf, "{{\"op\":4,\"d\":{{\"guild_id\":{s},\"channel_id\":{s},\"self_mute\":{s},\"self_deaf\":{s}}}}}", .{ g, ch, flag(mute), flag(deaf) }) catch null;
}

/// `server_id` do IDENTIFY e do RESUME da voz: o servidor, ou o canal numa DM.
pub fn serverId(guild: Id, channel: Id) Id {
    return if (guild != 0) guild else channel;
}

/// Grupo DAVE MLS: em transmissões Go Live o `group_id` é `rtc_server_id - 1`
/// mesmo quando `rtc_channel_id` difere do canal de voz; em chamadas é `channel_id`.
pub fn daveGroupId(is_stream: bool, server_id: Id, channel: Id) Id {
    if (is_stream and server_id > 0) return server_id -% 1;
    return channel;
}

/// Op 0 do gateway de voz. O texto leva o token: quem chama apaga depois.
pub fn writeIdentify(out: *std.ArrayList(u8), a: std.mem.Allocator, guild: Id, channel: Id, user: Id, session: []const u8, token: []const u8, max_dave: u16) !void {
    return writeIdentifyVideo(out, a, guild, channel, user, session, token, max_dave, false);
}

pub fn writeIdentifyVideo(out: *std.ArrayList(u8), a: std.mem.Allocator, guild: Id, channel: Id, user: Id, session: []const u8, token: []const u8, max_dave: u16, video: bool) !void {
    return writeIdentifyVideoKind(out, a, guild, channel, user, session, token, max_dave, video, "video");
}

pub fn writeIdentifyVideoKind(out: *std.ArrayList(u8), a: std.mem.Allocator, guild: Id, channel: Id, user: Id, session: []const u8, token: []const u8, max_dave: u16, video: bool, stream_type: []const u8) !void {
    try out.print(a, "{{\"op\":0,\"d\":{{\"server_id\":\"{d}\",\"user_id\":\"{d}\",\"session_id\":", .{ serverId(guild, channel), user });
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    if (video) {
        try out.print(a, ",\"video\":true,\"streams\":[{{\"type\":\"{s}\",\"rid\":\"100\",\"quality\":100}}],\"max_dave_protocol_version\":{d}}}}}", .{ stream_type, max_dave });
    } else {
        try out.print(a, ",\"video\":false,\"max_dave_protocol_version\":{d}}}}}", .{max_dave});
    }
}

/// Op 1 do gateway de voz: informa IP/porta UDP e declara codecs (Opus + H.264 encode/decode).
pub fn writeSelectProtocol(out: *std.ArrayList(u8), a: std.mem.Allocator, ip: []const u8, port: u16, include_video: bool) !void {
    try out.appendSlice(a, "{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":");
    try j.writeString(out, a, ip);
    try out.print(a, ",\"port\":{d},\"mode\":\"aead_xchacha20_poly1305_rtpsize\"}}", .{port});
    if (include_video) {
        try out.appendSlice(a, ",\"codecs\":[{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120},{\"name\":\"H264\",\"type\":\"video\",\"priority\":1000,\"payload_type\":101,\"rtx_payload_type\":102,\"encode\":true,\"decode\":true}],\"experiments\":[\"fixed_keyframe_interval\"]}}");
    } else {
        try out.appendSlice(a, ",\"codecs\":[{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120}]}}");
    }
}

/// Op 15 do gateway de voz: pede ao SFU envio dos fluxos de vídeo remotos em qualidade máxima.
pub fn writeMediaSinkWants(out: *std.ArrayList(u8), a: std.mem.Allocator, extra_ssrc: u32) !void {
    if (extra_ssrc != 0) {
        return writeMediaSinkWantsList(out, a, &.{extra_ssrc});
    }
    return writeMediaSinkWantsList(out, a, &.{});
}

pub fn writeMediaSinkWantsList(out: *std.ArrayList(u8), a: std.mem.Allocator, ssrcs: []const u32) !void {
    try out.appendSlice(a, "{\"op\":15,\"d\":{");
    var count: usize = 0;
    for (ssrcs, 0..) |s, idx| {
        if (s == 0) continue;
        var dup = false;
        for (ssrcs[0..idx]) |prev| {
            if (prev == s) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (count > 0) try out.append(a, ',');
        try out.print(a, "\"{d}\":100", .{s});
        count += 1;
    }
    if (count > 0) try out.append(a, ',');
    try out.appendSlice(a, "\"any\":100}}");
}

/// Op 22 do gateway principal: marca Go Live como ativo/despausado para espectadores.
pub fn streamSetPaused(buf: []u8, stream_key: []const u8, paused: bool) ?[]const u8 {
    if (stream_key.len == 0) return null;
    for (stream_key) |ch| if (ch == '"' or ch == '\\' or ch < 0x20) return null;
    return std.fmt.bufPrint(buf, "{{\"op\":22,\"d\":{{\"stream_key\":\"{s}\",\"paused\":{s}}}}}", .{ stream_key, flag(paused) }) catch null;
}

/// Op 12 do gateway de voz: anuncia SSRC de vídeo/RTX e resolução/FPS máximos.
pub fn writeVideoOp12(out: *std.ArrayList(u8), a: std.mem.Allocator, audio_ssrc: u32, video_ssrc: u32, rtx_ssrc: u32, active: bool, width: u16, height: u16, fps: u8, max_bitrate: u32) !void {
    return writeVideoOp12Kind(out, a, audio_ssrc, video_ssrc, rtx_ssrc, active, width, height, fps, max_bitrate, "video");
}

pub fn writeVideoOp12Kind(out: *std.ArrayList(u8), a: std.mem.Allocator, audio_ssrc: u32, video_ssrc: u32, rtx_ssrc: u32, active: bool, width: u16, height: u16, fps: u8, max_bitrate: u32, stream_type: []const u8) !void {
    if (!active or video_ssrc == 0) {
        try out.print(
            a,
            "{{\"op\":12,\"d\":{{\"audio_ssrc\":{d},\"video_ssrc\":0,\"rtx_ssrc\":0,\"streams\":[]}}}}",
            .{audio_ssrc},
        );
        return;
    }
    try out.print(
        a,
        "{{\"op\":12,\"d\":{{\"audio_ssrc\":{d},\"video_ssrc\":{d},\"rtx_ssrc\":{d},\"streams\":[{{\"type\":\"{s}\",\"rid\":\"100\",\"ssrc\":{d},\"rtx_ssrc\":{d},\"active\":true,\"quality\":100,\"max_bitrate\":{d},\"max_framerate\":{d},\"max_resolution\":{{\"type\":\"fixed\",\"width\":{d},\"height\":{d}}}}}]}}}}",
        .{ audio_ssrc, video_ssrc, rtx_ssrc, stream_type, video_ssrc, rtx_ssrc, max_bitrate, fps, width, height },
    );
}

/// Op 18 do gateway principal: inicia transmissão Go Live (canal de servidor ou DM/grupo).
pub fn streamCreate(buf: []u8, guild: Id, channel: Id) ?[]const u8 {
    if (guild != 0) {
        return std.fmt.bufPrint(buf, "{{\"op\":18,\"d\":{{\"type\":\"guild\",\"guild_id\":\"{d}\",\"channel_id\":\"{d}\",\"preferred_region\":null}}}}", .{ guild, channel }) catch null;
    }
    return std.fmt.bufPrint(buf, "{{\"op\":18,\"d\":{{\"type\":\"call\",\"channel_id\":\"{d}\"}}}}", .{channel}) catch null;
}

/// Op 20 do gateway principal: assistir a um Go Live ativo.
pub fn streamWatch(buf: []u8, stream_key: []const u8) ?[]const u8 {
    return fmtStreamKeyOp(buf, 20, stream_key);
}

/// Op 19 do gateway principal: encerrar/parar de assistir a um Go Live.
pub fn streamDelete(buf: []u8, stream_key: []const u8) ?[]const u8 {
    return fmtStreamKeyOp(buf, 19, stream_key);
}

fn fmtStreamKeyOp(buf: []u8, op: u8, stream_key: []const u8) ?[]const u8 {
    if (stream_key.len == 0) return null;
    for (stream_key) |ch| if (ch == '"' or ch == '\\' or ch < 0x20) return null;
    return std.fmt.bufPrint(buf, "{{\"op\":{d},\"d\":{{\"stream_key\":\"{s}\"}}}}", .{ op, stream_key }) catch null;
}

/// Op 7: retoma a sessão de voz depois de uma queda.
pub fn writeResume(out: *std.ArrayList(u8), a: std.mem.Allocator, guild: Id, channel: Id, session: []const u8, token: []const u8, seq_ack: i64) !void {
    try out.print(a, "{{\"op\":7,\"d\":{{\"server_id\":\"{d}\",\"session_id\":", .{serverId(guild, channel)});
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    try out.print(a, ",\"seq_ack\":{d}}}}}", .{seq_ack});
}

/// POST /channels/{id}/call/ring: toca para todo mundo da conversa.
pub const ring_body = "{\"recipients\":null}";

/// POST /channels/{id}/call/stop-ringing: recusar (para de tocar só para nós).
pub fn stopRingingBody(buf: []u8, me: Id) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"recipients\":[\"{d}\"]}}", .{me}) catch null;
}

/// CALL_CREATE / CALL_UPDATE (`ended` = CALL_DELETE). null = sem canal.
pub fn parse(d: std.json.Value, me: Id, ended: bool) ?ev.Call {
    const ch = j.id(j.get(d, "channel_id")) orelse return null;
    var out: ev.Call = .{ .channel = ch, .ended = ended };
    if (ended) return out;
    for (j.array(j.get(d, "ringing"))) |u| {
        const uid = j.id(u) orelse continue;
        if (uid == me) out.ringing_me = true else out.ringing +|= 1;
    }
    return out;
}

test "op 4 com self_video e op 18/19/20/12 de vídeo 4K" {
    var b: [512]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":\"10\",\"channel_id\":\"20\",\"self_mute\":false,\"self_deaf\":false,\"self_video\":true}}",
        voiceStateVideo(&b, 10, 20, false, false, true).?,
    );
    try t.expectEqualStrings(
        "{\"op\":18,\"d\":{\"type\":\"guild\",\"guild_id\":\"10\",\"channel_id\":\"20\",\"preferred_region\":null}}",
        streamCreate(&b, 10, 20).?,
    );
    try t.expectEqualStrings(
        "{\"op\":18,\"d\":{\"type\":\"call\",\"channel_id\":\"99\"}}",
        streamCreate(&b, 0, 99).?,
    );
    try t.expectEqualStrings(
        "{\"op\":20,\"d\":{\"stream_key\":\"guild:10:20:1003\"}}",
        streamWatch(&b, "guild:10:20:1003").?,
    );
    try t.expectEqualStrings(
        "{\"op\":19,\"d\":{\"stream_key\":\"guild:10:20:1003\"}}",
        streamDelete(&b, "guild:10:20:1003").?,
    );
    try t.expect(streamWatch(&b, "bad\"key") == null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try writeVideoOp12(&out, t.allocator, 100, 200, 201, true, 3840, 2160, 60, 18_000_000);
    try t.expect(std.mem.indexOf(u8, out.items, "\"op\":12") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"width\":3840,\"height\":2160") != null);

    out.clearRetainingCapacity();
    try writeVideoOp12(&out, t.allocator, 100, 0, 0, false, 1920, 1080, 30, 4_000_000);
    try t.expectEqualStrings("{\"op\":12,\"d\":{\"audio_ssrc\":100,\"video_ssrc\":0,\"rtx_ssrc\":0,\"streams\":[]}}", out.items);

    out.clearRetainingCapacity();
    try writeSelectProtocol(&out, t.allocator, "1.2.3.4", 50000, true);
    try t.expect(std.mem.indexOf(u8, out.items, "\"name\":\"H264\"") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"payload_type\":101,\"rtx_payload_type\":102") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"fixed_keyframe_interval\"") != null);

    out.clearRetainingCapacity();
    try writeMediaSinkWants(&out, t.allocator, 9988);
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"9988\":100,\"any\":100}}", out.items);

    out.clearRetainingCapacity();
    try writeMediaSinkWantsList(&out, t.allocator, &.{ 9988, 9999 });
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"9988\":100,\"9999\":100,\"any\":100}}", out.items);

    try t.expectEqualStrings("{\"op\":22,\"d\":{\"stream_key\":\"guild:10:20:1003\",\"paused\":false}}", streamSetPaused(&b, "guild:10:20:1003", false).?);
}

// --- Testes ----------------------------------------------------------------

const t = std.testing;

test "op 4 numa DM: guild_id null e o canal da conversa" {
    var b: [256]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":null,\"channel_id\":\"900001\",\"self_mute\":false,\"self_deaf\":true}}",
        voiceState(&b, 0, 900001, false, true).?,
    );
    // Sair da call da DM: os dois null.
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":null,\"channel_id\":null,\"self_mute\":true,\"self_deaf\":false}}",
        voiceState(&b, 0, null, true, false).?,
    );
}

test "op 4 num servidor continua com o guild_id" {
    var b: [256]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":\"81384788765712384\",\"channel_id\":\"500014\",\"self_mute\":false,\"self_deaf\":false}}",
        voiceState(&b, 81384788765712384, 500014, false, false).?,
    );
    // Sem espaço: não manda um JSON cortado.
    var tiny: [20]u8 = undefined;
    try t.expect(voiceState(&tiny, 1, 2, false, false) == null);
}

test "IDENTIFY e RESUME da voz: server_id é o canal numa DM" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeIdentify(&out, a, 0, 900001, 1000, "sess", "tk\"x", 1);
    try t.expectEqualStrings(
        "{\"op\":0,\"d\":{\"server_id\":\"900001\",\"user_id\":\"1000\",\"session_id\":\"sess\",\"token\":\"tk\\\"x\",\"video\":false,\"max_dave_protocol_version\":1}}",
        out.items,
    );
    out.clearRetainingCapacity();
    try writeIdentify(&out, a, 42, 500014, 1000, "s", "t", 1);
    try t.expect(std.mem.indexOf(u8, out.items, "\"server_id\":\"42\"") != null);
    out.clearRetainingCapacity();
    try writeResume(&out, a, 0, 900001, "s", "t", 7);
    try t.expectEqualStrings("{\"op\":7,\"d\":{\"server_id\":\"900001\",\"session_id\":\"s\",\"token\":\"t\",\"seq_ack\":7}}", out.items);
    try t.expectEqual(@as(Id, 900001), serverId(0, 900001));
    try t.expectEqual(@as(Id, 42), serverId(42, 900001));
}

test "recusar: stop-ringing só com o nosso id" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("{\"recipients\":[\"1000\"]}", stopRingingBody(&b, 1000).?);
    try t.expectEqualStrings("{\"recipients\":null}", ring_body);
}

test "CALL_CREATE / CALL_UPDATE / CALL_DELETE" {
    const a = t.allocator;
    const create =
        \\{"channel_id":"900001","message_id":"77","region":"brazil","ringing":["1000","1003"],"voice_states":[{"user_id":"1001","channel_id":"900001"}]}
    ;
    const p1 = try std.json.parseFromSlice(std.json.Value, a, create, .{});
    defer p1.deinit();
    const c1 = parse(p1.value, 1000, false).?;
    try t.expectEqual(@as(Id, 900001), c1.channel);
    try t.expect(c1.ringing_me and !c1.ended);
    try t.expectEqual(@as(u8, 1), c1.ringing);
    // Atendeu em outro aparelho (ou recusou): sai do `ringing`.
    const p2 = try std.json.parseFromSlice(std.json.Value, a, "{\"channel_id\":\"900001\",\"ringing\":[]}", .{});
    defer p2.deinit();
    const c2 = parse(p2.value, 1000, false).?;
    try t.expect(!c2.ringing_me and c2.ringing == 0);
    const p3 = try std.json.parseFromSlice(std.json.Value, a, "{\"channel_id\":\"900001\",\"unavailable\":false}", .{});
    defer p3.deinit();
    try t.expect(parse(p3.value, 1000, true).?.ended);
    // Sem canal não vale.
    const p4 = try std.json.parseFromSlice(std.json.Value, a, "{\"ringing\":[\"1000\"]}", .{});
    defer p4.deinit();
    try t.expect(parse(p4.value, 1000, false) == null);
}

test "daveGroupId usa rtc_server_id - 1 para Go Live e channel para chamada" {
    try t.expectEqual(@as(Id, 2000), daveGroupId(false, 1000, 2000));
    try t.expectEqual(@as(Id, 8999), daveGroupId(true, 9000, 7777));
    try t.expectEqual(@as(Id, 2000), daveGroupId(true, 0, 2000));
}
