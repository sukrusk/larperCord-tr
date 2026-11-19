//! Alocação NV12 mínima (page_allocator -> VirtualFree imediato no stop) e
//! gerador leve de quadro 4K NV12 para `--demo` sem alocar RGBA.
const std = @import("std");
const video_cfg = @import("video_cfg.zig");

pub const PlaneView = struct {
    buf: []u8,
    w: u16,
    h: u16,

    pub fn yPlane(v: PlaneView) []u8 {
        const y_len: usize = @as(usize, v.w) * v.h;
        return v.buf[0..y_len];
    }

    pub fn uvPlane(v: PlaneView) []u8 {
        const y_len: usize = @as(usize, v.w) * v.h;
        return v.buf[y_len..];
    }
};

pub fn allocNv12(w: u16, h: u16) ![]u8 {
    if (w < 2 or h < 2 or (w & 1) != 0 or (h & 1) != 0) return error.InvalidDims;
    const total = video_cfg.nv12ByteSize(w, h);
    // page_allocator devolve cada MiB ao SO imediatamente no free (zero retenção de arena).
    return try std.heap.page_allocator.alloc(u8, total);
}

pub fn freeNv12(buf: *[]u8) void {
    if (buf.len > 0) {
        std.heap.page_allocator.free(buf.*);
        buf.* = &.{};
    }
}

/// Desenha o fundo estático 4K (grade + barras de cor) apenas quando a resolução muda
/// ou no quadro 0.
pub fn initDemoBackground(buf: []u8, w: u16, h: u16) void {
    const y_len: usize = @as(usize, w) * h;
    if (buf.len < y_len + y_len / 2) return;
    const y_plane = buf[0..y_len];
    const uv_plane = buf[y_len..];
    const wu: usize = w;
    const hu: usize = h;

    // Fundo grafite escuro com grade fina e barra superior SMPTE suave.
    const bar_h = hu / 10;
    const bar_w = wu / 7;
    const smpte_y = [7]u8{ 210, 190, 160, 140, 110, 82, 52 };
    const smpte_u = [7]u8{ 128, 44, 156, 72, 184, 100, 212 };
    const smpte_v = [7]u8{ 128, 146, 44, 58, 200, 214, 118 };

    var row: usize = 0;
    while (row < hu) : (row += 1) {
        const r_ptr = y_plane[row * wu ..][0..wu];
        if (row < bar_h) {
            var b: usize = 0;
            while (b < 7) : (b += 1) {
                const x0 = b * bar_w;
                const x1 = if (b == 6) wu else (b + 1) * bar_w;
                @memset(r_ptr[x0..x1], smpte_y[b]);
            }
        } else {
            const on_hgrid = (row % 120) == 0;
            @memset(r_ptr, if (on_hgrid) 56 else 26);
            if (!on_hgrid) {
                var gx: usize = 120;
                while (gx < wu) : (gx += 120) r_ptr[gx] = 48;
            }
        }
    }

    // Plano UV (metade largura/altura).
    var crow: usize = 0;
    const chu = hu / 2;
    const cbar_h = bar_h / 2;
    const cwu = wu / 2;
    while (crow < chu) : (crow += 1) {
        const uv_row = uv_plane[crow * wu ..][0..wu];
        if (crow < cbar_h) {
            var cx: usize = 0;
            while (cx < cwu) : (cx += 1) {
                const bi = @min((cx * 2) / @max(bar_w, 1), 6);
                uv_row[cx * 2] = smpte_u[bi];
                uv_row[cx * 2 + 1] = smpte_v[bi];
            }
        } else {
            @memset(uv_row, 128);
        }
    }
}

/// Atualiza apenas uma faixa móvel 128x128 e uma linha de varredura para manter
/// 3840x2160@60fps abaixo de 0.1 ms/quadro no modo `--demo`.
pub fn stepDemoOverlay(buf: []u8, w: u16, h: u16, frame_idx: u64, camera_style: bool) void {
    const wu: usize = w;
    const hu: usize = h;
    const y_len = wu * hu;
    if (buf.len < y_len + y_len / 2) return;
    const y_plane = buf[0..y_len];
    const uv_plane = buf[y_len..];

    const box_s: usize = @min(wu / 12, @min(hu / 8, 160)) & ~@as(usize, 1);
    const area_y0 = (hu / 5) & ~@as(usize, 1);
    const travel_w = if (wu > box_s + 64) wu - box_s - 64 else 2;
    const step_px: usize = 16;

    // Apaga posição anterior do bloco móvel se houver.
    if (frame_idx > 0) {
        const prev_x = (32 + (((frame_idx - 1) * step_px) % travel_w)) & ~@as(usize, 1);
        var dy: usize = 0;
        while (dy < box_s) : (dy += 1) {
            const ry = area_y0 + dy;
            const bg: u8 = if ((ry % 120) == 0) 56 else 26;
            @memset(y_plane[ry * wu + prev_x ..][0..box_s], bg);
            if ((dy & 1) == 0) {
                @memset(uv_plane[(ry / 2) * wu + prev_x ..][0..box_s], 128);
            }
        }
    }

    // Desenha bloco atual vivo (magenta/ciano no Go Live ou âmbar/esmeralda na câmera demo).
    const cur_x = (32 + ((frame_idx * step_px) % travel_w)) & ~@as(usize, 1);
    const luma: u8 = if (camera_style) 196 else 212;
    const u_val: u8 = if (camera_style) 92 else 184;
    const v_val: u8 = if (camera_style) 172 else 74;

    var dy: usize = 0;
    while (dy < box_s) : (dy += 1) {
        const ry = area_y0 + dy;
        const border = dy < 4 or dy + 4 >= box_s;
        @memset(y_plane[ry * wu + cur_x ..][0..box_s], if (border) 235 else luma);
        if ((dy & 1) == 0) {
            const uv_row = uv_plane[(ry / 2) * wu + cur_x ..][0..box_s];
            var ix: usize = 0;
            while (ix < box_s) : (ix += 2) {
                uv_row[ix] = u_val;
                uv_row[ix + 1] = v_val;
            }
        }
    }
}

const t = std.testing;

test "NV12 4K aloca exatamente ~11.87 MiB e devolve tudo no free" {
    var buf = try allocNv12(3840, 2160);
    try t.expectEqual(@as(usize, 12_441_600), buf.len);
    initDemoBackground(buf, 3840, 2160);
    stepDemoOverlay(buf, 3840, 2160, 0, false);
    stepDemoOverlay(buf, 3840, 2160, 1, false);
    freeNv12(&buf);
    try t.expectEqual(@as(usize, 0), buf.len);
}
