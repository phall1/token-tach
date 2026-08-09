//! Live agent-session roster — "which of my agents is running right now".
//!
//! Every collector already stamps `session_id` and `cwd` on every
//! `UsageEvent`, and the ledger and burn gauge both drop them on the floor:
//! they answer "how many tokens" but never "who". This module keeps the
//! missing dimension — one row per live agent session, with its own token
//! counters, its own burn ring, and its own liveness state.
//!
//! Fixed capacity, no allocator, no failure mode. Like `predict.BurnRate`
//! it is a POD that can sit directly in the Model and be journaled and
//! replayed with it; a roster that could fail to allocate mid-sweep would
//! be a roster the tray has to render a "?" for.
//!
//! ## Liveness, and why file growth is the interesting signal
//!
//! A usage event is proof a turn FINISHED, not proof anything is running.
//! Claude Code writes user, tool_use and tool_result lines to its
//! transcript continuously while a turn is in flight and only appends the
//! assistant line (the one carrying the token counts) when the turn ends.
//! So a transcript that GREW but produced NO parsed event means an agent
//! is thinking or running tools at this instant — the one observation that
//! separates "an agent is working" from "an agent worked recently". The
//! roster models the two inputs separately and never conflates them:
//!
//! - `record` — a priced event landed: the turn COMPLETED. Clears
//!   `mid_turn`, bumps `last_event_ms`, counts a turn.
//! - `noteSessionGrowth` / `noteActivity` — bytes appeared with no event
//!   behind them: a turn is IN PROGRESS. Sets `mid_turn`, bumps
//!   `last_growth_ms`, counts no turn.
//!
//! Within one sweep a caller should report growth first and ingest events
//! second: a parsed event is the stronger, later observation and must win.
//! `mid_turn` is a stored flag rather than `last_growth_ms > last_event_ms`
//! on purpose — event timestamps come from the transcript's own clock and
//! routinely trail our wall clock by a second or two, so a derived
//! comparison would leave freshly-completed turns stuck reading "mid-turn".
//!
//! Nothing here reaps: `advanceTo` ages state and rolls rings but leaves
//! `.done` rows in their slots, so "what did that session cost" still has
//! an answer after the agent exits. Slots are recycled by eviction only.

const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const predict = @import("predict.zig");
const ring = @import("ring.zig");

/// Roster capacity. Nine concurrent agents on one machine is already an
/// unusual day; 32 leaves headroom for subagent fan-out without making the
/// Model expensive to journal.
pub const max_sessions: usize = 32;

/// Claude session ids and Codex rollout ids are UUIDs (36 bytes); 64 holds
/// those plus vendor prefixes. Longer ids are stored truncated and matched
/// on that prefix — two ids agreeing for 64 bytes would merge into one row,
/// which is strictly better than the alternative of allocating per session.
pub const session_id_cap: usize = 64;

/// Working directories are stored TAIL-first (see `Fixed.setSuffix`): a row
/// shows the basename, so losing the head of a deep path costs nothing and
/// losing the tail would cost everything.
pub const cwd_cap: usize = 160;

/// Model ids ("claude-fable-5-20260514", "gpt-5.2-codex") fit comfortably.
pub const model_cap: usize = 48;

/// Project names are directory basenames, not paths. Stored rather than
/// derived from `cwd` because `cwd` is truncated from the HEAD, and the
/// repository root a worktree rolls up to lives in exactly the part that
/// gets dropped.
pub const project_cap: usize = 64;

/// Per-session burn ring: 40 buckets x 15 s = a 10-minute window. Wide
/// enough that a row's sparkline shows the shape of a turn, short enough
/// that a finished session's rate decays to zero while it is still on
/// screen.
pub const burn_bucket_ms: i64 = 15_000;
pub const burn_buckets: usize = 40;

pub const Burn = ring.Accumulator(burn_buckets);

/// How a session reads to a human right now.
pub const Activity = enum {
    /// Working at this instant: a turn just completed, or one is in flight.
    running,
    /// Alive but between turns — usually waiting on the human.
    idle,
    /// Aged out. Kept for its history; a candidate for eviction.
    done,

    /// Lower is more alive. Used for display ordering and for rolling
    /// several sessions up into one agent verdict.
    pub fn rank(self: Activity) u8 {
        return switch (self) {
            .running => 0,
            .idle => 1,
            .done => 2,
        };
    }

    /// The livelier of two verdicts — an agent is running if ANY of its
    /// sessions is.
    pub fn liveliest(a: Activity, b: Activity) Activity {
        return if (b.rank() < a.rank()) b else a;
    }
};

