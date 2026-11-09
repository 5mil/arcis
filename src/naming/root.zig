//! root.zig — re-export for the "naming" named module

pub const NameStore = @import("name_store.zig").NameStore;
pub const NameKind = @import("name_store.zig").NameKind;
pub const Tradition = @import("rules.zig").Tradition;
pub const Rank = @import("rules.zig").Rank;
pub const generateName = @import("rules.zig").generateName;
