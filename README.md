# cc-reaper

Automated cleanup and guard rails for Claude Code leaks: orphaned subagents/MCP servers, live-session memory runaways, hidden macOS footprint growth, and disk pressure.

## The Problem

Claude Code spawns subagent processes and MCP servers for each session. When sessions end (especially abnormally), these processes become orphans (PPID=1) and keep consuming RAM and CPU — often 200-400 MB each, with some (like Cloudflare's MCP server) hitting 550%+ CPU. With multiple sessions over a day, this can accumulate to 7+ GB of wasted memory.

This is a [widely reported issue](https://github.com/anthropics/claude-code/issues/20369) affecting macOS and Linux users.

### What leaks

| Process Type | Pattern | Typical Size |
|---|---|---|
| Subagents | `claude --output-format stream-json` | 180-300 MB each |
| MCP servers (short-lived) | `npx mcp-server-cloudflare`, `npm exec mcp-*`, etc. | 40-110 MB each |
| claude-mem worker | `worker-service.cjs --daemon` (bun) | 100 MB |

> **Preserved by default**: Long-running MCP servers shared across sessions (Supabase, Stripe, context7, claude-mem, chroma-mcp) are whitelisted across all cleanup layers. `~/.claude/projects` session logs and `~/.claude/tasks` files are inspect-only and never deleted by `cc-reaper`.

## Solution: Six-Layer Defense

`cc-reaper` now combines **whitelist-aware PGID cleanup** for orphan/process leaks with a **scoped `claude` launcher wrapper** and a **30-second guard monitor** for live-session memory leaks. For escaped processes, it uses a persisted descendant ledger rather than global MCP-looking regexes as proof.

```
Session starts
  └── sourced `claude` wrapper — injects `NODE_OPTIONS=--max-old-space-size=8192` unless you already set a cap

Session ends normally
  └── Stop hook — records the session's descendant ledger, then reaps only Claude-managed descendants in the session PGID

Session leaks while still running
  └── claude-guard — inspect-first manual command for bloated/idle/descendant-heavy sessions
  └── LaunchAgent guard monitor — runs every 30 seconds and auto-reaps only persistent leak conditions on macOS

Session crashes / terminal force-closed
  └── proc-janitor daemon — scans every 30s, kills regex-matched orphans after 60s grace
  └── OR: LaunchAgent orphan monitor — zero-dependency macOS native, managed-process PGID cleanup + ledger-based PPID=1 fallback

Disk and startup hygiene
  └── disk monitor — inspect-only visibility for temp growth, Claude tasks, and full session logs

Manual intervention needed
  └── claude-cleanup — finds orphaned PGIDs (leader has PPID=1) and ledger-proven orphan descendants
  └── claude-sessions / claude-ram — inspect per-session memory, descendants, zombies, and orphan visibility
  └── claude-disk — inspect temp growth and oversized ~/.claude/projects/*.jsonl files
```

### Why PGID?

Claude Code sessions are process group leaders (PGID = session PID). All spawned MCP servers, subagents, and their children inherit this PGID. `cc-reaper` uses that PGID as the cleanup boundary, but kills members individually so it can preserve shared long-lived MCP servers and avoid reaping unrelated user-launched background work.

**Safety**: PGID cleanup only targets groups whose **leader** is a Claude CLI session (`claude.*stream-json`). The fallback path no longer kills global regex matches. It only kills PPID=`1` processes that were previously recorded as descendants of a real Claude session. Other apps like Chrome and Cursor may have `claude` subprocesses, so proof by session ancestry matters.

## Quick Start

```bash
git clone https://github.com/theQuert/cc-reaper.git
cd cc-reaper
chmod +x install.sh
./install.sh
```

**Updating:**

```bash
git pull
./install.sh
```

The installer copies the sourced shell wrapper and its bash runtime to `~/.cc-reaper/`, refreshes the stop hook, and installs the LaunchAgent suite when that option is selected. For proc-janitor users, manually sync the config:

```bash
cp proc-janitor/config.toml ~/.config/proc-janitor/config.toml
# Edit the log path: replace ~ with your actual home directory
```

## Manual Setup

### 1. Shell Functions

Add to `~/.zshrc` or `~/.bashrc`:

```bash
source /path/to/cc-reaper/shell/claude-cleanup.sh
```

Commands available after restart:

- `claude` — launch Claude Code with `NODE_OPTIONS=--max-old-space-size=8192` unless you already supplied a heap cap; use `command claude` to bypass the wrapper
- `claude-ram` — show RAM/CPU usage breakdown with per-session details and orphan visibility (read-only)
- `claude-sessions` — list all active sessions with idle/runaway detection, descendant counts, zombie counts, and session memory
- `claude-cleanup` — kill orphan Claude-managed processes immediately (managed PGID cleanup + ledger fallback)
- `claude-guard` — inspect-first session guard for bloated/idle/growth/descendant-heavy sessions
- `claude-guard --dry-run` — preview what claude-guard would kill without actually killing
- `claude-disk` — inspect Claude temp files, task files, and large session logs
- `claude-clean-disk --force` — remove `/private/tmp/claude-$UID` only when no Claude sessions are active

### 2. Claude Code Stop Hook

Copy the hook script:

```bash
mkdir -p ~/.claude/hooks
cp hooks/stop-cleanup-orphans.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/stop-cleanup-orphans.sh
```

Add to `~/.claude/settings.json` in the `"Stop"` hooks array:

```json
{
  "type": "command",
  "command": "\"$HOME\"/.claude/hooks/stop-cleanup-orphans.sh",
  "timeout": 15
}
```

<details>
<summary>Full settings.json example</summary>

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME\"/.claude/hooks/stop-cleanup-orphans.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

</details>

### 3. Background Daemon (choose one)

#### Option A: LaunchAgent suite (zero-dependency, macOS only)

Native macOS approach — no Homebrew or Rust required. Installs three agents and is the strongest safety path because it uses the descendant ledger and confirmation gates before destructive guard actions:

- orphan monitor — every 10 minutes, PPID=1 + PGID cleanup
- guard monitor — every 30 seconds, auto-reaps persistent zombies, fast-growth leaks, and sustained bloated sessions
- disk monitor — every hour, records temp/task/log growth without deleting preserved artifacts

```bash
mkdir -p ~/.cc-reaper/logs
cp launchd/cc-reaper-monitor.sh ~/.cc-reaper/
cp launchd/cc-reaper-guard-monitor.sh ~/.cc-reaper/
cp launchd/cc-reaper-disk-monitor.sh ~/.cc-reaper/
chmod +x ~/.cc-reaper/cc-reaper-monitor.sh
chmod +x ~/.cc-reaper/cc-reaper-guard-monitor.sh
chmod +x ~/.cc-reaper/cc-reaper-disk-monitor.sh

# Install and replace __HOME__ with actual path
for label in orphan guard disk; do
  sed "s|__HOME__|$HOME|g" "launchd/com.cc-reaper.${label}-monitor.plist" \
    > "$HOME/Library/LaunchAgents/com.cc-reaper.${label}-monitor.plist"
  launchctl load "$HOME/Library/LaunchAgents/com.cc-reaper.${label}-monitor.plist"
done
```

Useful commands:

```bash
launchctl list | grep cc-reaper           # check if running
cat ~/.cc-reaper/logs/monitor.log         # view cleanup log
cat ~/.cc-reaper/logs/guard-monitor.log   # view guard log
cat ~/.cc-reaper/logs/disk-monitor.log    # view disk log
launchctl unload ~/Library/LaunchAgents/com.cc-reaper.orphan-monitor.plist
launchctl unload ~/Library/LaunchAgents/com.cc-reaper.guard-monitor.plist
launchctl unload ~/Library/LaunchAgents/com.cc-reaper.disk-monitor.plist
```

#### Option B: proc-janitor (feature-rich)

Rust-based daemon with grace period, whitelist, and detailed logging. Requires Homebrew or Cargo.

This path is less precise than the LaunchAgent suite because `proc-janitor` cannot consult the descendant ledger and still relies on orphan regexes.

```bash
# Install
brew install jhlee0409/tap/proc-janitor   # or: cargo install proc-janitor

# Copy config
mkdir -p ~/.config/proc-janitor
cp proc-janitor/config.toml ~/.config/proc-janitor/config.toml
chmod 600 ~/.config/proc-janitor/config.toml
```

Edit `~/.config/proc-janitor/config.toml` and replace `~` in the log path with your actual home directory.

Start daemon:

```bash
brew services start jhlee0409/tap/proc-janitor   # auto-start on boot
proc-janitor start                                # or manual
```

Useful commands:

```bash
proc-janitor scan     # dry run — show orphans without killing
proc-janitor clean    # kill detected orphans
proc-janitor status   # check daemon health
```

## Automatic Session Guard

`claude-guard` is the live-session guard. The manual command stays inspect-first, and the installed LaunchAgent guard monitor only enables destructive actions after the condition persists across multiple samples. It operates in four phases:

1. **Zombie explosion kill** — Sessions whose zombie count exceeds `CC_MAX_ZOMBIES` across confirmation samples are killed. This directly mitigates statusline/process-table failures like [#34092](https://github.com/anthropics/claude-code/issues/34092).
2. **Descendant runaway alert** — Sessions whose managed descendant count exceeds `CC_MAX_DESCENDANTS` are treated as runaway candidates, but the installed LaunchAgent defaults leave this as alert-only to avoid killing legitimate heavy tool execution.
3. **Growth-rate kill** — Sessions whose managed memory is already above `CC_GUARD_MIN_GROWTH_MEM_MB` and still growing faster than `CC_MAX_GROWTH_MB_PER_MIN` across confirmation samples are treated as active leaks even if they have not hit the absolute ceiling yet.
4. **Bloated-session kill** — Sessions whose managed memory exceeds `CC_MAX_RSS_MB` for long enough are treated as bloated. On macOS, the guard prefers `footprint` over RSS when the real footprint is larger, which helps surface IOAccelerator/WebKit-style leaks like [#35804](https://github.com/anthropics/claude-code/issues/35804).

If session count exceeds `CC_MAX_SESSIONS`, the oldest idle sessions are only killed when `CC_GUARD_KILL_IDLE=1` is explicitly set.

```bash
claude-guard            # run the guard with safe defaults
claude-guard --dry-run  # preview without killing
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max allowed concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Session-memory threshold (MB) used for bloated-session detection |
| `CC_MAX_DESCENDANTS` | 128 | Descendant-process threshold before a session is treated as runaway |
| `CC_MAX_ZOMBIES` | 16 | Zombie-process threshold before a session is treated as runaway |
| `CC_MAX_GROWTH_MB_PER_MIN` | 512 | Growth-rate threshold (MB/min) for active leak detection |
| `CC_GUARD_MIN_GROWTH_MEM_MB` | 1024 | Session-memory floor before growth-rate kills can trigger |
| `CC_GUARD_MIN_KILL_AGE_SECONDS` | 180 | Minimum session age before non-zombie auto-kills are allowed |
| `CC_GUARD_CONFIRM_ZOMBIES` | 2 | Consecutive zombie-breach samples required before reaping |
| `CC_GUARD_CONFIRM_DESCENDANTS` | 4 | Consecutive descendant-breach samples required before reaping |
| `CC_GUARD_CONFIRM_GROWTH` | 2 | Consecutive growth-breach samples required before reaping |
| `CC_GUARD_CONFIRM_BLOATED_IDLE` | 2 | Consecutive idle bloated-session samples required before reaping |
| `CC_GUARD_CONFIRM_BLOATED_ACTIVE` | 6 | Consecutive active bloated-session samples required before reaping |
| `CC_USE_FOOTPRINT` | 1 | On macOS, use `footprint` when it reports more memory than RSS |
| `CC_GUARD_KILL_ZOMBIES` | 1 | Auto-kill sessions that exceed `CC_MAX_ZOMBIES` |
| `CC_GUARD_KILL_DESCENDANTS` | 0 | Auto-kill sessions that exceed `CC_MAX_DESCENDANTS` |
| `CC_GUARD_KILL_GROWTH` | 0 | Auto-kill sessions that exceed `CC_MAX_GROWTH_MB_PER_MIN` |
| `CC_GUARD_KILL_BLOATED` | 0 | Auto-kill sessions that exceed `CC_MAX_RSS_MB` |
| `CC_GUARD_KILL_IDLE` | 0 | Auto-kill oldest idle sessions when above `CC_MAX_SESSIONS` |
| `CC_REAPER_AUTO_NODE_OPTIONS` | 1 | Add a scoped `--max-old-space-size` cap to `claude` launches |
| `CC_NODE_MAX_OLD_SPACE_MB` | 8192 | Heap cap injected by the sourced `claude` wrapper |

Installed LaunchAgent defaults are intentionally stricter and safer than the manual command: 30-second cadence, `CC_MAX_RSS_MB=3072`, `CC_MAX_DESCENDANTS=96`, `CC_GUARD_MIN_KILL_AGE_SECONDS=300`, confirmation streaks for every destructive condition, auto-kill enabled for zombie, growth, and bloated-session conditions, and descendant overages left alert-only by default.

Example: lower the threshold to 2 GB but keep inspect-only behavior:

```bash
export CC_MAX_RSS_MB=2048
claude-guard
```

Example: opt into automatic bloated-session reaping:

```bash
export CC_GUARD_KILL_BLOATED=1
claude-guard
```

## Dependencies

| Tool | Required | Install |
|---|---|---|
| bash/zsh | Required | Pre-installed on macOS/Linux |
| macOS LaunchAgent | Option A (recommended) | Built-in, zero dependencies |
| [proc-janitor](https://github.com/jhlee0409/proc-janitor) | Option B | `brew install jhlee0409/tap/proc-janitor` |
| Claude Code | — | The tool this project cleans up after |

## File Structure

```
cc-reaper/
├── install.sh                      # One-command installer/updater (interactive daemon choice)
├── hooks/
│   └── stop-cleanup-orphans.sh     # Claude Code Stop hook (PGID + ledger fallback)
├── ISSUE_COVERAGE.md               # Upstream Claude Code issue-cluster audit and mitigation map
├── launchd/
│   ├── cc-reaper-monitor.sh        # LaunchAgent orphan monitor (PGID + PPID=1 fallback)
│   ├── cc-reaper-guard-monitor.sh  # LaunchAgent live-session guard wrapper
│   ├── cc-reaper-disk-monitor.sh   # LaunchAgent disk hygiene monitor
│   ├── com.cc-reaper.orphan-monitor.plist
│   ├── com.cc-reaper.guard-monitor.plist
│   └── com.cc-reaper.disk-monitor.plist
├── proc-janitor/
│   └── config.toml                 # proc-janitor daemon config (alternative to LaunchAgent)
├── shell/
│   ├── claude-cleanup.sh           # Shell wrapper to source from bash/zsh (also wraps `claude`)
│   └── claude-cleanup-runtime.bash # Bash runtime implementation
└── README.md
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

See [ISSUE_COVERAGE.md](ISSUE_COVERAGE.md) for the upstream `anthropics/claude-code` issue coverage map used to drive the current mitigations.

## Related Issues

- [anthropics/claude-code#20369](https://github.com/anthropics/claude-code/issues/20369) — Orphaned subagent process leaks memory
- [anthropics/claude-code#22554](https://github.com/anthropics/claude-code/issues/22554) — Subagent processes not terminating on macOS
- [anthropics/claude-code#25545](https://github.com/anthropics/claude-code/issues/25545) — Excessive RAM when idle
- [thedotmack/claude-mem#650](https://github.com/thedotmack/claude-mem/issues/650) — worker-service spawns subagents that don't exit

## License

Apache 2.0
