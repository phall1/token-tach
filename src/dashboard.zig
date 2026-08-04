//! History dashboard window: the instrument's analytical bench.
//! Same cabin materials, telemetry inks and compact labeling as the
//! popover cluster — but where the dial answers "how fast, right now",
//! this window answers "over what span, attributed to whom".
//!
//! FLOW LAYOUT, deliberately. The cluster in `view.zig` is absolute
//! because its needle rotates about a fixed pivot (see view.zig:7-13);
//! nothing here rotates, and this window is declared resizable with a
//! 820x560 floor. Every rect used to be measured against a constant
//! `window_width`, so the right column clipped below 920pt and left
//! dead margin above it, and two "aligned" grids seamed 24pt apart.
//! The whole tree is now columns, rows, a split and scroll regions, so
//! the layout IS the constraint solver and a resize cannot desync it.
//!
//! ONE TIME BASE PER PANEL, AND IT SAYS SO. The old panel mixed
//! month-to-date (hero), trailing-30-days (bars) and all-time (share +
//! both tables) with no labels, so three numbers that looked
//! comparable were not. Every card here carries its own scope tag, and
//! the header's segmented control moves the ones that can move.
//!
//! WHAT IS STILL ALL-TIME, AND WHY. `ledger.per_model` /
//! `per_project` have no time dimension at all — the ledger keeps a
//! single lifetime rollup per key — so those two tables are tagged
//! ALL-TIME rather than quietly re-labelled with the selected range.
//! Per-agent totals ARE range-scoped, but only out of `per_hour`,
//! which retains 14 local days; spans wider than that fall back to the
//! lifetime split and say so in the tag.
//!
//! SIX NUMBERED SECTIONS, 01 THROUGH 06. The KPI strip used to be the
//! one unnumbered band on a page whose other five panels all carried an
//! index, which reads as an omission rather than a hierarchy. It is
//! section 01 now and carries the month line that used to crowd the
//! title bar.
//!
//! HEIGHTS: TWO FIXED BANDS, TWO ELASTIC ONES. `01` and `06` are
//! readouts — a label, a number and a trace each — so their height is a
//! constant. The chart/fleet split and the two tables are *lists*, and
//! lists want whatever is left, so they share the remainder by weight.
//! That is what keeps the window honest between its 560pt floor and a
//! full-screen desktop instead of pinning 400pt of tables under a
//! squeezed chart.

const std = @import("std");
const native_sdk = @import("native_sdk");

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const types = @import("core/types.zig");
const ledger_mod = @import("core/ledger.zig");
const sessions_mod = @import("core/sessions.zig");
const trayfmt = @import("core/trayfmt.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Color = canvas.Color;

pub const Model = engine.Model;
pub const Msg = engine.Msg;
pub const Ui = canvas.Ui(Msg);

pub const window_label = "dashboard";
pub const canvas_label = "dashboard-canvas";
pub const window_width: f32 = 960;
/// Six bands need more than 700pt: at that height the machine strip
/// could only be paid for out of the chart, which is the panel that
/// earns the window. 800 still clears a 900pt-tall laptop screen with
/// the menu bar and title bar taken out, and everything below `header`
/// flexes anyway (see `split_weight` / `table_weight`), so the declared
/// 560pt floor composes too.
pub const window_height: f32 = 800;

const pad: f32 = 18;
const gap: f32 = 12;
const card_pad: f32 = 13;

/// How the two elastic bands divide whatever the fixed ones leave. The
/// chart/fleet split leads because it carries the page's headline
/// reading; the tables trail because they scroll and a short table is
/// still a usable table.
const split_weight: f32 = 1.65;
const table_weight: f32 = 1.15;

const agent_count = @typeInfo(types.Agent).@"enum".fields.len;

// ------------------------------------------------------- node budgeting
// The SDK fails a frame at RUNTIME past 1024 widget nodes per view, so
// every unbounded list here is bounded HERE, next to the reason, rather
// than discovered as a blank window. Measured on the saturated frame
// the budget test builds — all 14 agents, both tables past their caps,
// a full roster, every telemetry lane live — the window costs 591 nodes
// / 798 draw commands / 1314 chart path elements against 1024 / 2048 /
// 2048. The caps exist so those numbers cannot grow with the user's
// history. No anchored surfaces and no loop animations.
//
// THE PATH-ELEMENT BUDGET IS THE TIGHT ONE, and it is the machine
// strip's: a filled line series costs `2n + 3` elements, so six lanes
// alone would blow it at the SDK's 256-point downsample ceiling. See
// `lane_points`.
//
// Rows past a cap are never dropped silently — that was the old
// panel's real bug. Each capped list renders a "+N more" line carrying
// the remainder's cost, so the total on screen still reconciles.

/// Rows rendered per model/project table (8 nodes each).
const max_table_rows: usize = 20;
/// Rows rendered in the live-sessions pane (6 nodes each).
const max_session_rows: usize = 14;
/// Widest bar chart the window ever draws — also the stack budget for
/// the per-bucket scratch below.
const max_buckets: usize = 90;
/// Agent inks in the attribution rail before the tail collapses into
/// one "other" segment.
const max_rail_segments: usize = 6;

// ------------------------------------------------------------- scoping

/// One selectable span, and everything the panels need to describe it
/// honestly.
///
/// `agent_exact` is the load-bearing field: per-agent totals come from
/// `ledger.per_hour`, which retains `hour_retention_days` (14) days.
/// Asking it for a 30- or 90-day split would silently under-report the
/// older weeks, so those spans fall back to the lifetime rollup and the
/// tag changes with them.
const Scope = struct {
    range: engine.TimeRange,
    unit: ledger_mod.Unit,
    buckets: usize,
    /// Segmented-control label.
    seg: []const u8,
    /// Chart card title.
    title: []const u8,
    /// Compact scope tag stamped on every card that honours the range.
    tag: []const u8,
    /// What one bar covers, for the axis caption.
    bucket_noun: []const u8,
    agent_exact: bool,
};

/// The spans the dashboard offers. `TimeRange.live` is deliberately
/// absent: it is the popover's own sub-minute window, and the ledger's
/// finest bucket is an hour — a LIVE segment here could only ever draw
/// one bar. `scopeIndex` folds it onto the default instead.
const scopes = [_]Scope{
    .{ .range = .hour, .unit = .hour, .buckets = 12, .seg = "12H", .title = "02 / 12-HOUR API-EQUIVALENT COST", .tag = "12H", .bucket_noun = "hour", .agent_exact = true },
    .{ .range = .day, .unit = .hour, .buckets = 24, .seg = "24H", .title = "02 / 24-HOUR API-EQUIVALENT COST", .tag = "24H", .bucket_noun = "hour", .agent_exact = true },
    .{ .range = .week, .unit = .day, .buckets = 7, .seg = "7D", .title = "02 / 7-DAY API-EQUIVALENT COST", .tag = "7D", .bucket_noun = "day", .agent_exact = true },
    .{ .range = .month, .unit = .day, .buckets = 30, .seg = "30D", .title = "02 / 30-DAY API-EQUIVALENT COST", .tag = "30D", .bucket_noun = "day", .agent_exact = false },
    .{ .range = .all, .unit = .day, .buckets = 90, .seg = "90D", .title = "02 / 90-DAY API-EQUIVALENT COST", .tag = "90D", .bucket_noun = "day", .agent_exact = false },
};

/// Trailing 30 days: the widest span whose bars are still individually
/// readable, and the one the panel has always opened on.
const default_scope: usize = 3;

fn scopeIndex(range: engine.TimeRange) usize {
    for (scopes, 0..) |scope, i| {
        if (scope.range == range) return i;
    }
    return default_scope;
}

// --------------------------------------------------------- frame digest
// Everything the panels read, derived ONCE per rebuild. This window
// rebuilds on every Msg (>= 1 Hz), and the old file paid for that twice
// over: `engine.monthRollup` ran in both the header and the hero — two
// full scans of `per_day` plus two of `covered_per_day` — and
// `topTable` called `rowsTotalCost` inside its per-row loop, an O(n^2)
// rescan of every model and project on every frame.

const Frame = struct {
    scope: Scope,
    /// Cost per bucket, oldest first, with the still-filling final
    /// bucket zeroed — it renders as `partial` instead.
    cost: []f32,
    /// Zero everywhere except the final bucket: the amber "still
    /// filling" bar, drawn over the same slot the accent series left
    /// empty, so today never reads as a completed day.
    partial: []f32,
    /// Tokens per bucket — the KPI sparkline.
    tokens: []f32,
    /// One x-axis label per bucket; the renderer thins them to fit.
    labels: []const []const u8,
    totals: ledger_mod.Totals,
    peak: f64,
    agents: std.EnumArray(types.Agent, ledger_mod.Totals),
    /// False when `agents` is the lifetime rollup rather than the range.
    agents_scoped: bool,
    month: engine.MonthRollup,
    value: engine.SubscriptionValue,
    /// The hourly series holds nothing but the ledger does: a warm
    /// restart, since `per_hour` is not persisted. Saying so beats an
    /// empty chart that looks like an idle machine.
    hourly_cold: bool,
};

fn computeFrame(ui: *Ui, model: *const Model) Frame {
    const scope = scopes[scopeIndex(model.ux.time_range)];
    const n = scope.buckets;
    const tz = model.ledger.tz_offset_min;

    var raw: [max_buckets]ledger_mod.Totals = @splat(.{});
    model.ledger.trailing(scope.unit, model.now_ms, raw[0..n]);

    const cost = ui.arena.alloc(f32, n) catch return failedFrame(ui, scope, model);
    const partial = ui.arena.alloc(f32, n) catch return failedFrame(ui, scope, model);
    const tokens = ui.arena.alloc(f32, n) catch return failedFrame(ui, scope, model);
    const labels = ui.arena.alloc([]const u8, n) catch return failedFrame(ui, scope, model);

    const newest: i64 = switch (scope.unit) {
        .hour => ledger_mod.hourKey(model.now_ms, tz),
        .day => ledger_mod.dayKey(model.now_ms, tz),
    };

    var totals: ledger_mod.Totals = .{};
    var peak: f64 = 0;
    for (raw[0..n], 0..) |bucket, i| {
        const last = i == n - 1;
        cost[i] = if (last) 0 else @floatCast(bucket.cost_usd);
        partial[i] = if (last) @floatCast(bucket.cost_usd) else 0;
        tokens[i] = @floatFromInt(bucket.totalTokens());
        peak = @max(peak, bucket.cost_usd);
        accumulate(&totals, bucket);
        const key = newest - @as(i64, @intCast(n - 1 - i));
        labels[i] = switch (scope.unit) {
            // Local hour of day: `hourKey` is already tz-shifted, so the
            // remainder IS the wall-clock hour the bucket covers.
            .hour => ui.fmt("{d:0>2}", .{@as(u64, @intCast(@mod(key, ledger_mod.hours_per_day)))}),
            .day => blk: {
                const date = engine.civilFromDayKey(key);
                break :blk ui.fmt("{d}/{d}", .{ date.month, date.day });
            },
        };
    }

    const from_ms: i64 = switch (scope.unit) {
        .hour => ledger_mod.hourStartMs(newest - @as(i64, @intCast(n - 1)), tz),
        .day => ledger_mod.dayStartMs(newest - @as(i64, @intCast(n - 1)), tz),
    };
    const to_ms: i64 = switch (scope.unit) {
        .hour => ledger_mod.hourStartMs(newest + 1, tz),
        .day => ledger_mod.dayStartMs(newest + 1, tz),
    };

    return .{
        .scope = scope,
        .cost = cost,
        .partial = partial,
        .tokens = tokens,
        .labels = labels,
        .totals = totals,
        .peak = peak,
        .agents = if (scope.agent_exact)
            model.ledger.agentsInRange(from_ms, to_ms)
        else
            model.ledger.per_agent,
        .agents_scoped = scope.agent_exact,
        .month = engine.monthRollup(&model.ledger, model.now_ms),
        .value = engine.subscriptionValue(model),
        .hourly_cold = scope.unit == .hour and totals.events == 0 and model.ledger.all.events > 0,
    };
}

/// Arena exhaustion: `ui.failed` is already latched, so the tree is
/// discarded — this only has to be a value the builders can walk
/// without indexing empty slices.
fn failedFrame(ui: *Ui, scope: Scope, model: *const Model) Frame {
    ui.failed = true;
    return .{
        .scope = scope,
        .cost = &.{},
        .partial = &.{},
        .tokens = &.{},
        .labels = &.{},
        .totals = .{},
        .peak = 0,
        .agents = .initFill(.{}),
        .agents_scoped = false,
        .month = engine.monthRollup(&model.ledger, model.now_ms),
        .value = .{},
        .hourly_cold = false,
    };
}

fn accumulate(dst: *ledger_mod.Totals, src: ledger_mod.Totals) void {
    dst.input_tokens += src.input_tokens;
    dst.output_tokens += src.output_tokens;
    dst.cache_creation_tokens += src.cache_creation_tokens;
    dst.cache_read_tokens += src.cache_read_tokens;
    dst.cost_usd += src.cost_usd;
    dst.events += src.events;
}

// ---------------------------------------------------------------- view

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    const frame = computeFrame(ui, model);
    return ui.column(.{
        .grow = 1,
        .padding = pad,
        .gap = gap,
        .style = .{ .background = theme.bg, .radius = 0 },
        .semantics = .{ .label = "Token Tach dashboard" },
    }, .{
        header(ui, model),
        kpiSection(ui, model, &frame),
        mainSplit(ui, model, &frame),
        detailRow(ui, model),
        systemRow(ui, model),
    });
}

