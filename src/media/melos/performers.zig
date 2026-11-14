//! Performer accounts, bcrypt hashes, cookie sessions, login lockout, and CLI.
//! Plaintext passwords are never logged and are written only to the mode-600
//! initial-credentials file by the admin CLI (never by the server process).

const std = @import("std");
const words = @import("words.zig");

const bcrypt = std.crypto.pwhash.bcrypt;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

pub const MAX_USERS = 16;
pub const MAX_SESSIONS = 64;
pub const MAX_LOCKOUTS = 64;
pub const SESSION_TTL_S: i64 = 12 * 60 * 60;
pub const FAIL_LIMIT: u32 = 5;
pub const LOCK_BASE_S: i64 = 30;
pub const LOCK_MAX_S: i64 = 300;
pub const COOKIE_NAME = "melos_session";
pub const USERNAME_MAX = 32;
pub const HASH_MAX = 128;
pub const TOKEN_RAW = 32;
pub const TOKEN_HEX = TOKEN_RAW * 2;

const DEFAULT_HASH_PATH = "/opt/arcis/engine/secrets/performers.hashes";
const DEFAULT_INITIAL_PATH = "/opt/arcis/engine/secrets/performers-initial.txt";

pub const AuthInfo = struct {
    cookie: []const u8 = "",
    origin: []const u8 = "",
    referer: []const u8 = "",
    remote_ip: []const u8 = "",
    peer_loopback: bool = false,
};

pub const UserName = struct {
    buf: [USERNAME_MAX]u8 = undefined,
    len: u8 = 0,
    pub fn slice(self: *const UserName) []const u8 {
        return self.buf[0..self.len];
    }
};

const User = struct {
    name_buf: [USERNAME_MAX]u8 = undefined,
    name_len: u8 = 0,
    hash_buf: [HASH_MAX]u8 = undefined,
    hash_len: u8 = 0,

    fn name(self: *const User) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn hash(self: *const User) []const u8 {
        return self.hash_buf[0..self.hash_len];
    }
};

