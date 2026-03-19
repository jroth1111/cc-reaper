# Changelog

## [0.7.1] - 2026-03-19

### Changed
- **Session detection now only tracks real Claude session leaders** — guard and snapshot logic require a `claude` process-group leader instead of any command containing the substring `claude`.
- **Automatic cleanup now reaps only Claude-managed descendants** — stop-hook, manual cleanup, and LaunchAgent orphan cleanup no longer kill arbitrary background jobs solely because they once shared Claude ancestry.
- **LaunchAgent guard defaults are now more conservative** — descendant overages are alert-only by default, while bloated/growth kills require minimum session age plus confirmation streaks before reaping.

### Fixed
- **LaunchAgent orphan cleanup no longer SIGKILLs skipped processes in the survivor sweep** after the whitelist/managed-process filters already chose to preserve them.
- **TTY-based `caffeinate` cleanup was removed** because it could kill non-leak user work on the same terminal; managed-process cleanup and ledger proof now cover the Claude-owned case instead.

## [0.7.0] - 2026-03-19

### Added
- **Scoped `claude` launcher wrapper** — Sourcing `claude-cleanup.sh` now wraps `claude` itself and injects `--max-old-space-size=8192` unless the user already set a heap cap or disables the behavior.
- **Growth-rate leak detection** — `claude-guard` now persists per-session samples and can classify a live session as leaking before it reaches the absolute memory ceiling.

### Changed
- **LaunchAgent guard monitor is now an actual mitigation layer** — The macOS guard monitor runs every 30 seconds, lowers its automatic memory ceiling to 3 GB, and auto-reaps bloated, descendant-heavy, zombie-heavy, and fast-growing sessions by default.
- **Manual and automatic orphan cleanup paths are now aligned** — `claude-cleanup` and the LaunchAgent orphan monitor both use the same whitelist-aware PGID kill semantics as the rest of the stack.
- **Installer output now documents the wrapped `claude` command** so the runtime behavior is visible immediately after install/update.

### Fixed
- **`claude-health` now reports the wrapper-backed heap cap correctly** instead of warning as if `NODE_OPTIONS` must always be exported manually.
- **`grep -c` zero-match handling no longer emits duplicated `0` lines** in health and diagnostic output.

## [0.6.0] - 2026-03-19

### Added
- **LaunchAgent guard monitor** — New `launchd/cc-reaper-guard-monitor.sh` plus `com.cc-reaper.guard-monitor.plist` run `claude-guard` every 2 minutes on macOS, so live-session leaks are mitigated without manual intervention.
- **Issue coverage ledger** — Added `ISSUE_COVERAGE.md`, mapping upstream `anthropics/claude-code` leak clusters to current `cc-reaper` mitigations and residual gaps.
- **Disk/session visibility commands** — `claude-disk` and `claude-clean-disk` are now part of the canonical shell helper surface and documented in the install flow.

### Changed
- **Canonical runtime helper path** — Installer now copies the shell helper to `~/.cc-reaper/claude-cleanup.sh` and updates shell startup files to source the installed runtime copy instead of a repo-relative path.
- **LaunchAgent option now installs the full suite** — Orphan monitor, guard monitor, and disk monitor are installed together when the LaunchAgent path is chosen.
- **`claude-guard` now detects more than RSS spikes** — It can reap sessions for runaway descendant counts and zombie explosions, not just oversized memory.
- **macOS guard prefers `footprint` over RSS** when it reports a larger value, which better captures IOAccelerator / WebKit allocator leaks in long-lived sessions.

### Fixed
- **Shell helper divergence** — The repo had drifted between multiple helper copies. The canonical helper now includes cleanup, guard, session inspection, and disk-inspection commands in one place.
- **Fallback orphan matching missed common MCP shapes** — Pattern fallback now covers Docker, Python, `uv`/`uvx`, and generic Node MCP launch styles instead of mainly `npx`/`npm exec`.
- **zsh-sourced helper noise** — Guard and session commands now force local shell semantics under zsh so helper internals do not leak into command output.

## [0.5.1] - 2026-03-12

### Fixed
- **PGID kill now whitelists long-running MCP servers** — Stop hook and `claude-guard` previously killed ALL processes in a session's PGID group, including shared MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp). When a session ended, its MCP servers were killed even if other active sessions were still using them, causing "disabled" status in those sessions.
- **New `_claude_pgid_kill` helper** — Extracted whitelist-aware PGID kill logic into a shared function used by both `claude-guard` (Phase 1 bloated + Phase 2 idle) and the stop hook. Iterates group members individually, skipping whitelisted MCP servers instead of blind `kill -- -$PGID`.

## [0.5.0] - 2026-03-12

### Added
- **`claude-guard` automatic session reaper** — Two-phase guard that kills bloated sessions (tree RSS exceeds threshold) and evicts excess idle sessions
  - Phase 1: Kill sessions whose tree RSS (process + all children/grandchildren) exceeds `CC_MAX_RSS_MB` (default: 4096 MB), regardless of idle/active status
  - Phase 2: Kill oldest idle sessions if count exceeds `CC_MAX_SESSIONS`
  - PGID-based process group termination ensures all child processes are cleaned up
  - macOS desktop notifications when sessions are reaped
  - `--dry-run` flag to preview without killing
- **`CC_MAX_RSS_MB` environment variable** — Configurable RSS threshold (default: 4096 MB) with non-numeric value fallback and warning
- **`_claude_tree_rss` helper function** — Reusable tree RSS calculator (process + children + grandchildren), extracted from `claude-sessions`

