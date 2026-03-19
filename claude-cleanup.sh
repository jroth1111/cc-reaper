# Claude Code cleanup shell functions
# Add to ~/.zshrc or ~/.bashrc: source /path/to/claude-cleanup.sh

# Immediately kill orphan Claude Code processes
claude-cleanup() {
 echo "=== Claude Code Orphan Process Cleanup ==="

 # ─── PGID-based cleanup (primary) ────────────────────────────────────────
 # Find orphaned process groups: the PGID leader has PPID=1 (reparented to launchd)
 # and the group contains Claude-related processes. Kill entire group at once.
 local pgid_kills=0
 local orphan_pgids
 orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)
 for pgid in $orphan_pgids; do
 # Only kill groups whose leader is a Claude session (stream-json subagent)
 local leader_cmd
 leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)
 if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|claude.*--session-id"; then
 continue
 fi
 # Verify group contains Claude/MCP processes
 local match_count
 match_count=$(ps -eo pgid,command 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid' | grep -cE "claude|mcp|chroma|worker-service" 2>/dev/null || echo 0)
 if [ "$match_count" -gt 0 ]; then
 local group_pids
 group_pids=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
 local group_size
 group_size=$(echo "$group_pids" | wc -l | tr -d ' ')
 echo " Killing orphaned process group PGID=$pgid ($group_size processes)"
 kill -- -"$pgid" 2>/dev/null
 pgid_kills=$((pgid_kills + group_size))
 fi
 done

 # ─── Pattern-based fallback (PPID=1 only) ────────────────────────────────
 # Only target TRUE orphans (PPID=1), not just detached processes
 local orphan_count
 orphan_count=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | wc -l | tr -d ' ')
 local mcp_count
 mcp_count=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" | wc -l | tr -d ' ')

 if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ]; then
 echo "No orphan processes found."
 return 0
 fi

 [ "$pgid_kills" -gt 0 ] && echo " PGID-based: killed $pgid_kills processes"
 [ "$orphan_count" -gt 0 ] || [ "$mcp_count" -gt 0 ] && echo " Pattern fallback: $orphan_count subagents, $mcp_count MCP processes"

 # Kill orphaned processes (PPID=1 only)
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | awk '{print $1}' | while read pid; do kill "$pid" 2>/dev/null; done
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" | awk '{print $1}' | while read pid; do kill "$pid" 2>/dev/null; done
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[w]orker-service\\.cjs|[b]un.*worker-service" | awk '{print $1}' | while read pid; do kill "$pid" 2>/dev/null; done

 # NOTE: claude-mem, chroma-mcp, context7, supabase, stripe are NOT killed —
 # they are long-running MCP servers shared across sessions.

 sleep 1
 local remaining
 remaining=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]px.*mcp-server" | wc -l | tr -d ' ')
 echo "Cleaned. Remaining orphans: $remaining"
}

