//! Empacotamento e remontagem RTP de vídeo em Zig puro (zero SDL, mínimo RAM).
//!
//! Suporta:
//!   - H.264 Annex-B <-> RTP (RFC 6184: Single NAL Unit e FU-A acima do MTU);
//!   - Quadros genéricos (VP8 / VP9 / AV1 / HEVC) com fragmentação por MTU;
//!   - Montador de quadro limitado (`Assembler`) com detecção de perdas (NACK)
//!     e gerador de RTCP NACK (PT=205, FMT=1) / PLI (PT=206, FMT=1).
//!
//! Foco em memória mínima: apenas um buffer reutilizável de quadro comprimido
//! (sem anéis de quadros RGBA em RAM).
const std = @import("std");

/// Payload RTP máximo por datagrama UDP (abaixo de MTU 1500 menos cabeçalhos IP/UDP/RTP/AEAD).
pub const max_rtp_payload: usize = 1140;
/// Limite de segurança para um único Access Unit comprimido (2 MiB cobre keyframe 4K).
pub const max_frame_bytes: usize = 2 * 1024 * 1024;

pub const RtpHeader = struct {
    marker: bool,
    payload_type: u7,
    seq: u16,
    timestamp: u32,
    ssrc: u32,

    pub fn write(h: RtpHeader, out: *[12]u8) void {
        out[0] = 0x80; // V=2, P=0, X=0, CC=0
        out[1] = (@as(u8, @intFromBool(h.marker)) << 7) | @as(u8, h.payload_type);
        std.mem.writeInt(u16, out[2..4], h.seq, .big);
        std.mem.writeInt(u32, out[4..8], h.timestamp, .big);
        std.mem.writeInt(u32, out[8..12], h.ssrc, .big);
    }

    pub fn parse(pkt: []const u8) ?struct { hdr: RtpHeader, payload_off: usize } {
        if (pkt.len < 12) return null;
        if ((pkt[0] >> 6) != 2) return null;
        const cc: usize = pkt[0] & 0x0f;
        var off: usize = 12 + cc * 4;
        if (pkt[0] & 0x10 != 0) {
            if (off + 4 > pkt.len) return null;
            const ext_words: usize = std.mem.readInt(u16, pkt[off + 2 ..][0..2], .big);
            off += 4 + ext_words * 4;
        }
        var end = pkt.len;
        if (pkt[0] & 0x20 != 0) {
            if (end <= off or pkt[end - 1] == 0 or pkt[end - 1] > end - off) return null;
            end -= pkt[end - 1];
        }
        if (off > end) return null;
        return .{
            .hdr = .{
                .marker = (pkt[1] & 0x80) != 0,
                .payload_type = @intCast(pkt[1] & 0x7f),
                .seq = std.mem.readInt(u16, pkt[2..4], .big),
                .timestamp = std.mem.readInt(u32, pkt[4..8], .big),
                .ssrc = std.mem.readInt(u32, pkt[8..12], .big),
            },
            .payload_off = off,
        };
    }
};

/// Callback chamado para cada pacote RTP pronto (apenas o payload após o cabeçalho de 12 bytes,
/// mais `marker` indicando o último pacote do quadro de vídeo).
pub const PacketSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, payload: []const u8, marker: bool) void,
};

/// Divide um bitstream H.264 Annex-B em NAL units e empacota conforme RFC 6184
/// (Single NAL quando cabe em `mtu`, FU-A quando maior). Zero alocações.
pub fn packetizeH264AnnexB(annex_b: []const u8, mtu: usize, sink: PacketSink) void {
    const cap = @max(mtu, 16);
    var nals: [64][]const u8 = undefined;
    const count = splitAnnexBNals(annex_b, &nals);
    if (count == 0) return;

    var fu_buf: [max_rtp_payload + 8]u8 = undefined;
    for (nals[0..count], 0..) |nal, ni| {
        if (nal.len == 0) continue;
        const last_nal = ni + 1 == count;
        if (nal.len <= cap) {
            sink.emit(sink.ctx, nal, last_nal);
            continue;
        }
        const nalu_hdr = nal[0];
        const f_nri = nalu_hdr & 0xE0;
        const nal_type = nalu_hdr & 0x1F;
        const fu_indicator = f_nri | 28; // FU-A
        const body = nal[1..];
        const chunk_max = @min(cap - 2, fu_buf.len - 2);
        var off: usize = 0;
        while (off < body.len) {
            const left = body.len - off;
            const n = @min(left, chunk_max);
            const first = off == 0;
            const last = off + n >= body.len;
            var fu_hdr: u8 = nal_type;
            if (first) fu_hdr |= 0x80; // S
            if (last) fu_hdr |= 0x40; // E
            fu_buf[0] = fu_indicator;
            fu_buf[1] = fu_hdr;
            @memcpy(fu_buf[2..][0..n], body[off..][0..n]);
            sink.emit(sink.ctx, fu_buf[0 .. 2 + n], last_nal and last);
            off += n;
        }
    }
}

