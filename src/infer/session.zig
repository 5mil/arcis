const std = @import("std");
const Tokenizer  = @import("tokenizer.zig").Tokenizer;
const KVCache    = @import("kvcache.zig").KVCache;
const transformer = @import("transformer.zig");
const sampler    = @import("sampler.zig");
const Config     = @import("../core/config.zig").Config;

/// Session state tracks a single inference context.
pub const Session = struct {
    tokenizer:   *Tokenizer,
    kvcache:     KVCache,
    weights:     *const transformer.TransformerWeights,
    cfg:         transformer.TransformerConfig,
    sampler_cfg: sampler.SamplerConfig,
    /// Token IDs generated so far in this session.
    context:     std.ArrayList(u32),
    allocator:   std.mem.Allocator,
    rng:         std.Random.DefaultPrng,

    pub fn init(
        allocator: std.mem.Allocator,
        tokenizer: *Tokenizer,
        weights: *const transformer.TransformerWeights,
        cfg: transformer.TransformerConfig,
        sampler_cfg: sampler.SamplerConfig,
        seed: u64,
    ) !Session {
        const kv = try KVCache.init(
            allocator,
            cfg.n_layers,
            cfg.embed_dim, // context_len placeholder; real value from model meta
            cfg.n_kv_heads,
            cfg.head_dim,
        );
        return .{
            .tokenizer   = tokenizer,
            .kvcache     = kv,
            .weights     = weights,
            .cfg         = cfg,
            .sampler_cfg = sampler_cfg,
            .context     = std.ArrayList(u32).init(allocator),
            .allocator   = allocator,
            .rng         = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Session) void {
        self.kvcache.deinit();
        self.context.deinit();
    }

    /// Reset session state for a new conversation turn.
    pub fn reset(self: *Session) void {
        self.kvcache.reset();
        self.context.clearRetainingCapacity();
    }

    /// Encode prompt, run inference loop, return generated text.
    /// max_tokens: maximum new tokens to generate.
    /// stop_ids: token IDs that terminate generation (e.g. EOS).
    /// Caller owns returned slice.
    pub fn generate(
        self: *Session,
        prompt: []const u8,
        max_tokens: usize,
        stop_ids: []const u32,
    ) ![]u8 {
        // Encode prompt.
        const prompt_ids = try self.tokenizer.encode(prompt, true);
        defer self.allocator.free(prompt_ids);

        // Prefill: run transformer over all prompt tokens.
        for (prompt_ids, 0..) |tok, pos| {
            const logits = try transformer.forward(
                tok, pos,
                self.weights, &self.kvcache, &self.cfg,
                self.allocator,
            );
            self.allocator.free(logits);
            try self.context.append(tok);
        }

        // Generation loop.
        var new_ids = std.ArrayList(u32).init(self.allocator);
        defer new_ids.deinit();

        var pos: usize = prompt_ids.len;
        var last_tok = prompt_ids[prompt_ids.len - 1];

        while (new_ids.items.len < max_tokens) {
            const logits = try transformer.forward(
                last_tok, pos,
                self.weights, &self.kvcache, &self.cfg,
                self.allocator,
            );
            defer self.allocator.free(logits);

            var rng = self.rng.random();
            const next = try sampler.nextToken(
                logits,
                self.context.items,
                self.sampler_cfg,
                &rng,
                self.allocator,
            );

            try self.context.append(next);
            try new_ids.append(next);

            // Check stop conditions.
            var stop = false;
            for (stop_ids) |sid| { if (next == sid) { stop = true; break; } }
            if (stop) break;

            last_tok = next;
            pos += 1;
        }

        return self.tokenizer.decode(new_ids.items, true);
    }
};