/// A signal this recent means the session is mid-exchange. Two minutes is
/// deliberately much wider than any collector's poll interval: the gap
/// between an assistant message landing and the human's next prompt is
/// normally seconds, and a threshold near the poll period would make rows
/// flicker between running and idle on sweep jitter alone.
pub const running_within_ms: i64 = 2 * 60 * 1000;

/// How long "the file grew but no event came" keeps a row lit. A turn can
/// legitimately sit inside one tool call — a full build, a test suite, a
/// long web fetch — for many minutes without writing another line. Ten
/// minutes covers those; past it the far likelier explanation is that the
/// process died mid-turn, and a permanently-running phantom row is worse
/// than a row that goes quiet a little early.
pub const mid_turn_running_ms: i64 = 10 * 60 * 1000;

/// Retention horizon. After half an hour with no line and no growth the
/// session is over for display purposes, whether or not the process is
/// technically alive. Rows past this drop out of `live` and become the
/// preferred eviction victims.
pub const done_after_ms: i64 = 30 * 60 * 1000;

/// Fixed-width inline string. Two truncation policies, because which end
/// of a string carries its meaning depends on what the string is.
fn Fixed(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = @splat(0),
        len: u16 = 0,

        const Self = @This();
        pub const capacity = cap;

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eqlSlice(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }

        /// Keep the FIRST `cap` bytes — for identifiers and model names,
        /// where the leading bytes carry the identity.
        fn setPrefix(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = @intCast(n);
        }

        /// Keep the LAST `cap` bytes — for paths. Returns true when the
        /// head was dropped, so a UI can render the ellipsis.
        fn setSuffix(self: *Self, s: []const u8) bool {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[s.len - n ..]);
            self.len = @intCast(n);
            return n < s.len;
        }
    };
}

/// Trailing-slash-tolerant basename. A roster row wants "token-tach", not
/// "/Users/me/workspace/token-tach". Posix-only on purpose: these strings
/// come out of agent transcripts on macOS and Linux, and the Windows
/// splitter would mangle a path containing a backslash in a directory name.
///
/// `std.fs.path.basenamePosix` returns "" for "/" and for ""; a root cwd is
/// a real answer and an absent one is not, so the two are distinguished
/// here rather than both collapsing to the empty string.
pub fn projectName(path: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(path);
    if (base.len > 0) return base;
    return if (path.len > 0) "/" else "";
}

/// One agent session: identity, cumulative cost, and its own liveness.
pub const Session = struct {
    agent: types.Agent = .claude,
    id: Fixed(session_id_cap) = .{},
    cwd: Fixed(cwd_cap) = .{},
    /// The stored `cwd` lost its leading components to `cwd_cap`.
    cwd_head_truncated: bool = false,
    /// Basename of the repository root this session's `cwd` belongs to,
    /// stamped at ingest from `UsageEvent.projectKey()`. Empty for a
    /// collector that gave us no cwd at all.
    project_name: Fixed(project_cap) = .{},
    model: Fixed(model_cap) = .{},
    first_seen_ms: i64 = 0,
    /// Newest COMPLETED turn (a priced event).
    last_event_ms: i64 = 0,
    /// Newest transcript growth with no event behind it.
    last_growth_ms: i64 = 0,
    /// A turn is in flight: bytes arrived, the assistant line has not.
    mid_turn: bool = false,
    totals: ledger.Totals = .{},
    burn: Burn,

    /// Comptime-constructible blank, so a `Roster` can be `.{}` — the ring
    /// needs an explicit period and therefore cannot default itself.
    pub fn blank() Session {
        return .{ .burn = Burn.init(burn_bucket_ms) };
    }

    pub fn sessionId(self: *const Session) []const u8 {
        return self.id.slice();
    }

    pub fn cwdPath(self: *const Session) []const u8 {
        return self.cwd.slice();
    }

    pub fn modelName(self: *const Session) []const u8 {
        return self.model.slice();
    }

    /// The project label a row shows: the repository's name, so every
    /// worktree of one repo reads as that repo.
    ///
    /// Falls back to the basename of `cwd` for a session recorded before
    /// the resolved name existed — a journal replayed from an older
    /// build, or an event assembled without going through ingest.
    pub fn project(self: *const Session) []const u8 {
        const name = self.project_name.slice();
        if (name.len > 0) return name;
        return projectName(self.cwd.slice());
    }

    /// COMPLETED turns. One priced event is one turn by construction
    /// (claude: one assistant message, codex: one rollout turn), so this
    /// is `totals.events` under the name the product uses. A turn in
    /// flight is deliberately not counted until it lands.
    pub fn turns(self: *const Session) u64 {
        return self.totals.events;
    }

    /// Newest signal of any kind. Drives ordering, ageing and eviction.
    pub fn lastActivityMs(self: *const Session) i64 {
        return @max(self.last_event_ms, self.last_growth_ms);
    }

    /// Limit-weighted tokens/min over the ring window. Decays only when
    /// the roster is advanced, so callers must `advanceTo` each sweep.
    pub fn tokensPerMin(self: *const Session) f64 {
        return self.burn.perMinute();
    }

    /// Ring window oldest-first into `out` (newest last) — a row sparkline.
    pub fn sparkline(self: *const Session, out: []u64) []u64 {
        return self.burn.snapshot(out);
    }

    /// The state machine. `running` wins two different ways — a very
    /// recent signal of any kind, or an unfinished turn whose growth has
    /// stalled inside a long tool call.
    pub fn activityAt(self: *const Session, now_ms: i64) Activity {
        const last = self.lastActivityMs();
        if (last == 0) return .done;
        const age = now_ms - last;
        if (age > done_after_ms) return .done;
        if (age <= running_within_ms) return .running;
        if (self.mid_turn and now_ms - self.last_growth_ms <= mid_turn_running_ms) return .running;
        return .idle;
    }

    pub fn isRunning(self: *const Session, now_ms: i64) bool {
        return self.activityAt(now_ms) == .running;
    }

    fn matches(self: *const Session, agent: types.Agent, id: []const u8) bool {
        return self.agent == agent and self.id.eqlSlice(truncateId(id));
    }

    fn reset(self: *Session, agent: types.Agent, id: []const u8, now_ms: i64) void {
        self.* = Session.blank();
        self.agent = agent;
        self.id.setPrefix(id);
        self.first_seen_ms = now_ms;
    }
};