const Session = struct {
    used: bool = false,
    digest: [32]u8 = undefined,
    name_buf: [USERNAME_MAX]u8 = undefined,
    name_len: u8 = 0,
    expires: i64 = 0,

    fn username(self: *const Session) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const Lock = struct {
    used: bool = false,
    key_buf: [80]u8 = undefined,
    key_len: u8 = 0,
    fails: u32 = 0,
    locked_until: i64 = 0,
    backoff_s: i64 = LOCK_BASE_S,

    fn key(self: *const Lock) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

const Store = struct {
    mutex: std.Thread.Mutex = .{},
    users: [MAX_USERS]User = undefined,
    n_users: usize = 0,
    sessions: [MAX_SESSIONS]Session = [_]Session{.{}} ** MAX_SESSIONS,
    locks: [MAX_LOCKOUTS]Lock = [_]Lock{.{}} ** MAX_LOCKOUTS,
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,
    file_mtime: i128 = 0,
};

var g: Store = .{};

fn hashPath() []const u8 {
    if (g.path_len > 0) return g.path_buf[0..g.path_len];
    return std.posix.getenv("MELOS_PERFORMERS_FILE") orelse DEFAULT_HASH_PATH;
}

fn initialPath() []const u8 {
    return std.posix.getenv("MELOS_PERFORMERS_INITIAL") orelse DEFAULT_INITIAL_PATH;
}

fn setPath(p: []const u8) void {
    const n = @min(p.len, g.path_buf.len);
    @memcpy(g.path_buf[0..n], p[0..n]);
    g.path_len = n;
}

pub fn hasAccounts() bool {
    g.mutex.lock();
    defer g.mutex.unlock();
    return g.n_users > 0;
}

pub fn accountCount() usize {
    g.mutex.lock();
    defer g.mutex.unlock();
    return g.n_users;
}

/// True when performer routes must require a session or (if set) MELOS_PERFORMER_TOKEN.
pub fn authRequired() bool {
    return hasAccounts();
}

pub fn validUsername(name: []const u8) bool {
    if (name.len < 3 or name.len > USERNAME_MAX) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

pub fn originIsTrusted(origin: []const u8) bool {
    if (origin.len == 0) return false;
    if (std.mem.eql(u8, origin, "https://www.fizz.beer")) return true;
    if (std.mem.eql(u8, origin, "https://fizz.beer")) return true;
    return isLoopbackOrigin(origin);
}

fn isLoopbackOrigin(origin: []const u8) bool {
    const prefixes = [_][]const u8{ "http://127.0.0.1", "http://localhost", "http://[::1]" };
    for (prefixes) |p| {
        if (std.mem.eql(u8, origin, p)) return true;
        if (origin.len > p.len and std.mem.startsWith(u8, origin, p) and origin[p.len] == ':') {
            const port = origin[p.len + 1 ..];
            if (port.len == 0 or port.len > 5) return false;
            for (port) |c| if (!std.ascii.isDigit(c)) return false;
            const n = std.fmt.parseInt(u32, port, 10) catch return false;
            return n >= 1 and n <= 65535;
        }
    }
    return false;
}

fn refererOrigin(referer: []const u8) ?[]const u8 {
    // scheme://host[:port]
    const scheme_end = std.mem.indexOf(u8, referer, "://") orelse return null;
    const rest = referer[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return referer[0 .. scheme_end + 3 + slash];
}

pub fn originAllowed(auth: AuthInfo) bool {
    if (auth.origin.len > 0) return originIsTrusted(auth.origin);
    if (auth.referer.len > 0) {
        if (refererOrigin(auth.referer)) |o| return originIsTrusted(o);
    }
    return auth.peer_loopback;
}

pub fn cookieValue(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |part| {
        const kv = std.mem.trim(u8, part, " \t");
        if (kv.len < name.len + 1) continue;
        if (!std.mem.startsWith(u8, kv, name)) continue;
        if (kv[name.len] != '=') continue;
        return kv[name.len + 1 ..];
    }
    return null;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn decodeHex32(hex: []const u8, out: *[TOKEN_RAW]u8) bool {
    if (hex.len != TOKEN_HEX) return false;
    var i: usize = 0;
    while (i < TOKEN_RAW) : (i += 1) {
        const hi = hexDigit(hex[i * 2]) orelse return false;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return false;
        out[i] = (hi << 4) | lo;
    }
    return true;
}

fn tokenDigest(raw: *const [TOKEN_RAW]u8) [32]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(raw, &d, .{});
    return d;
}

fn ctEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn now() i64 {
    return std.time.timestamp();
}

fn findUser(name: []const u8) ?*User {
    var i: usize = 0;
    while (i < g.n_users) : (i += 1) {
        if (std.mem.eql(u8, g.users[i].name(), name)) return &g.users[i];
    }
    return null;
}

fn copyName(dst: []u8, src: []const u8) u8 {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

/// Returns the username for a valid, unexpired session cookie, or null.
pub fn sessionUser(cookie_header: []const u8) ?UserName {
    invalidateSessionsIfFileChanged();
    const raw_hex = cookieValue(cookie_header, COOKIE_NAME) orelse return null;
    var raw: [TOKEN_RAW]u8 = undefined;
    if (!decodeHex32(raw_hex, &raw)) return null;
    const digest = tokenDigest(&raw);
    const t = now();
    g.mutex.lock();
    defer g.mutex.unlock();
    for (&g.sessions) |*s| {
        if (!s.used) continue;
        if (s.expires <= t) {
            s.used = false;
            continue;
        }
        if (ctEq(&s.digest, &digest)) {
            var un: UserName = .{};
            un.len = copyName(&un.buf, s.username());
            return un;
        }
    }
    return null;
}

pub fn sessionOk(auth: AuthInfo, mutating: bool) bool {
    if (sessionUser(auth.cookie) == null) return false;
    if (mutating and !originAllowed(auth)) return false;
    return true;
}

pub fn tokenMatches(want: []const u8, got: ?[]const u8) bool {
    const t = got orelse return false;
    return ctEq(want, t);
}

fn hashPassword(password: []const u8, out: *[HASH_MAX]u8) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = bcrypt.Params.owasp,
        .encoding = .crypt,
    }, out);
}

fn verifyPassword(hash: []const u8, password: []const u8) bool {
    bcrypt.strVerify(hash, password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

var dummy_hash_mu: std.Thread.Mutex = .{};
var dummy_hash_buf: [HASH_MAX]u8 = undefined;
var dummy_hash_len: usize = 0;

fn dummyHash() []const u8 {
    dummy_hash_mu.lock();
    defer dummy_hash_mu.unlock();
    if (dummy_hash_len == 0) {
        const h = hashPassword("not-a-real-account-dummy", &dummy_hash_buf) catch return "$2b$10$012345678901234567890uabcdefghijklmnopqrstuvwxy123456";
        dummy_hash_len = h.len;
    }
    return dummy_hash_buf[0..dummy_hash_len];
}

fn lockKeyCopy(kind: []const u8, value: []const u8, buf: *[80]u8) []const u8 {
    const n = std.fmt.bufPrint(buf, "{s}:{s}", .{ kind, value }) catch buf[0..0];
    return n;
}

fn getOrCreateLock(key: []const u8) ?*Lock {
    var free: ?*Lock = null;
    for (&g.locks) |*L| {
        if (L.used and std.mem.eql(u8, L.key(), key)) return L;
        if (!L.used and free == null) free = L;
    }
    const L = free orelse return null;
    const n = @min(key.len, L.key_buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) L.key_buf[i] = key[i];
    L.used = true;
    L.key_len = @intCast(n);
    L.fails = 0;
    L.locked_until = 0;
    L.backoff_s = LOCK_BASE_S;
    return L;
}

fn lockRemaining(L: *const Lock, t: i64) i64 {
    if (L.locked_until <= t) return 0;
    return L.locked_until - t;
}

const LoginError = error{ InvalidCredentials, Locked, OriginDenied, NoAccounts, Internal };

pub const LoginResult = struct {
    status: u16,
    error_msg: ?[]const u8 = null,
    retry_after_ms: ?i64 = null,
    username: ?[]const u8 = null,
    cookie: ?[]u8 = null,
};

fn setCookieHeader(allocator: Allocator, token_hex: ?[]const u8, max_age: i64) ![]u8 {
    if (token_hex) |hex| {
        return std.fmt.allocPrint(allocator, "{s}={s}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age={d}", .{ COOKIE_NAME, hex, max_age });
    }
    return std.fmt.allocPrint(allocator, "{s}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0", .{COOKIE_NAME});
}

fn createSessionLocked(username: []const u8, token_hex_out: *[TOKEN_HEX]u8) bool {
    var raw: [TOKEN_RAW]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const digest = tokenDigest(&raw);
    _ = std.fmt.bufPrint(token_hex_out, "{s}", .{std.fmt.fmtSliceHexLower(&raw)}) catch return false;
    const t = now();
    var slot: ?*Session = null;
    var oldest_exp: i64 = std.math.maxInt(i64);
    var oldest: ?*Session = null;
    for (&g.sessions) |*s| {
        if (s.used and s.expires <= t) s.used = false;
        if (!s.used and slot == null) slot = s;
        if (s.used and s.expires < oldest_exp) {
            oldest_exp = s.expires;
            oldest = s;
        }
    }
    const s = slot orelse oldest orelse return false;
    const n = @min(username.len, s.name_buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) s.name_buf[i] = username[i];
    s.used = true;
    s.digest = digest;
    s.name_len = @intCast(n);
    s.expires = t + SESSION_TTL_S;
    return true;
}

fn dropSessionsFor(username: []const u8, keep_digest: ?[]const u8) void {
    for (&g.sessions) |*s| {
        if (!s.used) continue;
        if (!std.mem.eql(u8, s.username(), username)) continue;
        if (keep_digest) |d| {
            if (ctEq(&s.digest, d)) continue;
        }
        s.used = false;
    }
}

pub fn dropSessionByCookie(cookie_header: []const u8) void {
    const raw_hex = cookieValue(cookie_header, COOKIE_NAME) orelse return;
    var raw: [TOKEN_RAW]u8 = undefined;
    if (!decodeHex32(raw_hex, &raw)) return;
    const digest = tokenDigest(&raw);
    g.mutex.lock();
    defer g.mutex.unlock();
    for (&g.sessions) |*s| {
        if (s.used and ctEq(&s.digest, &digest)) s.used = false;
    }
}

pub fn login(allocator: Allocator, auth: AuthInfo, username: []const u8, password: []const u8) LoginResult {
    invalidateSessionsIfFileChanged();
    if (!originAllowed(auth)) {
        return .{ .status = 403, .error_msg = "origin not allowed" };
    }
    if (!validUsername(username) or password.len < 8 or password.len > 72) {
        // Still touch dummy hash so timing is not a cheap oracle for "no such user".
        _ = verifyPassword(dummyHash(), password);
        return .{ .status = 401, .error_msg = "invalid credentials" };
    }

    var user_key_buf: [80]u8 = undefined;
    var ip_key_buf: [80]u8 = undefined;
    const uk = lockKeyCopy("u", username, &user_key_buf);
    const ik = lockKeyCopy("ip", if (auth.remote_ip.len > 0) auth.remote_ip else "unknown", &ip_key_buf);

    var hash_copy: [HASH_MAX]u8 = undefined;
    var hash_len: usize = 0;
    var known = false;

    g.mutex.lock();
    const t0 = now();
    if (g.n_users == 0) {
        g.mutex.unlock();
        return .{ .status = 401, .error_msg = "invalid credentials" };
    }
    if (getOrCreateLock(uk)) |Lu| {
        const rem = lockRemaining(Lu, t0);
        if (rem > 0) {
            g.mutex.unlock();
            return .{ .status = 429, .error_msg = "too many attempts", .retry_after_ms = rem * 1000 };
        }
    }
    if (getOrCreateLock(ik)) |Li| {
        const rem = lockRemaining(Li, t0);
        if (rem > 0) {
            g.mutex.unlock();
            return .{ .status = 429, .error_msg = "too many attempts", .retry_after_ms = rem * 1000 };
        }
    }
    if (findUser(username)) |u| {
        known = true;
        hash_len = u.hash_len;
        var i: usize = 0;
        while (i < hash_len) : (i += 1) hash_copy[i] = u.hash_buf[i];
    }
    g.mutex.unlock();

    // Admin reset writes the hash file from another process; always prefer disk.
    var disk_buf: [HASH_MAX]u8 = undefined;
    if (readUserHashFromFile(username, &disk_buf)) |dh| {
        known = true;
        hash_len = dh.len;
        var i: usize = 0;
        while (i < hash_len) : (i += 1) hash_copy[i] = dh[i];
    }

    const ok = if (known)
        verifyPassword(hash_copy[0..hash_len], password)
    else
        verifyPassword(dummyHash(), password);

    g.mutex.lock();
    defer g.mutex.unlock();
    if (!ok) {
        recordFailure(uk, ik);
        return .{ .status = 401, .error_msg = "invalid credentials" };
    }
    clearFailure(uk);
    clearFailure(ik);
    var token_hex: [TOKEN_HEX]u8 = undefined;
    if (!createSessionLocked(username, &token_hex)) {
        return .{ .status = 503, .error_msg = "session store full" };
    }
    const cookie = setCookieHeader(allocator, &token_hex, SESSION_TTL_S) catch {
        return .{ .status = 500, .error_msg = "internal error" };
    };
    return .{ .status = 200, .username = findUser(username).?.name(), .cookie = cookie };
}

fn recordFailure(uk: []const u8, ik: []const u8) void {
    const t = now();
    for ([_][]const u8{ uk, ik }) |key| {
        const L = getOrCreateLock(key) orelse continue;
        L.fails += 1;
        if (L.fails >= FAIL_LIMIT) {
            L.locked_until = t + L.backoff_s;
            L.fails = 0;
            L.backoff_s = @min(L.backoff_s * 2, LOCK_MAX_S);
        }
    }
}

fn clearFailure(key: []const u8) void {
    for (&g.locks) |*L| {
        if (L.used and std.mem.eql(u8, L.key(), key)) {
            L.fails = 0;
            L.locked_until = 0;
            L.backoff_s = LOCK_BASE_S;
        }
    }
}

pub const ChangeError = error{ Unauthorized, OriginDenied, InvalidCurrent, WeakPassword, Internal };

pub fn changePassword(allocator: Allocator, auth: AuthInfo, current: []const u8, new_pw: []const u8) ChangeError!void {
    invalidateSessionsIfFileChanged();
    _ = allocator;
    if (!originAllowed(auth)) return error.OriginDenied;
    const user_n = sessionUser(auth.cookie) orelse return error.Unauthorized;
    const user = user_n.slice();
    if (new_pw.len < 8 or new_pw.len > 72) return error.WeakPassword;

    var hash_copy: [HASH_MAX]u8 = undefined;
    var hash_len: usize = 0;
    var name_copy: [USERNAME_MAX]u8 = undefined;
    var name_len: u8 = 0;
    g.mutex.lock();
    if (findUser(user)) |u| {
        hash_len = u.hash_len;
        @memcpy(hash_copy[0..hash_len], u.hash());
        name_len = u.name_len;
        @memcpy(name_copy[0..name_len], u.name());
    } else {
        g.mutex.unlock();
        return error.Unauthorized;
    }
    g.mutex.unlock();

    if (!verifyPassword(hash_copy[0..hash_len], current)) return error.InvalidCurrent;

    var new_hash_buf: [HASH_MAX]u8 = undefined;
    const new_hash = hashPassword(new_pw, &new_hash_buf) catch return error.Internal;

    g.mutex.lock();
    defer g.mutex.unlock();
    if (findUser(name_copy[0..name_len])) |u| {
        u.hash_len = @intCast(new_hash.len);
        @memcpy(u.hash_buf[0..new_hash.len], new_hash);
    } else return error.Unauthorized;
    persistLocked() catch return error.Internal;
    // Keep the current session; drop others for this user.
    if (cookieValue(auth.cookie, COOKIE_NAME)) |hex| {
        var raw: [TOKEN_RAW]u8 = undefined;
        if (decodeHex32(hex, &raw)) {
            const d = tokenDigest(&raw);
            dropSessionsFor(name_copy[0..name_len], &d);
        }
    }
}

fn persistLocked() !void {
    const path = hashPath();
    if (path.len == 0) return;
    try writeHashFile(path);
}

fn writeHashFile(path: []const u8) !void {
    try ensureParentDir(path);
    var tmp_buf: [1080]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .read = true, .mode = 0o600 });
        defer f.close();
        f.chmod(0o600) catch {};
        try writeHashContents(f);
    }
    try std.fs.cwd().rename(tmp, path);
    chmodPath(path, 0o600);
    g.file_mtime = fileMtime(path);
}

fn writeHashContents(f: std.fs.File) !void {
    const w = f.writer();
    try w.writeAll("# melos performer hashes v1\n# username <bcrypt>\n");
    var i: usize = 0;
    while (i < g.n_users) : (i += 1) {
        try w.print("{s} {s}\n", .{ g.users[i].name(), g.users[i].hash() });
    }
}

fn chmodPath(path: []const u8, mode: std.fs.File.Mode) void {
    if (std.fs.cwd().openFile(path, .{ .mode = .read_only })) |f| {
        defer f.close();
        f.chmod(mode) catch {};
        return;
    } else |_| {}
    var dir = std.fs.cwd().openDir(path, .{}) catch return;
    defer dir.close();
    dir.chmod(mode) catch {};
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    chmodPath(dir, 0o700);
}

fn parseHashLine(line_in: []const u8) ?struct { name: []const u8, hash: []const u8 } {
    const line = std.mem.trim(u8, line_in, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return null;
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const name = line[0..sp];
    const hash = std.mem.trim(u8, line[sp + 1 ..], " \t");
    if (!validUsername(name) or hash.len < 20 or hash.len > HASH_MAX) return null;
    return .{ .name = name, .hash = hash };
}

fn fileMtime(path: []const u8) i128 {
    const st = std.fs.cwd().statFile(path) catch return 0;
    return st.mtime;
}

/// If the hash file was rewritten (admin reset), drop all sessions.
/// Login reads hashes from disk, so we do not parse the file on this path.
pub fn invalidateSessionsIfFileChanged() void {
    const path = hashPath();
    const mt = fileMtime(path);
    g.mutex.lock();
    defer g.mutex.unlock();
    if (mt == 0 or mt == g.file_mtime) return;
    for (&g.sessions) |*s| s.used = false;
    g.file_mtime = mt;
}

fn readUserHashFromFile(username: []const u8, out: *[HASH_MAX]u8) ?[]const u8 {
    const path = hashPath();
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var line_buf: [256]u8 = undefined;
    const r = f.reader();
    while (true) {
        const line = r.readUntilDelimiterOrEof(&line_buf, '\n') catch return null;
        const raw = line orelse break;
        const rec = parseHashLine(raw) orelse continue;
        if (!std.mem.eql(u8, rec.name, username)) continue;
        const n = @min(rec.hash.len, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) out[i] = rec.hash[i];
        return out[0..n];
    }
    return null;
}

pub fn loadFromPath(path: []const u8) !void {
    setPath(path);
    const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer f.close();
    const mt = fileMtime(path);

    var parsed: [MAX_USERS]User = undefined;
    var n_parsed: usize = 0;
    var line_buf: [256]u8 = undefined;
    const r = f.reader();
    while (true) {
        const line = r.readUntilDelimiterOrEof(&line_buf, '\n') catch return error.FileTooBig;
        const raw = line orelse break;
        const rec = parseHashLine(raw) orelse continue;
        if (n_parsed >= MAX_USERS) break;
        var u: User = .{};
        const nl: u8 = @intCast(@min(rec.name.len, USERNAME_MAX));
        const hl: u8 = @intCast(@min(rec.hash.len, HASH_MAX));
        var i: usize = 0;
        while (i < nl) : (i += 1) u.name_buf[i] = rec.name[i];
        u.name_len = nl;
        i = 0;
        while (i < hl) : (i += 1) u.hash_buf[i] = rec.hash[i];
        u.hash_len = hl;
        parsed[n_parsed] = u;
        n_parsed += 1;
    }

    var stale_names: [MAX_USERS][USERNAME_MAX]u8 = undefined;
    var stale_nlen: [MAX_USERS]u8 = undefined;
    var stale_count: usize = 0;

    g.mutex.lock();
    defer g.mutex.unlock();

    var oi: usize = 0;
    while (oi < g.n_users) : (oi += 1) {
        const oname = g.users[oi].name();
        const ohash = g.users[oi].hash();
        var found = false;
        var pi: usize = 0;
        while (pi < n_parsed) : (pi += 1) {
            if (std.mem.eql(u8, parsed[pi].name(), oname) and ctEq(parsed[pi].hash(), ohash)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const nl = g.users[oi].name_len;
            stale_nlen[stale_count] = nl;
            var i: usize = 0;
            while (i < nl) : (i += 1) stale_names[stale_count][i] = g.users[oi].name_buf[i];
            stale_count += 1;
        }
    }

    g.n_users = n_parsed;
    oi = 0;
    while (oi < n_parsed) : (oi += 1) {
        g.users[oi] = parsed[oi];
    }
    g.file_mtime = mt;

    oi = 0;
    while (oi < stale_count) : (oi += 1) {
        dropSessionsFor(stale_names[oi][0..stale_nlen[oi]], null);
    }
}

pub fn loadDefault() !void {
    const path = std.posix.getenv("MELOS_PERFORMERS_FILE") orelse DEFAULT_HASH_PATH;
    try loadFromPath(path);
}

pub fn resetStore() void {
    g.mutex.lock();
    defer g.mutex.unlock();
    g.n_users = 0;
    g.path_len = 0;
    for (&g.sessions) |*s| s.used = false;
    for (&g.locks) |*L| L.used = false;
}

/// Test helper: add a user with an already-computed hash. Not used in production.
pub fn testingAddHashed(name: []const u8, hash: []const u8) !void {
    g.mutex.lock();
    defer g.mutex.unlock();
    if (g.n_users >= MAX_USERS) return error.TooManyUsers;
    if (findUser(name) != null) return error.Exists;
    var u: User = .{};
    u.name_len = copyName(&u.name_buf, name);
    u.hash_len = @intCast(hash.len);
    @memcpy(u.hash_buf[0..hash.len], hash);
    g.users[g.n_users] = u;
    g.n_users += 1;
}

pub fn testingAddPassword(name: []const u8, password: []const u8) !void {
    var buf: [HASH_MAX]u8 = undefined;
    const h = try hashPassword(password, &buf);
    try testingAddHashed(name, h);
}

pub fn generatePassword(out: *[64]u8) []const u8 {
    const w1 = words.words[std.crypto.random.uintLessThan(usize, words.words.len)];
    var w2 = words.words[std.crypto.random.uintLessThan(usize, words.words.len)];
    // Avoid a repeated word when the list allows it.
    if (words.words.len > 1) {
        var guard: u8 = 0;
        while (std.mem.eql(u8, w1, w2) and guard < 8) : (guard += 1) {
            w2 = words.words[std.crypto.random.uintLessThan(usize, words.words.len)];
        }
    }
    const nn = std.crypto.random.uintLessThan(u32, 10000);
    return std.fmt.bufPrint(out, "{s}-{s}-{d:0>4}", .{ w1, w2, nn }) catch unreachable;
}

fn writeInitialFile(path: []const u8, contents: []const u8, append: bool) !void {
    try ensureParentDir(path);
    var tmp_buf: [1080]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    if (append) {
        // Read existing (if any), then write combined to tmp and rename.
        var combined = std.ArrayList(u8).init(std.heap.page_allocator);
        defer combined.deinit();
        if (std.fs.cwd().openFile(path, .{})) |ef| {
            defer ef.close();
            const existing = try ef.readToEndAlloc(std.heap.page_allocator, 64 * 1024);
            defer std.heap.page_allocator.free(existing);
            try combined.appendSlice(existing);
            if (existing.len > 0 and existing[existing.len - 1] != '\n') try combined.append('\n');
        } else |_| {}
        try combined.appendSlice(contents);
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        f.chmod(0o600) catch {};
        try f.writeAll(combined.items);
    } else {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        f.chmod(0o600) catch {};
        try f.writeAll(contents);
    }
    try std.fs.cwd().rename(tmp, path);
    chmodPath(path, 0o600);
}

fn addOrReplaceUserLocked(name: []const u8, hash: []const u8) !void {
    if (findUser(name)) |u| {
        u.hash_len = @intCast(hash.len);
        @memcpy(u.hash_buf[0..hash.len], hash);
        return;
    }
    if (g.n_users >= MAX_USERS) return error.TooManyUsers;
    var u: User = .{};
    u.name_len = copyName(&u.name_buf, name);
    u.hash_len = @intCast(hash.len);
    @memcpy(u.hash_buf[0..hash.len], hash);
    g.users[g.n_users] = u;
    g.n_users += 1;
}

pub fn runCli(allocator: Allocator, args: []const []const u8) !void {
    const stderr = std.io.getStdErr().writer();
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        try stderr.writeAll("usage: performers.sh init [--force] | list | reset <username>\n");
        return;
    }
    if (std.mem.eql(u8, args[0], "init")) {
        var force = false;
        for (args[1..]) |a| {
            if (std.mem.eql(u8, a, "--force")) force = true;
        }
        try cmdInit(allocator, force);
        return;
    }
    if (std.mem.eql(u8, args[0], "list")) {
        try cmdList();
        return;
    }
    if (std.mem.eql(u8, args[0], "reset")) {
        if (args.len < 2) {
            try stderr.writeAll("usage: performers.sh reset <username>\n");
            std.process.exit(2);
        }
        try cmdReset(allocator, args[1]);
        return;
    }
    try stderr.print("unknown performers command: {s}\n", .{args[0]});
    std.process.exit(2);
}

fn cmdInit(allocator: Allocator, force: bool) !void {
    const stderr = std.io.getStdErr().writer();
    const hpath = std.posix.getenv("MELOS_PERFORMERS_FILE") orelse DEFAULT_HASH_PATH;
    const ipath = initialPath();
    setPath(hpath);
    if (!force) {
        if (std.fs.cwd().openFile(hpath, .{})) |f| {
            f.close();
            try stderr.print("hash file already exists: {s}\nrefusing to overwrite; pass --force to replace all accounts\n", .{hpath});
            std.process.exit(2);
        } else |_| {}
    }

    const names = [_][]const u8{ "performer1", "performer2", "performer3", "performer4", "performer5" };
    var creds = std.ArrayList(u8).init(allocator);
    defer creds.deinit();
    try creds.appendSlice("# Melos performer credentials. Mode 600. Do not share or commit.\n");
    const ts = now();
    try creds.writer().print("# Generated: {d}\n# Format: username word-word-NNNN\n\n", .{ts});

    g.mutex.lock();
    g.n_users = 0;
    for (names) |name| {
        var pw_buf: [64]u8 = undefined;
        const pw = generatePassword(&pw_buf);
        var hbuf: [HASH_MAX]u8 = undefined;
        const h = hashPassword(pw, &hbuf) catch {
            g.mutex.unlock();
            try stderr.writeAll("failed to hash a password\n");
            std.process.exit(1);
        };
        addOrReplaceUserLocked(name, h) catch {
            g.mutex.unlock();
            try stderr.writeAll("failed to store account\n");
            std.process.exit(1);
        };
        try creds.writer().print("{s} {s}\n", .{ name, pw });
    }
    writeHashFile(hpath) catch |err| {
        g.mutex.unlock();
        try stderr.print("failed to write hash file: {}\n", .{err});
        std.process.exit(1);
    };
    g.mutex.unlock();

    writeInitialFile(ipath, creds.items, false) catch |err| {
        try stderr.print("hashes written but credentials file failed ({s}): {}\nrun reset for each account after fixing the path\n", .{ ipath, err });
        std.process.exit(1);
    };
    try stderr.print("initialized 5 performers; credentials written to {s}\n", .{ipath});
}

fn cmdList() !void {
    const hpath = std.posix.getenv("MELOS_PERFORMERS_FILE") orelse DEFAULT_HASH_PATH;
    loadFromPath(hpath) catch |err| {
        try std.io.getStdErr().writer().print("failed to load {s}: {}\n", .{ hpath, err });
        std.process.exit(1);
    };
    const out = std.io.getStdOut().writer();
    g.mutex.lock();
    defer g.mutex.unlock();
    if (g.n_users == 0) {
        try std.io.getStdErr().writer().print("no performer accounts in {s}\n", .{hpath});
        return;
    }
    var i: usize = 0;
    while (i < g.n_users) : (i += 1) {
        try out.print("{s}\n", .{g.users[i].name()});
    }
}

fn cmdReset(allocator: Allocator, username: []const u8) !void {
    const stderr = std.io.getStdErr().writer();
    if (!validUsername(username)) {
        try stderr.writeAll("invalid username\n");
        std.process.exit(2);
    }
    const hpath = std.posix.getenv("MELOS_PERFORMERS_FILE") orelse DEFAULT_HASH_PATH;
    const ipath = initialPath();
    loadFromPath(hpath) catch |err| {
        try stderr.print("failed to load {s}: {}\n", .{ hpath, err });
        std.process.exit(1);
    };

    g.mutex.lock();
    const exists = findUser(username) != null;
    g.mutex.unlock();
    if (!exists) {
        try stderr.print("unknown username: {s}\n", .{username});
        std.process.exit(2);
    }

    var pw_buf: [64]u8 = undefined;
    const pw = generatePassword(&pw_buf);
    var hbuf: [HASH_MAX]u8 = undefined;
    const h = hashPassword(pw, &hbuf) catch {
        try stderr.writeAll("failed to hash a password\n");
        std.process.exit(1);
    };

    var note = std.ArrayList(u8).init(allocator);
    defer note.deinit();
    try note.writer().print("# --- reset {d} {s} ---\n{s} {s}\n", .{ now(), username, username, pw });

    // Write the password to a sibling temp first so a later failure cannot lose it.
    var hold_buf: [1080]u8 = undefined;
    const hold = try std.fmt.bufPrint(&hold_buf, "{s}.reset-hold", .{ipath});
    writeInitialFile(hold, note.items, false) catch |err| {
        try stderr.print("failed to write hold file: {}\n", .{err});
        std.process.exit(1);
    };

    g.mutex.lock();
    addOrReplaceUserLocked(username, h) catch {
        g.mutex.unlock();
        try stderr.print("failed to update account; password hold is {s}\n", .{hold});
        std.process.exit(1);
    };
    dropSessionsFor(username, null);
    writeHashFile(hpath) catch |err| {
        g.mutex.unlock();
        try stderr.print("failed to write hash file ({s}); password hold is {s}\n", .{ @errorName(err), hold });
        std.process.exit(1);
    };
    g.mutex.unlock();

    writeInitialFile(ipath, note.items, true) catch |err| {
        try stderr.print("hash updated; append to {s} failed ({s}); password is in {s}\n", .{ ipath, @errorName(err), hold });
        std.process.exit(1);
    };
    std.fs.cwd().deleteFile(hold) catch {};
    try stderr.print("reset {s}; new password written to {s}\n", .{ username, ipath });
}

// ---------------------------------------------------------------------------
// HTTP helpers used by api.zig
// ---------------------------------------------------------------------------

pub const HttpOut = struct {
    status: u16,
    body: []u8,
    set_cookie: ?[]u8 = null,
};

pub fn jsonLogin(allocator: Allocator, auth: AuthInfo, body: []const u8) !HttpOut {
    const Body = struct { username: ?[]const u8 = null, password: ?[]const u8 = null };
    var scratch: [2 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const b = if (std.mem.trim(u8, body, " \r\n\t").len == 0)
        Body{}
    else
        std.json.parseFromSliceLeaky(Body, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
            return .{ .status = 400, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"invalid json\"}}", .{}), .set_cookie = null };
    const user = b.username orelse "";
    const pass = b.password orelse "";
    const r = login(allocator, auth, user, pass);
    if (r.status == 200) {
        const uname = r.username orelse user;
        return .{
            .status = 200,
            .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"username\":\"{s}\"}}", .{uname}),
            .set_cookie = r.cookie,
        };
    }
    if (r.cookie) |c| allocator.free(c);
    if (r.status == 429) {
        const ms = r.retry_after_ms orelse 30000;
        return .{
            .status = 429,
            .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\",\"retry_after_ms\":{d}}}", .{ r.error_msg orelse "too many attempts", ms }),
            .set_cookie = null,
        };
    }
    return .{
        .status = r.status,
        .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{r.error_msg orelse "invalid credentials"}),
        .set_cookie = null,
    };
}

