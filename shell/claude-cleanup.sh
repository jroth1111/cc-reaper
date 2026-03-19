# Claude Code cleanup shell functions
# Add to ~/.zshrc or ~/.bashrc: source /path/to/claude-cleanup.sh

# ─── Utility Functions ─────────────────────────────────────────────────────

# Calculate total RSS (MB) for a process and all descendants (BFS, cycle-safe)
_claude_tree_rss() {
 local pid=$1
 [ -z "$pid" ] && { echo 0; return; }

 local total_kb=0
 local visited=""
 local queue="$pid"

 while [ -n "$queue" ]; do
 local current=${queue%% *}
 queue=${queue#* }
 [ "$queue" = "$current" ] && queue=""

 case " $visited " in
 *" $current "*) continue;;
 esac
 visited="$visited $current"

 local rss=$(ps -o rss= -p "$current" 2>/dev/null | tr -d ' ')
 [ -n "$rss" ] && total_kb=$((total_kb + rss))

 local children=$(pgrep -P "$current" 2>/dev/null)
 [ -n "$children" ] && queue="$queue $children"
 done

 echo $((total_kb / 1024))
}

# ─── Cleanup Functions ─────────────────────────────────────────────────────

claude-cleanup() {
 echo "=== Claude Code Orphan Process Cleanup ==="

 local pgid_kills=0
 local orphan_pgids
 orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)

 for pgid in $orphan_pgids; do
 local leader_cmd
 leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)
 if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|claude.*--session-id"; then
 continue
 fi

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

 # Count orphans and zombies
 local orphan_count
 orphan_count=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | wc -l | tr -d ' ')
 local zombie_count
 zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')

 if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$zombie_count" -eq 0 ]; then
 echo "No orphan processes found."
 return 0
 fi

 [ "$pgid_kills" -gt 0 ] && echo " PGID-based: killed $pgid_kills processes"
 [ "$orphan_count" -gt 0 ] && echo " Orphans: $orphan_count"
 [ "$zombie_count" -gt 100 ] && echo " ⚠️  WARNING: $zombie_count zombies (statusLine bug #34092?)"

 # Kill PPID=1 orphans
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | awk '{print $1}' | while read pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" | awk '{print $1}' | while read pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
 ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[w]orker-service\\.cjs|[b]un.*worker-service" | awk '{print $1}' | while read pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done

 sleep 1
 local remaining
 remaining=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | wc -l | tr -d ' ')
 echo "Cleaned. Remaining orphans: $remaining"
}

