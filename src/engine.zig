//! The TEA loop: Model, Msg, boot, update. Bridges the UI-free core
//! (tailers, ledger, pricing, prediction, oauth) to the Native SDK
//! effects channel (timers, fetch, spawn).
//!
//! Cadence: a repeating 2 s sweep timer tails both agents' JSONL trees
//! and re-derives every display string; a 30 s gate timer fires OAuth
//! polls when `claude-oauth = true` and the backoff window allows.

const std = @import("std");
const native_sdk = @import("native_sdk");
const c = @cImport({
    @cInclude("time.h");
});

const types = @import("core/types.zig");
const config = @import("core/config.zig");
const claude = @import("core/claude.zig");
const codex = @import("core/codex.zig");
const opencode = @import("core/opencode.zig");
const snapsource = @import("core/snapsource.zig");
const fleet = @import("core/fleet.zig");
const pricing = @import("core/pricing.zig");
const ledger_mod = @import("core/ledger.zig");
const statefile = @import("core/statefile.zig");
const predict = @import("core/predict.zig");
const sessions = @import("core/sessions.zig");
const project_mod = @import("core/project.zig");
const history_mod = @import("core/history.zig");
const ring = @import("core/ring.zig");
const alerts = @import("core/alerts.zig");
const oauth = @import("core/oauth.zig");
const keychain = @import("core/keychain.zig");
const trayfmt = @import("core/trayfmt.zig");
const system = @import("core/system/system.zig");

pub const Effects = native_sdk.Effects(Msg);

pub const sweep_timer_key: u64 = 1;
pub const oauth_gate_timer_key: u64 = 2;
pub const oauth_fetch_key: u64 = 3;
pub const creds_spawn_key: u64 = 5;
pub const catchup_timer_key: u64 = 6;
pub const ignition_timer_key: u64 = 7;
/// External-source channel (SDK fx.openChannel): a background thread
/// samples system telemetry on its own cadence and posts each reading,
/// so the strip is a PUSHED instrument, not a polled one. Shares the
/// keyed-effects key space (config_spawn_key is 8).
pub const system_channel_key: u64 = 9;

/// The telemetry producer's own pace, independent of the 2 s usage
/// sweep. 1 s keeps the strip lively; the delta-based samplers derive
/// their rates from real elapsed time, so any interval is exact.
pub const system_sample_interval_ms: u64 = 1_000;

pub const sweep_interval_ms: u32 = 2_000;
pub const oauth_gate_interval_ms: u32 = 30_000;
/// Historical catch-up cadence: fast enough to feel instant, spaced
/// enough that render frames land between chunks.
///
/// 120 ms, not 30: every catch-up chunk ends in a Msg dispatch, and the
/// SDK rebuilds the ENTIRE view tree on every Msg. At 30 ms that is a
/// 33 Hz full rebuild for the whole duration of a cold start — the most
/// expensive thing the app ever does, spent re-deriving a progress
/// counter. The chunk budget below scales with it, so the parse rate in
/// bytes/second is unchanged; only the redraws are 4x cheaper.
pub const catchup_interval_ms: u32 = 120;
/// Per-chunk byte budget for catch-up file parsing. Sized against
/// `catchup_interval_ms` to hold the same bytes/second as the old
/// 3 MiB @ 30 ms pairing.
pub const catchup_chunk_bytes: u64 = 12 * 1024 * 1024;

pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,
    catchup_tick: native_sdk.EffectTimer,
    oauth_tick: native_sdk.EffectTimer,
    creds_done: native_sdk.EffectExit,
    oauth_response: native_sdk.EffectResponse,
    spawn_done: native_sdk.EffectExit,
    /// Tray "Quit" — accessory apps have no Dock icon to quit from.
    quit,
    /// Display-only: the tray popover just opened (SDK on_command
    /// `tray.popover_opened`) — replay the ignition sweep.
    popover_opened,
    /// Display-only: an ignition phase boundary (one-shot timer).
    ignition_tick: native_sdk.EffectTimer,
    /// Open the history dashboard window (tray menu item or the
    /// popover's DASH button). The flag IS the window: main.zig's
    /// `windows_fn` declares the window while it is set and the runtime
    /// reconciles after every dispatch.
    open_dashboard,
    /// The user closed the dashboard window — clear the flag so the
    /// model agrees with the platform (see WindowDescriptor.on_close).
    dashboard_closed,
    /// Tray "Settings": open ~/.config/token-tach/config in the default
    /// editor (creating a commented template first if absent).
    open_config,
    /// A telemetry reading (or channel lifecycle event) posted by the
    /// system-sampler producer thread through the external-source
    /// channel (SDK fx.openChannel).
    system_reading: native_sdk.EffectChannelEvent,
    /// Pointer entered a system-telemetry cell — the footer reveals its
    /// full reading until the paired `hover_clear` (SDK on_hover_enter).
    hover_system: HoverTarget,
    /// Pointer left the hovered cell (SDK on_hover_leave) — footer
    /// returns to the status line.
    hover_clear,

    // ---------------------------------------------------------- UI wave
    // Declared HERE, ahead of the UI that sends them, so the view wave
    // binds widgets without editing this file at all. Every arm below
    // touches `Model.ux` and nothing else: no I/O, no effects, no
    // instrument state — which is what makes them safe to land early.

    /// Select a page of the multi-function display.
    mfd_page: MfdPage,
    /// Select the time span charts and tables cover.
    time_range: TimeRange,
    /// Restrict the fleet views to one agent; null shows everything.
    filter_agent: ?types.Agent,
    /// Sort a table by a column. Re-sending the current column flips the
    /// direction, which is what every table in the world does.
    sort_by: SortColumn,
    /// Step the big readout to its next mode (rate → today → trip → eta).
    readout_cycle,
    /// Focus a pane of the dashboard window.
    dashboard_focus: DashboardPane,
    /// The user acknowledged the current alerts; silence them until
    /// something changes.
    alert_ack,
    /// Toggle a HUD overlay. Sending the open panel closes it.
    hud_toggle: HudPanel,
    /// A HUD overlay dismissed itself (escape, click-away). Ignored
    /// unless that panel is the one actually open, so a stale dismissal
    /// cannot close a panel the user just opened.
    hud_closed: HudPanel,
    /// Pointer is over a chart sample; null clears the readout.
    chart_hover: ?ChartHover,
    /// A table row was pressed (row index within the rendered list).
    row_press: u16,
    /// Zero the trip odometer and restart its clock.
    trip_reset,
};

/// A hover-revealable element of the instrument. Scalar payload so the
/// SDK can capture the paired leave (a single-item pointer can't be).
pub const HoverTarget = enum { cpu, gpu, mem, disk, net, battery };

// --------------------------------------------------------- UI wave state
// The types below exist so the view wave adds its state to `Ux` — its
// own struct — instead of growing `Model`. They are pure display: no
// engine code reads them, so a bad value can make the UI wrong and can
// never make the numbers wrong.

/// Which page the multi-function display shows.
pub const MfdPage = enum { burn, sessions, windows, telemetry, ledger };

/// The span a chart or table covers. `.live` is the instrument's own
/// short window (the burn rings); the rest are history queries.
pub const TimeRange = enum { live, hour, day, week, month, all };

/// Sort key for the agent / session / model / project tables.
pub const SortColumn = enum { cost, tokens, activity, name };

/// What the large numeric readout shows.
pub const ReadoutMode = enum { rate, today, trip, eta };

/// A transient overlay panel. `.none` is "no HUD", so the open panel is
/// one value rather than a set of bools that can disagree.
pub const HudPanel = enum { none, alerts, sessions, help, config };

/// Which pane of the dashboard window has focus.
pub const DashboardPane = enum { overview, agents, projects, models, sessions };

/// A hovered chart sample. `chart` identifies the chart (the view owns
/// the numbering), `sample` indexes the snapshot it was drawn from —
/// never a wall clock, because the snapshot is what the user is looking
/// at and it scrolls between frames.
pub const ChartHover = struct { chart: u8 = 0, sample: u16 = 0 };

/// Pure-display UI state, kept in one sub-struct on the Model.
///
/// Wave 3 adds fields HERE. The point is that the UI can grow its own
/// state without touching the Model's engine fields, so a UI change can
/// never accidentally alter what gets journaled, persisted or measured.
pub const Ux = struct {
    mfd_page: MfdPage = .burn,
    time_range: TimeRange = .live,
    filter_agent: ?types.Agent = null,
    sort_by: SortColumn = .cost,
    /// Descending is the useful default for every column here: the
    /// biggest spender, the newest activity, the hottest burn.
    sort_desc: bool = true,
    readout: ReadoutMode = .rate,
    hover: ?ChartHover = null,
    hud: HudPanel = .none,
    dashboard_focus: DashboardPane = .overview,
    /// Journaled clock of the last `alert_ack`, so "acknowledged" is a
    /// point in time an alert can be newer than.
    alerts_acked_ms: i64 = 0,
    selected_row: u16 = 0,
};

/// Next readout in the cycle. A wrapping successor rather than a stored
/// index so adding a mode to `ReadoutMode` needs no edit here.
pub fn nextReadout(mode: ReadoutMode) ReadoutMode {
    const values = std.enums.values(ReadoutMode);
    // Widen before incrementing: the enum's tag type is exactly wide
    // enough to hold its members, so `last + 1` overflows in it.
    const idx: usize = @intFromEnum(mode);
    return values[(idx + 1) % values.len];
}

/// One queued history file awaiting its catch-up parse.
pub const CatchupFile = struct {
    agent: types.Agent,
    path: []const u8,
    size: u64,
};

const text_buf_len = 192;

