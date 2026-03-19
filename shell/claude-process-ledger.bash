#!/bin/bash
# Shared session-descendant ledger helpers for cc-reaper

ccr_state_dir() {
  echo "${CC_REAPER_STATE_DIR:-$HOME/.cc-reaper/state}"
}

ccr_snapshot_dir() {
  echo "$(ccr_state_dir)/session-descendants"
}

ccr_init_state() {
  mkdir -p "$(ccr_snapshot_dir)"
}

ccr_snapshot_file() {
  local session_pid=$1
  echo "$(ccr_snapshot_dir)/session-${session_pid}.tsv"
}

ccr_prune_snapshots() {
  local snapshot_dir retention_days
  snapshot_dir=$(ccr_snapshot_dir)
  retention_days=${CC_REAPER_LEDGER_RETENTION_DAYS:-1}

  [ -d "$snapshot_dir" ] || return 0
  find "$snapshot_dir" -name 'session-*.tsv' -type f -mtime +"$retention_days" -delete 2>/dev/null
}

ccr_descendants() {
  local pid=$1
  local child

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    echo "$child"
    ccr_descendants "$child"
  done < <(pgrep -P "$pid" 2>/dev/null)
}

ccr_record_session_snapshot() {
  local session_pid=$1
  [ -n "$session_pid" ] || return 1
  kill -0 "$session_pid" 2>/dev/null || return 1

  ccr_init_state
  ccr_prune_snapshots

  local snapshot_file tmp_file
  snapshot_file=$(ccr_snapshot_file "$session_pid")
  tmp_file=$(mktemp "$(ccr_snapshot_dir)/session-${session_pid}.XXXXXX") || return 1

  {
    echo "$session_pid"
    ccr_descendants "$session_pid"
  } | awk 'NF {print $1}' | sort -u | while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue

    local ppid pgid cmd
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [ -n "$cmd" ] || continue

    printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$pgid" "$cmd"
  done > "$tmp_file"

  mv "$tmp_file" "$snapshot_file"
}

ccr_live_session_pids() {
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

ccr_refresh_active_session_snapshots() {
  ccr_init_state
  ccr_prune_snapshots

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    ccr_record_session_snapshot "$pid"
  done < <(ccr_live_session_pids)
}

ccr_known_orphan_pids() {
  local snapshot_dir
  snapshot_dir=$(ccr_snapshot_dir)
  [ -d "$snapshot_dir" ] || return 0

  find "$snapshot_dir" -name 'session-*.tsv' -type f -print 2>/dev/null | while IFS= read -r file; do
    [ -f "$file" ] || continue

    while IFS=$'\t' read -r pid _recorded_ppid recorded_pgid recorded_cmd; do
      [ -n "$pid" ] || continue
      kill -0 "$pid" 2>/dev/null || continue

      local current_ppid current_pgid current_cmd
      current_ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$current_ppid" = "1" ] || continue

      current_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      current_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
      [ -n "$current_cmd" ] || current_cmd="$recorded_cmd"

      printf '%s\t%s\t%s\n' "$pid" "${current_pgid:-$recorded_pgid}" "$current_cmd"
    done < "$file"
  done | awk -F '\t' '!seen[$1]++ {print $0}'
}