/// Store-side view of an id: everything past `session_id_cap` is dropped,
/// and lookups apply the same rule so a truncated row still matches the
/// next event from the same session.
fn truncateId(id: []const u8) []const u8 {
    return id[0..@min(id.len, session_id_cap)];
}

/// Per-agent rollup — "who is burning", which `Model.burn` cannot answer
/// because it blends all agents into one number.
pub const AgentView = struct {
    activity: Activity = .done,
    /// Rows held for this agent, including `.done` ones.
    sessions: usize = 0,
    /// Rows currently `.running`.
    active_sessions: usize = 0,
    /// Sum of the per-session burn rings.
    tokens_per_min: f64 = 0,
    /// Newest signal across this agent's sessions and its agent-level
    /// growth marker.
    last_activity_ms: i64 = 0,
    totals: ledger.Totals = .{},
};

pub const Roster = struct {
    sessions: [max_sessions]Session = @splat(Session.blank()),
    len: usize = 0,
    /// Growth reported for an agent whose session we could not name (see
    /// `noteActivity`). Kept per agent so such an agent still lights up
    /// even with zero rows in the roster.
    agent_growth_ms: std.EnumArray(types.Agent, i64) = .initFill(0),

    pub fn count(self: *const Roster) usize {
        return self.len;
    }

    /// A priced event landed: the turn COMPLETED. Creates the row if this
    /// is the session's first event.
    ///
    /// A blank `session_id` is a legitimate key, not a reason to skip:
    /// several collectors cannot name a session, and folding all of an
    /// agent's anonymous events into one row keeps that agent visible
    /// instead of invisible.
    pub fn record(self: *Roster, ev: types.UsageEvent, cost_usd: ?f64) void {
        const s = self.slotFor(ev.agent, ev.session_id, ev.timestamp_ms);
        if (ev.cwd.len > 0) s.cwd_head_truncated = s.cwd.setSuffix(ev.cwd);
        // Stamped from the full, untruncated key, which is why the label
        // survives a deep path: `projectKey()` is the repository root and
        // `cwd` above may have already lost its head.
        const project_key = ev.projectKey();
        if (project_key.len > 0) s.project_name.setPrefix(projectName(project_key));
        if (ev.model.len > 0) s.model.setPrefix(ev.model);
        s.totals.add(ev, cost_usd);
        s.burn.add(ev.timestamp_ms, predict.limitWeightedTokens(ev));
        if (ev.timestamp_ms > s.last_event_ms) s.last_event_ms = ev.timestamp_ms;
        // The turn is over. This is the ACTIVE-vs-IDLE discriminator's
        // other half: growth said "in flight", an event says "landed".
        s.mid_turn = false;
    }

    /// Transcript bytes appeared for a NAMED session with no event behind
    /// them: that session is mid-turn right now.
    pub fn noteSessionGrowth(self: *Roster, agent: types.Agent, session_id: []const u8, now_ms: i64) void {
        const s = self.slotFor(agent, session_id, now_ms);
        if (now_ms > s.last_growth_ms) s.last_growth_ms = now_ms;
        s.mid_turn = true;
        self.bumpAgent(agent, now_ms);
    }

    /// Growth for an agent we could not attribute to a session — the
    /// caller only knows "one of agent X's files grew this tick".
    ///
    /// It lights the agent, and additionally lights that agent's
    /// most-recently-active row. Lighting every row would resurrect
    /// sessions that ended days ago; lighting none would leave a working
    /// agent with a roster full of idle rows. The newest row is the only
    /// defensible guess, and it is right whenever the agent has exactly
    /// one session in flight — the common case.
    pub fn noteActivity(self: *Roster, agent: types.Agent, now_ms: i64) void {
        self.bumpAgent(agent, now_ms);
        var newest: ?*Session = null;
        for (self.sessions[0..self.len]) |*s| {
            if (s.agent != agent) continue;
            if (newest == null or s.lastActivityMs() > newest.?.lastActivityMs()) newest = s;
        }
        if (newest) |s| {
            if (now_ms > s.last_growth_ms) s.last_growth_ms = now_ms;
            s.mid_turn = true;
        }
    }

    fn bumpAgent(self: *Roster, agent: types.Agent, now_ms: i64) void {
        const slot = self.agent_growth_ms.getPtr(agent);
        if (now_ms > slot.*) slot.* = now_ms;
    }

    /// Roll every session's ring forward to `now_ms` so idle sessions'
    /// rates decay instead of pinning at their last burst. States are
    /// derived from `now_ms` on read, so nothing else has to age here —
    /// and `.done` rows are deliberately left in place (their history is
    /// still worth reading; eviction, not time, frees a slot).
    pub fn advanceTo(self: *Roster, now_ms: i64) void {
        for (self.sessions[0..self.len]) |*s| s.burn.advanceTo(now_ms);
    }

    pub fn find(self: *const Roster, agent: types.Agent, session_id: []const u8) ?*const Session {
        for (self.sessions[0..self.len]) |*s| {
            if (s.matches(agent, session_id)) return s;
        }
        return null;
    }

    /// Fleet verdict: the liveliest session anywhere, plus any agent-level
    /// growth that has no row yet.
    pub fn activity(self: *const Roster, now_ms: i64) Activity {
        var best: Activity = .done;
        for (self.sessions[0..self.len]) |*s| {
            best = best.liveliest(s.activityAt(now_ms));
        }
        for (std.enums.values(types.Agent)) |agent| {
            best = best.liveliest(growthActivity(self.agent_growth_ms.get(agent), now_ms));
        }
        return best;
    }

    pub fn activeCount(self: *const Roster, now_ms: i64) usize {
        var n: usize = 0;
        for (self.sessions[0..self.len]) |*s| {
            if (s.activityAt(now_ms) == .running) n += 1;
        }
        return n;
    }

    /// Non-`.done` sessions, ordered for display, into caller memory.
    /// Returns the populated prefix of `out`; give it `max_sessions`
    /// entries to be sure nothing is dropped.
    pub fn live(self: *const Roster, out: []*const Session, now_ms: i64) []*const Session {
        return self.collect(out, now_ms, null);
    }

    /// `live`, restricted to one agent.
    pub fn forAgent(self: *const Roster, agent: types.Agent, out: []*const Session, now_ms: i64) []*const Session {
        return self.collect(out, now_ms, agent);
    }

    fn collect(self: *const Roster, out: []*const Session, now_ms: i64, only: ?types.Agent) []*const Session {
        var n: usize = 0;
        for (self.sessions[0..self.len]) |*s| {
            if (n == out.len) break;
            if (only) |a| if (s.agent != a) continue;
            if (s.activityAt(now_ms) == .done) continue;
            out[n] = s;
            n += 1;
        }
        sortForDisplay(out[0..n], now_ms);
        return out[0..n];
    }

    /// Running first, then hottest, then most recent. Insertion sort:
    /// stable (equal rows keep roster order, so a redraw never shuffles
    /// them) and allocation-free, which matters more than asymptotics at
    /// `max_sessions` = 32.
    fn sortForDisplay(items: []*const Session, now_ms: i64) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const item = items[i];
            var j = i;
            while (j > 0 and displayLess(item, items[j - 1], now_ms)) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = item;
        }
    }

    fn displayLess(a: *const Session, b: *const Session, now_ms: i64) bool {
        const ra = a.activityAt(now_ms).rank();
        const rb = b.activityAt(now_ms).rank();
        if (ra != rb) return ra < rb;
        const ba = a.tokensPerMin();
        const bb = b.tokensPerMin();
        if (ba != bb) return ba > bb;
        return a.lastActivityMs() > b.lastActivityMs();
    }

    pub fn agentActivity(self: *const Roster, agent: types.Agent, now_ms: i64) Activity {
        var best = growthActivity(self.agent_growth_ms.get(agent), now_ms);
        for (self.sessions[0..self.len]) |*s| {
            if (s.agent != agent) continue;
            best = best.liveliest(s.activityAt(now_ms));
        }
        return best;
    }

    /// Per-agent rollup for the popover: who is burning, how many of them,
    /// and how long since each last did anything.
    pub fn byAgent(self: *const Roster, now_ms: i64) std.EnumArray(types.Agent, AgentView) {
        var out: std.EnumArray(types.Agent, AgentView) = .initFill(.{});
        for (self.sessions[0..self.len]) |*s| {
            const view = out.getPtr(s.agent);
            const state = s.activityAt(now_ms);
            view.sessions += 1;
            if (state == .running) view.active_sessions += 1;
            view.tokens_per_min += s.tokensPerMin();
            view.last_activity_ms = @max(view.last_activity_ms, s.lastActivityMs());
            view.activity = view.activity.liveliest(state);
            view.totals.input_tokens += s.totals.input_tokens;
            view.totals.output_tokens += s.totals.output_tokens;
            view.totals.cache_creation_tokens += s.totals.cache_creation_tokens;
            view.totals.cache_read_tokens += s.totals.cache_read_tokens;
            view.totals.cost_usd += s.totals.cost_usd;
            view.totals.events += s.totals.events;
        }
        for (std.enums.values(types.Agent)) |agent| {
            const growth = self.agent_growth_ms.get(agent);
            const view = out.getPtr(agent);
            view.last_activity_ms = @max(view.last_activity_ms, growth);
            view.activity = view.activity.liveliest(growthActivity(growth, now_ms));
        }
        return out;
    }

    /// Existing row, a free slot, or the least-recently-active row
    /// recycled. Eviction takes the oldest signal (ties break to the lower
    /// index, so replay is deterministic) — the row least likely to be
    /// looked at, and usually one that is already `.done`.
    fn slotFor(self: *Roster, agent: types.Agent, session_id: []const u8, now_ms: i64) *Session {
        for (self.sessions[0..self.len]) |*s| {
            if (s.matches(agent, session_id)) return s;
        }
        if (self.len < max_sessions) {
            const s = &self.sessions[self.len];
            self.len += 1;
            s.reset(agent, session_id, now_ms);
            return s;
        }
        var victim: usize = 0;
        for (self.sessions[0..self.len], 0..) |*s, i| {
            if (s.lastActivityMs() < self.sessions[victim].lastActivityMs()) victim = i;
        }
        const s = &self.sessions[victim];
        s.reset(agent, session_id, now_ms);
        return s;
    }
};

