//! Null-tolerant field reads over a parsed `std.json.Value`.
//!
//! Every JSONL collector walks a vendor's object graph looking for a
//! handful of fields, and every one of them has to survive the same three
//! disappointments: the node is not an object, the key is absent, or the
//! value is the wrong type. Vendors rename and re-nest fields between
//! releases and a collector that returned an error for any of those would
//! stop counting tokens over a field it never needed.
//!
//! So the contract is uniform and total: **a shape mismatch reads exactly
//! like an absent field.** Nothing here errors, and nothing here allocates
//! — returned strings borrow the parse arena.
//!
//! This existed as the same three functions copied byte-for-byte into
//! pisrc, geminisrc, qwensrc and kimisrc, with two more partial copies
//! elsewhere. There is nothing collector-specific in any of them.
//!
//! ## Why `getU64` returns 0 and `getI64` returns null
//!
//! Token counters are the fields that read through `getU64`, and for a
//! counter "absent" and "zero" are the same claim — every call site would
//! otherwise write `orelse 0`. Timestamps and ids read through the
//! optional accessors, where 0 is a real value (the epoch, rowid 0) and
//! collapsing it into "missing" would invent data. Negative integers clamp
//! to 0 rather than wrapping: a vendor that logs -1 for "unknown" must not
//! become 18 quintillion tokens.

const std = @import("std");

/// The child at `key`, or null if `v` is not an object or has no such key.
pub fn getValue(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// The child at `key` only if it is itself an object.
///
/// Distinct from `getValue` on purpose: a caller that is about to descend
/// wants the type check, and one that is about to switch on the node does
/// not.
pub fn getObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    const child = getValue(v, key) orelse return null;
    if (child != .object) return null;
    return child;
}

pub fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const child = getValue(v, key) orelse return null;
    if (child != .string) return null;
    return child.string;
}

/// A non-negative integer counter; 0 for absent, non-integer or negative.
pub fn getU64(v: std.json.Value, key: []const u8) u64 {
    const child = getValue(v, key) orelse return 0;
    if (child != .integer) return 0;
    if (child.integer < 0) return 0;
    return @intCast(child.integer);
}

/// `getU64` for callers that must tell 0 from missing.
pub fn getU64Opt(v: std.json.Value, key: []const u8) ?u64 {
    const child = getValue(v, key) orelse return null;
    if (child != .integer) return null;
    if (child.integer < 0) return 0;
    return @intCast(child.integer);
}

pub fn getI64(v: std.json.Value, key: []const u8) ?i64 {
    const child = getValue(v, key) orelse return null;
    if (child != .integer) return null;
    return child.integer;
}

/// A number that may have been logged as either JSON form. Vendors are not
/// consistent about whether a whole-valued float keeps its decimal point.
pub fn getF64(v: std.json.Value, key: []const u8) ?f64 {
    const child = getValue(v, key) orelse return null;
    return switch (child) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

const testing = std.testing;

test "a shape mismatch reads exactly like an absent field" {
    const text =
        \\{"s": "hi", "n": 7, "neg": -1, "zero": 0, "f": 1.5, "fi": 2,
        \\ "obj": {"inner": "x"}, "arr": [1], "nul": null}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const v = parsed.value;

    try testing.expectEqualStrings("hi", getString(v, "s").?);
    try testing.expectEqual(@as(?[]const u8, null), getString(v, "n"));
    try testing.expectEqual(@as(?[]const u8, null), getString(v, "absent"));
    try testing.expectEqual(@as(?[]const u8, null), getString(v, "nul"));

    try testing.expectEqual(@as(u64, 7), getU64(v, "n"));
    try testing.expectEqual(@as(u64, 0), getU64(v, "absent"));
    try testing.expectEqual(@as(u64, 0), getU64(v, "s"));
    // A vendor's -1-for-unknown must not become 18 quintillion tokens.
    try testing.expectEqual(@as(u64, 0), getU64(v, "neg"));

    // The optional form is what tells a real 0 from a missing field.
    try testing.expectEqual(@as(?u64, 0), getU64Opt(v, "zero"));
    try testing.expectEqual(@as(?u64, null), getU64Opt(v, "absent"));

    try testing.expectEqual(@as(?i64, -1), getI64(v, "neg"));
    try testing.expectEqual(@as(?i64, null), getI64(v, "f"));

    try testing.expectEqual(@as(?f64, 1.5), getF64(v, "f"));
    // Whole-valued numbers arrive as either JSON form.
    try testing.expectEqual(@as(?f64, 2), getF64(v, "fi"));
    try testing.expectEqual(@as(?f64, null), getF64(v, "s"));

    // getObject type-checks where getValue does not.
    try testing.expect(getObject(v, "obj") != null);
    try testing.expectEqual(@as(?std.json.Value, null), getObject(v, "arr"));
    try testing.expect(getValue(v, "arr") != null);

    // A non-object root is not an error, just empty.
    const scalar = std.json.Value{ .integer = 1 };
    try testing.expectEqual(@as(?std.json.Value, null), getValue(scalar, "s"));
    try testing.expectEqual(@as(u64, 0), getU64(scalar, "s"));
}