fn header(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .height = 30, .gap = 10, .cross = .center }, .{
        ui.paragraph(.{
            .semantics = .{ .label = "Token Tach history dashboard" },
        }, &.{
            .{ .text = "TOKEN", .weight = .bold, .monospace = true, .scale = 1.3, .color = .text },
            .{ .text = " TACH", .weight = .bold, .monospace = true, .scale = 1.3, .color = .accent },
            .{ .text = " / LEDGER", .weight = .medium, .monospace = true, .scale = 1.0, .color = .text_muted },
        }),
        ui.spacer(1),
        rangeControl(ui, model),
    });
}

/// The control that turns `Msg.time_range` on. Every panel that can be
/// scoped reads `model.ux.time_range`; nothing emitted it before this.
fn rangeControl(ui: *Ui, model: *const Model) Ui.Node {
    const active = scopeIndex(model.ux.time_range);
    var segments: [scopes.len]Ui.Node = undefined;
    for (scopes, 0..) |scope, i| {
        segments[i] = ui.el(.segmented_control, .{
            .key = .{ .int = @intCast(i) },
            .text = scope.seg,
            .size = .sm,
            .selected = i == active,
            .on_press = .{ .time_range = scope.range },
            .semantics = .{ .label = ui.fmt("Scope the dashboard to {s}", .{scope.seg}) },
        }, .{});
    }
    const nodes: []const Ui.Node = &segments;
    return ui.el(.tabs, .{
        .gap = 2,
        .semantics = .{ .label = "Dashboard time range" },
    }, nodes);
}

// ------------------------------------------------------------- KPI row

/// Section 01. The five cards are five different time bases on purpose
/// — that is what the per-card tags are for — so the band's own caption
/// claims no scope of its own; it carries the calendar context the
/// title bar used to have to squeeze in.
fn kpiSection(ui: *Ui, model: *const Model, frame: *const Frame) Ui.Node {
    return ui.column(.{ .gap = 6 }, .{
        ui.row(.{ .height = 15, .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, "01 / SUMMARY"),
            ui.text(.{
                .size = .sm,
                .text_alignment = .end,
                .style_tokens = .{ .foreground = .text_muted },
            }, ui.fmt("{s} {d} · {d} active days", .{
                monthName(frame.month.month),
                frame.month.year,
                frame.month.active_days,
            })),
        }),
        kpiRow(ui, model, frame),
    });
}

fn kpiRow(ui: *Ui, model: *const Model, frame: *const Frame) Ui.Node {
    return ui.row(.{ .height = 112, .gap = gap }, .{
        costCard(ui, frame),
        tokensCard(ui, frame),
        burnCard(ui, model),
        tripCard(ui, model),
        planCard(ui, frame),
    });
}

fn costCard(ui: *Ui, frame: *const Frame) Ui.Node {
    return card(ui, .{
        .grow = 1,
        .min_width = 130,
        .semantics = .{ .label = "API-equivalent cost over the selected range" },
    }, .{
        kpiLabel(ui, "API EQUIV", frame.scope.tag),
        kpiValue(ui, fmtCost(ui, frame.totals.cost_usd), theme.green),
        sparkline(ui, frame.cost, .accent, "range cost sparkline"),
    });
}

fn tokensCard(ui: *Ui, frame: *const Frame) Ui.Node {
    return card(ui, .{
        .grow = 1,
        .min_width = 130,
        .semantics = .{ .label = "Tokens processed over the selected range" },
    }, .{
        kpiLabel(ui, "TOKENS", frame.scope.tag),
        kpiValue(ui, fmtTokens(ui, frame.totals.totalTokens()), theme.cluster_colors.text),
        sparkline(ui, frame.tokens, .text_muted, "range token sparkline"),
    });
}