/// A time axis for the telemetry strip.
///
/// `Model.system_snap` is a single instant, so every system meter draws
/// a bar of NOW and nothing on the panel can answer "was the machine
/// like this a minute ago" — the strip is a gauge cluster with no
/// tachometer. These are the same readings on a wall clock.
///
/// Sizing, deliberately: 5 s buckets x 360 = exactly 30 minutes, seven
/// series. One `ring.Series(f32, 360)` is 360 values + 360 filled flags
/// + a small clock ~= 1.8 KB, so the whole history costs ~12.5 KB of the
/// Model — an order of magnitude under the roster, and fixed. The
/// producer posts at 1 Hz, so a bucket keeps the LAST of five readings
/// rather than their mean: averaging a level series hides exactly the
/// spikes someone is looking at a telemetry chart to find.
///
/// Only enabled modules are recorded (the snapshot is masked before it
/// gets here), so turning a module off leaves a GAP rather than a run of
/// zeros — `Series` distinguishes the two and a chart must too.
pub const SystemHistory = struct {
    pub const period_ms: i64 = 5_000;
    pub const buckets: usize = 360;
    pub const span_ms: i64 = period_ms * @as(i64, @intCast(buckets));
    pub const Series = ring.Series(f32, buckets);

    /// Whole-machine busy fraction, 0..1.
    cpu: Series = .init(period_ms),
    /// Accelerator device utilization, 0..1.
    gpu: Series = .init(period_ms),
    /// Memory used fraction, 0..1.
    mem: Series = .init(period_ms),
    /// Root volume used fraction, 0..1.
    disk: Series = .init(period_ms),
    /// Receive throughput in BYTES PER SECOND, not the meter fraction:
    /// the meter's denominator is a ratcheted peak that moves on its own,
    /// so a stored fraction would encode the meter's history instead of
    /// the network's.
    net_rx: Series = .init(period_ms),
    /// Transmit throughput, bytes/sec.
    net_tx: Series = .init(period_ms),
    /// Battery charge, 0..1.
    battery: Series = .init(period_ms),

    /// Roll every series forward on wall time so a stalled sampler
    /// scrolls its trace away instead of pinning the last reading under
    /// the head. Safe at any cadence.
    pub fn advanceTo(self: *SystemHistory, now_ms: i64) void {
        inline for (@typeInfo(SystemHistory).@"struct".fields) |field| {
            @field(self, field.name).advanceTo(now_ms);
        }
    }

    /// Record one (already config-masked) reading at `now_ms`.
    pub fn record(self: *SystemHistory, now_ms: i64, snap: system.Snapshot) void {
        if (snap.cpu) |s| self.cpu.record(now_ms, @floatCast(s.total_frac));
        if (snap.gpu) |s| self.gpu.record(now_ms, @floatCast(s.device_utilization));
        if (snap.mem) |s| self.mem.record(now_ms, @floatCast(s.used_frac));
        if (snap.disk) |s| self.disk.record(now_ms, @floatCast(s.used_fraction));
        if (snap.net) |s| {
            if (s.in_bytes_per_sec) |v| self.net_rx.record(now_ms, @floatCast(v));
            if (s.out_bytes_per_sec) |v| self.net_tx.record(now_ms, @floatCast(v));
        }
        if (snap.battery) |s| self.battery.record(now_ms, @floatCast(s.charge));
    }

    /// Wall-clock start of the oldest bucket every series covers — the
    /// shared x-axis origin (they advance together, so one answers for
    /// all of them).
    pub fn windowStartMs(self: *const SystemHistory) i64 {
        return self.cpu.windowStartMs();
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator = undefined,
    ready: bool = false,
    cfg: config.Config = .{},
    /// Config live-reload state: the resolved config path (owned), the
    /// mtime of the last text we parsed, and the arena that owns every
    /// slice inside `cfg`. A reload builds a fresh arena, swaps `cfg`,
    /// then frees the old one — nothing else may alias config strings.
    config_path: []const u8 = "",
    config_mtime_ns: ?i128 = null,
    cfg_arena: ?std.heap.ArenaAllocator = null,

    claude_tailer: claude.Tailer = undefined,
    codex_tailer: codex.Tailer = undefined,
    opencode_poller: opencode.Poller = undefined,
    claude_roots: []const []const u8 = &.{},
    codex_roots: []const []const u8 = &.{},
    opencode_db: []const u8 = "",

    /// The tt-hr8 collector fleet (pi/gemini/qwen/kimi/goose/kilo/
    /// cline/roo). Built in setup; null until ready (or when fleet
    /// construction failed — the core agents still run).
    fleet: ?fleet.Fleet = null,

    prices: pricing.Db = undefined,
    ledger: ledger_mod.Ledger = undefined,
    /// LEGACY blended burn ring. `agent_burn` is the instrument; this one
    /// survives for exactly one reason: `view.zig`'s `burnSpark` indexes
    /// `model.burn.buckets` / `model.burn.head` by raw slot, and view.zig
    /// belongs to the UI wave. Both rings are fed from the same two call
    /// sites and a test below pins them bit-for-bit, so they cannot drift
    /// while this lasts. Deleting the field is a one-line change here the
    /// moment `burnSpark` moves to `AgentBurn`.
    burn: predict.BurnRate = .{},
    /// Burn split by agent, plus the fleet's 10-second scope trace.
    /// `totalPerMin` is the needle and is bit-exact against `burn`.
    agent_burn: predict.AgentBurn = .{},
    walls: predict.WallTracker = .{},
    alerts: alerts.AlertEngine = .{},

    /// Live agent sessions — the INSTANT tier. Never persisted: it answers
    /// "who is running right now", and a restored answer to that is a
    /// wrong answer. (`ledger.per_session` is the process-lifetime rollup,
    /// `history`'s session dimension is the durable record; the three are
    /// separate on purpose.)
    roster: sessions.Roster = .{},

    /// cwd -> repository root, memoized. Not journaled: it caches a
    /// filesystem fact, and the answers it produces are copied into the
    /// roster, the ledger and the history store at ingest, so a replay
    /// reads what was recorded rather than re-deriving it on a machine
    /// where the worktree has since been deleted.
    /// Defaults to the allocator-free string-rule resolver, so a Model
    /// built without `setup` still attributes projects deterministically.
    projects: project_mod.Resolver = .{},

    /// Durable analytical time series — the FOREVER tier. Null when the
    /// store could not be opened (another instance holds the lock, or the
    /// state directory is unusable); every call site tolerates that,
    /// because telemetry must never be able to break collection.
    history: ?history_mod.Writer = null,
    /// Events staged into the history writer since the last flush. Its OWN
    /// counter, deliberately not `state_dirty`: `ingest` records history
    /// without ever setting `state_dirty` (only `ingestChange` does), so a
    /// flush gated on that flag would never fire for the claude/codex
    /// tailers — i.e. for almost everything.
    history_dirty: u32 = 0,
    history_flush_countdown: u32 = history_flush_ticks,
    /// The persisted history backfill gate. Round-tripped through the
    /// statefile so a seeded durable store is seeded exactly once: the
    /// plain `save`/`restore` entry points default it, which would rewrite
    /// `backfilled = false` every minute and re-run the backfill on every
    /// boot. Held on the Model so the save path has something truthful to
    /// write back.
    backfill: statefile.Backfill = .{},

    /// Latest limit snapshots for display (windows slices owned by us).
    claude_limits: ?types.LimitSnapshot = null,
    codex_limits: ?types.LimitSnapshot = null,

    /// System telemetry: per-sampler counter state plus the latest
    /// snapshot (plain values, refreshed each sweep, ephemeral by
    /// design — never persisted).
    system_sampler: system.Sampler = system.Sampler.init(),
    system_snap: system.Snapshot = .{},
    /// The same readings on a wall clock (30 minutes at 5 s resolution).
    /// Fed from the 1 Hz producer arm; see `SystemHistory`.
    system_history: SystemHistory = .{},
    /// True when the sampler channel is unavailable (open refused, spawn
    /// failed, or the channel closed) and the 2 s sweep must sample
    /// system telemetry itself. False in the normal push path AND under
    /// replay (where the journaled channel events drive the strip), so
    /// the tick never double-samples over the channel.
    system_tick_fallback: bool = false,
    /// Back-pressure the producer reported on its last delivered reading
    /// (posts dropped because the UI drain fell behind) — surfaced so a
    /// stalled strip is honest, never silent.
    system_drops: u32 = 0,
    /// Which system cell the pointer is over, if any (pure display —
    /// drives the footer reveal). Null = footer shows the status line.
    hovered_system: ?HoverTarget = null,

    /// The launch-at-login value last pushed to the OS (null = never
    /// pushed). Applying is idempotent-guarded on this so config
    /// reload polls don't hammer SMAppService.
    launch_at_login_applied: ?bool = null,

    // OAuth poller state.
    oauth_backoff: oauth.Backoff = .{},
    oauth_next_ms: i64 = 0,
    oauth_last_success_ms: i64 = 0,
    oauth_inflight: bool = false,

    /// Journaled wall clock, refreshed on every tick — the only clock
    /// the render path may read.
    now_ms: i64 = 0,
    tz_offset_min: i32 = 0,
    first_sweep_done: bool = false,

    /// Plan tier from the keychain credentials ("max"/"pro"), locally
    /// known without any API call.
    claude_plan: []const u8 = "",
    claude_plan_buf: [32]u8 = undefined,

    // Historical catch-up: the file queue boot enumerated, chewed through
    // in byte-budgeted chunks on a fast timer so the dispatch loop (and
    // the window) never freezes behind months of JSONL.
    catchup_queue: []CatchupFile = &.{},
    catchup_next: usize = 0,
    catchup_active: bool = false,
    catchup_started_ms: i64 = 0,

    // Persisted tailer/ledger state (statefile.zig): resolved path (owned),
    // the ledger event count at the last save (idle ticks skip the write),
    // and the tick countdown to the next save.
    state_path: []const u8 = "",
    state_saved_events: u64 = 0,
    state_dirty: bool = false,
    state_save_countdown: u32 = state_save_ticks,

    // Display strings bound by app.native — regenerated each sweep, and
    // pointing into the fixed buffers below (never into stack copies).
    glance_text: []const u8 = "",
    claude_text: []const u8 = "",
    codex_text: []const u8 = "",
    opencode_text: []const u8 = "",
    today_text: []const u8 = "",
    status_text: []const u8 = "starting…",

    glance_buf: [text_buf_len]u8 = undefined,
    claude_buf: [text_buf_len]u8 = undefined,
    codex_buf: [text_buf_len]u8 = undefined,
    opencode_buf: [text_buf_len]u8 = undefined,
    today_buf: [text_buf_len]u8 = undefined,
    status_buf: [text_buf_len]u8 = undefined,

    /// An error status stays visible until the failing path succeeds;
    /// the routine "N events" line never overwrites it.
    status_error: bool = false,

    // Instrument display state (pure display, refreshed each sweep):
    // the tach needs a stable scale (a ratcheted, slowly decaying burn
    // peak) and the previous/current needle pose so the view's render
    // animation can sweep between them instead of snapping.
    gauge_peak_tpm: f64 = 0,
    needle_from_deg: f32 = -half_sweep_deg,
    needle_to_deg: f32 = -half_sweep_deg,

    // Ignition sweep (pure display): the key-on needle theatre — 0 →
    // full scale → settle onto truth — runs at boot and on every
    // popover open. The phase machine is stepped by one-shot timers;
    // `ignition_t0_ms` anchors the render animations on the wall
    // clock so mid-sweep rebuilds replay idempotently instead of
    // restarting the sweep.
    ignition_phase: IgnitionPhase = .off,
    ignition_t0_ms: i64 = 0,

    /// The history dashboard window's open flag (pure display). The
    /// runtime reconciles model-declared windows against this after
    /// every dispatch — presence IS visibility.
    dashboard_open: bool = false,

    // Derived-state cache. `glanceState` and `dangerState` are pure
    // functions of journaled state, and the view called them 5x and 7x
    // per rebuild — each one a `ledger.today` hash lookup plus, for
    // danger, `nearestWall` + `maxUtilization` over every tracked window.
    // The refresh journals them once per clock tick.
    //
    // Validity is `derived_cache_ms == now_ms`, not a bool: a Model whose
    // clock moved without a refresh (a hand-built test model, an update
    // arm that only bumped `now_ms`) MISSES and recomputes, so the cache
    // can make the app faster and cannot make it stale. -1 is a clock no
    // journaled `now_ms` can hold.
    glance_cache: trayfmt.GlanceState = .{ .now_ms = 0 },
    danger_cache: bool = false,
    derived_cache_ms: i64 = -1,

    /// Wave-3 UI state. Additions go in `Ux`, not here.
    ux: Ux = .{},

    /// Trip odometer: what this launch has burned, the counterpart to the
    /// ledger's all-time and per-day totals. `trip_start_ms` is both the
    /// clock the $/hr rate divides by and the cut-off that keeps a cold
    /// start's six months of backfill out of the trip (see `tripAdd`).
    trip_start_ms: i64 = 0,
    trip: ledger_mod.Totals = .{},
};

pub const IgnitionPhase = enum { off, up, settle };

/// Ignition tempo: needle 0 → full scale, a beat at the top, then a
/// settle onto the true reading (~1.3 s total — a car key turn).
pub const ignition_up_ms: u32 = 700;
pub const ignition_settle_ms: u32 = 620;

/// The tach sweeps ±120° around 12 o'clock (a classic 240° dial).
pub const half_sweep_deg: f32 = 120;

/// Ratchet decay per 2 s sweep: the peak halves in roughly 30 minutes,
/// so the dial re-ranges down slowly instead of flapping.
///
/// "Per sweep" is load-bearing and used to be a lie: the decay lived in
/// `refreshDisplay`, which four different cadences called — the 2 s
/// sweep, the 1 Hz telemetry arm, the config-reload branch, and the
/// 30 ms catch-up chunk. Steady state decayed ~3x too fast and a cold
/// start ~66x too fast, which is why the dial visibly re-ranged while
/// you watched it. It now applies only in `advanceInstrument`, whose
/// callers are exactly the sweep boundaries: `boot`, `sweepOnce`, and
/// the catch-up branch of the 2 s tick (which stands the usage sweep
/// down but is still the 2 s tick).
const peak_decay_per_sweep: f64 = 0.99923;

/// Smallest 1-2-5 ladder scale (tokens/min) that clears the recent
/// peak with ~15% headroom; never below 10k/m.
pub fn gaugeScaleTpm(peak_tpm: f64) f64 {
    const target = @max(peak_tpm * 1.15, 10_000);
    var decade: f64 = 10_000;
    while (decade < target) {
        if (decade * 2 >= target) return decade * 2;
        if (decade * 5 >= target) return decade * 5;
        decade *= 10;
    }
    return decade;
}

/// Needle pose (degrees clockwise from 12 o'clock) for a burn rate on
/// the current scale.
pub fn needleDeg(tpm: f64, scale_tpm: f64) f32 {
    const frac = std.math.clamp(tpm / @max(scale_tpm, 1), 0, 1);
    return @floatCast(-half_sweep_deg + 2 * half_sweep_deg * frac);
}

/// Redline truth: a wall projected within 45 minutes, or any limit
/// window past 80% utilization.
///
/// Served from the refresh's cache when it is current for `now_ms` — the
/// view asks seven times per rebuild and the answer cannot change
/// between those asks.
pub fn dangerState(model: *const Model) bool {
    if (model.derived_cache_ms == model.now_ms) return model.danger_cache;
    return computeDangerState(model);
}

fn computeDangerState(model: *const Model) bool {
    if (model.walls.maxUtilization()) |hot| {
        if (hot.used_percent > 80) return true;
    }
    if (model.walls.nearestWall(model.now_ms)) |wall| {
        if (wall.at_ms - model.now_ms < 45 * 60_000) return true;
    }
    return false;
}

/// Minutes since the last successful Claude OAuth poll, once that
/// reading has gone stale (older than `oauth.stale_after_ms`). Null
/// while fresh, before the first success, or when there is no snapshot
/// to be stale about. Note: deliberately NOT gated on
/// `cfg.claude_oauth` — when live-reload disables polling we keep the
/// last snapshot, and this tag is what keeps it honest.
pub fn oauthStaleMin(model: *const Model) ?u64 {
    if (model.claude_limits == null) return null;
    if (model.oauth_last_success_ms <= 0) return null;
    const age_ms = model.now_ms - model.oauth_last_success_ms;
    if (age_ms <= oauth.stale_after_ms) return null;
    return @intCast(@divFloor(age_ms, 60_000));
}

/// Is this agent's source enabled in config?
pub fn sourceEnabled(sources: config.Sources, agent: types.Agent) bool {
    return sources.enabled(agent);
}

/// True when an agent has nothing to report: source enabled but zero
/// ledger events and no limit snapshot. During catch-up the question is
/// still open; afterwards it means "no sessions found".
pub fn agentIsEmpty(model: *const Model, agent: types.Agent) bool {
    if (model.ledger.forAgent(agent).events != 0) return false;
    const limits = switch (agent) {
        .claude => model.claude_limits,
        .codex => model.codex_limits,
        else => null,
    };
    return limits == null;
}

/// Environment facts setup needs — extracted from the runner's
/// `init.environ_map` by main (keeps setup unit-testable).
pub const Env = struct {
    home: []const u8 = "",
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    opencode_db: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    pi_home: ?[]const u8 = null,
    gemini_cli_home: ?[]const u8 = null,
    qwen_runtime_dir: ?[]const u8 = null,
    qwen_home: ?[]const u8 = null,
    kimi_share_dir: ?[]const u8 = null,
    goose_path_root: ?[]const u8 = null,
    kilo_db: ?[]const u8 = null,
    cline_dir: ?[]const u8 = null,
    cline_data_dir: ?[]const u8 = null,
};

/// engine.Env -> fleet.Env, field by field (the two structs mirror each
/// other but stay decoupled, same pattern as systemEnabled).
fn fleetEnv(env: Env) fleet.Env {
    return .{
        .home = env.home,
        .pi_home = env.pi_home,
        .gemini_cli_home = env.gemini_cli_home,
        .qwen_runtime_dir = env.qwen_runtime_dir,
        .qwen_home = env.qwen_home,
        .kimi_share_dir = env.kimi_share_dir,
        .goose_path_root = env.goose_path_root,
        .xdg_data_home = env.xdg_data_home,
        .kilo_db = env.kilo_db,
        .cline_dir = env.cline_dir,
        .cline_data_dir = env.cline_data_dir,
    };
}

fn fleetPtr(model: *Model) ?*fleet.Fleet {
    if (model.fleet) |*fl| return fl;
    return null;
}

/// Persist tailer+ledger state every N sweep ticks (N × 2 s ≈ 60 s).
pub const state_save_ticks: u32 = 30;

/// Flush staged history every N sweep ticks (N × 2 s ≈ 30 s). Half the
/// statefile's cadence because the two protect different things: losing
/// a statefile costs a re-parse, losing history costs data that the
/// source transcripts may already have rotated away.
pub const history_flush_ticks: u32 = 15;

/// A wall clock for `setup`, which runs before the SDK's journaled one
/// exists. libc, not a subprocess — the same synchronous read
/// `localTzOffsetMin` makes, and for the same reason: the history store
/// stamps its file headers and dictionary generation with the creation
/// time, and a store created at epoch 0 would be permanently confusing.
/// Never assigned to `Model.now_ms`; `boot` owns that field.
fn setupWallMs() i64 {
    return @as(i64, c.time(null)) * 1000;
}

/// The `std.Io` handed to the history writer.
///
/// Every other call site in this file builds a `std.Io.Threaded` on the
/// stack and lets it die with the function. The writer is the one
/// component that STORES its `std.Io` for the life of the process, and
/// `Threaded.io()` points at the `Threaded` it was called on — so a
/// stack-local one would dangle the instant `setup` returned.
/// `global_single_threaded` is the instance with static lifetime.
fn historyIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Build the engine state: config, roots, tailers, pricing. Called once
/// on the heap-allocated model before the runtime starts.
pub fn setup(model: *Model, allocator: std.mem.Allocator, env: Env) !void {
    model.allocator = allocator;
    const home = env.home;
    // Before anything can ingest: the statefile restore below resolves the
    // project keys it reads through this.
    model.projects = project_mod.Resolver.init(allocator, home);

    // Config: absent file or bad lines never block startup. The path and
    // mtime stick around on the model so the 2 s sweep can live-reload.
    if (config.defaultPath(allocator, home)) |path| {
        model.config_path = path;
        model.config_mtime_ns = config.fileMtimeNs(path);
        _ = loadConfigFromDisk(model);
    } else |_| {}

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    model.claude_roots = if (model.cfg.claude_config_dirs.len > 0)
        try appendProjects(allocator, model.cfg.claude_config_dirs)
    else
        try claude.discoverRoots(allocator, io, env.claude_config_dir, home);

    const codex_env: ?[]const u8 = if (model.cfg.codex_home.len > 0)
        model.cfg.codex_home
    else
        env.codex_home;
    model.codex_roots = try codex.sessionsDirs(allocator, codex_env, home);
    model.opencode_db = try opencode.resolvePath(allocator, model.cfg.opencode_db, env.opencode_db, env.xdg_data_home, home);

    model.claude_tailer = claude.Tailer.init(allocator);
    model.codex_tailer = codex.Tailer.init(allocator);
    model.opencode_poller = opencode.Poller.init(allocator);
    // Collector fleet AFTER config load (env drives its roots). A failed
    // build degrades to core-agents-only rather than blocking startup.
    model.fleet = fleet.Fleet.init(allocator, fleetEnv(env)) catch |err| blk: {
        std.log.warn("collector fleet init failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    model.prices = try pricing.Db.init(allocator);
    // Resolve the local UTC offset synchronously, before the ledger and
    // its day buckets exist. Catch-up starts on boot, and a ledger created
    // at tz=0 would split historical days for every non-UTC user.
    model.tz_offset_min = localTzOffsetMin();
    model.ledger = ledger_mod.Ledger.init(allocator, model.tz_offset_min);

    // Warm launch: restore tailer offsets + ledger rollups so history is
    // never re-parsed. Any doubt about the file -> pristine full catch-up.
    model.state_path = statefile.defaultPath(allocator, env.xdg_state_home, home) catch "";
    if (model.state_path.len > 0) {
        const outcome = statefile.restoreWith(
            allocator,
            io,
            model.state_path,
            &model.claude_tailer,
            &model.codex_tailer,
            &model.opencode_poller,
            fleetPtr(model),
            &model.ledger,
            &model.backfill,
        ) catch .invalid; // OOM: hydration may be partial — reset below.
        switch (outcome) {
            .restored => {
                model.state_saved_events = model.ledger.all.events;
                // The restored PROJECTS rollup is keyed on whatever the
                // writing build used. Fold it onto repository roots so a
                // statefile from before the worktree rollup stops showing
                // its old per-worktree rows. A failure here leaves the
                // rollup exactly as restored — stale keys, correct totals.
                model.ledger.rekeyProjects(&model.projects) catch
                    std.log.warn("project rollup rekey failed — PROJECTS may show stale worktree rows", .{});
            },
            .absent => {},
            .invalid => {
                model.claude_tailer.deinit();
                model.codex_tailer.deinit();
                model.opencode_poller.deinit();
                model.ledger.deinit();
                model.claude_tailer = claude.Tailer.init(allocator);
                model.codex_tailer = codex.Tailer.init(allocator);
                model.opencode_poller = opencode.Poller.init(allocator);
                model.ledger = ledger_mod.Ledger.init(allocator, model.tz_offset_min);
                if (model.fleet) |*fl| fl.deinit();
                model.fleet = fleet.Fleet.init(allocator, fleetEnv(env)) catch null;
                std.log.warn("state file invalid — falling back to full catch-up", .{});
            },
        }
    }

    openHistory(model, env);
    model.ready = true;
}

/// Open the durable time series beside the statefile. A store we cannot
/// open (second instance holding the flock, unusable state directory)
/// leaves `model.history` null and the app runs exactly as it did before
/// history existed — the module's failure policy, honored at the seam.
fn openHistory(model: *Model, env: Env) void {
    const dir = history_mod.defaultDir(model.allocator, env.xdg_state_home, env.home) catch |err| {
        std.log.warn("history: no directory ({s})", .{@errorName(err)});
        return;
    };
    defer model.allocator.free(dir);
    const writer = history_mod.Writer.open(model.allocator, historyIo(), dir, .{
        .tz_offset_min = model.tz_offset_min,
        .now_ms = setupWallMs(),
    }) catch |err| {
        std.log.warn("history: not opened ({s})", .{@errorName(err)});
        return;
    };
    model.history = writer;
}

/// Release what the Model owns outright. Called on the tray Quit path
/// (which exits the process immediately afterwards) and from main's
/// teardown. Deliberately narrow: the ledger, tailers, config arena and
/// resolved paths live until the process does and are reclaimed by it —
/// the two members here are the ones with an OS-visible obligation, a
/// history flock plus staged records, and a sysctl scratch buffer.
pub fn deinit(model: *Model) void {
    if (model.history) |*writer| writer.deinit(); // flushes, then unlocks
    model.history = null;
    model.history_dirty = 0;
    model.system_sampler.deinit();
}

/// config `claude-config-dir` entries are config roots; the transcripts
/// live under `<root>/projects`.
fn appendProjects(allocator: std.mem.Allocator, dirs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    for (dirs) |d| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/projects", .{d}));
    }
    return try out.toOwnedSlice(allocator);
}

/// Read + parse the config file into a fresh arena and swap it in
/// (freeing the previous arena). A missing or unreadable file keeps the
/// current config untouched. Parse never hard-fails, so any readable
/// file yields a config (bad lines degrade to warnings/defaults).
fn loadConfigFromDisk(model: *Model) bool {
    if (model.config_path.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(model.allocator);
    const result = (config.load(arena.allocator(), model.config_path) catch null) orelse {
        arena.deinit();
        return false;
    };
    for (result.warnings) |w| {
        std.log.warn("config:{d}: {s}", .{ w.line, w.message });
    }
    model.cfg = result.config;
    if (model.cfg_arena) |*old| old.deinit();
    model.cfg_arena = arena;
    return true;
}

/// Live-reload poll, called from the 2 s sweep tick: stat the config
/// file and re-load when its mtime moved. Returns the sources that this
/// reload newly ENABLED (they need a history catch-up pass), or null
/// when nothing was reloaded. Applied live: `tray-format` (next tray
/// render), `source` (panels + sweeps), `claude-oauth` (enable polls on
/// the next gate; disable stops polling but KEEPS the last limit
/// snapshots — the staleness tag marks them honestly), and
/// `alert-threshold` (stored for the future notifier), and
/// `system-stats` (the next sweep samples exactly the new module set).
/// Root-path keys (`claude-config-dir`, `codex-home`, `opencode-db`)
/// still require a restart.
pub fn maybeReloadConfig(model: *Model) ?config.Sources {
    if (model.config_path.len == 0) return null;
    // A deleted config keeps the old values (ghostty behavior).
    const mtime = config.fileMtimeNs(model.config_path) orelse return null;
    if (model.config_mtime_ns) |old| {
        if (mtime == old) return null;
    }
    model.config_mtime_ns = mtime;
    const old_sources = model.cfg.sources;
    const old_oauth = model.cfg.claude_oauth;
    if (!loadConfigFromDisk(model)) return null;
    std.log.info("config reloaded from {s}", .{model.config_path});
    if (model.cfg.claude_oauth and !old_oauth) {
        // Freshly opted in: poll at the next gate, not after a stale
        // backoff window left over from before the opt-in.
        model.oauth_backoff = .{};
        model.oauth_next_ms = model.now_ms;
    }
    return model.cfg.sources.addedSince(old_sources);
}

pub fn boot(model: *Model, fx: *Effects) void {
    // Enumerate the historical file queue (directory walk only — fast)
    // and chew through it on the fast catch-up timer. The window shows
    // live scanning progress instead of freezing behind the parse.
    model.now_ms = fx.wallMs();
    model.trip_start_ms = model.now_ms;
    if (model.ready) startCatchup(model, model.cfg.sources, fx);
    fx.startTimer(.{
        .key = sweep_timer_key,
        .interval_ms = sweep_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    fx.startTimer(.{
        .key = oauth_gate_timer_key,
        .interval_ms = oauth_gate_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.oauth_tick),
    });
    openSystemChannel(model, fx);
    // One instrument advance so the needle has a pose to sweep from, then
    // the strings. Boot is a sweep boundary; every later refresh on this
    // path is strings-only.
    advanceInstrument(model);
    refreshStrings(model);
    startIgnition(model, fx);
}

// -------------------------------------------------- system telemetry channel

/// Open the external-source channel and launch the sampler thread that
/// feeds it. The thread owns its own `system.Sampler` (prior counters),
/// shares no mutable state with the loop, and posts a whole Snapshot per
/// reading — so the strip updates when the machine changes, not when a
/// timer fires. Under session replay the open PARKS (`live()` is false):
/// no thread spawns and the journaled readings drive the strip, keeping
/// replay offline and deterministic.
fn openSystemChannel(model: *Model, fx: *Effects) void {
    const handle = fx.openChannel(.{
        .key = system_channel_key,
        .on_event = Effects.channelMsg(.system_reading),
    });
    if (handle.live()) {
        startSystemSampler(handle) catch {
            // No producer will ever post: retire the occupancy and let
            // the 2 s sweep sample the strip instead of leaving it dead.
            fx.closeChannel(system_channel_key);
            model.system_tick_fallback = true;
            std.log.warn("system sampler thread failed to spawn — falling back to the sweep", .{});
        };
    }
    // `!handle.live()` is the replay path: the journaled events are the
    // whole stream, so the tick must NOT also sample (fallback stays false).
}

fn startSystemSampler(handle: native_sdk.ChannelHandle) std.Thread.SpawnError!void {
    const thread = try std.Thread.spawn(.{}, systemSamplerMain, .{handle});
    thread.detach();
}

/// The producer: sample every module on a fixed cadence, post the whole
/// Snapshot (a fixed-size POD — memcpy-serialized), and let the post's
/// answer be the whole protocol. `.closed` ends the occupancy (app
/// teardown or a closeChannel) and the thread returns; the
/// generation-stamped handle makes a post after close safe without a
/// join. Config filtering happens on the loop thread (mask on receipt),
/// so this stays a dumb, allocation-free sampler.
fn systemSamplerMain(handle: native_sdk.ChannelHandle) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sampler = system.Sampler.init();
    defer sampler.deinit();
    const all = system.Enabled{};
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(system_sample_interval_ms), .awake) catch return;
        const snap = sampler.sample(all);
        switch (handle.post(std.mem.asBytes(&snap))) {
            .accepted, .dropped_full => {},
            .dropped_oversized => unreachable, // a fixed-size Snapshot is far under the bound
            .closed => return,
        }
    }
}

/// Mask a producer Snapshot down to the modules the config currently
/// enables — done on the loop thread so live config reloads take effect
/// (the producer always samples everything). Meter fractions ride their
/// module: net's meter is meaningless without the net reading.
fn maskSystemSnapshot(full: system.Snapshot, enabled: config.SystemStats) system.Snapshot {
    return .{
        .cpu = if (enabled.cpu) full.cpu else null,
        .gpu = if (enabled.gpu) full.gpu else null,
        .mem = if (enabled.mem) full.mem else null,
        .disk = if (enabled.disk) full.disk else null,
        .net = if (enabled.net) full.net else null,
        .battery = if (enabled.battery) full.battery else null,
        .net_meter_frac = if (enabled.net) full.net_meter_frac else null,
        .disk_io_meter_frac = if (enabled.disk) full.disk_io_meter_frac else null,
    };
}

/// Key-on: arm the ignition sweep (display-only) and the one-shot
/// timer that steps it to the settle phase. Restartable — reopening
/// the popover mid-sweep re-anchors the whole sequence.
fn startIgnition(model: *Model, fx: *Effects) void {
    model.ignition_phase = .up;
    model.ignition_t0_ms = model.now_ms;
    fx.startTimer(.{
        .key = ignition_timer_key,
        .interval_ms = ignition_up_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.ignition_tick),
    });
}

