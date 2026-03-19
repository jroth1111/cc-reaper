# Claude Code Memory/Process Issue Coverage Matrix

Generated from `gh issue list --repo anthropics/claude-code` analysis.

## Issues MITIGATED by cc-reaper

| Issue | Title | Severity | Coverage | Notes |
|-------|-------|----------|----------|-------|
| #33947 | MCP server/subagent orphan accumulation | CRITICAL | ✅ FULL | Stop hook + LaunchAgent kill PPID=1 orphans |
| #20369 | Orphaned subagent 30GB memory leak | CRITICAL | ✅ FULL | PGID cleanup kills entire process group |
| #28046 | Caffeinate leak (1000s/processes) | CRITICAL | ✅ FULL | TTY-matched cleanup in stop hook |
| #26911 | Task output files (537GB disk) | CRITICAL | ✅ FULL | Disk monitor cleans at threshold/age |
| #34783 | Self-referential disk loop (696GB) | CRITICAL | ✅ FULL | Disk monitor prevents accumulation |
| #24649 | MCP processes not cleaned on exit | HIGH | ✅ FULL | Stop hook runs on session end |
| #19045 | Subagent processes not terminated | HIGH | ✅ FULL | PGID cleanup on Linux |
| #1935 | MCP servers not terminated on exit | HIGH | ✅ FULL | Stop hook + pattern fallback |
| #18405 | Orphaned processes crashing computer | HIGH | ✅ FULL | LaunchAgent monitors every 10 min |
| #35673 | MCP subprocesses not cleaned on terminal close | HIGH | ✅ FULL | LaunchAgent catches terminal close |
| #25533 | Chrome-native-host orphan processes | MEDIUM | ✅ PARTIAL | Pattern-based fallback may catch |

## Issues PARTIALLY MITIGATED

| Issue | Title | Severity | Coverage | Gap |
|-------|-------|----------|----------|-----|
| #4953 | 120GB+ memory leak, OOM killed | CRITICAL | ⚠️ PARTIAL | claude-guard kills at RSS threshold, but doesn't prevent growth |
| #27788 | V8 heap reservation (128GB) | CRITICAL | ⚠️ PARTIAL | Threshold kill helps, but user should set NODE_OPTIONS |
| #33589 | ArrayBuffer streaming leak (54MB/s) | HIGH | ⚠️ PARTIAL | Kills at 4GB threshold, but doesn't fix root cause |
| #33915 | ArrayBuffer 6GB/hr growth | HIGH | ⚠️ PARTIAL | Threshold-based reactive, not preventive |
| #32729 | ArrayBuffers 4GB at startup | HIGH | ⚠️ PARTIAL | Threshold kill after fact |
| #33735 | 18GB memory in long session | HIGH | ⚠️ PARTIAL | Threshold kill |
| #17615 | 304GB+ memory usage | CRITICAL | ⚠️ PARTIAL | Threshold kill |

## Issues NOT MITIGATED (require upstream fix)

| Issue | Title | Severity | Type | Notes |
|-------|-------|----------|------|-------|
| #33588 | Working Set 3.5GB/min (Windows) | CRITICAL | Memory leak | Windows-specific, needs upstream |
| #33415 | WSL2 heap exhaustion | CRITICAL | Memory leak | Windows/WSL specific |
| #30131 | SIGABRT from memory exhaustion | CRITICAL | Crash | V8 heap limit |
| #27863 | Sandbox OOM from node_modules | HIGH | Memory | Upstream issue |
| #32692 | GrowthBook polling leak | HIGH | Memory leak | Feature flags issue |
| #34092 | statusLine zombie subprocesses | MEDIUM | Process leak | Different subsystem |
| #29413 | VS Code extension process leak | MEDIUM | Process leak | Windows-specific |
| #32183 | Windows bash.exe orphan shells | MEDIUM | Process leak | Windows-specific |

## Summary Statistics

- **Fully mitigated**: 11 issues
- **Partially mitigated**: 7 issues (threshold-based reactive cleanup)
- **Not mitigated**: 8 issues (require upstream fixes, mostly Windows)
- **Total critical/high issues tracked**: 26

## Recommended User Actions

1. Set `NODE_OPTIONS="--max-old-space-size=8192"` to cap V8 heap (#27788)
2. Run `claude-guard` periodically or set `CC_GUARD_MODE=strict`
3. Monitor with `claude-ram` and `claude-disk`
4. For Windows users: Not fully covered, needs upstream fixes

## Architecture Coverage

```
┌─────────────────────────────────────────────────────────────┐
│                    cc-reaper Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Session End ──► Stop Hook ──► PGID Kill ──► SIGTERM/SIGKILL│
│                      │                                       │
│                      ▼                                       │
│               Pattern Fallback (PPID=1)                     │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Every 10min ──► LaunchAgent ──► Orphan Monitor            │
│                       │                                     │
│                       ▼                                     │
│              PGID + Pattern Kill                            │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Every 1hr ───► Disk Monitor ──► Age-based cleanup         │
│                     │                                       │
│                     ▼                                       │
│              Threshold Delete (10GB)                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```