/// The number the product is being reframed around: who is burning
/// RIGHT NOW. Tagged NOW, never scoped — the range control must not be
/// able to make a live reading look historical.
fn burnCard(ui: *Ui, model: *const Model) Ui.Node {
    const hot = model.agent_burn.hottest(model.now_ms);
    const tpm = model.agent_burn.totalPerMin(model.now_ms);
    const ink = if (hot) |h| theme.agentInk(@intFromEnum(h.agent)) else theme.text_faint;
    // The caption names WHO, and must not restate WHAT. It used to print
    // the hottest agent's rate — but the value above it is the fleet
    // total, and with one live agent (the overwhelmingly common case, and
    // the case in every screenshot ever taken of this card) those two are
    // the same number rendered 8pt apart. Share says the same thing about
    // dominance without echoing: "82% of fleet" when others are running,
    // "100% of fleet" when this agent IS the reading above.
    // "hottest: <agent>" is 17 characters at the longest agent label
    // ("opencode"/"continue") and clears the 121.2pt floor box that the
    // fits-its-own-card test enforces; a share ("· 100% of fleet") does
    // not, by 29pt. The word costs nothing now that the rate is gone.
    const caption = if (hot) |h|
        ui.fmt("hottest: {s}", .{h.agent.label()})
    else
        "fleet idle";
    return card(ui, .{
        .grow = 1,
        .min_width = 130,
        .semantics = .{ .label = "Fleet burn rate right now" },
    }, .{
        kpiLabel(ui, "BURN", "NOW"),
        kpiValue(ui, ui.fmt("{s}/m", .{fmtTokens(ui, @intFromFloat(@max(tpm, 0)))}), ink),
        ui.text(.{
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, caption),
    });
}

/// Trip odometer. The reset lives on a context menu rather than a
/// button: zeroing it is destructive and irreversible, and a control
/// that sits under the pointer at 1 Hz should not be one click from
/// throwing the reading away.
fn tripCard(ui: *Ui, model: *const Model) Ui.Node {
    const per_hour = engine.tripCostPerHour(model);
    const caption = if (per_hour) |rate|
        ui.fmt("{s}/hr · {s}", .{ fmtCost(ui, rate), fmtTokens(ui, model.trip.totalTokens()) })
    else
        "rate settling";
    return card(ui, .{
        .grow = 1,
        .min_width = 130,
        .context_menu = &[_]Ui.ContextMenuItem{
            .{ .label = "Reset trip odometer", .msg = .trip_reset },
        },
        .semantics = .{ .label = "Trip odometer since launch" },
    }, .{
        kpiLabel(ui, "TRIP", "LAUNCH"),
        kpiValue(ui, fmtCost(ui, model.trip.cost_usd), theme.trip),
        ui.text(.{
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, caption),
    });
}

/// Subscription value is month-to-date and CANNOT follow the range
/// control: the denominator is a monthly plan price, so dividing a
/// 12-hour spend by it would read as a catastrophic month.
fn planCard(ui: *Ui, frame: *const Frame) Ui.Node {
    const value = frame.value;
    const multiple = if (value.multipleLowerBound(frame.month.covered_cost_usd)) |m|
        ui.fmt("≥{d:.1}×", .{m})
    else if (value.incomplete)
        "unknown"
    else
        "no plan";
    // NO WRAPPING CAPTION ANYWHERE ON THIS ROW, and the cents are why.
    // This was the one caption long enough to need two lines, the cards
    // are sized by a row height their siblings' one-liners set, and the
    // second line spilled past the card's bottom border — which the
    // layout audit cannot see (the tree is internally consistent; the
    // shear happens at paint). Dropping the cents off a plan PRICE BAND
    // — a number that is $200.00 or $300.00–$400.00 and never anything
    // between — takes "API-equiv vs $300.00–$400.00/mo" down to
    // "vs $300–400/mo", which fits one line inside the narrowest card
    // the 820pt floor can produce. The "every KPI and machine label
    // fits its own card" test holds this whole row to that.
    const caption = if (value.plan_hi_usd > 0)
        ui.fmt("vs {s}/mo", .{planBand(ui, value)})
    else
        "no paid plan detected";
    return card(ui, .{
        .grow = 1,
        .min_width = 150,
        .semantics = .{ .label = "Subscription value, month to date" },
    }, .{
        kpiLabel(ui, "PLAN VALUE", "MTD"),
        // Green, not the needle ink. A subscription multiple above 1x is
        // the one number on this row that is unambiguously GOOD news —
        // you are getting more API-equivalent value than you pay for.
        // Inking it signal-orange put three of the five summary cards in
        // warning colours and made "you are winning" read as an alarm.
        // Amber stays reserved for `incomplete`, where the plan tier is
        // unknown and the multiple is therefore only a lower bound.
        kpiValue(ui, multiple, if (value.incomplete) theme.amber else theme.green),
        ui.text(.{
            .size = .sm,
            .wrap = false,
            .style_tokens = .{ .foreground = .text_muted },
        }, caption),
    });
}

/// Label plus scope tag in ONE proportional-muted leaf. A span
/// paragraph would let the tag take the mono register, but paragraphs
/// wrap by design and these boxes are 121pt wide at the window floor —
/// a plain leaf elides its tail instead, which is the sanctioned way to
/// lose characters. The tag is never the part that goes: it is short
/// and the label in front of it is the redundant half.
fn kpiLabel(ui: *Ui, label: []const u8, tag: []const u8) Ui.Node {
    return ui.text(.{
        .height = 15,
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, ui.fmt("{s} · {s}", .{ label, tag }));
}

fn kpiValue(ui: *Ui, value: []const u8, ink: Color) Ui.Node {
    return ui.paragraph(.{
        .height = 30,
        .wrap = false,
        .style = .{ .foreground = ink },
    }, &.{.{ .text = value, .weight = .bold, .monospace = true, .scale = 1.65 }});
}

fn sparkline(ui: *Ui, values: []const f32, ink: canvas.ChartSeriesColor, label: []const u8) Ui.Node {
    return ui.chart(.{
        .grow = 1,
        .y_min = 0,
        .baseline = true,
        .semantics = .{ .label = label },
    }, &.{.{ .kind = .line, .values = values, .color = ink, .fill = true, .label = label }});
}

// --------------------------------------------------- chart + fleet pane

fn mainSplit(ui: *Ui, model: *const Model, frame: *const Frame) Ui.Node {
    return ui.split(.{ .grow = split_weight, .value = 0.62 }, .{
        chartCard(ui, model, frame),
        fleetCard(ui, model, frame),
    });
}

/// The bar chart, with every axis the SDK offers switched on. It used
/// to carry gridlines and no numbers at all: no y scale, no x axis, and
/// a caption whose "peak $688.34" was the only figure on the plot, so
/// you could not tell which day anything happened on.
fn chartCard(ui: *Ui, model: *const Model, frame: *const Frame) Ui.Node {
    const series = [_]canvas.ChartSeries{
        .{ .kind = .bar, .values = frame.cost, .color = .accent, .label = "complete" },
        .{ .kind = .bar, .values = frame.partial, .color = .warning, .label = "in progress" },
    };
    const partial_cost: f64 = if (frame.partial.len > 0) frame.partial[frame.partial.len - 1] else 0;
    return card(ui, .{
        .grow = 1,
        .min_width = 330,
        .semantics = .{ .label = "API-equivalent cost bars over the selected range" },
    }, .{
        ui.row(.{ .height = 16, .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, frame.scope.title),
            ui.text(.{
                .size = .sm,
                .text_alignment = .end,
                .style_tokens = .{ .foreground = .text_muted },
            }, ui.fmt("peak {s}", .{fmtCost(ui, frame.peak)})),
        }),
        ui.chart(.{
            .grow = 1,
            .y_min = 0,
            // A hair of headroom so the tallest bar does not merge with
            // the top gridline and read as clipped.
            .y_max = @floatCast(@max(frame.peak, 0.01) * 1.08),
            .grid_lines = 3,
            .y_labels = true,
            .x_labels = frame.labels,
            .baseline = true,
            .hover_details = true,
            .semantics = .{ .label = ui.fmt("{s} cost bars", .{frame.scope.tag}) },
        }, &series),
        chartFoot(ui, model, frame, partial_cost),
    });
}

fn chartFoot(ui: *Ui, model: *const Model, frame: *const Frame, partial_cost: f64) Ui.Node {
    // A filter the daily series structurally cannot honour must be said
    // out loud: `per_day` has no agent dimension, so a per-agent split
    // exists only while the hourly series covers the span.
    if (model.ux.filter_agent) |agent| {
        if (!frame.scope.agent_exact) {
            return ui.text(.{
                .height = 14,
                .size = .sm,
                .style = .{ .foreground = theme.amber },
            }, ui.fmt("filter {s} · bars stay all-agents (the per-agent split is hourly, {d} days deep)", .{
                agent.label(),
                ledger_mod.hour_retention_days,
            }));
        }
    }
    if (frame.hourly_cold) {
        return ui.text(.{
            .height = 14,
            .size = .sm,
            .style = .{ .foreground = theme.amber },
        }, "hourly series is empty since restart — it refills as the collectors replay");
    }
    return ui.row(.{ .height = 14, .gap = 8 }, .{
        ui.text(.{
            .grow = 1,
            .size = .sm,
            .style_tokens = .{ .foreground = .text_muted },
        }, ui.fmt("$ per {s} · oldest → now", .{frame.scope.bucket_noun})),
        ui.text(.{
            .size = .sm,
            .text_alignment = .end,
            .style = .{ .foreground = theme.amber },
        }, ui.fmt("this {s} still filling · {s}", .{ frame.scope.bucket_noun, fmtCost(ui, partial_cost) })),
    });
}

/// The fleet pane: who spent it (agents) or who is running it right now
/// (sessions), on one `dashboard_focus`-driven control. The old card
/// showed a hard top-3 by ALL-TIME cost; this one scrolls the whole
/// roster and scopes to the selected range where the ledger can.
fn fleetCard(ui: *Ui, model: *const Model, frame: *const Frame) Ui.Node {
    const sessions_pane = model.ux.dashboard_focus == .sessions;
    const tag = if (sessions_pane) "LIVE" else if (frame.agents_scoped) frame.scope.tag else "ALL-TIME";
    var panes = [_]Ui.Node{
        ui.el(.segmented_control, .{
            .key = .{ .str = "agents" },
            .text = "AGENTS",
            .size = .sm,
            .selected = !sessions_pane,
            .on_press = .{ .dashboard_focus = .agents },
        }, .{}),
        ui.el(.segmented_control, .{
            .key = .{ .str = "sessions" },
            .text = "SESSIONS",
            .size = .sm,
            .selected = sessions_pane,
            .on_press = .{ .dashboard_focus = .sessions },
        }, .{}),
    };
    const pane_nodes: []const Ui.Node = &panes;
    return card(ui, .{
        .grow = 1,
        .min_width = 250,
        .gap = 6,
        .semantics = .{ .label = "Fleet attribution" },
    }, .{
        // Title and rail are ONE block on a 4pt gap: the rail is the
        // header's reading, not a third sibling, and every point spent
        // separating them came out of the roster below.
        ui.column(.{ .gap = 4 }, .{
            ui.row(.{ .height = 20, .gap = 8, .cross = .center }, .{
                ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("03 / FLEET · {s}", .{tag})),
                ui.el(.tabs, .{ .gap = 2, .semantics = .{ .label = "Fleet pane" } }, pane_nodes),
            }),
            attributionRail(ui, frame),
        }),
        ui.scroll(.{ .grow = 1 }, ui.column(
            .{ .gap = 4 },
            if (sessions_pane) sessionRows(ui, model) else agentRows(ui, model, frame),
        )),
        fleetFoot(ui, model, frame, sessions_pane),
    });
}

/// The pane's closing rule. Two jobs, and the second is why it exists:
/// it reconciles (the roster shows a ranked few, this counts all of
/// them), and it ANCHORS THE BOTTOM EDGE. A scroll region whose content
/// runs out mid-card leaves a hole that reads as an unfinished panel —
/// the same failure the popover MFD had — and the chart card beside
/// this one has carried a footer line all along, so the split was
/// visually lopsided as well.
fn fleetFoot(ui: *Ui, model: *const Model, frame: *const Frame, sessions_pane: bool) Ui.Node {
    var buffer: [sessions_mod.max_sessions]*const sessions_mod.Session = undefined;
    const live = model.roster.live(&buffer, model.now_ms);
    var running: usize = 0;
    for (live) |session| {
        if (session.isRunning(model.now_ms)) running += 1;
    }
    const text = if (sessions_pane)
        ui.fmt("{d} live · {d} running · {d} seen", .{ live.len, running, model.roster.count() })
    else blk: {
        var storage: [agent_count]AgentRow = undefined;
        const ranked = rankAgents(frame, &storage);
        var total: f64 = 0;
        for (ranked) |row| total += row.totals.cost_usd;
        break :blk ui.fmt("{d} agents · {d} live · {s} {s}", .{
            ranked.len,
            live.len,
            fmtCost(ui, total),
            if (frame.agents_scoped) frame.scope.tag else "all-time",
        });
    };
    return ui.text(.{
        .height = 14,
        .size = .sm,
        .style = .{ .foreground = theme.text_faint },
    }, text);
}

/// The stacked-by-agent reading, drawn by hand rather than as a chart
/// series: `canvas.ChartSeriesColor` is a closed set of DESIGN TOKENS,
/// so a stacked chart could only be inked in accent/warning/info — and
/// claude's identity ink has no token. A roster row, a share bar and
/// this rail must agree on what colour an agent is (theme.zig:146), so
/// the rail owns the palette and the chart stays a single honest total.
///
/// Grow fractions, not pixel widths: the pane is resizable, and a rail
/// measured against a constant is exactly the bug this file had.
fn attributionRail(ui: *Ui, frame: *const Frame) Ui.Node {
    var rows: [agent_count]AgentRow = undefined;
    const ranked = rankAgents(frame, &rows);
    var total: f64 = 0;
    for (ranked) |row| total += row.totals.cost_usd;

    if (total <= 0) {
        return ui.panel(.{
            .height = 5,
            .style = .{ .background = theme.track, .radius = 2 },
            .semantics = .{ .label = "no attributed spend in range" },
        }, .{});
    }

    var segments: [max_rail_segments + 1]Ui.Node = undefined;
    var count: usize = 0;
    var tail: f64 = 0;
    for (ranked, 0..) |row, i| {
        if (i >= max_rail_segments) {
            tail += row.totals.cost_usd;
            continue;
        }
        segments[count] = ui.panel(.{
            .key = .{ .int = @intFromEnum(row.agent) },
            .grow = @floatCast(row.totals.cost_usd / total),
            .style = .{ .background = theme.agentInk(@intFromEnum(row.agent)), .radius = 2 },
        }, .{});
        count += 1;
    }
    if (tail > 0) {
        segments[count] = ui.panel(.{
            .key = .{ .str = "other" },
            .grow = @floatCast(tail / total),
            .style = .{ .background = theme.track, .radius = 2 },
        }, .{});
        count += 1;
    }
    const nodes: []const Ui.Node = segments[0..count];
    return ui.row(.{
        .height = 5,
        .gap = 1,
        .semantics = .{ .label = "per-agent cost share" },
    }, nodes);
}

const AgentRow = struct { agent: types.Agent, totals: ledger_mod.Totals };

fn rankAgents(frame: *const Frame, out: *[agent_count]AgentRow) []AgentRow {
    var n: usize = 0;
    for (std.enums.values(types.Agent)) |agent| {
        const totals = frame.agents.get(agent);
        if (totals.events == 0 and totals.cost_usd == 0) continue;
        out[n] = .{ .agent = agent, .totals = totals };
        n += 1;
    }
    std.mem.sort(AgentRow, out[0..n], {}, struct {
        fn lt(_: void, a: AgentRow, b: AgentRow) bool {
            if (a.totals.cost_usd != b.totals.cost_usd) return a.totals.cost_usd > b.totals.cost_usd;
            return @intFromEnum(a.agent) < @intFromEnum(b.agent);
        }
    }.lt);
    return out[0..n];
}

fn agentRows(ui: *Ui, model: *const Model, frame: *const Frame) []const Ui.Node {
    var storage: [agent_count]AgentRow = undefined;
    const ranked = rankAgents(frame, &storage);
    if (ranked.len == 0) return emptyNote(ui, "No usage in this range");

    var total: f64 = 0;
    for (ranked) |row| total += row.totals.cost_usd;

    const nodes = ui.arena.alloc(Ui.Node, ranked.len) catch {
        ui.failed = true;
        return &.{};
    };
    for (ranked, 0..) |row, i| {
        const ordinal = @intFromEnum(row.agent);
        const ink = theme.agentInk(ordinal);
        const selected = model.ux.filter_agent == row.agent;
        const tpm = model.agent_burn.tokensPerMin(row.agent, model.now_ms);
        const share = if (total > 0) row.totals.cost_usd / total else 0;
        nodes[i] = ui.column(.{
            .key = .{ .int = ordinal },
            .gap = 2,
            .padding = 2,
            .style = .{
                .background = if (selected) theme.panel_raised else theme.transparent,
                .radius = 4,
            },
            // Pressing the selected agent clears the filter — a filter
            // you cannot switch off is a trap on a panel that rebuilds
            // under you every second.
            .on_press = .{ .filter_agent = if (selected) null else row.agent },
            .semantics = .{
                .label = ui.fmt("{s} {s}", .{ row.agent.label(), fmtCost(ui, row.totals.cost_usd) }),
                .focusable = true,
            },
        }, .{
            ui.row(.{ .height = 17, .gap = 6, .cross = .center }, .{
                ui.panel(.{ .width = 6, .height = 6, .style = .{ .background = ink, .radius = 3 } }, .{}),
                ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text } }, upperLabel(ui, row.agent)),
                ui.text(.{
                    .size = .sm,
                    .width = 66,
                    .text_alignment = .end,
                    .style = .{ .foreground = if (tpm > 0) theme.activity_dot else theme.text_faint },
                }, if (tpm > 0) ui.fmt("{s}/m", .{fmtTokens(ui, @intFromFloat(tpm))}) else "idle"),
                ui.text(.{
                    .size = .sm,
                    .width = 74,
                    .text_alignment = .end,
                    .style_tokens = .{ .foreground = .text_muted },
                }, fmtCost(ui, row.totals.cost_usd)),
            }),
            shareBar(ui, share, ink),
            // The third register. A roster row that is a name, a rate
            // and a total is four data points thick and 30pt tall, and
            // four of those in a 180pt pane is the ~90pt of dead air
            // this card shipped with. Share, volume and call count are
            // already in `Totals` — the row was throwing them away.
            ui.text(.{
                .height = 12,
                .size = .sm,
                .style = .{ .foreground = theme.text_faint },
            }, ui.fmt("{d:.0}% share · {s} · {s} calls", .{
                share * 100,
                fmtTokens(ui, row.totals.totalTokens()),
                fmtTokens(ui, row.totals.events),
            })),
        });
    }
    return nodes;
}

