# AGENTS.md

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

Quick reference:
- `bd ready` - find unblocked work
- `bd create "Title" --type task --priority 2` - create an issue
- `bd close <id>` - complete work
- `bd dolt push` - push beads to the configured Dolt remote

For full workflow details: `bd prime`.
