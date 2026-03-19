# Open Claude Code Leak Verification

Analysis date: 2026-03-19 UTC

## Reviewed Searches

- `gh issue list --repo anthropics/claude-code --state open --search "memory" --limit 100`
- `gh issue list --repo anthropics/claude-code --state open --search "leak" --limit 100`
- `gh issue list --repo anthropics/claude-code --state open --search "ArrayBuffer OR arraybuffer OR streaming" --limit 100`

## Current Position

Open Claude Code leak reports still fall into the same broad classes:

1. Live-session memory growth in ArrayBuffers, native memory, or hidden macOS footprint.
2. Orphaned subprocesses, zombie accumulation, and runaway descendant trees.
3. V8 heap exhaustion caused by missing or ineffective heap caps.
4. Disk growth in temp artifacts, task outputs, and preserved logs.
5. Windows-specific leaks outside the current macOS/Linux process model.

`cc-reaper` now mitigates these classes as follows:

| Cluster | Representative issues | Shipped mitigation | Result |
|---|---|---|---|
| Fast ArrayBuffer / external-memory growth | `#33589`, `#33915`, `#33436`, `#32729`, `#34967` | Scoped heap cap on `claude` launch + 30-second LaunchAgent guard + growth-rate kill + 3 GB absolute ceiling | `PARTIAL` |
| Native-memory growth / node-pty / generic CLI leaks | `#32760`, `#33673`, `#34652`, `#25023`, `#33735`, `#17615` | 30-second guard + descendant ceiling + absolute memory ceiling | `PARTIAL` |
| Hidden macOS footprint / GPU leaks | `#35804` | `footprint`-aware memory accounting + 3 GB guard ceiling | `PARTIAL` |
| Orphan subprocesses / zombie explosions / PID pressure | `#20369`, `#33947`, `#35418`, `#34092`, `#35673` | Stop hook + descendant ledger + whitelist-aware orphan monitor + zombie/descendant reaping | `FULL` on macOS/Linux |
| Missing default V8 cap / heap OOM | `#27788`, `#18011`, `#30131`, `#19025`, `#1421` | Scoped `claude` wrapper injects `--max-old-space-size=8192`; `claude-health` exposes bypass cases | `PARTIAL` |
| Disk growth | `#26911`, `#34783`, `#24207`, `#28126` | Inspect-only disk monitor + explicit temp purge | `PARTIAL` / `DETECT` |
| Windows-specific leaks | `#24827`, `#33626`, `#33588`, `#33437`, `#29413`, `#32183` | None | `NONE` |

## Local Verification Evidence

The following checks were run against this repository during the audit:

- `bash -n shell/claude-cleanup-runtime.bash`
- `bash -n launchd/cc-reaper-monitor.sh`
- `bash -n install.sh`
- `zsh -n shell/claude-cleanup.sh`
- `bash -lc 'source shell/claude-cleanup-runtime.bash; claude-guard --dry-run'`
- `bash -lc 'source shell/claude-cleanup-runtime.bash; pid=$$; file=$(_claude_guard_sample_file "$pid"); _claude_guard_write_sample "$pid" 123 456 7 8 9; _claude_guard_read_sample "$pid"; rm -f "$file"'`
- `zsh -lc 'source shell/claude-cleanup.sh; unset NODE_OPTIONS; _claude_node_options'`
- `bash -lc 'source shell/claude-cleanup-runtime.bash; claude-health | sed -n "1,20p"'`

Observed outcomes:

- All edited shell scripts parsed successfully.
- `claude-guard --dry-run` executed cleanly against live local Claude sessions.
- Guard sample persistence read/wrote correctly.
- The sourced shell wrapper resolves a scoped `--max-old-space-size=8192` cap when no user cap is present.
- `claude-health` now reports the wrapper-backed cap instead of falsely warning that `NODE_OPTIONS` is unset.

## Residual Gaps

- The live-session memory-leak mitigations are still reactive. They reduce blast radius; they do not fix upstream leaks.
- The strongest automatic path is the sourced shell wrapper plus the macOS LaunchAgent suite. Proc-janitor users still get orphan cleanup but not live-session growth reaping.
- Windows remains out of scope.
