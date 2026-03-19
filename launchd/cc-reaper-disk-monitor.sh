#!/bin/bash
# cc-reaper disk monitor — inspect Claude Code disk usage without deleting logs
# Runs periodically via macOS LaunchAgent to surface temp growth and preserved logs.

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

# Inspect stale temp files without deleting them
OUTPUT_COUNT=$(find "$CLAUDE_TMP" -name "*.output" -type f 2>/dev/null | wc -l | tr -d ' ')
STALE_OUTPUT_COUNT=$(find "$CLAUDE_TMP" -name "*.output" -type f -mtime +$MAX_AGE_DAYS 2>/dev/null | wc -l | tr -d ' ')
DIR_COUNT=$(find "$CLAUDE_TMP" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
STALE_DIR_COUNT=$(find "$CLAUDE_TMP" -mindepth 1 -maxdepth 1 -type d -mtime +$MAX_AGE_DAYS 2>/dev/null | wc -l | tr -d ' ')

log "Temp artifacts: $OUTPUT_COUNT .output file(s), $STALE_OUTPUT_COUNT older than ${MAX_AGE_DAYS}d; $DIR_COUNT directory(s), $STALE_DIR_COUNT older than ${MAX_AGE_DAYS}d"

# If over threshold, warn but preserve artifacts
if [ "$TMP_GB" -ge "$MAX_GB" ]; then
 log "WARNING threshold exceeded (${TMP_GB}GB >= ${MAX_GB}GB); no deletion performed"
 
 # Desktop notification
 osascript -e "display notification \"Claude temp files are using ${TMP_GB}GB; no deletion performed\" with title \"Claude Reaper\" subtitle \"Disk inspection\"" 2>/dev/null &
fi

# Inspect ~/.claude/tasks without deleting
CLAUDE_TASKS="$HOME/.claude/tasks"
if [ -d "$CLAUDE_TASKS" ]; then
 TASK_COUNT=$(find "$CLAUDE_TASKS" -type f 2>/dev/null | wc -l | tr -d ' ')
 TASKS_SIZE=$(du -sh "$CLAUDE_TASKS" 2>/dev/null | awk '{print $1}')
 log "Preserved ~/.claude/tasks: $TASK_COUNT file(s), size=$TASKS_SIZE"
fi

# Inspect ~/.claude/projects session logs without deleting
CLAUDE_PROJECTS="$HOME/.claude/projects"
if [ -d "$CLAUDE_PROJECTS" ]; then
 PROJECT_COUNT=$(find "$CLAUDE_PROJECTS" -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
 PROJECT_SIZE=$(du -sh "$CLAUDE_PROJECTS" 2>/dev/null | awk '{print $1}')
 log "Preserved ~/.claude/projects: $PROJECT_COUNT jsonl log(s), size=$PROJECT_SIZE"
fi

log "No deletions performed; session logs and Claude task files are preserved."