pub fn jsonLogout(allocator: Allocator, auth: AuthInfo) !HttpOut {
    dropSessionByCookie(auth.cookie);
    const cookie = try setCookieHeader(allocator, null, 0);
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\"}}", .{}),
        .set_cookie = cookie,
    };
}

pub fn jsonMe(allocator: Allocator, auth: AuthInfo) !HttpOut {
    if (sessionUser(auth.cookie)) |u| {
        return .{
            .status = 200,
            .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"username\":\"{s}\"}}", .{u.slice()}),
            .set_cookie = null,
        };
    }
    return .{
        .status = 401,
        .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"sign in required\"}}", .{}),
        .set_cookie = null,
    };
}

pub fn jsonPassword(allocator: Allocator, auth: AuthInfo, body: []const u8) !HttpOut {
    const Body = struct {
        current: ?[]const u8 = null,
        current_password: ?[]const u8 = null,
        @"new": ?[]const u8 = null,
        new_password: ?[]const u8 = null,
    };
    var scratch: [4 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const b = std.json.parseFromSliceLeaky(Body, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
        return .{ .status = 400, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"invalid json\"}}", .{}), .set_cookie = null };
    const cur = b.current orelse b.current_password orelse "";
    const nw = b.@"new" orelse b.new_password orelse "";
    changePassword(allocator, auth, cur, nw) catch |err| switch (err) {
        error.Unauthorized => return .{ .status = 401, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"sign in required\"}}", .{}), .set_cookie = null },
        error.OriginDenied => return .{ .status = 403, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"origin not allowed\"}}", .{}), .set_cookie = null },
        error.InvalidCurrent => return .{ .status = 401, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"current password is incorrect\"}}", .{}), .set_cookie = null },
        error.WeakPassword => return .{ .status = 400, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"new password must be 8-72 characters\"}}", .{}), .set_cookie = null },
        error.Internal => return .{ .status = 500, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"could not update password\"}}", .{}), .set_cookie = null },
    };
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\"}}", .{}),
        .set_cookie = null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "origin allowlist is strict" {
    try testing.expect(originIsTrusted("https://www.fizz.beer"));
    try testing.expect(originIsTrusted("https://fizz.beer"));
    try testing.expect(originIsTrusted("http://127.0.0.1"));
    try testing.expect(originIsTrusted("http://127.0.0.1:8080"));
    try testing.expect(originIsTrusted("http://localhost:3000"));
    try testing.expect(!originIsTrusted("https://evil.example"));
    try testing.expect(!originIsTrusted("https://www.fizz.beer.evil"));
    try testing.expect(!originIsTrusted("https://www.fizz.beer/"));
    try testing.expect(!originIsTrusted("http://127.0.0.1:8080/path"));
    try testing.expect(!originIsTrusted(""));
    const loop = AuthInfo{ .peer_loopback = true };
    try testing.expect(originAllowed(loop));
    const remote = AuthInfo{ .peer_loopback = false };
    try testing.expect(!originAllowed(remote));
}

