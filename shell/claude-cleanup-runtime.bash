# Claude Code cleanup shell functions
# Runtime implementation executed under bash

_claude_mcp_whitelist_regex() {
  echo "${CC_MCP_WHITELIST:-supabase|@stripe/mcp|context7|claude-mem|chroma-mcp}"
}

_claude_orphan_mcp_pattern() {
  echo "docker run .*mcp/|npm exec @upstash|npm exec mcp-|npx.*mcp-server|node.*mcp-server|node.*sequential-thinking|python.*mcp|uvx?.*mcp|worker-service\\.cjs|bun.*worker-service"
}

_claude_subagent_pattern() {
  echo "claude.*stream-json|claude.*--session-id"
}

_claude_is_whitelisted_mcp_cmd() {
  local cmd=$1
  [ -z "$cmd" ] && return 1
  echo "$cmd" | grep -qE "$(_claude_mcp_whitelist_regex)"
}

_claude_session_pids() {
  ps -eo pid,ppid,tty,command 2>/dev/null | awk '
    $2 != 1 &&
    $3 != "??" &&
    $0 ~ /claude/ &&
    $0 !~ /stream-json/ &&
    $0 !~ /worker-service/ &&
    $0 !~ /claude-cleanup\.sh/ &&
    $0 !~ /stop-cleanup-orphans\.sh/ &&
    $0 !~ /cc-reaper/ &&
    $0 !~ /mcp-server/ {
      print $1
    }
  '
}

_claude_active_session_count() {
  local count=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    count=$((count + 1))
  done < <(_claude_session_pids)
  echo "$count"
}

_claude_process_rss_mb() {
  local pid=$1
  local rss
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$rss" ] && echo 0 && return
  echo $((rss / 1024))
}

_claude_process_footprint_mb() {
  local pid=$1
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || { echo 0; return; }
  command -v footprint >/dev/null 2>&1 || { echo 0; return; }

  footprint -p "$pid" 2>/dev/null | awk '
    tolower($0) ~ /footprint:/ {
      for (i = 1; i <= NF; i++) {
        if (tolower($i) ~ /footprint:/) {
          value = $(i + 1)
          unit = $(i + 2)
          gsub(/,/, "", value)
          if (unit == "GB") { printf "%d\n", value * 1024; exit }
          if (unit == "MB") { printf "%d\n", value; exit }
          if (unit == "KB") { printf "%d\n", value / 1024; exit }
        }
      }
    }
  ' | head -n 1
}

_claude_process_memory_mb() {
  local pid=$1
  local rss_mb footprint_mb
  rss_mb=$(_claude_process_rss_mb "$pid")

  if [ "${CC_USE_FOOTPRINT:-1}" != "0" ]; then
    footprint_mb=$(_claude_process_footprint_mb "$pid")
  else
    footprint_mb=0
  fi

  if [ -n "$footprint_mb" ] && [ "$footprint_mb" -gt "$rss_mb" ]; then
    echo "$footprint_mb"
  else
    echo "$rss_mb"
  fi
}

_claude_descendants() {
  local pid=$1
  local child

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    echo "$child"
    _claude_descendants "$child"
  done < <(pgrep -P "$pid" 2>/dev/null)
}

_claude_tree_rss() {
  local pid=$1
  [ -z "$pid" ] && { echo 0; return; }

  local total_mb
  total_mb=$(_claude_process_rss_mb "$pid")

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    total_mb=$((total_mb + $(_claude_process_rss_mb "$child")))
  done < <(_claude_descendants "$pid")

  echo "$total_mb"
}

_claude_session_memory_mb() {
  local pid=$1
  [ -z "$pid" ] && { echo 0; return; }

  local total_mb
  total_mb=$(_claude_process_memory_mb "$pid")

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    local child_cmd child_mb
    child_cmd=$(ps -o command= -p "$child" 2>/dev/null)
    if echo "$child_cmd" | grep -q "claude"; then
      child_mb=$(_claude_process_memory_mb "$child")
    else
      child_mb=$(_claude_process_rss_mb "$child")
    fi
    total_mb=$((total_mb + child_mb))
  done < <(_claude_descendants "$pid")

  echo "$total_mb"
}

_claude_descendant_count() {
  local pid=$1
  local count=0

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    count=$((count + 1))
  done < <(_claude_descendants "$pid")

  echo "$count"
}

