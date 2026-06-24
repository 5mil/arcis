//! diffusion.zig — DDPM/DDIM scheduler, UNet denoising loop, VAE latent decode
//! Phase 5 — src/media/
//! Depends on: src/infer/attention.zig, src/core/tensor.zig
//! Mirrors: src/infer/sampler.zig (step-wise stochastic process)

const std = @import("std");
const Allocator = std.mem.Allocator;
const attention = @import("../infer/attention.zig");

// ---------------------------------------------------------------------------
// Scheduler config
// ---------------------------------------------------------------------------

pub const DiffusionConfig = struct {
    n_steps:      usize = 20,     // DDIM inference steps
    beta_start:   f32   = 0.00085,
    beta_end:     f32   = 0.012,
    img_size:     usize = 512,
    latent_size:  usize = 64,     // img_size / 8 (VAE factor)
    latent_ch:    usize = 4,      // VAE latent channels
    unet_ch:      usize = 320,    // UNet base channels
    cross_attn_dim: usize = 768,  // CLIP text embedding dim
};

// ---------------------------------------------------------------------------
// Noise schedule
// ---------------------------------------------------------------------------

/// Precomputed DDPM cosine/linear beta schedule buffers.
pub const NoiseSchedule = struct {
    alphas_cumprod: []f32,   // [n_steps]
    allocator: Allocator,

    /// Build linear beta schedule and compute cumulative alphas.
    pub fn init(allocator: Allocator, cfg: DiffusionConfig) !NoiseSchedule {
        const T = cfg.n_steps;
        const ac = try allocator.alloc(f32, T);
        var alpha_prod: f32 = 1.0;
        for (0..T) |t| {
            const tf: f32 = @floatFromInt(t);
            const Tf: f32 = @floatFromInt(T);
            const beta = cfg.beta_start + (cfg.beta_end - cfg.beta_start) * tf / (Tf - 1.0);
            alpha_prod *= (1.0 - beta);
            ac[t] = alpha_prod;
        }
        return NoiseSchedule{ .alphas_cumprod = ac, .allocator = allocator };
    }

    pub fn deinit(self: *NoiseSchedule) void {
        self.allocator.free(self.alphas_cumprod);
    }

    /// DDIM step: predict x_{t-1} from x_t and predicted noise eps.
    pub fn ddimStep(self: NoiseSchedule, x_t: []f32, eps: []const f32, t: usize, t_prev: usize) void {
        const at  = self.alphas_cumprod[t];
        const at1 = self.alphas_cumprod[t_prev];
        for (x_t, eps) |*x, e| {
            // x0 prediction
            const x0_pred = (x.* - @sqrt(1.0 - at) * e) / @sqrt(at);
            // direction to x_t
            x.* = @sqrt(at1) * x0_pred + @sqrt(1.0 - at1) * e;
        }
    }
};

// ---------------------------------------------------------------------------
// UNet stub
// ---------------------------------------------------------------------------

/// UNet weights (stub — actual conv/attn layers populated by GGUF loader).
pub const UNetWeights = struct {
    down_blocks: [][]const f32,
    mid_block:   []const f32,
    up_blocks:   [][]const f32,
    time_embed:  []const f32,
    text_proj:   []const f32,
};

/// Predict noise from latent x_t, timestep t, and text conditioning.
/// Returns owned eps buffer [latent_size * latent_size * latent_ch]. Caller frees.
pub fn unetForward(
    allocator: Allocator,
    x_t: []const f32,
    t: usize,
    text_emb: []const f32,
    weights: *UNetWeights,
    cfg: DiffusionConfig,
) ![]f32 {
    const latent_len = cfg.latent_size * cfg.latent_size * cfg.latent_ch;
    const eps = try allocator.alloc(f32, latent_len);
    @memset(eps, 0);
    // TODO: time embedding sinusoidal encode t → project via time_embed
    // TODO: down blocks (ResNet + cross-attention with text_emb)
    // TODO: mid block
    // TODO: up blocks with skip connections
    _ = x_t; _ = t; _ = text_emb; _ = weights;
    return eps;
}

// ---------------------------------------------------------------------------
// VAE decoder stub
// ---------------------------------------------------------------------------

pub const VAEWeights = struct {
    decoder_blocks: [][]const f32,
    post_quant_conv: []const f32,
};

/// Decode latent [latent_size x latent_size x latent_ch] → pixels [img_size x img_size x 3].
/// Returns owned u8 RGB pixel buffer. Caller frees.
pub fn vaeDecodeLatent(
    allocator: Allocator,
    latent: []const f32,
    weights: *VAEWeights,
    cfg: DiffusionConfig,
) ![]u8 {
    const pixel_len = cfg.img_size * cfg.img_size * 3;
    const pixels = try allocator.alloc(u8, pixel_len);
    @memset(pixels, 128); // neutral grey placeholder
    // TODO: VAE decoder conv blocks
    _ = latent; _ = weights;
    return pixels;
}

// ---------------------------------------------------------------------------
// DiffusionSession — full text → image pipeline
// ---------------------------------------------------------------------------

pub const DiffusionSession = struct {
    config:    DiffusionConfig,
    schedule:  NoiseSchedule,
    unet:      *UNetWeights,
    vae:       *VAEWeights,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        config: DiffusionConfig,
        unet: *UNetWeights,
        vae: *VAEWeights,
    ) !DiffusionSession {
        const schedule = try NoiseSchedule.init(allocator, config);
        return DiffusionSession{
            .config = config, .schedule = schedule,
            .unet = unet, .vae = vae, .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiffusionSession) void {
        self.schedule.deinit();
    }

    /// Generate image pixels from a text embedding.
    /// text_emb: CLIP embedding [cross_attn_dim]. Returns owned []u8 RGB. Caller frees.
    pub fn generate(self: *DiffusionSession, text_emb: []const f32) ![]u8 {
        const cfg = self.config;
        const latent_len = cfg.latent_size * cfg.latent_size * cfg.latent_ch;

        // Sample initial Gaussian noise latent.
        var prng = std.rand.DefaultPrng.init(0);
        const rand = prng.random();
        const latent = try self.allocator.alloc(f32, latent_len);
        defer self.allocator.free(latent);
        for (latent) |*v| v.* = rand.floatNorm(f32);

        // DDIM reverse diffusion loop.
        var t = cfg.n_steps - 1;
        while (t > 0) : (t -= 1) {
            const eps = try unetForward(
                self.allocator, latent, t, text_emb, self.unet, cfg,
            );
            defer self.allocator.free(eps);
            self.schedule.ddimStep(latent, eps, t, t - 1);
        }

        return try vaeDecodeLatent(self.allocator, latent, self.vae, cfg);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NoiseSchedule init and deinit" {
    const allocator = std.testing.allocator;
    var sched = try NoiseSchedule.init(allocator, DiffusionConfig{});
    defer sched.deinit();
    try std.testing.expectEqual(@as(usize, 20), sched.alphas_cumprod.len);
    // Alpha should be strictly decreasing.
    try std.testing.expect(sched.alphas_cumprod[0] > sched.alphas_cumprod[19]);
}

test "DiffusionConfig defaults" {
    const cfg = DiffusionConfig{};
    try std.testing.expectEqual(@as(usize, 512), cfg.img_size);
    try std.testing.expectEqual(@as(usize, 64), cfg.latent_size);
}
