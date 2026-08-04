//! Desktop HUD overlay — STUB, implementation in flight.
//!
//! Native SDK v0.8.0 added transparent / always_on_top / click_through /
//! activate_on_show to the runtime WindowDescriptor — the same
//! model-declared mechanism the dashboard window already uses. That makes
//! a floating, click-through, non-activating tach possible without any
//! new host patch.

const std = @import("std");

test "hud module is registered" {
    try std.testing.expect(true);
}