_claude_zombie_count() {
  local pid=$1
  local count=0

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    local stat
    stat=$(ps -o stat= -p "$child" 2>/dev/null | tr -d ' ')
    [ -n "$stat" ] && [ "${stat#Z}" != "$stat" ] && count=$((count + 1))
  done < <(_claude_descendants "$pid")

  echo "$count"
}

_claude_etime_to_seconds() {
  local etime=$1
  awk -v etime="$etime" '
    BEGIN {
      days = 0
      split(etime, parts, "-")
      if (length(parts) == 2) {
        days = parts[1]
        time = parts[2]
      } else {
        time = etime
      }

      n = split(time, clock, ":")
      if (n == 3) {
        hours = clock[1]
        mins = clock[2]
        secs = clock[3]
      } else if (n == 2) {
        hours = 0
        mins = clock[1]
        secs = clock[2]
      } else {
        hours = 0
        mins = 0
        secs = clock[1]
      }

      print (days * 86400) + (hours * 3600) + (mins * 60) + secs
    }
  '
}

_claude_guard_notify() {
  [ "${CC_GUARD_NOTIFY:-1}" = "0" ] && return
  command -v osascript >/dev/null 2>&1 || return
  local title=$1
  local subtitle=$2
  local message=$3
  osascript -e "display notification \"$message\" with title \"$title\" subtitle \"$subtitle\"" 2>/dev/null &
}

_claude_pgid_kill() {
  local target_pid=$1
  local pgid
  pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')

  if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      local pid_cmd
      pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
      _claude_is_whitelisted_mcp_cmd "$pid_cmd" && continue
      kill "$pid" 2>/dev/null
    done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')

    sleep 2
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      local pid_cmd
      pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
      _claude_is_whitelisted_mcp_cmd "$pid_cmd" && continue
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
  else
    kill "$target_pid" 2>/dev/null
  fi
}

claude-cleanup() {
  echo "=== Claude Code Orphan Process Cleanup ==="

  local pgid_kills=0
  local orphan_pgids leader_pattern mcp_pattern
  leader_pattern=$(_claude_subagent_pattern)
  mcp_pattern=$(_claude_orphan_mcp_pattern)

  orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)
  for pgid in $orphan_pgids; do
    local leader_cmd
    leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)

    if ! echo "$leader_cmd" | grep -qE "$leader_pattern"; then
      continue
    fi

    local match_count group_pids group_size
    match_count=$(ps -eo pgid,command 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid' | grep -cE "claude|mcp|worker-service|docker run .*mcp/" 2>/dev/null || echo 0)
    if [ "$match_count" -gt 0 ]; then
      group_pids=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
      group_size=$(echo "$group_pids" | wc -l | tr -d ' ')
      echo "  Killing orphaned process group PGID=$pgid ($group_size processes)"
      kill -- -"$pgid" 2>/dev/null
      pgid_kills=$((pgid_kills + group_size))
    fi
  done

  local fallback_candidates=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local cmd
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    _claude_is_whitelisted_mcp_cmd "$cmd" && continue
    fallback_candidates=$((fallback_candidates + 1))
  done < <(
    ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | \
      grep -E "($leader_pattern)|($mcp_pattern)" | \
      awk '{print $1}'
  )

  if [ "$pgid_kills" -eq 0 ] && [ "$fallback_candidates" -eq 0 ]; then
    echo "No orphan processes found."
    return 0
  fi

  [ "$pgid_kills" -gt 0 ] && echo "  PGID-based: killed $pgid_kills processes"
  [ "$fallback_candidates" -gt 0 ] && echo "  Pattern fallback: $fallback_candidates escaped orphan(s)"

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local cmd
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    _claude_is_whitelisted_mcp_cmd "$cmd" && continue
    kill "$pid" 2>/dev/null
  done < <(
    ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | \
      grep -E "($leader_pattern)|($mcp_pattern)" | \
      awk '{print $1}'
  )

  sleep 1
  local remaining=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local cmd
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    _claude_is_whitelisted_mcp_cmd "$cmd" && continue
    remaining=$((remaining + 1))
  done < <(
    ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | \
      grep -E "($leader_pattern)|($mcp_pattern)" | \
      awk '{print $1}'
  )

  echo "Cleaned. Remaining orphans: $remaining"
}

