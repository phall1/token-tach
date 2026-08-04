//! Immortal CFString cache for the macOS samplers.
//!
//! Every IOKit/CoreFoundation reading names its dictionary keys as strings,
//! and `CFStringCreateWithCString` allocates and copies on every call. The
//! samplers run on the poll cadence for days — a battery reading touches
//! nine keys, and rebuilding all nine 86,400 times a day is pure waste of a
//! value that never changes. The keys are fixed at compile time, so each is
//! built at most once and kept for the life of the process.
//!
//! WHY AN ENUM-INDEXED TABLE, AND NOT `cachedString(comptime literal)`:
//! the obvious shape is a generic taking the C string literal as a comptime
//! argument, with a function-local `var` for its cache slot. It does not
//! work. Generic instantiations are memoized on comptime argument VALUES,
//! and distinct `[*:0]const u8` literals do not reliably present as distinct
//! values, so two different keys can collapse into one instantiation and
//! share one slot — the second key silently hands back the first key's
//! string. Reading the write counter under the read key is exactly the kind
//! of bug that looks plausible on a dashboard and is never noticed. An enum
//! gives one slot per tag by construction, with no reliance on how the
//! compiler memoizes anything.
//!
//! OWNERSHIP — the single rule for every caller: the reference this cache
//! returns is deliberately NEVER released. Callers must never `CFRelease`
//! it, never attach a `defer` to it, and never hand it to something that
//! takes ownership. That is precisely what makes reuse safe: nothing else
//! holds a claim on the object, so it cannot be freed out from under the
//! next sample. The cost is a handful of small objects for the process
//! lifetime, which is the point of calling them immortal.

const std = @import("std");

const c = @cImport({
    // Neutralize Apple's _Static_asserts the same way the samplers do:
    // translate-c renders the bitfield structs they check as opaque, and
    // sizing an opaque type is a compile error.
    @cDefine("_Static_assert(c, m)", " ");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// A cache of immortal CFStrings, one slot per `Key` tag.
///
/// `Key` must be an exhaustive enum whose tags number 0..n-1 (the default
/// for a plain enum) and which exposes `fn literal(self: Key) [*:0]const u8`
/// naming the C string for each tag. `StringRef` is the caller's own
/// `c.CFStringRef` — each sampler has its own `@cImport`, and therefore its
/// own nominally distinct CFStringRef type, so the cache is generic over it
/// rather than forcing a cast at every call site.
///
/// Instantiate once per module and keep the handle:
///
///     const key_strings = cfcache.Cache(Key, c.CFStringRef);
///     const cachedString = key_strings.get;
///
/// Two modules that pass the same `Key` type share one cache, which is the
/// correct outcome — the keys are the same keys.
pub fn Cache(comptime Key: type, comptime StringRef: type) type {
    const info = switch (@typeInfo(Key)) {
        .@"enum" => |e| e,
        else => @compileError("cfcache.Cache needs an enum key, got " ++ @typeName(Key)),
    };
    comptime {
        if (!info.is_exhaustive)
            @compileError("cfcache.Cache needs an exhaustive enum: a `_` tag has no slot");
        // @intFromEnum indexes the table directly. A hand-numbered enum
        // would index out of bounds (or silently alias) instead.
        for (info.fields, 0..) |field, i| {
            if (field.value != i) @compileError(
                "cfcache.Cache needs default-numbered tags; " ++ @typeName(Key) ++ "." ++ field.name ++ " is not",
            );
        }
        if (!@hasDecl(Key, "literal"))
            @compileError(@typeName(Key) ++ " must declare `fn literal(self: @This()) [*:0]const u8`");
    }

    return struct {
        /// One immortal CFString per `Key`, 0 until first use.
        ///
        /// Relaxed atomics rather than plain vars: the app samples from a
        /// dedicated producer thread while the loop thread keeps a fallback
        /// sampler. The create is idempotent, so the worst a race can do is
        /// build one duplicate immortal string — never hand back a dangling
        /// one, and never hand back a half-published pointer.
        var slots: [info.fields.len]std.atomic.Value(usize) = @splat(.init(0));

        /// Real `CFStringCreateWithCString` calls made through this cache.
        /// One per distinct key for the life of the process; the samplers'
        /// tests assert it stops growing.
        var creates: std.atomic.Value(usize) = .init(0);

        /// The immortal CFString for `key`, or null if CoreFoundation
        /// refused to build it (it will be retried next call).
        ///
        /// NEVER `CFRelease` the result — see the module-level ownership
        /// rule.
        pub fn get(key: Key) StringRef {
            const slot = &slots[@intFromEnum(key)];
            const cached = slot.load(.monotonic);
            if (cached != 0) return @ptrFromInt(cached);

            const created = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key.literal(), c.kCFStringEncodingUTF8);
            if (created == null) return null;
            _ = creates.fetchAdd(1, .monotonic);
            slot.store(@intFromPtr(created), .monotonic);
            return @ptrCast(created);
        }

        /// How many CFStrings this cache has actually created. Bounded by
        /// the number of `Key` tags; the samplers assert it stops growing.
        pub fn createCount() usize {
            return creates.load(.monotonic);
        }
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Two independent key sets, to prove instantiations do not share slots —
/// the exact failure the enum-indexed design exists to rule out.
const AlphaKey = enum {
    one,
    two,

    fn literal(self: AlphaKey) [*:0]const u8 {
        return switch (self) {
            .one => "alpha-one",
            .two => "alpha-two",
        };
    }
};

const BetaKey = enum {
    one,

    fn literal(self: BetaKey) [*:0]const u8 {
        return switch (self) {
            // Deliberately the SAME literal AlphaKey.one names: if the
            // caches collapsed, this test could not tell them apart by
            // content, so it compares create counts instead.
            .one => "alpha-one",
        };
    }
};

const Alpha = Cache(AlphaKey, c.CFStringRef);
const Beta = Cache(BetaKey, c.CFStringRef);

test "each key gets its own string, created once and handed back forever" {
    var seen: [@typeInfo(AlphaKey).@"enum".fields.len]c.CFStringRef = undefined;
    for (std.enums.values(AlphaKey), 0..) |key, i| {
        seen[i] = Alpha.get(key) orelse return error.NoCfString;
        try testing.expect(c.CFStringGetLength(seen[i]) == @as(c.CFIndex, @intCast(std.mem.len(key.literal()))));
        for (seen[0..i]) |prior| try testing.expect(prior != seen[i]);
    }

    const after_priming = Alpha.createCount();
    for (0..1000) |_| {
        for (std.enums.values(AlphaKey), 0..) |key, i| {
            try testing.expectEqual(seen[i], Alpha.get(key) orelse return error.NoCfString);
        }
    }
    // A thousand more sweeps' worth of lookups, zero more allocations.
    try testing.expectEqual(after_priming, Alpha.createCount());
}

test "distinct key enums get distinct caches, not a shared slot" {
    _ = Alpha.get(.one) orelse return error.NoCfString;
    const alpha_before = Alpha.createCount();

    // Beta names the same literal. If the two instantiations shared a
    // table, Beta would hit Alpha's warm slot and create nothing.
    _ = Beta.get(.one) orelse return error.NoCfString;
    try testing.expectEqual(@as(usize, 1), Beta.createCount());
    try testing.expectEqual(alpha_before, Alpha.createCount());
}
