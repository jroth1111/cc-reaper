# cc-reaper

Automated cleanup and guard rails for Claude Code leaks: orphaned subagents/MCP servers, runaway child trees, and inspect-first visibility into live-session pressure and disk growth.

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

## Solution: Five-Layer Defense

All layers use **PGID-based process group cleanup** as the primary method — killing entire process groups spawned by a Claude session with a single `kill -- -$PGID`. Pattern-based detection is kept as a fallback for edge cases.

```
Session ends normally
  └── Stop hook — kills session's process group via PGID (catches all children)

Session leaks while still running
  └── claude-guard — alert-first for bloated/idle/descendant-heavy sessions, auto-reaps only explicitly enabled conditions
  └── LaunchAgent guard monitor — runs claude-guard every 2 minutes on macOS

Session crashes / terminal force-closed
  └── proc-janitor daemon — scans every 30s, kills orphans after 60s grace
  └── OR: LaunchAgent orphan monitor — zero-dependency macOS native, PGID group kill + PPID=1 fallback

Disk and startup hygiene
  └── disk monitor — inspect-only visibility for temp growth, Claude tasks, and full session logs

Manual intervention needed
  └── claude-cleanup — finds orphaned PGIDs (leader has PPID=1), kills entire groups
  └── claude-sessions / claude-ram — inspect per-session memory, descendants, zombies, and orphan visibility
  └── claude-disk — inspect temp growth and oversized ~/.claude/projects/*.jsonl files
```

### Why PGID?

Claude Code sessions are process group leaders (PGID = session PID). All spawned MCP servers, subagents, and their children inherit this PGID. This means one `kill -- -$PGID` reliably cleans up everything — including third-party MCP servers that pattern matching might miss.

**Safety**: PGID cleanup only targets groups whose **leader** is a Claude CLI session (`claude.*stream-json`). It never matches by group membership — other apps like Chrome and Cursor have `claude` subprocesses in their process groups, so matching by membership would kill them.

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

- `claude-ram` — show RAM/CPU usage breakdown with per-session details and orphan visibility (read-only)
- `claude-sessions` — list all active sessions with idle/runaway detection, descendant counts, zombie counts, and session memory
- `claude-cleanup` — kill orphan processes immediately (PGID group kill + pattern fallback)
- `claude-guard` — safety-first session guard: alerts on bloated/idle sessions by default and only auto-kills explicitly enabled conditions
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

Native macOS approach — no Homebrew or Rust required. Installs three agents:

- orphan monitor — every 10 minutes, PPID=1 + PGID cleanup
- guard monitor — every 2 minutes, runs `claude-guard`
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

`claude-guard` is a safety-first session guard. By default it only auto-kills zombie explosions. Memory-heavy sessions, descendant-heavy live sessions, and excess idle sessions are reported as inspect-only alerts unless you opt into destructive behavior with environment variables. It operates in three phases:

1. **Zombie explosion kill** — Sessions whose zombie count exceeds `CC_MAX_ZOMBIES` are killed immediately by default. This directly mitigates statusline/process-table failures like [#34092](https://github.com/anthropics/claude-code/issues/34092).
2. **Inspect-only pressure alerts** — Sessions whose descendant count exceeds `CC_MAX_DESCENDANTS` or whose session memory exceeds `CC_MAX_RSS_MB` are reported by default. On macOS, the guard prefers `footprint` over RSS when the real footprint is larger, which helps surface IOAccelerator/WebKit-style leaks like [#35804](https://github.com/anthropics/claude-code/issues/35804).
3. **Optional idle eviction** — If session count exceeds `CC_MAX_SESSIONS`, the oldest idle sessions are only killed when `CC_GUARD_KILL_IDLE=1` is explicitly set.

```bash
claude-guard            # run the guard with safe defaults
claude-guard --dry-run  # preview without killing
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max allowed concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Session memory threshold (MB); sessions exceeding this are killed regardless of activity |
| `CC_MAX_DESCENDANTS` | 128 | Descendant-process threshold before a session is treated as runaway |
| `CC_MAX_ZOMBIES` | 16 | Zombie-process threshold before a session is treated as runaway |
| `CC_USE_FOOTPRINT` | 1 | On macOS, use `footprint` when it reports more memory than RSS |
| `CC_GUARD_KILL_ZOMBIES` | 1 | Auto-kill sessions that exceed `CC_MAX_ZOMBIES` |
| `CC_GUARD_KILL_DESCENDANTS` | 0 | Auto-kill sessions that exceed `CC_MAX_DESCENDANTS` |
| `CC_GUARD_KILL_BLOATED` | 0 | Auto-kill sessions that exceed `CC_MAX_RSS_MB` |
| `CC_GUARD_KILL_IDLE` | 0 | Auto-kill oldest idle sessions when above `CC_MAX_SESSIONS` |

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
│   └── stop-cleanup-orphans.sh     # Claude Code Stop hook (PGID + pattern fallback)
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
│   ├── claude-cleanup.sh           # Shell wrapper to source from bash/zsh
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