/// Verdict from an agent-level growth marker alone. Growth without an
/// event IS a turn in flight, so the mid-turn horizon applies directly
/// rather than the tighter event-recency one.
fn growthActivity(growth_ms: i64, now_ms: i64) Activity {
    if (growth_ms == 0) return .done;
    const age = now_ms - growth_ms;
    if (age > done_after_ms) return .done;
    if (age <= mid_turn_running_ms) return .running;
    return .idle;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const minute: i64 = 60_000;
const t0: i64 = 1_700_000_000_000;

fn mkEv(agent: types.Agent, ts: i64, id: []const u8, out: u64) types.UsageEvent {
    return .{
        .agent = agent,
        .timestamp_ms = ts,
        .model = "claude-fable-5",
        .output_tokens = out,
        .session_id = id,
        .cwd = "/Users/me/workspace/token-tach",
    };
}

test "record creates a row carrying identity, totals and burn" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "sess-a", 1000), 0.25);

    try testing.expectEqual(@as(usize, 1), roster.count());
    const s = roster.find(.claude, "sess-a").?;
    try testing.expectEqualStrings("sess-a", s.sessionId());
    try testing.expectEqualStrings("/Users/me/workspace/token-tach", s.cwdPath());
    try testing.expectEqualStrings("token-tach", s.project());
    try testing.expectEqualStrings("claude-fable-5", s.modelName());
    try testing.expectEqual(@as(u64, 1), s.turns());
    try testing.expectEqual(@as(u64, 1000), s.totals.totalTokens());
    try testing.expectApproxEqAbs(@as(f64, 0.25), s.totals.cost_usd, 1e-12);
    try testing.expectEqual(t0, s.first_seen_ms);
    try testing.expectEqual(t0, s.last_event_ms);
    try testing.expect(s.tokensPerMin() > 0);
}