test "cookie parser and password generation shape" {
    try testing.expectEqualStrings("abcd", cookieValue("foo=1; melos_session=abcd; x=y", COOKIE_NAME).?);
    try testing.expect(cookieValue("x=y", COOKIE_NAME) == null);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var buf: [64]u8 = undefined;
        const pw = generatePassword(&buf);
        var parts = std.mem.splitScalar(u8, pw, '-');
        const a = parts.next().?;
        const b = parts.next().?;
        const c = parts.next().?;
        try testing.expect(parts.next() == null);
        try testing.expect(a.len >= 3 and b.len >= 3);
        try testing.expectEqual(@as(usize, 4), c.len);
        for (c) |ch| try testing.expect(ch >= '0' and ch <= '9');
    }
}

test "login, session, lockout, change password, logout" {
    resetStore();
    defer resetStore();
    // Use a unique temp dir so we never touch the VPS default path.
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/melos-perf-test-{d}", .{std.time.milliTimestamp()});
    std.fs.cwd().makePath(tmp) catch {};
    defer std.fs.cwd().deleteTree(tmp) catch {};
    var hpath_buf: [160]u8 = undefined;
    const hpath = try std.fmt.bufPrint(&hpath_buf, "{s}/performers.hashes", .{tmp});
    setPath(hpath);

    try testingAddPassword("performer1", "test-pass-0001");
    try persistForTest();

    const auth = AuthInfo{ .origin = "http://127.0.0.1:8080", .remote_ip = "127.0.0.1", .peer_loopback = true };
    const fail = login(testing.allocator, auth, "performer1", "wrong-password-99");
    try testing.expectEqual(@as(u16, 401), fail.status);
    try testing.expect(fail.cookie == null);

    const bad_origin = login(testing.allocator, .{ .origin = "https://evil.example", .remote_ip = "1.2.3.4" }, "performer1", "test-pass-0001");
    try testing.expectEqual(@as(u16, 403), bad_origin.status);

    const ok = login(testing.allocator, auth, "performer1", "test-pass-0001");
    defer if (ok.cookie) |c| testing.allocator.free(c);
    try testing.expectEqual(@as(u16, 200), ok.status);
    try testing.expect(ok.cookie != null);
    try testing.expect(std.mem.startsWith(u8, ok.cookie.?, "melos_session="));
    try testing.expect(std.mem.indexOf(u8, ok.cookie.?, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, ok.cookie.?, "SameSite=Strict") != null);

    // Build a Cookie header from the Set-Cookie value.
    const eq = std.mem.indexOfScalar(u8, ok.cookie.?, '=').?;
    const sc = std.mem.indexOfScalar(u8, ok.cookie.?, ';').?;
    var cookie_hdr_buf: [160]u8 = undefined;
    const cookie_hdr = try std.fmt.bufPrint(&cookie_hdr_buf, "{s}", .{ok.cookie.?[0..sc]});
    _ = eq;
    try testing.expect(sessionUser(cookie_hdr) != null);
    try testing.expectEqualStrings("performer1", sessionUser(cookie_hdr).?.slice());

    var authed = auth;
    authed.cookie = cookie_hdr;
    try changePassword(testing.allocator, authed, "test-pass-0001", "test-pass-0002");
    // Old password no longer works (new login).
    const stale = login(testing.allocator, auth, "performer1", "test-pass-0001");
    try testing.expectEqual(@as(u16, 401), stale.status);
    const again = login(testing.allocator, auth, "performer1", "test-pass-0002");
    defer if (again.cookie) |c| testing.allocator.free(c);
    try testing.expectEqual(@as(u16, 200), again.status);

    dropSessionByCookie(cookie_hdr);
    try testing.expect(sessionUser(cookie_hdr) == null);

    // Lockout: 5 failures then 429.
    var i: u32 = 0;
    while (i < FAIL_LIMIT) : (i += 1) {
        const r = login(testing.allocator, AuthInfo{ .origin = "http://127.0.0.1", .remote_ip = "9.9.9.9", .peer_loopback = true }, "performer1", "nope-nope-0000");
        try testing.expectEqual(@as(u16, 401), r.status);
    }
    const locked = login(testing.allocator, AuthInfo{ .origin = "http://127.0.0.1", .remote_ip = "9.9.9.9", .peer_loopback = true }, "performer1", "nope-nope-0000");
    try testing.expectEqual(@as(u16, 429), locked.status);
}

