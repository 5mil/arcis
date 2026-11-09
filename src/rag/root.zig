//! root.zig — re-export for the "rag" named module

pub const Embedder = @import("embedder.zig").Embedder;
pub const VectorIndex = @import("index.zig").VectorIndex;
pub const SearchResult = @import("index.zig").SearchResult;