# Show Claude Code RAM usage summary (read-only, no killing)
claude-ram() {
 echo "=== Claude Code RAM Usage ==="
 echo ""

 # --- Per-session breakdown ---
 echo "--- CLI Sessions (per-process) ---"
 printf " %-7s %8s %6s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED"
 ps -eo pid,rss,%cpu,etime,command | grep "[c]laude --dangerously" | awk '{printf " %-7s %7d %6s %s\n", $1, $2/1024, $3"%", $4}'
 local session_stats=$(ps aux | grep "[c]laude --dangerously" | awk '{sum+=$6; count++} END {printf "%d %d", count, sum/1024}')
 local session_count=$(echo "$session_stats" | awk '{print $1}')
 local session_mb=$(echo "$session_stats" | awk '{print $2}')
 echo " Total: $session_count sessions, ${session_mb} MB"

 # Session count warning
 if [ "$session_count" -ge 3 ]; then
 echo ""
 echo " *** WARNING: $session_count sessions open! Consider closing idle ones. ***"
 echo " *** Run 'claude-sessions' for details. ***"
 fi

 echo ""
 echo "--- Subagents ---"
 ps aux | grep "[c]laude.*stream-json" | awk '{sum+=$6; cpu+=$3; count++} END {printf " %d subagents, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

 echo "--- MCP Servers ---"
 ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential-thinking|[w]orker-service|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service|[n]pm exec @supabase" | awk '{sum+=$6; cpu+=$3; count++} END {printf " %d processes, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

 echo "--- Orphans (PPID=1) ---"
 ps -eo pid,ppid,rss,%cpu,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\\.cjs|[n]ode.*claude-mem" | awk '{sum+=$3; cpu+=$4; count++} END {printf " %d orphans, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

 echo "--- Total ---"
 ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential-thinking|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3} END {printf " %.0f MB (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

# Calculate tree RSS (MB) for a given PID: process + all descendants
# Uses process tree traversal, not PGID (more accurate for session memory)
_claude_tree_rss() {
 local pid=$1
 [ -z "$pid" ] && { echo 0; return; }
 
 local total_kb=0
 
 # Get RSS of the process itself
 local rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
 [ -n "$rss" ] && total_kb=$rss
 
 # Recursively get all descendants
 local children
 children=$(pgrep -P "$pid" 2>/dev/null)
 for child in $children; do
 [ -z "$child" ] && continue
 local child_rss=$(_claude_tree_rss "$child")
 total_kb=$((total_kb + child_rss * 1024))  # child_rss is in MB, convert to KB
 done
 
 echo $((total_kb / 1024))  # Return MB
}

# List all active Claude Code sessions with idle detection
claude-sessions() {
 echo "=== Claude Code Active Sessions ==="
 echo ""

 printf " %-7s %8s %6s %-14s %-8s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED" "STATUS" "CHILDREN"
 printf " %-7s %8s %6s %-14s %-8s %s\n" "-------" "--------" "------" "--------------" "--------" "--------"

 # Get session PIDs into an array
 local session_pids=()
 while IFS= read -r line; do
 session_pids+=("$line")
 done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

 local session_count=0
 local idle_count=0
 local total_mb=0

 for pid in "${session_pids[@]}"; do
 local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
 [ -z "$info" ] && continue

 local rss=$(echo "$info" | awk '{print $1}')
 local cpu=$(echo "$info" | awk '{print $2}')
 local etime=$(echo "$info" | awk '{print $3}')
 local rss_mb=$((rss / 1024))

 # Determine idle status: CPU < 1.0% = idle
 local proc_status="ACTIVE"
 local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
 if [ "$cpu_int" -lt 1 ]; then
 proc_status="[IDLE]"
 idle_count=$((idle_count + 1))
 fi

 # Count children (direct only for speed)
 local child_count=0
 while IFS= read -r cpid; do
 [ -z "$cpid" ] && continue
 child_count=$((child_count + 1))
 done < <(pgrep -P "$pid" 2>/dev/null)

 printf " %-7s %7s %6s %-14s %-8s %s\n" \
 "$pid" "${rss_mb}" "${cpu}%" "$etime" "$proc_status" "$child_count"

 session_count=$((session_count + 1))
 total_mb=$((total_mb + rss_mb))
 done

 echo ""
 echo " Sessions: $session_count total, $idle_count idle"
 echo " Total RSS: ${total_mb} MB ($(awk "BEGIN {printf \"%.1f\", $total_mb/1024}") GB)"

 if [ "$idle_count" -gt 0 ] && [ "$session_count" -gt 0 ]; then
 local idle_mb=$((total_mb * idle_count / session_count))
 echo ""
 echo " TIP: Close idle sessions in their iTerm tabs to free ~${idle_mb} MB"
 echo " Or use '/exit' in each idle Claude Code session."
 fi

 if [ "$session_count" -ge 4 ]; then
 echo ""
 echo " WARNING: $session_count sessions is excessive. Each session + MCP servers = 400-900 MB."
 echo " Consider keeping max 2-3 active sessions."
 fi
}

# Kill a session's process group while preserving whitelisted MCP servers
# Usage: _claude_pgid_kill <pid>
_claude_pgid_kill() {
 local target_pid=$1
 local MCP_WHITELIST="${CC_MCP_WHITELIST:-supabase|@stripe/mcp|context7|claude-mem|chroma-mcp}"
 local pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')
 
 if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
 # Send SIGTERM first
 while IFS= read -r pid; do
 [ -z "$pid" ] && continue
 local pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
 if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
 continue
 fi
 kill "$pid" 2>/dev/null
 done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
 
 # Wait then SIGKILL survivors
 sleep 2
 while IFS= read -r pid; do
 [ -z "$pid" ] && continue
 local pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
 if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
 continue
 fi
 if kill -0 "$pid" 2>/dev/null; then
 kill -9 "$pid" 2>/dev/null
 fi
 done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
 else
 kill "$target_pid" 2>/dev/null
 fi
}

