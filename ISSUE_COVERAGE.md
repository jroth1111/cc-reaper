# Claude Code Memory/Process Issue Coverage Matrix

Generated from `gh issue list --repo anthropics/claude-code` analysis.

## Critical Issues - FULLY MITIGATED ✅

| Issue | Title | Our Mitigation |
|-------|-------|----------------|
| #33947 | MCP server/subagent orphan accumulation (macOS PPID=1) | Stop hook + LaunchAgent orphan-monitor |
| #20369 | Orphaned subagent 30GB memory leak | PGID cleanup kills entire process group |
| #28046 | Caffeinate leak — thousands spawned | TTY-matched cleanup in stop hook |
| #26911 | Task output files 537GB disk | Inspect-only disk monitor + manual temp purge |
| #34783 | Self-referential disk loop 696GB | Inspect-only disk monitor + manual temp purge |
| #24649 | MCP processes not cleaned on exit | Stop hook runs on session end |
| #19045 | Subagent processes not terminated (Linux) | PGID cleanup works on Linux |
| #1935 | MCP servers not terminated on exit | Stop hook + pattern fallback |
| #18405 | Orphaned processes crashing computer | LaunchAgent monitors every 10 min |
| #35673 | MCP subprocesses not cleaned on terminal close | LaunchAgent catches terminal close |

## High Severity - PARTIALLY MITIGATED ⚠️

| Issue | Title | Gap | Mitigation |
|-------|-------|-----|------------|
| #4953 | 120GB+ memory leak, OOM killed | Safe defaults are alert-only for live memory pressure | `claude-guard` RSS threshold alert, opt-in kill |
| #27788 | V8 heap reservation 128GB on large RAM | User must set NODE_OPTIONS | `claude-health` warns if unset |
| #33589 | ArrayBuffer 54MB/s from startup | Root cause upstream | Threshold alert + opt-in kill + NODE_OPTIONS |
| #33915 | ArrayBuffer 6GB/hr growth | Root cause upstream | Threshold alert + opt-in kill |
| #33735 | 18GB private memory | Root cause upstream | Threshold alert + opt-in kill + monitoring |
| #17615 | 304GB+ memory usage | Root cause upstream | Threshold alert + opt-in kill |
| #18011 | V8 OOM crashes (SIGABRT) | Root cause upstream | NODE_OPTIONS cap |

## Medium Severity - DETECTION/MONITORING 🔍

| Issue | Title | Mitigation |
|-------|-------|------------|
| #34092 | statusLine zombie accumulation | `claude-check-zombies` detection |
| #32692 | GrowthBook polling leak (Windows) | `claude-check-growthbook` detection |
| #33480 | High memory on auto-download | Threshold alert + opt-in kill |
| #35804 | IOAccelerator GPU memory leak | Threshold alert + `footprint` accounting |

## Windows-Specific Issues - LIMITED COVERAGE ⚠️

| Issue | Title | Status |
|-------|-------|--------|
| #32692 | GrowthBook leak 300-700MB/min | Detection only, needs env var |
| #33588 | Working Set 3.5GB/min (Windows) | Needs upstream fix |
| #33415 | WSL2 heap exhaustion | Needs upstream fix |
| #29413 | VS Code extension process leak | Not covered (different subsystem) |
| #32183 | Windows bash.exe orphan shells | Not covered |
| #33626 | Native memory 18.6MB/s (Windows 11) | Threshold kill only |

## Coverage Statistics

- **Fully mitigated**: 10 issues
- **Partially mitigated**: 7 issues (threshold-based reactive)
- **Detection/monitoring**: 4 issues
- **Limited coverage (Windows)**: 6 issues
- **Total tracked**: 27 critical/high issues

## Mitigation Tools

| Tool | Purpose | Issues Addressed |
|------|---------|------------------|
| `claude-health` | Comprehensive health check | All issues |
| `claude-check-growthbook` | Detect GrowthBook leak | #32692 |
| `claude-check-zombies` | Detect statusLine zombies | #34092 |
| `claude-guard` | Alert-first live-session guard; auto-kill only for explicitly enabled conditions | #4953, #27788, #33735, #17615 |
| `claude-cleanup` | Kill orphan processes | #33947, #20369, #24649, #19045 |
| `claude-disk` | Check disk usage | #26911, #34783 |
| `claude-clean-disk` | Manual temp purge when no sessions are active | #26911, #34783 |
| `claude-ram` | Memory monitoring | All memory issues |
| `claude-sessions` | Session listing | #33979 |

## Automatic Mitigations

| Component | Frequency | Purpose |
|-----------|-----------|---------|
| Stop Hook | Session end | Kill PGID group |
| orphan-monitor | Every 10 min | Kill PPID=1 processes |
| disk-monitor | Every 1 hour | Inspect temp/tasks/logs without deleting preserved artifacts |
| guard-monitor | Every 2 min | Run safe-default `claude-guard` |

## Recommended User Setup

\`\`\`bash
# Add to ~/.zshrc or ~/.bashrc
export NODE_OPTIONS="--max-old-space-size=8192"  # Mitigate #27788
export CC_MAX_RSS_MB=4096                         # Alert at 4GB
export CC_GUARD_KILL_BLOATED=1                    # Optional: auto-kill bloated live sessions
source ~/.cc-reaper/shell/claude-cleanup.sh

# Optional: Disable GrowthBook on Windows (#32692)
export CLAUDE_CODE_DISABLE_GROWTHBOOK=1

# Periodic health check
claude-health
\`\`\`

## Issue Categories

### ArrayBuffer/Streaming Leaks (Root Cause: Upstream)
These are internal to Node.js/undici streaming and require upstream fixes:
- #33589, #33915, #32920, #33436, #32892, #33447, #33839, #33551

**Our mitigation**: Threshold-based alerting, optional killing, + NODE_OPTIONS heap cap

### Process Orphaning (Root Cause: macOS lacks PR_SET_PDEATHSIG)
These we can fully mitigate:
- #33947, #20369, #24649, #19045, #1935, #18405, #35673

**Our mitigation**: PGID cleanup + LaunchAgent monitoring

### V8 Heap Issues (Root Cause: Missing NODE_OPTIONS)
Require user action:
- #27788, #18011, #30131

**Our mitigation**: Warning in `claude-health`, documentation

### Windows-Specific (Platform limitations)
Cannot fully mitigate without upstream fixes:
- #32692, #33588, #33415, #29413, #32183, #33626

**Our mitigation**: Detection tools, environment variable workarounds