test "a session walks running -> idle -> done as the clock advances" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "sess-a", 500), null);

    try testing.expectEqual(Activity.running, roster.agentActivity(.claude, t0 + 30_000));
    try testing.expectEqual(@as(usize, 1), roster.activeCount(t0 + 30_000));

    // Past event recency but inside retention.
    try testing.expectEqual(Activity.idle, roster.agentActivity(.claude, t0 + 5 * minute));
    try testing.expectEqual(@as(usize, 0), roster.activeCount(t0 + 5 * minute));

    // Past the retention horizon.
    try testing.expectEqual(Activity.done, roster.agentActivity(.claude, t0 + 45 * minute));
    try testing.expectEqual(Activity.done, roster.activity(t0 + 45 * minute));

    // Done rows leave the display but keep their history.
    var buf: [max_sessions]*const Session = undefined;
    try testing.expectEqual(@as(usize, 0), roster.live(&buf, t0 + 45 * minute).len);
    try testing.expectEqual(@as(u64, 500), roster.find(.claude, "sess-a").?.totals.totalTokens());
}

test "growth without an event marks the session running mid-turn" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "sess-a", 500), null);

    // Long past event recency: recency alone would say idle.
    const later = t0 + 8 * minute;
    try testing.expectEqual(Activity.idle, roster.agentActivity(.claude, later));

    roster.noteSessionGrowth(.claude, "sess-a", later);
    const s = roster.find(.claude, "sess-a").?;
    try testing.expect(s.mid_turn);
    try testing.expectEqual(Activity.running, s.activityAt(later));
    // Still running deep into a stalled tool call...
    try testing.expectEqual(Activity.running, s.activityAt(later + 9 * minute));
    // ...but not forever.
    try testing.expectEqual(Activity.idle, s.activityAt(later + 12 * minute));
    // No turn was counted: nothing landed.
    try testing.expectEqual(@as(u64, 1), s.turns());
}