fn persistForTest() !void {
    g.mutex.lock();
    defer g.mutex.unlock();
    try persistLocked();
}

test "reload after external hash change on main thread" {
    resetStore();
    defer resetStore();
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/melos-reload-test-{d}", .{std.time.milliTimestamp()});
    std.fs.cwd().makePath(tmp) catch {};
    defer std.fs.cwd().deleteTree(tmp) catch {};
    var hpath_buf: [160]u8 = undefined;
    const hpath = try std.fmt.bufPrint(&hpath_buf, "{s}/performers.hashes", .{tmp});
    setPath(hpath);
    try testingAddPassword("performer2", "alpha-pass-0001");
    try persistForTest();

    var hbuf: [HASH_MAX]u8 = undefined;
    const h = try hashPassword("beta-pass-0002", &hbuf);
    var contents = std.ArrayList(u8).init(testing.allocator);
    defer contents.deinit();
    try contents.writer().print("performer2 {s}\n", .{h});
    {
        const f = try std.fs.cwd().createFile(hpath, .{ .truncate = true });
        defer f.close();
        try f.writeAll(contents.items);
    }

    const auth = AuthInfo{ .origin = "http://127.0.0.1", .remote_ip = "127.0.0.1", .peer_loopback = true };
    const stale = login(testing.allocator, auth, "performer2", "alpha-pass-0001");
    defer if (stale.cookie) |c| testing.allocator.free(c);
    try testing.expectEqual(@as(u16, 401), stale.status);
    const ok = login(testing.allocator, auth, "performer2", "beta-pass-0002");
    defer if (ok.cookie) |c| testing.allocator.free(c);
    try testing.expectEqual(@as(u16, 200), ok.status);
}