/// A proportional bar built from two grow weights. Every bar in the old
/// file multiplied a fraction by a hard-coded track width, which is
/// what made the panel unresizable in the first place.
fn shareBar(ui: *Ui, share: f64, ink: Color) Ui.Node {
    const filled: f32 = @floatCast(std.math.clamp(share, 0, 1));
    return ui.row(.{ .height = 4 }, .{
        ui.panel(.{
            .key = .{ .str = "fill" },
            .grow = @max(filled, 0.001),
            .style = .{ .background = ink, .radius = 2 },
        }, .{}),
        ui.panel(.{
            .key = .{ .str = "rest" },
            .grow = @max(1 - filled, 0.001),
            .style = .{ .background = theme.track, .radius = 2 },
        }, .{}),
    });
}

/// Live sessions — the roster's flagship signal. `mid_turn` (transcript
/// grew, no event parsed yet) is the only place in the app that can say
/// an agent is thinking AT THIS INSTANT, so it gets the lit pip.
fn sessionRows(ui: *Ui, model: *const Model) []const Ui.Node {
    var buffer: [sessions_mod.max_sessions]*const sessions_mod.Session = undefined;
    const live = if (model.ux.filter_agent) |agent|
        model.roster.forAgent(agent, &buffer, model.now_ms)
    else
        model.roster.live(&buffer, model.now_ms);
    if (live.len == 0) return emptyNote(ui, "No live sessions");

    const shown = @min(live.len, max_session_rows);
    const overflow: usize = live.len - shown;
    const nodes = ui.arena.alloc(Ui.Node, shown + @intFromBool(overflow > 0)) catch {
        ui.failed = true;
        return &.{};
    };
    for (live[0..shown], 0..) |session, i| {
        const ordinal = @intFromEnum(session.agent);
        const activity = session.activityAt(model.now_ms);
        const pip = switch (activity) {
            .running => if (session.mid_turn) theme.activity_dot else theme.green,
            .idle => theme.idle_dot,
            .done => theme.telltale_off,
        };
        nodes[i] = ui.column(.{
            .key = .{ .str = session.sessionId() },
            .gap = 2,
            .padding = 2,
            .style = .{
                .background = if (model.ux.selected_row == i) theme.panel_raised else theme.transparent,
                .radius = 4,
            },
            .on_press = .{ .row_press = @intCast(i) },
            .semantics = .{
                .label = ui.fmt("{s} {s} {s}", .{ session.agent.label(), session.project(), @tagName(activity) }),
                .focusable = true,
            },
        }, .{
            ui.row(.{ .gap = 6, .cross = .center }, .{
                ui.panel(.{ .width = 6, .height = 6, .style = .{ .background = pip, .radius = 3 } }, .{}),
                ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text } }, session.project()),
                ui.text(.{
                    .size = .sm,
                    .width = 74,
                    .text_alignment = .end,
                    .style_tokens = .{ .foreground = .text_muted },
                }, fmtCost(ui, session.totals.cost_usd)),
            }),
            ui.text(.{
                .size = .sm,
                .style = .{ .foreground = theme.agentInk(ordinal) },
            }, ui.fmt("{s} · {s} · {d} turns", .{ session.agent.label(), session.modelName(), session.turns() })),
        });
    }
    if (overflow > 0) nodes[shown] = overflowNote(ui, overflow, 0);
    return nodes;
}

fn emptyNote(ui: *Ui, text: []const u8) []const Ui.Node {
    const nodes = ui.arena.alloc(Ui.Node, 1) catch {
        ui.failed = true;
        return &.{};
    };
    nodes[0] = ui.text(.{
        .height = 18,
        .style_tokens = .{ .foreground = .text_muted },
    }, text);
    return nodes;
}

/// The overflow indicator. `agentSplit` used to print one and the
/// tables did not, so the tables silently dropped everything past row
/// seven — the remainder's cost is what proves nothing vanished.
fn overflowNote(ui: *Ui, more: usize, rest_cost: f64) Ui.Node {
    return ui.text(.{
        .height = 16,
        .size = .sm,
        .style = .{ .foreground = theme.text_faint },
    }, if (rest_cost > 0)
        ui.fmt("+{d} more · {s}", .{ more, fmtCost(ui, rest_cost) })
    else
        ui.fmt("+{d} more", .{more}));
}

// -------------------------------------------------------- detail tables

fn detailRow(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .grow = table_weight, .gap = gap }, .{
        keyedTable(ui, model, "04 / MODELS", model.ledger.per_model.keys(), model.ledger.per_model.values(), false),
        keyedTable(ui, model, "05 / PROJECTS", model.ledger.per_project.keys(), model.ledger.per_project.values(), true),
    });
}

const Row = struct { name: []const u8, totals: ledger_mod.Totals };

