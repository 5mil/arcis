//! handlers.zig — Arcis route handler functions
//! Phase 13 — /infer, /rag, /search, /name, /workflow, /term, /health
//! Each handler receives a *Request and *ArcisSession, returns Response.

const std       = @import("std");
const Allocator = std.mem.Allocator;
const Request   = @import("server.zig").Request;
const Response  = @import("server.zig").Response;
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

pub fn handleHealth(allocator: Allocator, _: *Request, _: *ArcisSession) !Response {
    const body = try allocator.dupe(u8, "{\"status\":\"ok\"}");
    return Response{ .status = 200, .body = body, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Infer
// ---------------------------------------------------------------------------
// POST /infer   body: {"prompt": "...", "max_tokens": 128}

pub fn handleInfer(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.infer) return forbidden(allocator);
    // Parse prompt from JSON body (minimal scan).
    const prompt = jsonGetString(req.body, "prompt") orelse
        return badRequest(allocator, "missing prompt");
    _ = prompt;
    // Session.generate is stubbed — returns placeholder until real GGUF weights loaded.
    const out = try std.fmt.allocPrint(allocator,
        "{{\"result\":\"[inference stub: session.generate not yet wired to weight file]\"}}", .{});
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// RAG
// ---------------------------------------------------------------------------
// POST /rag   body: {"query": "..."}

pub fn handleRag(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.rag) return forbidden(allocator);
    const query = jsonGetString(req.body, "query") orelse
        return badRequest(allocator, "missing query");
    _ = query;
    const out = try allocator.dupe(u8, "{\"result\":\"[rag stub: embed+retrieve pipeline not yet wired to corpus]\"}" );
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------
// GET /search?q=<term>   (also accepts POST body {"q":"..."})

pub fn handleSearch(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    const q = jsonGetString(req.body, "q") orelse
        queryParam(req.path, "q") orelse
        return badRequest(allocator, "missing q");

    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit();
    session.search.keyword.search(q, &ids) catch {};

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("{\"results\":[");
    for (ids.items, 0..) |id, i| {
        if (i > 0) try buf.appendSlice(",");
        try std.fmt.format(buf.writer(), "{d}", .{id});
    }
    try buf.appendSlice("]}");
    return Response{ .status = 200, .body = try buf.toOwnedSlice(), .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Name generation
// ---------------------------------------------------------------------------
// POST /name   body: {"kind": "wizard", "tradition": "greek", "rank": "sage"}

pub fn handleName(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.naming) return forbidden(allocator);
    const kind_s = jsonGetString(req.body, "kind") orelse "wizard";
    const trad_s = jsonGetString(req.body, "tradition") orelse "greek";
    const rank_s = jsonGetString(req.body, "rank") orelse "adept";

    const NameKind  = @import("../naming/name_store.zig").NameKind;
    const Tradition = @import("../naming/rules.zig").Tradition;
    const Rank      = @import("../naming/rules.zig").Rank;

    const kind = std.meta.stringToEnum(NameKind,  kind_s) orelse .wizard;
    const trad = std.meta.stringToEnum(Tradition, trad_s) orelse .greek;
    const rank = std.meta.stringToEnum(Rank,      rank_s) orelse .adept;

    const seed: u64 = @intCast(std.time.milliTimestamp());
    const id   = try session.names.generateAndStore(kind, trad, rank, seed);
    const rec  = session.names.getById(id) orelse return internalError(allocator);

    const out = try std.fmt.allocPrint(allocator,
        "{{\"id\":{d},\"name\":\"{s}\",\"tradition\":\"{s}\",\"rank\":\"{s}\"}}",
        .{ id, rec.value, trad_s, rank_s },
    );
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Workflow
// ---------------------------------------------------------------------------
// POST /workflow/run   body: {"workflow_id": 1, "payload": "..."}

pub fn handleWorkflowRun(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.workflow) return forbidden(allocator);
    const wf_id_str = jsonGetString(req.body, "workflow_id") orelse
        return badRequest(allocator, "missing workflow_id");
    const wf_id = std.fmt.parseInt(u64, wf_id_str, 10) catch
        return badRequest(allocator, "invalid workflow_id");
    const text = jsonGetString(req.body, "payload") orelse "";
    const Payload = @import("../workflow/node.zig").Payload;
    const job_id = try session.workflow.runNow(wf_id, Payload{ .text = text });
    const job    = session.workflow.getJob(job_id) orelse return internalError(allocator);
    const out = try std.fmt.allocPrint(allocator,
        "{{\"job_id\":{d},\"status\":\"{s}\"}}",
        .{ job_id, @tagName(job.status) },
    );
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Terminology
// ---------------------------------------------------------------------------
// POST /term/propose   body: {"label": "...", "definition": "...", "domain": "..."}
// POST /term/validate  body: {"id": 1}

pub fn handleTermPropose(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.ontology) return forbidden(allocator);
    const label = jsonGetString(req.body, "label") orelse
        return badRequest(allocator, "missing label");
    const def    = jsonGetString(req.body, "definition") orelse "";
    const domain = jsonGetString(req.body, "domain") orelse "general";
    const id = try session.terms.propose(label, def, domain);
    const out = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"status\":\"proposed\"}}", .{id});
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

pub fn handleTermValidate(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    if (!session.tier.caps.ontology) return forbidden(allocator);
    const id_str = jsonGetString(req.body, "id") orelse
        return badRequest(allocator, "missing id");
    const id = std.fmt.parseInt(u64, id_str, 10) catch
        return badRequest(allocator, "invalid id");
    _ = session.terms.validate(id);
    const out = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"status\":\"validated\"}}", .{id});
    return Response{ .status = 200, .body = out, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn forbidden(allocator: Allocator) !Response {
    const body = try allocator.dupe(u8, "{\"error\":\"tier does not permit this capability\"}");
    return Response{ .status = 403, .body = body, .allocator = allocator };
}

fn badRequest(allocator: Allocator, msg: []const u8) !Response {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg});
    return Response{ .status = 400, .body = body, .allocator = allocator };
}

fn internalError(allocator: Allocator) !Response {
    const body = try allocator.dupe(u8, "{\"error\":\"internal error\"}");
    return Response{ .status = 500, .body = body, .allocator = allocator };
}

/// Minimal JSON string extractor: finds "key":"value" and returns value slice.
/// Not a full parser — sufficient for simple flat request bodies.
fn jsonGetString(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return body[val_start..end];
}

/// Extract ?key=value from a path string.
fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var params = std.mem.splitScalar(u8, path[q + 1..], '&');
    while (params.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.eql(u8, param[0..eq], key)) return param[eq + 1..];
    }
    return null;
}
