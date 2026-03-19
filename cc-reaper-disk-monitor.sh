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

# Clean old .output files first (regardless of size)
OUTPUT_BEFORE=$(find "$CLAUDE_TMP" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
find "$CLAUDE_TMP" -name "*.output" -type f -mtime +$MAX_AGE_DAYS -delete 2>/dev/null
OUTPUT_AFTER=$(find "$CLAUDE_TMP" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
OUTPUT_DELETED=$((OUTPUT_BEFORE - OUTPUT_AFTER))
[ "$OUTPUT_DELETED" -gt 0 ] && log "Deleted $OUTPUT_DELETED old .output files (>$MAX_AGE_DAYS days)"

# Clean old task directories (abandoned sessions)
DIRS_BEFORE=$(find "$CLAUDE_TMP" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
find "$CLAUDE_TMP" -mindepth 1 -maxdepth 1 -type d -mtime +$MAX_AGE_DAYS -exec rm -rf {} \; 2>/dev/null
DIRS_AFTER=$(find "$CLAUDE_TMP" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
DIRS_DELETED=$((DIRS_BEFORE - DIRS_AFTER))
[ "$DIRS_DELETED" -gt 0 ] && log "Deleted $DIRS_DELETED old session directories (>$MAX_AGE_DAYS days)"

# Recalculate size after age-based cleanup
TMP_KB=$(du -sk "$CLAUDE_TMP" 2>/dev/null | awk '{print $1}')
TMP_GB=$((TMP_KB / 1048576))

# If still over threshold, clean everything
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
 TASKS_BEFORE=$(find "$CLAUDE_TASKS" -type f 2>/dev/null | wc -l | tr -d ' ')
 find "$CLAUDE_TASKS" -type f -mtime +$MAX_AGE_DAYS -delete 2>/dev/null
 TASKS_AFTER=$(find "$CLAUDE_TASKS" -type f 2>/dev/null | wc -l | tr -d ' ')
 TASKS_DELETED=$((TASKS_BEFORE - TASKS_AFTER))
 [ "$TASKS_DELETED" -gt 0 ] && log "Deleted $TASKS_DELETED old files from ~/.claude/tasks"
fi
