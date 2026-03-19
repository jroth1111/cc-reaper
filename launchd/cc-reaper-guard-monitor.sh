#!/bin/bash
# cc-reaper guard monitor — runs claude-guard with safe defaults
# Runs periodically via macOS LaunchAgent and only auto-reaps conditions that are
# explicitly configured for destructive action.

LOG_DIR="$HOME/.cc-reaper/logs"
LOG_FILE="$LOG_DIR/guard-monitor.log"
HELPERS_FILE="$HOME/.cc-reaper/claude-cleanup-runtime.bash"
mkdir -p "$LOG_DIR"

# Rotate log if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

if [ ! -f "$HELPERS_FILE" ]; then
  log "Missing helpers file at $HELPERS_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$HELPERS_FILE"

OUTPUT=$(CC_GUARD_NOTIFY=0 claude-guard 2>&1)
STATUS=$?

if [ -n "$OUTPUT" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    log "$line"
  done <<< "$OUTPUT"
fi

exit "$STATUS"
