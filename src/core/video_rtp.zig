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
const video_cfg = @import("video_cfg.zig");

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
    /// Verdadeiro se um quadro anterior incompleto foi substituído antes do marker.
    abandoned: bool = false,
    /// Em codecs baseados em cabeçalho por quadro (VP8/VP9/AV1), indica flag de keyframe do cabeçalho RTP.
    frame_key_hint: bool = false,
    /// Bits de pacotes faltantes relativos a `first_seq` (janela até 512 pacotes).
    seen: [64]u8 = @splat(0),
    /// Em FU-A, se já gravamos o cabeçalho da NAL atual.
    in_fua: bool = false,
    fua_nal: u8 = 0,
    /// Em AV1 RTP, estado de OBU fragmentado entre pacotes (`Y=1` -> `Z=1`).
    av1_in_obu: bool = false,
    av1_obu: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) FrameAssembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *FrameAssembler) void {
        if (a.reorder) |rb| a.gpa.free(rb);
        a.reorder = null;
        a.av1_obu.deinit(a.gpa);
        a.buf.deinit(a.gpa);
    }

    fn clearReorder(a: *FrameAssembler) void {
        if (a.reorder) |rb| {
            for (rb) |*p| p.active = false;
        }
    }

    pub fn reset(a: *FrameAssembler) void {
        a.buf.clearRetainingCapacity();
        a.av1_obu.clearRetainingCapacity();
        a.clearReorder();
        a.active = false;
        a.await_start = false;
        a.base_seq = 0;
        a.broken = false;
        a.in_fua = false;
        a.av1_in_obu = false;
        a.frame_key_hint = false;
        @memset(&a.seen, 0);
    }

    /// Libera a capacidade excedente ao sair de uma transmissão (RAM volta a 0).
    pub fn shrinkToZero(a: *FrameAssembler) void {
        if (a.reorder) |rb| a.gpa.free(rb);
        a.reorder = null;
        a.av1_obu.clearAndFree(a.gpa);
        a.buf.clearAndFree(a.gpa);
        a.active = false;
        a.await_start = false;
        a.base_seq = 0;
        a.broken = false;
        a.in_fua = false;
        a.av1_in_obu = false;
        a.abandoned = false;
        a.frame_key_hint = false;
    }

    pub fn takeAbandoned(a: *FrameAssembler) bool {
        const had = a.abandoned;
        a.abandoned = false;
        return had;
    }

    pub const PushResult = union(enum) {
        pending,
        /// Fatia apontando para `a.buf.items` — válida até o próximo `push*`.
        frame: []const u8,
        /// Quadro descartado por perda ou estouro; recomenda-se PLI/NACK.
        dropped: struct { need_pli: bool },
    };

    fn isContinuationPacket(codec: video_cfg.Codec, payload: []const u8) bool {
        if (payload.len == 0) return false;
        return switch (codec) {
            .auto, .h264 => payload.len >= 2 and (payload[0] & 0x1F) == 28 and (payload[1] & 0x80) == 0,
            .vp8 => (payload[0] & 0x10) == 0, // S=0 (não é início de partição)
            .vp9 => (payload[0] & 0x08) == 0, // B=0 (não é início de quadro)
            .av1 => (payload[0] & 0x80) != 0, // Z=1 (continuação de OBU anterior)
            .hevc => false,
        };
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

    fn drainReorder(a: *FrameAssembler, codec: video_cfg.Codec, out_marker: *bool) bool {
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
            if (!a.appendCodecPayload(codec, pkt.data[0..pkt.len], pkt.marker)) return false;
            if (pkt.marker) {
                out_marker.* = true;
                return true;
            }
        }
    }

    /// Recebe payload RTP H.264 (RFC 6184) e remonta em Annex-B (`00 00 00 01 ...`).
    pub fn pushH264(a: *FrameAssembler, seq: u16, ts: u32, marker: bool, payload: []const u8) PushResult {
        return a.pushPacket(.h264, seq, ts, marker, payload);
    }

    /// Recebe payload RTP de H.264 / VP8 / VP9 / AV1 / HEVC com reordenação e detecção de perdas.
    pub fn pushPacket(a: *FrameAssembler, codec: video_cfg.Codec, seq: u16, ts: u32, marker: bool, payload: []const u8) PushResult {
        if (payload.len == 0) return .pending;

        if (!a.active or ts != a.cur_ts) {
            if (a.active and ts != a.cur_ts) {
                const ts_back = a.cur_ts -% ts;
                if (ts_back > 0 and ts_back < 90_000 * 10) return .pending;
            }
            // Qualquer quadro anterior ainda ativo que não recebeu `marker` foi truncado por perda!
            const was_incomplete = a.active;
            a.reset();
            a.active = true;
            a.cur_ts = ts;
            a.first_seq = seq;
            a.last_seq = seq;
            if (was_incomplete) {
                a.need_pli = true;
                a.abandoned = true;
            }
            if (isContinuationPacket(codec, payload)) {
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
                if (isContinuationPacket(codec, payload)) {
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
                        if (!a.drainReorder(codec, &drained_marker) or !a.appendCodecPayload(codec, payload, marker)) {
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
                        a.av1_in_obu = false;
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
        if (!a.appendCodecPayload(codec, payload, marker) or !a.drainReorder(codec, &done_marker)) {
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
        a.av1_in_obu = false;
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

    fn appendCodecPayload(a: *FrameAssembler, codec: video_cfg.Codec, p: []const u8, marker: bool) bool {
        return switch (codec) {
            .auto, .h264 => a.appendH264Payload(p),
            .vp8 => a.appendVp8Payload(p),
            .vp9 => a.appendVp9Payload(p),
            .av1 => a.appendAv1Payload(p, marker),
            .hevc => a.appendStartCode() and a.appendBytes(p),
        };
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

    /// RFC 7741 VP8 RTP payload descriptor stripping.
    fn appendVp8Payload(a: *FrameAssembler, p: []const u8) bool {
        if (p.len < 1) return false;
        const b0 = p[0];
        var off: usize = 1;
        if ((b0 & 0x80) != 0) { // X
            if (off >= p.len) return false;
            const x = p[off];
            off += 1;
            if ((x & 0x80) != 0) { // I (PictureID)
                if (off >= p.len) return false;
                const m = (p[off] & 0x80) != 0;
                off += if (m) @as(usize, 2) else 1;
            }
            if ((x & 0x40) != 0) off += 1; // L (TL0PICIDX)
            if ((x & 0x30) != 0) off += 1; // T or K (TID/KEYIDX)
        }
        if (off > p.len) return false;
        const pay = p[off..];
        if (pay.len == 0) return true;
        if ((b0 & 0x10) != 0 and (b0 & 0x07) == 0 and a.buf.items.len == 0 and (pay[0] & 0x01) == 0) {
            a.frame_key_hint = true;
        }
        return a.appendBytes(pay);
    }

    /// RFC 9628 VP9 RTP payload descriptor stripping.
    fn appendVp9Payload(a: *FrameAssembler, p: []const u8) bool {
        if (p.len < 1) return false;
        const b0 = p[0];
        const i_bit = (b0 & 0x80) != 0;
        const p_bit = (b0 & 0x40) != 0;
        const l_bit = (b0 & 0x20) != 0;
        const f_bit = (b0 & 0x10) != 0;
        const b_bit = (b0 & 0x08) != 0;
        const v_bit = (b0 & 0x02) != 0;
        var off: usize = 1;
        if (i_bit) {
            if (off >= p.len) return false;
            const m = (p[off] & 0x80) != 0;
            off += if (m) @as(usize, 2) else 1;
        }
        if (l_bit) {
            off += 1; // Layer indices
            if (!f_bit) off += 1; // Non-flexible mode has TL0PICIDX
        }
        if (f_bit and p_bit) {
            // Flexible mode reference indices (N bit is LSB)
            var guard: u8 = 0;
            while (off < p.len and guard < 8) : (guard += 1) {
                const more = (p[off] & 0x01) != 0;
                off += 1;
                if (!more) break;
            }
        }
        if (v_bit) {
            if (off >= p.len) return false;
            const ss = p[off];
            off += 1;
            const n_s: usize = ((ss >> 5) & 7) + 1;
            const y_bit = (ss & 0x10) != 0;
            const g_bit = (ss & 0x08) != 0;
            if (y_bit) off += 4 * n_s;
            if (g_bit) {
                if (off >= p.len) return false;
                const n_g: usize = p[off];
                off += 1;
                for (0..n_g) |_| {
                    if (off >= p.len) return false;
                    const r: usize = (p[off] >> 2) & 3;
                    off += 1 + r;
                }
            }
        }
        if (off > p.len) return false;
        if (b_bit and !p_bit) a.frame_key_hint = true;
        return a.appendBytes(p[off..]);
    }

    fn appendAv1Payload(a: *FrameAssembler, p: []const u8, marker: bool) bool {
        if (p.len < 1) return false;
        const b0 = p[0];
        const z_bit = (b0 & 0x80) != 0;
        const y_bit = (b0 & 0x40) != 0;
        const w_cnt: u8 = (b0 >> 4) & 3;
        if ((b0 & 0x08) != 0) a.frame_key_hint = true;
        var off: usize = 1;
        var elem_idx: u8 = 0;
        while (off < p.len) {
            const has_len = (w_cnt == 0) or (elem_idx + 1 < w_cnt);
            var elem_len: usize = 0;
            if (has_len) {
                var shift: u6 = 0;
                while (off < p.len and shift < 28) {
                    const byte = p[off];
                    off += 1;
                    elem_len |= @as(usize, byte & 0x7F) << shift;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                } else return false;
            } else {
                elem_len = p.len - off;
            }
            if (off + elem_len > p.len) return false;
            const frag = p[off .. off + elem_len];
            off += elem_len;

            const is_last_in_pkt = if (w_cnt == 0) (off >= p.len) else (elem_idx + 1 >= w_cnt);
            const continues_next = is_last_in_pkt and y_bit;
            const is_cont_prev = (elem_idx == 0) and z_bit;

            if (!is_cont_prev) {
                if (a.av1_in_obu and a.av1_obu.items.len > 0) {
                    if (!a.flushAv1Obu(false)) return false;
                }
                a.av1_obu.clearRetainingCapacity();
                a.av1_in_obu = false;
            }
            if (a.buf.items.len + a.av1_obu.items.len + frag.len > max_frame_bytes) return false;
            a.av1_obu.appendSlice(a.gpa, frag) catch return false;

            if (continues_next) {
                a.av1_in_obu = true;
            } else {
                a.av1_in_obu = false;
                const final_obu_of_frame = is_last_in_pkt and marker;
                if (!a.flushAv1Obu(final_obu_of_frame)) return false;
                a.av1_obu.clearRetainingCapacity();
            }
            elem_idx +|= 1;
            if (w_cnt != 0 and elem_idx >= w_cnt) break;
        }
        return true;
    }

    fn flushAv1Obu(a: *FrameAssembler, is_frame_end: bool) bool {
        const obu = a.av1_obu.items;
        if (obu.len == 0) return true;
        const hdr = obu[0];
        const has_ext = (hdr & 0x04) != 0;
        const has_size = (hdr & 0x02) != 0;
        const hdr_len: usize = if (has_ext) 2 else 1;
        if (obu.len < hdr_len) return false;
        const obu_type = (hdr >> 3) & 0x0F;
        if (obu_type == 1) a.frame_key_hint = true; // OBU_SEQUENCE_HEADER

        // DAVE remove obu_size apenas no último OBU para anexar 0xFA 0xFA; OBUs intermediários precisam do tamanho.
        if (has_size or is_frame_end) {
            return a.appendBytes(obu);
        }
        const payload = obu[hdr_len..];
        var prefix: [10]u8 = undefined;
        prefix[0] = hdr | 0x02;
        if (has_ext) prefix[1] = obu[1];
        var p_len = hdr_len;
        var v = payload.len;
        while (true) {
            var b: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v != 0) b |= 0x80;
            prefix[p_len] = b;
            p_len += 1;
            if (v == 0) break;
        }
        return a.appendBytes(prefix[0..p_len]) and a.appendBytes(payload);
    }
};

/// Desencapsula pacote RTX (RFC 4588): 2 bytes de sequence number original + payload real.
pub fn unwrapRtx(pkt_payload: []const u8) ?struct { orig_seq: u16, orig_payload: []const u8 } {
    if (pkt_payload.len <= 2) return null;
    return .{
        .orig_seq = std.mem.readInt(u16, pkt_payload[0..2], .big),
        .orig_payload = pkt_payload[2..],
    };
}

/// Detecta se o Access Unit decodificado/desencriptado inicia um keyframe válido do codec.
pub fn isKeyframe(codec: video_cfg.Codec, au: []const u8, frame_key_hint: bool) bool {
    if (au.len == 0) return false;
    switch (codec) {
        .auto, .h264 => {
            var nals: [32][]const u8 = undefined;
            const count = splitAnnexBNals(au, &nals);
            for (nals[0..count]) |nal| {
                if (nal.len == 0) continue;
                const nt = nal[0] & 0x1F;
                if (nt == 5 or nt == 7) return true;
            }
            return false;
        },
        .hevc => {
            var nals: [32][]const u8 = undefined;
            const count = splitAnnexBNals(au, &nals);
            for (nals[0..count]) |nal| {
                if (nal.len == 0) continue;
                const nt = (nal[0] >> 1) & 0x3F;
                if (nt >= 16 and nt <= 21) return true;
                if (nt == 32 or nt == 33) return true;
            }
            return false;
        },
        .vp8 => return (au[0] & 0x01) == 0,
        .vp9 => {
            if (frame_key_hint) return true;
            if ((au[0] >> 6) == 2) {
                const prof = ((au[0] >> 4) & 1) | ((au[0] >> 5) & 2);
                if (prof == 3) {
                    const show_ex = (au[0] & 0x04) != 0;
                    return !show_ex and (au[0] & 0x02) == 0;
                }
                const show_ex = (au[0] & 0x08) != 0;
                return !show_ex and (au[0] & 0x04) == 0;
            }
            return false;
        },
        .av1 => {
            if (frame_key_hint) return true;
            var off: usize = 0;
            var checked: usize = 0;
            while (off < au.len and checked < 8) : (checked += 1) {
                const hdr = au[off];
                const obu_type = (hdr >> 3) & 0x0F;
                if (obu_type == 1) return true; // SEQUENCE_HEADER
                const has_ext = (hdr & 0x04) != 0;
                const has_size = (hdr & 0x02) != 0;
                off += if (has_ext) @as(usize, 2) else 1;
                if (!has_size or off >= au.len) break;
                var sz: usize = 0;
                var sh: u6 = 0;
                while (off < au.len and sh < 28) {
                    const b = au[off];
                    off += 1;
                    sz |= @as(usize, b & 0x7F) << sh;
                    if ((b & 0x80) == 0) break;
                    sh += 7;
                }
                off += sz;
            }
            return false;
        },
    }
}

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

/// Calcula timestamp abs-send-time de 24 bits (formato 6.18 em segundos, WebRTC RFC/draft).
pub fn absSendTime24(mono_us: u64) u24 {
    const ticks: u64 = (mono_us << 18) / 1_000_000;
    return @truncate(ticks);
}

/// Monta corpo da extensão RTP one-byte (`0xBEDE`, 4 palavras = 16 bytes) para vídeo do Discord:
///   - ID 3:  abs-send-time (3 bytes)
///   - ID 6:  playout-delay min=0 max=100ms (3 bytes)
///   - ID 7:  video-content-type (1 byte: 0 câmera, 1 tela)
///   - ID 11/12: rid / repaired-rid "100" (3 bytes)
pub fn buildVideoExt(out: *[16]u8, abs_send_time_24: u24, is_screen: bool, is_rtx: bool) void {
    out[0] = 0x32; // ID=3, L=2 (3 bytes)
    out[1] = @intCast((abs_send_time_24 >> 16) & 0xFF);
    out[2] = @intCast((abs_send_time_24 >> 8) & 0xFF);
    out[3] = @intCast(abs_send_time_24 & 0xFF);

    out[4] = 0x62; // ID=6, L=2 (3 bytes: 12b min=0, 12b max=10 => 0..100ms)
    out[5] = 0x00;
    out[6] = 0x00;
    out[7] = 0x0A;

    out[8] = 0x70; // ID=7, L=0 (1 byte)
    out[9] = if (is_screen) 1 else 0;

    out[10] = if (is_rtx) 0xC2 else 0xB2; // ID=11 (rid) / ID=12 (repaired-rid), L=2 (3 bytes)
    out[11] = '1';
    out[12] = '0';
    out[13] = '0';

    out[14] = 0x00;
    out[15] = 0x00;
}

/// Monta um pacote RTCP Sender Report (PT=200) de 28 bytes (RFC 3550).
pub fn buildRtcpSr(out: *[28]u8, sender_ssrc: u32, unix_ms: u64, rtp_ts: u32, pkt_count: u32, octet_count: u32) void {
    const ntp_epoch_offset: u64 = 2_208_988_800; // 1900 -> 1970 em segundos
    const ntp_sec: u32 = @truncate((unix_ms / 1000) +% ntp_epoch_offset);
    const rem_ms: u64 = unix_ms % 1000;
    const ntp_frac: u32 = @truncate((rem_ms << 32) / 1000);
    out[0] = 0x80; // V=2, P=0, RC=0
    out[1] = 200; // SR
    std.mem.writeInt(u16, out[2..4], 6, .big); // length in 32-bit words - 1
    std.mem.writeInt(u32, out[4..8], sender_ssrc, .big);
    std.mem.writeInt(u32, out[8..12], ntp_sec, .big);
    std.mem.writeInt(u32, out[12..16], ntp_frac, .big);
    std.mem.writeInt(u32, out[16..20], rtp_ts, .big);
    std.mem.writeInt(u32, out[20..24], pkt_count, .big);
    std.mem.writeInt(u32, out[24..28], octet_count, .big);
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

test "extensões RTP Discord 0xBEDE e RTCP SR" {
    var ext: [16]u8 = undefined;
    buildVideoExt(&ext, 0x123456, true, false);
    try t.expectEqual(@as(u8, 0x32), ext[0]);
    try t.expectEqual(@as(u8, 0x62), ext[4]);
    try t.expectEqual(@as(u8, 0x70), ext[8]);
    try t.expectEqual(@as(u8, 1), ext[9]);
    try t.expectEqualSlices(u8, &[_]u8{ 0xB2, '1', '0', '0' }, ext[10..14]);

    var pkt: [16 + 16 + 4]u8 = undefined;
    (RtpHeader{ .marker = true, .payload_type = 101, .seq = 7, .timestamp = 9000, .ssrc = 1234 }).write(pkt[0..12]);
    pkt[0] |= 0x10;
    @memcpy(pkt[12..16], &[_]u8{ 0xBE, 0xDE, 0x00, 0x04 });
    @memcpy(pkt[16..32], &ext);
    @memcpy(pkt[32..36], &[_]u8{ 0x65, 0xAA, 0xBB, 0xCC });
    const parsed = RtpHeader.parse(&pkt).?;
    try t.expectEqual(@as(usize, 32), parsed.payload_off);
    try t.expectEqual(@as(u7, 101), parsed.hdr.payload_type);
    try t.expect(parsed.hdr.marker);

    var sr: [28]u8 = undefined;
    buildRtcpSr(&sr, 0xAABBCCDD, 1_700_000_000_500, 90000, 10, 12000);
    try t.expectEqual(@as(u8, 200), sr[1]);
    try t.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, sr[4..8], .big));
    try t.expectEqual(@as(u32, 10), std.mem.readInt(u32, sr[20..24], .big));
}

test "quadro truncado sem marker sinaliza takeAbandoned para reset de keyframe" {
    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    // Quadro ts=1000 inicia FU-A sem marker (marker foi perdido pela rede).
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushH264(1, 1000, false, &[_]u8{ 0x7C, 0x81, 0xAA }));
    try t.expect(!asm_dec.takeAbandoned());

    // Quadro seguinte ts=4000 chega completo: caller precisa saber que ts=1000 caiu!
    const f2 = asm_dec.pushH264(2, 4000, true, &[_]u8{ 0x41, 0xBB });
    try t.expect(f2 == .frame);
    try t.expect(asm_dec.takeAbandoned());
    try t.expect(!asm_dec.takeAbandoned());
}

test "VP8, VP9 e AV1 RTP depacketization, keyframe e unwrapRtx" {
    var asm_dec = FrameAssembler.init(t.allocator);
    defer asm_dec.deinit();

    // VP8 keyframe fragmentado (X=1, I=1(2B), S=1 PID=0 -> keyframe byte0 & 1 == 0)
    const vp8_p1 = [_]u8{ 0x90, 0x80, 0x80, 0x01, 0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A };
    const vp8_p2 = [_]u8{ 0x80, 0x80, 0x80, 0x02, 0xAA, 0xBB };
    try t.expectEqual(FrameAssembler.PushResult.pending, asm_dec.pushPacket(.vp8, 10, 1000, false, &vp8_p1));
    const vp8_res = asm_dec.pushPacket(.vp8, 11, 1000, true, &vp8_p2);
    try t.expect(vp8_res == .frame);
    try t.expect(isKeyframe(.vp8, vp8_res.frame, asm_dec.frame_key_hint));
    try t.expectEqualSlices(u8, &[_]u8{ 0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0xAA, 0xBB }, vp8_res.frame);

    // VP9 delta (I=1(1B), P=1, B=1, E=1) vs keyframe (P=0, B=1)
    const vp9_k = [_]u8{ 0x8C, 0x05, 0x82, 0x49, 0x83, 0x42 };
    const vp9_res = asm_dec.pushPacket(.vp9, 12, 2000, true, &vp9_k);
    try t.expect(vp9_res == .frame);
    try t.expect(isKeyframe(.vp9, vp9_res.frame, asm_dec.frame_key_hint));
    try t.expectEqualSlices(u8, &[_]u8{ 0x82, 0x49, 0x83, 0x42 }, vp9_res.frame);

    // AV1 W=2 N=1 (Sequence Header OBU=1 + Frame OBU)
    const av1_pkt = [_]u8{
        0x28, // Z=0, Y=0, W=2, N=1
        0x03, // leb128 len = 3
        0x08, 0x00, 0x00, // OBU_SEQUENCE_HEADER (type=1 -> hdr=0x08) without size
        0x30, 0xAA, 0xBB, // OBU_FRAME
    };
    const av1_res = asm_dec.pushPacket(.av1, 13, 3000, true, &av1_pkt);
    try t.expect(av1_res == .frame);
    try t.expect(isKeyframe(.av1, av1_res.frame, asm_dec.frame_key_hint));
    // First OBU got has_size bit (0x0A) + leb128(2) inserted; final OBU kept cleanly.
    try t.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0x00, 0x00, 0x30, 0xAA, 0xBB }, av1_res.frame);

    // RFC 4588 RTX
    const rtx_raw = [_]u8{ 0x12, 0x34, 0x65, 0x88, 0x99 };
    const un = unwrapRtx(&rtx_raw).?;
    try t.expectEqual(@as(u16, 0x1234), un.orig_seq);
    try t.expectEqualSlices(u8, &[_]u8{ 0x65, 0x88, 0x99 }, un.orig_payload);
}