### Changed
- `claude-sessions` refactored to use shared `_claude_tree_rss` helper, reducing code duplication

## [0.4.1] - 2026-03-10

### Fixed
- **MCP server false-positive kills** — Long-running MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp) were being killed by pattern-based fallback and proc-janitor, causing repeated disconnections across sessions
- **Overly broad patterns removed** — `node.*claude` and `node.*mcp` matched nearly any node-based MCP process; replaced with specific patterns that only target known short-lived orphans

### Changed
- Long-running MCP servers are now **whitelisted** in proc-janitor and excluded from pattern-based kill in stop hook and `claude-cleanup`
- PGID-based cleanup (primary) still handles session-scoped cleanup correctly — MCP servers are killed when their owning session ends, but not across sessions
- Updated README with explicit proc-janitor config update instructions

## [0.4.0] - 2026-03-10

### Added
- **PGID-based process group cleanup** — Primary detection method across all three layers
  - Stop hook uses session's PGID to kill all child processes (MCP servers, subagents) in one shot, catching unknown third-party servers without pattern maintenance
  - `claude-cleanup` finds orphaned process groups (PGID leader has PPID=1) and kills entire groups via `kill -- -$PGID`
  - LaunchAgent monitor uses PGID-first scanning with pattern-based fallback, avoids duplicate kills
- **Installer update mode** — Re-running `install.sh` detects existing installation and shows "Update" messaging; always overwrites hook/monitor scripts to latest version; shows config diff hint for proc-janitor

### Fixed
- **PGID group kill safety** — Previously matched groups by membership (any process containing "claude"), which killed Chrome and Cursor whose process groups contain `claude --chrome-native-host`. Now only kills groups whose **leader** matches `claude.*stream-json` (orphaned subagent) or `claude.*--session-id` (orphaned session)
- **`claude-cleanup` stream-json missing TTY filter** — Pattern-based fallback killed active sessions' subagents. Added `$7 == "??"` filter to only target detached processes
- **`node.*sequential` too broad** — Narrowed to `node.*sequential-thinking` across all layers to prevent matching unrelated node processes

### Changed
- All three cleanup layers now use a two-pass strategy: PGID-based (primary) → pattern-based (fallback for processes that escaped their group via `setsid()`)
- Stop hook excludes own PID and parent PID from group kill to ensure clean shutdown
- `claude-cleanup` output now shows separate counts for PGID-based and pattern-based kills

## [0.3.0] - 2026-03-09

### Added
- **LaunchAgent daemon** — Zero-dependency macOS native alternative to proc-janitor
  - `launchd/cc-reaper-monitor.sh` — Lightweight orphan monitor (PPID=1 detection)
  - `launchd/com.cc-reaper.orphan-monitor.plist` — LaunchAgent config (runs every 10 minutes)
  - Includes SIGKILL fallback for unresponsive processes and log rotation
- **PPID=1 orphan detection** in `claude-cleanup` — Catches orphans reparented to launchd after crashes, complementing existing TTY-based filtering
- **CPU metrics** in `claude-ram` — All sections now show CPU% alongside RAM
- **Orphans section** in `claude-ram` — New `--- Orphans (PPID=1) ---` section for quick visibility
- **Interactive daemon choice** in installer — Users choose between proc-janitor (feature-rich) and LaunchAgent (zero-dependency)

### Fixed
- **proc-janitor whitelist too broad** — `"node.*server"` was matching `node.*mcp-server`, preventing daemon from cleaning MCP server orphans. Narrowed to `"node.*(dev-server|http-server|next.*server)"` to only protect actual web dev servers

### Updated
- **Broader MCP pattern coverage** across all layers (shell, stop hook, proc-janitor):
  - `npx.*mcp-server` — Catches third-party MCP servers installed via npx (Cloudflare, GitHub, etc.)
- **Installer** now 5-step flow with input validation and context-aware help output

## [0.2.0] - 2026-03-08

### Added
- **`claude-sessions` command** — Lists all active Claude Code CLI sessions with per-session details:
  - PID, RSS, CPU%, elapsed time
  - Idle detection (CPU < 1% = `[IDLE]`)
  - Child process count and full process tree RAM
  - Warnings when ≥4 sessions are open
  - Tips to close idle sessions
- **Per-session breakdown in `claude-ram`** — Now shows individual session PID, RSS, CPU%, and elapsed time instead of just totals
- **Session count warning** — `claude-ram` warns when ≥3 sessions are open and suggests running `claude-sessions`

### Updated
- **New process patterns** across all three layers (shell, stop hook, proc-janitor):
  - `node.*claude-mem.*mcp-server` — claude-mem plugin MCP servers
  - `uv.*chroma-mcp` / `uvx.*chroma-mcp` / `python.*chroma-mcp` — uv/uvx-spawned chroma vector DB
  - `bun.*worker-service` — bun-based worker-service daemons
- **Stop hook** (`stop-cleanup-orphans.sh`) — Added cleanup rules for claude-mem MCP servers, uv/uvx chroma-mcp, and bun worker-service
- **proc-janitor config** (`config.toml`) — Added 5 new target patterns

## [0.1.0] - 2026-03-01

### Added
- Initial release: three-layer orphan process cleanup
- `claude-cleanup` — Kill orphan processes immediately
- `claude-ram` — Show RAM usage breakdown
- Stop hook for automatic cleanup on session end
- proc-janitor daemon config for continuous monitoring
- One-command installer (`install.sh`)