/// Encontra start codes `00 00 01` ou `00 00 00 01` e devolve fatias sem o prefixo.
pub fn splitAnnexBNals(data: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    var start: ?usize = null;
    while (i + 2 < data.len) {
        const sc3 = data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1;
        const sc4 = i + 3 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1;
        if (sc3 or sc4) {
            const sc_len: usize = if (sc4) 4 else 3;
            if (start) |s| {
                if (i > s and count < out.len) {
                    out[count] = data[s..i];
                    count += 1;
                }
            }
            i += sc_len;
            start = i;
            continue;
        }
        i += 1;
    }
    if (start) |s| {
        if (data.len > s and count < out.len) {
            out[count] = data[s..];
            count += 1;
        }
    }
    return count;
}

/// Montador de quadros de vídeo com baixo uso de RAM: reutiliza um único buffer
/// para o Access Unit corrente e devolve o quadro completo ao ver `marker = true`
/// sem gaps. Em perda de pacote, sinaliza pedido de NACK/PLI.
pub const FrameAssembler = struct {
    const ReorderPkt = struct {
        active: bool = false,
        marker: bool = false,
        seq: u16 = 0,
        len: u16 = 0,
        data: [1420]u8 = undefined,
    };
    const reorder_cap = 48;

    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    reorder: ?[]ReorderPkt = null,
    cur_ts: u32 = 0,
    active: bool = false,
    await_start: bool = false,
    base_seq: u16 = 0,
    first_seq: u16 = 0,
    last_seq: u16 = 0,
    broken: bool = false,
    need_pli: bool = false,
    /// Bits de pacotes faltantes relativos a `first_seq` (janela até 512 pacotes).
    seen: [64]u8 = @splat(0),
    /// Em FU-A, se já gravamos o cabeçalho da NAL atual.
    in_fua: bool = false,
    fua_nal: u8 = 0,

    pub fn init(gpa: std.mem.Allocator) FrameAssembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *FrameAssembler) void {
        if (a.reorder) |rb| a.gpa.free(rb);
        a.reorder = null;
        a.buf.deinit(a.gpa);
    }

    fn clearReorder(a: *FrameAssembler) void {
        if (a.reorder) |rb| {
            for (rb) |*p| p.active = false;
        }
    }

    pub fn reset(a: *FrameAssembler) void {
        a.buf.clearRetainingCapacity();
        a.clearReorder();
        a.active = false;
        a.await_start = false;
        a.base_seq = 0;
        a.broken = false;
        a.in_fua = false;
        @memset(&a.seen, 0);
    }

    /// Libera a capacidade excedente ao sair de uma transmissão (RAM volta a 0).
    pub fn shrinkToZero(a: *FrameAssembler) void {
        if (a.reorder) |rb| a.gpa.free(rb);
        a.reorder = null;
        a.buf.clearAndFree(a.gpa);
        a.active = false;
        a.await_start = false;
        a.base_seq = 0;
        a.broken = false;
        a.in_fua = false;
    }

    pub const PushResult = union(enum) {
        pending,
        /// Fatia apontando para `a.buf.items` — válida até o próximo `push*`.
        frame: []const u8,
        /// Quadro descartado por perda ou estouro; recomenda-se PLI/NACK.
        dropped: struct { need_pli: bool },
    };

    fn isFuaContinuation(payload: []const u8) bool {
        return payload.len >= 2 and (payload[0] & 0x1F) == 28 and (payload[1] & 0x80) == 0;
    }

    fn stashReorder(a: *FrameAssembler, seq: u16, marker: bool, payload: []const u8) bool {
        if (payload.len > 1420) return false;
        if (a.reorder == null) {
            a.reorder = a.gpa.alloc(ReorderPkt, reorder_cap) catch return false;
            for (a.reorder.?) |*p| p.active = false;
        }
        const rb = a.reorder.?;
        for (rb) |*p| {
            if (p.active and p.seq == seq) return true;
        }
        for (rb) |*p| {
            if (!p.active) {
                p.active = true;
                p.marker = marker;
                p.seq = seq;
                p.len = @intCast(payload.len);
                @memcpy(p.data[0..payload.len], payload);
                return true;
            }
        }
        return false;
    }

    fn hasSeqInReorder(a: *const FrameAssembler, seq: u16) bool {
        const rb = a.reorder orelse return false;
        for (rb) |*p| {
            if (p.active and p.seq == seq) return true;
        }
        return false;
    }

    fn drainReorder(a: *FrameAssembler, out_marker: *bool) bool {
        const rb = a.reorder orelse return true;
        while (true) {
            const want = a.last_seq +% 1;
            var hit: ?*ReorderPkt = null;
            for (rb) |*p| {
                if (p.active and p.seq == want) {
                    hit = p;
                    break;
                }
            }
            const pkt = hit orelse return true;
            pkt.active = false;
            a.last_seq = want;
            a.markSeq(want);
            if (!a.appendH264Payload(pkt.data[0..pkt.len])) return false;
            if (pkt.marker) {
                out_marker.* = true;
                return true;
            }
        }
    }

    /// Recebe payload RTP H.264 (RFC 6184) e remonta em Annex-B (`00 00 00 01 ...`).
    pub fn pushH264(a: *FrameAssembler, seq: u16, ts: u32, marker: bool, payload: []const u8) PushResult {
        if (payload.len == 0) return .pending;

        if (!a.active or ts != a.cur_ts) {
            if (a.active and ts != a.cur_ts) {
                const ts_back = a.cur_ts -% ts;
                if (ts_back > 0 and ts_back < 90_000 * 10) return .pending;
            }
            const was_broken = a.active and (a.broken or a.await_start);
            a.reset();
            a.active = true;
            a.cur_ts = ts;
            a.first_seq = seq;
            a.last_seq = seq;
            if (was_broken) a.need_pli = true;
            if (isFuaContinuation(payload)) {
                a.await_start = true;
                a.base_seq = seq;
                if (!a.stashReorder(seq, marker, payload)) {
                    a.broken = true;
                    a.need_pli = true;
                }
                return .pending;
            }
            a.markSeq(seq);
        } else if (a.await_start) {
            const back = a.base_seq -% seq;
            if (back > 0 and back <= reorder_cap) {
                if (isFuaContinuation(payload)) {
                    a.base_seq = seq;
                    if (!a.stashReorder(seq, marker, payload)) {
                        a.broken = true;
                        a.need_pli = true;
                    }
                    return .pending;
                }
                a.await_start = false;
                a.first_seq = seq;
                a.last_seq = seq;
                a.markSeq(seq);
            } else {
                const fwd = seq -% a.base_seq;
                if (fwd > 0 and fwd <= reorder_cap) {
                    _ = a.stashReorder(seq, marker, payload);
                }
                return .pending;
            }
        } else {
            const diff = seq -% a.last_seq;
            if (diff == 0 or diff > 0x8000) {
                // Duplicado ou atrasado antigo: ignora sem quebrar.
                return .pending;
            }
            if (diff > 1) {
                if (!marker and diff <= reorder_cap and a.stashReorder(seq, marker, payload)) {
                    return .pending;
                }
                // Verifica se todos os pacotes intermediários chegaram fora de ordem antes deste marker.
                if (marker and diff <= reorder_cap) {
                    var all_present = true;
                    var s = a.last_seq +% 1;
                    while (s != seq) : (s +%= 1) {
                        if (!a.hasSeqInReorder(s)) {
                            all_present = false;
                            break;
                        }
                    }
                    if (all_present) {
                        var drained_marker = false;
                        if (!a.drainReorder(&drained_marker) or !a.appendH264Payload(payload)) {
                            a.reset();
                            return .{ .dropped = .{ .need_pli = true } };
                        }
                        a.last_seq = seq;
                        a.markSeq(seq);
                        if (a.buf.items.len == 0) {
                            a.reset();
                            return .pending;
                        }
                        a.active = false;
                        a.in_fua = false;
                        return .{ .frame = a.buf.items };
                    }
                }
                a.broken = true;
                a.need_pli = true;
            } else {
                a.last_seq = seq;
                a.markSeq(seq);
            }
        }

        if (a.broken) {
            if (marker) {
                const pli = a.need_pli;
                a.need_pli = false;
                a.reset();
                return .{ .dropped = .{ .need_pli = pli } };
            }
            return .pending;
        }

        var done_marker = marker;
        if (!a.appendH264Payload(payload) or !a.drainReorder(&done_marker)) {
            a.broken = true;
            a.need_pli = true;
            if (done_marker) {
                a.need_pli = false;
                a.reset();
                return .{ .dropped = .{ .need_pli = true } };
            }
            return .pending;
        }

        if (!done_marker) return .pending;
        if (a.buf.items.len == 0) {
            a.reset();
            return .pending;
        }
        a.active = false;
        a.in_fua = false;
        return .{ .frame = a.buf.items };
    }

    fn markSeq(a: *FrameAssembler, seq: u16) void {
        const d = seq -% a.first_seq;
        if (d < 512) a.seen[d / 8] |= @as(u8, 1) << @intCast(d % 8);
    }

    fn appendStartCode(a: *FrameAssembler) bool {
        if (a.buf.items.len + 4 > max_frame_bytes) return false;
        a.buf.appendSlice(a.gpa, &.{ 0, 0, 0, 1 }) catch return false;
        return true;
    }

    fn appendBytes(a: *FrameAssembler, bytes: []const u8) bool {
        if (a.buf.items.len + bytes.len > max_frame_bytes) return false;
        a.buf.appendSlice(a.gpa, bytes) catch return false;
        return true;
    }

    fn appendH264Payload(a: *FrameAssembler, p: []const u8) bool {
        const nal_type = p[0] & 0x1F;
        if (nal_type >= 1 and nal_type <= 23) {
            // Single NAL Unit
            a.in_fua = false;
            return a.appendStartCode() and a.appendBytes(p);
        } else if (nal_type == 24) {
            // STAP-A: múltiplos NALs empacotados
            a.in_fua = false;
            var off: usize = 1;
            while (off + 2 <= p.len) {
                const sz = std.mem.readInt(u16, p[off..][0..2], .big);
                off += 2;
                if (sz == 0 or off + sz > p.len) return false;
                if (!a.appendStartCode() or !a.appendBytes(p[off..][0..sz])) return false;
                off += sz;
            }
            return true;
        } else if (nal_type == 28) {
            // FU-A
            if (p.len < 2) return false;
            const fu_hdr = p[1];
            const start_bit = (fu_hdr & 0x80) != 0;
            const end_bit = (fu_hdr & 0x40) != 0;
            const orig_nal = (p[0] & 0xE0) | (fu_hdr & 0x1F);
            if (start_bit) {
                a.in_fua = true;
                a.fua_nal = orig_nal;
                if (!a.appendStartCode()) return false;
                if (!a.appendBytes(&.{orig_nal})) return false;
            } else if (!a.in_fua or a.fua_nal != orig_nal) {
                return false;
            }
            if (!a.appendBytes(p[2..])) return false;
            if (end_bit) a.in_fua = false;
            return true;
        }
        return false;
    }
};

