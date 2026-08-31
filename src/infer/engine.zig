//! engine.zig — High-level inference engine facade
//! Loads a GGUF model, builds weights + tokenizer + session, and exposes generate().

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader = @import("loader.zig");
const Model = @import("model.zig").Model;
const weights_mod = @import("weights.zig");
const transformer = @import("transformer.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Session = @import("session.zig").Session;
const sampler = @import("sampler.zig");

/// Owns everything needed for inference.
pub const InferenceEngine = struct {
    model:    Model,
    weights:  transformer.TransformerWeights,
    cfg:      transformer.TransformerConfig,
    tokenizer: Tokenizer,
    session:  ?Session,
    allocator: Allocator,
    loaded:   bool,

    pub fn initEmpty(allocator: Allocator) InferenceEngine {
        return .{
            .model     = undefined,
            .weights   = undefined,
            .cfg       = undefined,
            .tokenizer = Tokenizer.init(allocator),
            .session   = null,
            .allocator = allocator,
            .loaded    = false,
        };
    }

    /// Load a GGUF model from disk and prepare the inference session.
    pub fn load(self: *InferenceEngine, path: []const u8) !void {
        if (self.loaded) self.unload();

        self.model = try loader.loadModel(self.allocator, path);
        errdefer self.model.deinit();

        self.cfg = try weights_mod.configFromModel(&self.model);
        self.weights = try weights_mod.loadWeights(self.allocator, &self.model);
        errdefer weights_mod.freeWeights(self.allocator, &self.weights);

        // Best-effort tokenizer load from GGUF metadata
        self.tokenizer.loadFromGGUF(&self.model.gguf) catch |err| {
            std.log.warn("tokenizer load incomplete: {}", .{err});
        };

        const sampler_cfg = sampler.SamplerConfig{
            .temperature = 0.7,
            .top_p       = 0.9,
            .top_k       = 40,
        };

        self.session = try Session.init(
            self.allocator,
            &self.tokenizer,
            &self.weights,
            self.cfg,
            sampler_cfg,
            @intCast(std.time.milliTimestamp()),
        );

        self.loaded = true;
        std.log.info("model loaded: {s}  layers={d}  embed={d}  heads={d}",
            .{ self.model.meta.architecture, self.cfg.n_layers, self.cfg.embed_dim, self.cfg.n_heads });
    }

    pub fn unload(self: *InferenceEngine) void {
        if (!self.loaded) return;
        if (self.session) |*s| s.deinit();
        self.session = null;
        weights_mod.freeWeights(self.allocator, &self.weights);
        self.model.deinit();
        self.tokenizer.deinit();
        self.tokenizer = Tokenizer.init(self.allocator);
        self.loaded = false;
    }

    pub fn deinit(self: *InferenceEngine) void {
        self.unload();
        self.tokenizer.deinit();
    }

    /// Generate text. Returns owned slice. Model must be loaded.
    pub fn generate(
        self: *InferenceEngine,
        prompt: []const u8,
        max_tokens: usize,
    ) ![]u8 {
        if (!self.loaded or self.session == null) return error.ModelNotLoaded;

        var sess = &self.session.?;
        sess.reset();

        const eos = [_]u32{ self.tokenizer.vocab.eos_id };
        return sess.generate(prompt, max_tokens, &eos);
    }
};
