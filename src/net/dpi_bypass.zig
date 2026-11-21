//! Türkiye ve kısıtlı ağlar için uygulama içi DoH (DNS-over-HTTPS) çözümleyici
//! ve SNI DPI ayrıştırma yapılandırması. Yönetici izni veya sürücü gerektirmez;
//! `CURLOPT_RESOLVE` aracılığıyla REST, Gateway, WebSocket (`*.discord.media`
//! kamera/ekran paylaşımı dahil), medya ve güncelleyiciyi doğrudan korur.
const std = @import("std");
const builtin = @import("builtin");
const sys = if (builtin.is_test) struct {
    pub fn setDpiSplitMode(_: u8) void {}
    pub fn curlTls(_: anytype) void {}
} else @import("../platform/sys.zig");

const c = if (builtin.is_test) struct {} else @import("c");
const alloc = std.heap.c_allocator;

pub const HostPort = struct {
    host: []const u8,
    port: u16,
    is_ipv6: bool = false,
};

pub fn parseHostPort(url: []const u8) ?HostPort {
    const sch = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sch];
    const def_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) 80 else 443;
    var rest = url[sch + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |cut| rest = rest[0..cut];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (rest.len == 0) return null;

    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        const host = rest[1..close];
        if (host.len == 0) return null;
        var port = def_port;
        const after = rest[close + 1 ..];
        if (after.len > 1 and after[0] == ':') {
            port = std.fmt.parseInt(u16, after[1..], 10) catch return null;
        }
        return .{ .host = host, .port = port, .is_ipv6 = true };
    }

    var host = rest;
    var port = def_port;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        host = rest[0..colon];
        port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or port == 0) return null;
    return .{ .host = host, .port = port };
}

fn isIpv4Literal(host: []const u8) bool {
    var octets: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg.len > 3) return false;
        _ = std.fmt.parseInt(u8, seg, 10) catch return false;
        octets += 1;
    }
    return octets == 4;
}

fn isIpv6Literal(host: []const u8) bool {
    var colons: usize = 0;
    for (host) |ch| {
        if (ch == ':') {
            colons += 1;
        } else if (!std.ascii.isHex(ch) and ch != '.') {
            return false;
        }
    }
    return colons >= 2 and host.len >= 2 and host.len <= 45;
}

pub fn isIpLiteral(host: []const u8) bool {
    if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    return isIpv4Literal(host) or isIpv6Literal(host);
}

pub const DnsAnswer = struct {
    ip_buf: [64]u8 = undefined,
    ip_len: u8 = 0,
    ttl_s: u32 = 300,

    pub fn slice(self: *const DnsAnswer) []const u8 {
        return self.ip_buf[0..self.ip_len];
    }
};

/// Cloudflare (`1.1.1.1/dns-query`) ve Google (`8.8.8.8/resolve`) JSON çıktısını okur.
/// Önce IPv4 (`type == 1`), yoksa IPv6 (`type == 28`) kaydını seçer.
pub fn parseDnsJsonAnswer(body: []const u8, gpa: std.mem.Allocator) ?DnsAnswer {
    if (body.len == 0 or body.len > 64 * 1024) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("Status")) |st| {
        if (st == .integer and st.integer != 0) return null;
    }
    const ans = parsed.value.object.get("Answer") orelse return null;
    if (ans != .array) return null;

    var v6_pick: ?DnsAnswer = null;
    for (ans.array.items) |item| {
        if (item != .object) continue;
        const tp = item.object.get("type") orelse continue;
        const dt = item.object.get("data") orelse continue;
        if (tp != .integer or dt != .string) continue;
        if (tp.integer != 1 and tp.integer != 28) continue;
        const ip = std.mem.trim(u8, dt.string, " \t\r\n");
        if (ip.len == 0 or ip.len > 63) continue;
        if (tp.integer == 1 and !isIpv4Literal(ip)) continue;
        if (tp.integer == 28 and !isIpv6Literal(ip)) continue;

        var out: DnsAnswer = .{};
        @memcpy(out.ip_buf[0..ip.len], ip);
        out.ip_len = @intCast(ip.len);
        if (item.object.get("TTL")) |ttl| {
            if (ttl == .integer and ttl.integer > 0) {
                out.ttl_s = @intCast(std.math.clamp(ttl.integer, 30, 600));
            }
        }
        if (tp.integer == 1) return out;
        if (v6_pick == null) v6_pick = out;
    }
    return v6_pick;
}

// --- Çalışma zamanı DoH önbelleği ve `CURLOPT_RESOLVE` bağlayıcısı ---

pub var qa_no_network = false;

var doh_mode: std.atomic.Value(u8) = .init(1); // 0=kapalı, 1=Cloudflare(1.1.1.1), 2=Google(8.8.8.8)
var split_mode_val: std.atomic.Value(u8) = .init(1); // 0=kapalı, 1=Akıllı TCP bölme, 2=Sert kayıt bölme

pub fn setConfig(doh: u8, split: u8) void {
    doh_mode.store(@min(doh, 2), .release);
    const sp = @min(split, 2);
    split_mode_val.store(sp, .release);
    if (!builtin.is_test) sys.setDpiSplitMode(sp);
}

