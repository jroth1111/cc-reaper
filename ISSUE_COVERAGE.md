# Claude Code Memory / Process Issue Coverage

Last reviewed: 2026-03-19 UTC

## Review Inputs

- `gh issue list --repo anthropics/claude-code --state open --search "memory" --limit 100`
- `gh issue list --repo anthropics/claude-code --state open --search "leak" --limit 100`
- `gh issue list --repo anthropics/claude-code --state open --search "ArrayBuffer OR arraybuffer OR streaming" --limit 100`
- Spot-checked issue bodies: `#20369`, `#33947`, `#35418`, `#33589`, `#33915`, `#32760`, `#35804`, `#27788`, `#18011`, `#26911`, `#34783`

## Coverage Semantics

- `FULL` — `cc-reaper` ships an automatic mitigation path that materially contains the issue class on supported platforms.
- `PARTIAL` — `cc-reaper` materially reduces blast radius, but only with reactive reaping, scoped environment caps, or platform limits.
- `DETECT` — `cc-reaper` surfaces the condition but does not automatically mitigate it.
- `NONE` — no shipped mitigation exists.

## Shipped Mitigation Stack

- Sourced `claude` wrapper injects `NODE_OPTIONS=--max-old-space-size=8192` unless the user already supplied a cap or disables `CC_REAPER_AUTO_NODE_OPTIONS`.
- Recommended macOS LaunchAgent guard monitor samples every 30 seconds and auto-reaps:
  - zombie-heavy sessions: `CC_MAX_ZOMBIES=16`
  - descendant-heavy sessions: `CC_MAX_DESCENDANTS=96`
  - fast-growing sessions: `CC_MAX_GROWTH_MB_PER_MIN=512` once memory is already `>= 1024 MB`
  - bloated sessions: `CC_MAX_RSS_MB=3072`
- On macOS, session memory prefers `footprint` over RSS so hidden IOAccelerator/WebKit leaks are visible to the guard.
- Stop hook, manual cleanup, and LaunchAgent orphan monitor all use whitelist-aware PGID cleanup plus ledger-backed orphan proof.
- Disk tooling is inspect-only except explicit `claude-clean-disk --force`.

## Category Matrix

| Category | Representative issues | Current mitigation | Coverage | Residual gap |
|---|---|---|---|---|
| ArrayBuffer / streaming / external-memory leaks | `#33589`, `#33915`, `#33436`, `#32729`, `#33413`, `#34967` | Scoped heap cap on `claude` launch + 30-second growth/bloated-session reaper | `PARTIAL` | Root cause is upstream; very fast spikes can still outrun polling, and proc-janitor users do not get live-session guarding |
| Native / node-pty / generic CLI growth | `#32760`, `#33673`, `#34652`, `#25023`, `#33735`, `#17615` | 30-second growth detection + absolute memory ceiling + descendant ceiling | `PARTIAL` | Still reactive; no native-memory root-cause fix exists locally |
| macOS footprint-hidden / GPU / WebKit leaks | `#35804`, `#18859`, `#33453` | `footprint`-aware accounting + 3 GB guard ceiling + idle session visibility | `PARTIAL` | `cc-reaper` can only recycle the leaking session; it cannot release GPU slabs in-process |
| Orphan processes / subprocess explosions / PID exhaustion | `#20369`, `#33947`, `#24649`, `#35673`, `#35418`, `#34092` | Stop hook + descendant ledger + whitelist-aware orphan monitor + descendant/zombie reaping | `FULL` on macOS/Linux | Windows process-model issues remain out of scope |
| V8 heap reservation / missing default cap | `#27788`, `#18011`, `#30131`, `#19025`, `#1421` | Scoped `claude` wrapper injects `--max-old-space-size=8192`; health check exposes bypass cases | `PARTIAL` | Users who bypass the wrapper with `command claude` or run from unsourced shells lose the automatic cap |
| Disk growth / temp artifacts | `#26911`, `#34783`, `#24207`, `#28126`, `#8856` | Inspect-only disk monitor + explicit temp purge when no sessions are active | `PARTIAL` / `DETECT` | Preserved logs/tasks are intentionally not auto-deleted |
| Windows-specific memory leaks | `#24827`, `#33626`, `#33588`, `#33437`, `#29413`, `#32183` | None | `NONE` | Would require a Windows-specific process/session implementation |

## Bottom Line

- The process-leak class is mitigated well on macOS/Linux.
- The live-session memory-leak class is now automatically mitigated on the recommended macOS LaunchAgent path, but it remains reactive rather than preventive.
- Windows-specific leak reports are still uncovered.
