# Upstream Issue Coverage

Reviewed against `anthropics/claude-code` issues on 2026-03-19 with `gh issue list` / `gh issue view`.

Search inventory used:

- `memory leak OR out of memory OR OOM OR ArrayBuffer OR arrayBuffers OR RSS OR RAM`
- `orphan OR not terminated OR subagent processes not terminated OR leaked processes OR MCP server`

The upstream issue set is dominated by a few repeat failure modes rather than hundreds of unique bugs. This file tracks which classes `cc-reaper` mitigates, and where it still only offers partial relief.

## Coverage Summary

| Cluster | Representative Issues | Current Mitigation | Status |
|---|---|---|---|
| Orphaned subagents after session exit/crash | #20369, #19045, #19973 | Stop hook PGID kill, manual `claude-cleanup`, LaunchAgent orphan monitor, proc-janitor config | Strong |
| Orphaned / duplicated MCP server processes | #1935, #33947, #35673, #28126 | PGID cleanup, PPID=1 fallback, broadened MCP orphan patterns (`node`, `npx`, `docker`, `python`, `uv`) with whitelist for shared long-lived servers | Strong |
| Live-session ArrayBuffer / native memory growth | #4953, #32920, #33915, #33480, #35171 | `claude-guard` kill threshold, LaunchAgent guard monitor, per-session memory accounting | Strong on macOS LaunchAgent path, Partial elsewhere |
| Idle-session leak / high baseline memory | #18859, #32745, #25545, #27549 | `claude-guard` idle eviction, session visibility via `claude-sessions` | Strong on macOS LaunchAgent path, Partial elsewhere |
| macOS footprint hidden from RSS (`IOAccelerator`, WebKit/JSC) | #35804 | Guard prefers `footprint` over RSS when larger; `claude-sessions` uses the same session-memory accounting | Strong |
| Zombie / runaway child-process explosion | #34092 | `claude-guard` reaps sessions that exceed descendant or zombie thresholds | Strong |
| Session/task-file spillover and startup OOM from large artifacts | #20367, #19025, #28126 | `claude-disk`, `claude-clean-disk`, LaunchAgent disk monitor for temp/task cleanup, visibility into oversized session logs | Partial |
| Remote MCP auto-injection / duplicated active MCP overhead | #20412, #28860 | Guard/orphan cleanup contains the blast radius but does not dedupe active MCP topologies | Partial |
| VS Code extension / Windows renderer-specific leaks | #29413, #35968 | Out of scope for process cleanup in this repo; only indirect mitigation via shell commands where available | Weak / out of scope |

## Notes By Cluster

### Orphaned subagents and MCP servers

These are the cleanest fit for `cc-reaper`. The main protections are:

- Stop-hook PGID kill on normal session exit
- LaunchAgent / proc-janitor PPID=1 orphan sweeps
- Pattern fallback for processes that escaped their group
- Whitelist-aware PGID kills so shared MCP servers are not taken down across healthy sessions

### Live-session memory leaks

Most recent upstream memory reports are not orphan leaks. They are active-session leaks:

- streaming `ArrayBuffer` accumulation
- auto-updater downloads buffered in memory
- idle sessions growing without user interaction
- runaway child trees / zombie subprocess storms

`cc-reaper` mitigates these by reaping bad sessions rather than attempting to fix Claude Code internals:

- `CC_MAX_RSS_MB`
- `CC_MAX_DESCENDANTS`
- `CC_MAX_ZOMBIES`
- `CC_MAX_SESSIONS`

The LaunchAgent guard monitor makes this automatic on macOS.

### macOS footprint vs RSS

Issue [#35804](https://github.com/anthropics/claude-code/issues/35804) shows that RSS can understate true memory cost by an order of magnitude on macOS. `cc-reaper` therefore prefers `footprint` when it is available and larger than RSS. This matters for long-idle sessions where GPU / WebKit allocator pressure is the real failure mode.

### Disk / artifact growth

`cc-reaper` now exposes:

- temp-file visibility and cleanup
- `~/.claude/tasks` visibility
- largest `~/.claude/projects/*.jsonl` visibility

This helps diagnose the startup OOM reports tied to oversized session logs, but it does not yet automatically archive or rotate project session logs. That remains a deliberate gap because those files are user history, not disposable temp files.

## Residual Gaps

`cc-reaper` does **not** currently:

- share MCP servers across concurrent Claude sessions
- disable Claude's remote MCP sync / feature-flag traffic
- fix IDE / VS Code extension memory bugs
- repair Claude Code's internal updater, streaming, or renderer implementations
- automatically rotate or archive `~/.claude/projects/*.jsonl` histories

Those are upstream product/runtime fixes. `cc-reaper` can only contain them from the outside by killing unhealthy sessions and cleaning leaked process/artifact state.
