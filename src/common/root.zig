//! root.zig — re-export for the "common" named module
//! Allows tests rooted in subdirectories to import shared types without relative path issues.

pub const EntityId = @import("id.zig").EntityId;
pub const EntityKind = @import("id.zig").EntityKind;
pub const IdSequence = @import("id.zig").IdSequence;
pub const makeUrn = @import("id.zig").makeUrn;
pub const URN_BUF_SIZE = @import("id.zig").URN_BUF_SIZE;
pub const URN_PREFIX = @import("id.zig").URN_PREFIX;

pub const Status = @import("schema.zig").Status;
pub const Concept = @import("schema.zig").Concept;
pub const Relation = @import("schema.zig").Relation;
pub const RelationKind = @import("schema.zig").RelationKind;
pub const TextRecord = @import("schema.zig").TextRecord;
pub const Annotation = @import("schema.zig").Annotation;