/// Enumerate history for `only` (a subset of the enabled sources) and,
/// if anything queued, start the catch-up timer. Used at boot for every
/// enabled source and by config live-reload for newly enabled ones.
fn startCatchup(model: *Model, only: config.Sources, fx: *Effects) void {
    enumerateHistory(model, only) catch |err| {
        std.log.warn("history enumeration failed: {s}", .{@errorName(err)});
    };
    if (model.catchup_queue.len > 0) {
        model.catchup_active = true;
        model.catchup_started_ms = model.now_ms;
        fx.startTimer(.{
            .key = catchup_timer_key,
            .interval_ms = catchup_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.catchup_tick),
        });
    }
}

/// Walk the given sources' roots collecting *.jsonl paths + sizes (no
/// parsing).
fn enumerateHistory(model: *Model, only: config.Sources) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var queue: std.ArrayList(CatchupFile) = .empty;
    errdefer {
        for (queue.items) |f| model.allocator.free(f.path);
        queue.deinit(model.allocator);
    }

    var walk_arena = std.heap.ArenaAllocator.init(model.allocator);
    defer walk_arena.deinit();

    const groups = [_]struct { agent: types.Agent, roots: []const []const u8, enabled: bool }{
        .{ .agent = .claude, .roots = model.claude_roots, .enabled = only.enabled(.claude) },
        .{ .agent = .codex, .roots = model.codex_roots, .enabled = only.enabled(.codex) },
    };
    for (groups) |group| {
        if (!group.enabled) continue;
        for (group.roots) |root| {
            var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(walk_arena.allocator());
            defer walker.deinit();
            while (true) {
                const entry = (walker.next(io) catch break) orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
                const path = try std.fs.path.join(model.allocator, &.{ root, entry.path });
                const stat = dir.statFile(io, entry.path, .{}) catch {
                    model.allocator.free(path);
                    continue;
                };
                // Warm launch: a file whose restored offset already sits at
                // EOF has nothing to say — keep it out of the queue.
                const known: ?u64 = switch (group.agent) {
                    .claude => model.claude_tailer.offsetFor(path),
                    .codex => model.codex_tailer.offsetFor(path),
                    // Only claude/codex enqueue history catch-up files;
                    // tt-hr8 collectors cold-scan inline on first sweep.
                    else => unreachable,
                };
                if (known != null and known.? == stat.size) {
                    model.allocator.free(path);
                    continue;
                }
                try queue.append(model.allocator, .{ .agent = group.agent, .path = path, .size = stat.size });
            }
        }
    }
    // Oldest-first so burn/pace see history in causal order (claude
    // session files aren't date-named, but rough order beats none;
    // codex paths ARE date-ordered).
    std.mem.sort(CatchupFile, queue.items, {}, struct {
        fn lt(_: void, a: CatchupFile, b: CatchupFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    model.catchup_queue = try queue.toOwnedSlice(model.allocator);
}

/// Parse queued history files until the byte budget is spent. Runs on
/// the `catchup_interval_ms` timer (120 ms); each chunk is a few ms of
/// work, so frames land in between and the needle stays alive.
fn processCatchupChunk(model: *Model, fx: *Effects) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var budget: u64 = catchup_chunk_bytes;
    while (model.catchup_next < model.catchup_queue.len) {
        const file = model.catchup_queue[model.catchup_next];
        switch (file.agent) {
            .claude => {
                // Arena for BOTH the sink and the event strings, so the
                // chunk's whole allocation footprint dies with the arena
                // instead of charging the GPA a dupe-and-free pair for
                // every string in millions of backfilled lines. The two
                // halves move together or not at all: a ListSink on the
                // GPA plus a `...With` call would hand arena memory to
                // `ListSink.deinit`'s GPA frees.
                var sink = claude.ListSink.init(arena);
                model.claude_tailer.scanFileWith(arena, arena, io, file.path, sink.sink()) catch {};
                for (sink.events.items) |ev| ingest(model, ev);
            },
            .codex => {
                var events: std.ArrayList(types.UsageEvent) = .empty;
                defer events.deinit(arena);
                model.codex_tailer.poll(io, arena, file.path, &events) catch {};
                for (events.items) |ev| ingest(model, ev);
            },
            else => unreachable,
        }
        model.catchup_next += 1;
        if (file.size >= budget) break;
        budget -= file.size;
    }

    if (model.catchup_next >= model.catchup_queue.len) {
        model.catchup_active = false;
        fx.cancelTimer(catchup_timer_key);
        const took_ms = model.now_ms - model.catchup_started_ms;
        std.log.info("history catch-up: {d} files in {d} ms", .{ model.catchup_queue.len, took_ms });
        for (model.catchup_queue) |f| model.allocator.free(f.path);
        model.allocator.free(model.catchup_queue);
        model.catchup_queue = &.{};
        model.catchup_next = 0;
        // This pass IS the history backfill: the same walk that rebuilds
        // the ledger from the agents' own transcripts ran with the writer
        // attached, so the durable store now reaches as far back as those
        // files do. Close the gate BEFORE `saveStateNow` so it persists in
        // the same write — otherwise every boot re-seeds the store, and
        // because records are additive that double-counts rather than
        // deduping. Only claimable when a writer was actually open.
        if (model.history != null) {
            model.backfill = .{
                .backfilled = true,
                .backfill_watermark_ms = model.now_ms,
                .dict_generation = model.history.?.dictGeneration(),
            };
        }
        // Limits + a full display pass now that the ledger is complete.
        sweepOnce(model);
        saveStateNow(model);
        flushHistory(model);
    }
    // Strings only. A catch-up chunk is not a sweep: decaying the gauge
    // peak here (as the single old refresh did) burned ~66 sweeps' worth
    // of decay per second and re-ranged the dial mid-backfill.
    refreshStrings(model);
}

/// The OAuth cadence: `poll-interval` from config (seconds), floored at
/// 60s so a typo can never hammer the endpoint.
fn configuredPollMs(model: *const Model) i64 {
    return @as(i64, @max(model.cfg.poll_interval_s, 60)) * 1000;
}

pub const config_spawn_key: u64 = 8;

const config_template =
    \\# token-tach configuration — live-reloaded while the app runs.
    \\# Tray template tokens: {burn} {eta} {pct} {tok} {cost}
    \\#                       {cpu} {gpu} {mem} {disk} {net} {batt}
    \\#tray-format = {burn} → {eta}
    \\
    \\# System telemetry strip: true/false, or a module list
    \\# (cpu, gpu, mem, disk, net, battery).
    \\#system-stats = true
    \\
    \\# Server-truth Claude limits via your Claude Code OAuth token (Keychain).
    \\#claude-oauth = true
    \\#poll-interval = 180s
    \\
    \\# Register as a login item (installed app, macOS 13+). Unset = never touch it.
    \\#launch-at-login = true
    \\
    \\#alert-threshold = 70, 90
    \\#source = claude, codex, opencode
    \\#claude-config-dir = ~/some/other/claude-root
    \\#codex-home = ~/.codex
    \\#opencode-db = ~/.local/share/opencode/opencode.db
    \\
;

/// Tray "Settings": ensure the config file exists (write a fully
/// commented template on first use) and hand it to the default editor.
fn openConfig(model: *Model, fx: *Effects) void {
    if (model.config_path.len == 0) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, model.config_path, .{}) catch {
        if (std.fs.path.dirname(model.config_path)) |dir| {
            cwd.createDirPath(io, dir) catch {};
        }
        cwd.writeFile(io, .{ .sub_path = model.config_path, .data = config_template }) catch |err| {
            setErrorStatus(model, "could not create config: {s}", .{@errorName(err)});
            return;
        };
    };
    fx.spawn(.{
        .key = config_spawn_key,
        .argv = &.{ "/usr/bin/open", "-t", model.config_path },
        .output = .collect,
        .on_exit = Effects.exitMsg(.spawn_done),
    });
}