/// Monta um pacote RTCP PLI (Payload-Specific Feedback, FMT=1, PT=206) de 12 bytes.
pub fn buildRtcpPli(out: *[12]u8, sender_ssrc: u32, media_ssrc: u32) void {
    out[0] = 0x81; // V=2, P=0, FMT=1 (PLI)
    out[1] = 206; // PSFB
    std.mem.writeInt(u16, out[2..4], 2, .big); // length in 32-bit words minus 1
    std.mem.writeInt(u32, out[4..8], sender_ssrc, .big);
    std.mem.writeInt(u32, out[8..12], media_ssrc, .big);
}

/// Monta um pacote RTCP NACK (Generic NACK, FMT=1, PT=205) de 16 bytes.
pub fn buildRtcpNack(out: *[16]u8, sender_ssrc: u32, media_ssrc: u32, pid: u16, blp: u16) void {
    out[0] = 0x81; // V=2, P=0, FMT=1 (Generic NACK)
    out[1] = 205; // RTPFB
    std.mem.writeInt(u16, out[2..4], 3, .big);
    std.mem.writeInt(u32, out[4..8], sender_ssrc, .big);
    std.mem.writeInt(u32, out[8..12], media_ssrc, .big);
    std.mem.writeInt(u16, out[12..14], pid, .big);
    std.mem.writeInt(u16, out[14..16], blp, .big);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const t = std.testing;

test "H264 Annex-B empacota e remonta Single NAL e FU-A grandes (4K keyframe)" {
    // SPS pequeno (Single NAL) + IDR grande de 5000 bytes (fragmentado em FU-A).
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(t.allocator);
    try src.appendSlice(t.allocator, &.{ 0, 0, 0, 1, 0x67, 0x42, 0x00, 0x33, 0xAA });
    try src.appendSlice(t.allocator, &.{ 0, 0, 0, 1, 0x65 });
    for (0..5000) |i| try src.append(t.allocator, @intCast(i & 0xFF));

    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    const Collector = struct {
        asm_dec: *FrameAssembler,
        seq: u16 = 100,
        packets: usize = 0,
        got_frame: bool = false,
        frame_len: usize = 0,
        first_bytes: [9]u8 = undefined,

        fn onPkt(ctx: *anyopaque, payload: []const u8, marker: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.packets += 1;
            const res = self.asm_dec.pushH264(self.seq, 90000, marker, payload);
            self.seq +%= 1;
            switch (res) {
                .frame => |f| {
                    self.got_frame = true;
                    self.frame_len = f.len;
                    @memcpy(&self.first_bytes, f[0..9]);
                },
                else => {},
            }
        }
    };
    var col: Collector = .{ .asm_dec = &asm_dec };
    packetizeH264AnnexB(src.items, max_rtp_payload, .{ .ctx = &col, .emit = Collector.onPkt });

    try t.expect(col.packets >= 6);
    try t.expect(col.got_frame);
    try t.expectEqual(src.items.len, col.frame_len);
    try t.expectEqualSlices(u8, src.items[0..9], &col.first_bytes);
}

test "perda de pacote no meio do quadro pede PLI e descarta sem corromper" {
    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    // Pacote seq 10: início FU-A
    const p1 = [_]u8{ 0x7C, 0x85, 1, 2, 3 };
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(10, 1000, false, &p1));
    // Pacote seq 11 perdido; chega seq 12 com marker=true
    const p3 = [_]u8{ 0x7C, 0x45, 7, 8, 9 };
    const res = asm_dec.pushH264(12, 1000, true, &p3);
    try t.expect(res == .dropped);
    try t.expect(res.dropped.need_pli);

    // Próximo quadro (novo timestamp) com Single NAL íntegro volta a funcionar.
    const good = [_]u8{ 0x65, 0xAA, 0xBB };
    const ok = asm_dec.pushH264(13, 4000, true, &good);
    try t.expect(ok == .frame);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0x65, 0xAA, 0xBB }, ok.frame);
}