/// Model and project rollups. Tagged ALL-TIME because that is what they
/// are: `per_model` / `per_project` are lifetime maps with no bucket
/// keys, so the range control genuinely cannot reach them. Saying so is
/// the fix; re-labelling them with the selected span would not be.
fn keyedTable(
    ui: *Ui,
    model: *const Model,
    title: []const u8,
    keys: []const []const u8,
    values: []const ledger_mod.Totals,
    basename: bool,
) Ui.Node {
    const rows = sortedRows(ui, keys, values, model.ux.sort_by, model.ux.sort_desc, basename);
    // Hoisted: the old `topTable` called this INSIDE its row loop, an
    // O(n^2) rescan of every model and project on every rebuild.
    var total: f64 = 0;
    for (rows) |row| total += row.totals.cost_usd;

    const shown = @min(rows.len, max_table_rows);
    var rest: f64 = 0;
    for (rows[shown..]) |row| rest += row.totals.cost_usd;

    const body = ui.arena.alloc(Ui.Node, shown + @intFromBool(rows.len > shown)) catch {
        ui.failed = true;
        return card(ui, .{ .grow = 1, .min_width = 260 }, .{});
    };
    for (rows[0..shown], 0..) |row, i| {
        body[i] = ui.column(.{
            .key = .{ .int = @intCast(i) },
            .gap = 3,
            .padding = 3,
            .style = .{
                .background = if (model.ux.selected_row == i) theme.panel_raised else theme.transparent,
                .radius = 3,
            },
            .on_press = .{ .row_press = @intCast(i) },
            .semantics = .{
                .label = ui.fmt("{s} {s}", .{ row.name, fmtCost(ui, row.totals.cost_usd) }),
                .focusable = true,
            },
        }, .{
            ui.row(.{ .gap = 6, .cross = .center }, .{
                ui.text(.{ .grow = 1, .size = .sm, .style_tokens = .{ .foreground = .text } }, row.name),
                ui.text(.{
                    .size = .sm,
                    .width = 66,
                    .text_alignment = .end,
                    .style_tokens = .{ .foreground = .text_muted },
                }, fmtTokens(ui, row.totals.totalTokens())),
                ui.text(.{
                    .size = .sm,
                    .width = 70,
                    .text_alignment = .end,
                    .style_tokens = .{ .foreground = .text_muted },
                }, fmtCost(ui, row.totals.cost_usd)),
            }),
            shareBar(ui, if (total > 0) row.totals.cost_usd / total else 0, theme.green),
        });
    }
    if (rows.len > shown) body[shown] = overflowNote(ui, rows.len - shown, rest);

    return card(ui, .{
        .grow = 1,
        .min_width = 260,
        .semantics = .{ .label = ui.fmt("{s} all-time rollup", .{title}) },
    }, .{
        ui.row(.{ .height = 16, .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("{s} · ALL-TIME", .{title})),
            ui.text(.{
                .size = .sm,
                .text_alignment = .end,
                .style_tokens = .{ .foreground = .text_muted },
            }, ui.fmt("{d} rows", .{rows.len})),
        }),
        sortHeader(ui, model),
        ui.scroll(.{ .grow = 1 }, ui.column(.{ .gap = 3 }, if (rows.len == 0)
            emptyNote(ui, "No usage data yet")
        else
            @as([]const Ui.Node, body))),
    });
}

/// Pressable column headers — the control that emits `Msg.sort_by`.
/// Re-pressing the active column flips the direction in `applyUxMsg`,
/// so the arrow is read back from the model rather than tracked here.
fn sortHeader(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{ .height = 14, .gap = 6, .cross = .center }, .{
        sortCell(ui, model, .name, "NAME", 0, 1),
        sortCell(ui, model, .tokens, "TOKENS", 66, 0),
        sortCell(ui, model, .cost, "COST", 70, 0),
    });
}

fn sortCell(
    ui: *Ui,
    model: *const Model,
    column: engine.SortColumn,
    label: []const u8,
    width: f32,
    grow: f32,
) Ui.Node {
    const active = model.ux.sort_by == column;
    const arrow = if (!active) "" else if (model.ux.sort_desc) " ↓" else " ↑";
    return ui.text(.{
        .key = .{ .int = @intFromEnum(column) },
        .size = .sm,
        .width = width,
        .grow = grow,
        .text_alignment = if (grow > 0) .start else .end,
        .style = .{ .foreground = if (active) theme.green else theme.text_faint },
        .on_press = .{ .sort_by = column },
        .semantics = .{ .label = ui.fmt("Sort by {s}", .{label}), .focusable = true },
    }, ui.fmt("{s}{s}", .{ label, arrow }));
}

fn sortedRows(
    ui: *Ui,
    keys: []const []const u8,
    values: []const ledger_mod.Totals,
    column: engine.SortColumn,
    desc: bool,
    basename: bool,
) []Row {
    const rows = ui.arena.alloc(Row, keys.len) catch {
        ui.failed = true;
        return &.{};
    };
    for (keys, values, 0..) |key, totals, i| {
        rows[i] = .{ .name = if (basename) displayName(key) else key, .totals = totals };
    }
    const Sorter = struct {
        column: engine.SortColumn,
        desc: bool,
        fn lt(self: @This(), a: Row, b: Row) bool {
            const ordered = switch (self.column) {
                .name => std.mem.lessThan(u8, a.name, b.name),
                .tokens => a.totals.totalTokens() > b.totals.totalTokens(),
                // A keyed rollup has no activity clock, so `.activity`
                // reads as cost here rather than pretending to a
                // recency it never recorded.
                .cost, .activity => a.totals.cost_usd > b.totals.cost_usd,
            };
            return if (self.desc) ordered else !ordered;
        }
    };
    std.mem.sort(Row, rows, Sorter{ .column = column, .desc = desc }, Sorter.lt);
    return rows;
}

// ---------------------------------------------------------- system row

/// Section 06: the machine over the last half hour. Every system meter
/// elsewhere in this app draws a bar of NOW; `model.system_history` is
/// the same readings on a wall clock, and this strip is the only place
/// the app makes good on "system monitor" rather than "system gauge".
///
/// THE OLD STRIP WAS AN AFTERTHOUGHT and read as one: 78pt of card
/// holding four labels, four readings shoved to the far right of their
/// cells with a hand's width of nothing between, and four traces 17pt
/// tall — a sliver that cannot show a shape, which is the entire reason
/// to keep thirty minutes of samples. What changed:
///
///   - The trace gets the height. A lane is a label, a reading and a
///     plot, and the plot is now the tallest thing in it.
///   - Label and reading are ONE unit, set left, in the two registers
///     the cluster uses everywhere else: proportional muted for the
///     name, monospace bold for the number. Nothing is pushed right; the
///     trace under them spans the lane and does the spanning.
///   - Six channels, not four. `SystemHistory` has always recorded net
///     and battery and this panel ignored both, so a laptop on battery
///     during a long agent run — the exact situation the panel exists
///     for — had nothing to say about either.
fn systemRow(ui: *Ui, model: *const Model) Ui.Node {
    var cells: [6]Ui.Node = undefined;
    var count: usize = 0;
    const history = &model.system_history;

    if (!history.cpu.isEmpty()) {
        cells[count] = percentLane(ui, "CPU", &history.cpu, theme.loadZone(fractionOf(&history.cpu)));
        count += 1;
    }
    if (!history.gpu.isEmpty()) {
        cells[count] = percentLane(ui, "GPU", &history.gpu, theme.loadZone(fractionOf(&history.gpu)));
        count += 1;
    }
    if (!history.mem.isEmpty()) {
        cells[count] = percentLane(ui, "MEM", &history.mem, theme.loadZone(fractionOf(&history.mem)));
        count += 1;
    }
    if (!history.disk.isEmpty()) {
        // "DISK USED", not "DISK". The popover's DISK cell shows free
        // space (tt-t7u: capacity barely moves, so free bytes plus an I/O
        // meter is the more useful instrument there). This lane is a
        // percentage row, so it necessarily shows the complement — and
        // two surfaces printing "DISK" for opposite quantities in
        // opposite polarity is how a reader ends up believing a nearly
        // full volume is a nearly empty one. Naming the quantity costs
        // five glyphs and removes the ambiguity entirely.
        cells[count] = percentLane(ui, "DISK USED", &history.disk, theme.diskZone(fractionOf(&history.disk)));
        count += 1;
    }
    if (!history.net_rx.isEmpty() or !history.net_tx.isEmpty()) {
        cells[count] = netLane(ui, history);
        count += 1;
    }
    if (!history.battery.isEmpty()) {
        cells[count] = percentLane(ui, "BAT", &history.battery, theme.chargeZone(fractionOf(&history.battery)));
        count += 1;
    }

    if (count == 0) {
        return card(ui, .{ .height = 44, .semantics = .{ .label = "System telemetry history" } }, .{
            ui.text(.{
                .size = .sm,
                .style_tokens = .{ .foreground = .text_muted },
            }, "06 / MACHINE · no telemetry recorded yet"),
        });
    }

    // Every series advances on the same clock, so whichever channel is
    // live answers for the strip — but it has to BE live: a machine
    // with the CPU sampler disabled and the disk one on is not a
    // machine with no history.
    const recorded = recordedSamples(sampleSource(history));

    const nodes: []const Ui.Node = cells[0..count];
    return card(ui, .{
        .height = system_card_height,
        .gap = 6,
        .semantics = .{ .label = "System telemetry history" },
    }, .{
        // Span and cadence are READ OFF THE RING, not typed. The card
        // said "LAST 30 MIN" as a literal while the window length lived
        // in `SystemHistory.span_ms`; the two were one constant edit
        // away from disagreeing, and the caption would have been the
        // liar.
        ui.row(.{ .height = 14, .gap = 8, .cross = .center }, .{
            ui.text(.{
                .grow = 1,
                .size = .sm,
                .style_tokens = .{ .foreground = .text_muted },
            }, ui.fmt("06 / MACHINE · LAST {d} MIN", .{@divTrunc(engine.SystemHistory.span_ms, 60_000)})),
            // How much of the window is actually RECORDED. A ring that
            // has been alive for ninety seconds holds eighteen samples
            // against a thirty-minute axis, and a trace of three dots
            // under a caption claiming "360 samples" reads as a broken
            // panel rather than a young one. Counting says which it is.
            ui.text(.{
                .size = .sm,
                .text_alignment = .end,
                .style = .{ .foreground = theme.text_faint },
            }, if (recorded < engine.SystemHistory.buckets)
                ui.fmt("filling · {d} of {d} samples · {d}s apart", .{
                    recorded,
                    engine.SystemHistory.buckets,
                    @divTrunc(engine.SystemHistory.period_ms, 1000),
                })
            else
                ui.fmt("{d} samples · {d}s apart", .{
                    engine.SystemHistory.buckets,
                    @divTrunc(engine.SystemHistory.period_ms, 1000),
                })),
        }),
        ui.row(.{ .grow = 1, .gap = gap }, nodes),
    });
}

/// Fixed, and deliberately: 06 is a readout, not a list. Card padding
/// (26) + title (14) + gap (6) + a lane's header (18) + gap (3) leaves
/// the plot 45pt — 2.6x what it had, and enough for a trace to have a
/// shape at a glance.
const system_card_height: f32 = 112;

