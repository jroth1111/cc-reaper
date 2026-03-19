# Claude Code Memory/Process Issue Coverage Matrix

Generated from `gh issue list --repo anthropics/claude-code` analysis of 200+ issues.

## CRITICAL MEMORY LEAKS (>8GB) — Mitigation Status

| Issue | Title | Severity | Mitigation | Coverage |
|-------|-------|----------|------------|----------|
| #4953 | 120GB+ RAM, OOM killed | CRITICAL | `claude-guard` RSS threshold + `claude-health` warning | ⚠️ PARTIAL |
| #17615 | 304GB memory usage | CRITICAL | Threshold killing at CC_MAX_RSS_MB | ⚠️ PARTIAL |
| #33735 | 18GB private memory | HIGH | `claude-guard` + monitoring | ⚠️ PARTIAL |
| #30470 | 49GB kernel memory allocation | CRITICAL | Threshold kill + NODE_OPTIONS | ⚠️ PARTIAL |
| #11315 | 129GB RAM system freeze | CRITICAL | Threshold kill + NODE_OPTIONS | ⚠️ PARTIAL |
| #12987 | Unbounded memory leak (Linux) | CRITICAL | Threshold kill + NODE_OPTIONS | ⚠️ PARTIAL |
| #21378 | 15GB freeze after 20 min | CRITICAL | Threshold kill + NODE_OPTIONS | ⚠️ PARTIAL |

**Mitigation Gap**: These are root-cause issues requiring upstream fixes. Our mitigation is reactive (threshold-based killing).

## ARRAYBUFFER/STREAMING LEAKS — Mitigation Status

| Issue | Title | Growth Rate | Mitigation | Coverage |
|-------|-------|-------------|------------|----------|
| #33589 | BytesInternalReadableStreamSource | 54 MB/s | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33915 | ArrayBuffers not released | 6 GB/hr | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #32920 | 14K ArrayBuffers streaming | 480 MB/hr | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #32892 | ArrayBuffer accumulation | 92 GB/hr | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33447 | API Response bodies | 181 MB/turn | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33839 | Massive ArrayBuffer allocation | 2.26 GB/40s | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33436 | ArrayBuffer leak | 2.7 GB/64s | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33413 | arrayBuffers 4.2GB fresh session | CRITICAL | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33320 | 2.92 GB external ArrayBuffers | HIGH | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #33551 | ArrayBuffers 950 MB/hr | HIGH | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |
| #34967 | ArrayBuffers 6.3GB in 5 min | HIGH | NODE_OPTIONS cap + threshold | ⚠️ PARTIAL |

**Mitigation Strategy**: 
1. `claude-health` warns if NODE_OPTIONS not set
2. `claude-guard` kills at RSS threshold
3. User must set `export NODE_OPTIONS="--max-old-space-size=8192"`

## PROCESS/ORPHAN LEAKS — Mitigation Status

| Issue | Title | Platform | Mitigation | Coverage |
|-------|-------|----------|------------|----------|
| #33947 | MCP server/subagent orphan accumulation | macOS | Stop hook + LaunchAgent orphan-monitor | ✅ FULL |
| #20369 | Orphaned subagent 30GB memory leak | macOS | PGID cleanup kills entire process group | ✅ FULL |
| #28046 | Caffeinate leak — thousands spawned | macOS | TTY-matched cleanup in stop hook | ✅ FULL |
| #24649 | MCP processes not cleaned on exit | macOS | Stop hook runs on session end | ✅ FULL |
| #19045 | Subagent processes not terminated | Linux | PGID cleanup works on Linux | ✅ FULL |
| #1935 | MCP servers not terminated on exit | macOS | Stop hook + pattern fallback | ✅ FULL |
| #18405 | Orphaned processes crashing computer | All | LaunchAgent monitors every 10 min | ✅ FULL |
| #35673 | MCP subprocesses not cleaned on terminal close | macOS | LaunchAgent catches terminal close | ✅ FULL |
| #34092 | statusLine zombie accumulation | macOS | `claude-check-zombies` detection | 🔍 DETECT |
| #29413 | VS Code extension process leak | Windows | Not covered (different subsystem) | ❌ NONE |
| #32183 | Windows bash.exe orphan shells | Windows | Not covered (platform limitation) | ❌ NONE |

## DISK LEAKS — Mitigation Status

| Issue | Title | Size | Mitigation | Coverage |
|-------|-------|------|------------|----------|
| #26911 | Task .output files | 537 GB | LaunchAgent disk-monitor (threshold/age) | ✅ FULL |
| #34783 | Self-referential disk loop | 696 GB | Disk monitor prevents accumulation | ✅ FULL |
| #24207 | ~/.claude grows unbounded | Variable | `claude-disk` monitoring | 🔍 DETECT |
| #28126 | ~/.claude/tasks/ directories leak | Variable | Disk monitor cleans old files | ✅ FULL |
| #8856 | /tmp/claude-*-cwd tracking files | Variable | Included in disk cleanup | ✅ FULL |

## V8 HEAP/OOM — Mitigation Status