test "an event completes the turn and clears mid-turn" {
    var roster = Roster{};
    roster.noteSessionGrowth(.claude, "sess-a", t0);
    try testing.expect(roster.find(.claude, "sess-a").?.mid_turn);
    try testing.expectEqual(@as(u64, 0), roster.find(.claude, "sess-a").?.turns());

    // Transcript clocks trail our wall clock; an event stamped BEFORE the
    // growth tick must still close the turn.
    roster.record(mkEv(.claude, t0 - 2_000, "sess-a", 100), null);
    const s = roster.find(.claude, "sess-a").?;
    try testing.expect(!s.mid_turn);
    try testing.expectEqual(@as(u64, 1), s.turns());
    try testing.expectEqual(t0, s.lastActivityMs());
}

test "growth for an unnamed session lights the agent anyway" {
    var roster = Roster{};
    roster.noteActivity(.codex, t0);
    try testing.expectEqual(Activity.running, roster.agentActivity(.codex, t0 + minute));
    try testing.expectEqual(Activity.running, roster.activity(t0 + minute));
    // Other agents stay dark.
    try testing.expectEqual(Activity.done, roster.agentActivity(.claude, t0 + minute));

    // With a row present, the newest row is the one that lights.
    roster.record(mkEv(.codex, t0, "old", 10), null);
    roster.record(mkEv(.codex, t0 + minute, "new", 10), null);
    roster.noteActivity(.codex, t0 + 9 * minute);
    try testing.expect(roster.find(.codex, "new").?.mid_turn);
    try testing.expect(!roster.find(.codex, "old").?.mid_turn);
}