/// Save every `state_save_ticks` sweeps, only if the ledger moved.
fn maybeSaveState(model: *Model) void {
    if (model.state_save_countdown > 1) {
        model.state_save_countdown -= 1;
        return;
    }
    model.state_save_countdown = state_save_ticks;
    if (!model.state_dirty and model.ledger.all.events == model.state_saved_events) return;
    saveStateNow(model);
}

fn saveStateNow(model: *Model) void {
    if (model.state_path.len == 0) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    statefile.saveWith(model.allocator, io, model.state_path, &model.claude_tailer, &model.codex_tailer, &model.opencode_poller, fleetPtr(model), &model.ledger, model.backfill) catch |err| {
        std.log.warn("state save failed: {s}", .{@errorName(err)});
        return;
    };
    model.state_saved_events = model.ledger.all.events;
    model.state_dirty = false;
}

/// Push staged history to disk every `history_flush_ticks` sweeps, and
/// only when something is staged.
///
/// The gate keys off `history_dirty`, NOT `state_dirty`: `ingest` (the
/// claude/codex/fleet path — nearly every event) records history and
/// never sets `state_dirty`; only `ingestChange` does. Reusing that flag
/// would leave the store flushing on nothing but the writer's own minute
/// rollovers.
fn maybeFlushHistory(model: *Model) void {
    if (model.history_flush_countdown > 1) {
        model.history_flush_countdown -= 1;
        return;
    }
    model.history_flush_countdown = history_flush_ticks;
    if (model.history_dirty == 0) return;
    flushHistory(model);
}

/// Flush now. Cheap and always safe — an early flush of an additive
/// store only writes more records, never different ones.
fn flushHistory(model: *Model) void {
    if (model.history) |*writer| writer.flush();
    model.history_dirty = 0;
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => {
            model.now_ms = fx.wallMs();
            // Config live-reload rides the sweep tick: an mtime stat per
            // 2 s is free, and a newly enabled source gets the same
            // chunked history catch-up boot gives it.
            if (maybeReloadConfig(model)) |newly_enabled| {
                if (newly_enabled.any() and !model.catchup_active) {
                    startCatchup(model, newly_enabled, fx);
                }
                refreshStrings(model);
            }
            applyLaunchAtLogin(model, fx);
            // System telemetry normally arrives PUSHED through the
            // sampler channel; the sweep samples it only when that
            // channel is unavailable (spawn failed / closed / refused).
            if (model.system_tick_fallback) sampleSystem(model);
            // While catch-up owns the tailers, the steady usage sweep
            // stands down (offsets make overlap safe, but it's wasted
            // work); the instrument and the strings still advance so the
            // new system sample reaches the strip.
            if (!model.catchup_active) {
                const sweep_start_ns = native_sdk.monotonicNanoseconds();
                sweepOnce(model);
                const sweep_us = (native_sdk.monotonicNanoseconds() - sweep_start_ns) / std.time.ns_per_us;
                std.log.debug("sweep: {d} us", .{sweep_us});
                dispatchAlerts(model, fx);
                maybeSaveState(model);
                maybeFlushHistory(model);
            } else {
                // Catch-up owns the tailers, but this tick is still the
                // 2 s boundary the decay constant is written for — the
                // dial should keep ranging while months of history parse,
                // just not once per 120 ms chunk.
                advanceInstrument(model);
                refreshStrings(model);
            }
            // First OAuth poll shouldn't wait for the 30 s gate.
            if (!model.first_sweep_done) maybeOauthPoll(model, fx);
            model.first_sweep_done = true;
        },
        .catchup_tick => {
            model.now_ms = fx.wallMs();
            if (model.catchup_active) processCatchupChunk(model, fx);
        },
        .oauth_tick => {
            model.now_ms = fx.wallMs();
            maybeOauthPoll(model, fx);
        },
        .creds_done => |exit| {
            model.now_ms = fx.wallMs();
            handleCreds(model, exit, fx);
        },
        .oauth_response => |resp| {
            model.now_ms = fx.wallMs();
            handleOauthResponse(model, resp);
            dispatchAlerts(model, fx);
            refreshStrings(model);
        },
        .spawn_done => {},
        .popover_opened => {
            model.now_ms = fx.wallMs();
            startIgnition(model, fx);
        },
        .open_config => openConfig(model, fx),
        .system_reading => |event| {
            model.now_ms = fx.wallMs();
            switch (event.kind) {
                .data => {
                    // The producer posts a whole fixed-size Snapshot;
                    // guard the length so a stray payload can't misread.
                    if (event.bytes.len == @sizeOf(system.Snapshot)) {
                        const full = std.mem.bytesToValue(system.Snapshot, event.bytes[0..@sizeOf(system.Snapshot)]);
                        model.system_snap = maskSystemSnapshot(full, model.cfg.system_stats);
                        model.system_drops = event.dropped_total;
                        model.system_history.record(model.now_ms, model.system_snap);
                        // Glance only. This arm fires at 1 Hz and changes
                        // nothing but the telemetry tokens in the tray
                        // template — re-deriving three agent lines, the
                        // odometer and the status footer for it was pure
                        // waste, and journaling a needle pose here zeroed
                        // the sweep animation's delta between sweeps.
                        refreshGlance(model);
                    }
                },
                // The channel ended (teardown) or the open was refused —
                // resume sampling on the sweep so the strip stays live.
                .closed, .rejected => {
                    model.system_tick_fallback = true;
                    model.system_drops = event.dropped_total;
                },
            }
        },
        // Hover reveal is pure display: set the target (or clear it) and
        // let the rebuild re-render the footer. Cheap — hover Msgs fire
        // on containment edges, never per pointer move.
        .hover_system => |target| model.hovered_system = target,
        .hover_clear => model.hovered_system = null,
        .quit => {
            // Accessory app: the tray Quit item is the only exit
            // affordance. Flush state and history (deinit flushes, then
            // drops the store's flock so the next launch is not locked
            // out by our corpse), then leave — the runtime has no
            // graceful-shutdown API to hand back to.
            saveStateNow(model);
            deinit(model);
            std.process.exit(0);
        },
        .open_dashboard => {
            model.now_ms = fx.wallMs();
            model.dashboard_open = true;
        },
        .dashboard_closed => {
            model.dashboard_open = false;
        },
        .ignition_tick => {
            model.now_ms = fx.wallMs();
            switch (model.ignition_phase) {
                .up => {
                    model.ignition_phase = .settle;
                    fx.startTimer(.{
                        .key = ignition_timer_key,
                        .interval_ms = ignition_settle_ms,
                        .mode = .one_shot,
                        .on_fire = Effects.timerMsg(.ignition_tick),
                    });
                },
                .settle, .off => model.ignition_phase = .off,
            }
        },

        // ------------------------------------------------------ UI wave
        // Every one of these is pure display state, so they share one
        // effect-free handler — which is also what makes them testable
        // without standing up an effects channel.
        .mfd_page,
        .time_range,
        .filter_agent,
        .sort_by,
        .readout_cycle,
        .dashboard_focus,
        .alert_ack,
        .hud_toggle,
        .hud_closed,
        .chart_hover,
        .row_press,
        .trip_reset,
        => applyUxMsg(model, msg),
    }
}

/// The UI wave's messages: writes to `Model.ux` (plus the trip odometer,
/// which the UI owns the reset button for) and nothing else.
///
/// No effects and deliberately no refresh — the runtime rebuilds the view
/// after every dispatch, so a page flip is on screen by the time this
/// returns, and re-deriving display strings for a click would put tailer
/// work on the input path.
pub fn applyUxMsg(model: *Model, msg: Msg) void {
    switch (msg) {
        .mfd_page => |page| model.ux.mfd_page = page,
        .time_range => |range| model.ux.time_range = range,
        .filter_agent => |agent| model.ux.filter_agent = agent,
        // Re-sending the live column flips the direction; a new column
        // starts descending, which is the useful end of every column here.
        .sort_by => |column| {
            if (model.ux.sort_by == column) {
                model.ux.sort_desc = !model.ux.sort_desc;
            } else {
                model.ux.sort_by = column;
                model.ux.sort_desc = true;
            }
        },
        .readout_cycle => model.ux.readout = nextReadout(model.ux.readout),
        .dashboard_focus => |pane| model.ux.dashboard_focus = pane,
        .alert_ack => model.ux.alerts_acked_ms = model.now_ms,
        .hud_toggle => |panel| model.ux.hud = if (model.ux.hud == panel) .none else panel,
        // A dismissal names the panel it came from, so a late one cannot
        // close whatever the user opened in the meantime.
        .hud_closed => |panel| {
            if (model.ux.hud == panel) model.ux.hud = .none;
        },
        .chart_hover => |sample| model.ux.hover = sample,
        .row_press => |row| model.ux.selected_row = row,
        .trip_reset => {
            model.trip = .{};
            model.trip_start_ms = model.now_ms;
        },
        // Everything else is the engine's; this handler never sees them.
        else => {},
    }
}

/// The machine's current UTC offset in minutes east, from libc — a
/// synchronous read (no subprocess) so `setup` can key the ledger before
/// any history is bucketed. Falls back to UTC if localtime is unavailable.
pub fn localTzOffsetMin() i32 {
    var t: c.time_t = c.time(null);
    var tmv: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tmv) == null) return 0;
    return @intCast(@divTrunc(tmv.tm_gmtoff, 60));
}

// ------------------------------------------------------------------ sweep