fn fractionOf(series: *const engine.SystemHistory.Series) f64 {
    return @floatCast(series.latest() orelse 0);
}

/// The first channel with anything in it, for the strip's shared
/// "how much of the window is recorded" caption.
fn sampleSource(history: *const engine.SystemHistory) *const engine.SystemHistory.Series {
    inline for (.{ &history.cpu, &history.mem, &history.gpu, &history.disk, &history.net_rx, &history.battery }) |series| {
        if (!series.isEmpty()) return series;
    }
    return &history.cpu;
}

/// Slots in the ring that hold a reading.
fn recordedSamples(series: *const engine.SystemHistory.Series) usize {
    var raw: [engine.SystemHistory.buckets]?f32 = undefined;
    var n: usize = 0;
    for (series.snapshot(&raw)) |sample| {
        if (sample != null) n += 1;
    }
    return n;
}

/// A 0..1 channel: CPU, GPU, memory, disk, battery. The domain is
/// pinned to full scale rather than fitted to the window, so a lane at
/// 12% LOOKS like 12% and the six lanes are readable against each other
/// — an auto-fitted trace would draw an idle machine and a pegged one
/// identically.
fn percentLane(ui: *Ui, label: []const u8, series: *const engine.SystemHistory.Series, ink: Color) Ui.Node {
    const values = laneValues(ui, series);
    return lane(ui, .{
        .label = label,
        .reading = ui.fmt("{d:.0}%", .{(series.latest() orelse 0) * 100}),
        .ink = ink,
        .values = values,
        .y_max = 1,
        .grid_lines = 1,
        .semantics = ui.fmt("{s} percent over the last {d} minutes", .{
            label,
            @divTrunc(engine.SystemHistory.span_ms, 60_000),
        }),
    });
}

/// Throughput has no full scale to pin to, so this lane fits its own
/// window and the READING carries the absolute — the opposite contract
/// from `percentLane`, and the reason the two are separate functions
/// rather than one with a flag.
///
/// Both directions are plotted (receive filled, transmit as a bare
/// line) because a lane that showed only one would be silent about
/// uploads, and one summed trace would hide which way the traffic went.
/// The reading is the combined rate: on a strip this narrow two numbers
/// do not fit, and the pair of traces already separates them.
fn netLane(ui: *Ui, history: *const engine.SystemHistory) Ui.Node {
    const rx = laneValues(ui, &history.net_rx);
    const tx = laneValues(ui, &history.net_tx);
    var peak: f32 = 0;
    for (rx) |v| peak = @max(peak, if (std.math.isNan(v)) 0 else v);
    for (tx) |v| peak = @max(peak, if (std.math.isNan(v)) 0 else v);
    const now = @max((history.net_rx.latest() orelse 0) + (history.net_tx.latest() orelse 0), 0);
    return lane(ui, .{
        .label = "NET",
        .reading = ui.fmt("{s}/s", .{fmtBytes(ui, @intFromFloat(now))}),
        // No zone function covers throughput — there is no "too much
        // network" threshold to colour against — so it stays on the
        // neutral text ink instead of borrowing a severity it cannot
        // justify.
        .ink = theme.cluster_colors.text,
        .values = rx,
        .second = tx,
        .y_max = @max(peak * 1.1, 1),
        .semantics = ui.fmt("network receive and transmit over the last {d} minutes", .{
            @divTrunc(engine.SystemHistory.span_ms, 60_000),
        }),
    });
}

const LaneSpec = struct {
    label: []const u8,
    reading: []const u8,
    ink: Color,
    values: []const f32,
    second: []const f32 = &.{},
    y_max: f32,
    /// Hairline divisions of the plot. A percent lane gets one, at half
    /// scale: it turns an empty or near-flat trace into a READING
    /// against a scale rather than a blank box, which is the difference
    /// between an idle instrument and a dead one. Throughput has no
    /// meaningful fraction of its own auto-fitted domain, so it gets
    /// none.
    grid_lines: u8 = 0,
    semantics: []const u8,
};

fn lane(ui: *Ui, spec: LaneSpec) Ui.Node {
    var series: [2]canvas.ChartSeries = undefined;
    // Filled ONLY when there is a second trace to be told apart from —
    // which is the NET lane and nothing else. On a percent lane the fill
    // is pinned to a 0..100 domain, so a channel that is both high and
    // steady (memory parked at 71%, a volume parked at 83% for months)
    // draws as a solid block: no shape, and the heaviest object in a
    // panel of five. It also buries the only thing the trace encodes,
    // because the eye lands on the mass and not on its top edge. Bare
    // strokes make all five lanes comparable against the same baseline,
    // and match view.zig's telemetry strip, which unfilled for exactly
    // this reason. NET keeps the fill: there, filled-vs-stroked IS the
    // legend separating receive from transmit.
    series[0] = .{
        .kind = .line,
        .values = spec.values,
        .color = .info,
        .fill = spec.second.len > 0,
        .label = spec.label,
    };
    var series_count: usize = 1;
    if (spec.second.len > 0) {
        series[1] = .{ .kind = .line, .values = spec.second, .color = .text_muted, .label = "tx" };
        series_count = 2;
    }
    return ui.column(.{ .grow = 1, .gap = 3, .key = .{ .str = spec.label } }, .{
        ui.row(.{ .height = 18, .gap = 6, .cross = .center }, .{
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, spec.label),
            ui.paragraph(.{
                .grow = 1,
                .size = .sm,
                .wrap = false,
                .style = .{ .foreground = spec.ink },
            }, &.{.{ .text = spec.reading, .weight = .bold, .monospace = true, .scale = 1.1 }}),
        }),
        ui.chart(.{
            .grow = 1,
            .y_min = 0,
            .y_max = spec.y_max,
            .grid_lines = spec.grid_lines,
            .baseline = true,
            .semantics = .{ .label = spec.semantics },
        }, series[0..series_count]),
    });
}

/// Plotted points per lane, and the ratio that gets `SystemHistory`'s
/// 360 samples down to it.
///
/// THIS IS A HARD RUNTIME BUDGET, not a taste call. A filled line series
/// costs `2n + 3` path elements and the SDK refuses a frame past
/// `max_chart_path_elements_per_frame` (2048) with
/// `ChartPathElementListFull` — a blank window, not a warning. Six
/// filled lanes at the SDK's own 256-point downsample ceiling is 3090
/// elements and fails; at 90 points the whole window (six lanes, the
/// net lane's second trace, both KPI sparklines and the bar chart) fits
/// with room to spare. 90 points across a lane 140pt wide is still
/// finer than one point per 1.5pt of plot.
const lane_points: usize = 90;
const lane_stride: usize = engine.SystemHistory.buckets / lane_points;

/// A lane's samples as the chart wants them: `lane_stride` consecutive
/// readings collapsed to their PEAK, newest bucket last.
///
/// Peak-hold rather than mean, because this is a load trace and the
/// spike is the event worth seeing — averaging is how a monitor hides
/// the thing you opened it to find. The stride divides the ring evenly
/// (360 / 90), so the final bucket ends exactly on the newest sample and
/// the right edge of the trace agrees with the reading printed above it.
///
/// Gaps in the ring (a module disabled mid-run) stay NaN, which the
/// chart SKIPS rather than plotting as zero — a disabled sampler must
/// not look like an idle machine. A bucket is NaN only when every
/// sample in it was missing.
fn laneValues(ui: *Ui, series: *const engine.SystemHistory.Series) []const f32 {
    var raw: [engine.SystemHistory.buckets]?f32 = undefined;
    const window = series.snapshot(&raw);
    const out_len = window.len / lane_stride;
    const values = ui.arena.alloc(f32, out_len) catch {
        ui.failed = true;
        return &.{};
    };
    // Anchored on the END of the window: any remainder is dropped from
    // the OLDEST edge, never the newest.
    const offset = window.len - out_len * lane_stride;
    for (values, 0..) |*slot, i| {
        var peak: ?f32 = null;
        for (window[offset + i * lane_stride ..][0..lane_stride]) |sample| {
            const value = sample orelse continue;
            peak = if (peak) |p| @max(p, value) else value;
        }
        slot.* = peak orelse std.math.nan(f32);
    }
    return values;
}

// ------------------------------------------------------------- material

const CardOptions = struct {
    grow: f32 = 0,
    height: f32 = 0,
    min_width: f32 = 0,
    gap: f32 = 7,
    context_menu: []const Ui.ContextMenuItem = &.{},
    semantics: canvas.WidgetSemantics = .{},
};

/// The cabin panel: graphite fill, hairline bezel edge, and a column
/// for the content (a `panel` STACKS its children, so the flow lives
/// one level in).
fn card(ui: *Ui, options: CardOptions, children: anytype) Ui.Node {
    return ui.panel(.{
        .grow = options.grow,
        .height = options.height,
        .min_width = options.min_width,
        .context_menu = options.context_menu,
        .semantics = options.semantics,
        .style = .{
            .background = theme.panel,
            .border = theme.bezel_edge,
            .stroke_width = 1,
            .radius = 8,
        },
    }, ui.column(.{ .grow = 1, .padding = card_pad, .gap = options.gap }, children));
}

fn upperLabel(ui: *Ui, agent: types.Agent) []const u8 {
    const label = agent.label();
    const out = ui.arena.alloc(u8, label.len) catch {
        ui.failed = true;
        return label;
    };
    return std.ascii.upperString(out, label);
}

fn displayName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len > 0) base else path;
}

fn fmtCost(ui: *Ui, cost: f64) []const u8 {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    trayfmt.writeCost(&w, cost) catch {};
    return ui.arena.dupe(u8, w.buffered()) catch {
        ui.failed = true;
        return "";
    };
}

fn fmtBytes(ui: *Ui, bytes: u64) []const u8 {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    trayfmt.writeHumanBytes(&w, bytes) catch {};
    return ui.arena.dupe(u8, w.buffered()) catch {
        ui.failed = true;
        return "";
    };
}

fn fmtTokens(ui: *Ui, tokens: u64) []const u8 {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    trayfmt.writeHumanTokens(&w, tokens) catch {};
    return ui.arena.dupe(u8, w.buffered()) catch {
        ui.failed = true;
        return "";
    };
}

