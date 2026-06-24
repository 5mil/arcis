const std = @import("std");
const Retriever        = @import("retriever.zig").Retriever;
const RetrievedPassage = @import("retriever.zig").RetrievedPassage;
const Session          = @import("../infer/session.zig").Session;

/// RAG pipeline: retrieve relevant passages, build a grounded prompt,
/// run inference, return the answer.
pub const RAGPipeline = struct {
    retriever: *Retriever,
    session:   *Session,
    top_k:     usize,
    max_tokens: usize,
    allocator:  std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        retriever: *Retriever,
        session: *Session,
        top_k: usize,
        max_tokens: usize,
    ) RAGPipeline {
        return .{
            .retriever  = retriever,
            .session    = session,
            .top_k      = top_k,
            .max_tokens = max_tokens,
            .allocator  = allocator,
        };
    }

    /// Build a grounded prompt from retrieved passages.
    /// Caller owns returned slice.
    fn buildPrompt(
        self: *RAGPipeline,
        query: []const u8,
        passages: []const RetrievedPassage,
    ) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        try buf.appendSlice("### Context\n");
        for (passages, 1..) |p, i| {
            try buf.writer().print("[{d}] ({s} chunk {d}, score {d:.3})\n{s}\n\n",
                .{ i, p.source_id, p.chunk_idx, p.score, p.text });
        }
        try buf.appendSlice("### Question\n");
        try buf.appendSlice(query);
        try buf.appendSlice("\n\n### Answer\n");
        return buf.toOwnedSlice();
    }

    /// Run the full RAG cycle: retrieve → prompt → generate → return answer.
    /// Caller owns returned slice.
    pub fn query(
        self: *RAGPipeline,
        q: []const u8,
    ) ![]u8 {
        const passages = try self.retriever.retrieve(q, self.top_k);
        defer self.allocator.free(passages);

        const prompt = try self.buildPrompt(q, passages);
        defer self.allocator.free(prompt);

        const eos = [_]u32{ self.session.tokenizer.vocab.eos_id };
        return self.session.generate(prompt, self.max_tokens, &eos);
    }
};