pub fn currentDoh() u8 {
    return doh_mode.load(.acquire);
}

pub fn currentSplit() u8 {
    return split_mode_val.load(.acquire);
}

const CacheEntry = struct {
    host: [256]u8 = undefined,
    host_len: u16 = 0,
    ip: [64]u8 = undefined,
    ip_len: u8 = 0,
    expires_ms: i64 = 0,
    used_at: i64 = 0,

    fn matches(e: *const CacheEntry, h: []const u8, now_ms: i64) bool {
        return e.host_len == h.len and now_ms < e.expires_ms and std.ascii.eqlIgnoreCase(e.host[0..e.host_len], h);
    }
};

var cache_mu: ?*anyopaque = null;
var cache_slots: [64]CacheEntry = @splat(.{});
var cache_init_once: std.atomic.Value(u8) = .init(0);

fn lockCache() void {
    if (builtin.is_test) return;
    while (true) {
        const s = cache_init_once.load(.acquire);
        if (s == 2) break;
        if (s == 0 and cache_init_once.cmpxchgWeak(0, 1, .acq_rel, .acquire) == null) {
            cache_mu = c.SDL_CreateMutex();
            cache_init_once.store(2, .release);
            break;
        }
        c.SDL_Delay(1);
    }
    if (cache_mu) |m| _ = c.SDL_LockMutex(@ptrCast(m));
}

fn unlockCache() void {
    if (builtin.is_test) return;
    if (cache_mu) |m| _ = c.SDL_UnlockMutex(@ptrCast(m));
}

fn cacheGet(host: []const u8, now_ms: i64, out: *[64]u8) ?[]const u8 {
    lockCache();
    defer unlockCache();
    for (&cache_slots) |*e| {
        if (e.matches(host, now_ms)) {
            @memcpy(out[0..e.ip_len], e.ip[0..e.ip_len]);
            e.used_at = now_ms;
            return out[0..e.ip_len];
        }
    }
    return null;
}

fn cachePut(host: []const u8, ip: []const u8, ttl_s: u32, now_ms: i64) void {
    if (host.len == 0 or host.len > 255 or ip.len == 0 or ip.len > 63) return;
    lockCache();
    defer unlockCache();
    var pick: *CacheEntry = &cache_slots[0];
    var oldest: i64 = std.math.maxInt(i64);
    for (&cache_slots) |*e| {
        if (e.host_len == host.len and std.ascii.eqlIgnoreCase(e.host[0..e.host_len], host)) {
            pick = e;
            break;
        }
        if (e.host_len == 0 or e.expires_ms <= now_ms) {
            pick = e;
            break;
        }
        if (e.used_at < oldest) {
            oldest = e.used_at;
            pick = e;
        }
    }
    @memcpy(pick.host[0..host.len], host);
    pick.host_len = @intCast(host.len);
    @memcpy(pick.ip[0..ip.len], ip);
    pick.ip_len = @intCast(ip.len);
    pick.expires_ms = now_ms + @as(i64, ttl_s) * 1000;
    pick.used_at = now_ms;
}

fn writeDohCb(ptr: [*c]u8, size: usize, n: usize, ud: ?*anyopaque) callconv(.c) usize {
    const out: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
    const total = size * n;
    if (out.items.len + total > 32 * 1024) return 0;
    out.appendSlice(alloc, ptr[0..total]) catch return 0;
    return total;
}

fn queryDohOne(base_url: []const u8, host: []const u8) ?DnsAnswer {
    if (builtin.is_test) return null;
    const h = c.curl_easy_init() orelse return null;
    defer c.curl_easy_cleanup(h);

    var url_buf: [384]u8 = undefined;
    const qurl = std.fmt.bufPrintSentinel(&url_buf, "{s}{s}&type=A", .{ base_url, host }, 0) catch return null;
    var hdrs: ?*c.struct_curl_slist = null;
    hdrs = c.curl_slist_append(hdrs, "Accept: application/dns-json");
    defer if (hdrs) |l| c.curl_slist_free_all(l);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    sys.curlTls(h);
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, qurl.ptr);
    if (hdrs) |l| _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, l);
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https");
    _ = c.curl_easy_setopt(h, c.CURLOPT_REDIR_PROTOCOLS_STR, "https");
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT_MS, @as(c_long, 2500));
    _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 1800));
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeDohCb);
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &body);
    if (c.curl_easy_perform(h) != c.CURLE_OK) return null;

    var status: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
    if (status != 200) return null;
    return parseDnsJsonAnswer(body.items, alloc);
}