test "eviction at capacity recycles the least-recently-active row" {
    var roster = Roster{};
    var buf: [8]u8 = undefined;
    for (0..max_sessions) |i| {
        const id = std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable;
        // s0 is the oldest, s31 the newest.
        roster.record(mkEv(.claude, t0 + @as(i64, @intCast(i)) * 1000, id, 10), null);
    }
    try testing.expectEqual(max_sessions, roster.count());
    try testing.expect(roster.find(.claude, "s0") != null);

    roster.record(mkEv(.claude, t0 + 999_000, "fresh", 10), null);
    try testing.expectEqual(max_sessions, roster.count());
    try testing.expectEqual(@as(?*const Session, null), roster.find(.claude, "s0"));
    try testing.expect(roster.find(.claude, "s1") != null);
    try testing.expect(roster.find(.claude, "fresh") != null);

    // The recycled slot carries none of the evicted session's history.
    const fresh = roster.find(.claude, "fresh").?;
    try testing.expectEqual(@as(u64, 1), fresh.turns());
    try testing.expectEqual(t0 + 999_000, fresh.first_seen_ms);
}

test "display ordering puts running first, then hottest, then newest" {
    var roster = Roster{};
    // Idle but enormous.
    roster.record(mkEv(.claude, t0, "idle-big", 100_000), null);
    // Running, small.
    roster.record(mkEv(.codex, t0 + 4 * minute, "run-small", 10), null);
    // Running, large.
    roster.record(mkEv(.opencode, t0 + 4 * minute, "run-big", 5_000), null);

    const now = t0 + 5 * minute;
    roster.advanceTo(now);
    var buf: [max_sessions]*const Session = undefined;
    const rows = roster.live(&buf, now);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("run-big", rows[0].sessionId());
    try testing.expectEqualStrings("run-small", rows[1].sessionId());
    try testing.expectEqualStrings("idle-big", rows[2].sessionId());
    try testing.expectEqual(Activity.running, rows[0].activityAt(now));
    try testing.expectEqual(Activity.idle, rows[2].activityAt(now));

    // forAgent filters to one agent's rows.
    const only = roster.forAgent(.codex, &buf, now);
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("run-small", only[0].sessionId());
}

test "per-agent rollup sums across sessions" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "a", 1000), 0.10);
    roster.record(mkEv(.claude, t0 + 1000, "b", 2000), 0.20);
    roster.record(mkEv(.claude, t0 + 2000, "a", 500), 0.05);
    roster.record(mkEv(.codex, t0, "c", 700), 0.01);

    const now = t0 + 30_000;
    roster.advanceTo(now);
    const views = roster.byAgent(now);

    const claude = views.get(.claude);
    try testing.expectEqual(@as(usize, 2), claude.sessions);
    try testing.expectEqual(@as(usize, 2), claude.active_sessions);
    try testing.expectEqual(@as(u64, 3), claude.totals.events);
    try testing.expectEqual(@as(u64, 3500), claude.totals.totalTokens());
    try testing.expectApproxEqAbs(@as(f64, 0.35), claude.totals.cost_usd, 1e-12);
    try testing.expectEqual(Activity.running, claude.activity);
    try testing.expectEqual(t0 + 2000, claude.last_activity_ms);
    // The two rows' rates sum to the agent's rate.
    const a = roster.find(.claude, "a").?.tokensPerMin();
    const b = roster.find(.claude, "b").?.tokensPerMin();
    try testing.expectApproxEqAbs(a + b, claude.tokens_per_min, 1e-9);

    try testing.expectEqual(@as(usize, 1), views.get(.codex).sessions);
    // An agent with no sessions rolls up empty, not garbage.
    const goose = views.get(.goose);
    try testing.expectEqual(@as(usize, 0), goose.sessions);
    try testing.expectEqual(Activity.done, goose.activity);
    try testing.expectEqual(@as(f64, 0), goose.tokens_per_min);
}

test "project basename handles trailing slashes and bare root" {
    try testing.expectEqualStrings("token-tach", projectName("/Users/me/workspace/token-tach"));
    try testing.expectEqualStrings("token-tach", projectName("/Users/me/workspace/token-tach/"));
    try testing.expectEqualStrings("token-tach", projectName("/Users/me/workspace/token-tach///"));
    try testing.expectEqualStrings("/", projectName("/"));
    try testing.expectEqualStrings("/", projectName("////"));
    try testing.expectEqualStrings("", projectName(""));
    try testing.expectEqualStrings("rel", projectName("rel"));
}

test "an over-long session id truncates but still matches itself" {
    var roster = Roster{};
    const long = "z" ** (session_id_cap + 40);
    roster.record(mkEv(.claude, t0, long, 100), null);
    try testing.expectEqual(@as(usize, 1), roster.count());
    try testing.expectEqual(@as(usize, session_id_cap), roster.find(.claude, long).?.sessionId().len);

    // The next event from the same session lands on the same row.
    roster.record(mkEv(.claude, t0 + 1000, long, 100), null);
    try testing.expectEqual(@as(usize, 1), roster.count());
    try testing.expectEqual(@as(u64, 2), roster.find(.claude, long).?.turns());
}