claude-ram() {
  echo "=== Claude Code RAM Usage ==="
  echo ""

  echo "--- CLI Sessions ---"
  printf "  %-7s %8s %6s %s\n" "PID" "MEM(MB)" "CPU%" "ELAPSED"

  local session_count=0
  local session_mb=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local info cpu etime mem_mb
    info=$(ps -p "$pid" -o %cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue
    cpu=$(echo "$info" | awk '{print $1}')
    etime=$(echo "$info" | awk '{print $2}')
    mem_mb=$(_claude_session_memory_mb "$pid")
    printf "  %-7s %8s %6s %s\n" "$pid" "$mem_mb" "${cpu}%" "$etime"
    session_count=$((session_count + 1))
    session_mb=$((session_mb + mem_mb))
  done < <(_claude_session_pids)
  echo "  Total: $session_count sessions, ${session_mb} MB"

  if [ "$session_count" -ge 3 ]; then
    echo ""
    echo "  WARNING: $session_count sessions open. Run 'claude-sessions' for per-session detail."
  fi

  echo ""
  echo "--- Subagents ---"
  ps aux | grep "[c]laude.*stream-json" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d subagents, %.0f MB RSS, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- MCP Servers ---"
  ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[d]ocker run .*mcp/|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential-thinking|[w]orker-service|[n]ode.*claude-mem|[u]vx?.*mcp|[p]ython.*mcp|[b]un.*worker-service|[n]pm exec @supabase" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d processes, %.0f MB RSS, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Orphans (PPID=1) ---"
  ps -eo pid,ppid,rss,%cpu,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[d]ocker run .*mcp/|[c]hroma-mcp|[w]orker-service\\.cjs|[n]ode.*claude-mem|[p]ython.*mcp|[u]vx?.*mcp" | awk '{sum+=$3; cpu+=$4; count++} END {printf "  %d orphans, %.0f MB RSS, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Total ---"
  ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[d]ocker run .*mcp/|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential-thinking|[n]ode.*claude-mem|[u]vx?.*mcp|[p]ython.*mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3} END {printf "  %.0f MB RSS (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

claude-sessions() {
  echo "=== Claude Code Active Sessions ==="
  echo ""

  printf "  %-7s %8s %6s %-10s %-6s %-6s %s\n" "PID" "MEM(MB)" "CPU%" "ELAPSED" "PROC" "ZOMB" "STATUS"
  printf "  %-7s %8s %6s %-10s %-6s %-6s %s\n" "-------" "--------" "------" "----------" "------" "------" "--------"

  local session_count=0
  local idle_count=0
  local total_mb=0
  local total_desc=0
  local total_zombies=0
  local max_descendants=${CC_MAX_DESCENDANTS:-128}
  local max_zombies=${CC_MAX_ZOMBIES:-16}

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue

    local info cpu etime mem_mb desc_count zombie_count cpu_int session_status
    info=$(ps -p "$pid" -o %cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue

    cpu=$(echo "$info" | awk '{print $1}')
    etime=$(echo "$info" | awk '{print $2}')
    mem_mb=$(_claude_session_memory_mb "$pid")
    desc_count=$(_claude_descendant_count "$pid")
    zombie_count=$(_claude_zombie_count "$pid")
    cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')

    session_status="LIVE"
    if [ "$zombie_count" -ge "$max_zombies" ] || [ "$desc_count" -ge "$max_descendants" ]; then
      session_status="[RUNAWAY]"
    elif [ "$cpu_int" -lt 1 ]; then
      session_status="[IDLE]"
      idle_count=$((idle_count + 1))
    fi

    printf "  %-7s %8s %6s %-10s %-6s %-6s %s\n" \
      "$pid" "$mem_mb" "${cpu}%" "$etime" "$desc_count" "$zombie_count" "$session_status"

    session_count=$((session_count + 1))
    total_mb=$((total_mb + mem_mb))
    total_desc=$((total_desc + desc_count))
    total_zombies=$((total_zombies + zombie_count))
  done < <(_claude_session_pids)

  echo ""
  echo "  Sessions: $session_count total, $idle_count idle, $total_desc descendants, $total_zombies zombies"
  echo "  Total memory: ${total_mb} MB ($(awk "BEGIN {printf \"%.1f\", $total_mb/1024}") GB)"
  [ "${CC_USE_FOOTPRINT:-1}" != "0" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ] && echo "  Note: macOS session memory prefers footprint over RSS when larger."

  if [ "$session_count" -ge 4 ]; then
    echo ""
    echo "  WARNING: $session_count sessions is excessive. Keep 2-3 active when possible."
  fi
}

claude-guard() {
  local dry_run=false
  local quiet=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --quiet) quiet=true ;;
      *)
        echo "Usage: claude-guard [--dry-run] [--quiet]" >&2
        return 1
        ;;
    esac
    shift
  done

  _say() {
    $quiet || echo "$@"
  }

  local max_sessions=${CC_MAX_SESSIONS:-3}
  local idle_threshold=${CC_IDLE_THRESHOLD:-1}
  local max_rss_mb=${CC_MAX_RSS_MB:-4096}
  local max_descendants=${CC_MAX_DESCENDANTS:-128}
  local max_zombies=${CC_MAX_ZOMBIES:-16}
  local kill_bloated=${CC_GUARD_KILL_BLOATED:-0}
  local kill_idle=${CC_GUARD_KILL_IDLE:-0}
  local kill_descendants=${CC_GUARD_KILL_DESCENDANTS:-0}
  local kill_zombies=${CC_GUARD_KILL_ZOMBIES:-1}

  if ! echo "$max_rss_mb" | grep -qE '^[0-9]+$'; then
    _say "WARNING: CC_MAX_RSS_MB='$max_rss_mb' is not numeric, using default 4096"
    max_rss_mb=4096
  fi
  if ! echo "$max_descendants" | grep -qE '^[0-9]+$'; then
    _say "WARNING: CC_MAX_DESCENDANTS='$max_descendants' is not numeric, using default 128"
    max_descendants=128
  fi
  if ! echo "$max_zombies" | grep -qE '^[0-9]+$'; then
    _say "WARNING: CC_MAX_ZOMBIES='$max_zombies' is not numeric, using default 16"
    max_zombies=16
  fi

  _say "=== Claude Guard ==="
  _say "  Config: max_sessions=$max_sessions, idle_threshold=${idle_threshold}%, max_mem=${max_rss_mb} MB, max_descendants=$max_descendants, max_zombies=$max_zombies"
  _say "  Actions: kill_zombies=$kill_zombies, kill_descendants=$kill_descendants, kill_bloated=$kill_bloated, kill_idle=$kill_idle"
  _say ""

  local session_pids=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    session_pids+=("$line")
  done < <(_claude_session_pids)

  local session_count=${#session_pids[@]}
  if [ "$session_count" -eq 0 ]; then
    _say "  No Claude Code sessions running."
    return 0
  fi

  local forced_pids=()
  local forced_reason=()
  local forced_metric=()
  local idle_rows=""
  local alert_rows=""
  local live_count=0

  _say "  PID     MEM(MB)   CPU% ELAPSED    PROC   ZOMB   STATUS"
  _say "  ------- -------- ------ ---------- ------ ------ --------"

  for pid in "${session_pids[@]}"; do
    local info cpu etime mem_mb desc_count zombie_count cpu_int session_status reason age_secs
    info=$(ps -p "$pid" -o %cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue

    cpu=$(echo "$info" | awk '{print $1}')
    etime=$(echo "$info" | awk '{print $2}')
    mem_mb=$(_claude_session_memory_mb "$pid")
    desc_count=$(_claude_descendant_count "$pid")
    zombie_count=$(_claude_zombie_count "$pid")
    cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
    age_secs=$(_claude_etime_to_seconds "$etime")

    session_status="LIVE"
    reason=""
    if [ "$zombie_count" -ge "$max_zombies" ]; then
      session_status="[RUNAWAY]"
      reason="zombies"
      if [ "$kill_zombies" = "1" ]; then
        forced_pids+=("$pid")
        forced_reason+=("$reason")
        forced_metric+=("$zombie_count")
      else
        alert_rows="${alert_rows}zombies\t${pid}\t${etime}\t${zombie_count}\t${mem_mb}\n"
        session_status="[RUNAWAY:ALERT]"
      fi
    elif [ "$desc_count" -ge "$max_descendants" ]; then
      session_status="[RUNAWAY]"
      reason="descendants"
      if [ "$kill_descendants" = "1" ]; then
        forced_pids+=("$pid")
        forced_reason+=("$reason")
        forced_metric+=("$desc_count")
      else
        alert_rows="${alert_rows}descendants\t${pid}\t${etime}\t${desc_count}\t${mem_mb}\n"
        session_status="[RUNAWAY:ALERT]"
      fi
    elif [ "$mem_mb" -ge "$max_rss_mb" ]; then
      session_status="[BLOATED]"
      reason="memory"
      if [ "$kill_bloated" = "1" ]; then
        forced_pids+=("$pid")
        forced_reason+=("$reason")
        forced_metric+=("$mem_mb")
      else
        alert_rows="${alert_rows}memory\t${pid}\t${etime}\t${mem_mb}\t${mem_mb}\n"
        session_status="[BLOATED:ALERT]"
      fi
    elif [ "$cpu_int" -lt "$idle_threshold" ]; then
      session_status="[IDLE]"
      idle_rows="${idle_rows}${age_secs}\t${pid}\t${etime}\t${mem_mb}\n"
    else
      live_count=$((live_count + 1))
    fi

    _say "$(printf '  %-7s %8s %6s %-10s %-6s %-6s %s' "$pid" "$mem_mb" "${cpu}%" "$etime" "$desc_count" "$zombie_count" "$session_status")"
  done

  _say ""
  _say "  Sessions: $session_count total, ${#forced_pids[@]} forced-reap, $live_count live"

  local killed=0
  local freed_mb=0
  local planned_kills=0
  local planned_freed_mb=0

  if [ "${#forced_pids[@]}" -gt 0 ]; then
    _say ""
    _say "  --- Reaping runaway/bloated sessions ---"
    local i=0
    while [ "$i" -lt "${#forced_pids[@]}" ]; do
      local pid=${forced_pids[$i]}
      local reason=${forced_reason[$i]}
      local metric=${forced_metric[$i]}
      local mem_mb=$(_claude_session_memory_mb "$pid")
      planned_kills=$((planned_kills + 1))
      planned_freed_mb=$((planned_freed_mb + mem_mb))

      if $dry_run; then
        _say "  [DRY-RUN] Would kill PID $pid ($reason=$metric, memory=${mem_mb} MB)"
      else
        _claude_pgid_kill "$pid"
        _say "  Killed PID $pid ($reason=$metric, memory=${mem_mb} MB)"
        killed=$((killed + 1))
        freed_mb=$((freed_mb + mem_mb))
        _claude_guard_notify "Claude Guard" "Runaway session reaped" "Killed session PID $pid ($reason=$metric)"
      fi
      i=$((i + 1))
    done
  fi

  local remaining=$((session_count - killed))
  local idle_count=0
  [ -n "$idle_rows" ] && idle_count=$(printf "%b" "$idle_rows" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$remaining" -gt "$max_sessions" ] && [ "$idle_count" -gt 0 ] && [ "$kill_idle" = "1" ]; then
    local to_kill=$((remaining - max_sessions))
    [ "$to_kill" -gt "$idle_count" ] && to_kill=$idle_count

    _say ""
    _say "  --- Killing $to_kill idle session(s) to reach limit of $max_sessions ---"
    while IFS=$'\t' read -r age pid etime mem_mb; do
      [ -z "$pid" ] && continue
      planned_kills=$((planned_kills + 1))
      planned_freed_mb=$((planned_freed_mb + mem_mb))
      if $dry_run; then
        _say "  [DRY-RUN] Would kill PID $pid (idle ${etime}, memory=${mem_mb} MB)"
      else
        _claude_pgid_kill "$pid"
        _say "  Killed PID $pid (idle ${etime}, memory=${mem_mb} MB)"
        killed=$((killed + 1))
        freed_mb=$((freed_mb + mem_mb))
      fi
    done < <(printf "%b" "$idle_rows" | sed '/^$/d' | sort -nr | head -n "$to_kill")
  fi

  _say ""
  local alert_count=0
  [ -n "$alert_rows" ] && alert_count=$(printf "%b" "$alert_rows" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$alert_count" -gt 0 ]; then
    _say "  Inspect-only alerts:"
    while IFS=$'\t' read -r kind pid etime metric mem_mb; do
      [ -z "$pid" ] && continue
      case "$kind" in
        zombies)
          _say "    PID $pid has $metric zombies after $etime (memory=${mem_mb} MB)"
          ;;
        descendants)
          _say "    PID $pid has $metric descendants after $etime (memory=${mem_mb} MB)"
          ;;
        memory)
          _say "    PID $pid is using ${metric} MB after $etime"
          ;;
      esac
    done < <(printf "%b" "$alert_rows" | sed '/^$/d')
  fi

  if [ "$remaining" -gt "$max_sessions" ] && [ "$idle_count" -gt 0 ] && [ "$kill_idle" != "1" ]; then
    _say "  Idle eviction disabled: $idle_count idle session(s), $remaining total session(s)"
  fi

  if $dry_run && [ "$planned_kills" -gt 0 ]; then
    _say "  Would reap $planned_kills session(s), free ~${planned_freed_mb} MB"
  elif [ "$killed" -gt 0 ]; then
    _say "  Reaped $killed session(s), freed ~${freed_mb} MB"
    $dry_run || _claude_guard_notify "Claude Guard" "Cleanup complete" "Reaped $killed session(s), freed ~${freed_mb} MB"
  elif [ "$alert_count" -gt 0 ]; then
    _say "  No live sessions killed under safe defaults."
  else
    _say "  All clear — no sessions to reap."
  fi
}

claude-disk() {
  echo "=== Claude Code Disk Usage ==="
  echo ""

  local claude_tmp="/private/tmp/claude-$(id -u)"
  local claude_home="$HOME/.claude"
  local claude_projects="$claude_home/projects"
  local claude_tasks="$claude_home/tasks"

  if [ -d "$claude_tmp" ]; then
    local tmp_size output_count
    tmp_size=$(du -sh "$claude_tmp" 2>/dev/null | awk '{print $1}')
    output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "--- Task Output Files ---"
    echo "  Location: $claude_tmp"
    echo "  Total size: $tmp_size"
    echo "  .output files: $output_count"
  fi

  if [ -d "$claude_tasks" ]; then
    local tasks_size tasks_count
    tasks_size=$(du -sh "$claude_tasks" 2>/dev/null | awk '{print $1}')
    tasks_count=$(find "$claude_tasks" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo "--- ~/.claude/tasks ---"
    echo "  Total size: $tasks_size"
    echo "  Files: $tasks_count"
  fi

  if [ -d "$claude_projects" ]; then
    local project_size jsonl_count
    project_size=$(du -sh "$claude_projects" 2>/dev/null | awk '{print $1}')
    jsonl_count=$(find "$claude_projects" -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo "--- Session Logs (~/.claude/projects) ---"
    echo "  Total size: $project_size"
    echo "  .jsonl files: $jsonl_count"
    if [ "$jsonl_count" -gt 0 ]; then
      echo ""
      echo "  Largest session logs:"
      find "$claude_projects" -name "*.jsonl" -type f -exec ls -lh {} \; 2>/dev/null | sort -k5 -hr | head -5 | awk '{printf "  %s %s\n", $5, $NF}'
    fi
  fi

  echo ""
  echo "  Preservation policy: cc-reaper does not delete ~/.claude/projects session logs or ~/.claude/tasks files."
  echo ""
  echo "--- Disk Summary ---"
  df -h / 2>/dev/null | tail -1 | awk '{printf "  Root filesystem: %s used, %s available\n", $3, $4}'
}

claude-clean-disk() {
  local force=false
  [ "$1" = "--force" ] && force=true

  echo "=== Claude Code Disk Cleanup ==="

  local claude_tmp="/private/tmp/claude-$(id -u)"
  local active_sessions
  active_sessions=$(_claude_active_session_count)

  if [ -d "$claude_tmp" ]; then
    local before_size
    before_size=$(du -s "$claude_tmp" 2>/dev/null | awk '{print $1}')

    if $force; then
      if [ "$active_sessions" -gt 0 ]; then
        echo "  Refusing to delete $claude_tmp while $active_sessions Claude session(s) are active."
        echo "  Close Claude first, then re-run 'claude-clean-disk --force' if you want to purge temp files."
        echo ""
        echo "  Session logs and Claude task files remain preserved."
        return 1
      fi
      echo "  Cleaning $claude_tmp ..."
      rm -rf "$claude_tmp"
      local freed_mb=$((before_size * 512 / 1048576))
      [ "$freed_mb" -gt 0 ] && echo "  Freed ~${freed_mb} MB"
    else
      local output_count tmp_size
      output_count=$(find "$claude_tmp" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
      tmp_size=$(du -sh "$claude_tmp" 2>/dev/null | awk '{print $1}')
      echo "  Found $output_count .output files ($tmp_size)"
      echo ""
      echo "  Run 'claude-clean-disk --force' to delete temp files."
    fi
  fi

  echo ""
  echo "  Preservation policy: ~/.claude/projects session logs and ~/.claude/tasks files are never deleted by cc-reaper."
}

_claude_disk_check() {
 local claude_tmp="/private/tmp/claude-$(id -u)"
 local max_gb=${CLAUDE_DISK_MAX_GB:-10}

 if [ -d "$claude_tmp" ]; then
 local tmp_kb tmp_gb
 tmp_kb=$(du -sk "$claude_tmp" 2>/dev/null | awk '{print $1}')
 tmp_gb=$((tmp_kb / 1048576))

 if [ "$tmp_gb" -ge "$max_gb" ]; then
 echo "WARNING: Claude temp directory exceeds ${max_gb}GB: ${tmp_gb}GB" >&2
 echo "Run 'claude-clean-disk --force' to clean" >&2
 return 1
 fi
 fi
 return 0
 }

claude-health() {
 echo "=== Claude Code Health Check ==="
 echo ""

 echo "--- Memory ---"
 local total_rss
 total_rss=$(ps aux | grep -iE "[c]laude" | awk '{sum+=$6} END {printf "%.0f", sum/1024}')
 echo " Total RSS: ${total_rss} MB"
 [ "$(echo "$total_rss > 8000" | bc 2>/dev/null || echo 0)" -eq 1 ] && echo " ⚠️  High memory (>8GB)"

 echo ""
 echo "--- Processes ---"
 local session_count orphan_count zombie_count
 session_count=$(ps aux | grep "[c]laude --dangerously" | grep -v grep | wc -l | tr -d ' ')
 orphan_count=$(ps -eo pid,ppid,command | awk '$2 == 1' | grep -c "[c]laude" 2>/dev/null || echo 0)
 zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')
 echo " Sessions: $session_count"
 echo " Orphans: $orphan_count"
 echo " Zombies: $zombie_count"
 [ "$zombie_count" -gt 100 ] && echo " ⚠️  CRITICAL: Many zombies (#34092)"

 echo ""
 echo "--- Disk ---"
 local tmp_size
 tmp_size=$(du -sm /private/tmp/claude-$(id -u) 2>/dev/null | awk '{print $1}')
 echo " Temp: ${tmp_size} MB"
 [ "$(echo "$tmp_size > 5000" | bc 2>/dev/null || echo 0)" -eq 1 ] && echo " ⚠️  Large temp (#26911)"

 echo ""
 echo "--- V8 Heap Cap ---"
 if echo "$NODE_OPTIONS" | grep -q "max-old-space-size"; then
 echo " ✓ NODE_OPTIONS set"
 else
 echo " ⚠️  NOT SET — V8 may reserve 50% RAM (#27788)"
 echo "    Fix: export NODE_OPTIONS=\"--max-old-space-size=8192\""
 fi
}

claude-check-growthbook() {
 echo "=== GrowthBook Connection Check (#32692) ==="
 local gb_conns
 gb_conns=$(lsof -i :443 2>/dev/null | grep -c "160.79.104.10" || echo "0")
 if [ "$gb_conns" -gt 4 ]; then
 echo " ⚠️  $gb_conns GrowthBook connections — possible leak"
 echo "    Fix: export CLAUDE_CODE_DISABLE_GROWTHBOOK=1"
 else
 echo " ✓ Normal: $gb_conns connections"
 fi
}

claude-check-zombies() {
 echo "=== Zombie Process Check (#34092) ==="
 local zombie_count
 zombie_count=$(ps -eo pid,ppid,stat | awk '$2 == 1 && $3 ~ /Z/ {count++} END {print count+0}')
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
