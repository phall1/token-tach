# Allowance-first Token Tach

## Summary

Token Tach becomes a calm menu-bar usage monitor. Its first click answers which
allowance is available, when it resets, and what the user has consumed recently.
The user approved this direction after comparison with Omarchy's Agents panel.

## Design reference

Omarchy `quattro`, commit `31bd80daa4613ffdee995ac27467fce5a2990806`,
`shell/plugins/agents`. Figma: none provided; the approved reference is Omarchy.

## Behavior

1. The default menu-bar glance names the most-used fresh allowance and its used
   percentage. Without fresh limits it shows today's recorded tokens, explicitly
   labeled as usage. Existing custom `tray-format` templates still work.
2. The popover has one reading order: source identity and allowance, seven days
   of recorded tokens, top models over those same seven days, then drill-downs.
   The giant dial, ignition animation, odometer, trip meter and system telemetry
   are absent from this surface. The desktop HUD and history remain available.
3. Only enabled sources with recorded usage or allowance data appear. A chooser
   appears only with multiple sources and supports all known sources without
   squeezing them into one horizontal row. Selection follows source identity,
   survives refreshes, and falls back if that source is disabled or disappears.
4. Source means the harness that recorded usage. A provider is the issuer of an
   allowance. An account is an identity within that provider. These are distinct:
   OpenCode usage is never automatically charged to a Claude/Codex subscription.
   Unknown accounts remain unidentified, and local usage is labeled as local
   harness usage rather than account-wide spend. No model-name billing inference.
5. Allowance meters display used percent, window name and reset countdown.
   Missing limits read as unavailable, never zero. Claude OAuth remains opt-in.
   Codex limits identify their provenance as a local session-log observation.
6. Readings older than five minutes, future-dated observations, or windows whose
   reset has passed are marked stale. Stale readings remain readable but cannot
   drive a confident menu-bar allowance. A passed reset asks for a new reading;
   it never manufactures a zero-percent window. Unknown resets are named.
7. Opening or refreshing the panel refreshes local collection and requests Claude
   limits when permitted by its existing rate-limit/backoff gate. Repeated clicks
   cannot bypass that gate. Refresh does not launch an agent or alter credentials.
8. Authentication/network problems are visible beside the affected allowance.
   Cached readings and local usage stay available. Loading and unavailable history
   states are explicit; the panel never presents an unread archive as seven zeroes.
   A failed archive read retries automatically. If collection has stopped because
   the archive writer is unavailable, the panel asks for a restart to retry it.
9. The seven-day chart includes today, oldest first, in the archive's day timezone.
   If that timezone differs from the current machine it is disclosed. Today is
   partial. Day rows and model rows use exact recorded totals, including cache
   tokens; dollars are labeled API-equivalent, not money actually billed.
10. Sessions is a focused drill-down showing project, harness, model and recent
    activity. Transcript inference reads as recent activity / possible in-flight
    work rather than confirmed running processes. It can show every retained row
    through scrolling. History opens the existing analytical window.
11. Buttons have accessible names and use ordinary keyboard focus/activation.
    The source chooser and session drill-down have an explicit Back action.
    The normal transient popover dismissal behavior is retained.
12. With no data, the app remains discoverable and explains that local usage
    appears after a supported harness is used. Settings and History remain
    reachable. Disabled sources never contribute to the default allowance glance.
13. Historical files, their schema and their stable harness IDs survive the
    reshape. Existing CLI queries and custom telemetry tray tokens remain usable.