test "an over-long cwd keeps its tail so the basename survives" {
    var roster = Roster{};
    var ev = mkEv(.claude, t0, "a", 10);
    const deep = "/Users/me/" ++ ("nested/" ** 40) ++ "token-tach";
    ev.cwd = deep;
    roster.record(ev, null);

    const s = roster.find(.claude, "a").?;
    try testing.expect(s.cwd_head_truncated);
    try testing.expectEqual(@as(usize, cwd_cap), s.cwdPath().len);
    try testing.expectEqualStrings("token-tach", s.project());
}

test "the same session id under two agents stays two rows" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "shared", 10), null);
    roster.record(mkEv(.codex, t0, "shared", 20), null);
    try testing.expectEqual(@as(usize, 2), roster.count());
    try testing.expectEqual(@as(u64, 10), roster.find(.claude, "shared").?.totals.totalTokens());
    try testing.expectEqual(@as(u64, 20), roster.find(.codex, "shared").?.totals.totalTokens());
}

test "anonymous events fold into one row per agent" {
    var roster = Roster{};
    roster.record(mkEv(.kimi, t0, "", 10), null);
    roster.record(mkEv(.kimi, t0 + 1000, "", 15), null);
    try testing.expectEqual(@as(usize, 1), roster.count());
    const s = roster.find(.kimi, "").?;
    try testing.expectEqual(@as(u64, 2), s.turns());
    try testing.expectEqual(@as(u64, 25), s.totals.totalTokens());
}

test "advanceTo drains an idle session's rate without dropping its totals" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "a", 10_000), null);
    try testing.expect(roster.find(.claude, "a").?.tokensPerMin() > 0);

    roster.advanceTo(t0 + 60 * minute);
    const s = roster.find(.claude, "a").?;
    try testing.expectEqual(@as(f64, 0), s.tokensPerMin());
    try testing.expectEqual(@as(u64, 10_000), s.totals.totalTokens());
    try testing.expectEqual(Activity.done, s.activityAt(t0 + 60 * minute));
}

test "sparkline reads oldest-first with the newest bucket last" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "a", 100), null);
    roster.record(mkEv(.claude, t0 + 3 * burn_bucket_ms, "a", 400), null);
    roster.advanceTo(t0 + 3 * burn_bucket_ms);

    var buf: [burn_buckets]u64 = undefined;
    const spark = roster.find(.claude, "a").?.sparkline(&buf);
    try testing.expectEqual(burn_buckets, spark.len);
    try testing.expectEqual(@as(u64, 400), spark[spark.len - 1]);
    try testing.expectEqual(@as(u64, 100), spark[spark.len - 4]);
    try testing.expectEqual(@as(u64, 0), spark[spark.len - 2]);
}

test "an empty roster is done, quiet and orderable" {
    var roster = Roster{};
    var buf: [max_sessions]*const Session = undefined;
    try testing.expectEqual(Activity.done, roster.activity(t0));
    try testing.expectEqual(@as(usize, 0), roster.activeCount(t0));
    try testing.expectEqual(@as(usize, 0), roster.live(&buf, t0).len);
    try testing.expectEqual(@as(?*const Session, null), roster.find(.claude, "nope"));
    roster.advanceTo(t0);
    try testing.expectEqual(@as(usize, 0), roster.count());
}

test "live respects a short output slice instead of overflowing it" {
    var roster = Roster{};
    roster.record(mkEv(.claude, t0, "a", 10), null);
    roster.record(mkEv(.claude, t0, "b", 10), null);
    roster.record(mkEv(.claude, t0, "c", 10), null);
    var buf: [2]*const Session = undefined;
    try testing.expectEqual(@as(usize, 2), roster.live(&buf, t0).len);
}

test "cache reads are discounted in a session's burn like the main gauge" {
    var roster = Roster{};
    roster.record(.{
        .agent = .claude,
        .timestamp_ms = t0,
        .model = "m",
        .cache_read_tokens = 1_000_000,
        .session_id = "a",
    }, null);
    const s = roster.find(.claude, "a").?;
    // Raw totals keep the truth; the burn ring holds the weighted view.
    try testing.expectEqual(@as(u64, 1_000_000), s.totals.totalTokens());
    try testing.expectEqual(@as(u64, 100_000), s.burn.total());
}