fn sweepOnce(model: *Model) void {
    if (!model.ready) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Liveness ordering, documented in sessions.zig: report GROWTH first
    // and ingest EVENTS second. Growth means "a turn is in flight"; a
    // parsed event means "a turn landed" — the stronger, later
    // observation, and it must be the one that wins within a sweep.
    if (model.cfg.sources.enabled(.claude)) {
        // Arena for the sink AND the event strings — both die with the
        // sweep, so there is no `sink.deinit()` to own and no per-event
        // GPA dupe/free churn. Splitting the pair is the dangerous edit:
        // a ListSink on the GPA plus a `...With` call would hand arena
        // memory to `ListSink.deinit`'s GPA frees.
        var sink = claude.ListSink.init(arena);
        const grew = model.claude_tailer.sweepIncrementalWith(arena, arena, io, model.claude_roots, sink.sink(), model.now_ms) catch |err| blk: {
            std.log.warn("claude sweep failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        // The mid-turn signal, previously computed and thrown away: new
        // transcript bytes with no completed turn behind them is an agent
        // thinking RIGHT NOW.
        if (grew) model.roster.noteActivity(.claude, model.now_ms);
        for (sink.events.items) |ev| ingest(model, ev);
    }

    if (model.cfg.sources.enabled(.codex)) {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        defer events.deinit(arena);
        const grew = model.codex_tailer.sweepIncremental(io, arena, model.codex_roots, &events, model.now_ms) catch |err| blk: {
            std.log.warn("codex sweep failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (grew) model.roster.noteActivity(.codex, model.now_ms);
        for (events.items) |ev| ingest(model, ev);

        // Limits ride the tailer now (captured off token_count lines during
        // parse, restored from the state file) — no per-tick file re-reads.
        if (model.codex_tailer.lastLimits()) |snap| {
            const newer = if (model.codex_limits) |cur| snap.read_at_ms > cur.read_at_ms else true;
            if (newer) {
                model.walls.observe(snap);
                storeLimits(model, &model.codex_limits, snap);
            }
        }
    }

    if (model.cfg.sources.enabled(.opencode)) {
        var changes: std.ArrayList(opencode.Change) = .empty;
        defer {
            opencode.freeChanges(arena, changes.items);
            changes.deinit(arena);
        }
        model.opencode_poller.poll(arena, model.opencode_db, &changes) catch |err| {
            std.log.warn("opencode sweep failed: {s}", .{@errorName(err)});
        };
        for (changes.items) |change| ingestOpenCodeChange(model, change);
    }

    // The tt-hr8 collector fleet: JSONL tailers + SQLite pollers append
    // events, snapshot pollers append add/replace changes. Per-source
    // failures are logged inside sweep and never stall the tick.
    if (model.fleet) |*fl| {
        var events: std.ArrayList(types.UsageEvent) = .empty;
        defer events.deinit(arena);
        var changes: std.ArrayList(snapsource.Change) = .empty;
        defer {
            snapsource.freeChanges(arena, changes.items);
            changes.deinit(arena);
        }
        fl.sweep(arena, io, model.cfg.sources, model.now_ms, &events, &changes);
        for (events.items) |ev| ingest(model, ev);
        for (changes.items) |change| ingestChange(model, change.previous, change.current);
    }

    // A sweep is an instrument boundary: peak decay and needle-pose
    // journaling happen here, never on the interleaved refreshes.
    advanceInstrument(model);
    refreshStrings(model);
}

/// System telemetry: microseconds of syscalls, no subprocesses. Sampled
/// on EVERY tick — independent of usage catch-up — so the live strip is
/// present from the first frame even while months of history parse in
/// the background. Off in config clears the snapshot so the view (and
/// tray tokens) go quiet.
fn sampleSystem(model: *Model) void {
    if (model.cfg.system_stats.any()) {
        model.system_snap = model.system_sampler.sample(systemEnabled(model.cfg.system_stats));
        // The fallback path feeds the time axis too, so losing the
        // producer costs resolution (2 s instead of 1 s), not the chart.
        model.system_history.record(model.now_ms, model.system_snap);
    } else {
        model.system_snap = .{};
    }
}

/// config.SystemStats → system.Enabled, field by field (the two structs
/// mirror each other but stay decoupled).
fn systemEnabled(s: config.SystemStats) system.Enabled {
    return .{ .cpu = s.cpu, .gpu = s.gpu, .mem = s.mem, .disk = s.disk, .net = s.net, .battery = s.battery };
}

/// One priced event reaches every consumer here: the accounting ledger,
/// both burn rings, the live roster, the durable series, and the trip.
///
/// Note what this path does NOT do: set `state_dirty`. The tailers'
/// restored offsets already make the statefile's save cadence sufficient,
/// which is exactly why the history flush has its own dirty counter.
fn ingest(model: *Model, raw: types.UsageEvent) void {
    const ev = withProjectRoot(model, raw);
    const cost = model.prices.costOf(ev);
    model.ledger.add(ev, cost) catch return;
    model.burn.addTokens(ev.timestamp_ms, predict.limitWeightedTokens(ev));
    model.agent_burn.addEvent(ev);
    model.roster.record(ev, cost);
    recordHistory(model, ev, .{ .cost_usd = cost, .now_ms = model.now_ms });
    tripAdd(model, ev, cost);
}

/// Stamp `project_root` on an event: the one place cwd becomes a project.
///
/// Every consumer downstream keys or labels off `projectKey()`, so doing
/// this once here is what makes a worktree, a subdirectory and the
/// checkout itself all read as one repository. Cheap by construction — the
/// resolver memoizes per distinct cwd, so a months-long cold-start replay
/// pays for a handful of directories, not for every event.
fn withProjectRoot(model: *Model, ev: types.UsageEvent) types.UsageEvent {
    if (ev.cwd.len == 0) return ev;
    var out = ev;
    out.project_root = model.projects.rootFor(ev.cwd);
    return out;
}

/// Stage one row into the durable series. Never fails: `Writer.record`
/// swallows its own I/O errors by contract, and a store that never opened
/// is simply absent.
fn recordHistory(model: *Model, ev: types.UsageEvent, opts: history_mod.RecordOptions) void {
    if (model.history) |*writer| {
        writer.record(ev, opts);
        model.history_dirty +|= 1;
    }
}

/// Fold an event into the trip odometer.
///
/// The timestamp gate is the whole point: a cold start replays months of
/// transcripts through `ingest`, and a trip meter that counted them would
/// read as the fleet's lifetime spend under a "this session" label — the
/// single most misleading number the panel could show.
fn tripAdd(model: *Model, ev: types.UsageEvent, cost: ?f64) void {
    if (ev.timestamp_ms < model.trip_start_ms) return;
    model.trip.add(ev, cost);
}

/// Spend per hour since the trip started. Null before a minute has
/// elapsed: dividing a burst by twenty seconds yields a four-figure
/// hourly rate that is arithmetically correct and completely useless.
pub fn tripCostPerHour(model: *const Model) ?f64 {
    if (model.trip_start_ms <= 0) return null;
    const elapsed_ms = model.now_ms - model.trip_start_ms;
    if (elapsed_ms < 60_000) return null;
    return model.trip.cost_usd * 3_600_000.0 / @as(f64, @floatFromInt(elapsed_ms));
}

fn ingestOpenCodeChange(model: *Model, change: opencode.Change) void {
    ingestChange(model, change.previous, change.current);
}

/// Shared add/replace ledgering for row-shaped sources (opencode rows
/// and the fleet's snapshot pollers — same Change shape, distinct
/// types, so the helper takes the two events directly). A replace
/// feeds only the token DELTA to the burn gauge.
fn ingestChange(model: *Model, previous_raw: ?types.UsageEvent, current_raw: types.UsageEvent) void {
    const current = withProjectRoot(model, current_raw);
    const previous: ?types.UsageEvent =
        if (previous_raw) |old| withProjectRoot(model, old) else null;
    const new_cost = model.prices.costOf(current);
    if (previous) |old| {
        const old_cost = model.prices.costOf(old);
        model.ledger.replace(old, old_cost, current, new_cost) catch return;
        const delta = types.UsageEvent{
            .agent = current.agent,
            .timestamp_ms = current.timestamp_ms,
            .model = current.model,
            .input_tokens = current.input_tokens -| old.input_tokens,
            .output_tokens = current.output_tokens -| old.output_tokens,
            .cache_creation_tokens = current.cache_creation_tokens -| old.cache_creation_tokens,
            .cache_read_tokens = current.cache_read_tokens -| old.cache_read_tokens,
            .session_id = current.session_id,
            .cwd = current.cwd,
            // Carried, not re-resolved: the delta must land in the same
            // project bucket the row itself did.
            .project_root = current.project_root,
        };
        model.burn.addTokens(delta.timestamp_ms, predict.limitWeightedTokens(delta));
        model.agent_burn.addEvent(delta);
        // The roster and the trip take the DELTA for the same reason the
        // burn gauge does — a re-read row that grew by 300 tokens is 300
        // tokens of work, not a fresh copy of the whole row. The turn
        // count is still +1: for row-shaped sources an observed change IS
        // the session's next completed exchange.
        model.roster.record(delta, subCost(new_cost, old_cost));
        // History is additive, so a correction is just another record;
        // `delta` marks it as one and permits the negative cost.
        recordHistory(model, delta, .{
            .cost_usd = subCost(new_cost, old_cost),
            .delta = true,
            .now_ms = model.now_ms,
        });
        tripAdd(model, delta, subCost(new_cost, old_cost));
    } else {
        model.ledger.add(current, new_cost) catch return;
        model.burn.addTokens(current.timestamp_ms, predict.limitWeightedTokens(current));
        model.agent_burn.addEvent(current);
        model.roster.record(current, new_cost);
        recordHistory(model, current, .{ .cost_usd = new_cost, .now_ms = model.now_ms });
        tripAdd(model, current, new_cost);
    }
    model.state_dirty = true;
}

/// Cost difference for a replaced row. Null only when NEITHER side had a
/// price — an unpriced model stays unpriced rather than being recorded as
/// a free correction.
fn subCost(new_cost: ?f64, old_cost: ?f64) ?f64 {
    if (new_cost == null and old_cost == null) return null;
    return (new_cost orelse 0) - (old_cost orelse 0);
}

/// Keep our own copy of a limit snapshot (arena-born snapshots die with
/// the sweep); frees the previous copy.
fn storeLimits(model: *Model, slot: *?types.LimitSnapshot, snap: types.LimitSnapshot) void {
    const windows = model.allocator.dupe(types.LimitWindow, snap.windows) catch return;
    const plan = model.allocator.dupe(u8, snap.plan) catch {
        model.allocator.free(windows);
        return;
    };
    if (slot.*) |old| {
        model.allocator.free(old.windows);
        model.allocator.free(old.plan);
    }
    slot.* = .{ .agent = snap.agent, .read_at_ms = snap.read_at_ms, .plan = plan, .windows = windows };
}

/// Enforce the config's `launch-at-login` preference (tt-rex). Absent
/// key = never touch the OS registration. Guarded on the last pushed
/// value, so this is a no-op on every tick until the config changes.
/// A bare dev binary reports RequiresAppBundle — logged once, not an
/// error status (the packaged app is where the preference is real).
fn applyLaunchAtLogin(model: *Model, fx: *Effects) void {
    const want = model.cfg.launch_at_login orelse return;
    if (model.launch_at_login_applied == want) return;
    const services = fx.services orelse return;
    // Mark attempted either way: a failing environment (dev binary,
    // macOS < 13) will not succeed on retry, so don't retry every tick.
    model.launch_at_login_applied = want;
    services.setLaunchAtLogin(want) catch |err| {
        std.log.warn("launch-at-login = {}: not applied ({s}) — the packaged app (macOS 13+) is required", .{ want, @errorName(err) });
        return;
    };
    std.log.info("launch-at-login: {}", .{want});
}

fn dispatchAlerts(model: *Model, fx: *Effects) void {
    var snaps: [2]types.LimitSnapshot = undefined;
    var count: usize = 0;
    if (model.claude_limits) |snap| {
        snaps[count] = snap;
        count += 1;
    }
    if (model.codex_limits) |snap| {
        snaps[count] = snap;
        count += 1;
    }
    const fired = model.alerts.observe(
        model.now_ms,
        model.tz_offset_min,
        snaps[0..count],
        model.walls.nearestWall(model.now_ms),
        model.cfg.alert_thresholds,
    );
    const services = fx.services orelse return;
    for (fired) |*alert| {
        services.showNotification(.{
            .title = alert.title(),
            .subtitle = "Token Tach",
            .body = alert.body(),
        }) catch {};
    }
}

// ------------------------------------------------------------------ oauth

/// Kick a poll: acquire credentials ASYNCHRONOUSLY via Apple's
/// security(1) through the effects channel. A synchronous SecItem read
/// (keychain.zig) blocks the whole dispatch loop on macOS's keychain
/// consent dialog for unsigned binaries — the frozen-tray bug. The
/// spawn keeps any consent prompt in the child; keychain.zig remains
/// the path for signed/bundled builds whose ACL entry sticks.
fn maybeOauthPoll(model: *Model, fx: *Effects) void {
    if (!model.cfg.claude_oauth) return;
    if (model.oauth_inflight or model.now_ms < model.oauth_next_ms) return;

    model.oauth_inflight = true;
    fx.spawn(.{
        .key = creds_spawn_key,
        .argv = &.{ "/usr/bin/security", "find-generic-password", "-s", keychain.claude_service, "-w" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.creds_done),
    });
}

fn handleCreds(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    if (exit.code != 0) {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
        setErrorStatus(model, "keychain read failed (security exit {d})", .{exit.code});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(model.allocator);
    defer arena_state.deinit();
    const creds = oauth.parseCredentials(arena_state.allocator(), std.mem.trim(u8, exit.output, " \t\r\n")) catch {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
        setErrorStatus(model, "unreadable Claude credentials payload", .{});
        return;
    };
    defer std.crypto.secureZero(u8, @constCast(creds.access_token));

    if (creds.expired(model.now_ms)) {
        model.oauth_inflight = false;
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
        setErrorStatus(model, "Claude credentials expired; reopen Claude Code to refresh", .{});
        return;
    }

    if (creds.subscription_type.len > 0 and creds.subscription_type.len <= model.claude_plan_buf.len) {
        @memcpy(model.claude_plan_buf[0..creds.subscription_type.len], creds.subscription_type);
        model.claude_plan = model.claude_plan_buf[0..creds.subscription_type.len];
    }

    var auth_buf: [2048]u8 = undefined;
    defer std.crypto.secureZero(u8, &auth_buf);
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{creds.access_token}) catch {
        model.oauth_inflight = false;
        return;
    };

    fx.fetch(.{
        .key = oauth_fetch_key,
        .url = oauth.endpoint_url,
        .headers = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "anthropic-beta", .value = oauth.beta_header },
            .{ .name = "User-Agent", .value = oauth.user_agent },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.oauth_response),
    });
}

fn handleOauthResponse(model: *Model, resp: native_sdk.EffectResponse) void {
    model.oauth_inflight = false;
    if (resp.outcome == .ok and resp.status == 200) {
        const plan = model.claude_plan;
        var arena_state = std.heap.ArenaAllocator.init(model.allocator);
        defer arena_state.deinit();
        const snap = oauth.parseUsageResponse(arena_state.allocator(), resp.body, model.now_ms, plan) catch {
            model.oauth_backoff.onFailure();
            model.oauth_next_ms = model.now_ms + model.oauth_backoff.delayMs();
            setErrorStatus(model, "unparseable usage response", .{});
            return;
        };
        model.walls.observe(snap);
        storeLimits(model, &model.claude_limits, snap);
        model.oauth_backoff.onSuccess();
        model.status_error = false;
        model.oauth_last_success_ms = model.now_ms;
        model.oauth_next_ms = model.now_ms + configuredPollMs(model);
    } else {
        model.oauth_backoff.onFailure();
        model.oauth_next_ms = model.now_ms + model.oauth_backoff.delayMs();
        setErrorStatus(model, "usage endpoint: status {d} ({t})", .{ resp.status, resp.outcome });
    }
}

// ---------------------------------------------------------------- display

fn setStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
    model.status_text = std.fmt.bufPrint(&model.status_buf, fmt, args) catch model.status_text;
}

fn setErrorStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
    setStatus(model, fmt, args);
    model.status_error = true;
}

/// The tray/panel glance, served from the refresh's cache when it is
/// current for `now_ms` (see `Model.glance_cache`). The view asks five
/// times per rebuild; the answer cannot change between those asks.
pub fn glanceState(model: *const Model) trayfmt.GlanceState {
    if (model.derived_cache_ms == model.now_ms) return model.glance_cache;
    return computeGlanceState(model);
}

fn computeGlanceState(model: *const Model) trayfmt.GlanceState {
    const today = model.ledger.today(model.now_ms);
    const wall = model.walls.nearestWall(model.now_ms);
    const hot = model.walls.maxUtilization();
    return .{
        .now_ms = model.now_ms,
        .tz_offset_min = model.tz_offset_min,
        // Per-agent rings, blended. Bit-exact against the single ring
        // this used to read — same anchor, same weights, same order, with
        // each bucket summed as u64 before it becomes a float.
        .burn_tokens_per_min = model.agent_burn.totalPerMin(model.now_ms),
        .idle = model.agent_burn.isIdle(model.now_ms),
        .wall_at_ms = if (wall) |w| w.at_ms else null,
        .hot_percent = if (hot) |h| h.used_percent else null,
        .next_reset_ms = nextReset(model),
        .today_tokens = today.totalTokens(),
        .today_cost_usd = today.cost_usd,
        .cpu_frac = if (model.system_snap.cpu) |s| s.total_frac else null,
        .gpu_frac = if (model.system_snap.gpu) |s| s.device_utilization else null,
        .mem_frac = if (model.system_snap.mem) |s| s.used_frac else null,
        .disk_free_bytes = if (model.system_snap.disk) |s| s.free_bytes else null,
        .net_rx_bps = if (model.system_snap.net) |s| s.in_bytes_per_sec else null,
        .net_tx_bps = if (model.system_snap.net) |s| s.out_bytes_per_sec else null,
        .battery_frac = if (model.system_snap.battery) |s| s.charge else null,
    };
}