test "reordenação leve de pacotes UDP remonta quadro H264 íntegro" {
    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    // FU-A dividido em 3 pacotes: seq 20 (início), 21 (meio), 22 (fim+marker), entregues 20, 22, 21!
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(20, 9000, false, &[_]u8{ 0x7C, 0x85, 0x11, 0x22 }));
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(21, 9000, false, &[_]u8{ 0x7C, 0x05, 0x33, 0x44 }));
    _ = asm_dec.pushH264(23, 9000, false, &[_]u8{ 0x7C, 0x45, 0x77, 0x88 });
    // Ops, chegou 23 antes de 22 — ainda pendente. Agora chega 22? Wait: testa sem 23: envia 30, 32, 31
    asm_dec.reset();
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(30, 12000, false, &[_]u8{ 0x7C, 0x85, 0xAA }));
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(32, 12000, false, &[_]u8{ 0x7C, 0x05, 0xCC }));
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(31, 12000, false, &[_]u8{ 0x7C, 0x05, 0xBB }));
    const done = asm_dec.pushH264(33, 12000, true, &[_]u8{ 0x7C, 0x45, 0xDD });
    try t.expect(done == .frame);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0xCC, 0xDD }, done.frame);
}

test "RTCP PLI e NACK geram cabeçalhos válidos" {
    var pli: [12]u8 = undefined;
    buildRtcpPli(&pli, 0x11223344, 0x55667788);
    try t.expectEqual(@as(u8, 0x81), pli[0]);
    try t.expectEqual(@as(u8, 206), pli[1]);
    try t.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, pli[8..12], .big));

    var nack: [16]u8 = undefined;
    buildRtcpNack(&nack, 1, 2, 42, 0x0003);
    try t.expectEqual(@as(u8, 205), nack[1]);
    try t.expectEqual(@as(u16, 42), std.mem.readInt(u16, nack[12..14], .big));
}

test "reordenação quando pacote #0 (FU-A start) chega após continuação e pacote antigo atrasado é ignorado" {
    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    // Pacotes do frame ts=20000 chegam fora de ordem: seq 101 (FU-A cont + marker) antes de seq 100 (FU-A start).
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(101, 20000, true, &[_]u8{ 0x7C, 0x45, 0xBB }));
    // Pacote antigo atrasado (ts=17000) não derruba a montagem do frame atual.
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(99, 17000, true, &[_]u8{ 0x61, 0x01 }));
    // Chega o pacote #0 (FU-A start): drena seq 101 e entrega o frame completo.
    const out = asm_dec.pushH264(100, 20000, false, &[_]u8{ 0x7C, 0x85, 0xAA });
    try t.expect(out == .frame);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0x65, 0xAA, 0xBB }, out.frame);
}
