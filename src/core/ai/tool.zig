//! App-facing declaration types for `verve.ai`. Types only — no logic, so
//! app code can name them without pulling in the schema/registry machinery.

/// How much damage a tool can do. The framework never infers this; the app
/// author declares it, and the policy gate enforces whatever they declared.
///
/// - `.safe`      — reads only, no observable side effects.
/// - `.mutating`  — changes app state. The default: opting *out* of caution
///                  should be a deliberate act, not an omission.
/// - `.dangerous` — destructive, irreversible, or outward-facing. Never runs
///                  without an explicit human confirmation round-trip.
pub const Risk = enum { safe, mutating, dangerous };

/// Per-field description. Zig has no comptime doc-comment reflection, so the
/// text a model reads has to be declared separately from the field itself.
pub const ArgDoc = struct {
    field: []const u8,
    description: []const u8,
};

/// One entry in an app's tool allowlist. Nothing is exposed to a model unless
/// it appears in a `[]const ToolDecl` somewhere.
pub const ToolDecl = struct {
    fn_name: []const u8,
    description: []const u8,
    risk: Risk = .mutating,
    arg_docs: []const ArgDoc = &.{},
};