fn nextReset(model: *const Model) ?i64 {
    var best: ?i64 = null;
    inline for (.{ model.claude_limits, model.codex_limits }) |maybe| {
        if (maybe) |snap| {
            for (snap.windows) |w| {
                if (w.resets_at_ms > model.now_ms and (best == null or w.resets_at_ms < best.?)) {
                    best = w.resets_at_ms;
                }
            }
        }
    }
    return best;
}

// The refresh used to be ONE function called from four cadences — the
// 2 s sweep, the 1 Hz telemetry arm, the config-reload branch and the
// 30 ms catch-up chunk — while two of the things it did are only correct
// once per sweep. It is now three pieces with explicit contracts:
//
//   advanceClocks   — wall-clock only. Correct at ANY cadence, and the
//                     more often the better.
//   refreshGlance   — advance + derive + the tray line. Any cadence.
//   refreshStrings  — refreshGlance + the panel's other strings. Any
//                     cadence, just wasteful at high ones.
//   advanceInstrument — peak decay + needle pose. SWEEP BOUNDARIES ONLY
//                     (`boot`, `sweepOnce`, and the catch-up branch of
//                     the 2 s tick). Calling it anywhere else is the bug
//                     this split exists to make unrepresentable.

/// Roll every wall-clock-anchored ring forward to `now_ms`.
///
/// Advancing on the wall clock is always correct: it is what makes an
/// idle ring read zero instead of pinning its last burst under the write
/// head. `walls` in particular has been recording into its 6-hour
/// utilization history on every poll since Wave 1 with nothing ever
/// advancing it — this is the call that makes its gap detection true.
fn advanceClocks(model: *Model) void {
    model.burn.advanceTo(model.now_ms);
    model.agent_burn.advanceTo(model.now_ms);
    model.walls.advanceTo(model.now_ms);
    model.roster.advanceTo(model.now_ms);
    model.system_history.advanceTo(model.now_ms);
}

/// Journal the derived state the view asks for repeatedly.
fn refreshDerived(model: *Model) void {
    model.glance_cache = computeGlanceState(model);
    model.danger_cache = computeDangerState(model);
    model.derived_cache_ms = model.now_ms;
}

/// Advance, derive, and render the tray glance. The cheap refresh: what
/// a 1 Hz telemetry reading actually changes.
fn refreshGlance(model: *Model) void {
    advanceClocks(model);
    refreshDerived(model);
    model.glance_text = trayfmt.render(&model.glance_buf, model.cfg.tray_format, model.glance_cache);
}

/// Every display string. Safe at any cadence — nothing here is a
/// per-sweep quantity.
fn refreshStrings(model: *Model) void {
    refreshGlance(model);

    model.claude_text = agentLine(&model.claude_buf, model, .claude, model.claude_limits);
    model.codex_text = agentLine(&model.codex_buf, model, .codex, model.codex_limits);
    model.opencode_text = agentLine(&model.opencode_buf, model, .opencode, null);

    // Today's rollup rides the glance cache rather than a second
    // `ledger.today()` hash lookup for the same numbers.
    {
        var w = std.Io.Writer.fixed(&model.today_buf);
        w.writeAll("today ") catch {};
        trayfmt.writeCost(&w, model.glance_cache.today_cost_usd) catch {};
        w.writeAll(" · ") catch {};
        trayfmt.writeHumanTokens(&w, model.glance_cache.today_tokens) catch {};
        w.writeAll(" tok") catch {};
        model.today_text = w.buffered();
    }

    if (model.catchup_active) {
        setStatus(model, "scanning history… {d}/{d} files", .{ model.catchup_next, model.catchup_queue.len });
    } else if (!model.status_error) {
        if (model.ready) {
            // Dropped telemetry posts reach the footer. `system_drops`
            // was recorded and never rendered, which broke its own
            // promise that a stalled strip is honest rather than silent.
            if (model.system_drops > 0) {
                setStatus(model, "{d} events · {d} models priced · {d} telemetry drops", .{
                    model.ledger.all.events,
                    model.ledger.per_model.count(),
                    model.system_drops,
                });
            } else {
                setStatus(model, "{d} events · {d} models priced", .{ model.ledger.all.events, model.ledger.per_model.count() });
            }
        }
    }
}

/// Per-sweep instrument bookkeeping: ratchet/decay the auto-range peak
/// and journal the needle sweep (`from` = the pose the user last saw).
///
/// The only callers are the three sweep boundaries — `boot`, `sweepOnce`,
/// and the catch-up branch of the 2 s tick (which stands the usage sweep
/// down but is still the 2 s tick the decay constant is written for).
/// That restriction is the fix. Both quantities
/// here are per-sweep by construction: the decay constant is documented
/// per 2 s sweep, and `needle_from_deg` is the input to the view's 850 ms
/// sweep animation — an interleaved refresh setting `from = to` zeroes
/// the animation's delta and the needle snaps instead of sweeping.
fn advanceInstrument(model: *Model) void {
    const tpm = model.agent_burn.totalPerMin(model.now_ms);
    model.gauge_peak_tpm = @max(tpm, model.gauge_peak_tpm * peak_decay_per_sweep);
    model.needle_from_deg = model.needle_to_deg;
    model.needle_to_deg = needleDeg(tpm, gaugeScaleTpm(model.gauge_peak_tpm));
}

fn agentLine(buf: []u8, model: *const Model, agent: types.Agent, limits: ?types.LimitSnapshot) []const u8 {
    const totals = model.ledger.forAgent(agent);
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(agent.label()) catch {};
    w.writeAll("  ") catch {};
    if (!sourceEnabled(model.cfg.sources, agent)) {
        w.writeAll("disabled") catch {};
        return w.buffered();
    }
    if (agentIsEmpty(model, agent)) {
        w.writeAll(if (model.catchup_active) "scanning…" else "no sessions found") catch {};
        return w.buffered();
    }
    trayfmt.writeHumanTokens(&w, totals.totalTokens()) catch {};
    w.writeAll(" tok · ") catch {};
    trayfmt.writeCost(&w, totals.cost_usd) catch {};
    if (agent == .claude) {
        if (oauthStaleMin(model)) |mins| {
            w.writeAll(" · stale ") catch {};
            w.printInt(mins, 10, .lower, .{}) catch {};
            w.writeByte('m') catch {};
        }
    }
    if (limits) |snap| {
        for (snap.windows) |win| {
            const label: []const u8 = switch (win.kind) {
                .five_hour => " · 5h ",
                .weekly => " · wk ",
                .weekly_opus => " · opus ",
                .weekly_sonnet => " · sonnet ",
                .monthly => " · mo ",
            };
            w.writeAll(label) catch {};
            w.printInt(@as(u64, @intFromFloat(std.math.clamp(win.used_percent, 0, 100))), 10, .lower, .{}) catch {};
            w.writeByte('%') catch {};
        }
        if (snap.plan.len > 0) {
            w.writeAll(" · ") catch {};
            w.writeAll(snap.plan) catch {};
        }
    }
    return w.buffered();
}

// --------------------------------------------------- dashboard rollups
// Pure display helpers for the history dashboard window: local calendar
// math over the ledger's per-day buckets plus the subscription-value
// framing. All read-only over Model/Ledger — unit-tested below.

/// A local civil date derived from a ledger day key (days since epoch
/// in the ledger's local time; see ledger.dayKey).
pub const CivilDate = struct { year: u16, month: u8, day: u8 };

pub fn civilFromDayKey(day_key: i64) CivilDate {
    const epoch = std.time.epoch;
    const clamped: u47 = @intCast(std.math.clamp(day_key, 0, std.math.maxInt(u47)));
    const year_day = (epoch.EpochDay{ .day = clamped }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1,
    };
}

/// This local calendar month's rollup: the month the journaled clock
/// says it is (in the ledger's tz), summed from per-day buckets.
pub const MonthRollup = struct {
    year: u16,
    /// 1–12.
    month: u8,
    /// Day key of the 1st (inclusive lower bound of the bucket scan).
    first_day_key: i64,
    /// Calendar length of the month in days.
    day_count: u8,
    totals: ledger_mod.Totals,
    /// Subscription-covered (claude/codex) API-equivalent cost this
    /// month — the honest numerator for the subscription-value multiple.
    covered_cost_usd: f64,
    /// Local days this month with at least one event.
    active_days: u32,
};

pub fn monthRollup(ledger: *const ledger_mod.Ledger, now_ms: i64) MonthRollup {
    const today_key = ledger_mod.dayKey(now_ms, ledger.tz_offset_min);
    const date = civilFromDayKey(today_key);
    const first = today_key - @as(i64, date.day) + 1;
    const day_count: u8 = std.time.epoch.getDaysInMonth(date.year, @enumFromInt(date.month));
    var out: MonthRollup = .{
        .year = date.year,
        .month = date.month,
        .first_day_key = first,
        .day_count = day_count,
        .totals = .{},
        .covered_cost_usd = ledger.coveredCostInRange(first, day_count),
        .active_days = 0,
    };
    for (ledger.per_day.keys(), ledger.per_day.values()) |key, totals| {
        if (key < first or key >= first + day_count) continue;
        accumulateTotals(&out.totals, totals);
        if (totals.events > 0) out.active_days += 1;
    }
    return out;
}

/// Fill `out` with cost per local day for the trailing `out.len` days,
/// oldest first — `out[out.len - 1]` is today. Days with no bucket are 0.
pub fn trailingDailyCost(ledger: *const ledger_mod.Ledger, now_ms: i64, out: []f64) void {
    const today_key = ledger_mod.dayKey(now_ms, ledger.tz_offset_min);
    for (out, 0..) |*slot, i| {
        const key = today_key - @as(i64, @intCast(out.len - 1 - i));
        slot.* = if (ledger.per_day.get(key)) |totals| totals.cost_usd else 0;
    }
}

fn accumulateTotals(dst: *ledger_mod.Totals, src: ledger_mod.Totals) void {
    dst.input_tokens += src.input_tokens;
    dst.output_tokens += src.output_tokens;
    dst.cache_creation_tokens += src.cache_creation_tokens;
    dst.cache_read_tokens += src.cache_read_tokens;
    dst.cost_usd += src.cost_usd;
    dst.events += src.events;
}

/// A known plan's monthly price band. `lo == hi` when the plan string
/// names one price; claude "max" is ambiguous between the 5x ($100) and
/// 20x ($200) tiers — the credentials payload doesn't say which — so it
/// carries the whole band and every derived figure says so.
pub const PlanPrice = struct { lo: f64, hi: f64 };

pub fn planPrice(agent: types.Agent, plan: []const u8) ?PlanPrice {
    const eq = std.ascii.eqlIgnoreCase;
    switch (agent) {
        .claude => {
            if (eq(plan, "pro")) return .{ .lo = 20, .hi = 20 };
            if (eq(plan, "max")) return .{ .lo = 100, .hi = 200 };
        },
        .codex => {
            if (eq(plan, "plus")) return .{ .lo = 20, .hi = 20 };
            if (eq(plan, "pro")) return .{ .lo = 200, .hi = 200 };
            if (eq(plan, "free")) return .{ .lo = 0, .hi = 0 };
        },
        else => return null,
    }
    return null;
}

/// The subscription-value framing: what the ledger's usage would have
/// cost at API rates versus what the visible plans cost per month.
/// Honesty rules: the multiple divides by the plan band's HIGH end (a
/// lower bound, displayed "≥"), and an agent with usage but no
/// recognizable plan marks the figure incomplete — an understated
/// denominator would inflate the multiple, so none is claimed.
pub const SubscriptionValue = struct {
    plan_lo_usd: f64 = 0,
    plan_hi_usd: f64 = 0,
    claude_plan: []const u8 = "",
    codex_plan: []const u8 = "",
    /// Some agent contributed usage without a priceable plan string.
    incomplete: bool = false,

    /// The plan band spans two possible tiers (claude "max").
    pub fn ambiguous(self: SubscriptionValue) bool {
        return self.plan_lo_usd != self.plan_hi_usd;
    }

    /// Conservative "N× the plan" multiple: cost ÷ high end of the plan
    /// band. Null when the denominator is unknown or zero.
    pub fn multipleLowerBound(self: SubscriptionValue, api_cost_usd: f64) ?f64 {
        if (self.incomplete or self.plan_hi_usd <= 0) return null;
        return api_cost_usd / self.plan_hi_usd;
    }
};

pub fn subscriptionValue(model: *const Model) SubscriptionValue {
    var out: SubscriptionValue = .{};
    out.claude_plan = if (model.claude_plan.len > 0)
        model.claude_plan
    else if (model.claude_limits) |snap| snap.plan else "";
    out.codex_plan = if (model.codex_limits) |snap| snap.plan else "";

    const plans = [_]struct { agent: types.Agent, plan: []const u8 }{
        .{ .agent = .claude, .plan = out.claude_plan },
        .{ .agent = .codex, .plan = out.codex_plan },
    };
    for (plans) |entry| {
        const has_usage = model.ledger.forAgent(entry.agent).events > 0;
        if (planPrice(entry.agent, entry.plan)) |price| {
            out.plan_lo_usd += price.lo;
            out.plan_hi_usd += price.hi;
        } else if (has_usage) {
            out.incomplete = true;
        }
    }
    return out;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "oauth response drives backoff and snapshot state" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    defer if (model.claude_limits) |l| {
        testing.allocator.free(l.windows);
        testing.allocator.free(l.plan);
    };
    model.now_ms = 1_000_000;
    model.oauth_inflight = true;

    handleOauthResponse(&model, .{
        .key = oauth_fetch_key,
        .outcome = .ok,
        .status = 200,
        .body =
        \\{"five_hour":{"utilization":42.0,"resets_at":"2026-07-09T12:00:00Z"}}
        ,
    });
    try testing.expect(!model.oauth_inflight);
    try testing.expectEqual(@as(usize, 1), model.claude_limits.?.windows.len);
    try testing.expectEqual(model.now_ms + oauth.poll_interval_ms, model.oauth_next_ms);

    // A 429 backs off beyond the normal cadence.
    model.oauth_inflight = true;
    handleOauthResponse(&model, .{ .key = oauth_fetch_key, .outcome = .ok, .status = 429 });
    try testing.expect(model.oauth_next_ms >= model.now_ms + 180_000);
    try testing.expectEqual(@as(usize, 1), model.claude_limits.?.windows.len);
}

test "oauth staleness: fresh, stale, and no-snapshot cases" {
    var model = Model{ .allocator = testing.allocator };
    model.now_ms = 60 * 60_000;

    // No snapshot: nothing to be stale about.
    model.oauth_last_success_ms = 1;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));

    const windows = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 10 }};
    model.claude_limits = .{ .agent = .claude, .read_at_ms = 0, .windows = &windows };

    // Exactly at the threshold is still fresh.
    model.oauth_last_success_ms = model.now_ms - oauth.stale_after_ms;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));
    // Seven minutes old (threshold is five): stale, reported in minutes.
    model.oauth_last_success_ms = model.now_ms - 7 * 60_000;
    try testing.expectEqual(@as(?u64, 7), oauthStaleMin(&model));
    // Never succeeded: no tag (the "no limit data" row covers it).
    model.oauth_last_success_ms = 0;
    try testing.expectEqual(@as(?u64, null), oauthStaleMin(&model));
}

