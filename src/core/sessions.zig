//! Live agent-session roster — STUB, implementation in flight.
//!
//! Every collector already stamps `session_id` and `cwd` on every
//! `UsageEvent`, and `engine.ingest` drops both on the floor. This module
//! is where "which agents are running right now" comes from.

const std = @import("std");

test "sessions module is registered" {
    try std.testing.expect(true);
}
