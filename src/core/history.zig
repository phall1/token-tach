//! Durable append-only usage time series — STUB, implementation in flight.
//!
//! The statefile persists the IDENTITY of every event forever (dedup
//! keys) and the CONTENT of none finer than a calendar day. This module
//! is the durable store that makes "what did project X cost in June"
//! and "what was my burn rate at 3pm last Tuesday" answerable.

const std = @import("std");

test "history module is registered" {
    try std.testing.expect(true);
}