claude-ram() {
 echo "=== Claude Code RAM Usage ==="
 echo ""

 echo "--- CLI Sessions ---"
 printf " %-7s %8s %6s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED"
 ps -eo pid,rss,%cpu,etime,command | grep "[c]laude --dangerously" | awk '{printf " %-7s %7d %6s %s\n", $1, $2/1024, $3"%", $4}'

 local session_stats=$(ps aux | grep "[c]laude --dangerously" | awk '{sum+=$6; count++} END {printf "%d %d", count, sum/1024}')
 local session_count=$(echo "$session_stats" | awk '{print $1}')
 local session_mb=$(echo "$session_stats" | awk '{print $2}')
 echo " Total: $session_count sessions, ${session_mb} MB"

 [ "$session_count" -ge 3 ] && echo "" && echo " *** WARNING: $session_count sessions open! ***"

 echo ""
 echo "--- Subagents ---"
 ps aux | grep "[c]laude.*stream-json" | awk '{sum+=$6; cpu+=$3; count++} END {printf " %d subagents, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

 echo "--- MCP Servers ---"
 ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*claude-mem|[b]un.*worker-service|[n]pm exec @supabase" | awk '{sum+=$6; cpu+=$3; count++} END {printf " %d processes, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

 echo "--- Orphans (PPID=1) ---"
 ps -eo pid,ppid,rss,%cpu,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server" | awk '{sum+=$3; count++} END {printf " %d orphans, %.0f MB\n", count, sum/1024}'

 echo "--- Zombies ---"
 local zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')
 [ "$zombie_count" -gt 0 ] && echo " $zombie_count zombie processes"

 echo "--- Total ---"
 ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[w]orker-service|[b]un.*worker" | awk '{sum+=$6; cpu+=$3} END {printf " %.0f MB (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

claude-sessions() {
 echo "=== Claude Code Active Sessions ==="
 echo ""

 printf " %-7s %8s %6s %-14s %-8s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED" "STATUS" "CHILDREN"
 printf " %-7s %8s %6s %-14s %-8s %s\n" "-------" "--------" "------" "--------------" "--------" "--------"

 local session_pids=()
 while IFS= read -r line; do session_pids+=("$line"); done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

 local session_count=0 idle_count=0 total_mb=0

 for pid in "${session_pids[@]}"; do
 local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
 [ -z "$info" ] && continue

 local rss=$(echo "$info" | awk '{print $1}')
 local cpu=$(echo "$info" | awk '{print $2}')
 local etime=$(echo "$info" | awk '{print $3}')
 local rss_mb=$((rss / 1024))

 local proc_status="ACTIVE"
 local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
 [ "$cpu_int" -lt 1 ] && proc_status="[IDLE]" && idle_count=$((idle_count + 1))

 local child_count=0
 while IFS= read -r cpid; do [ -n "$cpid" ] && child_count=$((child_count + 1)); done < <(pgrep -P "$pid" 2>/dev/null)

 printf " %-7s %7s %6s %-14s %-8s %s\n" "$pid" "${rss_mb}" "${cpu}%" "$etime" "$proc_status" "$child_count"
 session_count=$((session_count + 1))
 total_mb=$((total_mb + rss_mb))
 done

 echo ""
 echo " Sessions: $session_count total, $idle_count idle"
 echo " Total RSS: ${total_mb} MB"
}

_claude_pgid_kill() {
 local target_pid=$1
 local MCP_WHITELIST="${CC_MCP_WHITELIST:-supabase|@stripe/mcp|context7|claude-mem|chroma-mcp}"
 local pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')

 if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
 local pids_to_kill=()
 while IFS= read -r pid; do
 [ -z "$pid" ] && continue
 local pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
 echo "$pid_cmd" | grep -qE "$MCP_WHITELIST" && continue
 pids_to_kill+=("$pid")
 done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')

 for pid in "${pids_to_kill[@]}"; do kill "$pid" 2>/dev/null; done
 sleep 2
 for pid in "${pids_to_kill[@]}"; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
 else
 kill "$target_pid" 2>/dev/null; sleep 1
 kill -0 "$target_pid" 2>/dev/null && kill -9 "$target_pid" 2>/dev/null
 fi
}

claude-guard() {
 local dry_run=false
 [ "$1" = "--dry-run" ] && dry_run=true

 local max_sessions=${CC_MAX_SESSIONS:-3}
 local idle_threshold=${CC_IDLE_THRESHOLD:-1}
 local max_rss_mb=${CC_MAX_RSS_MB:-4096}
 local guard_mode=${CC_GUARD_MODE:-strict}
 local grace_secs=${CC_GUARD_GRACE_SECS:-0}

 ! echo "$max_rss_mb" | grep -qE '^[0-9]+$' && max_rss_mb=4096

 # Mitigation #27788: Check NODE_OPTIONS
 if ! echo "$NODE_OPTIONS" | grep -q "max-old-space-size"; then
 echo ""
 echo " ⚠️  NODE_OPTIONS not set — V8 may reserve 50% of system RAM (#27788)"
 echo "    Recommend: export NODE_OPTIONS=\"--max-old-space-size=8192\""
 echo ""
 fi

 echo "=== Claude Guard ==="
 echo " Config: max_sessions=$max_sessions, max_rss=${max_rss_mb} MB, mode=$guard_mode"
 [ "$grace_secs" -gt 0 ] && echo " Grace period: ${grace_secs}s"
 echo ""

 local session_pids=()
 while IFS= read -r line; do session_pids+=("$line"); done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

 local session_count=${#session_pids[@]}
 [ "$session_count" -eq 0 ] && echo " No sessions running." && return 0

 local bloated_pids=() bloated_rss=() idle_pids=() idle_etimes=()

 printf " %-7s %8s %6s %-14s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED" "STATUS"
 for pid in "${session_pids[@]}"; do
 local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
 [ -z "$info" ] && continue
 local rss=$(echo "$info" | awk '{print $1}')
 local cpu=$(echo "$info" | awk '{print $2}')
 local etime=$(echo "$info" | awk '{print $3}')
 local rss_mb=$((rss / 1024))
 local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')

 local status="LIVE"
 if [ "$rss_mb" -ge "$max_rss_mb" ]; then
 status="[BLOATED]"; bloated_pids+=("$pid"); bloated_rss+=("$rss_mb")
 elif [ "$cpu_int" -lt "$idle_threshold" ]; then
 status="[IDLE]"; idle_pids+=("$pid"); idle_etimes+=("$etime")
 fi
 printf " %-7s %7s %6s %-14s %s\n" "$pid" "${rss_mb}" "${cpu}%" "$etime" "$status"
 done

 echo ""
 echo " Sessions: $session_count total, ${#bloated_pids[@]} bloated, ${#idle_pids[@]} idle"

 [ "$guard_mode" = "warn" ] && { [ ${#bloated_pids[@]} -gt 0 ] && echo " WARNING: Bloated sessions detected"; return 0; }

 local killed=0 freed_mb=0
 if [ ${#bloated_pids[@]} -gt 0 ]; then
 echo ""
 echo " --- Killing bloated sessions ---"
 [ "$grace_secs" -gt 0 ] && ! $dry_run && { echo " Waiting ${grace_secs}s..."; sleep "$grace_secs"; }
 for i in "${!bloated_pids[@]}"; do
 local bpid=${bloated_pids[$i]} brss=${bloated_rss[$i]}
 $dry_run && echo " [DRY-RUN] Would kill $bpid (${brss} MB)" && continue
 _claude_pgid_kill "$bpid"
 echo " Killed $bpid (${brss} MB)"
 killed=$((killed + 1)); freed_mb=$((freed_mb + brss))
 done
 fi

 local remaining=$((session_count - killed))
 if [ "$remaining" -gt "$max_sessions" ] && [ ${#idle_pids[@]} -gt 0 ]; then
 local to_kill=$((remaining - max_sessions))
 [ "$to_kill" -gt "${#idle_pids[@]}" ] && to_kill=${#idle_pids[@]}
 echo ""
 echo " --- Killing $to_kill idle session(s) ---"
 for i in $(seq 0 $((to_kill - 1))); do
 local ipid=${idle_pids[$i]}
 $dry_run && echo " [DRY-RUN] Would kill $ipid" && continue
 _claude_pgid_kill "$ipid"
 killed=$((killed + 1))
 done
 fi

 echo ""
 [ "$killed" -gt 0 ] && echo " Reaped $killed session(s), freed ~${freed_mb} MB" || echo " All clear"
}

# NEW: Comprehensive health check
claude-health() {
 echo "=== Claude Code Health Check ==="
 echo ""

 # Memory
 local total_rss=$(ps aux | grep -iE "[c]laude" | awk '{sum+=$6} END {printf "%.0f", sum/1024}')
 echo "--- Memory ---"
 echo " Total RSS: ${total_rss} MB"
 [ "$(echo "$total_rss > 8000" | bc 2>/dev/null || echo 0)" -eq 1 ] && echo " ⚠️  High memory (>8GB)"

 # Processes
 echo ""
 echo "--- Processes ---"
 local session_count=$(ps aux | grep "[c]laude --dangerously" | grep -v grep | wc -l | tr -d ' ')
 local orphan_count=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -c "[c]laude" 2>/dev/null || echo 0)
 local zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')
 echo " Sessions: $session_count"
 echo " Orphans: $orphan_count"
 echo " Zombies: $zombie_count"
 [ "$zombie_count" -gt 100 ] && echo " ⚠️  CRITICAL: Many zombies (#34092)"

 # Disk
 echo ""
 echo "--- Disk ---"
 local tmp_size=$(du -sm /private/tmp/claude-$(id -u) 2>/dev/null | awk '{print $1}')
 echo " Temp: ${tmp_size} MB"
 [ "$(echo "$tmp_size > 5000" | bc 2>/dev/null || echo 0)" -eq 1 ] && echo " ⚠️  Large temp (#26911)"

 # NODE_OPTIONS
 echo ""
 echo "--- V8 Heap Cap ---"
 if echo "$NODE_OPTIONS" | grep -q "max-old-space-size"; then
 echo " ✓ NODE_OPTIONS set"
 else
 echo " ⚠️  NOT SET — V8 may reserve 50% RAM (#27788)"
 echo "    Fix: export NODE_OPTIONS=\"--max-old-space-size=8192\""
 fi
}

# NEW: Check for GrowthBook leak
claude-check-growthbook() {
 echo "=== GrowthBook Connection Check (#32692) ==="
 local gb_conns=$(lsof -i :443 2>/dev/null | grep -c "160.79.104.10" || echo "0")
 if [ "$gb_conns" -gt 4 ]; then
 echo " ⚠️  $gb_conns GrowthBook connections — possible leak"
 echo "    Fix: export CLAUDE_CODE_DISABLE_GROWTHBOOK=1"
 else
 echo " ✓ Normal: $gb_conns connections"
 fi
}

# NEW: Check for zombie accumulation
claude-check-zombies() {
 echo "=== Zombie Process Check (#34092) ==="
 local zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')
 if [ "$zombie_count" -gt 100 ]; then
 echo " ⚠️  CRITICAL: $zombie_count zombies!"
 echo "    May indicate statusLine bug (#34092)"
 echo "    Check ~/.claude/settings.json for statusLine config"
 elif [ "$zombie_count" -gt 10 ]; then
 echo " ⚠️  $zombie_count zombies"
 else
 echo " ✓ Normal: $zombie_count zombies"
 fi
}

claude-disk() {
 echo "=== Claude Code Disk Usage ==="
 echo ""
 local claude_tmp="/private/tmp/claude-$(id -u)"
 [ -d "$claude_tmp" ] && {
 local tmp_size=$(du -sh "$claude_tmp" 2>/dev/null | awk '{print $1}')
 local output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
 echo "--- Task Output Files ---"
 echo " Location: $claude_tmp"
 echo " Size: $tmp_size"
 echo " Files: $output_count"
 }
 local home_size=$(du -sh "$HOME/.claude" 2>/dev/null | awk '{print $1}')
 echo ""
 echo "--- ~/.claude ---"
 echo " Size: $home_size"
 echo ""
 df -h / 2>/dev/null | tail -1 | awk '{printf " Root: %s used, %s free\n", $3, $4}'
}

claude-clean-disk() {
 local force=false
 [ "$1" = "--force" ] && force=true
 local claude_tmp="/private/tmp/claude-$(id -u)"

 if [ -d "$claude_tmp" ]; then
 if $force; then
 echo " Cleaning $claude_tmp ..."
 rm -rf "$claude_tmp"
 echo " Done."
 else
 local output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
 echo " $output_count .output files found"
 echo " Run 'claude-clean-disk --force' to delete"
 fi
 fi
}
