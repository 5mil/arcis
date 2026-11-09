//! root.zig — re-export for the "ontology" named module

pub const ConceptStore = @import("concept_store.zig").ConceptStore;
pub const TerminologyDirectory = @import("terminology.zig").TerminologyDirectory;
