#!/bin/bash
# cc-reaper orphan monitor — lightweight alternative to proc-janitor
# Runs periodically via macOS LaunchAgent to detect and kill orphaned
# Claude Code processes (PPID=1, reparented to launchd).
#
# Zero dependencies — no Homebrew, no Rust, just bash + launchd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_HELPERS="$SCRIPT_DIR/claude-process-ledger.bash"
[ -f "$LEDGER_HELPERS" ] || LEDGER_HELPERS="$SCRIPT_DIR/../shell/claude-process-ledger.bash"
[ -f "$LEDGER_HELPERS" ] || LEDGER_HELPERS="$HOME/.cc-reaper/claude-process-ledger.bash"
# shellcheck disable=SC1090
source "$LEDGER_HELPERS"

LOG_DIR="$HOME/.cc-reaper/logs"
LOG_FILE="$LOG_DIR/monitor.log"
mkdir -p "$LOG_DIR"

# Rotate log if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
 mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
 echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

MCP_WHITELIST="${CC_MCP_WHITELIST:-supabase|@stripe/mcp|context7|claude-mem|chroma-mcp}"
ccr_refresh_active_session_snapshots

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# Find orphaned process groups whose leader has PPID=1 and is a Claude process.
killed_pgids=()

orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)

for pgid in $orphan_pgids; do
 # SAFETY: Only kill groups whose leader is a Claude CLI session.
 leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)

 # Must match claude subagent pattern
 if ! echo "$leader_cmd" | grep -qE "claude.*(stream-json|--session-id)"; then
 continue
 fi

 group_info=$(ps -eo pid,pgid,%cpu,%mem,command 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {printf "PID=%s CPU=%s%% MEM=%s%% ", $1, $3, $4}')
 log "KILL SIGTERM group PGID=$pgid ($group_info)"

 # Send SIGTERM first
 kill -- -"$pgid" 2>/dev/null
 killed_pgids+=("$pgid")
done

# ─── Ledger-based fallback (PPID=1 only) ──────────────────────────────────────
# Only kill processes that are TRUE orphans (PPID=1) and were previously
# observed as descendants of a Claude session.
kill_pids=()
while IFS=$'\t' read -r pid pid_pgid cmd; do
 [ -n "$pid" ] || continue

 echo "$cmd" | grep -qE "$MCP_WHITELIST" && continue

 # Skip if already killed via PGID
 already_killed=false
 if [ ${#killed_pgids[@]} -gt 0 ]; then
 for kpgid in "${killed_pgids[@]}"; do
 [ "$pid_pgid" = "$kpgid" ] && already_killed=true && break
 done
 fi
 $already_killed && continue

 cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
 mem=$(ps -o %mem= -p "$pid" 2>/dev/null | tr -d ' ')
 etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
 log "KILL SIGTERM orphan PID=$pid CPU=${cpu}% MEM=${mem}% ELAPSED=$etime CMD=$(echo "$cmd" | head -c 80)"
 kill "$pid" 2>/dev/null
 kill_pids+=("$pid")
done < <(ccr_known_orphan_pids)

total_pgids=${#killed_pgids[@]}
total_pids=${#kill_pids[@]}
if [ "$total_pgids" -eq 0 ] && [ "$total_pids" -eq 0 ]; then
 exit 0
fi

# Wait for graceful shutdown, then SIGKILL survivors
sleep 3

for pgid in "${killed_pgids[@]}"; do
 survivors=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
 for pid in $survivors; do
 kill -9 "$pid" 2>/dev/null
 log "SIGKILL PID=$pid from group PGID=$pgid"
 done
done

for pid in "${kill_pids[@]}"; do
 if kill -0 "$pid" 2>/dev/null; then
 kill -9 "$pid" 2>/dev/null
 log "SIGKILL PID=$pid (did not respond to SIGTERM)"
 fi
done

log "Cleaned $total_pgids orphan process group(s), $total_pids individual process(es)"