test "config live-reload: mtime change reapplies, unchanged mtime does not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config",
        .data = "tray-format = AAA\nsource = codex\n",
    });

    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    defer if (model.cfg_arena) |*a| a.deinit();
    // tmpDir paths are cwd-relative, same contract as config.load's test.
    model.config_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/config", .{tmp.sub_path});
    defer testing.allocator.free(model.config_path);

    // First observation (mtime unknown at setup): reload. Claude was
    // already enabled by default, so nothing is NEWLY enabled by v1.
    const first = maybeReloadConfig(&model) orelse return error.TestUnexpectedResult;
    try testing.expect(!first.enabled(.claude) and !first.enabled(.codex));
    try testing.expectEqualStrings("AAA", model.cfg.tray_format);
    try testing.expect(!model.cfg.sources.enabled(.claude));
    try testing.expect(model.cfg.sources.enabled(.codex));

    // Unchanged mtime: no reload, no churn.
    try testing.expectEqual(@as(?config.Sources, null), maybeReloadConfig(&model));

    // v2 re-enables claude and opts into OAuth. Rewrite until the mtime
    // observably moves (APFS is ns-resolution; one write suffices in
    // practice, the loop just removes the timing assumption).
    model.now_ms = 123_456;
    model.oauth_next_ms = 999_999_999;
    var tries: usize = 0;
    while (config.fileMtimeNs(model.config_path).? == model.config_mtime_ns.?) : (tries += 1) {
        if (tries > 10_000) return error.TestUnexpectedResult;
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "config",
            .data = "tray-format = BBB\nsource = claude, codex\nclaude-oauth = true\n",
        });
    }
    const second = maybeReloadConfig(&model) orelse return error.TestUnexpectedResult;
    try testing.expect(second.enabled(.claude));
    try testing.expect(!second.enabled(.codex));
    try testing.expectEqualStrings("BBB", model.cfg.tray_format);
    try testing.expect(model.cfg.claude_oauth);
    // Fresh opt-in reopens the poll gate immediately.
    try testing.expectEqual(model.now_ms, model.oauth_next_ms);

    // Deleted config: keep the last good values, report no reload.
    try tmp.dir.deleteFile(testing.io, "config");
    try testing.expectEqual(@as(?config.Sources, null), maybeReloadConfig(&model));
    try testing.expectEqualStrings("BBB", model.cfg.tray_format);
}

test "civil dates from day keys" {
    // 1970-01-01 is day 0.
    try testing.expectEqual(CivilDate{ .year = 1970, .month = 1, .day = 1 }, civilFromDayKey(0));
    // 2026-07-09 is day 20643 (verified against `date -j -f %F 2026-07-09 +%s` / 86400).
    try testing.expectEqual(CivilDate{ .year = 2026, .month = 7, .day = 9 }, civilFromDayKey(20_643));
    // Leap-year boundary: 2024-02-29 is day 19782, 2024-03-01 is 19783.
    try testing.expectEqual(CivilDate{ .year = 2024, .month = 2, .day = 29 }, civilFromDayKey(19_782));
    try testing.expectEqual(CivilDate{ .year = 2024, .month = 3, .day = 1 }, civilFromDayKey(19_783));
}

test "month rollup sums exactly the local calendar month" {
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();

    // 2026-07-09T12:00Z. July 2026 spans day keys 20635..20665.
    const now_ms: i64 = (20_643 * 86_400_000) + 12 * 3_600_000;
    const day_ms = 86_400_000;
    const mk = struct {
        fn ev(ts: i64, out: u64) types.UsageEvent {
            return .{ .agent = .claude, .timestamp_ms = ts, .model = "m", .output_tokens = out };
        }
    };
    // June 30 (out of month), July 1, July 9, July 31 (in month).
    try ledger.add(mk.ev(20_634 * day_ms, 1), 10.0);
    try ledger.add(mk.ev(20_635 * day_ms, 2), 1.0);
    try ledger.add(mk.ev(20_643 * day_ms, 4), 2.0);
    try ledger.add(mk.ev(20_665 * day_ms, 8), 4.0);
    // Aug 1 (out of month).
    try ledger.add(mk.ev(20_666 * day_ms, 16), 20.0);

    const rollup = monthRollup(&ledger, now_ms);
    try testing.expectEqual(@as(u16, 2026), rollup.year);
    try testing.expectEqual(@as(u8, 7), rollup.month);
    try testing.expectEqual(@as(i64, 20_635), rollup.first_day_key);
    try testing.expectEqual(@as(u8, 31), rollup.day_count);
    try testing.expectEqual(@as(u64, 14), rollup.totals.totalTokens());
    try testing.expectApproxEqAbs(@as(f64, 7.0), rollup.totals.cost_usd, 1e-9);
    try testing.expectEqual(@as(u32, 3), rollup.active_days);
}

test "month rollup respects the ledger tz offset at a month boundary" {
    // 2026-08-01T02:00Z at UTC-5 is still locally July 31.
    var ledger = ledger_mod.Ledger.init(testing.allocator, -300);
    defer ledger.deinit();
    const now_ms: i64 = 20_666 * 86_400_000 + 2 * 3_600_000;
    try ledger.add(.{ .agent = .claude, .timestamp_ms = now_ms, .model = "m", .output_tokens = 5 }, 1.5);

    const rollup = monthRollup(&ledger, now_ms);
    try testing.expectEqual(@as(u8, 7), rollup.month);
    try testing.expectApproxEqAbs(@as(f64, 1.5), rollup.totals.cost_usd, 1e-9);
}