/// Whole dollars, one currency mark for the pair: "$200", "$300–400".
/// Plan prices are published as round monthly figures, so the cents
/// `fmtCost` prints are two guaranteed zeroes per side — 12 glyphs of
/// nothing on the narrowest card in the window (see `planCard`).
fn planBand(ui: *Ui, value: engine.SubscriptionValue) []const u8 {
    if (value.plan_lo_usd == value.plan_hi_usd) return ui.fmt("${d:.0}", .{value.plan_hi_usd});
    return ui.fmt("${d:.0}–{d:.0}", .{ value.plan_lo_usd, value.plan_hi_usd });
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Month",
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testModel(allocator: std.mem.Allocator) Model {
    var model = Model{
        .allocator = allocator,
        .ledger = ledger_mod.Ledger.init(allocator, 0),
    };
    // A round day boundary keeps the day/hour keys legible in failures.
    model.now_ms = 20_643 * 86_400_000 + 12 * 3_600_000;
    model.trip_start_ms = model.now_ms - 3_600_000;
    return model;
}

fn seed(model: *Model, agent: types.Agent, at_ms: i64, model_name: []const u8, cwd: []const u8, cost: f64) !void {
    try model.ledger.add(.{
        .agent = agent,
        .timestamp_ms = at_ms,
        .model = model_name,
        .output_tokens = 1_000,
        .session_id = "s-1",
        .cwd = cwd,
    }, cost);
}

/// Every channel `SystemHistory` records, over the full window. The
/// audit used to run against a model with NO telemetry at all, which
/// meant section 06 was laid out in its 44pt empty state and its six
/// populated lanes were never measured at any window size.
fn seedTelemetry(model: *Model) void {
    const h = &model.system_history;
    const start = model.now_ms - engine.SystemHistory.span_ms + engine.SystemHistory.period_ms;
    var t = start;
    var i: usize = 0;
    while (t <= model.now_ms) : (t += engine.SystemHistory.period_ms) {
        const phase: f32 = @floatFromInt(i % 20);
        h.cpu.record(t, 0.2 + phase / 60.0);
        h.gpu.record(t, 0.05 + phase / 120.0);
        h.mem.record(t, 0.66 + phase / 300.0);
        h.disk.record(t, 0.83);
        h.net_rx.record(t, 400_000 + phase * 90_000);
        h.net_tx.record(t, 40_000 + phase * 9_000);
        h.battery.record(t, 0.92 - phase / 400.0);
        i += 1;
    }
}

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    const node = rootView(&ui, model);
    try testing.expect(!ui.failed);
    return ui.finalizeWithTokens(node, theme.tokens());
}

fn findText(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (findText(child, needle)) return true;
    }
    return false;
}

fn hasExactText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.eql(u8, widget.text, text)) return true;
    for (widget.children) |child| {
        if (hasExactText(child, text)) return true;
    }
    return false;
}

/// The press Msg of the DEEPEST pressable widget whose subtree carries
/// `text` — a row binds its handler on the container while the label
/// lives on a text leaf inside it, so matching the leaf alone finds
/// nothing.
fn firstPressMsg(widget: canvas.Widget, tree: Ui.Tree, text: []const u8) ?Msg {
    for (widget.children) |child| {
        if (firstPressMsg(child, tree, text)) |msg| return msg;
    }
    if (!hasExactText(widget, text)) return null;
    return tree.msgFor(widget.id, .press);
}

fn countNodes(widget: canvas.Widget) usize {
    var n: usize = 1;
    for (widget.children) |child| n += countNodes(child);
    return n;
}

/// The seeded worst case every layout test runs against: two agents
/// with a month of history, RECOGNIZED plans on both, and every
/// telemetry channel populated.
///
/// Each of those is a branch the audit is otherwise blind to. Without
/// the plans the subscription card takes its short "no paid plan
/// detected" caption and the row's longest string is never laid out —
/// which is exactly how a sheared caption reached the shipped window.
/// Without the telemetry, section 06 lays out in its 44pt empty state
/// and its six populated lanes are measured at no window size at all.
/// Two plans is also the widest band the price table can produce
/// (claude max $100–200 + codex pro $200 = "$300–400").
fn seedWorstCase(model: *Model) !void {
    for (0..24) |i| {
        try seed(model, .claude, model.now_ms - @as(i64, @intCast(i)) * 86_400_000, "claude-fable-5", "/w/token-tach", 4.5);
        try seed(model, .codex, model.now_ms - @as(i64, @intCast(i)) * 3_600_000, "gpt-5.5", "/w/home-ops", 1.25);
    }
    model.claude_plan = "max";
    model.codex_limits = .{ .agent = .codex, .read_at_ms = model.now_ms, .plan = "pro" };
    seedTelemetry(model);
}

/// Every window size the panel has to hold: the declared floor
/// (main.zig: min 820x560), a small laptop window, the default, a
/// common 16:10 desktop, and a wide one. Absolute rects against a 920
/// constant used to clip the right column below that and leave dead
/// margin above it; the flow tree has to answer for all of them.
const test_sizes = [_][2]f32{
    .{ 820, 560 },
    .{ 1024, 640 },
    .{ window_width, window_height },
    .{ 1280, 860 },
    .{ 1600, 1000 },
    .{ 2400, 1400 },
};

test "dashboard lays out cleanly from the window floor to a wide desktop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seedWorstCase(&model);

    const tree = try buildTree(arena_state.allocator(), &model);

    // The 1024-node per-view cap fails a frame at RUNTIME, so the
    // budget is asserted, not assumed.
    try testing.expect(countNodes(tree.root) < 1024);

    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    defer testing.allocator.free(nodes);

    for (test_sizes) |size| {
        const bounds = geometry.RectF.init(0, 0, size[0], size[1]);
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, theme.tokens(), nodes);
        var findings: [canvas.max_layout_audit_findings]canvas.LayoutAuditFinding = undefined;
        const issues = canvas.auditWidgetLayout(layout, bounds, theme.tokens(), &findings);
        var overlaps: usize = 0;
        for (issues.findings) |finding| {
            if (finding.rule == .sibling_overlap) overlaps += 1;
        }
        try testing.expectEqual(@as(usize, 0), overlaps);
        // Nothing wraps into a sibling, elides silently, or spills past
        // a clip scope either — the whole panel audits clean at every
        // size the window can take.
        try testing.expectEqual(@as(usize, 0), issues.total);
    }
}

// THREE runtime budgets, on a SATURATED frame: every agent present,
// both tables past their caps, the roster full, every telemetry lane
// live. Exceeding any of them fails the FRAME at runtime — a blank
// window, not a compile error — so they are asserted here or they are
// not checked at all.
//
// The third one is not hypothetical. Section 06 handed the SDK six
// filled line series; at the SDK's own 256-point downsample ceiling
// that is 3090 path elements against a 2048 budget, and the first
// version of this strip failed the frame outright. `lane_points` is
// sized against this test, not against taste.
test "a saturated dashboard frame stays inside every runtime budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seedWorstCase(&model);
    var buf: [24]u8 = undefined;
    for (std.enums.values(types.Agent)) |agent| {
        const name = try std.fmt.bufPrint(&buf, "model-{s}", .{agent.label()});
        try seed(&model, agent, model.now_ms, name, "/w/token-tach", 3.0);
        model.agent_burn.addTokens(agent, model.now_ms, 50_000);
    }
    for (0..max_table_rows + 8) |i| {
        const name = try std.fmt.bufPrint(&buf, "project-{d:0>3}", .{i});
        try seed(&model, .claude, model.now_ms, name, name, @floatFromInt(i + 1));
    }
    for (0..sessions_mod.max_sessions) |i| {
        const id = try std.fmt.bufPrint(&buf, "session-{d:0>3}", .{i});
        model.roster.record(.{
            .agent = .claude,
            .timestamp_ms = model.now_ms,
            .model = "claude-fable-5",
            .session_id = id,
            .cwd = "/w/token-tach",
            .output_tokens = 1_000,
        }, 1.0);
    }

    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    defer testing.allocator.free(nodes);
    const commands = try testing.allocator.alloc(canvas.CanvasCommand, max_commands);
    defer testing.allocator.free(commands);

    // Both fleet panes: the sessions roster is the taller of the two and
    // only reachable through `dashboard_focus`.
    for ([_]engine.DashboardPane{ .agents, .sessions }) |focus| {
        model.ux.dashboard_focus = focus;
        const tree = try buildTree(arena_state.allocator(), &model);
        const layout = try canvas.layoutWidgetTreeWithTokens(
            tree.root,
            geometry.RectF.init(0, 0, window_width, window_height),
            theme.tokens(),
            nodes,
        );
        var builder = canvas.Builder.init(commands);
        try canvas.emitWidgetLayout(&builder, layout, theme.tokens());
        std.debug.print("\nDASHBOARD {s}: {d} nodes / {d} commands / {d} path elements\n", .{
            @tagName(focus),
            countNodes(tree.root),
            builder.displayList().commandCount(),
            builder.path_element_len,
        });
        try testing.expect(countNodes(tree.root) <= max_view_nodes);
        try testing.expect(builder.displayList().commandCount() <= max_commands);
        try testing.expect(builder.path_element_len <= canvas.max_chart_path_elements_per_frame);
    }
}

/// `canvas_limits.max_canvas_widget_nodes_per_view` and
/// `max_canvas_commands_per_view`, restated because the limits module is
/// runtime-internal and not reachable from the SDK's public canvas
/// namespace.
const max_view_nodes: usize = 1024;
const max_commands: usize = 2048;

/// Text size a `.text` leaf resolves to, replicating
/// `widget_metrics.widgetTypographySize` (not exported). Only the two
/// rungs this window uses.
fn leafTextSize(widget: canvas.Widget, tokens: canvas.DesignTokens) f32 {
    return switch (widget.size) {
        .sm => @max(8, tokens.typography.body_size - 1),
        else => tokens.typography.body_size,
    };
}

/// Assert every single-style text leaf inside `within` fits the box it
/// was given.
///
/// THE LAYOUT AUDIT CANNOT DO THIS. Its own docs are explicit: an
/// ellipsized single line is correct rendering, never a finding. So a
/// title too long for its own card — "TOKENS PROCESSED · 30D" in a
/// 121pt box — audits perfectly clean and ships truncated. The same
/// blind spot on the other axis (a wrapped caption reserving more
/// height than its card) is why nothing on the KPI row wraps any more.
///
/// Spanned paragraphs are skipped: they mix mono, weights and scales,
/// so a single sans measurement of their concatenated text would be
/// meaningless.
fn expectTextFits(
    layout: canvas.WidgetLayoutTree,
    within: geometry.RectF,
    tokens: canvas.DesignTokens,
) !void {
    for (layout.nodes) |node| {
        if (node.widget.kind != .text) continue;
        if (node.widget.text.len == 0 or node.widget.spans.len > 0) continue;
        if (!within.containsRect(node.frame)) continue;
        const width = canvas.estimateTextWidthForFont(
            canvas.default_sans_font_id,
            node.widget.text,
            leafTextSize(node.widget, tokens),
        );
        if (width > node.frame.width + 0.5) {
            std.debug.print(
                "\n\"{s}\" needs {d:.1}pt and has {d:.1}pt\n",
                .{ node.widget.text, width, node.frame.width },
            );
            return error.TextDoesNotFitItsBox;
        }
    }
}