| Issue | Title | Root Cause | Mitigation | Coverage |
|-------|-------|------------|------------|----------|
| #27788 | Unbounded V8 heap reservation | Missing NODE_OPTIONS | `claude-health` warning | 🔍 DETECT |
| #18011 | V8 OOM crashes (SIGABRT) | Heap exhaustion | NODE_OPTIONS cap | ⚠️ PARTIAL |
| #30131 | SIGABRT sudden memory exhaustion | Heap exhaustion | NODE_OPTIONS cap | ⚠️ PARTIAL |
| #19025 | Session JSONL exceeds V8 heap | File size | NODE_OPTIONS cap | ⚠️ PARTIAL |
| #1421 | Heap Out of Memory while thinking | Heap exhaustion | NODE_OPTIONS cap | ⚠️ PARTIAL |

## WINDOWS-SPECIFIC — Mitigation Status

| Issue | Title | Growth Rate | Mitigation | Coverage |
|-------|-------|-------------|------------|----------|
| #32692 | GrowthBook polling leak | 300-700 MB/min | `claude-check-growthbook` + env var | 🔍 DETECT |
| #33588 | Working Set growth (Windows) | 3.5 GB/min | Not covered | ❌ NONE |
| #33415 | WSL2 heap exhaustion | Variable | Not covered | ❌ NONE |
| #33626 | Native memory growth (Win11) | 18.6 MB/s | Not covered | ❌ NONE |
| #29413 | VS Code extension process leak | 11+ GB | Not covered | ❌ NONE |
| #32183 | Windows bash.exe orphan shells | Variable | Not covered | ❌ NONE |
| #24827 | Memory leak in windows | Variable | Not covered | ❌ NONE |
| #24840 | Extreme memory (13GB RSS, 47GB commit) | Variable | Not covered | ❌ NONE |

## COVERAGE SUMMARY

| Category | Total | Fully Mitigated | Partially Mitigated | Detection Only | Not Covered |
|----------|-------|-----------------|--------------------|-----------------|-------------|
| Critical Memory (>8GB) | 7 | 0 | 7 | 0 | 0 |
| ArrayBuffer Leaks | 11 | 0 | 11 | 0 | 0 |
| Process/Orphan Leaks | 11 | 8 | 0 | 1 | 2 |
| Disk Leaks | 5 | 4 | 0 | 1 | 0 |
| V8 Heap/OOM | 5 | 0 | 4 | 1 | 0 |
| Windows-Specific | 8 | 0 | 0 | 1 | 7 |
| **TOTAL** | **47** | **12** | **22** | **4** | **9** |

## MITIGATION TOOLS

| Tool | Purpose | Issues Addressed |
|------|---------|------------------|
| `claude-health` | Comprehensive health check | All issues |
| `claude-check-growthbook` | Detect GrowthBook leak (#32692) | Windows GrowthBook |
| `claude-check-zombies` | Detect statusLine zombies (#34092) | statusLine bug |
| `claude-guard` | Auto-kill bloated sessions | All memory leaks |
| `claude-cleanup` | Kill orphan processes | All process leaks |
| `claude-disk` | Check disk usage | All disk leaks |
| `claude-clean-disk` | Clean temp files | #26911, #34783 |
| `claude-ram` | Memory monitoring | All memory issues |
| `claude-sessions` | Session listing | #33979 |

## AUTOMATIC MITIGATIONS

| Component | Frequency | Purpose | Issues |
|-----------|-----------|---------|--------|
| Stop Hook | Session end | Kill PGID group | Process leaks |
| orphan-monitor | Every 10 min | Kill PPID=1 processes | Orphan processes |
| disk-monitor | Every 1 hour | Clean temp files | Disk leaks |
| guard-monitor | Every 5 min | Kill bloated sessions | Memory leaks |

## RECOMMENDED USER SETUP

```bash
# Add to ~/.zshrc or ~/.bashrc
export NODE_OPTIONS="--max-old-space-size=8192"  # Mitigate #27788
export CC_MAX_RSS_MB=4096                         # Kill at 4GB
export CC_GUARD_MODE=strict                       # Auto-kill bloated
source ~/.cc-reaper/shell/claude-cleanup.sh

# Windows-specific (if applicable)
export CLAUDE_CODE_DISABLE_GROWTHBOOK=1          # Mitigate #32692

# Periodic health check
claude-health

# Check specific issues
claude-check-growthbook  # Windows GrowthBook leak
claude-check-zombies     # statusLine zombie bug
```

## ROOT CAUSE ANALYSIS

### Memory Leaks (Upstream Issues)
- ArrayBuffer accumulation from streaming responses
- API response bodies not garbage collected  
- Native addon memory leaks
- These require upstream fixes; we provide reactive mitigation

### Process Leaks (Platform Limitation)
- macOS lacks `prctl(PR_SET_PDEATHSIG)`
- We fully mitigate via PGID cleanup + LaunchAgent

### V8 Heap (User Configuration)
- Claude Code doesn't set `NODE_OPTIONS` by default
- We warn users but cannot force the setting

### Windows-Specific (Platform Gap)
- Different process model, no PGID
- Would need Windows-specific implementation
- Currently not covered