pub fn resolveHostDoh(host: []const u8, out_ip: *[64]u8) ?[]const u8 {
    if (builtin.is_test or qa_no_network) return null;
    const mode = doh_mode.load(.acquire);
    if (mode == 0 or host.len == 0 or host.len > 255 or isIpLiteral(host)) return null;
    // Host adında geçersiz URL karakteri varsa DoH sorgulama.
    for (host) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-')) return null;
    }

    const now_ms: i64 = @intCast(c.SDL_GetTicks());
    if (cacheGet(host, now_ms, out_ip)) |hit| return hit;

    const endpoints = if (mode == 2)
        [3][]const u8{
            "https://8.8.8.8/resolve?name=",
            "https://1.1.1.1/dns-query?name=",
            "https://1.0.0.1/dns-query?name=",
        }
    else
        [3][]const u8{
            "https://1.1.1.1/dns-query?name=",
            "https://8.8.8.8/resolve?name=",
            "https://8.8.4.4/resolve?name=",
        };

    for (endpoints) |ep| {
        if (queryDohOne(ep, host)) |ans| {
            const ip = ans.slice();
            cachePut(host, ip, ans.ttl_s, now_ms);
            @memcpy(out_ip[0..ip.len], ip);
            return out_ip[0..ip.len];
        }
    }
    return null;
}

pub const ResolveGuard = struct {
    list: ?*anyopaque = null,

    pub fn attach(h: *anyopaque, url: []const u8, has_proxy: bool) ResolveGuard {
        if (builtin.is_test or qa_no_network or has_proxy) return .{};
        if (doh_mode.load(.acquire) == 0) return .{};
        const hp = parseHostPort(url) orelse return .{};
        if (isIpLiteral(hp.host)) return .{};

        var ip_buf: [64]u8 = undefined;
        const ip = resolveHostDoh(hp.host, &ip_buf) orelse return .{};

        var entry_buf: [360]u8 = undefined;
        const is_v6 = std.mem.indexOfScalar(u8, ip, ':') != null;
        const entry = if (is_v6)
            std.fmt.bufPrintSentinel(&entry_buf, "{s}:{d}:[{s}]", .{ hp.host, hp.port, ip }, 0)
        else
            std.fmt.bufPrintSentinel(&entry_buf, "{s}:{d}:{s}", .{ hp.host, hp.port, ip }, 0);
        const ez = entry catch return .{};

        const sl = c.curl_slist_append(null, ez.ptr) orelse return .{};
        const curl_h: *c.CURL = @ptrCast(@alignCast(h));
        _ = c.curl_easy_setopt(curl_h, c.CURLOPT_RESOLVE, sl);
        return .{ .list = sl };
    }

    pub fn detach(self: *ResolveGuard, h: ?*anyopaque) void {
        if (builtin.is_test) return;
        if (self.list) |p| {
            if (h) |ch| {
                const curl_h: *c.CURL = @ptrCast(@alignCast(ch));
                _ = c.curl_easy_setopt(curl_h, c.CURLOPT_RESOLVE, @as(?*anyopaque, null));
            }
            c.curl_slist_free_all(@ptrCast(@alignCast(p)));
            self.list = null;
        }
    }

    pub fn deinit(self: *ResolveGuard) void {
        self.detach(null);
    }
};

// --- Birim testleri ---

const t = std.testing;

test "parseHostPort extrai host e porta de URLs Discord e IPv6" {
    const a = parseHostPort("wss://c-fra10-abc.discord.media/?v=8").?;
    try t.expectEqualStrings("c-fra10-abc.discord.media", a.host);
    try t.expectEqual(@as(u16, 443), a.port);

    const b = parseHostPort("https://discord.com:8443/api/v9/users/@me").?;
    try t.expectEqualStrings("discord.com", b.host);
    try t.expectEqual(@as(u16, 8443), b.port);

    const v6 = parseHostPort("https://[2606:4700::1]:443/test").?;
    try t.expectEqualStrings("2606:4700::1", v6.host);
    try t.expectEqual(@as(u16, 443), v6.port);
    try t.expect(v6.is_ipv6);
}

test "isIpLiteral reconhece IPs e localhost" {
    try t.expect(isIpLiteral("1.1.1.1"));
    try t.expect(isIpLiteral("127.0.0.1"));
    try t.expect(isIpLiteral("::1"));
    try t.expect(isIpLiteral("localhost"));
    try t.expect(!isIpLiteral("discord.com"));
    try t.expect(!isIpLiteral("gateway.discord.gg"));
}

test "parseDnsJsonAnswer prioriza registro A e valida IP" {
    const sample =
        \\{"Status":0,"Answer":[{"name":"discord.com.","type":5,"TTL":120,"data":"alias.discord.com."},{"name":"discord.com.","type":28,"TTL":200,"data":"2606:4700::1"},{"name":"discord.com.","type":1,"TTL":180,"data":"162.159.135.232"}]}
    ;
    const ans = parseDnsJsonAnswer(sample, std.testing.allocator).?;
    try t.expectEqualStrings("162.159.135.232", ans.slice());
    try t.expectEqual(@as(u32, 180), ans.ttl_s);

    const nx = "{\"Status\":3,\"Answer\":[]}";
    try t.expect(parseDnsJsonAnswer(nx, std.testing.allocator) == null);

    const bad_ip = "{\"Status\":0,\"Answer\":[{\"type\":1,\"TTL\":100,\"data\":\"not.an.ip\"}]}";
    try t.expect(parseDnsJsonAnswer(bad_ip, std.testing.allocator) == null);
}