# Automatic session guard: kills bloated (RSS threshold) and idle sessions
# Usage: claude-guard [--dry-run]
# Config env vars:
# CC_MAX_SESSIONS — max allowed sessions (default: 3)
# CC_IDLE_THRESHOLD — CPU% below which a session is idle (default: 1)
# CC_MAX_RSS_MB — tree RSS threshold in MB; sessions exceeding this are killed (default: 4096)
claude-guard() {
 local dry_run=false
 [ "$1" = "--dry-run" ] && dry_run=true

 # ─── Configuration ─────────────────────────────────────────────────────
 local max_sessions=${CC_MAX_SESSIONS:-3}
 local idle_threshold=${CC_IDLE_THRESHOLD:-1}
 local max_rss_mb=${CC_MAX_RSS_MB:-4096}

 # Validate CC_MAX_RSS_MB is numeric
 if ! echo "$max_rss_mb" | grep -qE '^[0-9]+$'; then
 echo " WARNING: CC_MAX_RSS_MB='$max_rss_mb' is not numeric, using default 4096"
 max_rss_mb=4096
 fi

 echo "=== Claude Guard ==="
 echo " Config: max_sessions=$max_sessions, idle_threshold=${idle_threshold}%, max_rss=${max_rss_mb} MB"
 echo ""

 # ─── Gather sessions ───────────────────────────────────────────────────
 local session_pids=()
 while IFS= read -r line; do
 session_pids+=("$line")
 done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

 local session_count=${#session_pids[@]}
 if [ "$session_count" -eq 0 ]; then
 echo " No Claude Code sessions running."
 return 0
 fi

 # ─── Classify sessions ─────────────────────────────────────────────────
 local bloated_pids=()
 local bloated_rss=()
 local idle_pids=()
 local idle_etimes=()
 local live_count=0

 printf " %-7s %8s %6s %-14s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED" "STATUS"
 printf " %-7s %8s %6s %-14s %s\n" "-------" "--------" "------" "--------------" "--------"

 for pid in "${session_pids[@]}"; do
 local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
 [ -z "$info" ] && continue

 local rss=$(echo "$info" | awk '{print $1}')
 local cpu=$(echo "$info" | awk '{print $2}')
 local etime=$(echo "$info" | awk '{print $3}')
 local rss_mb=$((rss / 1024))
 local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')

 # Determine status: bloated takes priority over idle
 local status="LIVE"
 if [ "$rss_mb" -ge "$max_rss_mb" ]; then
 status="[BLOATED]"
 bloated_pids+=("$pid")
 bloated_rss+=("$rss_mb")
 elif [ "$cpu_int" -lt "$idle_threshold" ]; then
 status="[IDLE]"
 idle_pids+=("$pid")
 idle_etimes+=("$etime")
 else
 live_count=$((live_count + 1))
 fi

 printf " %-7s %7s %6s %-14s %s\n" "$pid" "${rss_mb}" "${cpu}%" "$etime" "$status"
 done

 echo ""
 echo " Sessions: $session_count total, ${#bloated_pids[@]} bloated, ${#idle_pids[@]} idle, $live_count live"

 # ─── Phase 1: Kill bloated sessions (regardless of count) ──────────────
 local killed=0
 local freed_mb=0

 if [ ${#bloated_pids[@]} -gt 0 ]; then
 echo ""
 echo " --- Killing bloated sessions (RSS > ${max_rss_mb} MB) ---"
 for i in "${!bloated_pids[@]}"; do
 local bpid=${bloated_pids[$i]}
 local brss=${bloated_rss[$i]}
 if $dry_run; then
 echo " [DRY-RUN] Would kill PID $bpid (RSS: ${brss} MB, threshold: ${max_rss_mb} MB)"
 else
 _claude_pgid_kill "$bpid"
 echo " Killed PID $bpid (RSS: ${brss} MB, threshold: ${max_rss_mb} MB)"
 killed=$((killed + 1))
 freed_mb=$((freed_mb + brss))
 osascript -e "display notification \"Killed session PID $bpid — ${brss} MB (threshold: ${max_rss_mb} MB)\" with title \"Claude Guard\" subtitle \"Bloated session reaped\"" 2>/dev/null &
 fi
 done
 fi

 # ─── Phase 2: Kill idle sessions if over max_sessions ──────────────────
 local remaining=$((session_count - killed))
 if [ "$remaining" -gt "$max_sessions" ] && [ ${#idle_pids[@]} -gt 0 ]; then
 local to_kill=$((remaining - max_sessions))
 [ "$to_kill" -gt "${#idle_pids[@]}" ] && to_kill=${#idle_pids[@]}

 echo ""
 echo " --- Killing $to_kill idle session(s) to reach limit of $max_sessions ---"
 for i in $(seq 0 $((to_kill - 1))); do
 local ipid=${idle_pids[$i]}
 local ietime=${idle_etimes[$i]}
 local irss=$(ps -o rss= -p "$ipid" 2>/dev/null | awk '{printf "%d", $1/1024}')
 if $dry_run; then
 echo " [DRY-RUN] Would kill PID $ipid (idle ${ietime}, RSS: ${irss} MB)"
 else
 _claude_pgid_kill "$ipid"
 echo " Killed PID $ipid (idle ${ietime}, RSS: ${irss} MB)"
 killed=$((killed + 1))
 freed_mb=$((freed_mb + irss))
 fi
 done
 fi

 # ─── Summary ───────────────────────────────────────────────────────────
 echo ""
 if [ "$killed" -gt 0 ]; then
 echo " Reaped $killed session(s), freed ~${freed_mb} MB"
 if ! $dry_run; then
 osascript -e "display notification \"Reaped $killed session(s), freed ~${freed_mb} MB\" with title \"Claude Guard\" subtitle \"Cleanup complete\"" 2>/dev/null &
 fi
 elif $dry_run && [ ${#bloated_pids[@]} -eq 0 ] && [ "$remaining" -le "$max_sessions" ]; then
 echo " All clear — no sessions to reap."
 elif ! $dry_run; then
 echo " All clear — no sessions to reap."
 fi
}

claude-disk() {
 echo "=== Claude Code Disk Usage ==="
 echo ""

 local claude_tmp="/private/tmp/claude-$(id -u)"
 local claude_home="$HOME/.claude"

 if [ -d "$claude_tmp" ]; then
 local tmp_size=$(du -sh "$claude_tmp" 2>/dev/null | awk '{print $1}')
 local output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
 echo "--- Task Output Files ---"
 echo " Location: $claude_tmp"
 echo " Total size: $tmp_size"
 echo " .output files: $output_count"

 if [ "$output_count" -gt 0 ]; then
 echo ""
 echo " Largest files:"
 find "$claude_tmp" -name "*.output" -type f -exec ls -lh {} \; 2>/dev/null | sort -k5 -hr | head -5 | awk '{printf " %s %s\n", $5, $NF}'
 fi
 fi

 if [ -d "$claude_home" ]; then
 local home_size=$(du -sh "$claude_home" 2>/dev/null | awk '{print $1}')
 echo ""
 echo "--- ~/.claude Directory ---"
 echo " Location: $claude_home"
 echo " Total size: $home_size"

 local jsonl_count=$(find "$claude_home" -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
 local tasks_count=$(find "$claude_home/tasks" -type f 2>/dev/null | wc -l | tr -d ' ')
 echo " .jsonl files: $jsonl_count"
 echo " task files: $tasks_count"
 fi

 echo ""
 echo "--- Disk Summary ---"
 df -h / 2>/dev/null | tail -1 | awk '{printf " Root filesystem: %s used, %s available\n", $3, $4}'
}

claude-clean-disk() {
 local force=false
 [ "$1" = "--force" ] && force=true

 echo "=== Claude Code Disk Cleanup ==="

 local claude_tmp="/private/tmp/claude-$(id -u)"
 local claude_home="$HOME/.claude"

 if [ -d "$claude_tmp" ]; then
 local before_size=$(du -s "$claude_tmp" 2>/dev/null | awk '{print $1}')

 if $force; then
 echo " Cleaning $claude_tmp ..."
 rm -rf "$claude_tmp"
 local freed_mb=$((before_size * 512 / 1048576))
 [ "$freed_mb" -gt 0 ] && echo " Freed ~${freed_mb} MB"
 else
 local output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
 local tmp_size=$(du -sh "$claude_tmp" 2>/dev/null | awk '{print $1}')
 echo " Found $output_count .output files ($tmp_size)"
 echo ""
 echo " Run 'claude-clean-disk --force' to delete ALL temp files"
 echo " (Claude Code will recreate directories as needed)"
 echo ""
 echo " Or delete specific sessions:"
 ls -d "$claude_tmp"/*/ 2>/dev/null | head -5 | while read dir; do
 local dsize=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
 echo " rm -rf \"$dir\" # $dsize"
 done
 fi
 fi

 if [ -d "$claude_home/tasks" ]; then
 local tasks_size=$(du -sh "$claude_home/tasks" 2>/dev/null | awk '{print $1}')
 local tasks_count=$(find "$claude_home/tasks" -type f 2>/dev/null | wc -l | tr -d ' ')
 if [ "$tasks_count" -gt 10 ]; then
 echo ""
 echo " Note: $tasks_count files in ~/.claude/tasks/ ($tasks_size)"
 echo " Consider: rm -rf ~/.claude/tasks/"
 fi
 fi
}

_claude_disk_check() {
 local claude_tmp="/private/tmp/claude-$(id -u)"
 local max_gb=${CLAUDE_DISK_MAX_GB:-10}

 if [ -d "$claude_tmp" ]; then
 local tmp_kb=$(du -sk "$claude_tmp" 2>/dev/null | awk '{print $1}')
 local tmp_gb=$((tmp_kb / 1048576))

 if [ "$tmp_gb" -ge "$max_gb" ]; then
 echo "WARNING: Claude temp directory exceeds ${max_gb}GB: ${tmp_gb}GB" >&2
 echo "Run 'claude-clean-disk --force' to clean" >&2
 return 1
 fi
 fi
 return 0
}
