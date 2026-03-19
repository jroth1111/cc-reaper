#!/bin/bash
# cc-reaper disk monitor — cleans Claude Code temp files
# Runs periodically via macOS LaunchAgent to prevent disk exhaustion

LOG_DIR="$HOME/.cc-reaper/logs"
LOG_FILE="$LOG_DIR/disk-monitor.log"
mkdir -p "$LOG_DIR"

# Rotate log if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
 mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
 echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Configuration
MAX_GB=${CLAUDE_DISK_MAX_GB:-10}
MAX_AGE_DAYS=${CLAUDE_DISK_MAX_AGE_DAYS:-7}

CLAUDE_TMP="/private/tmp/claude-$(id -u)"

if [ ! -d "$CLAUDE_TMP" ]; then
 log "No temp directory found"
 exit 0
fi

# Calculate current size
TMP_KB=$(du -sk "$CLAUDE_TMP" 2>/dev/null | awk '{print $1}')
TMP_GB=$((TMP_KB / 1048576))

log "Temp directory: ${TMP_GB}GB (threshold: ${MAX_GB}GB)"

# Clean old files first (regardless of size)
OLD_FILES=$(find "$CLAUDE_TMP" -name "*.output" -type f -mtime +$MAX_AGE_DAYS 2>/dev/null)
if [ -n "$OLD_FILES" ]; then
 OLD_COUNT=$(echo "$OLD_FILES" | wc -l | tr -d ' ')
 echo "$OLD_FILES" | xargs rm -f 2>/dev/null
 log "Deleted $OLD_COUNT files older than $MAX_AGE_DAYS days"
fi

# If still over threshold, clean everything
TMP_KB=$(du -sk "$CLAUDE_TMP" 2>/dev/null | awk '{print $1}')
TMP_GB=$((TMP_KB / 1048576))

if [ "$TMP_GB" -ge "$MAX_GB" ]; then
 log "Threshold exceeded (${TMP_GB}GB >= ${MAX_GB}GB), cleaning all temp files"
 rm -rf "$CLAUDE_TMP"
 log "Deleted temp directory"
 
 # Desktop notification
 osascript -e "display notification \"Cleaned ${TMP_GB}GB of Claude temp files\" with title \"Claude Reaper\" subtitle \"Disk cleanup\"" 2>/dev/null &
fi

# Also clean old ~/.claude/tasks files
CLAUDE_TASKS="$HOME/.claude/tasks"
if [ -d "$CLAUDE_TASKS" ]; then
 OLD_TASKS=$(find "$CLAUDE_TASKS" -type f -mtime +$MAX_AGE_DAYS 2>/dev/null)
 if [ -n "$OLD_TASKS" ]; then
 TASKS_COUNT=$(echo "$OLD_TASKS" | wc -l | tr -d ' ')
 echo "$OLD_TASKS" | xargs rm -f 2>/dev/null
 log "Deleted $TASKS_COUNT old task files from ~/.claude/tasks"
 fi
fi