test "month rollup covered cost excludes API-billed agents" {
    // The subscription-value multiple's numerator: only claude/codex
    // count. A fleet/opencode spend that dwarfs them must not inflate it.
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    const now_ms: i64 = (20_643 * 86_400_000) + 12 * 3_600_000;
    try ledger.add(.{ .agent = .claude, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 100.0);
    try ledger.add(.{ .agent = .codex, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 20.0);
    try ledger.add(.{ .agent = .opencode, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 2_000.0);
    try ledger.add(.{ .agent = .goose, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 900.0);

    const rollup = monthRollup(&ledger, now_ms);
    // Blended total has everyone; covered has only claude+codex.
    try testing.expectApproxEqAbs(@as(f64, 3_020.0), rollup.totals.cost_usd, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 120.0), rollup.covered_cost_usd, 1e-9);

    // The honest multiple against a $220 plan band is 0.5×, not 13.7×.
    var model = Model{ .allocator = testing.allocator };
    @memcpy(model.claude_plan_buf[0..3], "max");
    model.claude_plan = model.claude_plan_buf[0..3];
    const cw = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 1 }};
    model.codex_limits = .{ .agent = .codex, .read_at_ms = 0, .plan = "plus", .windows = &cw };
    model.ledger = ledger;
    const value = subscriptionValue(&model);
    try testing.expectApproxEqAbs(@as(f64, 120.0 / 220.0), value.multipleLowerBound(rollup.covered_cost_usd).?, 1e-9);
}

test "system snapshot round-trips through the channel byte encoding" {
    // The producer posts std.mem.asBytes(&snap); the loop decodes with
    // bytesToValue. A fixed-size POD Snapshot must survive that verbatim.
    const snap = system.Snapshot{
        .cpu = .{ .total_frac = 0.42, .core_count = 14, .load_avg_1m = 3.25, .p_cluster_frac = 0.64, .e_cluster_frac = 1.0 },
        .mem = .{ .used_bytes = 40_000_000_000, .total_bytes = 51_500_000_000, .used_frac = 0.777, .pressure = .warn },
        .net = .{ .total_bytes_in = 1, .total_bytes_out = 2, .in_bytes_per_sec = 1_230_000, .out_bytes_per_sec = 88_000 },
        .net_meter_frac = 0.4,
    };
    const bytes = std.mem.asBytes(&snap);
    try testing.expectEqual(@sizeOf(system.Snapshot), bytes.len);
    const back = std.mem.bytesToValue(system.Snapshot, bytes);
    try testing.expectEqual(snap.cpu.?.core_count, back.cpu.?.core_count);
    try testing.expectEqual(snap.cpu.?.p_cluster_frac.?, back.cpu.?.p_cluster_frac.?);
    try testing.expectEqual(snap.mem.?.pressure, back.mem.?.pressure);
    try testing.expectEqual(snap.net.?.in_bytes_per_sec.?, back.net.?.in_bytes_per_sec.?);
    try testing.expectEqual(snap.net_meter_frac.?, back.net_meter_frac.?);
    try testing.expect(back.gpu == null and back.disk == null and back.battery == null);
}

test "channel snapshot is masked to the config-enabled modules on receipt" {
    const full = system.Snapshot{
        .cpu = .{ .total_frac = 0.4, .core_count = 8, .load_avg_1m = 1, .p_cluster_frac = null, .e_cluster_frac = null },
        .gpu = .{ .device_utilization = 0.1 },
        .net = .{ .total_bytes_in = 0, .total_bytes_out = 0, .in_bytes_per_sec = 5, .out_bytes_per_sec = 6 },
        .net_meter_frac = 0.3,
    };
    // Only CPU enabled: gpu and net (and net's meter) are dropped.
    const masked = maskSystemSnapshot(full, .{ .cpu = true, .gpu = false, .mem = false, .disk = false, .net = false, .battery = false });
    try testing.expect(masked.cpu != null);
    try testing.expect(masked.gpu == null);
    try testing.expect(masked.net == null);
    try testing.expect(masked.net_meter_frac == null);
}

test "trailing daily cost fills oldest-first with zeros for silent days" {
    var ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer ledger.deinit();
    const day_ms = 86_400_000;
    const now_ms: i64 = 20_643 * day_ms + 1;
    try ledger.add(.{ .agent = .claude, .timestamp_ms = now_ms, .model = "m", .output_tokens = 1 }, 3.0);
    try ledger.add(.{ .agent = .codex, .timestamp_ms = now_ms - 2 * day_ms, .model = "m", .output_tokens = 1 }, 5.0);

    var out: [4]f64 = undefined;
    trailingDailyCost(&ledger, now_ms, &out);
    try testing.expectEqual(@as(f64, 0), out[0]);
    try testing.expectEqual(@as(f64, 5.0), out[1]);
    try testing.expectEqual(@as(f64, 0), out[2]);
    try testing.expectEqual(@as(f64, 3.0), out[3]);
}

test "plan price table" {
    try testing.expectEqual(PlanPrice{ .lo = 20, .hi = 20 }, planPrice(.claude, "pro").?);
    try testing.expectEqual(PlanPrice{ .lo = 100, .hi = 200 }, planPrice(.claude, "Max").?);
    try testing.expectEqual(PlanPrice{ .lo = 20, .hi = 20 }, planPrice(.codex, "plus").?);
    try testing.expectEqual(PlanPrice{ .lo = 200, .hi = 200 }, planPrice(.codex, "pro").?);
    try testing.expectEqual(PlanPrice{ .lo = 0, .hi = 0 }, planPrice(.codex, "free").?);
    try testing.expectEqual(@as(?PlanPrice, null), planPrice(.claude, "enterprise"));
    try testing.expectEqual(@as(?PlanPrice, null), planPrice(.codex, ""));
}

test "subscription value: bands, ambiguity, and the incomplete guard" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();

    // claude max + codex plus with usage on both.
    @memcpy(model.claude_plan_buf[0..3], "max");
    model.claude_plan = model.claude_plan_buf[0..3];
    const codex_windows = [_]types.LimitWindow{.{ .kind = .five_hour, .used_percent = 1 }};
    model.codex_limits = .{ .agent = .codex, .read_at_ms = 0, .plan = "plus", .windows = &codex_windows };
    try model.ledger.add(.{ .agent = .claude, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 100.0);
    try model.ledger.add(.{ .agent = .codex, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 10.0);
    // OpenCode contributes to the API-equivalent numerator supplied below,
    // never to the Claude/Codex subscription-plan denominator.
    try model.ledger.add(.{ .agent = .opencode, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 4_070.0);

    var value = subscriptionValue(&model);
    try testing.expectEqual(@as(f64, 120), value.plan_lo_usd);
    try testing.expectEqual(@as(f64, 220), value.plan_hi_usd);
    try testing.expect(value.ambiguous());
    try testing.expect(!value.incomplete);
    // ≥ 4180 / 220 = 19×.
    try testing.expectApproxEqAbs(@as(f64, 19.0), value.multipleLowerBound(4_180).?, 1e-9);

    // An agent with usage but no recognizable plan withdraws the claim.
    model.claude_plan = "";
    value = subscriptionValue(&model);
    try testing.expect(value.incomplete);
    try testing.expectEqual(@as(?f64, null), value.multipleLowerBound(4_180));

    // No usage from the unpriced agent: the claim stands on codex alone.
    var fresh = Model{ .allocator = testing.allocator };
    fresh.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer fresh.ledger.deinit();
    fresh.codex_limits = .{ .agent = .codex, .read_at_ms = 0, .plan = "plus", .windows = &codex_windows };
    try fresh.ledger.add(.{ .agent = .codex, .timestamp_ms = 0, .model = "m", .output_tokens = 1 }, 10.0);
    const solo = subscriptionValue(&fresh);
    try testing.expect(!solo.incomplete);
    try testing.expectEqual(@as(f64, 20), solo.plan_hi_usd);
    try testing.expect(!solo.ambiguous());
}

test "glance state reflects ledger and burn" {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    defer model.ledger.deinit();
    model.now_ms = 10 * 60_000;

    const ev = types.UsageEvent{
        .agent = .claude,
        .timestamp_ms = model.now_ms - 60_000,
        .model = "claude-fable-5",
        .output_tokens = 5000,
    };
    try model.ledger.add(ev, 1.25);
    model.burn.addTokens(ev.timestamp_ms, predict.limitWeightedTokens(ev));
    model.agent_burn.addEvent(ev);

    const glance = glanceState(&model);
    try testing.expect(!glance.idle);
    try testing.expectEqual(@as(u64, 5000), glance.today_tokens);
    try testing.expectEqual(@as(f64, 1.25), glance.today_cost_usd);
    try testing.expect(glance.burn_tokens_per_min > 0);
}

// ---------------------------------------------------- wave-2 activation

/// A Model wired far enough to run the refresh path: a real ledger and a
/// real price db, no tailers (nothing below sweeps files).
fn testModel() !Model {
    var model = Model{ .allocator = testing.allocator };
    model.ledger = ledger_mod.Ledger.init(testing.allocator, 0);
    model.prices = try pricing.Db.init(testing.allocator);
    model.ready = true;
    return model;
}

fn testModelDeinit(model: *Model) void {
    model.ledger.deinit();
    model.prices.deinit();
}

test "the gauge peak decays once per sweep, not once per refresh" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 100 * 60_000;
    model.gauge_peak_tpm = 100_000;

    // A sweep boundary is one decay step.
    advanceInstrument(&model);
    const after_one_sweep = model.gauge_peak_tpm;
    try testing.expectApproxEqAbs(100_000 * peak_decay_per_sweep, after_one_sweep, 1e-9);

    // THE BUG: peak decay used to live in the single `refreshDisplay`,
    // which the 1 Hz telemetry arm, the config-reload branch and the
    // 30 ms catch-up chunk all called too. A hundred string refreshes
    // between sweeps must move the dial's auto-range by exactly nothing.
    for (0..50) |_| refreshStrings(&model);
    for (0..50) |_| refreshGlance(&model);
    try testing.expectEqual(after_one_sweep, model.gauge_peak_tpm);

    // The next real sweep decays once more, not a hundred times.
    advanceInstrument(&model);
    try testing.expectApproxEqAbs(after_one_sweep * peak_decay_per_sweep, model.gauge_peak_tpm, 1e-9);
}

test "a string refresh never journals a needle pose" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 100 * 60_000;

    // `needle_from_deg` is the input to view.zig's 850 ms sweep
    // animation. Interleaved refreshes setting from = to collapsed the
    // animation delta to zero between sweeps, so the needle snapped.
    model.needle_from_deg = -120;
    model.needle_to_deg = -20;
    for (0..10) |_| refreshStrings(&model);
    try testing.expectEqual(@as(f32, -120), model.needle_from_deg);
    try testing.expectEqual(@as(f32, -20), model.needle_to_deg);

    // Only a sweep advances the pose, and it carries the old target
    // forward as the new origin.
    advanceInstrument(&model);
    try testing.expectEqual(@as(f32, -20), model.needle_from_deg);
}

test "the refresh advances every wall-clock ring, the wall tracker included" {
    var model = try testModel();
    defer testModelDeinit(&model);

    const t0: i64 = 1_000 * 60_000;
    model.now_ms = t0;

    model.walls.observe(.{ .agent = .claude, .read_at_ms = t0, .windows = &.{
        .{ .kind = .five_hour, .used_percent = 40 },
    } });
    model.burn.addTokens(t0, 50_000);
    model.agent_burn.addTokens(.claude, t0, 50_000);
    model.roster.record(.{
        .agent = .claude,
        .timestamp_ms = t0,
        .model = "claude-fable-5",
        .session_id = "s1",
        .output_tokens = 50_000,
    }, 1.0);
    model.system_history.record(t0, .{ .cpu = .{
        .total_frac = 0.5,
        .core_count = 8,
        .load_avg_1m = 1,
        .p_cluster_frac = null,
        .e_cluster_frac = null,
    } });

    var curve: [predict.WindowPace.history_buckets]?f32 = undefined;
    try testing.expectEqual(
        @as(?f32, 40),
        model.walls.paceFor(.claude, .five_hour).?.utilizationHistory(&curve)[predict.WindowPace.history_buckets - 1],
    );

    // Ten hours later with nothing observed. `walls.observe` has been
    // feeding predict's 6 h utilization history since Wave 1 with NOTHING
    // ever advancing it, so a ten-hour-old reading sat under the write
    // head reading as current.
    model.now_ms = t0 + 10 * 60 * 60_000;
    refreshStrings(&model);

    for (model.walls.paceFor(.claude, .five_hour).?.utilizationHistory(&curve)) |v| {
        try testing.expectEqual(@as(?f32, null), v);
    }
    try testing.expectEqual(@as(f64, 0), model.burn.tokensPerMin(model.now_ms));
    try testing.expectEqual(@as(f64, 0), model.agent_burn.totalPerMin(model.now_ms));
    try testing.expectEqual(@as(f64, 0), model.roster.find(.claude, "s1").?.tokensPerMin());
    try testing.expect(model.system_history.cpu.isEmpty());

    // Advancing must not fabricate activity: the session is still there,
    // still costed, just no longer burning.
    try testing.expectEqual(@as(u64, 1), model.roster.find(.claude, "s1").?.turns());
}

test "per-agent burn drives the needle at exactly the legacy blended value" {
    var model = try testModel();
    defer testModelDeinit(&model);

    const t0: i64 = 2_000 * 60_000;
    const stream = [_]types.UsageEvent{
        .{ .agent = .claude, .timestamp_ms = t0, .model = "claude-fable-5", .output_tokens = 1_200 },
        .{ .agent = .codex, .timestamp_ms = t0 + 30_000, .model = "gpt-5.2-codex", .input_tokens = 4_000 },
        .{ .agent = .claude, .timestamp_ms = t0 + 90_000, .model = "claude-fable-5", .cache_read_tokens = 90_000 },
        .{ .agent = .gemini, .timestamp_ms = t0 + 200_000, .model = "gemini-3-pro", .output_tokens = 777 },
    };
    for (stream) |ev| ingest(&model, ev);

    model.now_ms = t0 + 240_000;
    refreshStrings(&model);

    // Bit-exact, not approximately equal. Swapping the Model's single
    // blended ring for per-agent rings must not move the needle by a
    // token — same anchor, same weights, same order, each bucket summed
    // as u64 before the float divide.
    const legacy = model.burn.tokensPerMin(model.now_ms);
    try testing.expectEqual(legacy, model.agent_burn.totalPerMin(model.now_ms));
    try testing.expectEqual(legacy, glanceState(&model).burn_tokens_per_min);
    try testing.expectEqual(model.burn.isIdle(model.now_ms), model.agent_burn.isIdle(model.now_ms));

    // And the split the blended ring could never answer.
    try testing.expectEqual(types.Agent.claude, model.agent_burn.hottest(model.now_ms).?.agent);
    try testing.expect(model.agent_burn.tokensPerMin(.codex, model.now_ms) > 0);
    try testing.expectEqual(@as(f64, 0), model.agent_burn.tokensPerMin(.kimi, model.now_ms));

    // Still exact after the rings have been rolled forward on wall time.
    model.now_ms = t0 + 8 * 60_000;
    refreshStrings(&model);
    try testing.expectEqual(model.burn.tokensPerMin(model.now_ms), model.agent_burn.totalPerMin(model.now_ms));
}

test "ingest reaches the roster, and a landed turn beats reported growth" {
    var model = try testModel();
    defer testModelDeinit(&model);

    const t0: i64 = 3_000 * 60_000;
    model.now_ms = t0;

    // Growth first, events second — the order sweepOnce uses.
    model.roster.noteActivity(.claude, t0);
    try testing.expect(model.roster.activity(t0) == .running);

    ingest(&model, .{
        .agent = .claude,
        .timestamp_ms = t0,
        .model = "claude-fable-5",
        .session_id = "sess-a",
        .cwd = "/Users/me/workspace/token-tach",
        .output_tokens = 2_000,
    });
    ingest(&model, .{
        .agent = .codex,
        .timestamp_ms = t0,
        .model = "gpt-5.2-codex",
        .session_id = "sess-b",
        .output_tokens = 500,
    });

    const claude_row = model.roster.find(.claude, "sess-a").?;
    try testing.expectEqual(@as(u64, 1), claude_row.turns());
    try testing.expectEqualStrings("token-tach", claude_row.project());
    try testing.expect(claude_row.isRunning(t0));
    // A parsed event is the stronger, later observation: the turn LANDED,
    // so the mid-turn flag growth set must be cleared.
    try testing.expect(!claude_row.mid_turn);
    try testing.expectEqual(@as(usize, 2), model.roster.activeCount(t0));

    // Growth reported after the event puts the row back in flight.
    model.roster.noteActivity(.claude, t0 + 1_000);
    try testing.expect(model.roster.find(.claude, "sess-a").?.mid_turn);

    // And the trip odometer counted both events, since both landed after
    // the trip started.
    model.trip_start_ms = t0 - 1;
    try testing.expectEqual(@as(u64, 2), model.trip.events);
}

test "the trip odometer ignores backfill and only rates a real interval" {
    var model = try testModel();
    defer testModelDeinit(&model);

    const launch: i64 = 4_000 * 60_000;
    model.trip_start_ms = launch;
    model.now_ms = launch;

    // A cold start replays months of transcripts through the same
    // `ingest`. None of it belongs to this trip.
    ingest(&model, .{
        .agent = .claude,
        .timestamp_ms = launch - 90 * 24 * 60 * 60_000,
        .model = "claude-fable-5",
        .output_tokens = 5_000_000,
    });
    try testing.expectEqual(@as(u64, 0), model.trip.events);
    try testing.expectEqual(@as(u64, 0), model.trip.totalTokens());
    // Under a minute in, an hourly rate is arithmetic, not information.
    model.now_ms = launch + 30_000;
    try testing.expectEqual(@as(?f64, null), tripCostPerHour(&model));

    // Live traffic does count.
    ingest(&model, .{
        .agent = .claude,
        .timestamp_ms = launch + 10_000,
        .model = "claude-fable-5",
        .output_tokens = 1_000,
    });
    try testing.expectEqual(@as(u64, 1), model.trip.events);

    model.now_ms = launch + 30 * 60_000;
    model.trip.cost_usd = 3.0;
    try testing.expectApproxEqAbs(@as(f64, 6.0), tripCostPerHour(&model).?, 1e-9);
}

test "derived state is cached per journaled clock, never across one" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 500 * 60_000;

    try model.ledger.add(.{
        .agent = .claude,
        .timestamp_ms = model.now_ms,
        .model = "claude-fable-5",
        .output_tokens = 1_000,
    }, 2.50);
    refreshStrings(&model);
    try testing.expectEqual(@as(f64, 2.50), glanceState(&model).today_cost_usd);

    // A ledger write behind the cache's back within the same tick is
    // deliberately not seen — the refresh is the journaling point.
    try model.ledger.add(.{
        .agent = .codex,
        .timestamp_ms = model.now_ms,
        .model = "gpt-5.2-codex",
        .output_tokens = 1,
    }, 1.00);
    try testing.expectEqual(@as(f64, 2.50), glanceState(&model).today_cost_usd);

    // Moving the clock invalidates it, so a Model whose clock advanced
    // without a refresh (a hand-built one, an update arm that only
    // bumped now_ms) recomputes rather than serving a stale answer.
    model.now_ms += 1;
    try testing.expectEqual(@as(f64, 3.50), glanceState(&model).today_cost_usd);
    refreshStrings(&model);
    try testing.expectEqual(@as(f64, 3.50), model.glance_cache.today_cost_usd);
}

test "dropped telemetry posts reach the status line" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 600 * 60_000;

    refreshStrings(&model);
    try testing.expect(std.mem.indexOf(u8, model.status_text, "models priced") != null);
    try testing.expect(std.mem.indexOf(u8, model.status_text, "drops") == null);

    // A stalled strip must say so; `system_drops` was recorded and never
    // rendered, which broke its own doc comment's promise.
    model.system_drops = 7;
    refreshStrings(&model);
    try testing.expect(std.mem.indexOf(u8, model.status_text, "7 telemetry drops") != null);
    // scripts/verify greps the status line for this substring.
    try testing.expect(std.mem.indexOf(u8, model.status_text, "models priced") != null);
}

test "system telemetry gets a time axis, with gaps for disabled modules" {
    var model = try testModel();
    defer testModelDeinit(&model);

    const t0: i64 = 700 * 60_000;
    var i: i64 = 0;
    while (i < 12) : (i += 1) {
        const ts = t0 + i * SystemHistory.period_ms;
        model.system_history.record(ts, .{
            .cpu = .{ .total_frac = 0.1 * @as(f64, @floatFromInt(i)), .core_count = 8, .load_avg_1m = 1, .p_cluster_frac = null, .e_cluster_frac = null },
        });
    }

    var curve: [SystemHistory.buckets]?f32 = undefined;
    const cpu_curve = model.system_history.cpu.snapshot(&curve);
    try testing.expectEqual(SystemHistory.buckets, cpu_curve.len);
    try testing.expectApproxEqAbs(@as(f32, 1.1), cpu_curve[cpu_curve.len - 1].?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), cpu_curve[cpu_curve.len - 12].?, 1e-6);
    // Before the sampler was running is a GAP, not 0% — a chart must be
    // able to tell "idle machine" from "we were not looking".
    try testing.expectEqual(@as(?f32, null), cpu_curve[cpu_curve.len - 13]);
    // GPU was never enabled in these readings: no series at all.
    try testing.expect(model.system_history.gpu.isEmpty());
    try testing.expectEqual(SystemHistory.span_ms, 30 * 60_000);
}

test "the history flush gate keys off its own dirty counter, not state_dirty" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 800 * 60_000;

    // No writer opened: the whole path must be inert, never a crash and
    // never a stuck dirty counter.
    model.history_dirty = 0;
    model.history_flush_countdown = 1;
    maybeFlushHistory(&model);
    try testing.expectEqual(history_flush_ticks, model.history_flush_countdown);

    // `ingest` — the claude/codex/fleet path, i.e. nearly every event —
    // records history and deliberately never sets `state_dirty`. A flush
    // gated on that flag would essentially never fire.
    ingest(&model, .{
        .agent = .claude,
        .timestamp_ms = model.now_ms,
        .model = "claude-fable-5",
        .output_tokens = 10,
    });
    try testing.expect(!model.state_dirty);

    // The countdown spends `history_flush_ticks` sweeps before firing.
    model.history_dirty = 5;
    model.history_flush_countdown = history_flush_ticks;
    for (0..history_flush_ticks - 1) |_| maybeFlushHistory(&model);
    try testing.expectEqual(@as(u32, 5), model.history_dirty);
    maybeFlushHistory(&model);
    try testing.expectEqual(@as(u32, 0), model.history_dirty);
    try testing.expectEqual(history_flush_ticks, model.history_flush_countdown);
}

test "UI-wave messages move only the ux sub-struct" {
    var model = try testModel();
    defer testModelDeinit(&model);
    model.now_ms = 900 * 60_000;

    // Re-sending the current sort column flips direction; a new column
    // resets to descending.
    try testing.expect(model.ux.sort_desc);
    applyUxMsg(&model, .{ .sort_by = .cost });
    try testing.expect(!model.ux.sort_desc);
    applyUxMsg(&model, .{ .sort_by = .name });
    try testing.expectEqual(SortColumn.name, model.ux.sort_by);
    try testing.expect(model.ux.sort_desc);

    // A HUD toggle is idempotent-to-closed; a dismissal that names a
    // different panel cannot close the one the user just opened.
    applyUxMsg(&model, .{ .hud_toggle = .alerts });
    try testing.expectEqual(HudPanel.alerts, model.ux.hud);
    applyUxMsg(&model, .{ .hud_closed = .help });
    try testing.expectEqual(HudPanel.alerts, model.ux.hud);
    applyUxMsg(&model, .{ .hud_toggle = .alerts });
    try testing.expectEqual(HudPanel.none, model.ux.hud);

    applyUxMsg(&model, .{ .mfd_page = .sessions });
    try testing.expectEqual(MfdPage.sessions, model.ux.mfd_page);
    applyUxMsg(&model, .{ .chart_hover = .{ .chart = 2, .sample = 41 } });
    try testing.expectEqual(@as(u16, 41), model.ux.hover.?.sample);
    applyUxMsg(&model, .{ .chart_hover = null });
    try testing.expectEqual(@as(?ChartHover, null), model.ux.hover);

    // The readout cycles rather than storing an index, so a new mode
    // needs no edit in the update arm.
    const first = model.ux.readout;
    for (0..std.enums.values(ReadoutMode).len) |_| applyUxMsg(&model, .readout_cycle);
    try testing.expectEqual(first, model.ux.readout);

    // And none of it touched the instrument.
    try testing.expectEqual(@as(f64, 0), model.gauge_peak_tpm);
    try testing.expectEqual(@as(u64, 0), model.ledger.all.events);
}