fn frameOfSemantics(layout: canvas.WidgetLayoutTree, label: []const u8) ?geometry.RectF {
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.frame;
    }
    return null;
}

test "every KPI and machine label fits its own card at the window floor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seedWorstCase(&model);
    // The burn caption names an agent, so it is only as wide as the
    // longest label in the enum: pin the widest one rather than the
    // convenient one.
    model.agent_burn.addTokens(.opencode, model.now_ms, 987_654);

    const tree = try buildTree(arena_state.allocator(), &model);
    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    defer testing.allocator.free(nodes);

    // Chrome-only regions: fixed strings in boxes this file sizes. User
    // data (model names, project paths) legitimately elides and is not
    // asserted here.
    const chrome = [_][]const u8{
        "API-equivalent cost over the selected range",
        "Tokens processed over the selected range",
        "Fleet burn rate right now",
        "Trip odometer since launch",
        "Subscription value, month to date",
        "System telemetry history",
    };

    for (test_sizes) |size| {
        const bounds = geometry.RectF.init(0, 0, size[0], size[1]);
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, theme.tokens(), nodes);
        for (chrome) |label| {
            const frame = frameOfSemantics(layout, label) orelse return error.MissingCard;
            try expectTextFits(layout, frame, theme.tokens());
        }
    }
}

test "the page numbers all six of its sections, starting at 01" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seedWorstCase(&model);

    const tree = try buildTree(arena_state.allocator(), &model);
    // The KPI strip was the one unnumbered band on a page whose other
    // five panels all carried an index. Either everything is numbered or
    // nothing is; this holds the page to the former.
    for ([_][]const u8{ "01 / ", "02 / ", "03 / ", "04 / ", "05 / ", "06 / " }) |section| {
        try testing.expect(findText(tree.root, section));
    }
}

test "a young telemetry ring says so instead of looking broken" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    // Three samples: what the strip actually holds fifteen seconds
    // after launch, and how every user sees it first. Three dots on a
    // thirty-minute axis under a caption promising 360 samples reads as
    // a broken panel; the count is what makes it a young one.
    for (0..3) |i| {
        const at = model.now_ms - @as(i64, @intCast(2 - i)) * engine.SystemHistory.period_ms;
        model.system_history.cpu.record(at, 0.3);
    }

    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findText(tree.root, "filling · 3 of 360 samples"));
    // And it is still a strip, not the "no telemetry recorded yet"
    // placeholder — one channel is enough to draw.
    try testing.expect(hasExactText(tree.root, "CPU"));
    try testing.expect(!findText(tree.root, "no telemetry recorded yet"));
}

test "the machine strip plots every channel the history records" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seedWorstCase(&model);

    const tree = try buildTree(arena_state.allocator(), &model);
    // Net and battery are recorded by `SystemHistory` and were dropped
    // on the floor by the old four-lane strip.
    // "DISK USED" rather than "DISK": this lane is a used-percentage and
    // the popover's DISK cell is free bytes, so the label has to name
    // which of the two it is.
    for ([_][]const u8{ "CPU", "GPU", "MEM", "DISK USED", "NET", "BAT" }) |channel| {
        try testing.expect(hasExactText(tree.root, channel));
    }
    // And the span/cadence caption is derived from the ring, not typed:
    // 360 samples 5 s apart IS 30 minutes.
    try testing.expect(findText(tree.root, "LAST 30 MIN"));
    try testing.expect(findText(tree.root, "360 samples · 5s apart"));
}

test "the time-range control emits time_range and re-scopes the chart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seed(&model, .claude, model.now_ms, "claude-fable-5", "/w/token-tach", 9.0);

    // The engine's default is `.live`, which this window folds onto the
    // 30-day view: the ledger's finest bucket is an hour, so a LIVE
    // segment could only ever draw one bar.
    try testing.expectEqual(engine.TimeRange.live, model.ux.time_range);
    {
        const tree = try buildTree(arena_state.allocator(), &model);
        try testing.expect(findText(tree.root, "30-DAY API-EQUIVALENT COST"));
        const msg = firstPressMsg(tree.root, tree, "24H").?;
        try testing.expectEqual(engine.TimeRange.day, msg.time_range);
        engine.applyUxMsg(&model, msg);
    }
    {
        const tree = try buildTree(arena_state.allocator(), &model);
        try testing.expect(findText(tree.root, "24-HOUR API-EQUIVALENT COST"));
        try testing.expect(!findText(tree.root, "30-DAY API-EQUIVALENT COST"));
    }
}

test "table headers emit sort_by and agent rows emit filter_agent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    try seed(&model, .claude, model.now_ms, "claude-fable-5", "/w/token-tach", 9.0);
    try seed(&model, .codex, model.now_ms, "gpt-5.5", "/w/home-ops", 3.0);

    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expectEqual(engine.SortColumn.name, firstPressMsg(tree.root, tree, "NAME").?.sort_by);
    try testing.expectEqual(engine.SortColumn.tokens, firstPressMsg(tree.root, tree, "TOKENS").?.sort_by);
    // Cost is the default sort, so its header carries the arrow.
    try testing.expectEqual(engine.SortColumn.cost, firstPressMsg(tree.root, tree, "COST ↓").?.sort_by);

    const filter = firstPressMsg(tree.root, tree, "CLAUDE").?;
    try testing.expectEqual(types.Agent.claude, filter.filter_agent.?);
    engine.applyUxMsg(&model, filter);
    // Pressing the filtered agent again clears it rather than trapping
    // the panel in a filter with no visible way out.
    const second = try buildTree(arena_state.allocator(), &model);
    try testing.expectEqual(@as(?types.Agent, null), firstPressMsg(second.root, second, "CLAUDE").?.filter_agent);
}

test "tables show an overflow indicator instead of dropping rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    var buf: [16]u8 = undefined;
    const extra = 5;
    for (0..max_table_rows + extra) |i| {
        const name = try std.fmt.bufPrint(&buf, "model-{d:0>3}", .{i});
        try seed(&model, .claude, model.now_ms, name, "/w/token-tach", @floatFromInt(i + 1));
    }

    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findText(tree.root, "+5 more"));
    // The cheapest rows are the ones past the cap, and the indicator
    // carries their cost so the visible column still reconciles.
    try testing.expect(findText(tree.root, "$15.00"));
}

test "hourly and daily rollups agree over a span both series cover" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = testModel(testing.allocator);
    defer model.ledger.deinit();
    // Four events inside the last 24 hours: the hourly series and the
    // daily series must be two views of the same money, or the range
    // control silently changes the answer as well as the axis.
    for ([_]i64{ 0, 3, 7, 11 }) |hours_back| {
        try seed(&model, .claude, model.now_ms - hours_back * 3_600_000, "claude-fable-5", "/w/token-tach", 2.5);
    }

    var hourly: [24]ledger_mod.Totals = @splat(.{});
    model.ledger.trailing(.hour, model.now_ms, &hourly);
    var daily: [2]ledger_mod.Totals = @splat(.{});
    model.ledger.trailing(.day, model.now_ms, &daily);

    var hourly_cost: f64 = 0;
    for (hourly) |bucket| hourly_cost += bucket.cost_usd;
    var daily_cost: f64 = 0;
    for (daily) |bucket| daily_cost += bucket.cost_usd;
    try testing.expectApproxEqAbs(@as(f64, 10.0), hourly_cost, 1e-9);
    try testing.expectApproxEqAbs(daily_cost, hourly_cost, 1e-9);

    // And the frame digest reports the same total on either scoping.
    var ui = Ui.init(arena_state.allocator());
    model.ux.time_range = .day;
    const hourly_frame = computeFrame(&ui, &model);
    model.ux.time_range = .week;
    const daily_frame = computeFrame(&ui, &model);
    try testing.expectApproxEqAbs(hourly_frame.totals.cost_usd, daily_frame.totals.cost_usd, 1e-9);
    try testing.expect(!ui.failed);
}

test "the plan band is whole dollars, and stays one line" {
    // The band is the only string on the KPI row assembled from live
    // numbers rather than written down, and it is the one that forced a
    // second line. `expectTextFits` proves the rendered caption fits its
    // box; this proves the FORMAT that keeps it fitting — cents on a
    // published monthly plan price are two guaranteed zeroes per side.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = Ui.init(arena_state.allocator());

    const widest = engine.SubscriptionValue{ .plan_lo_usd = 300, .plan_hi_usd = 400 };
    try testing.expectEqualStrings("$300–400", planBand(&ui, widest));
    try testing.expectEqualStrings("$200", planBand(&ui, .{ .plan_lo_usd = 200, .plan_hi_usd = 200 }));

    // Card content width at the declared 820pt floor: five cards share
    // the row after the window padding and four gaps, each spending
    // `card_pad` per side.
    const card_content_w = (820 - 2 * pad - 4 * gap) / 5 - 2 * card_pad;
    const caption = ui.fmt("vs {s}/mo", .{planBand(&ui, widest)});
    const size = @max(8, theme.tokens().typography.body_size - 1);
    try testing.expect(canvas.estimateTextWidthForFont(canvas.default_sans_font_id, caption, size) <= card_content_w);
}

test "scopes fold live onto the default and describe themselves" {
    try testing.expectEqual(default_scope, scopeIndex(.live));
    try testing.expectEqual(engine.TimeRange.month, scopes[default_scope].range);
    for (scopes) |scope| {
        try testing.expect(scope.buckets <= max_buckets);
        try testing.expect(scope.seg.len > 0);
        // Only spans the hourly retention window actually covers may
        // claim a range-scoped per-agent split.
        if (scope.agent_exact) {
            const days: i64 = switch (scope.unit) {
                .hour => 1,
                .day => @intCast(scope.buckets),
            };
            try testing.expect(days <= ledger_mod.hour_retention_days);
        }
    }
}
